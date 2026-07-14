from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .geometry import expand_normalized_quad, order_quad, poly_iou


# These values mirror OpenCVDocumentFilterBridge.mm. The high threshold keeps
# the existing fast agreement path. The lower threshold only establishes that
# OpenCV and PageSeg are looking at the same object; it is never enough by
# itself to select the OpenCV boundary.
PAGESEG_AGREEMENT_IOU_THRESHOLD = 0.85
PAGESEG_SAME_OBJECT_IOU_THRESHOLD = 0.35
PAGESEG_MODEL_FALLBACK_EXPANSION = 0.02

# A disagreement is resolved in OpenCV's favor only when every side has usable
# image evidence and PageSeg has a materially weaker side. These thresholds
# were checked against the full 2,577-frame SmartDoc holdout cache as well as
# the raw inputs from the 2026-07-12 and 2026-07-14 reports.
OPENCV_EDGE_AVERAGE_THRESHOLD = 0.44
OPENCV_EDGE_MINIMUM_THRESHOLD = 0.20
OPENCV_EDGE_AVERAGE_ADVANTAGE = 0.06
OPENCV_EDGE_MINIMUM_ADVANTAGE = 0.20


@dataclass(frozen=True)
class BoundaryEdgeEvidence:
    sides: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)

    @property
    def average(self) -> float:
        return float(np.mean(self.sides))

    @property
    def minimum(self) -> float:
        return float(np.min(self.sides))


@dataclass(frozen=True)
class BoundaryFusionDecision:
    quad: np.ndarray | None
    source: str
    agreement_iou: float | None
    baseline_evidence: BoundaryEdgeEvidence
    model_evidence: BoundaryEdgeEvidence
    model_expansion: float = 0.0


def build_edge_support_map(bgr: np.ndarray, detect_size: int = 900) -> np.ndarray:
    """Build the same boundary-support image used by the iOS detector."""
    height, width = bgr.shape[:2]
    scale = min(1.0, float(detect_size) / max(1, height, width))
    if scale < 1.0:
        resized = cv2.resize(bgr, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    else:
        resized = bgr

    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0.0)
    canny = cv2.Canny(blurred, 40.0, 70.0)
    grad_x = cv2.Sobel(blurred, cv2.CV_16S, 1, 0, ksize=3)
    grad_y = cv2.Sobel(blurred, cv2.CV_16S, 0, 1, ksize=3)
    sobel = cv2.addWeighted(
        cv2.convertScaleAbs(grad_x),
        0.5,
        cv2.convertScaleAbs(grad_y),
        0.5,
        0.0,
    )
    support = cv2.max(canny, sobel)
    return cv2.dilate(support, cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3)))


def measure_quad_edge_evidence(
    edge_support_map: np.ndarray,
    normalized_quad: np.ndarray | None,
) -> BoundaryEdgeEvidence:
    if normalized_quad is None or edge_support_map.size == 0:
        return BoundaryEdgeEvidence()

    height, width = edge_support_map.shape[:2]
    points = order_quad(np.asarray(normalized_quad, dtype=np.float32))
    points = points * np.array([width, height], dtype=np.float32)
    thickness = max(3, min(width, height) // 120)
    sides: list[float] = []
    for start, end in zip(points, np.roll(points, -1, axis=0)):
        line_mask = np.zeros(edge_support_map.shape[:2], dtype=np.uint8)
        cv2.line(
            line_mask,
            tuple(np.round(start).astype(np.int32)),
            tuple(np.round(end).astype(np.int32)),
            255,
            thickness,
        )
        support = float(cv2.mean(edge_support_map, mask=line_mask)[0]) / 255.0
        sides.append(float(np.clip(support, 0.0, 1.0)))
    return BoundaryEdgeEvidence((sides[0], sides[1], sides[2], sides[3]))


def has_stronger_complete_boundary(
    agreement_iou: float,
    baseline: BoundaryEdgeEvidence,
    model: BoundaryEdgeEvidence,
) -> bool:
    return (
        agreement_iou >= PAGESEG_SAME_OBJECT_IOU_THRESHOLD
        and baseline.average >= OPENCV_EDGE_AVERAGE_THRESHOLD
        and baseline.minimum >= OPENCV_EDGE_MINIMUM_THRESHOLD
        and baseline.average - model.average >= OPENCV_EDGE_AVERAGE_ADVANTAGE
        and baseline.minimum - model.minimum >= OPENCV_EDGE_MINIMUM_ADVANTAGE
    )


def choose_boundary_fusion(
    bgr: np.ndarray,
    baseline_quad: np.ndarray | None,
    model_quad: np.ndarray | None,
    model_expansion: float = PAGESEG_MODEL_FALLBACK_EXPANSION,
) -> BoundaryFusionDecision:
    edge_support_map = build_edge_support_map(bgr)
    baseline_evidence = measure_quad_edge_evidence(edge_support_map, baseline_quad)
    model_evidence = measure_quad_edge_evidence(edge_support_map, model_quad)

    if model_quad is None:
        return BoundaryFusionDecision(
            quad=baseline_quad,
            source="opencv" if baseline_quad is not None else "none",
            agreement_iou=None,
            baseline_evidence=baseline_evidence,
            model_evidence=model_evidence,
        )
    if baseline_quad is None:
        return BoundaryFusionDecision(
            quad=expand_normalized_quad(model_quad, model_expansion),
            source="model",
            agreement_iou=None,
            baseline_evidence=baseline_evidence,
            model_evidence=model_evidence,
            model_expansion=model_expansion,
        )

    agreement_iou = poly_iou(baseline_quad, model_quad)
    if agreement_iou >= PAGESEG_AGREEMENT_IOU_THRESHOLD:
        source = "opencv_model_agreed"
        quad = baseline_quad
        expansion = 0.0
    elif has_stronger_complete_boundary(agreement_iou, baseline_evidence, model_evidence):
        source = "opencv_edge_supported"
        quad = baseline_quad
        expansion = 0.0
    else:
        source = "model"
        quad = expand_normalized_quad(model_quad, model_expansion)
        expansion = model_expansion

    return BoundaryFusionDecision(
        quad=quad,
        source=source,
        agreement_iou=agreement_iou,
        baseline_evidence=baseline_evidence,
        model_evidence=model_evidence,
        model_expansion=expansion,
    )
