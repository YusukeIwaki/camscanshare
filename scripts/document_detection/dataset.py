from __future__ import annotations

import glob
import math
import random
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from .geometry import mask_from_quad, order_quad
from .seg_model import INPUT_SIZE
from .smartdoc import SmartDocRecord, load_smartdoc_records


def collect_page_pool(models_dir: str | Path | None) -> list[str]:
    if not models_dir:
        return []
    root = Path(models_dir)
    patterns = [
        "02-edited/*.*",
        "01-original/*.*",
        "03-captured-nexus/*.*",
        "**/*.png",
        "**/*.jpg",
        "**/*.jpeg",
    ]
    paths: list[str] = []
    for pattern in patterns:
        paths.extend(str(path) for path in root.glob(pattern) if path.is_file())
    seen: set[str] = set()
    unique: list[str] = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def collect_background_pool(
    train_records: list[SmartDocRecord],
    report_root: str | Path = "report_server/reports",
    include_reports: bool = True,
    stride: int = 12,
) -> list[str]:
    # Use only train split SmartDoc frames here to avoid leaking background05
    # holdout frames into the synthetic training set.
    paths = [str(record.path) for record in train_records[:: max(1, stride)]]
    if include_reports:
        paths.extend(glob.glob(str(Path(report_root) / "report-*" / "source.jpg")))
    random.shuffle(paths)
    return paths


def _fit_square_rgb(image: np.ndarray, size: int, rng: np.random.Generator) -> np.ndarray:
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2RGB)
    h, w = image.shape[:2]
    if h <= 0 or w <= 0:
        return np.full((size, size, 3), 128, dtype=np.uint8)
    scale = size / float(min(h, w))
    resized = cv2.resize(
        image,
        (max(size, int(round(w * scale))), max(size, int(round(h * scale)))),
        interpolation=cv2.INTER_AREA if scale < 1.0 else cv2.INTER_CUBIC,
    )
    rh, rw = resized.shape[:2]
    x0 = int(rng.integers(0, max(1, rw - size + 1)))
    y0 = int(rng.integers(0, max(1, rh - size + 1)))
    return resized[y0 : y0 + size, x0 : x0 + size].copy()


def _procedural_background(rng: np.random.Generator, size: int) -> np.ndarray:
    kind = rng.choice(["desk", "tile", "monitor", "fabric", "floor"])
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    noise = rng.normal(0, 8, (size, size, 1)).astype(np.float32)
    if kind == "desk":
        base = np.array(
            [rng.uniform(105, 175), rng.uniform(75, 135), rng.uniform(45, 95)],
            dtype=np.float32,
        )
        grain = (np.sin(xx / rng.uniform(8, 18)) * 10 + np.sin((xx + yy) / rng.uniform(18, 32)) * 8)[..., None]
        bg = base + grain + noise
    elif kind == "tile":
        base = np.array(
            [rng.uniform(145, 215), rng.uniform(145, 215), rng.uniform(135, 205)],
            dtype=np.float32,
        )
        bg = np.broadcast_to(base, (size, size, 3)).copy() + noise
        gap = int(rng.integers(42, 86))
        for pos in range(int(rng.integers(-gap, gap)), size, gap):
            bg[:, max(0, pos - 1) : min(size, pos + 2)] *= 0.72
            bg[max(0, pos - 1) : min(size, pos + 2), :] *= 0.72
    elif kind == "monitor":
        bg = np.full((size, size, 3), rng.uniform(30, 70), dtype=np.float32) + noise
        for _ in range(int(rng.integers(2, 5))):
            x0, y0 = int(rng.integers(0, size - 60)), int(rng.integers(0, size - 60))
            x1, y1 = int(rng.integers(x0 + 40, size)), int(rng.integers(y0 + 40, size))
            color = rng.uniform(70, 180, 3)
            cv2.rectangle(bg, (x0, y0), (x1, y1), color.tolist(), -1)
    elif kind == "fabric":
        base = np.array(
            [rng.uniform(70, 145), rng.uniform(80, 155), rng.uniform(90, 165)],
            dtype=np.float32,
        )
        weave = ((np.sin(xx / 6) + np.sin(yy / 7)) * 7)[..., None]
        bg = base + weave + noise
    else:
        base = np.array(
            [rng.uniform(120, 190), rng.uniform(115, 175), rng.uniform(100, 155)],
            dtype=np.float32,
        )
        bg = base + ((xx + yy) / (2 * size) * rng.uniform(-35, 35))[..., None] + noise
    return np.clip(bg, 0, 255).astype(np.uint8)


def _load_background(background_paths: list[str], rng: np.random.Generator, size: int) -> np.ndarray:
    if background_paths and rng.random() < 0.72:
        for _ in range(4):
            image = cv2.imread(str(rng.choice(background_paths)))
            if image is not None:
                rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
                return _fit_square_rgb(rgb, size, rng)
    return _procedural_background(rng, size)


def _random_quad(
    rng: np.random.Generator,
    size: int,
    mode: str,
    central_bias: bool = False,
) -> np.ndarray:
    if mode == "full":
        scale_w = rng.uniform(0.96, 1.36)
        scale_h = rng.uniform(0.96, 1.36)
        margin = -0.18
        jitter_ratio = 0.055
        angle_range = 0.13
    elif mode == "edge":
        scale_w = rng.uniform(0.72, 1.16)
        scale_h = rng.uniform(0.72, 1.16)
        margin = -0.08
        jitter_ratio = 0.12
        angle_range = 0.27
    elif mode == "distractor":
        scale_w = rng.uniform(0.28, 0.68)
        scale_h = rng.uniform(0.28, 0.68)
        margin = -0.02
        jitter_ratio = 0.16
        angle_range = 0.55
    else:
        scale_w = rng.uniform(0.42, 0.82)
        scale_h = rng.uniform(0.42, 0.82)
        margin = 0.06
        jitter_ratio = 0.15
        angle_range = 0.42

    aspect = rng.uniform(0.62, 0.82) if rng.random() < 0.72 else rng.uniform(1.15, 1.55)
    if aspect < 1.0:
        box_h = scale_h * size
        box_w = box_h * aspect
    else:
        box_w = scale_w * size
        box_h = box_w / aspect
    box_w = min(box_w, scale_w * size)
    box_h = min(box_h, scale_h * size)

    def choose_center(box: float) -> float:
        if central_bias:
            return float(np.clip(rng.normal(size * 0.5, size * 0.10), box * 0.35, size - box * 0.35))
        lo = box / 2 + margin * size
        hi = size - box / 2 - margin * size
        if hi <= lo:
            return size / 2
        return float(rng.uniform(lo, hi))

    cx = choose_center(box_w)
    cy = choose_center(box_h)
    quad = np.array(
        [
            [cx - box_w / 2, cy - box_h / 2],
            [cx + box_w / 2, cy - box_h / 2],
            [cx + box_w / 2, cy + box_h / 2],
            [cx - box_w / 2, cy + box_h / 2],
        ],
        dtype=np.float32,
    )
    jitter = jitter_ratio * min(box_w, box_h)
    quad += rng.uniform(-jitter, jitter, size=quad.shape).astype(np.float32)
    angle = float(rng.uniform(-angle_range, angle_range))
    rot = np.array([[math.cos(angle), -math.sin(angle)], [math.sin(angle), math.cos(angle)]], dtype=np.float32)
    center = quad.mean(axis=0)
    quad = (quad - center) @ rot.T + center
    if mode == "normal":
        quad[:, 0] = np.clip(quad[:, 0], 2, size - 2)
        quad[:, 1] = np.clip(quad[:, 1], 2, size - 2)
    else:
        quad[:, 0] = np.clip(quad[:, 0], -0.45 * size, 1.45 * size)
        quad[:, 1] = np.clip(quad[:, 1], -0.45 * size, 1.45 * size)
    return order_quad(quad)


def _make_procedural_page(rng: np.random.Generator, low_contrast_rgb: np.ndarray | None = None) -> np.ndarray:
    ph = int(rng.integers(440, 760))
    pw = int(rng.integers(320, 560))
    if low_contrast_rgb is None:
        base = np.array([rng.uniform(225, 255), rng.uniform(225, 255), rng.uniform(220, 252)], dtype=np.float32)
    else:
        base = np.clip(low_contrast_rgb.astype(np.float32) + rng.uniform(10, 34, 3), 165, 246)
    page = np.broadcast_to(base, (ph, pw, 3)).copy()
    page += rng.normal(0, 2.5, page.shape).astype(np.float32)

    ink_base = int(rng.integers(20, 95))
    line_count = int(rng.integers(8, 26))
    for _ in range(line_count):
        y = int(rng.integers(28, ph - 22))
        x0 = int(rng.integers(18, max(20, pw // 3)))
        x1 = int(rng.integers(max(x0 + 18, pw // 2), pw - 12))
        color = int(np.clip(ink_base + rng.normal(0, 22), 0, 145))
        cv2.line(page, (x0, y), (x1, y), (color, color, color), int(rng.integers(1, 4)), cv2.LINE_AA)
    if rng.random() < 0.45:
        for _ in range(int(rng.integers(1, 4))):
            x0 = int(rng.integers(20, pw - 120))
            y0 = int(rng.integers(35, ph - 100))
            x1 = int(rng.integers(x0 + 60, min(pw - 15, x0 + 190)))
            y1 = int(rng.integers(y0 + 45, min(ph - 15, y0 + 170)))
            cv2.rectangle(page, (x0, y0), (x1, y1), (rng.uniform(80, 180),) * 3, 1, cv2.LINE_AA)
            rows = int(rng.integers(2, 5))
            cols = int(rng.integers(2, 5))
            for row in range(1, rows):
                yy = y0 + (y1 - y0) * row // rows
                cv2.line(page, (x0, yy), (x1, yy), (rng.uniform(100, 185),) * 3, 1, cv2.LINE_AA)
            for col in range(1, cols):
                xx = x0 + (x1 - x0) * col // cols
                cv2.line(page, (xx, y0), (xx, y1), (rng.uniform(100, 185),) * 3, 1, cv2.LINE_AA)
    if rng.random() < 0.25:
        color = tuple(float(v) for v in rng.uniform([120, 25, 25], [210, 80, 90]))
        center = (int(rng.integers(pw // 3, pw * 2 // 3)), int(rng.integers(ph // 3, ph * 2 // 3)))
        cv2.ellipse(page, center, (int(rng.integers(35, 80)), int(rng.integers(18, 55))), rng.uniform(0, 180), 0, 360, color, 2)
    return np.clip(page, 0, 255).astype(np.uint8)


def _load_page(page_pool: list[str], rng: np.random.Generator, low_contrast_rgb: np.ndarray | None = None) -> np.ndarray:
    if page_pool and rng.random() < 0.68:
        for _ in range(4):
            image = cv2.imread(str(rng.choice(page_pool)))
            if image is None:
                continue
            rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
            if low_contrast_rgb is not None:
                tint = np.broadcast_to(
                    np.clip(low_contrast_rgb.astype(np.float32) + rng.uniform(16, 42, 3), 170, 248),
                    rgb.shape,
                )
                gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
                rgb = tint * 0.72 + gray[..., None] * 0.28
            return np.clip(rgb, 0, 255).astype(np.uint8)
    return _make_procedural_page(rng, low_contrast_rgb)


def _composite_page(
    canvas: np.ndarray,
    page: np.ndarray,
    quad: np.ndarray,
    rng: np.random.Generator,
    mask_out: np.ndarray | None,
    alpha_scale: float = 1.0,
) -> tuple[np.ndarray, np.ndarray | None]:
    size = canvas.shape[0]
    ph, pw = page.shape[:2]
    src = np.array([[0, 0], [pw - 1, 0], [pw - 1, ph - 1], [0, ph - 1]], dtype=np.float32)
    homography = cv2.getPerspectiveTransform(src, quad.astype(np.float32))
    warped = cv2.warpPerspective(page.astype(np.float32), homography, (size, size), borderValue=0)
    alpha = cv2.warpPerspective(
        np.ones((ph, pw), dtype=np.float32),
        homography,
        (size, size),
        flags=cv2.INTER_NEAREST,
        borderValue=0,
    )
    alpha = np.clip(alpha * alpha_scale, 0.0, 1.0)
    warped *= rng.uniform(0.76, 1.10)
    out = warped * alpha[..., None] + canvas.astype(np.float32) * (1.0 - alpha[..., None])
    out = np.clip(out, 0, 255).astype(np.uint8)
    if mask_out is not None:
        mask = (alpha > 0.5).astype(np.uint8) * 255
        mask_out = np.maximum(mask_out, mask)
    return out, mask_out


def _apply_shadow_and_occluders(
    image: np.ndarray,
    rng: np.random.Generator,
    page_mask: np.ndarray | None = None,
) -> np.ndarray:
    size = image.shape[0]
    out = image.astype(np.float32)
    if rng.random() < 0.58:
        shadow = np.ones((size, size), dtype=np.float32)
        start = (int(rng.integers(-size // 4, size)), int(rng.integers(0, size)))
        end = (int(start[0] + rng.integers(-size // 2, size // 2)), int(rng.integers(0, size)))
        cv2.line(shadow, start, end, float(rng.uniform(0.48, 0.82)), int(rng.integers(size // 5, size // 2)))
        shadow = cv2.GaussianBlur(shadow, (0, 0), float(rng.uniform(10, 34)))
        out *= shadow[..., None]

    if rng.random() < 0.34:
        overlay = out.copy()
        for _ in range(int(rng.integers(1, 4))):
            if page_mask is not None and page_mask.any() and rng.random() < 0.70:
                ys, xs = np.where(page_mask > 0)
                pick = int(rng.integers(0, len(xs)))
                center = (int(xs[pick]), int(ys[pick]))
            else:
                center = (int(rng.integers(0, size)), int(rng.integers(0, size)))
            axes = (int(rng.integers(18, 58)), int(rng.integers(34, 96)))
            skin = tuple(float(v) for v in rng.uniform([125, 82, 58], [226, 178, 135]))
            cv2.ellipse(overlay, center, axes, float(rng.uniform(0, 180)), 0, 360, skin, -1, cv2.LINE_AA)
        out = overlay

    if rng.random() < 0.18:
        # Clear plastic folder tint crossing the page and nearby background.
        tint_mask = np.zeros((size, size), dtype=np.float32)
        quad = _random_quad(rng, size, "edge")
        center = quad.mean(axis=0)
        quad = (quad - center) * rng.uniform(1.05, 1.35) + center
        cv2.fillConvexPoly(tint_mask, np.round(quad).astype(np.int32), 1.0)
        tint_mask = cv2.GaussianBlur(tint_mask, (0, 0), 4.0)
        tint = np.array([rng.uniform(190, 230), rng.uniform(220, 250), rng.uniform(228, 255)], dtype=np.float32)
        strength = rng.uniform(0.10, 0.26)
        out = out * (1.0 - tint_mask[..., None] * strength) + tint * (tint_mask[..., None] * strength)
    return np.clip(out, 0, 255).astype(np.uint8)


def _jpeg_roundtrip(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    quality = int(rng.integers(38, 88))
    ok, encoded = cv2.imencode(".jpg", cv2.cvtColor(image, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        return image
    decoded = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
    return cv2.cvtColor(decoded, cv2.COLOR_BGR2RGB)


def _photometric_augment(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    out = image.astype(np.float32)
    out *= rng.uniform(0.72, 1.22)
    out += rng.uniform(-18, 18)
    if rng.random() < 0.55:
        # Color temperature shift in RGB.
        temp = rng.uniform(-0.16, 0.16)
        gains = np.array([1.0 + temp, 1.0, 1.0 - temp], dtype=np.float32)
        out *= gains
    if rng.random() < 0.40:
        gamma = rng.uniform(0.75, 1.35)
        out = 255.0 * np.power(np.clip(out, 0, 255) / 255.0, gamma)
    if rng.random() < 0.38:
        sigma = float(rng.uniform(0.6, 2.1))
        out = cv2.GaussianBlur(out, (0, 0), sigma)
    if rng.random() < 0.48:
        out += rng.normal(0, rng.uniform(2.0, 10.0), out.shape).astype(np.float32)
    out = np.clip(out, 0, 255).astype(np.uint8)
    if rng.random() < 0.42:
        out = _jpeg_roundtrip(out, rng)
    return out


def _maybe_flip(image: np.ndarray, mask: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    if rng.random() < 0.5:
        return image[:, ::-1].copy(), mask[:, ::-1].copy()
    return image, mask


def synth_hard_negative(
    background_paths: list[str],
    rng: np.random.Generator,
    size: int = INPUT_SIZE,
) -> tuple[np.ndarray, np.ndarray]:
    image = _load_background(background_paths, rng, size).astype(np.float32)
    for _ in range(int(rng.integers(2, 7))):
        quad = _random_quad(rng, size, "distractor")
        color_kind = rng.choice(["table", "monitor", "frame", "tile"])
        if color_kind == "monitor":
            fill = rng.uniform([20, 24, 28], [72, 86, 105]).astype(np.float32)
            edge = rng.uniform([90, 90, 95], [190, 190, 205]).astype(np.float32)
        elif color_kind == "frame":
            fill = rng.uniform([145, 100, 60], [220, 175, 115]).astype(np.float32)
            edge = rng.uniform([60, 40, 25], [120, 90, 65]).astype(np.float32)
        elif color_kind == "tile":
            fill = rng.uniform([130, 135, 130], [210, 210, 205]).astype(np.float32)
            edge = fill * rng.uniform(0.55, 0.78)
        else:
            fill = rng.uniform([80, 60, 38], [170, 135, 95]).astype(np.float32)
            edge = fill * rng.uniform(0.55, 0.85)
        cv2.fillConvexPoly(image, np.round(quad).astype(np.int32), fill.tolist(), cv2.LINE_AA)
        cv2.polylines(image, [np.round(quad).astype(np.int32)], True, edge.tolist(), int(rng.integers(2, 6)), cv2.LINE_AA)
        if color_kind == "frame":
            inner = (quad - quad.mean(axis=0)) * rng.uniform(0.72, 0.86) + quad.mean(axis=0)
            cv2.fillConvexPoly(image, np.round(inner).astype(np.int32), rng.uniform(55, 145, 3).tolist(), cv2.LINE_AA)
    image = _apply_shadow_and_occluders(np.clip(image, 0, 255).astype(np.uint8), rng)
    image = _photometric_augment(image, rng)
    return image, np.zeros((size, size), dtype=np.uint8)


def synth_positive(
    background_paths: list[str],
    page_pool: list[str],
    rng: np.random.Generator,
    size: int = INPUT_SIZE,
) -> tuple[np.ndarray, np.ndarray]:
    image = _load_background(background_paths, rng, size)
    mask = np.zeros((size, size), dtype=np.uint8)
    low_contrast = rng.random() < 0.24
    bg_mean = image.reshape(-1, 3).mean(axis=0)

    if rng.random() < 0.34:
        for _ in range(int(rng.integers(1, 4))):
            page = _load_page(page_pool, rng, None)
            quad = _random_quad(rng, size, "distractor")
            page = (page.astype(np.float32) * rng.uniform(0.82, 1.04) + rng.uniform(-20, 10)).clip(0, 255).astype(np.uint8)
            image, _ = _composite_page(image, page, quad, rng, None, alpha_scale=rng.uniform(0.88, 1.0))

    mode = str(rng.choice(["normal", "edge", "full"], p=[0.44, 0.32, 0.24]))
    page = _load_page(page_pool, rng, bg_mean if low_contrast else None)
    quad = _random_quad(rng, size, mode, central_bias=True)
    image, mask = _composite_page(image, page, quad, rng, mask)
    image = _apply_shadow_and_occluders(image, rng, mask)
    image = _photometric_augment(image, rng)
    return image, mask


def _augment_real(image: np.ndarray, mask: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    image, mask = _maybe_flip(image, mask, rng)
    image = _apply_shadow_and_occluders(image, rng, mask if rng.random() < 0.25 else None) if rng.random() < 0.22 else image
    image = _photometric_augment(image, rng)
    return image, mask


class DetectionDataset(Dataset):
    def __init__(
        self,
        smartdoc_records: list[SmartDocRecord],
        background_paths: list[str],
        page_pool: list[str],
        synth_ratio: float = 0.62,
        hard_negative_ratio: float = 0.18,
        size: int = INPUT_SIZE,
        train: bool = True,
        length: int | None = None,
    ):
        self.records = smartdoc_records
        self.background_paths = background_paths
        self.page_pool = page_pool
        self.synth_ratio = float(synth_ratio if train else 0.0)
        self.hard_negative_ratio = float(hard_negative_ratio)
        self.size = int(size)
        self.train = train
        self._len = int(length or max(1, len(smartdoc_records)))

    def __len__(self) -> int:
        return self._len

    def _rng(self, index: int) -> np.random.Generator:
        worker_seed = random.randint(0, 2**31 - 1) if self.train else 0
        seed = (index * 2654435761 + worker_seed) & 0xFFFFFFFF
        return np.random.default_rng(seed)

    def _load_real(self, index: int, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
        if not self.records:
            return synth_positive(self.background_paths, self.page_pool, rng, self.size)
        record = self.records[index % len(self.records)]
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            return np.full((self.size, self.size, 3), 128, dtype=np.uint8), np.zeros((self.size, self.size), dtype=np.uint8)
        h, w = bgr.shape[:2]
        mask = mask_from_quad(record.quad, h, w)
        image = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)

        if self.train and rng.random() < 0.46:
            x0, y0 = record.quad[:, 0].min(), record.quad[:, 1].min()
            x1, y1 = record.quad[:, 0].max(), record.quad[:, 1].max()
            bw, bh = max(2.0, x1 - x0), max(2.0, y1 - y0)
            pads = rng.uniform(-0.15, 0.38, size=4)
            cx0 = int(np.clip(x0 - pads[0] * bw, 0, w - 2))
            cx1 = int(np.clip(x1 + pads[1] * bw, cx0 + 2, w))
            cy0 = int(np.clip(y0 - pads[2] * bh, 0, h - 2))
            cy1 = int(np.clip(y1 + pads[3] * bh, cy0 + 2, h))
            if cx1 - cx0 >= 32 and cy1 - cy0 >= 32:
                image = image[cy0:cy1, cx0:cx1]
                mask = mask[cy0:cy1, cx0:cx1]

        image = cv2.resize(image, (self.size, self.size), interpolation=cv2.INTER_AREA)
        mask = cv2.resize(mask, (self.size, self.size), interpolation=cv2.INTER_NEAREST)
        if self.train:
            image, mask = _augment_real(image, mask, rng)
        return image, mask

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        rng = self._rng(index)
        use_synth = self.train and self.synth_ratio > 0 and rng.random() < self.synth_ratio
        if use_synth:
            if rng.random() < self.hard_negative_ratio:
                image, mask = synth_hard_negative(self.background_paths, rng, self.size)
            else:
                image, mask = synth_positive(self.background_paths, self.page_pool, rng, self.size)
        else:
            image, mask = self._load_real(index, rng)

        image = np.ascontiguousarray(image)
        mask = np.ascontiguousarray(mask)
        image_t = torch.from_numpy(image).permute(2, 0, 1).float().div(255.0)
        mask_t = torch.from_numpy(mask).unsqueeze(0).float().div(255.0)
        return image_t, mask_t


__all__ = [
    "INPUT_SIZE",
    "DetectionDataset",
    "collect_background_pool",
    "collect_page_pool",
    "load_smartdoc_records",
    "synth_hard_negative",
    "synth_positive",
]

