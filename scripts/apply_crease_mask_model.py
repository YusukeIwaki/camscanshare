#!/usr/bin/env python3
"""Apply a trained crease mask model to document images.

This script is for docs-side inspection. It writes one directory per input image
with:

- probability.png: predicted removable-defect probability
- raw-mask.png: thresholded CNN mask before foreground protection
- mask.png: foreground-protected defect mask
- fold-influence.png: soft broad-fold whitening influence
- dark-shadow-influence.png: broad dark-facet influence near fold candidates
- bw-whiten-mask.png: final forced-white mask for B/W output
- aggressive-cleanup-mask.png: additional crease-ridge/noise cleanup mask
- overlay.jpg: red protected-mask overlay for visual inspection
- cleaned-preview.png: conservative luminance whitening preview
- original-bw.png, cleaned-bw.png, cleaned-bw-aggressive.png: document B/W outputs

Usage:
    .venv/bin/python scripts/apply_crease_mask_model.py \
      --checkpoint tmp/crease-mask-model/model.pt \
      docs/public/algorithm/steps/report-samples/report-2026-05-16_15-25-20-step1.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np
import torch

from filter_asset_pipeline import apply_document_bw_pipeline
from train_crease_mask_model import TinyUNet, predict_full_image, select_device


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Apply crease mask model.")
    parser.add_argument("images", nargs="+", help="Images to process.")
    parser.add_argument("--checkpoint", default="tmp/crease-mask-model/model.pt", help="PyTorch checkpoint.")
    parser.add_argument("--out-dir", default="tmp/crease-mask-model-real-eval", help="Output directory.")
    parser.add_argument("--threshold", type=float, default=0.58, help="Mask threshold.")
    parser.add_argument("--tile-size", type=int, default=384, help="Inference tile size.")
    parser.add_argument("--overlap", type=int, default=96, help="Inference tile overlap.")
    return parser.parse_args()


def read_image(path: Path) -> np.ndarray:
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Failed to read image: {path}")
    return image


def write_image(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(path), image):
        raise RuntimeError(f"Failed to write image: {path}")


def load_model(checkpoint_path: Path, device: torch.device) -> TinyUNet:
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    in_channels = int(checkpoint.get("in_channels", len(checkpoint.get("input_channels", [])) or 3))
    model = TinyUNet(in_channels=in_channels, base_channels=int(checkpoint.get("base_channels", 16)))
    model.load_state_dict(checkpoint["model"])
    model.input_channels = in_channels
    model.to(device)
    model.eval()
    return model


def foreground_protection_mask(image_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    adaptive = cv2.adaptiveThreshold(
        cv2.GaussianBlur(gray, (3, 3), 0),
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        35,
        10,
    )
    _, dark = cv2.threshold(gray, max(96, int(np.percentile(gray, 12))), 255, cv2.THRESH_BINARY_INV)
    local_mean = cv2.GaussianBlur(gray.astype(np.float32), (0, 0), sigmaX=12.0, sigmaY=12.0)
    locally_dark = (((local_mean - gray.astype(np.float32)) > 8.0) & (gray < 238)).astype(np.uint8) * 255
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    saturation = hsv[:, :, 1]
    value = hsv[:, :, 2]
    saturation_threshold = max(18, int(np.percentile(saturation, 88)))
    colored = ((saturation > saturation_threshold) & (value < 252)).astype(np.uint8) * 255
    lab = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    chroma = np.sqrt((lab[:, :, 1] - 128.0) ** 2 + (lab[:, :, 2] - 128.0) ** 2)
    chroma_threshold = max(7.0, float(np.percentile(chroma, 88)))
    chromatic = ((chroma > chroma_threshold) & (gray < 248)).astype(np.uint8) * 255
    mask = cv2.bitwise_or(cv2.bitwise_or(adaptive, dark), cv2.bitwise_or(colored, chromatic))
    mask = cv2.bitwise_or(mask, locally_dark)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), dtype=np.uint8))
    return cv2.dilate(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=1)


def smoothstep(value: np.ndarray, low: float, high: float) -> np.ndarray:
    t = np.clip((value - low) / max(1e-5, high - low), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def odd_kernel_size(value: float, low: int, high: int) -> int:
    size = int(round(np.clip(value, low, high)))
    return size if size % 2 == 1 else size + 1


def paper_luminance_background(luminance: np.ndarray) -> np.ndarray:
    h, w = luminance.shape
    kernel_size = odd_kernel_size(min(h, w) * 0.14, 41, 121)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_size, kernel_size))
    closed = cv2.morphologyEx(np.clip(luminance, 0, 255).astype(np.uint8), cv2.MORPH_CLOSE, kernel)
    return cv2.GaussianBlur(closed.astype(np.float32), (0, 0), sigmaX=kernel_size / 3.4, sigmaY=kernel_size / 3.4)


def fine_content_protection_mask(image_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray_u8 = np.clip(gray, 0, 255).astype(np.uint8)
    local_mean = cv2.GaussianBlur(gray, (0, 0), sigmaX=5.0, sigmaY=5.0)
    grad_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    gradient = cv2.magnitude(grad_x, grad_y)
    gradient_threshold = max(8.0, float(np.percentile(gradient, 82)))

    adaptive = cv2.adaptiveThreshold(
        cv2.GaussianBlur(gray_u8, (3, 3), 0),
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        35,
        10,
    )
    dark_sharp = (
        (adaptive > 0)
        & ((gradient > gradient_threshold) | ((local_mean - gray) > 12.0) | (gray < 136.0))
    )
    edges = gradient > max(14.0, float(np.percentile(gradient, 88)))

    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    saturation = hsv[:, :, 1]
    value = hsv[:, :, 2]
    colored = (saturation > max(22, int(np.percentile(saturation, 90)))) & (value < 252)

    mask = ((dark_sharp | edges | colored) & (gray < 250.0)).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), dtype=np.uint8))
    return cv2.dilate(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)), iterations=1)


def printed_form_line_mask(image_bgr: np.ndarray, include_vertical: bool = True) -> np.ndarray:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    adaptive = cv2.adaptiveThreshold(
        blurred,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        35,
        10,
    )
    h, w = gray.shape
    horizontal_width = odd_kernel_size(w * 0.075, 17, 81)
    horizontal = cv2.morphologyEx(
        adaptive,
        cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (horizontal_width, 1)),
    )
    lines = horizontal.copy()
    if include_vertical:
        edges = cv2.Canny(blurred, 48, 140)
        min_line_length = max(24, int(min(h, w) * 0.10))
        segments = cv2.HoughLinesP(
            edges,
            1,
            np.pi / 180.0,
            threshold=max(16, int(min_line_length * 0.45)),
            minLineLength=min_line_length,
            maxLineGap=4,
        )
        if segments is not None:
            for segment in segments[:, 0, :]:
                x1, y1, x2, y2 = (int(value) for value in segment)
                angle = abs(np.degrees(np.arctan2(float(y2 - y1), float(x2 - x1))))
                angle = min(angle, 180.0 - angle)
                if angle <= 5.0 or angle >= 87.0:
                    cv2.line(lines, (x1, y1), (x2, y2), 255, 3, cv2.LINE_AA)
    return cv2.dilate(lines, cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3)), iterations=1)


def final_bw_whiten_mask(image_bgr: np.ndarray, dark_shadow_influence: np.ndarray) -> np.ndarray:
    lab = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    luminance = lab[:, :, 0]
    paper_background = paper_luminance_background(luminance)
    deficit = paper_background - luminance
    near_shadow = cv2.dilate(
        (dark_shadow_influence > 0.055).astype(np.uint8) * 255,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)),
        iterations=1,
    ) > 0
    form_lines = printed_form_line_mask(image_bgr, include_vertical=True) > 0
    ridge_candidate = (near_shadow & (deficit > 9.0) & (luminance < 228.0) & ~form_lines).astype(np.uint8)
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(ridge_candidate, connectivity=8)
    ridge = np.zeros_like(ridge_candidate)
    for label in range(1, component_count):
        width = int(stats[label, cv2.CC_STAT_WIDTH])
        height = int(stats[label, cv2.CC_STAT_HEIGHT])
        area = int(stats[label, cv2.CC_STAT_AREA])
        short_side = max(1, min(width, height))
        long_side = max(width, height)
        vertical_or_slanted = height >= width * 1.15
        if area >= 14 and long_side >= 18 and long_side / short_side >= 2.2 and vertical_or_slanted:
            ridge[labels == label] = 1

    mask = ((dark_shadow_influence > 0.10) | (ridge > 0)) & ~form_lines
    mask_u8 = mask.astype(np.uint8) * 255
    mask_u8 = cv2.morphologyEx(mask_u8, cv2.MORPH_CLOSE, np.ones((3, 3), dtype=np.uint8))
    return mask_u8


def aggressive_bw_cleanup_mask(
    image_bgr: np.ndarray,
    bw_bgr: np.ndarray,
    fold_influence: np.ndarray,
    dark_shadow_influence: np.ndarray,
) -> np.ndarray:
    gray_bw = cv2.cvtColor(bw_bgr, cv2.COLOR_BGR2GRAY)
    black = gray_bw < 128
    defect_influence = np.maximum(fold_influence, dark_shadow_influence)
    defect_zone = cv2.dilate(
        (defect_influence > 0.045).astype(np.uint8) * 255,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)),
        iterations=1,
    ) > 0
    form_lines = printed_form_line_mask(image_bgr, include_vertical=False) > 0
    candidate = (black & defect_zone & ~form_lines).astype(np.uint8)
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(candidate, connectivity=8)

    cleanup = np.zeros_like(candidate)
    for label in range(1, component_count):
        component = labels == label
        area = int(stats[label, cv2.CC_STAT_AREA])
        width = int(stats[label, cv2.CC_STAT_WIDTH])
        height = int(stats[label, cv2.CC_STAT_HEIGHT])
        short_side = max(1, min(width, height))
        long_side = max(width, height)
        aspect = long_side / short_side
        density = area / float(max(1, width * height))
        mean_influence = float(np.mean(defect_influence[component]))

        horizontal_text_like = width >= height * 1.55 and height <= 22 and density >= 0.18
        ridge_like = (
            area >= 14
            and long_side >= 18
            and aspect >= 2.0
            and mean_influence >= 0.035
            and not horizontal_text_like
        )
        chunky_ridge = (
            area >= 60
            and long_side >= 30
            and density <= 0.30
            and mean_influence >= 0.035
            and not horizontal_text_like
        )
        local_noise = area <= 10 and mean_influence >= 0.045
        sparse_medium_noise = (
            area <= 26
            and mean_influence >= 0.060
            and density <= 0.36
            and not horizontal_text_like
        )
        if ridge_like or chunky_ridge or local_noise or sparse_medium_noise:
            cleanup[component] = 1

    cleanup_u8 = cleanup * 255
    return cv2.morphologyEx(cleanup_u8, cv2.MORPH_CLOSE, np.ones((3, 3), dtype=np.uint8))


def fold_seed_field(image_bgr: np.ndarray, probability: np.ndarray, threshold: float) -> np.ndarray:
    foreground = foreground_protection_mask(image_bgr)
    background = foreground == 0
    seed_u8 = ((probability > threshold) & background).astype(np.uint8) * 255
    if not np.any(seed_u8):
        return np.zeros_like(probability, dtype=np.float32)
    seed_u8 = cv2.dilate(seed_u8, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (39, 39)), iterations=2)
    return cv2.GaussianBlur(seed_u8.astype(np.float32) / 255.0, (0, 0), sigmaX=20.0, sigmaY=20.0)


def fold_influence_field(image_bgr: np.ndarray, probability: np.ndarray, threshold: float) -> np.ndarray:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    foreground = foreground_protection_mask(image_bgr)
    background = foreground == 0
    high_confidence = (probability > threshold) & background
    low_threshold = max(0.16, threshold - 0.34)
    low_confidence = np.clip((probability - low_threshold) / max(1e-5, threshold - low_threshold), 0.0, 1.0)
    low_confidence *= background.astype(np.float32)

    seed = high_confidence.astype(np.uint8) * 255
    seed = cv2.dilate(seed, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (17, 17)), iterations=2)
    broad_seed = cv2.GaussianBlur(seed.astype(np.float32) / 255.0, (0, 0), sigmaX=11.0, sigmaY=11.0)

    local_mean = cv2.GaussianBlur(gray, (0, 0), sigmaX=34.0, sigmaY=34.0)
    broad_signature = np.clip(np.abs(local_mean - gray) / 0.09, 0.0, 1.0)
    influence = np.maximum(broad_seed, low_confidence * broad_signature * 0.80)
    influence = cv2.GaussianBlur(influence, (0, 0), sigmaX=2.4, sigmaY=2.4)
    return np.clip(influence * background.astype(np.float32), 0.0, 1.0)


def dark_shadow_influence_field(image_bgr: np.ndarray, probability: np.ndarray, threshold: float) -> np.ndarray:
    lab = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    luminance = lab[:, :, 0]
    paper_background = paper_luminance_background(luminance)
    deficit = cv2.GaussianBlur(np.maximum(paper_background - luminance, 0.0), (0, 0), sigmaX=2.0, sigmaY=2.0)
    dark_facet = smoothstep(deficit, 7.5, 30.0)

    near_fold = np.clip(fold_seed_field(image_bgr, probability, threshold) * 1.45, 0.0, 1.0)
    fine_content = fine_content_protection_mask(image_bgr).astype(np.float32) / 255.0
    fine_content = cv2.GaussianBlur(fine_content, (0, 0), sigmaX=1.2, sigmaY=1.2)
    ridge_override = smoothstep(probability, max(0.34, threshold - 0.24), min(1.0, threshold + 0.04))
    content_keep = 1.0 - np.clip(fine_content * (0.92 - 0.58 * ridge_override), 0.0, 0.92)

    influence = dark_facet * near_fold * content_keep
    active = (influence > 0.11).astype(np.uint8)
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(active, connectivity=8)
    kept = np.zeros_like(active)
    min_area = max(18, int(active.size * 0.00012))
    for label in range(1, component_count):
        if int(stats[label, cv2.CC_STAT_AREA]) >= min_area:
            kept[labels == label] = 1
    influence *= kept.astype(np.float32)
    influence_u8 = np.clip(influence * 255.0, 0, 255).astype(np.uint8)
    influence_u8 = cv2.morphologyEx(
        influence_u8,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15)),
    )
    influence = cv2.GaussianBlur(influence_u8.astype(np.float32) / 255.0, (0, 0), sigmaX=3.2, sigmaY=3.2)
    return np.clip(influence, 0.0, 1.0)


def cleaned_preview(image_bgr: np.ndarray, probability: np.ndarray, threshold: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    lab = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    luminance = lab[:, :, 0]
    fold_influence = fold_influence_field(image_bgr, probability, threshold)
    dark_shadow_influence = dark_shadow_influence_field(image_bgr, probability, threshold)
    influence = np.maximum(fold_influence * 0.78, dark_shadow_influence)

    local_background = paper_luminance_background(luminance)
    local_shadow = np.clip((local_background - luminance) / 34.0, 0.0, 1.0)
    confidence = np.clip((probability - max(0.16, threshold - 0.34)) / max(1e-5, 1.0 - threshold), 0.0, 1.0)
    fold_weight = fold_influence * (0.40 + 0.52 * local_shadow + 0.28 * confidence)
    shadow_weight = dark_shadow_influence * (0.70 + 0.66 * local_shadow)
    weight = np.clip(np.maximum(fold_weight, shadow_weight), 0.0, 0.98)

    target = np.maximum(local_background + 22.0 + 14.0 * dark_shadow_influence, 248.0)
    lab[:, :, 0] = np.clip(luminance * (1.0 - weight) + target * weight, 0, 255)
    shadow_chroma = smoothstep(dark_shadow_influence, 0.05, 0.45)
    chroma_weight = np.clip(np.maximum(fold_influence * 0.42, shadow_chroma), 0.0, 1.0)
    lab[:, :, 1] = lab[:, :, 1] * (1.0 - chroma_weight) + 128.0 * chroma_weight
    lab[:, :, 2] = lab[:, :, 2] * (1.0 - chroma_weight) + 128.0 * chroma_weight
    return cv2.cvtColor(lab.astype(np.uint8), cv2.COLOR_LAB2BGR), influence, dark_shadow_influence


def protected_mask(image_bgr: np.ndarray, probability: np.ndarray, threshold: float) -> np.ndarray:
    foreground = foreground_protection_mask(image_bgr)
    raw_mask = probability > threshold
    return (raw_mask & (foreground == 0)).astype(np.uint8) * 255


def overlay_mask(image_bgr: np.ndarray, mask: np.ndarray) -> np.ndarray:
    red = np.zeros_like(image_bgr)
    red[:, :, 2] = 255
    overlay = cv2.addWeighted(image_bgr, 0.58, red, 0.42, 0.0)
    return np.where((mask[:, :, None] > 0), overlay, image_bgr)


def fit_cell(image: np.ndarray, label: str, width: int = 330, height: int = 440) -> np.ndarray:
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    source_h, source_w = image.shape[:2]
    scale = min(width / source_w, (height - 30) / source_h)
    resized_w = max(1, int(round(source_w * scale)))
    resized_h = max(1, int(round(source_h * scale)))
    resized = cv2.resize(image, (resized_w, resized_h), interpolation=cv2.INTER_AREA)
    canvas = np.full((height, width, 3), 255, dtype=np.uint8)
    x = (width - resized_w) // 2
    y = 28 + (height - 30 - resized_h) // 2
    canvas[y: y + resized_h, x: x + resized_w] = resized
    cv2.putText(canvas, label, (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (0, 0, 170), 1, cv2.LINE_AA)
    return canvas


def main() -> None:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    checkpoint_path = (repo_root / args.checkpoint).resolve()
    out_dir = (repo_root / args.out_dir).resolve()
    device = select_device()
    model = load_model(checkpoint_path, device)

    sheet_rows = []
    for image_arg in args.images:
        image_path = (repo_root / image_arg).resolve()
        image = read_image(image_path)
        probability = predict_full_image(model, image, device, tile_size=args.tile_size, overlap=args.overlap)
        raw_mask = (probability > args.threshold).astype(np.uint8) * 255
        mask = protected_mask(image, probability, args.threshold)
        probability_u8 = np.clip(probability * 255.0, 0, 255).astype(np.uint8)
        overlay = overlay_mask(image, mask)
        cleaned, influence, dark_shadow_influence = cleaned_preview(image, probability, args.threshold)
        original_bw = apply_document_bw_pipeline(image)
        cleaned_bw = apply_document_bw_pipeline(cleaned)
        bw_whiten_mask = final_bw_whiten_mask(image, dark_shadow_influence)
        cleaned_bw[bw_whiten_mask > 0] = 255
        aggressive_cleanup = aggressive_bw_cleanup_mask(image, cleaned_bw, influence, dark_shadow_influence)
        aggressive_bw = cleaned_bw.copy()
        aggressive_bw[aggressive_cleanup > 0] = 255
        influence_u8 = np.clip(influence * 255.0, 0, 255).astype(np.uint8)
        dark_shadow_u8 = np.clip(dark_shadow_influence * 255.0, 0, 255).astype(np.uint8)

        stem = image_path.stem
        sample_dir = out_dir / stem
        write_image(sample_dir / "probability.png", probability_u8)
        write_image(sample_dir / "raw-mask.png", raw_mask)
        write_image(sample_dir / "mask.png", mask)
        write_image(sample_dir / "fold-influence.png", influence_u8)
        write_image(sample_dir / "dark-shadow-influence.png", dark_shadow_u8)
        write_image(sample_dir / "bw-whiten-mask.png", bw_whiten_mask)
        write_image(sample_dir / "aggressive-cleanup-mask.png", aggressive_cleanup)
        write_image(sample_dir / "overlay.jpg", overlay)
        write_image(sample_dir / "cleaned-preview.png", cleaned)
        write_image(sample_dir / "original-bw.png", original_bw)
        write_image(sample_dir / "cleaned-bw.png", cleaned_bw)
        write_image(sample_dir / "cleaned-bw-aggressive.png", aggressive_bw)
        sheet_rows.append(
            np.concatenate(
                [
                    fit_cell(image, f"{stem} input"),
                    fit_cell(probability_u8, "probability"),
                    fit_cell(dark_shadow_u8, "dark shadow"),
                    fit_cell(cleaned, "cleaned preview"),
                    fit_cell(original_bw, "original bw"),
                    fit_cell(cleaned_bw, "cleaned bw"),
                    fit_cell(aggressive_bw, "aggressive bw"),
                ],
                axis=1,
            ),
        )
        print(
            f"{image_path}: raw_mask_ratio={float(np.mean(raw_mask > 0)):.4f} "
            f"protected_mask_ratio={float(np.mean(mask > 0)):.4f} "
            f"shadow_ratio={float(np.mean(dark_shadow_influence > 0.12)):.4f} "
            f"aggressive_ratio={float(np.mean(aggressive_cleanup > 0)):.4f} -> {sample_dir}",
        )

    if sheet_rows:
        write_image(out_dir / "contact-sheet.jpg", np.concatenate(sheet_rows, axis=0))
        print(f"Contact sheet: {out_dir / 'contact-sheet.jpg'}")


if __name__ == "__main__":
    main()
