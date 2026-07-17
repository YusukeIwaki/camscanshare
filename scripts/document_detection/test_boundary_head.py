from __future__ import annotations

import unittest

import cv2
import numpy as np

from .boundary_head_dataset import targets_from_mask
from .boundary_head_model import quad_from_mask_and_boundary
from .geometry import normalize_quad, poly_iou


class BoundaryHeadTest(unittest.TestCase):
    def test_boundary_target_and_fit_recover_an_inset_mask_quad(self) -> None:
        size = 320
        expected_px = np.array([[43, 30], [277, 45], [291, 282], [28, 268]], dtype=np.float32)
        mask = np.zeros((size, size), dtype=np.float32)
        cv2.fillConvexPoly(mask, expected_px.astype(np.int32), 1.0)
        boundary, present, fully_visible = targets_from_mask(mask, boundary_width=3)
        expected = normalize_quad(expected_px, size, size)
        center = expected.mean(axis=0, keepdims=True)
        coarse = center + (expected - center) * 0.95

        result = quad_from_mask_and_boundary(coarse, boundary, search_band_ratio=0.06)

        self.assertEqual(present, 1.0)
        self.assertEqual(fully_visible, 1.0)
        self.assertIsNotNone(result.quad)
        self.assertEqual(result.accepted_side_count, 4)
        self.assertGreater(poly_iou(result.quad, expected), poly_iou(coarse, expected) + 0.03)

    def test_negative_mask_has_no_boundary_or_state(self) -> None:
        boundary, present, fully_visible = targets_from_mask(np.zeros((64, 64), dtype=np.float32))
        self.assertEqual(int(np.count_nonzero(boundary)), 0)
        self.assertEqual(present, 0.0)
        self.assertEqual(fully_visible, 0.0)

    def test_missing_mask_quad_stays_undetected(self) -> None:
        result = quad_from_mask_and_boundary(None, np.zeros((320, 320), dtype=np.float32))
        self.assertIsNone(result.quad)
        self.assertEqual(result.accepted_side_count, 0)


if __name__ == "__main__":
    unittest.main()
