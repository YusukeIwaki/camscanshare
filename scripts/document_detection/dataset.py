"""Training data for page-segmentation detection.

Two sources are combined:

1. SmartDoc 2015 Challenge 1 frames (real handheld camera frames with ground-truth
   document quads). This gives realistic perspective, motion blur, illumination
   change and partial occlusion. Masks are rasterized from the quad annotation.

2. On-the-fly synthetic composites that target this app's real failure domain:
   a document page warped by a random homography, pasted onto a cluttered
   photographic background (desk / laptop / lap), with optional hard-case
   augmentations:
     - translucent bluish overlay covering the page (clear plastic folder),
     - partial occlusion by a foreground blob,
     - low page/background contrast,
     - soft cast shadows.

Both sources emit (image_tensor CHW float[0,1], mask_tensor 1HW float[0,1]).
"""

import csv
import gzip
import math
import os
import random

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

INPUT_SIZE = 320


# ---------------------------------------------------------------------------
# SmartDoc real frames
# ---------------------------------------------------------------------------
def load_smartdoc_records(frames_dir, holdout_bg="background05"):
    """Return (train_records, val_records). Each record: (abs_path, quad(4,2))."""
    meta_path = os.path.join(frames_dir, "metadata.csv.gz")
    opener = gzip.open if meta_path.endswith(".gz") else open
    train, val = [], []
    with opener(meta_path, "rt") as f:
        reader = csv.DictReader(f)
        for row in reader:
            quad = np.array([
                [float(row["tl_x"]), float(row["tl_y"])],
                [float(row["tr_x"]), float(row["tr_y"])],
                [float(row["br_x"]), float(row["br_y"])],
                [float(row["bl_x"]), float(row["bl_y"])],
            ], dtype="float32")
            path = os.path.join(frames_dir, row["image_path"])
            rec = (path, quad)
            if row["bg_name"] == holdout_bg:
                val.append(rec)
            else:
                train.append(rec)
    return train, val


def _mask_from_quad(quad, h, w):
    mask = np.zeros((h, w), dtype="uint8")
    cv2.fillConvexPoly(mask, quad.astype(np.int32), 255)
    return mask


# ---------------------------------------------------------------------------
# Synthetic composites
# ---------------------------------------------------------------------------
def _random_homography_quad(w, h, rng, fill_mode="normal"):
    """Random destination quad for a warped page on a WxH canvas.

    fill_mode:
      - "normal": page is a sub-region with background visible all around.
      - "edge":   page is large and may extend past the frame borders, so the
                  visible page touches or exceeds one or more edges.
      - "full":   page covers essentially the whole frame (near-scan close-up).
    """
    if fill_mode == "full":
        scale_lo, scale_hi = 1.0, 1.35
        margin = -0.15
    elif fill_mode == "edge":
        scale_lo, scale_hi = 0.8, 1.15
        margin = -0.05
    else:
        scale_lo, scale_hi = 0.45, 0.82
        margin = 0.06
    bw = rng.uniform(scale_lo, scale_hi) * w
    bh = rng.uniform(scale_lo, scale_hi) * h

    def _center(box, extent):
        lo = box / 2 + margin * extent
        hi = extent - box / 2 - margin * extent
        if hi <= lo:
            return extent / 2
        return rng.uniform(lo, hi)

    cx = _center(bw, w)
    cy = _center(bh, h)
    base = np.array([
        [cx - bw / 2, cy - bh / 2],
        [cx + bw / 2, cy - bh / 2],
        [cx + bw / 2, cy + bh / 2],
        [cx - bw / 2, cy + bh / 2],
    ], dtype="float32")
    jitter = (0.06 if fill_mode == "full" else 0.16) * min(bw, bh)
    quad = base + rng.uniform(-jitter, jitter, size=base.shape).astype("float32")
    # rotation (gentler for near-full-frame scans)
    ang = rng.uniform(-0.12, 0.12) if fill_mode == "full" else rng.uniform(-0.35, 0.35)
    ca, sa = math.cos(ang), math.sin(ang)
    c = quad.mean(axis=0)
    rot = np.array([[ca, -sa], [sa, ca]], dtype="float32")
    quad = (quad - c) @ rot.T + c
    # For edge/full modes let corners fall outside the frame (warp+mask clip
    # naturally, producing edge-touching pages). Only clamp far-out coordinates.
    if fill_mode == "normal":
        quad[:, 0] = np.clip(quad[:, 0], 2, w - 2)
        quad[:, 1] = np.clip(quad[:, 1], 2, h - 2)
    else:
        quad[:, 0] = np.clip(quad[:, 0], -0.4 * w, 1.4 * w)
        quad[:, 1] = np.clip(quad[:, 1], -0.4 * h, 1.4 * h)
    return quad.astype("float32")


def _make_synthetic_page(rng, page_pool):
    """Return an RGB page image with mostly-white paper + some content."""
    if page_pool and rng.random() < 0.75:
        img = cv2.imread(random.choice(page_pool))
        if img is not None:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            return img
    # fallback: procedural page
    ph, pw = int(rng.integers(400, 700)), int(rng.integers(300, 520))
    base = int(rng.integers(225, 255))
    page = np.full((ph, pw, 3), base, dtype="uint8")
    for _ in range(rng.integers(6, 22)):
        y = rng.integers(20, ph - 20)
        x0 = rng.integers(10, pw // 3)
        x1 = rng.integers(pw // 2, pw - 10)
        col = int(rng.integers(0, 90))
        cv2.line(page, (x0, y), (x1, y), (col, col, col), rng.integers(1, 4))
    return page


def synth_composite(background_bgr, page_pool, rng, size=INPUT_SIZE):
    """Composite a warped page onto a background. Returns (rgb uint8, mask uint8)."""
    bg = cv2.resize(background_bgr, (size, size))
    bg = cv2.cvtColor(bg, cv2.COLOR_BGR2RGB).astype(np.float32)

    page = _make_synthetic_page(rng, page_pool).astype(np.float32)
    ph, pw = page.shape[:2]
    fill_mode = rng.choice(["normal", "edge", "full"], p=[0.4, 0.32, 0.28])
    dst = _random_homography_quad(size, size, rng, fill_mode=fill_mode)
    src = np.array([[0, 0], [pw, 0], [pw, ph], [0, ph]], dtype="float32")
    H = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(page, H, (size, size), borderValue=0)
    page_mask = cv2.warpPerspective(
        np.ones((ph, pw), np.float32), H, (size, size), flags=cv2.INTER_NEAREST
    )
    mask = (page_mask > 0.5).astype("uint8") * 255

    # brightness / illumination on the page
    warped *= rng.uniform(0.7, 1.05)

    alpha = page_mask[..., None]
    comp = warped * alpha + bg * (1 - alpha)

    # --- hard-case augmentations ---
    # translucent bluish overlay (clear plastic folder) extending past the page
    if rng.random() < 0.35:
        folder = _random_homography_quad(size, size, rng)
        # grow folder quad ~10-25% around its center so it exceeds the page
        c = folder.mean(0)
        folder = (folder - c) * rng.uniform(1.1, 1.3) + c
        fmask = np.zeros((size, size), np.float32)
        cv2.fillConvexPoly(fmask, folder.astype(np.int32), 1.0)
        fmask = cv2.GaussianBlur(fmask, (0, 0), 3)[..., None]
        tint = np.array([rng.uniform(200, 235), rng.uniform(225, 250),
                         rng.uniform(225, 250)], np.float32)
        strength = rng.uniform(0.12, 0.3)
        comp = comp * (1 - strength * fmask) + tint * (strength * fmask)

    # cast shadow band
    if rng.random() < 0.4:
        shadow = np.ones((size, size), np.float32)
        x0 = rng.integers(0, size)
        cv2.line(shadow, (x0, 0), (x0 + rng.integers(-size // 3, size // 3), size),
                 rng.uniform(0.55, 0.85), rng.integers(size // 4, size // 2))
        shadow = cv2.GaussianBlur(shadow, (0, 0), rng.uniform(8, 25))[..., None]
        comp *= shadow

    # partial occlusion by a foreground blob
    if rng.random() < 0.3:
        occ = comp.copy()
        oc = (int(rng.integers(0, size)), int(rng.integers(0, size)))
        axes = (int(rng.integers(20, 70)), int(rng.integers(20, 70)))
        color = tuple(int(v) for v in rng.integers(20, 160, size=3))
        cv2.ellipse(occ, oc, axes, rng.uniform(0, 180), 0, 360, color, -1)
        omask = np.zeros((size, size), np.float32)
        cv2.ellipse(omask, oc, axes, rng.uniform(0, 180), 0, 360, 1.0, -1)
        omask = omask[..., None]
        comp = occ * omask + comp * (1 - omask)
        # occluded page pixels are no longer visible page -> keep in mask?
        # Keep full page in mask so the model learns to hallucinate occluded region
        # (matches how a human would still draw the full page boundary).

    comp = np.clip(comp, 0, 255).astype("uint8")
    return comp, mask


# ---------------------------------------------------------------------------
# Shared augmentation for real frames
# ---------------------------------------------------------------------------
def _augment_real(img, mask, rng):
    # color jitter
    img = img.astype(np.float32)
    img *= rng.uniform(0.75, 1.15)
    img += rng.uniform(-12, 12)
    if rng.random() < 0.3:
        k = int(rng.choice([3, 5, 7]))
        img = cv2.GaussianBlur(img, (k, k), 0)
    # horizontal flip
    if rng.random() < 0.5:
        img = img[:, ::-1]
        mask = mask[:, ::-1]
    return np.clip(img, 0, 255).astype("uint8"), mask


class DetectionDataset(Dataset):
    def __init__(self, smartdoc_records, background_paths, page_pool,
                 synth_ratio=0.5, size=INPUT_SIZE, train=True, length=None):
        self.records = smartdoc_records
        self.backgrounds = background_paths
        self.page_pool = page_pool
        self.synth_ratio = synth_ratio if (background_paths and train) else 0.0
        self.size = size
        self.train = train
        self._len = length or len(smartdoc_records)

    def __len__(self):
        return self._len

    def _load_real(self, idx, rng=None):
        path, quad = self.records[idx % len(self.records)]
        img = cv2.imread(path)
        if img is None:
            # degenerate fallback
            img = np.zeros((self.size, self.size, 3), np.uint8)
            return img, np.zeros((self.size, self.size), np.uint8)
        h, w = img.shape[:2]
        mask = _mask_from_quad(quad, h, w)
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

        # Tight-crop augmentation: turn a sub-region document into a near-full-frame
        # example (page fills or exceeds the crop) with an exact boundary. This is
        # the real-data source for the close-up scan case the model must handle.
        if self.train and rng is not None and rng.random() < 0.5:
            x0, y0 = quad[:, 0].min(), quad[:, 1].min()
            x1, y1 = quad[:, 0].max(), quad[:, 1].max()
            bw, bh = x1 - x0, y1 - y0
            # per-side padding fraction of the bbox; negative -> page exceeds crop
            pl, pr, pt, pb = rng.uniform(-0.12, 0.35, size=4)
            cx0 = int(np.clip(x0 - pl * bw, 0, w - 2))
            cy0 = int(np.clip(y0 - pt * bh, 0, h - 2))
            cx1 = int(np.clip(x1 + pr * bw, cx0 + 2, w))
            cy1 = int(np.clip(y1 + pb * bh, cy0 + 2, h))
            if (cx1 - cx0) >= 16 and (cy1 - cy0) >= 16:
                img = img[cy0:cy1, cx0:cx1]
                mask = mask[cy0:cy1, cx0:cx1]

        img = cv2.resize(img, (self.size, self.size))
        mask = cv2.resize(mask, (self.size, self.size), interpolation=cv2.INTER_NEAREST)
        return img, mask

    def __getitem__(self, idx):
        rng = np.random.default_rng(
            (idx * 2654435761 + (0 if not self.train else random.randint(0, 1 << 30))) & 0xFFFFFFFF
        )
        use_synth = self.train and self.synth_ratio > 0 and rng.random() < self.synth_ratio
        if use_synth:
            bg = cv2.imread(random.choice(self.backgrounds))
            if bg is None:
                bg = np.full((self.size, self.size, 3),
                             rng.integers(40, 160), dtype="uint8")
            img, mask = synth_composite(bg, self.page_pool, rng, self.size)
        else:
            img, mask = self._load_real(idx, rng=rng if self.train else None)
            if self.train:
                img, mask = _augment_real(img, mask, rng)

        img_t = torch.from_numpy(np.ascontiguousarray(img)).permute(2, 0, 1).float() / 255.0
        mask_t = torch.from_numpy(np.ascontiguousarray(mask)).unsqueeze(0).float() / 255.0
        return img_t, mask_t
