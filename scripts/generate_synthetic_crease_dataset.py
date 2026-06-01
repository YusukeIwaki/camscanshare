#!/usr/bin/env python3
"""Generate paired training data for paper crease and wrinkle cleanup.

The dataset is synthetic by design: every generated sample has a degraded input,
a clean target, a removable-defect mask, and a foreground mask. The goal is to
train a model to remove paper defects without learning to remove text, lines, or
figures.

The crease styles are tuned around the report samples:
  - report-2026-05-16_15-25-20-step1.png
  - report-2026-05-16_15-21-16-step1.png

Usage:
    .venv/bin/python scripts/generate_synthetic_crease_dataset.py
    .venv/bin/python scripts/generate_synthetic_crease_dataset.py --count 96
"""

from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

import cv2
import numpy as np


DEFAULT_BASE_IMAGES = (
    "docs/public/algorithm/steps/user-samples/20260407_201908-step1.png",
    "docs/public/algorithm/steps/user-samples/20260407_201920-step1.png",
    "docs/public/algorithm/steps/opencv-samples/tax-step1.png",
    "docs/public/algorithm/steps/opencv-samples/chart-step1.png",
    "docs/public/algorithm/steps/opencv-samples/notepad-step1.png",
)

REFERENCE_IMAGES = (
    "docs/public/algorithm/steps/report-samples/report-2026-05-16_15-25-20-step1.png",
    "docs/public/algorithm/steps/report-samples/report-2026-05-16_15-21-16-step1.png",
)


@dataclass(frozen=True)
class SamplePaths:
    sample_id: str
    input_path: Path
    clean_path: Path
    defect_mask_path: Path
    foreground_mask_path: Path
    shadow_field_path: Path


@dataclass(frozen=True)
class TextureSource:
    label: str
    image: np.ndarray


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate synthetic crease/wrinkle training pairs.",
    )
    parser.add_argument(
        "--out-dir",
        default="tmp/synthetic-crease-dataset",
        help="Output dataset directory. tmp/ is gitignored by default.",
    )
    parser.add_argument("--count", type=int, default=48, help="Number of samples to generate.")
    parser.add_argument("--seed", type=int, default=20260518, help="Random seed.")
    parser.add_argument("--width", type=int, default=768, help="Output width.")
    parser.add_argument("--height", type=int, default=1088, help="Output height.")
    parser.add_argument(
        "--negative-ratio",
        type=float,
        default=0.20,
        help="Ratio of no-crease negative samples with normal paper background.",
    )
    parser.add_argument(
        "--procedural-ratio",
        type=float,
        default=0.60,
        help="Ratio of samples using generated school handouts instead of existing base images.",
    )
    parser.add_argument(
        "--hard-negative-trap-ratio",
        type=float,
        default=0.65,
        help="Ratio of generated handouts that include pale headings, badges, and filled shapes.",
    )
    parser.add_argument(
        "--base-image",
        action="append",
        default=[],
        help="Additional clean-ish base image to use. Can be passed multiple times.",
    )
    parser.add_argument(
        "--texture-image",
        action="append",
        default=[],
        help=(
            "Wrinkled/folded blank paper texture image path or URL. "
            "Can be passed multiple times. Remote images are cached under the output tmp directory."
        ),
    )
    parser.add_argument(
        "--texture-ratio",
        type=float,
        default=0.65,
        help="Probability of using a supplied texture image for each positive crease sample.",
    )
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


def is_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"}


def safe_texture_filename(url: str, index: int) -> str:
    parsed = urlparse(url)
    name = Path(parsed.path).name or f"texture-{index:02d}.jpg"
    if "." not in name:
        name += ".jpg"
    safe = "".join(char if char.isalnum() or char in "._-" else "_" for char in name)
    return f"{index:02d}-{safe[:96]}"


def download_texture(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        return
    request = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(request, timeout=30) as response:
        destination.write_bytes(response.read())


def load_texture_sources(texture_args: list[str], repo_root: Path, out_dir: Path) -> list[TextureSource]:
    textures: list[TextureSource] = []
    for index, source in enumerate(texture_args):
        if is_url(source):
            texture_path = out_dir / "source-textures" / safe_texture_filename(source, index)
            download_texture(source, texture_path)
            label = source
        else:
            raw_path = Path(source)
            texture_path = raw_path if raw_path.is_absolute() else repo_root / raw_path
            label = str(texture_path.relative_to(repo_root)) if texture_path.is_relative_to(repo_root) else str(texture_path)
        textures.append(TextureSource(label=label, image=read_image(texture_path)))
    return textures


def fit_to_canvas(image: np.ndarray, width: int, height: int, rng: random.Random) -> np.ndarray:
    source_h, source_w = image.shape[:2]
    scale = min(width / source_w, height / source_h) * rng.uniform(0.91, 1.02)
    resized_w = max(1, int(round(source_w * scale)))
    resized_h = max(1, int(round(source_h * scale)))
    resized = cv2.resize(image, (resized_w, resized_h), interpolation=cv2.INTER_AREA)

    canvas = np.full((height, width, 3), 246, dtype=np.uint8)
    max_x = max(0, width - resized_w)
    max_y = max(0, height - resized_h)
    offset_x = rng.randint(0, max_x) if max_x else 0
    offset_y = rng.randint(0, max_y) if max_y else 0
    canvas[offset_y: offset_y + resized_h, offset_x: offset_x + resized_w] = resized[:height, :width]
    return canvas


def draw_qr_like_block(image: np.ndarray, x: int, y: int, size: int, rng: random.Random) -> None:
    cells = 13
    cell = max(1, size // cells)
    cv2.rectangle(image, (x, y), (x + cells * cell, y + cells * cell), (250, 250, 250), -1)
    cv2.rectangle(image, (x, y), (x + cells * cell, y + cells * cell), (40, 40, 40), 1)
    for row in range(cells):
        for col in range(cells):
            finder = (
                (row < 4 and col < 4)
                or (row < 4 and col >= cells - 4)
                or (row >= cells - 4 and col < 4)
            )
            if finder or rng.random() < 0.34:
                x1 = x + col * cell
                y1 = y + row * cell
                cv2.rectangle(image, (x1, y1), (x1 + cell - 1, y1 + cell - 1), (30, 30, 30), -1)


def draw_rounded_rect(
    image: np.ndarray,
    top_left: tuple[int, int],
    bottom_right: tuple[int, int],
    color: tuple[int, int, int],
    radius: int,
    thickness: int,
) -> None:
    x1, y1 = top_left
    x2, y2 = bottom_right
    radius = max(1, min(radius, (x2 - x1) // 2, (y2 - y1) // 2))
    cv2.rectangle(image, (x1 + radius, y1), (x2 - radius, y2), color, thickness)
    cv2.rectangle(image, (x1, y1 + radius), (x2, y2 - radius), color, thickness)
    cv2.ellipse(image, (x1 + radius, y1 + radius), (radius, radius), 180, 0, 90, color, thickness)
    cv2.ellipse(image, (x2 - radius, y1 + radius), (radius, radius), 270, 0, 90, color, thickness)
    cv2.ellipse(image, (x2 - radius, y2 - radius), (radius, radius), 0, 0, 90, color, thickness)
    cv2.ellipse(image, (x1 + radius, y2 - radius), (radius, radius), 90, 0, 90, color, thickness)


def draw_hard_negative_printed_shapes(
    image: np.ndarray,
    margin_x: int,
    title_y: int,
    ink: tuple[int, int, int],
    rng: random.Random,
) -> None:
    height, width = image.shape[:2]
    pale_palette = [
        (232, 225, 214),
        (230, 224, 238),
        (226, 235, 240),
        (238, 232, 222),
        (224, 232, 230),
    ]
    line_palette = [
        (130, 120, 110),
        (125, 118, 145),
        (112, 132, 145),
        (145, 124, 116),
    ]

    if rng.random() < 0.92:
        center = (width // 2 + rng.randint(-35, 35), title_y - rng.randint(8, 22))
        axes = (rng.randint(int(width * 0.20), int(width * 0.34)), rng.randint(24, 42))
        cv2.ellipse(image, center, axes, rng.uniform(-4, 4), 0, 360, rng.choice(pale_palette), -1, cv2.LINE_AA)

    if rng.random() < 0.86:
        band_y = rng.randint(int(height * 0.18), int(height * 0.34))
        band_h = rng.randint(30, 58)
        cv2.rectangle(image, (margin_x, band_y), (width - margin_x, band_y + band_h), rng.choice(pale_palette), -1)
        cv2.line(image, (margin_x, band_y), (width - margin_x, band_y), rng.choice(line_palette), 1)
        cv2.line(image, (margin_x, band_y + band_h), (width - margin_x, band_y + band_h), rng.choice(line_palette), 1)
        cv2.putText(
            image,
            rng.choice(["Important", "Notice", "Check", "Return"]),
            (margin_x + 18, band_y + band_h - 16),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.54,
            ink,
            1,
            cv2.LINE_AA,
        )

    for _ in range(rng.randint(1, 3)):
        w = rng.randint(int(width * 0.17), int(width * 0.34))
        h = rng.randint(32, 58)
        x = rng.randint(margin_x, max(margin_x, width - margin_x - w))
        y = rng.randint(int(height * 0.42), int(height * 0.82))
        fill = rng.choice(pale_palette)
        outline = rng.choice(line_palette)
        if rng.random() < 0.55:
            draw_rounded_rect(image, (x, y), (x + w, y + h), fill, radius=12, thickness=-1)
            draw_rounded_rect(image, (x, y), (x + w, y + h), outline, radius=12, thickness=1)
        else:
            cv2.ellipse(image, (x + w // 2, y + h // 2), (w // 2, h // 2), 0, 0, 360, fill, -1, cv2.LINE_AA)
            cv2.ellipse(image, (x + w // 2, y + h // 2), (w // 2, h // 2), 0, 0, 360, outline, 1, cv2.LINE_AA)
        cv2.putText(image, rng.choice(["Note", "Call", "Sign", "Due"]), (x + 14, y + h // 2 + 6), cv2.FONT_HERSHEY_SIMPLEX, 0.45, ink, 1, cv2.LINE_AA)

    if rng.random() < 0.72:
        box_w = rng.randint(int(width * 0.42), int(width * 0.68))
        box_h = rng.randint(76, 124)
        x1 = rng.randint(margin_x, max(margin_x, width - margin_x - box_w))
        y1 = rng.randint(int(height * 0.56), int(height * 0.80))
        cv2.rectangle(image, (x1, y1), (x1 + box_w, y1 + box_h), rng.choice(pale_palette), -1)
        cv2.rectangle(image, (x1, y1), (x1 + box_w, y1 + box_h), rng.choice(line_palette), 1)
        for row in range(1, rng.randint(2, 4)):
            yy = y1 + row * box_h // 4
            cv2.line(image, (x1, yy), (x1 + box_w, yy), rng.choice(line_palette), 1)
        cv2.putText(image, "Contact / Office", (x1 + 18, y1 + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.48, ink, 1, cv2.LINE_AA)


def make_synthetic_handout(width: int, height: int, rng: random.Random, hard_negative_shapes: bool = False) -> np.ndarray:
    """Create a clean school-handout-like page with dense printable structure."""
    image = np.full((height, width, 3), rng.randint(242, 250), dtype=np.uint8)
    margin_x = int(width * rng.uniform(0.08, 0.12))
    y = int(height * rng.uniform(0.07, 0.10))
    ink = (rng.randint(32, 58),) * 3
    title_y = y

    if hard_negative_shapes:
        draw_hard_negative_printed_shapes(image, margin_x, title_y, ink, rng)

    title = rng.choice(["School Notice", "PTA Activity Notice", "Health Check Notice", "Class Schedule"])
    cv2.putText(image, title, (margin_x, y), cv2.FONT_HERSHEY_SIMPLEX, 1.05, ink, 2, cv2.LINE_AA)
    y += 42
    cv2.line(image, (margin_x, y), (width - margin_x, y), ink, 2)
    y += 34

    for _ in range(rng.randint(6, 10)):
        line_w = rng.randint(int(width * 0.48), int(width * 0.78))
        cv2.putText(
            image,
            rng.choice(["Please check the details below.", "Return this form by Friday.", "Bring this notice to school."]),
            (margin_x, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            rng.uniform(0.45, 0.58),
            ink,
            1,
            cv2.LINE_AA,
        )
        if rng.random() < 0.7:
            cv2.line(image, (margin_x + rng.randint(180, 260), y + 5), (margin_x + line_w, y + 5), (95, 95, 95), 1)
        y += rng.randint(28, 38)

    box_top = y + 10
    box_h = rng.randint(int(height * 0.18), int(height * 0.28))
    cv2.rectangle(image, (margin_x, box_top), (width - margin_x, box_top + box_h), ink, 2)
    rows = rng.randint(4, 7)
    cols = rng.randint(3, 5)
    for row in range(1, rows):
        yy = box_top + row * box_h // rows
        cv2.line(image, (margin_x, yy), (width - margin_x, yy), ink, 1)
    for col in range(1, cols):
        xx = margin_x + col * (width - margin_x * 2) // cols
        cv2.line(image, (xx, box_top), (xx, box_top + box_h), ink, 1)
    for row in range(rows):
        for col in range(cols):
            if rng.random() < 0.82:
                tx = margin_x + col * (width - margin_x * 2) // cols + 12
                ty = box_top + row * box_h // rows + 27
                cv2.putText(image, rng.choice(["Class", "Date", "Name", "Check", "Memo"]), (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.42, ink, 1, cv2.LINE_AA)

    y = box_top + box_h + 44
    for _ in range(rng.randint(5, 9)):
        cv2.circle(image, (margin_x + 8, y - 5), 3, ink, -1)
        cv2.putText(
            image,
            rng.choice(["Lunch box", "Water bottle", "Notebook", "Parent signature", "No late arrival"]),
            (margin_x + 24, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.48,
            ink,
            1,
            cv2.LINE_AA,
        )
        y += rng.randint(28, 36)

    if rng.random() < 0.75:
        draw_qr_like_block(image, width - margin_x - 92, height - margin_x - 92, 86, rng)
    if rng.random() < 0.55:
        cv2.rectangle(image, (margin_x, height - margin_x - 90), (width - margin_x - 120, height - margin_x - 26), ink, 2)
        cv2.putText(image, "Parent / Guardian", (margin_x + 18, height - margin_x - 50), cv2.FONT_HERSHEY_SIMPLEX, 0.55, ink, 1, cv2.LINE_AA)

    return image


def foreground_mask(clean_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(clean_bgr, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    adaptive = cv2.adaptiveThreshold(
        blurred,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        35,
        11,
    )
    _, dark = cv2.threshold(gray, max(120, int(np.percentile(gray, 18))), 255, cv2.THRESH_BINARY_INV)
    local_mean = cv2.GaussianBlur(gray.astype(np.float32), (0, 0), sigmaX=12.0, sigmaY=12.0)
    locally_dark = (((local_mean - gray.astype(np.float32)) > 8.0) & (gray < 238)).astype(np.uint8) * 255
    hsv = cv2.cvtColor(clean_bgr, cv2.COLOR_BGR2HSV)
    saturation = hsv[:, :, 1]
    value = hsv[:, :, 2]
    saturation_threshold = max(18, int(np.percentile(saturation, 88)))
    colored = ((saturation > saturation_threshold) & (value < 252)).astype(np.uint8) * 255
    lab = cv2.cvtColor(clean_bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    chroma = np.sqrt((lab[:, :, 1] - 128.0) ** 2 + (lab[:, :, 2] - 128.0) ** 2)
    chroma_threshold = max(7.0, float(np.percentile(chroma, 88)))
    chromatic = ((chroma > chroma_threshold) & (gray < 248)).astype(np.uint8) * 255
    mask = cv2.bitwise_or(cv2.bitwise_or(adaptive, dark), cv2.bitwise_or(colored, chromatic))
    mask = cv2.bitwise_or(mask, locally_dark)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), dtype=np.uint8), iterations=1)
    return cv2.dilate(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=1)


def random_polyline(width: int, height: int, rng: random.Random, long_fold: bool) -> list[tuple[float, float]]:
    angle = rng.choice([0, math.pi / 2, math.pi / 4, -math.pi / 4, rng.uniform(-0.55, 0.55)])
    length = rng.uniform(0.72, 1.18) * math.hypot(width, height) if long_fold else rng.uniform(0.16, 0.48) * max(width, height)
    center_x = rng.uniform(width * 0.08, width * 0.92)
    center_y = rng.uniform(height * 0.08, height * 0.92)
    dx = math.cos(angle)
    dy = math.sin(angle)
    nx = -dy
    ny = dx
    steps = rng.randint(4, 8)
    points: list[tuple[float, float]] = []
    curve = rng.uniform(-0.10, 0.10) * length
    for index in range(steps):
        t = (index / (steps - 1) - 0.5) * length
        wobble = math.sin(index / max(1, steps - 1) * math.pi) * curve + rng.uniform(-0.018, 0.018) * length
        x = center_x + dx * t + nx * wobble
        y = center_y + dy * t + ny * wobble
        points.append((x, y))
    return points


def segment_fields(
    shape: tuple[int, int],
    points: list[tuple[float, float]],
    sigma: float,
) -> tuple[np.ndarray, np.ndarray]:
    height, width = shape
    y_grid, x_grid = np.mgrid[0:height, 0:width].astype(np.float32)
    distance = np.full((height, width), np.inf, dtype=np.float32)
    signed = np.zeros((height, width), dtype=np.float32)
    for start, end in zip(points, points[1:]):
        x1, y1 = start
        x2, y2 = end
        vx = x2 - x1
        vy = y2 - y1
        length_sq = max(vx * vx + vy * vy, 1.0)
        t = np.clip(((x_grid - x1) * vx + (y_grid - y1) * vy) / length_sq, 0.0, 1.0)
        proj_x = x1 + t * vx
        proj_y = y1 + t * vy
        dx = x_grid - proj_x
        dy = y_grid - proj_y
        dist = np.sqrt(dx * dx + dy * dy)
        update = dist < distance
        distance[update] = dist[update]
        inv_len = 1.0 / math.sqrt(length_sq)
        normal_x = -vy * inv_len
        normal_y = vx * inv_len
        signed[update] = dx[update] * normal_x + dy[update] * normal_y

    support = np.exp(-(distance * distance) / (2.0 * sigma * sigma))
    return support.astype(np.float32), signed.astype(np.float32)


def correlated_noise(shape: tuple[int, int], rng: random.Random, sigma: float) -> np.ndarray:
    noise = np.random.default_rng(rng.randrange(2**32)).normal(0.0, 1.0, shape).astype(np.float32)
    blurred = cv2.GaussianBlur(noise, (0, 0), sigmaX=sigma, sigmaY=sigma)
    blurred -= float(blurred.mean())
    std = float(blurred.std())
    if std > 1e-5:
        blurred /= std
    return blurred


def apply_displacement(image: np.ndarray, height_field: np.ndarray, rng: random.Random) -> np.ndarray:
    gray = height_field.astype(np.float32)
    grad_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=5)
    grad_y = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=5)
    scale = rng.uniform(0.10, 0.28)
    height, width = gray.shape
    y_grid, x_grid = np.mgrid[0:height, 0:width].astype(np.float32)
    map_x = x_grid + grad_x * scale
    map_y = y_grid + grad_y * scale
    return cv2.remap(image, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)


def paired_crease_fields(
    shape: tuple[int, int],
    points: list[tuple[float, float]],
    width: float,
    transition: float,
    amplitude: float,
    rng: random.Random,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return adjacent dark/bright fold lobes around a single crease centerline.

    The normal profile is intentionally bipolar: one side darkens and the other
    side brightens with a steep transition at the same centerline. That matches
    photographed paper folds better than independently drawn dark scratches.
    """
    support, signed = segment_fields(shape, points, width)
    side = rng.choice([-1.0, 1.0])
    signed_side = signed * side
    bipolar = np.tanh(signed_side / max(0.35, transition)) * support

    highlight_balance = rng.uniform(0.55, 0.95)
    shadow = np.clip(-bipolar, 0.0, 1.0) * amplitude
    highlight = np.clip(bipolar, 0.0, 1.0) * amplitude * highlight_balance

    center_sigma = max(0.7, transition * rng.uniform(0.85, 1.35))
    center_band = np.exp(-(signed * signed) / (2.0 * center_sigma * center_sigma)) * support
    if rng.random() < 0.72:
        shadow += center_band * amplitude * rng.uniform(0.08, 0.22)
    else:
        highlight += center_band * amplitude * rng.uniform(0.06, 0.16)

    local_variation = correlated_noise(shape, rng, sigma=rng.uniform(10.0, 32.0))
    local_gain = np.clip(1.0 + local_variation * rng.uniform(0.04, 0.16), 0.72, 1.26)
    shadow *= local_gain
    highlight *= local_gain

    strength = np.clip(np.abs(bipolar) + center_band * 0.85, 0.0, 1.0) * amplitude
    height = bipolar * amplitude * rng.uniform(0.26, 0.58)
    return (
        shadow.astype(np.float32),
        highlight.astype(np.float32),
        height.astype(np.float32),
        strength.astype(np.float32),
    )


def paired_broad_fold_fields(
    shape: tuple[int, int],
    points: list[tuple[float, float]],
    width: float,
    transition: float,
    amplitude: float,
    rng: random.Random,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return a wide fold field with adjacent shadow/highlight paper facets."""
    support, signed = segment_fields(shape, points, width)
    side = rng.choice([-1.0, 1.0])
    signed_side = signed * side
    slope = np.tanh(signed_side / max(0.8, transition))

    shadow_center = -width * rng.uniform(0.18, 0.40)
    highlight_center = width * rng.uniform(0.12, 0.34)
    shadow_lobe = np.exp(-((signed_side - shadow_center) ** 2) / (2.0 * (width * rng.uniform(0.30, 0.54)) ** 2))
    highlight_lobe = np.exp(-((signed_side - highlight_center) ** 2) / (2.0 * (width * rng.uniform(0.22, 0.46)) ** 2))
    valley = np.exp(-(signed_side * signed_side) / (2.0 * (transition * rng.uniform(0.85, 1.45)) ** 2))

    low_frequency_gain = correlated_noise(shape, rng, sigma=rng.uniform(24.0, 62.0))
    low_frequency_gain = np.clip(1.0 + low_frequency_gain * rng.uniform(0.05, 0.18), 0.65, 1.30)
    support_soft = np.power(np.clip(support, 0.0, 1.0), rng.uniform(0.55, 0.92))

    shadow = (shadow_lobe * rng.uniform(0.70, 1.12) + valley * rng.uniform(0.10, 0.28)) * support_soft
    highlight = highlight_lobe * rng.uniform(0.46, 0.90) * support_soft
    if rng.random() < 0.35:
        highlight += valley * rng.uniform(0.05, 0.16) * support_soft

    shadow_field = shadow * amplitude * low_frequency_gain
    highlight_field = highlight * amplitude * low_frequency_gain
    height_field = slope * support_soft * amplitude * rng.uniform(0.18, 0.42)

    gradient_band = np.exp(-(signed_side * signed_side) / (2.0 * (transition * rng.uniform(1.0, 1.9)) ** 2))
    strength = np.clip(
        shadow * 0.95 + highlight * 0.78 + gradient_band * support_soft * 0.50,
        0.0,
        1.0,
    ) * amplitude
    return (
        shadow_field.astype(np.float32),
        highlight_field.astype(np.float32),
        height_field.astype(np.float32),
        strength.astype(np.float32),
    )


def random_texture_patch(texture_bgr: np.ndarray, width: int, height: int, rng: random.Random) -> np.ndarray:
    image = texture_bgr.copy()
    if rng.random() < 0.5:
        image = cv2.flip(image, 1)
    if rng.random() < 0.5:
        image = cv2.flip(image, 0)
    if rng.random() < 0.35:
        image = np.rot90(image, rng.choice([1, 2, 3])).copy()

    source_h, source_w = image.shape[:2]
    scale = max(width / source_w, height / source_h) * rng.uniform(1.0, 1.65)
    resized_w = max(width, int(round(source_w * scale)))
    resized_h = max(height, int(round(source_h * scale)))
    resized = cv2.resize(image, (resized_w, resized_h), interpolation=cv2.INTER_AREA)

    max_x = max(0, resized_w - width)
    max_y = max(0, resized_h - height)
    x = rng.randint(0, max_x) if max_x else 0
    y = rng.randint(0, max_y) if max_y else 0
    patch = resized[y: y + height, x: x + width].copy()

    if rng.random() < 0.55:
        angle = rng.uniform(-12.0, 12.0)
        matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), angle, 1.0)
        patch = cv2.warpAffine(
            patch,
            matrix,
            (width, height),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_REFLECT_101,
        )
    return patch


def robust_unit_field(field: np.ndarray, percentile: float = 96.0) -> np.ndarray:
    centered = field.astype(np.float32) - float(np.median(field))
    scale = float(np.percentile(np.abs(centered), percentile))
    if scale < 1e-5:
        return np.zeros_like(centered, dtype=np.float32)
    return np.clip(centered / scale, -1.7, 1.7)


def texture_defect_fields(
    texture_bgr: np.ndarray,
    shape: tuple[int, int],
    rng: random.Random,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    height, width = shape
    patch = random_texture_patch(texture_bgr, width, height, rng)
    gray = cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = np.clip(
        gray,
        float(np.percentile(gray, 2.0)),
        float(np.percentile(gray, 98.0)),
    )
    gray = cv2.GaussianBlur(gray, (0, 0), sigmaX=rng.uniform(2.6, 5.5), sigmaY=rng.uniform(2.6, 5.5))

    local_base = cv2.GaussianBlur(gray, (0, 0), sigmaX=rng.uniform(18.0, 42.0), sigmaY=rng.uniform(18.0, 42.0))
    broad_base = cv2.GaussianBlur(gray, (0, 0), sigmaX=rng.uniform(90.0, 175.0), sigmaY=rng.uniform(90.0, 175.0))
    band = cv2.GaussianBlur(gray - local_base, (0, 0), sigmaX=rng.uniform(2.4, 5.2), sigmaY=rng.uniform(2.4, 5.2))
    broad = cv2.GaussianBlur(local_base - broad_base, (0, 0), sigmaX=rng.uniform(7.0, 16.0), sigmaY=rng.uniform(7.0, 16.0))

    band_unit = robust_unit_field(band, percentile=95.5)
    broad_unit = robust_unit_field(broad, percentile=94.0)
    if rng.random() < 0.5:
        band_unit *= -1.0
    if rng.random() < 0.35:
        broad_unit *= -1.0

    grad_x = cv2.Sobel(band, cv2.CV_32F, 1, 0, ksize=5)
    grad_y = cv2.Sobel(band, cv2.CV_32F, 0, 1, ksize=5)
    grad_mag = cv2.GaussianBlur(np.sqrt(grad_x * grad_x + grad_y * grad_y), (0, 0), 2.4)
    line_confidence = np.clip(
        grad_mag / max(1e-5, float(np.percentile(grad_mag, 96.5))),
        0.0,
        1.0,
    )
    line_confidence = cv2.GaussianBlur(line_confidence, (0, 0), 1.8)

    line_amp = rng.uniform(4.0, 12.0)
    broad_amp = rng.uniform(1.5, 6.0)
    signed_pair = band_unit * line_confidence
    shadow_field = np.clip(-signed_pair, 0.0, 1.20) * line_amp
    shadow_field += np.clip(-broad_unit, 0.0, 1.20) * broad_amp * line_confidence
    highlight_field = np.clip(signed_pair, 0.0, 1.20) * line_amp * rng.uniform(0.55, 0.95)
    highlight_field += np.clip(broad_unit, 0.0, 1.20) * broad_amp * rng.uniform(0.35, 0.70) * line_confidence

    strength = cv2.GaussianBlur(
        np.abs(signed_pair) * 1.15 + np.abs(broad_unit) * line_confidence * 0.75,
        (0, 0),
        sigmaX=1.4,
        sigmaY=1.4,
    )
    strength = np.clip(strength / max(1e-5, float(np.percentile(strength, 98.5))), 0.0, 1.4)
    height_field = (highlight_field - shadow_field) * rng.uniform(0.18, 0.48)
    return (
        shadow_field.astype(np.float32),
        highlight_field.astype(np.float32),
        height_field.astype(np.float32),
        strength.astype(np.float32),
    )


def synthesize_defects(
    clean_bgr: np.ndarray,
    mode: str,
    rng: random.Random,
    texture_source: TextureSource | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    height, width = clean_bgr.shape[:2]
    shadow_field = np.zeros((height, width), dtype=np.float32)
    highlight_field = np.zeros((height, width), dtype=np.float32)
    height_field = np.zeros((height, width), dtype=np.float32)
    crease_strength = np.zeros((height, width), dtype=np.float32)
    texture_strength = np.zeros((height, width), dtype=np.float32)

    if mode == "folded_handout":
        broad_fold_count = rng.randint(2, 4)
        crease_count = rng.randint(1, 3)
        wrinkle_count = rng.randint(3, 7)
    elif mode == "forgot_clear_file":
        broad_fold_count = rng.randint(3, 7)
        crease_count = rng.randint(1, 3)
        wrinkle_count = rng.randint(10, 20)
    elif mode == "broad_fold_handout":
        broad_fold_count = rng.randint(4, 8)
        crease_count = rng.randint(0, 2)
        wrinkle_count = rng.randint(2, 8)
    else:
        broad_fold_count = rng.randint(3, 6)
        crease_count = rng.randint(1, 4)
        wrinkle_count = rng.randint(8, 18)

    for _ in range(broad_fold_count):
        shadow, highlight, height_delta, strength = paired_broad_fold_fields(
            (height, width),
            random_polyline(width, height, rng, long_fold=True),
            width=rng.uniform(20.0, 58.0),
            transition=rng.uniform(2.5, 8.0),
            amplitude=rng.uniform(8.0, 25.0),
            rng=rng,
        )
        shadow_field += shadow
        highlight_field += highlight
        height_field += height_delta
        crease_strength += strength

    for _ in range(crease_count):
        shadow, highlight, height_delta, strength = paired_crease_fields(
            (height, width),
            random_polyline(width, height, rng, long_fold=True),
            width=rng.uniform(7.0, 17.0),
            transition=rng.uniform(1.1, 3.4),
            amplitude=rng.uniform(11.0, 30.0),
            rng=rng,
        )
        shadow_field += shadow
        highlight_field += highlight
        height_field += height_delta
        crease_strength += strength

    for _ in range(wrinkle_count):
        shadow, highlight, height_delta, strength = paired_crease_fields(
            (height, width),
            random_polyline(width, height, rng, long_fold=False),
            width=rng.uniform(2.8, 7.5),
            transition=rng.uniform(0.65, 1.8),
            amplitude=rng.uniform(5.5, 17.0),
            rng=rng,
        )
        shadow_field += shadow
        highlight_field += highlight
        height_field += height_delta
        crease_strength += strength

    if texture_source is not None:
        texture_shadow, texture_highlight, texture_height, texture_strength = texture_defect_fields(
            texture_source.image,
            (height, width),
            rng,
        )
        texture_mix = rng.uniform(0.28, 0.70)
        shadow_field += texture_shadow * texture_mix
        highlight_field += texture_highlight * texture_mix
        height_field += texture_height * rng.uniform(0.65, 1.15)

    paper_texture = correlated_noise((height, width), rng, sigma=rng.uniform(6.0, 22.0)) * rng.uniform(1.5, 5.5)
    broad_cloud = correlated_noise((height, width), rng, sigma=rng.uniform(36.0, 90.0)) * rng.uniform(3.0, 11.0)

    degraded = apply_displacement(clean_bgr, height_field, rng)
    lab = cv2.cvtColor(degraded, cv2.COLOR_BGR2LAB).astype(np.float32)
    l_channel = lab[:, :, 0]
    l_channel = l_channel - shadow_field + highlight_field + paper_texture + broad_cloud

    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    cx = width * rng.uniform(0.35, 0.65)
    cy = height * rng.uniform(0.35, 0.65)
    radial = np.sqrt(((xx - cx) / width) ** 2 + ((yy - cy) / height) ** 2)
    l_channel -= np.clip((radial - 0.20) * rng.uniform(16.0, 35.0), 0.0, 22.0)

    lab[:, :, 0] = np.clip(l_channel, 0, 255)
    lab[:, :, 1] += rng.uniform(-1.5, 3.5)
    lab[:, :, 2] += rng.uniform(-6.0, 3.0) if rng.random() < 0.55 else rng.uniform(0.0, 6.0)
    degraded = cv2.cvtColor(np.clip(lab, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)

    if rng.random() < 0.55:
        overlay = np.full_like(degraded, (rng.randint(240, 255), rng.randint(232, 248), rng.randint(224, 244)))
        degraded = cv2.addWeighted(degraded, rng.uniform(0.84, 0.94), overlay, rng.uniform(0.06, 0.16), 0.0)

    defect_strength = cv2.GaussianBlur(
        crease_strength + texture_strength * 8.0 + np.abs(height_field) * 0.45,
        (0, 0),
        2.2,
    )
    mask_percentile = 82 if texture_source is not None else 76
    mask_floor = 4.8 if mode == "broad_fold_handout" else 5.8
    defect_mask = (defect_strength > max(mask_floor, float(np.percentile(defect_strength, mask_percentile)))).astype(np.uint8) * 255
    defect_mask = cv2.morphologyEx(defect_mask, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    defect_mask = cv2.morphologyEx(defect_mask, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    shadow_vis = np.clip(defect_strength / max(1e-5, np.percentile(defect_strength, 99)) * 255.0, 0, 255).astype(np.uint8)

    return degraded, defect_mask, shadow_vis


def synthesize_negative_capture(clean_bgr: np.ndarray, rng: random.Random) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Apply camera/paper variation without removable crease defects."""
    height, width = clean_bgr.shape[:2]
    degraded = clean_bgr.copy()
    lab = cv2.cvtColor(degraded, cv2.COLOR_BGR2LAB).astype(np.float32)
    luminance = lab[:, :, 0]
    paper_texture = correlated_noise((height, width), rng, sigma=rng.uniform(8.0, 28.0)) * rng.uniform(1.0, 5.0)
    broad_cloud = correlated_noise((height, width), rng, sigma=rng.uniform(44.0, 140.0)) * rng.uniform(3.0, 12.0)
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    cx = width * rng.uniform(0.35, 0.65)
    cy = height * rng.uniform(0.35, 0.65)
    radial = np.sqrt(((xx - cx) / width) ** 2 + ((yy - cy) / height) ** 2)
    vignette = np.clip((radial - 0.22) * rng.uniform(4.0, 14.0), 0.0, 10.0)
    smooth_bands = np.zeros((height, width), dtype=np.float32)
    for _ in range(rng.randint(1, 3)):
        angle = rng.uniform(-math.pi, math.pi)
        distance = (xx - width * rng.uniform(0.2, 0.8)) * math.cos(angle) + (yy - height * rng.uniform(0.2, 0.8)) * math.sin(angle)
        sigma = rng.uniform(90.0, 240.0)
        band = np.exp(-(distance * distance) / (2.0 * sigma * sigma))
        smooth_bands += band * rng.uniform(-7.0, 7.0)
    lab[:, :, 0] = np.clip(luminance + paper_texture + broad_cloud - vignette, 0, 255)
    lab[:, :, 0] = np.clip(lab[:, :, 0] + smooth_bands, 0, 255)
    lab[:, :, 1] += rng.uniform(-1.5, 2.5)
    lab[:, :, 2] += rng.uniform(-4.0, 5.0)
    degraded = cv2.cvtColor(np.clip(lab, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)
    if rng.random() < 0.35:
        degraded = cv2.GaussianBlur(degraded, (3, 3), 0)
    empty = np.zeros((height, width), dtype=np.uint8)
    return degraded, empty, empty


def make_paths(out_dir: Path, sample_id: str) -> SamplePaths:
    return SamplePaths(
        sample_id=sample_id,
        input_path=out_dir / "images" / "input" / f"{sample_id}.png",
        clean_path=out_dir / "targets" / "clean" / f"{sample_id}.png",
        defect_mask_path=out_dir / "masks" / "defect" / f"{sample_id}.png",
        foreground_mask_path=out_dir / "masks" / "foreground" / f"{sample_id}.png",
        shadow_field_path=out_dir / "fields" / "shadow" / f"{sample_id}.png",
    )


def contact_cell(image: np.ndarray, label: str, width: int = 260, height: int = 360) -> np.ndarray:
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    source_h, source_w = image.shape[:2]
    scale = min(width / source_w, (height - 34) / source_h)
    resized_w = max(1, int(round(source_w * scale)))
    resized_h = max(1, int(round(source_h * scale)))
    resized = cv2.resize(image, (resized_w, resized_h), interpolation=cv2.INTER_AREA)
    canvas = np.full((height, width, 3), 255, dtype=np.uint8)
    x = (width - resized_w) // 2
    y = 30 + (height - 34 - resized_h) // 2
    canvas[y: y + resized_h, x: x + resized_w] = resized
    cv2.putText(canvas, label, (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 180), 1, cv2.LINE_AA)
    return canvas


def write_contact_sheet(out_dir: Path, samples: list[SamplePaths], max_rows: int = 12) -> None:
    rows = []
    for paths in samples[:max_rows]:
        clean = read_image(paths.clean_path)
        degraded = read_image(paths.input_path)
        defect = cv2.imread(str(paths.defect_mask_path), cv2.IMREAD_GRAYSCALE)
        foreground = cv2.imread(str(paths.foreground_mask_path), cv2.IMREAD_GRAYSCALE)
        row = np.concatenate(
            [
                contact_cell(clean, f"{paths.sample_id} clean"),
                contact_cell(degraded, "input"),
                contact_cell(defect, "defect mask"),
                contact_cell(foreground, "foreground"),
            ],
            axis=1,
        )
        rows.append(row)
    if rows:
        write_image(out_dir / "contact-sheet.jpg", np.concatenate(rows, axis=0))


def main() -> None:
    args = parse_args()
    rng = random.Random(args.seed)
    repo_root = Path(__file__).resolve().parent.parent
    out_dir = (repo_root / args.out_dir).resolve()
    width = args.width
    height = args.height

    base_paths = [repo_root / path for path in DEFAULT_BASE_IMAGES]
    base_paths.extend((repo_root / path).resolve() for path in args.base_image)
    bases = [read_image(path) for path in base_paths if path.exists()]
    if not bases:
        raise RuntimeError("No base images found.")

    for subdir in (
        "images/input",
        "targets/clean",
        "masks/defect",
        "masks/foreground",
        "fields/shadow",
        "references",
        "source-textures",
    ):
        (out_dir / subdir).mkdir(parents=True, exist_ok=True)

    texture_sources = load_texture_sources(args.texture_image, repo_root, out_dir)
    texture_ratio = min(1.0, max(0.0, args.texture_ratio))
    procedural_ratio = min(1.0, max(0.0, args.procedural_ratio))
    hard_negative_trap_ratio = min(1.0, max(0.0, args.hard_negative_trap_ratio))
    negative_ratio = min(1.0, max(0.0, args.negative_ratio))

    for reference in REFERENCE_IMAGES:
        source_path = repo_root / reference
        if source_path.exists():
            write_image(out_dir / "references" / source_path.name, read_image(source_path))

    samples: list[SamplePaths] = []
    manifest_rows = []
    modes = ("broad_fold_handout", "folded_handout", "forgot_clear_file", "hybrid")
    for index in range(args.count):
        sample_id = f"synthetic-crease-{index:04d}"
        paths = make_paths(out_dir, sample_id)
        is_negative = rng.random() < negative_ratio
        force_trap_handout = is_negative and rng.random() < hard_negative_trap_ratio
        hard_negative_shapes = force_trap_handout or rng.random() < hard_negative_trap_ratio
        if force_trap_handout or rng.random() < procedural_ratio:
            clean = make_synthetic_handout(width, height, rng, hard_negative_shapes=hard_negative_shapes)
            base_label = "procedural_school_handout_with_traps" if hard_negative_shapes else "procedural_school_handout"
        else:
            base_index = rng.randrange(len(bases))
            clean = fit_to_canvas(bases[base_index], width, height, rng)
            base_label = str(base_paths[base_index].relative_to(repo_root))

        if is_negative:
            mode = "clean_negative"
            degraded, defect_mask, shadow_field = synthesize_negative_capture(clean, rng)
            texture_label = None
        else:
            mode = rng.choice(modes)
            texture_source = None
            if texture_sources and rng.random() < texture_ratio:
                texture_source = rng.choice(texture_sources)
            degraded, defect_mask, shadow_field = synthesize_defects(clean, mode, rng, texture_source)
            texture_label = texture_source.label if texture_source is not None else None
        fg_mask = foreground_mask(clean)

        write_image(paths.clean_path, clean)
        write_image(paths.input_path, degraded)
        write_image(paths.defect_mask_path, defect_mask)
        write_image(paths.foreground_mask_path, fg_mask)
        write_image(paths.shadow_field_path, shadow_field)
        samples.append(paths)
        manifest_rows.append(
            {
                "id": sample_id,
                "mode": mode,
                "base": base_label,
                "input": str(paths.input_path.relative_to(out_dir)),
                "clean_target": str(paths.clean_path.relative_to(out_dir)),
                "defect_mask": str(paths.defect_mask_path.relative_to(out_dir)),
                "foreground_mask": str(paths.foreground_mask_path.relative_to(out_dir)),
                "shadow_field": str(paths.shadow_field_path.relative_to(out_dir)),
                "texture": texture_label,
                "hard_negative_shapes": hard_negative_shapes,
            },
        )

    with (out_dir / "manifest.jsonl").open("w", encoding="utf-8") as handle:
        for row in manifest_rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    readme = {
        "seed": args.seed,
        "count": args.count,
        "size": [width, height],
        "reference_images": [str(Path(path)) for path in REFERENCE_IMAGES],
        "texture_images": args.texture_image,
        "texture_ratio": texture_ratio,
        "procedural_ratio": procedural_ratio,
        "hard_negative_trap_ratio": hard_negative_trap_ratio,
        "negative_ratio": negative_ratio,
        "purpose": "Paired synthetic training data for removable paper crease/wrinkle masks.",
        "notes": [
            "input is the wrinkled document image.",
            "clean_target is the same page before synthetic paper defects were added.",
            "defect_mask marks removable paper defects, not foreground content.",
            "foreground_mask marks text, ruled lines, borders, drawings, and form structure to protect during training.",
        ],
    }
    (out_dir / "dataset.json").write_text(json.dumps(readme, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_contact_sheet(out_dir, samples)
    print(f"Wrote {len(samples)} samples to {out_dir}")
    print(f"Contact sheet: {out_dir / 'contact-sheet.jpg'}")


if __name__ == "__main__":
    main()
