from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np

from .geometry import denormalize_quad, draw_quad, order_quad, poly_iou, write_contact_sheet
from .opencv_baseline import detect_document_quad


REPO_ROOT = Path(__file__).resolve().parents[2]
VALID_DOCUMENT_STATES = {"unlabeled", "fully_visible", "partially_visible", "no_document"}


@dataclass(frozen=True)
class FinderEvalSample:
    id: str
    image: Path
    source: str
    split: str
    document_state: str
    corners: np.ndarray | None
    failure_tags: tuple[str, ...]
    metadata: dict[str, Any]


def _normalized_corners(value: Any, sample_id: str) -> np.ndarray | None:
    if value is None:
        return None
    corners = np.asarray(value, dtype=np.float32)
    if corners.shape != (4, 2):
        raise ValueError(f"{sample_id}: corners must be 4x2 normalized points")
    if not np.isfinite(corners).all():
        raise ValueError(f"{sample_id}: corners contain a non-finite value")
    if (corners < 0.0).any() or (corners > 1.0).any():
        raise ValueError(f"{sample_id}: corners must stay inside normalized image bounds")
    ordered = order_quad(corners)
    if abs(float(cv2.contourArea(ordered))) < 1e-5:
        raise ValueError(f"{sample_id}: corners do not form a usable quadrilateral")
    return ordered


def parse_sample(raw: dict[str, Any], manifest_path: Path) -> FinderEvalSample:
    sample_id = str(raw.get("id", "")).strip()
    if not sample_id:
        raise ValueError(f"{manifest_path}: sample id is required")
    state = str(raw.get("document_state", "unlabeled"))
    if state not in VALID_DOCUMENT_STATES:
        raise ValueError(f"{sample_id}: unsupported document_state {state!r}")
    corners = _normalized_corners(raw.get("corners"), sample_id)
    if state == "fully_visible" and corners is None:
        raise ValueError(f"{sample_id}: fully_visible samples require four corners")
    if state == "no_document" and corners is not None:
        raise ValueError(f"{sample_id}: no_document samples cannot have corners")

    image_value = str(raw.get("image", "")).strip()
    if not image_value:
        raise ValueError(f"{sample_id}: image path is required")
    image_path = (REPO_ROOT / image_value).resolve()
    try:
        image_path.relative_to(REPO_ROOT)
    except ValueError as exc:
        raise ValueError(f"{sample_id}: image must stay inside the repository") from exc

    known = {
        "id",
        "image",
        "source",
        "split",
        "document_state",
        "corners",
        "failure_tags",
    }
    metadata = {key: value for key, value in raw.items() if key not in known}
    return FinderEvalSample(
        id=sample_id,
        image=image_path,
        source=str(raw.get("source", "unknown")),
        split=str(raw.get("split", "test")),
        document_state=state,
        corners=corners,
        failure_tags=tuple(str(tag) for tag in raw.get("failure_tags", [])),
        metadata=metadata,
    )


def load_manifests(paths: Iterable[Path], require_images: bool = True) -> list[FinderEvalSample]:
    samples: list[FinderEvalSample] = []
    ids: set[str] = set()
    for path in paths:
        payload = json.loads(path.read_text())
        if payload.get("version") != 1:
            raise ValueError(f"{path}: version must be 1")
        if payload.get("coordinate_space") != "normalized_top_left":
            raise ValueError(f"{path}: coordinate_space must be normalized_top_left")
        for raw in payload.get("samples", []):
            sample = parse_sample(raw, path)
            if sample.id in ids:
                raise ValueError(f"duplicate sample id: {sample.id}")
            if require_images and not sample.image.is_file():
                raise FileNotFoundError(f"{sample.id}: image not found: {sample.image}")
            ids.add(sample.id)
            samples.append(sample)
    return samples


def normalized_corner_errors(
    predicted: np.ndarray | None,
    expected: np.ndarray,
    width: int,
    height: int,
) -> np.ndarray:
    if predicted is None:
        return np.ones(4, dtype=np.float32)
    predicted_px = denormalize_quad(predicted, width, height)
    expected_px = denormalize_quad(expected, width, height)
    diagonal = max(1.0, math.hypot(width, height))
    return np.linalg.norm(predicted_px - expected_px, axis=1) / diagonal


def _percentile(values: list[float], percentile: float) -> float | None:
    return float(np.percentile(np.asarray(values, dtype=np.float32), percentile)) if values else None


def _metric_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    full_rows = [row for row in rows if row["document_state"] == "fully_visible"]
    no_document_rows = [row for row in rows if row["document_state"] == "no_document"]
    partial_rows = [row for row in rows if row["document_state"] == "partially_visible"]
    ious = [float(row["iou"]) for row in full_rows]
    mean_corner_errors = [float(row["mean_corner_error"]) for row in full_rows]
    max_corner_errors = [float(row["max_corner_error"]) for row in full_rows]
    detected_full = sum(bool(row["detected"]) for row in full_rows)
    false_positive_no_document = sum(bool(row["detected"]) for row in no_document_rows)
    detected_partial = sum(bool(row["detected"]) for row in partial_rows)
    return {
        "samples_evaluated": len(rows),
        "fully_visible": len(full_rows),
        "partially_visible": len(partial_rows),
        "no_document": len(no_document_rows),
        "fully_visible_recall": detected_full / len(full_rows) if full_rows else None,
        "no_document_false_positive_rate": (
            false_positive_no_document / len(no_document_rows) if no_document_rows else None
        ),
        "partial_candidate_rate": detected_partial / len(partial_rows) if partial_rows else None,
        "iou": {
            "mean": float(np.mean(ious)) if ious else None,
            "p50": _percentile(ious, 50),
            "p05": _percentile(ious, 5),
            "pass_080": sum(value >= 0.80 for value in ious) / len(ious) if ious else None,
            "pass_090": sum(value >= 0.90 for value in ious) / len(ious) if ious else None,
            "pass_095": sum(value >= 0.95 for value in ious) / len(ious) if ious else None,
        },
        "mean_corner_error_by_image_diagonal": {
            "mean": float(np.mean(mean_corner_errors)) if mean_corner_errors else None,
            "p50": _percentile(mean_corner_errors, 50),
            "p90": _percentile(mean_corner_errors, 90),
            "p95": _percentile(mean_corner_errors, 95),
            "p99": _percentile(mean_corner_errors, 99),
        },
        "max_corner_error_by_image_diagonal": {
            "mean": float(np.mean(max_corner_errors)) if max_corner_errors else None,
            "p95": _percentile(max_corner_errors, 95),
        },
    }


def evaluate_opencv_preview(
    samples: list[FinderEvalSample],
    out_dir: Path,
    split: str | None = "test",
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    overlays: list[np.ndarray] = []
    labels: list[str] = []

    for sample in samples:
        if sample.document_state == "unlabeled" or (split and sample.split != split):
            continue
        bgr = cv2.imread(str(sample.image))
        if bgr is None:
            raise RuntimeError(f"failed to read {sample.image}")
        height, width = bgr.shape[:2]
        predicted, detector_meta = detect_document_quad(bgr, "preview", normalized=True)
        detected = predicted is not None
        row: dict[str, Any] = {
            "id": sample.id,
            "image": str(sample.image.relative_to(REPO_ROOT)),
            "source": sample.source,
            "split": sample.split,
            "document_state": sample.document_state,
            "failure_tags": list(sample.failure_tags),
            "detected": detected,
            "detector_source": str(detector_meta.get("source", "none")),
            "detector_kind": str(detector_meta.get("kind", "none")),
            "detector_score": detector_meta.get("score"),
        }
        if sample.document_state == "fully_visible" and sample.corners is not None:
            errors = normalized_corner_errors(predicted, sample.corners, width, height)
            row.update(
                {
                    "iou": poly_iou(predicted, sample.corners, size=640),
                    "corner_errors": [float(value) for value in errors],
                    "mean_corner_error": float(errors.mean()),
                    "max_corner_error": float(errors.max()),
                }
            )
        overlay = draw_quad(bgr, sample.corners, (0, 190, 0), "GT", normalized=True, thickness=4)
        overlay = draw_quad(overlay, predicted, (0, 0, 255), "OpenCV preview", normalized=True, thickness=3)
        label = sample.id
        if "iou" in row:
            label += f" IoU={row['iou']:.3f} corner={row['mean_corner_error']:.4f}"
        cv2.imwrite(str(out_dir / f"{sample.id}.jpg"), overlay)
        overlays.append(overlay)
        labels.append(label)
        rows.append(row)

    summary = {
        "detector": "opencv_preview",
        "split": split,
        "metrics": _metric_summary(rows),
        "rows": rows,
    }
    (out_dir / "metrics.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    write_contact_sheet(
        overlays,
        out_dir / "contact_sheet.jpg",
        labels,
        cols=2,
        cell_width=640,
        cell_height=520,
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate finder paper detection on manually labeled images")
    parser.add_argument(
        "--manifest",
        action="append",
        default=None,
        help="Manifest path. May be repeated; defaults to docs/document-detection-eval.json.",
    )
    parser.add_argument("--out-dir", default="tmp/document-detection-eval/opencv-preview")
    parser.add_argument("--split", default="test", help="Split to evaluate; use 'all' for every split")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    manifests = [Path(value) for value in args.manifest] if args.manifest else [Path("docs/document-detection-eval.json")]
    samples = load_manifests(manifests)
    print(f"validated {len(samples)} samples from {len(manifests)} manifest(s)")
    if args.validate_only:
        return
    summary = evaluate_opencv_preview(
        samples,
        Path(args.out_dir),
        split=None if args.split == "all" else args.split,
    )
    print(json.dumps(summary["metrics"], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
