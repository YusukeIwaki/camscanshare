from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


INPUT_SIZE = 320
PAGESEG_MIN_COMPONENT_MEAN = 0.55


@dataclass(frozen=True)
class MaskQuadInfo:
    quad: np.ndarray | None = None
    mask_area_ratio: float = 0.0
    component_mean_probability: float = 0.0


class ConvBNAct(nn.Sequential):
    def __init__(self, in_ch: int, out_ch: int, kernel_size: int = 3):
        padding = kernel_size // 2
        super().__init__(
            nn.Conv2d(in_ch, out_ch, kernel_size, padding=padding, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.Hardswish(inplace=True),
        )


class SepConvBNAct(nn.Sequential):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__(
            nn.Conv2d(in_ch, in_ch, 3, padding=1, groups=in_ch, bias=False),
            nn.BatchNorm2d(in_ch),
            nn.Hardswish(inplace=True),
            nn.Conv2d(in_ch, out_ch, 1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.Hardswish(inplace=True),
        )


class UpBlock(nn.Module):
    def __init__(self, in_ch: int, skip_ch: int, out_ch: int):
        super().__init__()
        self.fuse = nn.Sequential(
            SepConvBNAct(in_ch + skip_ch, out_ch),
            SepConvBNAct(out_ch, out_ch),
        )

    def forward(self, x: torch.Tensor, skip: torch.Tensor) -> torch.Tensor:
        x = F.interpolate(x, size=skip.shape[-2:], mode="bilinear", align_corners=False)
        return self.fuse(torch.cat([x, skip], dim=1))


class PageSegNet(nn.Module):
    """MobileNetV3-Small encoder + lightweight U-Net decoder.

    Input is NCHW RGB in [0, 1]. Output is a single-channel logit mask by
    default; set include_sigmoid=True for export graphs that directly emit
    probabilities.
    """

    def __init__(self, pretrained: bool = True, include_sigmoid: bool = False):
        super().__init__()
        from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

        weights = None
        if pretrained:
            try:
                weights = MobileNet_V3_Small_Weights.DEFAULT
            except Exception:
                weights = None
        try:
            backbone = mobilenet_v3_small(weights=weights)
        except Exception as exc:
            print(f"warning: failed to load MobileNetV3 pretrained weights ({exc}); using random init")
            backbone = mobilenet_v3_small(weights=None)

        self.encoder = backbone.features
        self.include_sigmoid = include_sigmoid
        self.center = ConvBNAct(576, 160, kernel_size=1)
        self.up3 = UpBlock(160, 48, 96)
        self.up2 = UpBlock(96, 24, 64)
        self.up1 = UpBlock(64, 16, 40)
        self.up0 = UpBlock(40, 16, 24)
        self.refine = SepConvBNAct(24, 24)
        self.head = nn.Conv2d(24, 1, 1)

        mean = torch.tensor([0.485, 0.456, 0.406], dtype=torch.float32).view(1, 3, 1, 1)
        std = torch.tensor([0.229, 0.224, 0.225], dtype=torch.float32).view(1, 3, 1, 1)
        self.register_buffer("mean", mean)
        self.register_buffer("std", std)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = (x - self.mean) / self.std
        skips: dict[str, torch.Tensor] = {}
        y = x
        for index, layer in enumerate(self.encoder):
            y = layer(y)
            if index == 0:
                skips["s0"] = y      # 1/2, 16ch
            elif index == 1:
                skips["s1"] = y      # 1/4, 16ch
            elif index == 3:
                skips["s2"] = y      # 1/8, 24ch
            elif index == 8:
                skips["s3"] = y      # 1/16, 48ch

        y = self.center(y)           # 1/32, 160ch
        y = self.up3(y, skips["s3"])
        y = self.up2(y, skips["s2"])
        y = self.up1(y, skips["s1"])
        y = self.up0(y, skips["s0"])
        y = F.interpolate(y, size=x.shape[-2:], mode="bilinear", align_corners=False)
        y = self.refine(y)
        logits = self.head(y)
        return torch.sigmoid(logits) if self.include_sigmoid else logits


def count_parameters(model: nn.Module) -> int:
    return sum(param.numel() for param in model.parameters())


def load_checkpoint_state(path: str | Path) -> dict[str, Any]:
    checkpoint = torch.load(path, map_location="cpu")
    if isinstance(checkpoint, dict) and "model_state" in checkpoint:
        return checkpoint["model_state"]
    return checkpoint


def load_model(path: str | Path, pretrained: bool = False, include_sigmoid: bool = False) -> PageSegNet:
    model = PageSegNet(pretrained=pretrained, include_sigmoid=include_sigmoid)
    state = load_checkpoint_state(path)
    model.load_state_dict(state)
    return model


def _largest_component(binary: np.ndarray) -> np.ndarray | None:
    num, labels, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    if num <= 1:
        return None
    areas = stats[1:, cv2.CC_STAT_AREA]
    best_label = int(np.argmax(areas)) + 1
    component = (labels == best_label).astype(np.uint8) * 255
    return component


def quad_from_mask_info(
    prob: np.ndarray,
    thresh: float = 0.48,
    min_area_ratio: float = 0.012,
    min_peak: float = 0.20,
    min_component_mean: float = PAGESEG_MIN_COMPONENT_MEAN,
) -> MaskQuadInfo:
    """Extract a normalized quad from a page probability mask.

    The extraction intentionally favors one dominant connected component. This
    matches the app behavior where the detector should return a single primary
    document, and it keeps hard-negative false positives from tiny blobs low.
    """
    if prob is None:
        return MaskQuadInfo()
    prob = np.asarray(prob, dtype=np.float32)
    if prob.ndim != 2:
        raise ValueError(f"prob must be HxW, got {prob.shape}")
    h, w = prob.shape[:2]
    if h <= 0 or w <= 0 or float(prob.max(initial=0.0)) < min_peak:
        return MaskQuadInfo()

    binary = (prob >= thresh).astype(np.uint8) * 255
    if binary.sum() == 0:
        adaptive_thresh = max(min_peak, float(np.percentile(prob, 92)))
        binary = (prob >= adaptive_thresh).astype(np.uint8) * 255
    if binary.sum() == 0:
        return MaskQuadInfo()

    kernel = np.ones((5, 5), dtype=np.uint8)
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=2)
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, np.ones((3, 3), dtype=np.uint8), iterations=1)
    component = _largest_component(binary)
    if component is None:
        return MaskQuadInfo()

    component_area = cv2.countNonZero(component)
    mask_area_ratio = float(component_area) / max(1.0, float(h * w))
    component_mean_probability = float(cv2.mean(prob, mask=component)[0])
    if component_mean_probability < min_component_mean:
        return MaskQuadInfo(
            mask_area_ratio=mask_area_ratio,
            component_mean_probability=component_mean_probability,
        )

    min_area = min_area_ratio * h * w
    contours, _ = cv2.findContours(component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return MaskQuadInfo(
            mask_area_ratio=mask_area_ratio,
            component_mean_probability=component_mean_probability,
        )
    contour = max(contours, key=cv2.contourArea)
    area = cv2.contourArea(contour)
    if area < min_area:
        return MaskQuadInfo(
            mask_area_ratio=mask_area_ratio,
            component_mean_probability=component_mean_probability,
        )

    hull = cv2.convexHull(contour)
    perimeter = cv2.arcLength(hull, True)
    quad = None
    for epsilon in (0.012, 0.018, 0.024, 0.032, 0.045, 0.06, 0.08):
        approx = cv2.approxPolyDP(hull, epsilon * perimeter, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            candidate = approx.reshape(4, 2).astype(np.float32)
            if cv2.contourArea(candidate) >= min_area:
                quad = candidate
                break

    if quad is None:
        rect = cv2.minAreaRect(hull)
        quad = cv2.boxPoints(rect).astype(np.float32)
        if cv2.contourArea(quad) < min_area:
            return MaskQuadInfo(
                mask_area_ratio=mask_area_ratio,
                component_mean_probability=component_mean_probability,
            )

    from .geometry import order_quad

    ordered = order_quad(quad)
    ordered[:, 0] = np.clip(ordered[:, 0] / float(w), 0.0, 1.0)
    ordered[:, 1] = np.clip(ordered[:, 1] / float(h), 0.0, 1.0)
    return MaskQuadInfo(
        quad=ordered.astype(np.float32),
        mask_area_ratio=mask_area_ratio,
        component_mean_probability=component_mean_probability,
    )


def quad_from_mask(
    prob: np.ndarray,
    thresh: float = 0.48,
    min_area_ratio: float = 0.012,
    min_peak: float = 0.20,
    min_component_mean: float = PAGESEG_MIN_COMPONENT_MEAN,
) -> np.ndarray | None:
    return quad_from_mask_info(
        prob,
        thresh=thresh,
        min_area_ratio=min_area_ratio,
        min_peak=min_peak,
        min_component_mean=min_component_mean,
    ).quad
