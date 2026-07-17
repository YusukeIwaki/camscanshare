from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from .geometry import order_quad
from .seg_model import INPUT_SIZE, PageSegNet, load_checkpoint_state


class PageBoundaryNet(PageSegNet):
    """PageSegNet with spatial boundary and document-state heads."""

    def __init__(self, pretrained: bool = True):
        super().__init__(pretrained=pretrained, include_sigmoid=False)
        self.boundary_head = nn.Conv2d(24, 1, 1)
        self.state_head = nn.Linear(160, 2)

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        normalized = (image - self.mean) / self.std
        skips: dict[str, torch.Tensor] = {}
        encoded = normalized
        for index, layer in enumerate(self.encoder):
            encoded = layer(encoded)
            if index == 0:
                skips["s0"] = encoded
            elif index == 1:
                skips["s1"] = encoded
            elif index == 3:
                skips["s2"] = encoded
            elif index == 8:
                skips["s3"] = encoded

        center = self.center(encoded)
        state_logits = self.state_head(F.adaptive_avg_pool2d(center, 1).flatten(1))
        decoded = self.up3(center, skips["s3"])
        decoded = self.up2(decoded, skips["s2"])
        decoded = self.up1(decoded, skips["s1"])
        decoded = self.up0(decoded, skips["s0"])
        decoded = F.interpolate(decoded, size=normalized.shape[-2:], mode="bilinear", align_corners=False)
        features = self.refine(decoded)
        return self.head(features), self.boundary_head(features), state_logits


def count_parameters(model: nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters())


def load_base_segmentation_weights(model: PageBoundaryNet, checkpoint: str | Path) -> tuple[list[str], list[str]]:
    state = load_checkpoint_state(checkpoint)
    result = model.load_state_dict(state, strict=False)
    expected_missing = {
        "boundary_head.weight",
        "boundary_head.bias",
        "state_head.weight",
        "state_head.bias",
    }
    missing = set(result.missing_keys)
    if missing != expected_missing or result.unexpected_keys:
        raise ValueError(
            f"unexpected PageSeg checkpoint mismatch: missing={sorted(missing)} "
            f"unexpected={sorted(result.unexpected_keys)}"
        )
    return list(result.missing_keys), list(result.unexpected_keys)


def load_boundary_checkpoint_state(path: str | Path) -> dict[str, Any]:
    checkpoint = torch.load(path, map_location="cpu")
    if isinstance(checkpoint, dict) and "model_state" in checkpoint:
        return checkpoint["model_state"]
    return checkpoint


@dataclass(frozen=True)
class BoundarySideFit:
    confidence: float
    point_count: int
    angle_delta_degrees: float
    accepted: bool


@dataclass(frozen=True)
class BoundaryQuadResult:
    quad: np.ndarray | None
    sides: tuple[BoundarySideFit, BoundarySideFit, BoundarySideFit, BoundarySideFit]

    @property
    def accepted_side_count(self) -> int:
        return sum(side.accepted for side in self.sides)


def _empty_side() -> BoundarySideFit:
    return BoundarySideFit(0.0, 0, 0.0, False)


def _weighted_line(points: np.ndarray, weights: np.ndarray) -> tuple[np.ndarray, float] | None:
    total = float(weights.sum())
    if len(points) < 8 or total <= 1e-6:
        return None
    center = (points * weights[:, None]).sum(axis=0) / total
    centered = points - center
    covariance = (centered * weights[:, None]).T @ centered / total
    values, vectors = np.linalg.eigh(covariance)
    tangent = vectors[:, int(np.argmax(values))].astype(np.float32)
    if float(np.linalg.norm(tangent)) < 1e-6:
        return None
    tangent /= np.linalg.norm(tangent)
    normal = np.array([-tangent[1], tangent[0]], dtype=np.float32)
    return normal, float(np.dot(normal, center))


def _intersect(
    line_a: tuple[np.ndarray, float],
    line_b: tuple[np.ndarray, float],
) -> np.ndarray | None:
    matrix = np.stack([line_a[0], line_b[0]]).astype(np.float64)
    if abs(float(np.linalg.det(matrix))) < 1e-4:
        return None
    return np.linalg.solve(
        matrix,
        np.array([line_a[1], line_b[1]], dtype=np.float64),
    ).astype(np.float32)


def _angle_delta_degrees(first: np.ndarray, second: np.ndarray) -> float:
    cosine = float(np.clip(abs(np.dot(first, second)), 0.0, 1.0))
    return float(np.degrees(np.arccos(cosine)))


def quad_from_mask_and_boundary(
    mask_quad: np.ndarray | None,
    boundary_probability: np.ndarray,
    *,
    search_band_ratio: float = 0.03,
    probability_threshold: float = 0.20,
    min_confidence: float = 0.28,
    max_angle_delta_degrees: float = 12.0,
) -> BoundaryQuadResult:
    """Fit one spatial boundary-map line near each side of a mask quad."""
    empty = (_empty_side(), _empty_side(), _empty_side(), _empty_side())
    if mask_quad is None:
        return BoundaryQuadResult(None, empty)
    probability = np.asarray(boundary_probability, dtype=np.float32)
    if probability.ndim != 2 or probability.size == 0:
        return BoundaryQuadResult(order_quad(mask_quad), empty)
    height, width = probability.shape
    coarse = order_quad(mask_quad) * np.array([width, height], dtype=np.float32)
    yy, xx = np.mgrid[0:height, 0:width]
    all_points = np.stack([xx.reshape(-1), yy.reshape(-1)], axis=1).astype(np.float32)
    all_probability = probability.reshape(-1)
    search_band = max(3.0, min(width, height) * float(search_band_ratio))

    lines: list[tuple[np.ndarray, float]] = []
    side_results: list[BoundarySideFit] = []
    for side_index in range(4):
        start = coarse[side_index]
        end = coarse[(side_index + 1) % 4]
        direction = end - start
        length = float(np.linalg.norm(direction))
        if length < 8.0:
            return BoundaryQuadResult(order_quad(mask_quad), empty)
        tangent = direction / length
        coarse_normal = np.array([-tangent[1], tangent[0]], dtype=np.float32)
        relative = all_points - start
        along = relative @ tangent
        distance = relative @ coarse_normal
        candidate_mask = (
            (along >= 0.06 * length)
            & (along <= 0.94 * length)
            & (np.abs(distance) <= search_band)
            & (all_probability >= probability_threshold)
        )
        points = all_points[candidate_mask]
        probabilities = all_probability[candidate_mask]
        # Prefer strong boundary probabilities while retaining enough of a
        # soft band for a sub-pixel weighted fit.
        weights = np.square(probabilities)
        line = _weighted_line(points, weights)
        confidence = float(np.average(probabilities, weights=weights)) if len(points) else 0.0
        accepted = False
        angle_delta = 0.0
        if line is not None:
            fitted_normal, fitted_constant = line
            angle_delta = _angle_delta_degrees(fitted_normal, coarse_normal)
            if np.dot(fitted_normal, coarse_normal) < 0:
                fitted_normal = -fitted_normal
                fitted_constant = -fitted_constant
            # One robust reweighting pass suppresses corner bleed and isolated
            # boundary activations away from the fitted side.
            residual = np.abs(points @ fitted_normal - fitted_constant)
            robust = np.exp(-0.5 * np.square(residual / max(1.0, search_band * 0.20)))
            refined = _weighted_line(points, weights * robust)
            if refined is not None:
                fitted_normal, fitted_constant = refined
                if np.dot(fitted_normal, coarse_normal) < 0:
                    fitted_normal = -fitted_normal
                    fitted_constant = -fitted_constant
                angle_delta = _angle_delta_degrees(fitted_normal, coarse_normal)
            accepted = (
                len(points) >= max(12, int(length * 0.08))
                and confidence >= min_confidence
                and angle_delta <= max_angle_delta_degrees
            )
        if not accepted:
            fitted_normal = coarse_normal
            fitted_constant = float(np.dot(coarse_normal, start))
        lines.append((fitted_normal, fitted_constant))
        side_results.append(
            BoundarySideFit(
                confidence=confidence,
                point_count=len(points),
                angle_delta_degrees=angle_delta,
                accepted=accepted,
            )
        )

    intersections: list[np.ndarray] = []
    for corner_index in range(4):
        point = _intersect(lines[(corner_index - 1) % 4], lines[corner_index])
        if point is None:
            return BoundaryQuadResult(order_quad(mask_quad), tuple(side_results))
        intersections.append(point)
    refined_px = np.asarray(intersections, dtype=np.float32)
    if not np.isfinite(refined_px).all() or not cv2.isContourConvex(np.round(refined_px).astype(np.int32)):
        return BoundaryQuadResult(order_quad(mask_quad), tuple(side_results))
    if abs(float(cv2.contourArea(refined_px))) < 0.01 * width * height:
        return BoundaryQuadResult(order_quad(mask_quad), tuple(side_results))
    if float(np.max(np.linalg.norm(refined_px - coarse, axis=1))) > search_band * 2.75:
        return BoundaryQuadResult(order_quad(mask_quad), tuple(side_results))
    normalized = order_quad(refined_px / np.array([width, height], dtype=np.float32))
    if (normalized < -0.02).any() or (normalized > 1.02).any():
        return BoundaryQuadResult(order_quad(mask_quad), tuple(side_results))
    return BoundaryQuadResult(np.clip(normalized, 0.0, 1.0), tuple(side_results))
