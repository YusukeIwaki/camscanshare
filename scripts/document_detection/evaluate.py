from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import torch

try:
    from scripts.filter_asset_pipeline import candidate_edge_support, score_document_quad
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from filter_asset_pipeline import candidate_edge_support, score_document_quad

from .boundary_fusion import (
    PAGESEG_AGREEMENT_IOU_THRESHOLD,
    PAGESEG_MODEL_FALLBACK_EXPANSION,
    choose_boundary_fusion,
)
from .geometry import denormalize_quad, draw_quad, normalize_quad, poly_iou, write_contact_sheet
from .opencv_baseline import detect_document_quad
from .seg_model import INPUT_SIZE, MaskQuadInfo, PageSegNet, load_checkpoint_state, quad_from_mask_info
from .smartdoc import SmartDocRecord, load_smartdoc_records

PAGESEG_NEAR_FULL_FRAME_MASK_AREA_RATIO = 0.68
FUSED_IOU_DELTA_THRESHOLD = 0.05
IOS_EDGE_SUPPORT_SCORE_WEIGHT = 0.18


def choose_device(requested: str = "auto") -> torch.device:
    if requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def metric_stats(values: list[float]) -> dict[str, float]:
    arr = np.array(values, dtype=np.float32) if values else np.array([0.0], dtype=np.float32)
    return {
        "n": int(arr.size),
        "mean": float(arr.mean()),
        "median": float(np.median(arr)),
        "p05": float(np.percentile(arr, 5)),
        "iou80": float((arr >= 0.80).mean()),
        "iou90": float((arr >= 0.90).mean()),
    }


def format_stats(name: str, stats: dict[str, float]) -> str:
    return (
        f"{name:8s} n={int(stats['n']):4d} "
        f"mean={stats['mean']:.4f} median={stats['median']:.4f} p05={stats['p05']:.4f} "
        f"IoU>=0.80={stats['iou80']:.4f} IoU>=0.90={stats['iou90']:.4f}"
    )


@torch.no_grad()
def model_detect_info(model: PageSegNet, device: torch.device, bgr: np.ndarray) -> tuple[MaskQuadInfo, np.ndarray]:
    rgb = cv2.cvtColor(cv2.resize(bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    tensor = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255.0).unsqueeze(0).to(device)
    logits = model(tensor)
    prob = torch.sigmoid(logits)[0, 0].detach().cpu().numpy()
    return quad_from_mask_info(prob), prob


@torch.no_grad()
def model_detect(model: PageSegNet, device: torch.device, bgr: np.ndarray) -> tuple[np.ndarray | None, np.ndarray]:
    info, prob = model_detect_info(model, device, bgr)
    return info.quad, prob


def _edge_touch_point_count(normalized_quad: np.ndarray | None) -> int:
    if normalized_quad is None:
        return 0
    points = np.asarray(normalized_quad, dtype=np.float32).reshape(4, 2)
    touches = (
        (points[:, 0] < 0.02)
        | (points[:, 0] > 0.98)
        | (points[:, 1] < 0.02)
        | (points[:, 1] > 0.98)
    )
    return int(np.count_nonzero(touches))


def _ios_like_quad_score(bgr: np.ndarray, normalized_quad: np.ndarray | None, bonus: float = 0.0) -> float | None:
    if normalized_quad is None:
        return None
    h, w = bgr.shape[:2]
    denormalized = denormalize_quad(normalized_quad, w, h)
    area = float(abs(cv2.contourArea(denormalized)))
    geometry_score = score_document_quad(
        denormalized,
        area=area,
        image_area=float(max(1, w) * max(1, h)),
        image_width=w,
        image_height=h,
    )
    edge_score = candidate_edge_support(bgr, denormalized) * IOS_EDGE_SUPPORT_SCORE_WEIGHT
    return geometry_score + edge_score + bonus


def _choose_fused_quad(
    bgr: np.ndarray,
    baseline_quad: np.ndarray | None,
    model_info: MaskQuadInfo | None,
) -> tuple[np.ndarray | None, str, float | None, float | None, str | None]:
    baseline_score = _ios_like_quad_score(bgr, baseline_quad)
    model_score = None
    reject_reason = None

    model_quad = model_info.quad if model_info is not None else None
    if model_quad is not None and model_info is not None:
        edge_touch_count = _edge_touch_point_count(model_quad)
        if edge_touch_count >= 3 and model_info.mask_area_ratio < PAGESEG_NEAR_FULL_FRAME_MASK_AREA_RATIO:
            reject_reason = "edge_touch"
        else:
            model_score = _ios_like_quad_score(bgr, model_quad)

    accepted_model_quad = model_quad if model_score is not None else None
    decision = choose_boundary_fusion(bgr, baseline_quad, accepted_model_quad)

    return decision.quad, decision.source, baseline_score, model_score, reject_reason


def _selected_records(records: list[SmartDocRecord], limit: int, stride: int) -> list[SmartDocRecord]:
    sample = records[:: max(1, stride)]
    return sample[:limit] if limit > 0 else sample


def _draw_eval_overlay(
    bgr: np.ndarray,
    gt: np.ndarray,
    baseline: np.ndarray | None,
    model_quad: np.ndarray | None,
    fused_quad: np.ndarray | None,
    label: str,
) -> np.ndarray:
    vis = draw_quad(bgr, gt, (0, 210, 0), "GT", normalized=True)
    vis = draw_quad(vis, baseline, (0, 0, 255), "baseline", normalized=True)
    vis = draw_quad(vis, model_quad, (255, 128, 0), "model", normalized=True)
    vis = draw_quad(vis, fused_quad, (255, 0, 255), "fused", normalized=True)
    cv2.rectangle(vis, (0, vis.shape[0] - 34), (vis.shape[1], vis.shape[0]), (255, 255, 255), -1)
    cv2.putText(vis, label, (12, vis.shape[0] - 11), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (30, 30, 30), 1, cv2.LINE_AA)
    return vis


def evaluate_records(
    model: PageSegNet | None,
    device: torch.device,
    records: list[SmartDocRecord],
    out_dir: Path,
    limit: int = 1000,
    stride: int = 4,
    max_overlays: int = 36,
    baseline_mode: str = "capture",
) -> dict[str, dict[str, float]]:
    out_dir.mkdir(parents=True, exist_ok=True)
    sample = _selected_records(records, limit, stride)
    model_ious: list[float] = []
    baseline_ious: list[float] = []
    fused_ious: list[float] = []
    fused_improved = 0
    fused_worsened = 0
    fused_model_selected = 0
    fused_opencv_model_agreed = 0
    fused_opencv_edge_supported = 0
    fused_model_edge_rejected = 0
    contact_images: list[np.ndarray] = []
    contact_labels: list[str] = []

    if model is not None:
        model.eval()

    for index, record in enumerate(sample):
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            continue
        h, w = bgr.shape[:2]
        gt = normalize_quad(record.quad, w, h)
        baseline_quad, baseline_meta = detect_document_quad(bgr, baseline_mode, normalized=True)
        baseline_iou = poly_iou(baseline_quad, gt, INPUT_SIZE)
        baseline_ious.append(baseline_iou)

        model_quad = None
        model_iou = 0.0
        fused_quad = baseline_quad
        fused_source = "baseline" if baseline_quad is not None else "none"
        baseline_score = None
        model_score = None
        if model is not None:
            model_info, _ = model_detect_info(model, device, bgr)
            model_quad = model_info.quad
            model_iou = poly_iou(model_quad, gt, INPUT_SIZE)
            model_ious.append(model_iou)
            fused_quad, fused_source, baseline_score, model_score, reject_reason = _choose_fused_quad(
                bgr,
                baseline_quad,
                model_info,
            )
            if reject_reason == "edge_touch":
                fused_model_edge_rejected += 1
            if fused_source == "model":
                fused_model_selected += 1
            elif fused_source == "opencv_model_agreed":
                fused_opencv_model_agreed += 1
            elif fused_source == "opencv_edge_supported":
                fused_opencv_edge_supported += 1
            fused_iou = poly_iou(fused_quad, gt, INPUT_SIZE)
            fused_ious.append(fused_iou)
            delta = fused_iou - baseline_iou
            if delta >= FUSED_IOU_DELTA_THRESHOLD:
                fused_improved += 1
            elif delta <= -FUSED_IOU_DELTA_THRESHOLD:
                fused_worsened += 1

        if index < max_overlays:
            fused_iou = poly_iou(fused_quad, gt, INPUT_SIZE) if model is not None else baseline_iou
            label = (
                f"{record.scene_id}/f{record.frame_index} "
                f"base={baseline_iou:.2f} model={model_iou:.2f} fused={fused_iou:.2f}/{fused_source} "
                f"s=({baseline_score if baseline_score is not None else -1:.2f},"
                f"{model_score if model_score is not None else -1:.2f}) "
                f"{baseline_meta.get('source', 'none')}:{baseline_meta.get('kind', 'none')}"
            )
            overlay = _draw_eval_overlay(bgr, gt, baseline_quad, model_quad, fused_quad, label)
            path = out_dir / f"smartdoc_{index:03d}.jpg"
            cv2.imwrite(str(path), overlay)
            contact_images.append(overlay)
            contact_labels.append(label)

    if contact_images:
        write_contact_sheet(contact_images, out_dir / "smartdoc_contact_sheet.jpg", contact_labels, cols=3)

    metrics: dict[str, dict[str, float]] = {"baseline": metric_stats(baseline_ious)}
    if model is not None:
        metrics["model"] = metric_stats(model_ious)
        fused_stats = metric_stats(fused_ious)
        fused_stats.update(
            {
                "improved_vs_baseline_005": float(fused_improved),
                "worsened_vs_baseline_005": float(fused_worsened),
                "model_selected": float(fused_model_selected),
                "opencv_model_agreed_selected": float(fused_opencv_model_agreed),
                "opencv_edge_supported_selected": float(fused_opencv_edge_supported),
                "model_edge_rejected": float(fused_model_edge_rejected),
            },
        )
        metrics["fused"] = fused_stats
    return metrics


def _draw_report_overlay(
    bgr: np.ndarray,
    baseline_quad: np.ndarray | None,
    model_quad: np.ndarray | None,
    fused_quad: np.ndarray | None,
    label: str,
) -> np.ndarray:
    vis = draw_quad(bgr, baseline_quad, (0, 0, 255), "baseline", normalized=True)
    vis = draw_quad(vis, model_quad, (255, 128, 0), "model", normalized=True)
    vis = draw_quad(vis, fused_quad, (255, 0, 255), "fused", normalized=True)
    cv2.rectangle(vis, (0, vis.shape[0] - 34), (vis.shape[1], vis.shape[0]), (255, 255, 255), -1)
    cv2.putText(vis, label, (12, vis.shape[0] - 11), cv2.FONT_HERSHEY_SIMPLEX, 0.62, (30, 30, 30), 1, cv2.LINE_AA)
    return vis


def generate_report_overlays(
    model: PageSegNet | None,
    device: torch.device,
    report_root: Path,
    out_dir: Path,
    limit: int = 80,
    baseline_mode: str = "capture",
) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    # source.jpg is already perspective-corrected and cannot reproduce the
    # paper detector. Evaluate only the raw capture saved in debug sessions.
    paths: list[str] = []
    for report_dir in sorted(report_root.glob("report-*")):
        raw_inputs = sorted(glob.glob(str(report_dir / "debug" / "*" / "02_input.png")))
        if raw_inputs:
            paths.append(raw_inputs[-1])
    if limit > 0:
        paths = paths[:limit]
    contact_images: list[np.ndarray] = []
    contact_labels: list[str] = []

    if model is not None:
        model.eval()

    for index, source_path in enumerate(paths):
        bgr = cv2.imread(source_path)
        if bgr is None:
            continue
        baseline_quad, baseline_meta = detect_document_quad(bgr, baseline_mode, normalized=True)
        model_quad = None
        fused_quad = baseline_quad
        fused_source = "baseline" if baseline_quad is not None else "none"
        baseline_score = _ios_like_quad_score(bgr, baseline_quad)
        model_score = None
        if model is not None:
            model_info, _ = model_detect_info(model, device, bgr)
            model_quad = model_info.quad
            fused_quad, fused_source, baseline_score, model_score, reject_reason = _choose_fused_quad(
                bgr,
                baseline_quad,
                model_info,
            )
        report_id = Path(source_path).parents[2].name
        label = (
            f"{report_id} fused={fused_source} "
            f"s=({baseline_score if baseline_score is not None else -1:.2f},"
            f"{model_score if model_score is not None else -1:.2f}) "
            f"{baseline_meta.get('source', 'none')}:{baseline_meta.get('kind', 'none')}"
        )
        overlay = _draw_report_overlay(bgr, baseline_quad, model_quad, fused_quad, label)
        cv2.imwrite(str(out_dir / f"{report_id}.jpg"), overlay)
        contact_images.append(overlay)
        contact_labels.append(label)

    if contact_images:
        write_contact_sheet(contact_images, out_dir / "report_contact_sheet.jpg", contact_labels, cols=3)
    return len(contact_images)


def load_eval_model(checkpoint: Path | None, device: torch.device) -> PageSegNet | None:
    if checkpoint is None:
        return None
    model = PageSegNet(pretrained=False).to(device)
    model.load_state_dict(load_checkpoint_state(checkpoint))
    model.eval()
    return model


def evaluate_checkpoint(
    checkpoint: str | Path | None,
    frames_dir: str | Path = "tmp/smartdoc15/frames",
    out_dir: str | Path = "tmp/docdet-v3/eval",
    report_out_dir: str | Path = "tmp/docdet-v3/report-overlays",
    report_root: str | Path = "report_server/reports",
    holdout_bg: str = "background05",
    limit: int = 1000,
    stride: int = 4,
    max_overlays: int = 36,
    report_limit: int = 80,
    device_name: str = "auto",
    baseline_mode: str = "capture",
) -> dict[str, dict[str, float]]:
    device = choose_device(device_name)
    checkpoint_path = Path(checkpoint) if checkpoint else None
    model = load_eval_model(checkpoint_path, device)
    _, val_records = load_smartdoc_records(frames_dir, holdout_bg=holdout_bg)
    metrics = evaluate_records(
        model,
        device,
        val_records,
        Path(out_dir),
        limit=limit,
        stride=stride,
        max_overlays=max_overlays,
        baseline_mode=baseline_mode,
    )
    report_count = generate_report_overlays(
        model,
        device,
        Path(report_root),
        Path(report_out_dir),
        limit=report_limit,
        baseline_mode=baseline_mode,
    )
    metrics["_meta"] = {
        "report_overlays": float(report_count),
        "val_records": float(len(val_records)),
        "device": str(device),
    }
    out_path = Path(out_dir)
    lines = []
    if "model" in metrics:
        lines.append(format_stats("model", metrics["model"]))
    if "fused" in metrics:
        lines.append(format_stats("fused", metrics["fused"]))
        lines.append(
            "fused_delta "
            f"improved_vs_baseline_005={int(metrics['fused']['improved_vs_baseline_005'])} "
            f"worsened_vs_baseline_005={int(metrics['fused']['worsened_vs_baseline_005'])} "
            f"model_selected={int(metrics['fused']['model_selected'])} "
            f"opencv_model_agreed_selected={int(metrics['fused']['opencv_model_agreed_selected'])} "
            f"opencv_edge_supported_selected={int(metrics['fused']['opencv_edge_supported_selected'])} "
            f"model_edge_rejected={int(metrics['fused']['model_edge_rejected'])}",
        )
    lines.append(format_stats("baseline", metrics["baseline"]))
    lines.append(f"report_overlays={report_count}")
    (out_path / "metrics.txt").write_text("\n".join(lines) + "\n")
    (out_path / "metrics.json").write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    return metrics


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate document detector against SmartDoc holdout and app OpenCV baseline.")
    parser.add_argument("--checkpoint", default=None, help="Model checkpoint. Omit with --baseline-only.")
    parser.add_argument("--baseline-only", action="store_true", help="Skip model loading and only evaluate the OpenCV baseline.")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--out-dir", default="tmp/docdet-v3/eval")
    parser.add_argument("--report-out-dir", default="tmp/docdet-v3/report-overlays")
    parser.add_argument("--report-root", default="report_server/reports")
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--stride", type=int, default=4)
    parser.add_argument("--max-overlays", type=int, default=36)
    parser.add_argument("--report-limit", type=int, default=80)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--baseline-mode", choices=("capture", "preview"), default="capture")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    checkpoint = None if args.baseline_only else args.checkpoint
    if checkpoint is None and not args.baseline_only:
        raise SystemExit("--checkpoint is required unless --baseline-only is set")
    metrics = evaluate_checkpoint(
        checkpoint,
        frames_dir=args.frames_dir,
        out_dir=args.out_dir,
        report_out_dir=args.report_out_dir,
        report_root=args.report_root,
        holdout_bg=args.holdout_bg,
        limit=args.limit,
        stride=args.stride,
        max_overlays=args.max_overlays,
        report_limit=args.report_limit,
        device_name=args.device,
        baseline_mode=args.baseline_mode,
    )
    if "model" in metrics:
        print(format_stats("model", metrics["model"]))
    if "fused" in metrics:
        print(format_stats("fused", metrics["fused"]))
        print(
            "fused_delta "
            f"improved_vs_baseline_005={int(metrics['fused']['improved_vs_baseline_005'])} "
            f"worsened_vs_baseline_005={int(metrics['fused']['worsened_vs_baseline_005'])} "
            f"model_selected={int(metrics['fused']['model_selected'])} "
            f"opencv_model_agreed_selected={int(metrics['fused']['opencv_model_agreed_selected'])} "
            f"opencv_edge_supported_selected={int(metrics['fused']['opencv_edge_supported_selected'])} "
            f"model_edge_rejected={int(metrics['fused']['model_edge_rejected'])}",
        )
    print(format_stats("baseline", metrics["baseline"]))
    print(f"report overlays: {int(metrics['_meta']['report_overlays'])}")


if __name__ == "__main__":
    main()
