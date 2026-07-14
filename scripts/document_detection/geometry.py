from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np


def order_quad(points: np.ndarray) -> np.ndarray:
    """Return points ordered clockwise as TL, TR, BR, BL."""
    pts = np.asarray(points, dtype=np.float32).reshape(4, 2)
    center = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - center[1], pts[:, 0] - center[0])
    ordered = pts[np.argsort(angles)]
    if cv2.contourArea(ordered.reshape(4, 1, 2), oriented=True) < 0:
        ordered = ordered[::-1]
    start = int(np.argmin(ordered.sum(axis=1)))
    return np.roll(ordered, -start, axis=0).astype(np.float32)


def normalize_quad(points: np.ndarray, width: int, height: int) -> np.ndarray:
    quad = order_quad(points).astype(np.float32)
    scale = np.array([max(1, width), max(1, height)], dtype=np.float32)
    return quad / scale


def denormalize_quad(points: np.ndarray, width: int, height: int) -> np.ndarray:
    quad = order_quad(points).astype(np.float32)
    scale = np.array([max(1, width), max(1, height)], dtype=np.float32)
    return quad * scale


def expand_normalized_quad(points: np.ndarray | None, expansion: float) -> np.ndarray | None:
    if points is None:
        return None
    quad = order_quad(points).astype(np.float32)
    if expansion == 0.0:
        return quad
    center = quad.mean(axis=0, keepdims=True)
    expanded = center + (quad - center) * (1.0 + float(expansion))
    return order_quad(np.clip(expanded, 0.0, 1.0)).astype(np.float32)


def mask_from_quad(points: np.ndarray, height: int, width: int) -> np.ndarray:
    mask = np.zeros((height, width), dtype=np.uint8)
    cv2.fillConvexPoly(mask, np.round(order_quad(points)).astype(np.int32), 255)
    return mask


def mask_from_normalized_quad(points: np.ndarray, size: int) -> np.ndarray:
    mask = np.zeros((size, size), dtype=np.uint8)
    pts = np.asarray(points, dtype=np.float32).copy()
    pts[:, 0] *= size
    pts[:, 1] *= size
    cv2.fillConvexPoly(mask, np.round(order_quad(pts)).astype(np.int32), 1)
    return mask


def poly_iou(quad_a: np.ndarray | None, quad_b: np.ndarray | None, size: int = 320) -> float:
    if quad_a is None or quad_b is None:
        return 0.0
    mask_a = mask_from_normalized_quad(quad_a, size)
    mask_b = mask_from_normalized_quad(quad_b, size)
    inter = np.logical_and(mask_a, mask_b).sum()
    union = np.logical_or(mask_a, mask_b).sum()
    return float(inter / union) if union else 0.0


def draw_quad(
    image: np.ndarray,
    quad: np.ndarray | None,
    color: tuple[int, int, int],
    label: str | None = None,
    normalized: bool = True,
    thickness: int | None = None,
) -> np.ndarray:
    out = image.copy()
    if quad is None:
        if label:
            cv2.putText(out, f"{label}: none", (14, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)
        return out

    h, w = out.shape[:2]
    if normalized:
        pts = denormalize_quad(quad, w, h)
    else:
        pts = order_quad(quad)
    pts_i = np.round(pts).astype(np.int32)
    line_thickness = thickness or max(2, int(round(max(w, h) / 360)))
    cv2.polylines(out, [pts_i], True, color, line_thickness, cv2.LINE_AA)
    for index, (x, y) in enumerate(pts_i):
        cv2.circle(out, (int(x), int(y)), max(3, line_thickness + 1), color, -1, cv2.LINE_AA)
        cv2.putText(
            out,
            str(index),
            (int(x) + 5, int(y) - 5),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            color,
            max(1, line_thickness - 1),
            cv2.LINE_AA,
        )
    if label:
        cv2.putText(out, label, (14, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2, cv2.LINE_AA)
    return out


def resize_for_contact(image: np.ndarray, width: int, height: int) -> np.ndarray:
    h, w = image.shape[:2]
    scale = min(width / max(1, w), height / max(1, h))
    resized = cv2.resize(
        image,
        (max(1, int(round(w * scale))), max(1, int(round(h * scale)))),
        interpolation=cv2.INTER_AREA if scale < 1.0 else cv2.INTER_CUBIC,
    )
    canvas = np.full((height, width, 3), 245, dtype=np.uint8)
    y = (height - resized.shape[0]) // 2
    x = (width - resized.shape[1]) // 2
    canvas[y : y + resized.shape[0], x : x + resized.shape[1]] = resized
    return canvas


def write_contact_sheet(
    images: list[np.ndarray],
    out_path: Path,
    labels: list[str] | None = None,
    cols: int = 4,
    cell_width: int = 420,
    cell_height: int = 260,
) -> None:
    if not images:
        return
    rows = int(np.ceil(len(images) / float(cols)))
    sheet = np.full((rows * cell_height, cols * cell_width, 3), 238, dtype=np.uint8)
    for index, image in enumerate(images):
        r, c = divmod(index, cols)
        cell = resize_for_contact(image, cell_width, cell_height)
        if labels and index < len(labels):
            cv2.rectangle(cell, (0, 0), (cell_width, 28), (255, 255, 255), -1)
            cv2.putText(
                cell,
                labels[index][:70],
                (8, 20),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.52,
                (30, 30, 30),
                1,
                cv2.LINE_AA,
            )
        sheet[
            r * cell_height : (r + 1) * cell_height,
            c * cell_width : (c + 1) * cell_width,
        ] = cell
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(out_path), sheet):
        raise RuntimeError(f"failed to write contact sheet: {out_path}")
