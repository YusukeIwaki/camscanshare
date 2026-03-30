from __future__ import annotations

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

A4_PORTRAIT = 210.0 / 297.0
A4_LANDSCAPE = 297.0 / 210.0
A4_TOLERANCE = 0.20


def repo_root_for(script_path: str) -> Path:
    return Path(script_path).resolve().parent.parent


def load_manifest_entries(repo_root: Path, manifest: str, only: list[str]) -> list[dict]:
    manifest_path = (repo_root / manifest).resolve()
    entries = json.loads(manifest_path.read_text())
    selected_ids = set(only)
    if selected_ids:
        entries = [entry for entry in entries if entry["id"] in selected_ids]
    return entries


def read_image(path: Path) -> np.ndarray:
    image = cv2.imread(str(path))
    if image is None:
        raise RuntimeError(f"Failed to read image: {path}")
    return image


def write_image(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok = cv2.imwrite(str(path), image)
    if not ok:
        raise RuntimeError(f"Failed to write image: {path}")


def snap_ratio_to_paper(image_ratio: float, tolerance: float = A4_TOLERANCE) -> float | None:
    portrait_delta = abs(image_ratio / A4_PORTRAIT - 1.0)
    landscape_delta = abs(image_ratio / A4_LANDSCAPE - 1.0)
    best_ratio, best_delta = (
        (A4_PORTRAIT, portrait_delta)
        if portrait_delta <= landscape_delta
        else (A4_LANDSCAPE, landscape_delta)
    )
    if best_delta <= tolerance:
        return best_ratio
    return None


def compute_target_paper_ratio(width: int, height: int) -> float | None:
    if width <= 0 or height <= 0:
        return A4_PORTRAIT
    return snap_ratio_to_paper(width / float(height))


def normalize_document_aspect(
    image: np.ndarray,
    target_ratio: float | None = None,
) -> tuple[np.ndarray, str]:
    height, width = image.shape[:2]
    if target_ratio is None:
        target_ratio = compute_target_paper_ratio(width, height)
    if target_ratio is None:
        return image.copy(), "keep_original_ratio"

    area = width * height
    target_width = max(1, int(round(np.sqrt(area * target_ratio))))
    target_height = max(1, int(round(np.sqrt(area / target_ratio))))

    if target_width == width and target_height == height:
        return image.copy(), "already_close_to_a4"

    interpolation = cv2.INTER_CUBIC if target_width > width or target_height > height else cv2.INTER_AREA
    normalized = cv2.resize(image, (target_width, target_height), interpolation=interpolation)
    orientation = "portrait" if target_ratio == A4_PORTRAIT else "landscape"
    return normalized, f"a4_{orientation}"


def quad_side_lengths(points: np.ndarray) -> tuple[float, float, float, float]:
    rect = order_points(points.reshape(4, 2).astype(np.float32))
    top_left, top_right, bottom_right, bottom_left = rect
    width_top = float(np.linalg.norm(top_right - top_left))
    width_bottom = float(np.linalg.norm(bottom_right - bottom_left))
    height_left = float(np.linalg.norm(bottom_left - top_left))
    height_right = float(np.linalg.norm(bottom_right - top_right))
    return width_top, width_bottom, height_left, height_right


def estimate_quad_paper_ratio(points: np.ndarray) -> float | None:
    width_top, width_bottom, height_left, height_right = quad_side_lengths(points)
    max_width = max(width_top, width_bottom)
    min_width = max(1.0, min(width_top, width_bottom))
    max_height = max(height_left, height_right)
    min_height = max(1.0, min(height_left, height_right))

    observed_ratio = max_width / max_height
    width_skew = max_width / min_width
    height_skew = max_height / min_height
    estimated_ratio = observed_ratio

    # When a portrait page is strongly foreshortened, max-width/max-height drifts
    # toward a square. Prefer the far edge width against the tall edge height.
    if observed_ratio < 1.05 and width_skew > 1.20 and width_skew >= height_skew:
        estimated_ratio = min_width / max_height

    return snap_ratio_to_paper(estimated_ratio)


def resize_for_detection(image: np.ndarray, target_height: int = 500) -> tuple[np.ndarray, float]:
    height, width = image.shape[:2]
    scale = target_height / float(height) if height > target_height else 1.0
    if scale != 1.0:
        resized = cv2.resize(
            image,
            (int(round(width * scale)), int(round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        resized = image.copy()
    ratio = height / float(resized.shape[0])
    return resized, ratio


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


def collect_candidate_quads(mask: np.ndarray, ratio: float, min_area: float) -> list[tuple[np.ndarray, str]]:
    candidates: list[tuple[np.ndarray, str]] = []
    contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:40]:
        area = cv2.contourArea(contour)
        if area < min_area:
            continue
        perimeter = cv2.arcLength(contour, True)
        polygon = cv2.approxPolyDP(contour, 0.02 * perimeter, True)
        if len(polygon) == 4 and cv2.isContourConvex(polygon):
            candidates.append((polygon.reshape(4, 2).astype(np.float32) * ratio, "quad"))
            continue
        rect = cv2.minAreaRect(contour)
        candidates.append((cv2.boxPoints(rect).astype(np.float32) * ratio, "minAreaRect"))
    return candidates


def count_touched_sides(image: np.ndarray, points: np.ndarray) -> int:
    xs = points[:, 0]
    ys = points[:, 1]
    margin_x = image.shape[1] * 0.02
    margin_y = image.shape[0] * 0.02
    return sum(
        [
            np.any(xs < margin_x),
            np.any(xs > image.shape[1] - margin_x),
            np.any(ys < margin_y),
            np.any(ys > image.shape[0] - margin_y),
        ],
    )


def compute_chroma(a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    a32 = a_channel.astype(np.float32) - 128.0
    b32 = b_channel.astype(np.float32) - 128.0
    chroma = np.sqrt(a32 * a32 + b32 * b32)
    return np.clip(chroma, 0, 255).astype(np.uint8)


def build_paper_candidate_mask(resized: np.ndarray) -> np.ndarray:
    lab = cv2.cvtColor(resized, cv2.COLOR_BGR2LAB)
    luminance, a_channel, b_channel = cv2.split(lab)
    chroma = compute_chroma(a_channel, b_channel)
    bright_threshold = max(110, int(np.percentile(luminance, 55)))
    _, bright_mask = cv2.threshold(luminance, bright_threshold, 255, cv2.THRESH_BINARY)
    _, low_chroma_mask = cv2.threshold(chroma, 42, 255, cv2.THRESH_BINARY_INV)
    paper_mask = cv2.bitwise_and(bright_mask, low_chroma_mask)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_OPEN, kernel, iterations=1)
    return paper_mask


def score_candidate(image: np.ndarray, points: np.ndarray) -> float:
    try:
        warped = four_point_transform(image, points)
    except cv2.error:
        return -1.0

    if warped.size == 0:
        return -1.0

    height, width = warped.shape[:2]
    area_ratio = (width * height) / float(image.shape[0] * image.shape[1])
    if area_ratio < 0.08:
        return -1.0

    gray = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY)
    center = gray[height // 6: height * 5 // 6, width // 6: width * 5 // 6]
    border = np.concatenate([
        gray[: max(1, height // 20), :].ravel(),
        gray[-max(1, height // 20):, :].ravel(),
        gray[:, : max(1, width // 20)].ravel(),
        gray[:, -max(1, width // 20):].ravel(),
    ])
    center_mean = float(center.mean()) / 255.0
    border_mean = float(border.mean()) / 255.0
    aspect = max(width, height) / float(max(1, min(width, height)))
    aspect_penalty = 0.0 if aspect < 2.4 else min(1.0, (aspect - 2.4) / 2.0)
    xs = points[:, 0]
    ys = points[:, 1]
    margin_x = image.shape[1] * 0.02
    margin_y = image.shape[0] * 0.02
    edge_touches = float(np.count_nonzero(xs < margin_x) + np.count_nonzero(xs > image.shape[1] - margin_x))
    edge_touches += float(np.count_nonzero(ys < margin_y) + np.count_nonzero(ys > image.shape[0] - margin_y))
    edge_penalty = min(1.8, edge_touches * 0.35)
    return area_ratio * 4.0 + center_mean * 1.8 - (0.35 - border_mean) * 1.2 - aspect_penalty - edge_penalty


def candidate_edge_support(image: np.ndarray, points: np.ndarray) -> float:
    resized, ratio = resize_for_detection(image)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    grad_x = cv2.Sobel(blurred, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(blurred, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = cv2.magnitude(grad_x, grad_y)
    magnitude = cv2.normalize(magnitude, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)

    scaled_points = order_points((points / ratio).astype(np.float32)).astype(np.int32)
    mask = np.zeros_like(gray)
    thickness = max(3, gray.shape[0] // 120)
    for start, end in zip(scaled_points, np.roll(scaled_points, -1, axis=0)):
        cv2.line(mask, tuple(start), tuple(end), 255, thickness=thickness)

    values = magnitude[mask > 0]
    if values.size == 0:
        return 0.0
    return float(values.mean()) / 255.0


def score_detection_candidate(image: np.ndarray, points: np.ndarray, source: str, kind: str) -> float:
    score = score_candidate(image, points)
    if score < 0:
        return score

    score += candidate_edge_support(image, points) * 2.2

    if source == "merged" and kind == "quad":
        return score + 0.15

    if source == "paper" and count_touched_sides(image, points) >= 3:
        return score - 1.6

    return score


def trim_dark_border(image: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    row_ratio = (gray > 18).mean(axis=1)
    col_ratio = (gray > 18).mean(axis=0)

    def find_start(values: np.ndarray) -> int:
        for index, value in enumerate(values):
            if value > 0.65:
                return index
        return 0

    def find_end(values: np.ndarray) -> int:
        for index in range(len(values) - 1, -1, -1):
            if values[index] > 0.65:
                return index + 1
        return len(values)

    top = find_start(row_ratio)
    bottom = find_end(row_ratio)
    left = find_start(col_ratio)
    right = find_end(col_ratio)

    if bottom - top < image.shape[0] * 0.5 or right - left < image.shape[1] * 0.5:
        return image
    return image[top:bottom, left:right]


def largest_component_mask(mask: np.ndarray) -> np.ndarray:
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return mask
    largest = max(contours, key=cv2.contourArea)
    filled = np.zeros_like(mask)
    cv2.drawContours(filled, [largest], -1, 255, thickness=cv2.FILLED)
    return filled


def trim_to_document_bounds(image: np.ndarray) -> np.ndarray:
    mask = build_paper_candidate_mask(image)
    mask = largest_component_mask(mask)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return image
    x, y, w, h = cv2.boundingRect(max(contours, key=cv2.contourArea))
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    p10, p90 = np.percentile(gray, [10, 90])
    border = np.concatenate([
        gray[: max(1, gray.shape[0] // 20), :].ravel(),
        gray[-max(1, gray.shape[0] // 20):, :].ravel(),
        gray[:, : max(1, gray.shape[1] // 20)].ravel(),
        gray[:, -max(1, gray.shape[1] // 20):].ravel(),
    ])
    border_mean = float(border.mean())
    contrast_spread = float(p90 - p10) / 255.0
    conservative_trim = contrast_spread > 0.45 and border_mean < 180.0
    low_contrast_trim = contrast_spread < 0.20
    pad_ratio = 0.04 if low_contrast_trim else 0.02
    pad_x = int(round(w * pad_ratio))
    pad_y = int(round(h * pad_ratio))
    left = max(0, x - pad_x)
    top = max(0, y - pad_y)
    right = min(image.shape[1], x + w + pad_x)
    bottom = min(image.shape[0], y + h + pad_y)
    trimmed_width_ratio = (right - left) / float(image.shape[1])
    trimmed_height_ratio = (bottom - top) / float(image.shape[0])
    trim_ratios = (
        left / float(image.shape[1]),
        (image.shape[1] - right) / float(image.shape[1]),
        top / float(image.shape[0]),
        (image.shape[0] - bottom) / float(image.shape[0]),
    )
    min_keep_ratio = 0.90 if conservative_trim else 0.82
    max_side_trim = 0.08 if conservative_trim else 0.15
    if right - left < image.shape[1] * 0.5 or bottom - top < image.shape[0] * 0.5:
        return image
    if low_contrast_trim and border_mean > 175.0 and max(trim_ratios) > 0.10:
        return image
    if (
        trimmed_width_ratio < min_keep_ratio
        or trimmed_height_ratio < min_keep_ratio
        or max(trim_ratios) > max_side_trim
    ):
        return image
    return image[top:bottom, left:right]


def find_document_candidate(image: np.ndarray, crop_mode: str | None = None) -> dict[str, object] | None:
    if crop_mode == "copy_source":
        return {
            "points": None,
            "source": "copy_source",
            "kind": "copy_source",
        }

    resized, ratio = resize_for_detection(image)
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
    min_area = resized.shape[0] * resized.shape[1] * 0.15
    paper_mask = build_paper_candidate_mask(resized)

    candidates: list[dict[str, object]] = []

    for source, mask in (("merged", merged), ("paper", paper_mask)):
        for points, kind in collect_candidate_quads(mask, ratio, min_area):
            score = score_detection_candidate(image, points, source, kind)
            if score < 0:
                continue
            candidates.append(
                {
                    "points": points,
                    "source": source,
                    "kind": kind,
                    "score": score,
                },
            )

    if candidates:
        return max(candidates, key=lambda candidate: float(candidate["score"]))

    contours, _ = cv2.findContours(merged, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None

    fallback = max(contours, key=cv2.contourArea)
    rect = cv2.minAreaRect(fallback)
    points = cv2.boxPoints(rect).astype(np.float32) * ratio
    return {
        "points": points,
        "source": "fallback_source",
        "kind": "minAreaRect",
    }


def detect_document(image: np.ndarray, crop_mode: str | None = None) -> tuple[np.ndarray, str]:
    candidate = find_document_candidate(image, crop_mode)
    if candidate is None:
        return image.copy(), "fallback_source"
    points = candidate["points"]
    if points is None:
        return image.copy(), str(candidate["source"])

    warped = trim_dark_border(four_point_transform(image, points))
    return trim_to_document_bounds(warped), str(candidate["source"])


def estimate_document_paper_ratio(image: np.ndarray, crop_mode: str | None = None) -> float | None:
    candidate = find_document_candidate(image, crop_mode)
    if candidate is None:
        return compute_target_paper_ratio(image.shape[1], image.shape[0])

    points = candidate["points"]
    if points is None:
        return compute_target_paper_ratio(image.shape[1], image.shape[0])

    return estimate_quad_paper_ratio(points)


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

    kernel_side = max(15, int(round(min(working.shape[1], working.shape[0]) / 24.0)))
    if kernel_side % 2 == 0:
        kernel_side += 1
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_side, kernel_side))
    closed = cv2.morphologyEx(working, cv2.MORPH_CLOSE, kernel)
    sigma = max(12.0, min(80.0, min(working.shape[1], working.shape[0]) / 18.0))
    blurred = cv2.GaussianBlur(closed, (0, 0), sigmaX=sigma, sigmaY=sigma)

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
    black_point = find_percentile(histogram, total_pixels, 0.005)
    white_point = max(black_point + 1, find_percentile(histogram, total_pixels, 0.995))

    clipped = np.minimum(luminance, white_point).astype(np.float32)
    stretched = (clipped - float(black_point)) * (255.0 / float(white_point - black_point))
    return np.clip(stretched, 0, 255).astype(np.uint8)


def build_paper_mask(luminance: np.ndarray, a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    chroma = compute_chroma(a_channel, b_channel)
    bright_threshold = max(96, int(np.percentile(luminance, 18)))
    _, bright_mask = cv2.threshold(luminance, bright_threshold, 255, cv2.THRESH_BINARY)
    _, low_chroma_mask = cv2.threshold(chroma, 34, 255, cv2.THRESH_BINARY_INV)
    paper_mask = cv2.bitwise_and(bright_mask, low_chroma_mask)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    paper_mask = cv2.morphologyEx(paper_mask, cv2.MORPH_OPEN, kernel)
    return paper_mask


def build_accent_mask(luminance: np.ndarray, a_channel: np.ndarray, b_channel: np.ndarray) -> np.ndarray:
    chroma = compute_chroma(a_channel, b_channel)
    _, strong_chroma_mask = cv2.threshold(chroma, 28, 255, cv2.THRESH_BINARY)
    _, visible_mask = cv2.threshold(luminance, 48, 255, cv2.THRESH_BINARY)
    accent_mask = cv2.bitwise_and(strong_chroma_mask, visible_mask)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    return cv2.morphologyEx(accent_mask, cv2.MORPH_OPEN, kernel)


def build_structure_mask(luminance: np.ndarray) -> np.ndarray:
    adaptive = cv2.adaptiveThreshold(
        luminance,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        31,
        9,
    )
    _, dark = cv2.threshold(
        luminance,
        max(72, int(np.percentile(luminance, 10))),
        255,
        cv2.THRESH_BINARY_INV,
    )
    structure = cv2.bitwise_or(adaptive, dark)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    structure = cv2.morphologyEx(structure, cv2.MORPH_OPEN, kernel)
    structure = cv2.dilate(structure, kernel, iterations=2)
    return structure


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
    structure_mask = build_structure_mask(denoised_l)
    paper_mask = cv2.bitwise_and(paper_mask, cv2.bitwise_not(structure_mask))
    paper_mask = cv2.morphologyEx(
        paper_mask,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)),
        iterations=2,
    )
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

    output_l = blend_toward_value(denoised_l, paper_mask, 244.0, 0.34)
    output_l = cv2.addWeighted(output_l, 0.58, denoised_l, 0.42, 0.0)
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


def apply_brightness(image: np.ndarray, value: float) -> np.ndarray:
    offset = 255.0 * (value - 1.0)
    result = image.astype(np.float32) + offset
    return np.clip(result, 0, 255).astype(np.uint8)


def apply_contrast(image: np.ndarray, value: float) -> np.ndarray:
    offset = 128.0 * (1.0 - value)
    result = image.astype(np.float32) * value + offset
    return np.clip(result, 0, 255).astype(np.uint8)


def apply_grayscale(image: np.ndarray, _value: float) -> np.ndarray:
    b, g, r = cv2.split(image)
    gray = (
        r.astype(np.float32) * 0.2127
        + g.astype(np.float32) * 0.7151
        + b.astype(np.float32) * 0.0722
    )
    gray = np.clip(gray, 0, 255).astype(np.uint8)
    return cv2.merge([gray, gray, gray])


def apply_saturate(image: np.ndarray, value: float) -> np.ndarray:
    if value == 0.0:
        return apply_grayscale(image, 1.0)

    rw, gw, bw = 0.2127, 0.7151, 0.0722
    b_ch, g_ch, r_ch = (
        image[:, :, 0].astype(np.float32),
        image[:, :, 1].astype(np.float32),
        image[:, :, 2].astype(np.float32),
    )

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
    spec = FILTERS[filter_key]
    result = image.copy()
    for op_name, op_value in spec["ops"]:
        result = OP_DISPATCH[op_name](result, op_value)
    return result
