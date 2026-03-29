#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from filter_asset_pipeline import (
    apply_magic_pipeline,
    load_manifest_entries,
    read_image,
    repo_root_for,
    write_image,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Magic filter Step 1/2 assets from existing Step 0 crops.",
    )
    parser.add_argument(
        "--manifest",
        default="docs/magic-filter-samples.json",
        help="JSON manifest with source/step0/step1/step2 paths.",
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
        step0_path = (repo_root / entry["step0"]).resolve()
        step1_path = (repo_root / entry["step1"]).resolve()
        step2_path = (repo_root / entry["step2"]).resolve()

        step0 = read_image(step0_path)
        step1, step2 = apply_magic_pipeline(step0)

        write_image(step1_path, step1)
        write_image(step2_path, step2)

        print(
            f'{entry["id"]}: magic '
            f'step0={step0.shape[1]}x{step0.shape[0]} '
            f'step1={step1.shape[1]}x{step1.shape[0]} '
            f'step2={step2.shape[1]}x{step2.shape[0]}'
        )


if __name__ == "__main__":
    main()
