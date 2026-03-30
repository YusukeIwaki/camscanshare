#!/usr/bin/env python3

from __future__ import annotations

import argparse

from filter_asset_pipeline import (
    detect_document,
    load_manifest_entries,
    read_image,
    repo_root_for,
    write_image,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Step 0 perspective-corrected crops for docs samples.",
    )
    parser.add_argument(
        "--manifest",
        default="docs/filter-samples.json",
        help="JSON manifest with source/step0 paths.",
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
        source = (repo_root / entry["source"]).resolve()
        step0_path = (repo_root / entry["step0"]).resolve()

        image = read_image(source)
        step0, mode = detect_document(image, entry.get("crop_mode"))
        write_image(step0_path, step0)

        print(
            f'{entry["id"]}: {mode} '
            f'original={image.shape[1]}x{image.shape[0]} '
            f'step0={step0.shape[1]}x{step0.shape[0]}'
        )


if __name__ == "__main__":
    main()
