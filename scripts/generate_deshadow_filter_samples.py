#!/usr/bin/env python3
"""Generate docs filter sample images for the 影除去 (deshadow) neural filter.

Reads Step 1 (aspect-normalized) images and applies the GCDRNet-based
deshadow pipeline defined in deshadow_pipeline.py, which shares the fp16
ONNX models committed under androidapp assets with the mobile apps.

Requires onnxruntime (available in the repository .venv).

Usage:
    .venv/bin/python scripts/generate_deshadow_filter_samples.py
    .venv/bin/python scripts/generate_deshadow_filter_samples.py --only angled
"""

from __future__ import annotations

import argparse

from deshadow_pipeline import apply_deshadow_filter
from filter_asset_pipeline import (
    load_manifest_entries,
    read_image,
    repo_root_for,
    resolve_filter_output_path,
    write_image,
)

FILTER_KEY = "deshadow"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate deshadow filter sample images from Step 1 normalized crops.",
    )
    parser.add_argument(
        "--manifest",
        default="docs/filter-samples.json",
        help="JSON manifest with sample definitions.",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="Only process specific sample ids. Can be passed multiple times.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_root = repo_root_for(__file__)
    entries = load_manifest_entries(repo_root, args.manifest, args.only)

    for entry in entries:
        step1_path = (repo_root / entry["step1"]).resolve()
        try:
            step1 = read_image(step1_path)
        except RuntimeError:
            print(f'  SKIP {entry["id"]}: step1 not found at {step1_path}')
            continue

        out_rel = resolve_filter_output_path(entry, FILTER_KEY)
        out_path = (repo_root / out_rel).resolve()

        result = apply_deshadow_filter(step1)
        write_image(out_path, result)

        print(f'  {entry["id"]}/{FILTER_KEY}: {result.shape[1]}x{result.shape[0]} -> {out_rel}')


if __name__ == "__main__":
    main()
