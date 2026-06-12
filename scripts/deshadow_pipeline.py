"""Shared GCDRNet-based deshadow filter pipeline.

This is the canonical Python implementation of the 影除去 (deshadow) filter.
It runs the exact same processing that the Android/iOS apps perform:

  1. GCNet (UNeXt, 3ch) on a 512x512 square resize -> global shadow map
  2. DRNet (UNeXt, 6ch) on an aspect-fit resize into a 1024x1024
     replicate-padded square, fed with [input, input/shadow]
  3. gain map = DRNet output / DRNet input at 1024 resolution,
     Gaussian-smoothed (sigma 2.0), bilinearly upsampled to the original
     resolution and multiplied onto the full-resolution image

The fp16 ONNX models committed under androidapp assets are the single
source of truth shared by this script and the Android app. The iOS app uses
Core ML conversions of the same checkpoints.

Model provenance: GCDRNet, "Appearance Enhancement for Camera-captured
Document Images in the Wild" (Zhang et al., IEEE TAI 2023),
https://github.com/ZZZHANG-jx/GCDRNet
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np

GC_SIZE = 512
DR_SIZE = 1024
GAIN_EPS = 8.0
GAIN_BLUR_SIGMA = 2.0

_MODEL_DIR = Path(__file__).resolve().parent.parent / "androidapp/app/src/main/assets/deshadow"
GCNET_ONNX = _MODEL_DIR / "gcnet-512-fp16.onnx"
DRNET_ONNX = _MODEL_DIR / "drnet-1024-fp16.onnx"

_sessions: dict[str, object] = {}


def _session(path: Path):
    import onnxruntime as ort

    key = str(path)
    if key not in _sessions:
        _sessions[key] = ort.InferenceSession(key, providers=["CPUExecutionProvider"])
    return _sessions[key]


def _chw(img_bgr: np.ndarray) -> np.ndarray:
    return (img_bgr.transpose(2, 0, 1)[None].astype(np.float32)) / 255.0


def apply_deshadow_filter(img_bgr: np.ndarray) -> np.ndarray:
    """Apply the deshadow filter to a BGR uint8 image at any resolution."""
    height, width = img_bgr.shape[:2]

    gc_in = cv2.resize(img_bgr, (GC_SIZE, GC_SIZE), interpolation=cv2.INTER_AREA)
    shadow = _session(GCNET_ONNX).run(None, {"input": _chw(gc_in)})[0][0]

    scale = DR_SIZE / max(height, width)
    if scale < 1.0:
        dr_w, dr_h = int(round(width * scale)), int(round(height * scale))
    else:
        dr_w, dr_h = width, height
    dr_img = cv2.resize(img_bgr, (dr_w, dr_h), interpolation=cv2.INTER_AREA)
    dr_pad = cv2.copyMakeBorder(
        dr_img, 0, DR_SIZE - dr_h, 0, DR_SIZE - dr_w, cv2.BORDER_REPLICATE
    )

    shadow_big = cv2.resize(
        shadow.transpose(1, 2, 0), (DR_SIZE, DR_SIZE), interpolation=cv2.INTER_LINEAR
    )
    dr_input = dr_pad.astype(np.float32) / 255.0
    gc_corrected = np.clip(dr_input / np.maximum(shadow_big, 1e-4), 0, 1)
    x = np.concatenate([dr_input, gc_corrected], axis=2).transpose(2, 0, 1)[None]
    pred = _session(DRNET_ONNX).run(None, {"input": x.astype(np.float32)})[0][0]
    pred_u8 = (np.clip(pred.transpose(1, 2, 0), 0, 1)[:dr_h, :dr_w] * 255).astype(np.uint8)

    gain = (pred_u8.astype(np.float32) + GAIN_EPS) / (dr_img.astype(np.float32) + GAIN_EPS)
    gain = cv2.GaussianBlur(gain, (0, 0), GAIN_BLUR_SIGMA)
    gain_full = cv2.resize(gain, (width, height), interpolation=cv2.INTER_LINEAR)
    return np.clip(img_bgr.astype(np.float32) * gain_full, 0, 255).astype(np.uint8)
