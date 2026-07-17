from __future__ import annotations

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset


def targets_from_mask(mask: np.ndarray, boundary_width: int = 3) -> tuple[np.ndarray, float, float]:
    binary = (np.asarray(mask) >= 0.5).astype(np.uint8)
    height, width = binary.shape[-2:]
    area_ratio = float(np.count_nonzero(binary)) / max(1.0, float(height * width))
    present = float(area_ratio >= 0.008)
    margin = max(1, min(height, width) // 100)
    touches_border = bool(
        binary[:margin, :].any()
        or binary[-margin:, :].any()
        or binary[:, :margin].any()
        or binary[:, -margin:].any()
    )
    fully_visible = float(bool(present) and not touches_border)
    if not present:
        return np.zeros_like(binary, dtype=np.float32), present, fully_visible
    radius = max(1, int(boundary_width))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1))
    dilated = cv2.dilate(binary, kernel)
    eroded = cv2.erode(binary, kernel)
    boundary = (dilated - eroded).astype(np.float32)
    return boundary, present, fully_visible


class BoundaryHeadDataset(Dataset):
    def __init__(self, base: Dataset, boundary_width: int = 3):
        self.base = base
        self.boundary_width = int(boundary_width)

    def __len__(self) -> int:
        return len(self.base)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
        image, mask = self.base[index]
        boundary, present, fully_visible = targets_from_mask(
            mask.squeeze(0).numpy(),
            self.boundary_width,
        )
        targets = {
            "mask": mask,
            "boundary": torch.from_numpy(boundary).unsqueeze(0),
            "present": torch.tensor(present, dtype=torch.float32),
            "fully_visible": torch.tensor(fully_visible, dtype=torch.float32),
        }
        return image, targets
