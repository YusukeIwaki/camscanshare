#!/usr/bin/env python3
"""Generate filter sample images for sharpen / bw / whiteboard / vivid filters.

Reads Step 0 (cropped) images produced by generate_step0_samples.py
and applies each simple filter using ColorMatrix-equivalent operations
that match the Android app's ImageFilter.kt / ImageProcessor.kt.

Usage:
    python scripts/generate_simple_filter_samples.py
    python scripts/generate_simple_filter_samples.py --only angled --only flat
    python scripts/generate_simple_filter_samples.py --filter sharpen --filter bw
"""

from __future__ import annotations

import argparse
from filter_asset_pipeline import (
    FILTERS,
    apply_filter,
    load_manifest_entries,
    read_image,
    repo_root_for,
    write_image,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate simple filter sample images from Step 0 crops.",
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
    parser.add_argument(
        "--filter",
        action="append",
        default=[],
        help="Only generate specific filters (sharpen/bw/whiteboard/vivid).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_root = repo_root_for(__file__)
    entries = load_manifest_entries(repo_root, args.manifest, args.only)

    selected_filters = set(args.filter) if args.filter else set(FILTERS.keys())

    for entry in entries:
        step0_path = (repo_root / entry["step0"]).resolve()
        try:
            step0 = read_image(step0_path)
        except RuntimeError:
            print(f'  SKIP {entry["id"]}: step0 not found at {step0_path}')
            continue

        for filter_key in sorted(selected_filters):
            out_rel = entry["filters"][filter_key]
            out_path = (repo_root / out_rel).resolve()

            result = apply_filter(step0, filter_key)
            write_image(out_path, result)

            print(f'  {entry["id"]}/{filter_key}: {result.shape[1]}x{result.shape[0]} -> {out_rel}')


if __name__ == "__main__":
    main()
