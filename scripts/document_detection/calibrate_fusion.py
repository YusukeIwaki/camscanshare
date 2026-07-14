from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch

try:
    from scripts.document_detection.evaluate import (
        FUSED_IOU_DELTA_THRESHOLD,
        PAGESEG_AGREEMENT_IOU_THRESHOLD,
        PAGESEG_MODEL_FALLBACK_EXPANSION,
        PAGESEG_NEAR_FULL_FRAME_MASK_AREA_RATIO,
        _edge_touch_point_count,
        _ios_like_quad_score,
        choose_device,
        format_stats,
        load_eval_model,
        metric_stats,
        model_detect_info,
    )
    from scripts.document_detection.geometry import expand_normalized_quad, normalize_quad, poly_iou
    from scripts.document_detection.opencv_baseline import detect_document_quad
    from scripts.document_detection.seg_model import INPUT_SIZE
    from scripts.document_detection.smartdoc import SmartDocRecord, load_smartdoc_records
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.document_detection.evaluate import (
        FUSED_IOU_DELTA_THRESHOLD,
        PAGESEG_AGREEMENT_IOU_THRESHOLD,
        PAGESEG_MODEL_FALLBACK_EXPANSION,
        PAGESEG_NEAR_FULL_FRAME_MASK_AREA_RATIO,
        _edge_touch_point_count,
        _ios_like_quad_score,
        choose_device,
        format_stats,
        load_eval_model,
        metric_stats,
        model_detect_info,
    )
    from scripts.document_detection.geometry import expand_normalized_quad, normalize_quad, poly_iou
    from scripts.document_detection.opencv_baseline import detect_document_quad
    from scripts.document_detection.seg_model import INPUT_SIZE
    from scripts.document_detection.smartdoc import SmartDocRecord, load_smartdoc_records


SCHEMA_VERSION = 1


@dataclass(frozen=True)
class SweepSetting:
    family: str
    agreement_iou_threshold: float | None = None
    model_expansion: float = 0.0
    legacy_bonus: float | None = None

    @property
    def label(self) -> str:
        if self.family == "legacy_bonus":
            return f"legacy_bonus:{self.legacy_bonus:.2f}"
        return (
            f"{self.family}:T={self.agreement_iou_threshold:.2f}:"
            f"e={self.model_expansion:.2f}"
        )


def _quad_to_json(quad: np.ndarray | None) -> list[list[float]] | None:
    if quad is None:
        return None
    return [[float(x), float(y)] for x, y in np.asarray(quad, dtype=np.float32).reshape(4, 2)]


def _quad_from_json(value: Any) -> np.ndarray | None:
    if value is None:
        return None
    return np.asarray(value, dtype=np.float32).reshape(4, 2)


def _selected_records(records: list[SmartDocRecord], limit: int, stride: int) -> list[SmartDocRecord]:
    sample = records[:: max(1, stride)]
    return sample[:limit] if limit > 0 else sample


def _model_reject_reason(model_quad: np.ndarray | None, mask_area_ratio: float) -> str | None:
    if model_quad is None:
        return None
    edge_touch_count = _edge_touch_point_count(model_quad)
    if edge_touch_count >= 3 and mask_area_ratio < PAGESEG_NEAR_FULL_FRAME_MASK_AREA_RATIO:
        return "edge_touch"
    return None


@torch.no_grad()
def build_cache(
    checkpoint: Path,
    frames_dir: Path,
    holdout_bg: str,
    baseline_mode: str,
    limit: int,
    stride: int,
    device_name: str,
    cache_path: Path,
) -> dict[str, Any]:
    device = choose_device(device_name)
    model = load_eval_model(checkpoint, device)
    if model is None:
        raise RuntimeError("checkpoint is required to build calibration cache")
    model.eval()

    _, val_records = load_smartdoc_records(frames_dir, holdout_bg=holdout_bg)
    sample = _selected_records(val_records, limit=limit, stride=stride)
    rows: list[dict[str, Any]] = []

    started_at = time.time()
    for index, record in enumerate(sample):
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            print(f"warning: failed to read image: {record.path}", file=sys.stderr)
            continue

        h, w = bgr.shape[:2]
        gt = normalize_quad(record.quad, w, h)
        baseline_quad, baseline_meta = detect_document_quad(bgr, baseline_mode, normalized=True)
        baseline_score = _ios_like_quad_score(bgr, baseline_quad, bonus=0.0)
        baseline_iou = poly_iou(baseline_quad, gt, INPUT_SIZE)

        model_info, _ = model_detect_info(model, device, bgr)
        model_quad = model_info.quad
        model_score = _ios_like_quad_score(bgr, model_quad, bonus=0.0)
        model_iou = poly_iou(model_quad, gt, INPUT_SIZE)
        reject_reason = _model_reject_reason(model_quad, model_info.mask_area_ratio)

        rows.append(
            {
                "index": index,
                "path": str(record.path),
                "scene_id": record.scene_id,
                "frame_index": int(record.frame_index),
                "width": int(w),
                "height": int(h),
                "gt_quad": _quad_to_json(gt),
                "baseline_quad": _quad_to_json(baseline_quad),
                "baseline_score": None if baseline_score is None else float(baseline_score),
                "baseline_iou": float(baseline_iou),
                "baseline_source": str(baseline_meta.get("source", "none")),
                "baseline_kind": str(baseline_meta.get("kind", "none")),
                "model_quad": _quad_to_json(model_quad),
                "model_score": None if model_score is None else float(model_score),
                "model_component_mean_probability": float(model_info.component_mean_probability),
                "model_mask_area_ratio": float(model_info.mask_area_ratio),
                "model_iou": float(model_iou),
                "model_reject_reason": reject_reason,
            },
        )

        if (index + 1) % 50 == 0 or index + 1 == len(sample):
            elapsed = time.time() - started_at
            rate = (index + 1) / max(1e-6, elapsed)
            print(
                f"cached {index + 1}/{len(sample)} frames "
                f"({rate:.2f} fps, elapsed {elapsed / 60.0:.1f} min)",
                flush=True,
            )

    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "checkpoint": str(checkpoint),
        "frames_dir": str(frames_dir),
        "holdout_bg": holdout_bg,
        "baseline_mode": baseline_mode,
        "limit": int(limit),
        "stride": int(stride),
        "device": str(device),
        "created_at_unix": time.time(),
        "records_total": int(len(val_records)),
        "records_cached": int(len(rows)),
        "rows": rows,
    }
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"wrote cache: {cache_path} ({len(rows)} rows)")
    return payload


def load_or_build_cache(args: argparse.Namespace) -> dict[str, Any]:
    cache_path = Path(args.cache)
    if cache_path.exists() and not args.rebuild_cache:
        payload = json.loads(cache_path.read_text())
        if int(payload.get("schema_version", -1)) != SCHEMA_VERSION:
            raise RuntimeError(
                f"unsupported cache schema {payload.get('schema_version')}; "
                "rerun with --rebuild-cache",
            )
        return payload

    return build_cache(
        checkpoint=Path(args.checkpoint),
        frames_dir=Path(args.frames_dir),
        holdout_bg=args.holdout_bg,
        baseline_mode=args.baseline_mode,
        limit=args.limit,
        stride=args.stride,
        device_name=args.device,
        cache_path=cache_path,
    )


def choose_row(row: dict[str, Any], setting: SweepSetting) -> tuple[float, str]:
    baseline_score = row.get("baseline_score")
    model_score = row.get("model_score")
    model_iou = float(row.get("model_iou") or 0.0)
    baseline_iou = float(row.get("baseline_iou") or 0.0)
    baseline_quad = _quad_from_json(row.get("baseline_quad"))
    model_quad = _quad_from_json(row.get("model_quad"))
    gt_quad = _quad_from_json(row.get("gt_quad"))

    model_available = (
        row.get("model_quad") is not None
        and model_score is not None
        and row.get("model_reject_reason") is None
    )
    if not model_available:
        return baseline_iou, "opencv" if row.get("baseline_quad") is not None else "none"

    if setting.family == "legacy_bonus":
        bonus = float(setting.legacy_bonus or 0.0)
        if baseline_score is None or float(model_score) + bonus > float(baseline_score):
            return model_iou, "model"
        return baseline_iou, "opencv" if row.get("baseline_quad") is not None else "none"

    if (
        baseline_quad is not None
        and model_quad is not None
        and poly_iou(baseline_quad, model_quad, INPUT_SIZE) >= float(setting.agreement_iou_threshold)
    ):
        return baseline_iou, "opencv_model_agreed"

    expanded_model_quad = expand_normalized_quad(model_quad, float(setting.model_expansion))
    if expanded_model_quad is not None and gt_quad is not None:
        return poly_iou(expanded_model_quad, gt_quad, INPUT_SIZE), "model"
    if model_quad is not None:
        return model_iou, "model"

    return baseline_iou, "opencv" if row.get("baseline_quad") is not None else "none"


def evaluate_setting(rows: list[dict[str, Any]], setting: SweepSetting) -> dict[str, Any]:
    fused_ious: list[float] = []
    baseline_ious: list[float] = []
    model_ious: list[float] = []
    improved = 0
    worsened = 0
    model_selected = 0
    opencv_model_agreed_selected = 0
    model_edge_rejected = 0

    for row in rows:
        baseline_iou = float(row.get("baseline_iou") or 0.0)
        model_iou = float(row.get("model_iou") or 0.0)
        baseline_ious.append(baseline_iou)
        model_ious.append(model_iou)
        if row.get("model_reject_reason") == "edge_touch":
            model_edge_rejected += 1

        fused_iou, source = choose_row(row, setting)
        fused_ious.append(float(fused_iou))
        if source == "model":
            model_selected += 1
        elif source == "opencv_model_agreed":
            opencv_model_agreed_selected += 1

        delta = float(fused_iou) - baseline_iou
        if delta >= FUSED_IOU_DELTA_THRESHOLD:
            improved += 1
        elif delta <= -FUSED_IOU_DELTA_THRESHOLD:
            worsened += 1

    fused_stats = metric_stats(fused_ious)
    baseline_stats = metric_stats(baseline_ious)
    model_stats = metric_stats(model_ious)
    return {
        "label": setting.label,
        "family": setting.family,
        "agreement_iou_threshold": setting.agreement_iou_threshold,
        "model_expansion": float(setting.model_expansion),
        "legacy_bonus": setting.legacy_bonus,
        "fused": fused_stats,
        "baseline": baseline_stats,
        "model": model_stats,
        "improved_vs_baseline_005": int(improved),
        "worsened_vs_baseline_005": int(worsened),
        "model_selected": int(model_selected),
        "opencv_model_agreed_selected": int(opencv_model_agreed_selected),
        "model_edge_rejected": int(model_edge_rejected),
    }


def float_range(start: float, stop: float, step: float) -> list[float]:
    values: list[float] = []
    current = start
    while current <= stop + step * 0.5:
        values.append(round(current, 10))
        current += step
    return values


def sweep(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    settings: list[SweepSetting] = []
    settings.append(SweepSetting("legacy_bonus", legacy_bonus=0.25))
    for threshold in (0.5, 0.6, 0.7, 0.8, 0.85, 0.9):
        for expansion in (0.0, 0.01, 0.02, 0.03, 0.04):
            settings.append(
                SweepSetting(
                    "agreement",
                    agreement_iou_threshold=threshold,
                    model_expansion=expansion,
                ),
            )

    return [evaluate_setting(rows, setting) for setting in settings]


def _percent(value: float) -> float:
    return float(value) * 100.0


def format_result_row(result: dict[str, Any]) -> str:
    fused = result["fused"]
    if result["family"] == "legacy_bonus":
        threshold_text = "-"
        expansion_text = "-"
        bonus_text = f"{float(result['legacy_bonus']):.2f}"
    else:
        threshold_text = f"{float(result['agreement_iou_threshold']):.2f}"
        expansion_text = f"{float(result['model_expansion']):.2f}"
        bonus_text = "-"
    return (
        f"{result['family']:<9s} "
        f"{bonus_text:>6s} "
        f"{threshold_text:>5s} "
        f"{expansion_text:>5s} "
        f"{fused['mean']:>7.4f} "
        f"{fused['p05']:>7.4f} "
        f"{_percent(fused['iou80']):>8.2f} "
        f"{_percent(fused['iou90']):>8.2f} "
        f"{result['improved_vs_baseline_005']:>8d} "
        f"{result['worsened_vs_baseline_005']:>7d} "
        f"{result['model_selected']:>7d} "
        f"{result['opencv_model_agreed_selected']:>7d}"
    )


def result_sort_key(result: dict[str, Any]) -> tuple[float, float, float, int]:
    fused = result["fused"]
    return (
        float(fused["mean"]),
        float(fused["p05"]),
        float(fused["iou80"]),
        -int(result["model_selected"]),
    )


def write_results(results: list[dict[str, Any]], out_dir: Path, max_worsened: int) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "fusion-calibration-results.json").write_text(
        json.dumps(results, indent=2, sort_keys=True) + "\n",
    )

    csv_lines = [
        "family,legacy_bonus,agreement_iou_threshold,model_expansion,mean,median,p05,iou80,iou90,"
        "improved_vs_baseline_005,worsened_vs_baseline_005,model_selected,"
        "opencv_model_agreed_selected,model_edge_rejected",
    ]
    for result in results:
        fused = result["fused"]
        csv_lines.append(
            ",".join(
                [
                    str(result["family"]),
                    "" if result["legacy_bonus"] is None else f"{float(result['legacy_bonus']):.4f}",
                    ""
                    if result["agreement_iou_threshold"] is None
                    else f"{float(result['agreement_iou_threshold']):.4f}",
                    f"{float(result['model_expansion']):.4f}",
                    f"{float(fused['mean']):.8f}",
                    f"{float(fused['median']):.8f}",
                    f"{float(fused['p05']):.8f}",
                    f"{float(fused['iou80']):.8f}",
                    f"{float(fused['iou90']):.8f}",
                    str(int(result["improved_vs_baseline_005"])),
                    str(int(result["worsened_vs_baseline_005"])),
                    str(int(result["model_selected"])),
                    str(int(result["opencv_model_agreed_selected"])),
                    str(int(result["model_edge_rejected"])),
                ],
            ),
        )
    (out_dir / "fusion-calibration-results.csv").write_text("\n".join(csv_lines) + "\n")

    eligible = [
        r
        for r in results
        if r["family"] != "legacy_bonus" and int(r["worsened_vs_baseline_005"]) <= max_worsened
    ]
    best = max(eligible, key=result_sort_key) if eligible else max(results, key=result_sort_key)
    representative = representative_rows(results, best, max_worsened)

    lines = [
        "family     bonus     T     e    mean     p05  IoU>=80  IoU>=90 improved worsened   model   agreed",
        "---------------------------------------------------------------------------------------------------",
    ]
    lines.extend(format_result_row(result) for result in representative)
    lines.append("")
    lines.append(f"best_eligible={best['label']} max_worsened={max_worsened}")
    lines.append(format_result_row(best))
    (out_dir / "fusion-calibration-summary.txt").write_text("\n".join(lines) + "\n")


def representative_rows(
    results: list[dict[str, Any]],
    best: dict[str, Any],
    max_worsened: int,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []

    def add_unique(result: dict[str, Any]) -> None:
        key = result["label"]
        if all(existing["label"] != key for existing in rows):
            rows.append(result)

    for result in results:
        if result["family"] == "legacy_bonus":
            add_unique(result)

    add_unique(best)
    eligible = [
        r
        for r in results
        if r["family"] != "legacy_bonus" and int(r["worsened_vs_baseline_005"]) <= max_worsened
    ]
    for result in sorted(eligible, key=result_sort_key, reverse=True)[:12]:
        add_unique(result)
    for result in results:
        if result["family"] == "agreement":
            add_unique(result)
    return rows


def print_summary(payload: dict[str, Any], results: list[dict[str, Any]], max_worsened: int) -> None:
    rows = payload["rows"]
    baseline = metric_stats([float(row.get("baseline_iou") or 0.0) for row in rows])
    model = metric_stats([float(row.get("model_iou") or 0.0) for row in rows])
    print(format_stats("model", model))
    print(format_stats("baseline", baseline))
    eligible = [
        r
        for r in results
        if r["family"] != "legacy_bonus" and int(r["worsened_vs_baseline_005"]) <= max_worsened
    ]
    best = max(eligible, key=result_sort_key) if eligible else max(results, key=result_sort_key)
    print("")
    print("family     bonus     T     e    mean     p05  IoU>=80  IoU>=90 improved worsened   model   agreed")
    print("---------------------------------------------------------------------------------------------------")
    for result in representative_rows(results, best, max_worsened):
        print(format_result_row(result))
    print("")
    print(f"best eligible: {best['label']}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Calibrate model/OpenCV document-detection fusion on SmartDoc holdout.")
    parser.add_argument("--checkpoint", default="tmp/docdet-v3/best.pt")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--baseline-mode", choices=("capture", "preview"), default="capture")
    parser.add_argument("--cache", default="tmp/docdet-v3/fusion-calibration-cache.json")
    parser.add_argument("--out-dir", default="tmp/docdet-v3/fusion-calibration")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--stride", type=int, default=1)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--rebuild-cache", action="store_true")
    parser.add_argument("--max-worsened", type=int, default=50)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    payload = load_or_build_cache(args)
    rows = payload["rows"]
    if not rows:
        raise SystemExit("no cached rows")
    results = sweep(rows)
    out_dir = Path(args.out_dir)
    write_results(results, out_dir, max_worsened=args.max_worsened)
    print_summary(payload, results, max_worsened=args.max_worsened)
    print(f"\nwrote results under: {out_dir}")


if __name__ == "__main__":
    main()
