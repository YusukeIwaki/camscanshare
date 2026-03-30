#!/usr/bin/env python3

from __future__ import annotations

import argparse

from filter_asset_pipeline import (
    estimate_document_paper_ratio,
    load_manifest_entries,
    normalize_document_aspect,
    read_image,
    repo_root_for,
    write_image,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Step 1 aspect-normalized assets from existing Step 0 crops.",
    )
    parser.add_argument(
        "--manifest",
        default="docs/filter-samples.json",
        help="JSON manifest with step0/step1 paths.",
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
        source_path = (repo_root / entry["source"]).resolve()
        step0_path = (repo_root / entry["step0"]).resolve()
        step1_path = (repo_root / entry["step1"]).resolve()

        source = read_image(source_path)
        step0 = read_image(step0_path)
        target_ratio = estimate_document_paper_ratio(source, entry.get("crop_mode"))
        step1, mode = normalize_document_aspect(step0, target_ratio=target_ratio)
        write_image(step1_path, step1)

        print(
            f'{entry["id"]}: {mode} '
            f'step0={step0.shape[1]}x{step0.shape[0]} '
            f'step1={step1.shape[1]}x{step1.shape[0]}'
        )


if __name__ == "__main__":
    main()
