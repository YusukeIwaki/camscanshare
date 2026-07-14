from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from .geometry import draw_quad, normalize_quad, write_contact_sheet
from .smartdoc import load_smartdoc_records, validate_record_coordinate_space


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render SmartDoc GT quad overlays for coordinate sanity checks.")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--out-dir", default="tmp/docdet-v3/sanity")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--split", choices=("val", "train", "all"), default="val")
    parser.add_argument("--count", type=int, default=48)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    train, val = load_smartdoc_records(args.frames_dir, holdout_bg=args.holdout_bg)
    if args.split == "train":
        records = train
    elif args.split == "all":
        records = train + val
    else:
        records = val
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if not records:
        raise SystemExit("no SmartDoc records found")

    indices = np.linspace(0, len(records) - 1, min(args.count, len(records)), dtype=int)
    contact_images: list[np.ndarray] = []
    labels: list[str] = []
    for output_index, record_index in enumerate(indices):
        record = records[int(record_index)]
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            continue
        h, w = bgr.shape[:2]
        gt = normalize_quad(record.quad, w, h)
        label = f"{record.scene_id}/f{record.frame_index} {w}x{h}"
        overlay = draw_quad(bgr, gt, (0, 220, 0), label, normalized=True)
        out_path = out_dir / f"gt_{output_index:03d}_{record.bg_name}_{record.model_name}_f{record.frame_index:04d}.jpg"
        cv2.imwrite(str(out_path), overlay)
        contact_images.append(overlay)
        labels.append(label)

    write_contact_sheet(contact_images, out_dir / "gt_contact_sheet.jpg", labels, cols=3)
    stats = validate_record_coordinate_space(records)
    stats["records_in_split"] = len(records)
    stats["rendered"] = len(contact_images)
    (out_dir / "summary.json").write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(contact_images)} overlays to {out_dir}")
    print(json.dumps(stats, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

