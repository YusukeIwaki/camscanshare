from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch

from .boundary_head_model import (
    PageBoundaryNet,
    load_boundary_checkpoint_state,
    quad_from_mask_and_boundary,
)
from .boundary_fusion import choose_boundary_fusion
from .finder_eval import load_manifests
from .geometry import denormalize_quad, draw_quad, normalize_quad, poly_iou, write_contact_sheet
from .opencv_baseline import detect_document_quad
from .seg_model import INPUT_SIZE, PageSegNet, load_checkpoint_state, quad_from_mask_info
from .smartdoc import SmartDocRecord, load_smartdoc_records


def choose_device(requested: str) -> torch.device:
    if requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _percentile(values: list[float], percentile: float) -> float | None:
    return float(np.percentile(np.asarray(values, dtype=np.float32), percentile)) if values else None


def _corner_errors(
    predicted: np.ndarray | None,
    expected: np.ndarray,
    width: int,
    height: int,
) -> np.ndarray:
    if predicted is None:
        return np.ones(4, dtype=np.float32)
    scale = np.array([width, height], dtype=np.float32)
    diagonal = max(1.0, math.hypot(width, height))
    return np.linalg.norm((predicted - expected) * scale, axis=1) / diagonal


def _result(
    quad: np.ndarray | None,
    gt: np.ndarray,
    width: int,
    height: int,
    latency_ms: float | None,
) -> dict[str, Any]:
    errors = _corner_errors(quad, gt, width, height)
    return {
        "detected": quad is not None,
        "quad": quad.tolist() if quad is not None else None,
        "iou": poly_iou(quad, gt, INPUT_SIZE),
        "mean_corner_error": float(errors.mean()),
        "max_corner_error": float(errors.max()),
        "latency_ms": latency_ms,
    }


def _summary(rows: list[dict[str, Any]], key: str) -> dict[str, Any]:
    ious = [float(row[key]["iou"]) for row in rows]
    mean_errors = [float(row[key]["mean_corner_error"]) for row in rows]
    max_errors = [float(row[key]["max_corner_error"]) for row in rows]
    latencies = [float(row[key]["latency_ms"]) for row in rows if row[key].get("latency_ms") is not None]
    return {
        "n": len(rows),
        "recall": float(np.mean([row[key]["detected"] for row in rows])) if rows else None,
        "iou": {
            "mean": float(np.mean(ious)) if ious else None,
            "p50": _percentile(ious, 50),
            "p05": _percentile(ious, 5),
            "pass_080": float(np.mean(np.asarray(ious) >= 0.80)) if ious else None,
            "pass_090": float(np.mean(np.asarray(ious) >= 0.90)) if ious else None,
            "pass_095": float(np.mean(np.asarray(ious) >= 0.95)) if ious else None,
        },
        "mean_corner_error_by_diagonal": {
            "mean": float(np.mean(mean_errors)) if mean_errors else None,
            "p50": _percentile(mean_errors, 50),
            "p90": _percentile(mean_errors, 90),
            "p95": _percentile(mean_errors, 95),
            "p99": _percentile(mean_errors, 99),
        },
        "max_corner_error_by_diagonal": {
            "mean": float(np.mean(max_errors)) if max_errors else None,
            "p95": _percentile(max_errors, 95),
        },
        "latency_ms_desktop": {
            "p50": _percentile(latencies, 50),
            "p95": _percentile(latencies, 95),
        },
    }


def _input_tensor(bgr: np.ndarray, device: torch.device) -> torch.Tensor:
    rgb = cv2.cvtColor(
        cv2.resize(bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_AREA),
        cv2.COLOR_BGR2RGB,
    )
    return torch.from_numpy(rgb).permute(2, 0, 1).float().div(255.0).unsqueeze(0).to(device)


def _synchronize(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


@torch.no_grad()
def _base_prediction(
    model: PageSegNet,
    tensor: torch.Tensor,
    device: torch.device,
) -> tuple[np.ndarray | None, float]:
    _synchronize(device)
    started = time.perf_counter()
    probability = torch.sigmoid(model(tensor))[0, 0].detach().cpu().numpy()
    _synchronize(device)
    latency_ms = (time.perf_counter() - started) * 1000.0
    return quad_from_mask_info(probability).quad, latency_ms


@torch.no_grad()
def _boundary_prediction(
    model: PageBoundaryNet,
    tensor: torch.Tensor,
    device: torch.device,
    search_band_ratio: float,
) -> tuple[np.ndarray | None, np.ndarray | None, np.ndarray, np.ndarray, float, float, Any]:
    _synchronize(device)
    started = time.perf_counter()
    mask_logits, boundary_logits, state_logits = model(tensor)
    _synchronize(device)
    inference_ms = (time.perf_counter() - started) * 1000.0
    mask_probability = torch.sigmoid(mask_logits)[0, 0].detach().cpu().numpy()
    boundary_probability = torch.sigmoid(boundary_logits)[0, 0].detach().cpu().numpy()
    state_probability = torch.sigmoid(state_logits)[0].detach().cpu().numpy()
    mask_quad = quad_from_mask_info(mask_probability).quad
    fit_started = time.perf_counter()
    boundary_result = quad_from_mask_and_boundary(
        mask_quad,
        boundary_probability,
        search_band_ratio=search_band_ratio,
    )
    fit_ms = (time.perf_counter() - fit_started) * 1000.0
    return (
        mask_quad,
        boundary_result.quad,
        mask_probability,
        boundary_probability,
        inference_ms,
        fit_ms,
        (state_probability, boundary_result),
    )


def _load_records(args: argparse.Namespace) -> tuple[list[SmartDocRecord], str]:
    if not args.manifest:
        _, records = load_smartdoc_records(args.frames_dir, holdout_bg=args.holdout_bg)
        return records, f"SmartDoc holdout {args.holdout_bg}"
    records: list[SmartDocRecord] = []
    for index, sample in enumerate(load_manifests([Path(value) for value in args.manifest])):
        if sample.document_state != "fully_visible" or sample.corners is None:
            continue
        image = cv2.imread(str(sample.image))
        if image is None:
            continue
        height, width = image.shape[:2]
        records.append(
            SmartDocRecord(
                path=sample.image,
                quad=denormalize_quad(sample.corners, width, height),
                bg_name="finder",
                model_name=sample.id,
                frame_index=index,
                model_width=float(width),
                model_height=float(height),
            )
        )
    return records, "finder manifests"


def _draw_overlay(row: dict[str, Any]) -> np.ndarray | None:
    image = cv2.imread(row["image"])
    if image is None:
        return None

    def quad(key: str) -> np.ndarray | None:
        return np.asarray(row[key]["quad"], dtype=np.float32) if row[key]["quad"] else None

    overlay = draw_quad(image, np.asarray(row["ground_truth"], dtype=np.float32), (0, 190, 0), "GT")
    overlay = draw_quad(overlay, quad("base_mask"), (255, 128, 0), "base mask")
    overlay = draw_quad(overlay, quad("trained_mask"), (255, 0, 0), "trained mask")
    overlay = draw_quad(overlay, quad("boundary"), (255, 0, 255), "boundary")
    overlay = draw_quad(overlay, quad("opencv_preview"), (0, 0, 255), "OpenCV")
    overlay = draw_quad(overlay, quad("boundary_fused"), (0, 190, 255), "fused")
    return overlay


def evaluate(args: argparse.Namespace) -> dict[str, Any]:
    device = choose_device(args.device)
    records, split_name = _load_records(args)
    selected = records[:: max(1, args.stride)]
    if args.limit > 0:
        selected = selected[: args.limit]
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    base_model = PageSegNet(pretrained=False).to(device)
    base_model.load_state_dict(load_checkpoint_state(args.base_checkpoint))
    base_model.eval()
    model = PageBoundaryNet(pretrained=False).to(device)
    model.load_state_dict(load_boundary_checkpoint_state(args.checkpoint))
    model.eval()
    warmup = torch.zeros((1, 3, INPUT_SIZE, INPUT_SIZE), dtype=torch.float32, device=device)
    with torch.no_grad():
        for _ in range(3):
            base_model(warmup)
            model(warmup)
    _synchronize(device)

    rows: list[dict[str, Any]] = []
    for index, record in enumerate(selected):
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            continue
        height, width = bgr.shape[:2]
        gt = normalize_quad(record.quad, width, height)
        tensor = _input_tensor(bgr, device)
        base_quad, base_latency = _base_prediction(base_model, tensor, device)
        (
            trained_mask_quad,
            boundary_quad,
            _,
            _,
            inference_ms,
            fit_ms,
            extra,
        ) = _boundary_prediction(model, tensor, device, args.search_band_ratio)
        state_probability, boundary_result = extra
        gated_boundary = (
            boundary_quad
            if state_probability[0] >= args.presence_threshold
            and state_probability[1] >= args.full_threshold
            else None
        )
        opencv_started = time.perf_counter()
        opencv_quad, opencv_meta = detect_document_quad(bgr, "preview", normalized=True)
        opencv_ms = (time.perf_counter() - opencv_started) * 1000.0
        fusion_started = time.perf_counter()
        fusion = choose_boundary_fusion(
            bgr,
            opencv_quad,
            boundary_quad,
            model_expansion=0.0,
        )
        fusion_ms = (time.perf_counter() - fusion_started) * 1000.0
        rows.append(
            {
                "id": f"{record.scene_id}/frame-{record.frame_index}",
                "image": str(record.path),
                "ground_truth": gt.tolist(),
                "presence_probability": float(state_probability[0]),
                "fully_visible_probability": float(state_probability[1]),
                "accepted_side_count": boundary_result.accepted_side_count,
                "boundary_sides": [
                    {
                        "confidence": side.confidence,
                        "point_count": side.point_count,
                        "angle_delta_degrees": side.angle_delta_degrees,
                        "accepted": side.accepted,
                    }
                    for side in boundary_result.sides
                ],
                "opencv_source": opencv_meta.get("source"),
                "opencv_kind": opencv_meta.get("kind"),
                "fusion_source": fusion.source,
                "fusion_agreement_iou": fusion.agreement_iou,
                "opencv_preview": _result(opencv_quad, gt, width, height, opencv_ms),
                "base_mask": _result(base_quad, gt, width, height, base_latency),
                "trained_mask": _result(trained_mask_quad, gt, width, height, inference_ms),
                "boundary": _result(boundary_quad, gt, width, height, inference_ms + fit_ms),
                "boundary_gated": _result(gated_boundary, gt, width, height, inference_ms + fit_ms),
                "boundary_fused": _result(
                    fusion.quad,
                    gt,
                    width,
                    height,
                    inference_ms + fit_ms + fusion_ms,
                ),
                "boundary_fit_latency_ms": fit_ms,
            }
        )
        if (index + 1) % 100 == 0 or index + 1 == len(selected):
            print(f"evaluated {index + 1}/{len(selected)}", flush=True)

    keys = (
        "opencv_preview",
        "base_mask",
        "trained_mask",
        "boundary",
        "boundary_gated",
        "boundary_fused",
    )
    metrics = {key: _summary(rows, key) for key in keys}
    mask_ious = np.asarray([row["trained_mask"]["iou"] for row in rows], dtype=np.float32)
    boundary_ious = np.asarray([row["boundary"]["iou"] for row in rows], dtype=np.float32)
    deltas = boundary_ious - mask_ious
    metrics["boundary_delta"] = {
        "mean": float(deltas.mean()) if len(deltas) else None,
        "improved_001": int(np.count_nonzero(deltas >= 0.01)),
        "worsened_001": int(np.count_nonzero(deltas <= -0.01)),
        "improved_005": int(np.count_nonzero(deltas >= 0.05)),
        "worsened_005": int(np.count_nonzero(deltas <= -0.05)),
        "mean_accepted_sides": float(np.mean([row["accepted_side_count"] for row in rows])) if rows else None,
        "fit_latency_ms_desktop": {
            "p50": _percentile([row["boundary_fit_latency_ms"] for row in rows], 50),
            "p95": _percentile([row["boundary_fit_latency_ms"] for row in rows], 95),
        },
    }
    fusion_ious = np.asarray([row["boundary_fused"]["iou"] for row in rows], dtype=np.float32)
    fusion_deltas = fusion_ious - boundary_ious
    fusion_sources: dict[str, int] = {}
    for row in rows:
        source = str(row["fusion_source"])
        fusion_sources[source] = fusion_sources.get(source, 0) + 1
    metrics["fusion_delta"] = {
        "mean_vs_boundary": float(fusion_deltas.mean()) if len(fusion_deltas) else None,
        "improved_vs_boundary_001": int(np.count_nonzero(fusion_deltas >= 0.01)),
        "worsened_vs_boundary_001": int(np.count_nonzero(fusion_deltas <= -0.01)),
        "improved_vs_boundary_005": int(np.count_nonzero(fusion_deltas >= 0.05)),
        "worsened_vs_boundary_005": int(np.count_nonzero(fusion_deltas <= -0.05)),
        "sources": fusion_sources,
    }
    summary = {
        "checkpoint": args.checkpoint,
        "base_checkpoint": args.base_checkpoint,
        "device": str(device),
        "split": split_name,
        "stride": args.stride,
        "search_band_ratio": args.search_band_ratio,
        "metrics": metrics,
        "rows": rows,
    }
    (out_dir / "metrics.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

    priority = sorted(rows, key=lambda row: row["boundary"]["iou"])[: args.max_overlays // 2]
    priority += sorted(
        rows,
        key=lambda row: row["boundary"]["iou"] - row["trained_mask"]["iou"],
        reverse=True,
    )[: args.max_overlays // 4]
    priority += sorted(
        rows,
        key=lambda row: row["boundary"]["iou"] - row["trained_mask"]["iou"],
    )[: args.max_overlays // 4]
    unique: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in priority:
        if row["id"] not in seen:
            seen.add(row["id"])
            unique.append(row)
    overlays: list[np.ndarray] = []
    labels: list[str] = []
    for overlay_index, row in enumerate(unique[: args.max_overlays]):
        overlay = _draw_overlay(row)
        if overlay is None:
            continue
        image = cv2.imread(row["image"])
        tensor = _input_tensor(image, device)
        _, _, mask_probability, boundary_probability, _, _, _ = _boundary_prediction(
            model,
            tensor,
            device,
            args.search_band_ratio,
        )
        cv2.imwrite(str(out_dir / f"mask_probability_{overlay_index:03d}.png"), np.clip(mask_probability * 255, 0, 255).astype(np.uint8))
        cv2.imwrite(
            str(out_dir / f"boundary_probability_{overlay_index:03d}.png"),
            np.clip(boundary_probability * 255, 0, 255).astype(np.uint8),
        )
        delta = row["boundary"]["iou"] - row["trained_mask"]["iou"]
        label = (
            f"{row['id']} base={row['base_mask']['iou']:.2f} mask={row['trained_mask']['iou']:.2f} "
            f"boundary={row['boundary']['iou']:.2f} d={delta:+.2f}"
        )
        cv2.imwrite(str(out_dir / f"overlay_{overlay_index:03d}.jpg"), overlay)
        overlays.append(overlay)
        labels.append(label)
    write_contact_sheet(overlays, out_dir / "contact_sheet.jpg", labels, cols=3, cell_width=520, cell_height=360)
    return summary


def _format(name: str, metric: dict[str, Any]) -> str:
    return (
        f"{name:16s} n={metric['n']:4d} recall={metric['recall']:.4f} "
        f"mean={metric['iou']['mean']:.4f} p05={metric['iou']['p05']:.4f} "
        f"IoU80={metric['iou']['pass_080']:.4f} IoU90={metric['iou']['pass_090']:.4f} "
        f"cornerP95={metric['mean_corner_error_by_diagonal']['p95']:.4f}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate PageSeg spatial boundary head")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--base-checkpoint", default="tmp/docdet-v3/best.pt")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--manifest", action="append", default=None)
    parser.add_argument("--out-dir", default="tmp/docdet-boundary-v1/eval")
    parser.add_argument("--limit", type=int, default=650)
    parser.add_argument("--stride", type=int, default=4)
    parser.add_argument("--search-band-ratio", type=float, default=0.03)
    parser.add_argument("--presence-threshold", type=float, default=0.5)
    parser.add_argument("--full-threshold", type=float, default=0.5)
    parser.add_argument("--max-overlays", type=int, default=36)
    parser.add_argument("--device", default="auto")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    summary = evaluate(args)
    for key in (
        "opencv_preview",
        "base_mask",
        "trained_mask",
        "boundary",
        "boundary_gated",
        "boundary_fused",
    ):
        print(_format(key, summary["metrics"][key]))
    print(json.dumps(summary["metrics"]["boundary_delta"], indent=2, sort_keys=True))
    print(json.dumps(summary["metrics"]["fusion_delta"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
