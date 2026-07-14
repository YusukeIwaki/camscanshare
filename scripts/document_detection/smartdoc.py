from __future__ import annotations

import csv
import gzip
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from .geometry import normalize_quad, order_quad


@dataclass(frozen=True)
class SmartDocRecord:
    path: Path
    quad: np.ndarray
    bg_name: str
    model_name: str
    frame_index: int
    model_width: float
    model_height: float

    @property
    def scene_id(self) -> str:
        return f"{self.bg_name}/{self.model_name}"


def metadata_path(frames_dir: str | Path) -> Path:
    frames_path = Path(frames_dir)
    gz_path = frames_path / "metadata.csv.gz"
    if gz_path.exists():
        return gz_path
    csv_path = frames_path / "metadata.csv"
    if csv_path.exists():
        return csv_path
    raise FileNotFoundError(f"SmartDoc metadata not found under {frames_path}")


def load_smartdoc_records(frames_dir: str | Path, holdout_bg: str = "background05") -> tuple[list[SmartDocRecord], list[SmartDocRecord]]:
    """Load SmartDoc frame records and split by background scene.

    SmartDoc metadata stores quad coordinates in the original video frame
    coordinate system. The frame JPEGs in this repo are 1920x1080, and the
    metadata values fall in that same coordinate range. The model_width and
    model_height columns are the physical document model dimensions, not image
    dimensions.
    """
    all_records = load_all_records(frames_dir)
    train = [record for record in all_records if record.bg_name != holdout_bg]
    val = [record for record in all_records if record.bg_name == holdout_bg]
    return train, val


def load_all_records(frames_dir: str | Path) -> list[SmartDocRecord]:
    frames_path = Path(frames_dir)
    meta = metadata_path(frames_path)
    opener = gzip.open if meta.suffix == ".gz" else open
    records: list[SmartDocRecord] = []
    with opener(meta, "rt", newline="") as file:
        reader = csv.DictReader(file)
        for row in reader:
            quad = np.array(
                [
                    [float(row["tl_x"]), float(row["tl_y"])],
                    [float(row["tr_x"]), float(row["tr_y"])],
                    [float(row["br_x"]), float(row["br_y"])],
                    [float(row["bl_x"]), float(row["bl_y"])],
                ],
                dtype=np.float32,
            )
            records.append(
                SmartDocRecord(
                    path=frames_path / row["image_path"],
                    quad=order_quad(quad),
                    bg_name=row["bg_name"],
                    model_name=row["model_name"],
                    frame_index=int(row["frame_index"]),
                    model_width=float(row["model_width"]),
                    model_height=float(row["model_height"]),
                ),
            )
    return records


def normalized_gt_quad(record: SmartDocRecord, image: np.ndarray) -> np.ndarray:
    h, w = image.shape[:2]
    return normalize_quad(record.quad, w, h)


def validate_record_coordinate_space(records: list[SmartDocRecord], sample_count: int = 64) -> dict[str, float]:
    """Return quick coordinate sanity stats for reporting and smoke checks."""
    if not records:
        return {"checked": 0}
    indices = np.linspace(0, len(records) - 1, min(sample_count, len(records)), dtype=int)
    inside_ratios: list[float] = []
    widths: list[int] = []
    heights: list[int] = []
    for index in indices:
        record = records[int(index)]
        image = cv2.imread(str(record.path))
        if image is None:
            continue
        h, w = image.shape[:2]
        widths.append(w)
        heights.append(h)
        q = record.quad
        inside = (
            (q[:, 0] >= 0)
            & (q[:, 0] <= w)
            & (q[:, 1] >= 0)
            & (q[:, 1] <= h)
        )
        inside_ratios.append(float(inside.mean()))
    return {
        "checked": float(len(inside_ratios)),
        "mean_corner_inside_ratio": float(np.mean(inside_ratios)) if inside_ratios else 0.0,
        "median_width": float(np.median(widths)) if widths else 0.0,
        "median_height": float(np.median(heights)) if heights else 0.0,
    }

