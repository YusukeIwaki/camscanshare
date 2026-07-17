from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from .annotate_finder_eval import ManifestStore
from .finder_eval import load_manifests, normalized_corner_errors


class FinderEvalTest(unittest.TestCase):
    def _manifest(self, sample: dict) -> Path:
        directory = Path(tempfile.mkdtemp(dir=Path.cwd() / "tmp"))
        path = directory / "manifest.json"
        path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "coordinate_space": "normalized_top_left",
                    "samples": [sample],
                }
            )
        )
        return path

    def test_full_document_requires_four_corners(self) -> None:
        path = self._manifest(
            {
                "id": "missing-corners",
                "image": "docs/public/algorithm/test.jpg",
                "document_state": "fully_visible",
                "corners": None,
            }
        )
        with self.assertRaisesRegex(ValueError, "require four corners"):
            load_manifests([path])

    def test_no_document_rejects_corners(self) -> None:
        path = self._manifest(
            {
                "id": "negative-with-corners",
                "image": "docs/public/algorithm/test.jpg",
                "document_state": "no_document",
                "corners": [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]],
            }
        )
        with self.assertRaisesRegex(ValueError, "cannot have corners"):
            load_manifests([path])

    def test_corner_error_is_normalized_by_image_diagonal(self) -> None:
        expected = np.array([[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]], dtype=np.float32)
        predicted = expected.copy()
        predicted[:, 0] += 0.1
        errors = normalized_corner_errors(predicted, expected, width=400, height=300)
        np.testing.assert_allclose(errors, np.full(4, 0.08), atol=1e-6)

    def test_annotation_store_creates_an_empty_local_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "finder-eval.local.json"

            store = ManifestStore(path)

            self.assertEqual(store.samples, [])
            payload = json.loads(path.read_text())
            self.assertEqual(payload["coordinate_space"], "normalized_top_left")


if __name__ == "__main__":
    unittest.main()
