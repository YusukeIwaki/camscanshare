from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from .boundary_fusion import (
    BoundaryEdgeEvidence,
    build_edge_support_map,
    choose_boundary_fusion,
    measure_quad_edge_evidence,
)
from .evaluate import choose_device, load_eval_model, model_detect_info
from .geometry import draw_quad, order_quad, poly_iou, write_contact_sheet
from .opencv_baseline import detect_document_quad


DEFAULT_REPORTS = (
    "report-2026-07-12_17-51-57",
    "report-2026-07-12_17-54-30",
    "report-2026-07-14_08-58-09",
    "report-2026-07-14_08-59-11",
)


def _edge_json(evidence: BoundaryEdgeEvidence) -> dict[str, Any]:
    return {
        "sides": [float(value) for value in evidence.sides],
        "average": evidence.average,
        "minimum": evidence.minimum,
    }


def _load_old_selected_quad(session_dir: Path) -> np.ndarray | None:
    path = session_dir / "selected_quad.json"
    if not path.exists():
        return None
    corners = json.loads(path.read_text()).get("corners") or []
    if len(corners) != 4:
        return None
    # iOS stores normalized CI coordinates with a bottom-left origin. The
    # Python detector and OpenCV images use a top-left origin.
    points = np.array(
        [[float(point["x"]), 1.0 - float(point["y"])] for point in corners],
        dtype=np.float32,
    )
    return order_quad(points)


def _find_session(report_root: Path, report_id: str) -> tuple[Path, Path]:
    matches = sorted(glob.glob(str(report_root / report_id / "debug" / "*" / "02_input.png")))
    if not matches:
        raise FileNotFoundError(f"raw document-detection input not found for {report_id}")
    input_path = Path(matches[-1])
    return input_path.parent, input_path


def _overlay(
    bgr: np.ndarray,
    old_quad: np.ndarray | None,
    baseline_quad: np.ndarray | None,
    model_quad: np.ndarray | None,
    new_quad: np.ndarray | None,
    label: str,
) -> np.ndarray:
    # old=red, PageSeg=blue, OpenCV=yellow, selected new=green
    out = draw_quad(bgr, old_quad, (0, 0, 255), normalized=True)
    out = draw_quad(out, model_quad, (255, 128, 0), normalized=True)
    out = draw_quad(out, baseline_quad, (0, 220, 255), normalized=True)
    out = draw_quad(out, new_quad, (0, 200, 0), normalized=True, thickness=5)
    cv2.rectangle(out, (0, out.shape[0] - 44), (out.shape[1], out.shape[0]), (255, 255, 255), -1)
    cv2.putText(
        out,
        label,
        (12, out.shape[0] - 15),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.72,
        (25, 25, 25),
        2,
        cv2.LINE_AA,
    )
    return out


def evaluate_report_regressions(
    checkpoint: Path,
    report_root: Path,
    report_ids: list[str],
    out_dir: Path,
    device_name: str,
) -> dict[str, Any]:
    device = choose_device(device_name)
    model = load_eval_model(checkpoint, device)
    if model is None:
        raise RuntimeError("PageSeg checkpoint is required")

    out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    contact_images: list[np.ndarray] = []
    contact_labels: list[str] = []

    for report_id in report_ids:
        session_dir, input_path = _find_session(report_root, report_id)
        bgr = cv2.imread(str(input_path))
        if bgr is None:
            raise RuntimeError(f"failed to read {input_path}")

        old_quad = _load_old_selected_quad(session_dir)
        baseline_quad, baseline_meta = detect_document_quad(bgr, "capture", normalized=True)
        model_info, _ = model_detect_info(model, device, bgr)
        decision = choose_boundary_fusion(bgr, baseline_quad, model_info.quad)

        edge_support_map = build_edge_support_map(bgr)
        old_evidence = measure_quad_edge_evidence(edge_support_map, old_quad)
        new_evidence = measure_quad_edge_evidence(edge_support_map, decision.quad)
        minimum_gain = new_evidence.minimum - old_evidence.minimum
        evidence_improved = minimum_gain >= 0.05 and new_evidence.minimum >= 0.20
        label = (
            f"{report_id} {decision.source} "
            f"weakest edge {old_evidence.minimum:.3f}->{new_evidence.minimum:.3f}"
        )
        overlay = _overlay(
            bgr,
            old_quad,
            baseline_quad,
            model_info.quad,
            decision.quad,
            label,
        )
        cv2.imwrite(str(out_dir / f"{report_id}.jpg"), overlay)
        contact_images.append(overlay)
        contact_labels.append(label)

        rows.append(
            {
                "report_id": report_id,
                "input_path": str(input_path),
                "old_vs_new_iou": poly_iou(old_quad, decision.quad),
                "model_vs_opencv_iou": poly_iou(model_info.quad, baseline_quad),
                "old_edge_evidence": _edge_json(old_evidence),
                "new_edge_evidence": _edge_json(new_evidence),
                "minimum_edge_gain": minimum_gain,
                "edge_evidence_improved": evidence_improved,
                "new_source": decision.source,
                "opencv_source": str(baseline_meta.get("source", "none")),
                "opencv_kind": str(baseline_meta.get("kind", "none")),
            },
        )

    write_contact_sheet(
        contact_images,
        out_dir / "report_regression_contact_sheet.jpg",
        contact_labels,
        cols=2,
        cell_width=620,
        cell_height=820,
    )
    summary = {
        "checkpoint": str(checkpoint),
        "reports_total": len(rows),
        "reports_edge_evidence_improved": sum(bool(row["edge_evidence_improved"]) for row in rows),
        "all_reports_edge_evidence_improved": all(bool(row["edge_evidence_improved"]) for row in rows),
        "rows": rows,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate raw document-boundary report regressions")
    parser.add_argument("--checkpoint", default="tmp/docdet-v3/best.pt")
    parser.add_argument("--report-root", default="report_server/reports")
    parser.add_argument("--out-dir", default="tmp/docdet-v5/report-regressions")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--reports", nargs="*", default=list(DEFAULT_REPORTS))
    args = parser.parse_args()
    summary = evaluate_report_regressions(
        checkpoint=Path(args.checkpoint),
        report_root=Path(args.report_root),
        report_ids=list(args.reports),
        out_dir=Path(args.out_dir),
        device_name=args.device,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
