#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Original/Step0/Step1/Step2 assets for docs samples.",
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


def order_points(points: np.ndarray) -> np.ndarray:
    rect = np.zeros((4, 2), dtype=np.float32)
    sums = points.sum(axis=1)
    rect[0] = points[np.argmin(sums)]
    rect[2] = points[np.argmax(sums)]
    diffs = np.diff(points, axis=1)
    rect[1] = points[np.argmin(diffs)]
    rect[3] = points[np.argmax(diffs)]
    return rect


def four_point_transform(image: np.ndarray, points: np.ndarray) -> np.ndarray:
    rect = order_points(points.reshape(4, 2).astype(np.float32))
    top_left, top_right, bottom_right, bottom_left = rect

    width_a = np.linalg.norm(bottom_right - bottom_left)
    width_b = np.linalg.norm(top_right - top_left)
    height_a = np.linalg.norm(top_right - bottom_right)
    height_b = np.linalg.norm(top_left - bottom_left)

    max_width = max(int(round(width_a)), int(round(width_b)))
    max_height = max(int(round(height_a)), int(round(height_b)))

    destination = np.array(
        [
            [0, 0],
            [max_width - 1, 0],
            [max_width - 1, max_height - 1],
            [0, max_height - 1],
        ],
        dtype=np.float32,
    )
    matrix = cv2.getPerspectiveTransform(rect, destination)
    return cv2.warpPerspective(image, matrix, (max_width, max_height))


def detect_document(image: np.ndarray) -> tuple[np.ndarray, str]:
    original = image.copy()
    height, width = image.shape[:2]
    scale = 500.0 / float(height) if height > 500 else 1.0
    if scale != 1.0:
        resized = cv2.resize(
            image,
            (int(round(width * scale)), int(round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        resized = image.copy()

    ratio = height / float(resized.shape[0])
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)

    edges = cv2.Canny(blurred, 50, 150)
    edges = cv2.dilate(edges, np.ones((3, 3), dtype=np.uint8), iterations=1)
    edges = cv2.morphologyEx(
        edges,
        cv2.MORPH_CLOSE,
        np.ones((5, 5), dtype=np.uint8),
        iterations=2,
    )

    adaptive = cv2.adaptiveThreshold(
        blurred,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY,
        31,
        15,
    )
    adaptive = 255 - adaptive
    adaptive = cv2.morphologyEx(
        adaptive,
        cv2.MORPH_CLOSE,
        np.ones((5, 5), dtype=np.uint8),
        iterations=2,
    )

    merged = cv2.bitwise_or(edges, adaptive)
    contours, _ = cv2.findContours(merged, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    min_area = resized.shape[0] * resized.shape[1] * 0.15

    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:30]:
        area = cv2.contourArea(contour)
        if area < min_area:
            continue
        perimeter = cv2.arcLength(contour, True)
        polygon = cv2.approxPolyDP(contour, 0.02 * perimeter, True)
        if len(polygon) == 4 and cv2.isContourConvex(polygon):
            points = polygon.reshape(4, 2).astype(np.float32) * ratio
            return four_point_transform(original, points), "quad"

    fallback = max(contours, key=cv2.contourArea)
    rect = cv2.minAreaRect(fallback)
    points = cv2.boxPoints(rect).astype(np.float32) * ratio
    return four_point_transform(original, points), "minAreaRect"


def estimate_illumination(luminance: np.ndarray) -> np.ndarray:
    height, width = luminance.shape[:2]
    min_side = min(width, height)
    scale = 1024.0 / float(min_side) if min_side > 1024 else 1.0

    if scale < 1.0:
        working = cv2.resize(
            luminance,
            (int(round(width * scale)), int(round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        working = luminance.copy()

    sigma = max(12.0, min(80.0, min(working.shape[1], working.shape[0]) / 18.0))
    blurred = cv2.GaussianBlur(working, (0, 0), sigmaX=sigma, sigmaY=sigma)

    if scale < 1.0:
        return cv2.resize(blurred, (width, height), interpolation=cv2.INTER_CUBIC)
    return blurred


def flat_field_correct(luminance: np.ndarray, illumination: np.ndarray) -> np.ndarray:
    luminance32 = luminance.astype(np.float32) + 1.0
    illumination32 = illumination.astype(np.float32) + 1.0
    corrected = luminance32 / illumination32 * float(illumination.mean())
    return np.clip(corrected, 0, 255).astype(np.uint8)


def find_percentile(histogram: np.ndarray, total_pixels: int, percentile: float) -> int:
    target = max(0, min(total_pixels - 1, int(total_pixels * percentile)))
    cumulative = 0
    for value, count in enumerate(histogram):
        cumulative += int(count)
        if cumulative > target:
            return value
    return 255


def auto_stretch_luminance(luminance: np.ndarray) -> np.ndarray:
    histogram = cv2.calcHist([luminance], [0], None, [256], [0, 256]).flatten()
    total_pixels = int(luminance.shape[0] * luminance.shape[1])
    black_point = find_percentile(histogram, total_pixels, 0.02)
    white_point = max(black_point + 1, find_percentile(histogram, total_pixels, 0.985))

    clipped = np.minimum(luminance, white_point).astype(np.float32)
    stretched = (clipped - float(black_point)) * (255.0 / float(white_point - black_point))
    return np.clip(stretched, 0, 255).astype(np.uint8)


def compute_chroma(a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    a32 = a_channel.astype(np.float32) - 128.0
    b32 = b_channel.astype(np.float32) - 128.0
    chroma = np.sqrt(a32 * a32 + b32 * b32)
    return np.clip(chroma, 0, 255).astype(np.uint8)


def build_paper_mask(luminance: np.ndarray, a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    chroma = compute_chroma(a_channel, b_channel)
    _, bright_mask = cv2.threshold(luminance, 170, 255, cv2.THRESH_BINARY)
    _, low_chroma_mask = cv2.threshold(chroma, 20, 255, cv2.THRESH_BINARY_INV)
    paper_mask = cv2.bitwise_and(bright_mask, low_chroma_mask)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_OPEN, kernel)
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_CLOSE, kernel)
    return paper_mask


def build_accent_mask(luminance: np.ndarray, a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    chroma = compute_chroma(a_channel, b_channel)
    _, strong_chroma_mask = cv2.threshold(chroma, 28, 255, cv2.THRESH_BINARY)
    _, visible_mask = cv2.threshold(luminance, 48, 255, cv2.THRESH_BINARY)
    accent_mask = cv2.bitwise_and(strong_chroma_mask, visible_mask)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    return cv2.morphologyEx(accent_mask, cv2.MORPH_OPEN, kernel)


def compress_chroma(channel: np.ndarray, factor: float) -> np.ndarray:
    channel32 = channel.astype(np.float32)
    compressed = (channel32 - 128.0) * factor + 128.0
    return np.clip(compressed, 0, 255).astype(np.uint8)


def blend_toward_value(channel: np.ndarray, mask: np.ndarray, target: float, strength: float) -> np.ndarray:
    channel32 = channel.astype(np.float32)
    mask32 = mask.astype(np.float32) * (strength / 255.0)
    inverse = 1.0 - mask32
    blended = channel32 * inverse + target * mask32
    return np.clip(blended, 0, 255).astype(np.uint8)


def apply_magic_pipeline(cropped: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    rgb = cv2.cvtColor(cropped, cv2.COLOR_BGR2RGB)
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)
    luminance, a_channel, b_channel = cv2.split(lab)

    illumination = estimate_illumination(luminance)
    flattened_l = flat_field_correct(luminance, illumination)
    step1_lab = cv2.merge([flattened_l, a_channel, b_channel])
    step1_rgb = cv2.cvtColor(step1_lab, cv2.COLOR_LAB2RGB)
    step1_bgr = cv2.cvtColor(step1_rgb, cv2.COLOR_RGB2BGR)

    stretched_l = auto_stretch_luminance(flattened_l)
    denoised_l = cv2.medianBlur(stretched_l, 3)
    paper_mask = build_paper_mask(denoised_l, a_channel, b_channel)
    accent_mask = build_accent_mask(denoised_l, a_channel, b_channel)

    if int(cv2.countNonZero(paper_mask)) > 0:
        mean_a = float(cv2.mean(a_channel, mask=paper_mask)[0])
        mean_b = float(cv2.mean(b_channel, mask=paper_mask)[0])
    else:
        mean_a = 128.0
        mean_b = 128.0

    neutralized_a = np.clip(a_channel.astype(np.float32) - (mean_a - 128.0), 0, 255).astype(np.uint8)
    neutralized_b = np.clip(b_channel.astype(np.float32) - (mean_b - 128.0), 0, 255).astype(np.uint8)

    muted_a = compress_chroma(neutralized_a, 0.18)
    muted_b = compress_chroma(neutralized_b, 0.18)
    accent_a = compress_chroma(neutralized_a, 0.85)
    accent_b = compress_chroma(neutralized_b, 0.85)

    output_l = blend_toward_value(denoised_l, paper_mask, 255.0, 0.82)
    output_a = muted_a.copy()
    output_b = muted_b.copy()
    output_a[accent_mask > 0] = accent_a[accent_mask > 0]
    output_b[accent_mask > 0] = accent_b[accent_mask > 0]
    output_a[paper_mask > 0] = 128
    output_b[paper_mask > 0] = 128

    final_lab = cv2.merge([output_l, output_a, output_b])
    final_rgb = cv2.cvtColor(final_lab, cv2.COLOR_LAB2RGB)
    final_bgr = cv2.cvtColor(final_rgb, cv2.COLOR_RGB2BGR)
    return step1_bgr, final_bgr


def write_image(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok = cv2.imwrite(str(path), image)
    if not ok:
        raise RuntimeError(f"Failed to write image: {path}")


def main() -> None:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = (repo_root / args.manifest).resolve()
    entries = json.loads(manifest_path.read_text())

    selected_ids = set(args.only)
    if selected_ids:
        entries = [entry for entry in entries if entry["id"] in selected_ids]

    for entry in entries:
        source = (repo_root / entry["source"]).resolve()
        step0_path = (repo_root / entry["step0"]).resolve()
        step1_path = (repo_root / entry["step1"]).resolve()
        step2_path = (repo_root / entry["step2"]).resolve()

        image = cv2.imread(str(source))
        if image is None:
            raise RuntimeError(f"Failed to read source image: {source}")

        step0, mode = detect_document(image)
        step1, step2 = apply_magic_pipeline(step0)

        write_image(step0_path, step0)
        write_image(step1_path, step1)
        write_image(step2_path, step2)

        print(
            f'{entry["id"]}: {mode} '
            f'original={image.shape[1]}x{image.shape[0]} '
            f'step0={step0.shape[1]}x{step0.shape[0]}'
        )


if __name__ == "__main__":
    main()
