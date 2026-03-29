#!/usr/bin/env python3
"""Generate filter sample images for sharpen / bw / whiteboard / vivid filters.

Reads Step 0 (cropped) images produced by generate_magic_filter_steps.py
and applies each simple filter using ColorMatrix-equivalent operations
that match the Android app's ImageFilter.kt / ImageProcessor.kt.

Usage:
    python scripts/generate_simple_filter_samples.py
    python scripts/generate_simple_filter_samples.py --only angled --only flat
    python scripts/generate_simple_filter_samples.py --filter sharpen --filter bw
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


FILTERS = {
    "sharpen": {
        # contrast(1.4) brightness(1.05)
        "ops": [("contrast", 1.4), ("brightness", 1.05)],
    },
    "bw": {
        # grayscale(1) contrast(1.3)
        "ops": [("grayscale", 1.0), ("contrast", 1.3)],
    },
    "whiteboard": {
        # brightness(1.3) contrast(1.6) saturate(0)
        "ops": [("brightness", 1.3), ("contrast", 1.6), ("saturate", 0.0)],
    },
    "vivid": {
        # saturate(2) contrast(1.2)
        "ops": [("saturate", 2.0), ("contrast", 1.2)],
    },
}


def apply_brightness(image: np.ndarray, value: float) -> np.ndarray:
    """Matches Android brightnessMatrix: offset = 255 * (value - 1)."""
    offset = 255.0 * (value - 1.0)
    result = image.astype(np.float32) + offset
    return np.clip(result, 0, 255).astype(np.uint8)


def apply_contrast(image: np.ndarray, value: float) -> np.ndarray:
    """Matches Android contrastMatrix: pixel * value + 128 * (1 - value)."""
    offset = 128.0 * (1.0 - value)
    result = image.astype(np.float32) * value + offset
    return np.clip(result, 0, 255).astype(np.uint8)


def apply_grayscale(image: np.ndarray, _value: float) -> np.ndarray:
    """Convert to grayscale using standard luminance weights (BT.601).

    Android's ColorMatrix.setSaturation(0) uses:
      R_weight = 0.2127, G_weight = 0.7151, B_weight = 0.0722
    OpenCV uses BGR order.
    """
    b, g, r = cv2.split(image)
    gray = (
        r.astype(np.float32) * 0.2127
        + g.astype(np.float32) * 0.7151
        + b.astype(np.float32) * 0.0722
    )
    gray = np.clip(gray, 0, 255).astype(np.uint8)
    return cv2.merge([gray, gray, gray])


def apply_saturate(image: np.ndarray, value: float) -> np.ndarray:
    """Matches Android saturationMatrix.

    setSaturation(s) builds a matrix that blends between grayscale (s=0)
    and original (s=1), or boosts beyond original (s>1).
    Uses BT.601 luminance weights: R=0.2127, G=0.7151, B=0.0722.
    """
    if value == 0.0:
        return apply_grayscale(image, 1.0)

    rw, gw, bw = 0.2127, 0.7151, 0.0722
    b_ch, g_ch, r_ch = (
        image[:, :, 0].astype(np.float32),
        image[:, :, 1].astype(np.float32),
        image[:, :, 2].astype(np.float32),
    )

    # The saturation matrix for each output channel:
    # out_R = (rw*(1-s) + s)*R + gw*(1-s)*G + bw*(1-s)*B
    # out_G = rw*(1-s)*R + (gw*(1-s)+s)*G + bw*(1-s)*B
    # out_B = rw*(1-s)*R + gw*(1-s)*G + (bw*(1-s)+s)*B
    inv = 1.0 - value
    out_r = (rw * inv + value) * r_ch + gw * inv * g_ch + bw * inv * b_ch
    out_g = rw * inv * r_ch + (gw * inv + value) * g_ch + bw * inv * b_ch
    out_b = rw * inv * r_ch + gw * inv * g_ch + (bw * inv + value) * b_ch

    out_r = np.clip(out_r, 0, 255).astype(np.uint8)
    out_g = np.clip(out_g, 0, 255).astype(np.uint8)
    out_b = np.clip(out_b, 0, 255).astype(np.uint8)
    return cv2.merge([out_b, out_g, out_r])


OP_DISPATCH = {
    "brightness": apply_brightness,
    "contrast": apply_contrast,
    "grayscale": apply_grayscale,
    "saturate": apply_saturate,
}


def apply_filter(image: np.ndarray, filter_key: str) -> np.ndarray:
    """Apply a named filter to a BGR image."""
    spec = FILTERS[filter_key]
    result = image.copy()
    for op_name, op_value in spec["ops"]:
        result = OP_DISPATCH[op_name](result, op_value)
    return result


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
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = (repo_root / args.manifest).resolve()
    entries = json.loads(manifest_path.read_text())

    selected_ids = set(args.only)
    if selected_ids:
        entries = [entry for entry in entries if entry["id"] in selected_ids]

    selected_filters = set(args.filter) if args.filter else set(FILTERS.keys())

    for entry in entries:
        step0_path = (repo_root / entry["step0"]).resolve()
        step0 = cv2.imread(str(step0_path))
        if step0 is None:
            print(f'  SKIP {entry["id"]}: step0 not found at {step0_path}')
            continue

        for filter_key in sorted(selected_filters):
            out_rel = entry["filters"][filter_key]
            out_path = (repo_root / out_rel).resolve()
            out_path.parent.mkdir(parents=True, exist_ok=True)

            result = apply_filter(step0, filter_key)
            ok = cv2.imwrite(str(out_path), result)
            if not ok:
                raise RuntimeError(f"Failed to write: {out_path}")

            print(f'  {entry["id"]}/{filter_key}: {result.shape[1]}x{result.shape[0]} -> {out_rel}')


if __name__ == "__main__":
    main()
