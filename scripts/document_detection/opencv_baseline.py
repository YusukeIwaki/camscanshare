from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import numpy as np

try:
    from scripts.filter_asset_pipeline import find_document_candidate
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from filter_asset_pipeline import find_document_candidate

from .geometry import normalize_quad, order_quad


def detect_document_quad(
    bgr: np.ndarray,
    detection_mode: str = "capture",
    normalized: bool = True,
) -> tuple[np.ndarray | None, dict[str, Any]]:
    """App-equivalent OpenCV document detector.

    This wraps the Python version used by scripts/generate_step0_samples.py,
    which mirrors the current app detector more closely than the old v1 Canny
    baseline. It returns an ordered quad and detector metadata.
    """
    candidate = find_document_candidate(bgr, detection_mode=detection_mode)
    if candidate is None or candidate.get("points") is None:
        return None, {"source": "none", "kind": "none", "score": None, "mode": detection_mode}

    points = order_quad(np.asarray(candidate["points"], dtype=np.float32))
    if normalized:
        h, w = bgr.shape[:2]
        points = normalize_quad(points, w, h)
    return points, candidate

