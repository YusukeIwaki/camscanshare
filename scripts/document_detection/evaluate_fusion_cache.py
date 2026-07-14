from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from .boundary_fusion import (
    PAGESEG_AGREEMENT_IOU_THRESHOLD,
    PAGESEG_MODEL_FALLBACK_EXPANSION,
    choose_boundary_fusion,
)
from .evaluate import FUSED_IOU_DELTA_THRESHOLD, metric_stats
from .geometry import expand_normalized_quad, poly_iou


def _quad(value: Any) -> np.ndarray | None:
    if value is None:
        return None
    return np.asarray(value, dtype=np.float32).reshape(4, 2)


def _previous_fusion(
    baseline_quad: np.ndarray | None,
    model_quad: np.ndarray | None,
) -> tuple[np.ndarray | None, str]:
    if model_quad is None:
        return baseline_quad, "opencv" if baseline_quad is not None else "none"
    if (
        baseline_quad is not None
        and poly_iou(baseline_quad, model_quad) >= PAGESEG_AGREEMENT_IOU_THRESHOLD
    ):
        return baseline_quad, "opencv_model_agreed"
    return expand_normalized_quad(model_quad, PAGESEG_MODEL_FALLBACK_EXPANSION), "model"


def evaluate_cache(cache_path: Path, out_path: Path) -> dict[str, Any]:
    payload = json.loads(cache_path.read_text())
    baseline_ious: list[float] = []
    model_ious: list[float] = []
    previous_ious: list[float] = []
    fused_ious: list[float] = []
    sources: Counter[str] = Counter()
    previous_sources: Counter[str] = Counter()
    changed = 0
    failed_images: list[str] = []

    for row in payload.get("rows") or []:
        bgr = cv2.imread(str(row["path"]))
        if bgr is None:
            failed_images.append(str(row["path"]))
            continue
        gt_quad = _quad(row.get("gt_quad"))
        baseline_quad = _quad(row.get("baseline_quad"))
        raw_model_quad = _quad(row.get("model_quad"))
        model_quad = raw_model_quad if row.get("model_reject_reason") is None else None

        decision = choose_boundary_fusion(bgr, baseline_quad, model_quad)
        previous_quad, previous_source = _previous_fusion(baseline_quad, model_quad)
        baseline_iou = poly_iou(baseline_quad, gt_quad)
        model_iou = poly_iou(raw_model_quad, gt_quad)
        previous_iou = poly_iou(previous_quad, gt_quad)
        fused_iou = poly_iou(decision.quad, gt_quad)

        baseline_ious.append(baseline_iou)
        model_ious.append(model_iou)
        previous_ious.append(previous_iou)
        fused_ious.append(fused_iou)
        sources[decision.source] += 1
        previous_sources[previous_source] += 1
        if decision.source != previous_source or poly_iou(decision.quad, previous_quad) < 0.999:
            changed += 1

    baseline_array = np.asarray(baseline_ious, dtype=np.float32)
    fused_array = np.asarray(fused_ious, dtype=np.float32)
    previous_array = np.asarray(previous_ious, dtype=np.float32)
    summary = {
        "cache": str(cache_path),
        "records": len(fused_ious),
        "failed_images": failed_images,
        "baseline": metric_stats(baseline_ious),
        "model": metric_stats(model_ious),
        "previous_fused": metric_stats(previous_ious),
        "new_fused": metric_stats(fused_ious),
        "previous_sources": dict(previous_sources),
        "new_sources": dict(sources),
        "changed_vs_previous": changed,
        "new_worsened_vs_baseline_005": int(
            np.count_nonzero(fused_array <= baseline_array - FUSED_IOU_DELTA_THRESHOLD)
        ),
        "previous_worsened_vs_baseline_005": int(
            np.count_nonzero(previous_array <= baseline_array - FUSED_IOU_DELTA_THRESHOLD)
        ),
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate production fusion on a cached SmartDoc holdout")
    parser.add_argument("--cache", default="tmp/docdet-v3/fusion-calibration-cache.json")
    parser.add_argument("--out", default="tmp/docdet-v5/fusion-cache-eval/summary.json")
    args = parser.parse_args()
    print(json.dumps(evaluate_cache(Path(args.cache), Path(args.out)), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
