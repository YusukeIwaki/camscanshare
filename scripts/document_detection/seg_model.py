"""Compact page-segmentation model for document boundary detection.

The architecture is a small MobileNet-style separable-conv U-Net that outputs a
single-channel page-probability mask at the input resolution. It is intentionally
export-clean: only Conv/BN/ReLU6/bilinear-upsample/sigmoid ops so both ONNX
(ONNX Runtime on Android) and Core ML (iOS) conversions are lossless and fast.

This mirrors CamScanner's modern detector shape (a small CNN whose Conv/Sigmoid
head yields a page region, then OpenCV refines the quad) rather than the earlier
direct-corner-regression LDRNet attempt, which topped out around 0.53 IoU.
"""

import torch
import torch.nn as nn
import torch.nn.functional as F


def conv_bn(inp, oup, stride=1):
    return nn.Sequential(
        nn.Conv2d(inp, oup, 3, stride, 1, bias=False),
        nn.BatchNorm2d(oup),
        nn.ReLU6(inplace=True),
    )


class DWSep(nn.Module):
    """Depthwise-separable conv block (MobileNet style)."""

    def __init__(self, inp, oup, stride=1):
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(inp, inp, 3, stride, 1, groups=inp, bias=False),
            nn.BatchNorm2d(inp),
            nn.ReLU6(inplace=True),
            nn.Conv2d(inp, oup, 1, 1, 0, bias=False),
            nn.BatchNorm2d(oup),
            nn.ReLU6(inplace=True),
        )

    def forward(self, x):
        return self.block(x)


class PageSegNet(nn.Module):
    """Small separable U-Net. Input NCHW RGB in [0,1]; output N1HW sigmoid mask."""

    def __init__(self, width=1.0):
        super().__init__()

        def c(ch):
            return max(8, int(ch * width))

        # Encoder
        self.stem = conv_bn(3, c(16), stride=2)          # 1/2
        self.enc1 = DWSep(c(16), c(32), stride=2)        # 1/4
        self.enc2 = DWSep(c(32), c(64), stride=2)        # 1/8
        self.enc3 = DWSep(c(64), c(128), stride=2)       # 1/16
        self.enc4 = DWSep(c(128), c(128), stride=2)      # 1/32
        self.bottleneck = DWSep(c(128), c(128))

        # Decoder (bilinear upsample + separable conv, with skip fusion)
        self.dec4 = DWSep(c(128) + c(128), c(128))
        self.dec3 = DWSep(c(128) + c(64), c(64))
        self.dec2 = DWSep(c(64) + c(32), c(32))
        self.dec1 = DWSep(c(32) + c(16), c(16))
        self.head = nn.Conv2d(c(16), 1, 1)

    @staticmethod
    def _up(x, ref):
        return F.interpolate(x, size=ref.shape[-2:], mode="bilinear", align_corners=False)

    def forward(self, x):
        s0 = self.stem(x)        # 1/2
        s1 = self.enc1(s0)       # 1/4
        s2 = self.enc2(s1)       # 1/8
        s3 = self.enc3(s2)       # 1/16
        s4 = self.enc4(s3)       # 1/32
        b = self.bottleneck(s4)

        d4 = self.dec4(torch.cat([self._up(b, s3), s3], 1))
        d3 = self.dec3(torch.cat([self._up(d4, s2), s2], 1))
        d2 = self.dec2(torch.cat([self._up(d3, s1), s1], 1))
        d1 = self.dec1(torch.cat([self._up(d2, s0), s0], 1))
        logits = self.head(self._up(d1, x))
        return logits  # apply sigmoid outside for training stability


def quad_from_mask(prob, thresh=0.5):
    """Extract a 4-corner quad (TL,TR,BR,BL order) from a probability mask.

    Returns normalized corners in [0,1] as a (4,2) float array, or None.
    """
    import cv2
    import numpy as np

    h, w = prob.shape[:2]
    binary = (prob >= thresh).astype("uint8") * 255
    if binary.sum() == 0:
        return None
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    c = max(contours, key=cv2.contourArea)
    if cv2.contourArea(c) < 0.02 * h * w:
        return None

    peri = cv2.arcLength(c, True)
    quad = None
    for eps in (0.02, 0.03, 0.04, 0.05, 0.06, 0.08):
        approx = cv2.approxPolyDP(c, eps * peri, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            quad = approx.reshape(4, 2).astype("float32")
            break
    if quad is None:
        rect = cv2.minAreaRect(c)
        quad = cv2.boxPoints(rect).astype("float32")

    # Order corners TL, TR, BR, BL
    s = quad.sum(axis=1)
    d = np.diff(quad, axis=1).reshape(-1)
    ordered = np.array([
        quad[np.argmin(s)],   # TL
        quad[np.argmin(d)],   # TR
        quad[np.argmax(s)],   # BR
        quad[np.argmax(d)],   # BL
    ], dtype="float32")
    ordered[:, 0] /= w
    ordered[:, 1] /= h
    return ordered
