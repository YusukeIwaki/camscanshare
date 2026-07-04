"""Evaluate the trained detector against an OpenCV baseline.

  .venv/bin/python scripts/document_detection/evaluate.py \
      --checkpoint tmp/docdet-v1/best.pt --frames-dir tmp/smartdoc15/frames \
      --out-dir tmp/docdet-v1/eval

Reports quad-IoU distribution on the SmartDoc background05 holdout for both the
model and a reference OpenCV Canny+contour detector, and writes overlay images
for a handful of frames, the real report source images, and any --extra images
(e.g. the user's screenshots) so results can be inspected visually.
"""

import argparse
import glob
import os
import sys

import cv2
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dataset import INPUT_SIZE, load_smartdoc_records
from seg_model import PageSegNet, quad_from_mask


# --- reference OpenCV baseline (Canny + contour + rectangularity scoring) -----
def opencv_detect(bgr, detect_size=500):
    h, w = bgr.shape[:2]
    scale = detect_size / max(h, w)
    small = cv2.resize(bgr, (int(w * scale), int(h * scale))) if scale < 1 else bgr.copy()
    sh, sw = small.shape[:2]
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    best, best_score = None, -1.0
    for blur, lo, hi in [(5, 30, 50), (5, 50, 150), (5, 75, 200), (11, 30, 100)]:
        b = cv2.GaussianBlur(gray, (blur, blur), 0)
        edges = cv2.Canny(b, lo, hi)
        edges = cv2.dilate(edges, np.ones((5, 5), np.uint8))
        cnts, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for c in sorted(cnts, key=cv2.contourArea, reverse=True)[:12]:
            area = cv2.contourArea(c)
            if area < 0.05 * sh * sw:
                continue
            peri = cv2.arcLength(c, True)
            for eps in (0.02, 0.03, 0.04, 0.05):
                approx = cv2.approxPolyDP(c, eps * peri, True)
                if len(approx) == 4 and cv2.isContourConvex(approx):
                    q = approx.reshape(4, 2).astype("float32")
                    score = _rect_score(q, sw, sh)
                    if score > best_score:
                        best_score, best = score, q / [sw, sh]
                    break
    return _order(best) if best is not None else None


def _rect_score(q, w, h):
    def ang(a, b, c):
        v1, v2 = a - b, c - b
        cos = np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-6)
        return np.degrees(np.arccos(np.clip(cos, -1, 1)))
    angles = [ang(q[(i - 1) % 4], q[i], q[(i + 1) % 4]) for i in range(4)]
    angle_score = np.mean([max(0, 1 - abs(a - 90) / 30) for a in angles])
    area = cv2.contourArea(q.astype(np.float32)) / (w * h)
    c = q.mean(0) / [w, h]
    center = max(0, 1 - np.linalg.norm(c - 0.5) / 0.5)
    return angle_score * 0.55 + area * 0.2 + center * 0.25


def _order(q):
    s = q.sum(1); d = np.diff(q, axis=1).reshape(-1)
    return np.array([q[np.argmin(s)], q[np.argmin(d)], q[np.argmax(s)], q[np.argmax(d)]], "float32")


def poly_iou(a, b, size=INPUT_SIZE):
    if a is None or b is None:
        return 0.0
    ma = np.zeros((size, size), np.uint8); mb = np.zeros((size, size), np.uint8)
    cv2.fillConvexPoly(ma, (a * size).astype(np.int32), 1)
    cv2.fillConvexPoly(mb, (b * size).astype(np.int32), 1)
    inter = np.logical_and(ma, mb).sum(); union = np.logical_or(ma, mb).sum()
    return inter / union if union else 0.0


def model_detect(model, device, bgr):
    rgb = cv2.cvtColor(cv2.resize(bgr, (INPUT_SIZE, INPUT_SIZE)), cv2.COLOR_BGR2RGB)
    t = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255).unsqueeze(0).to(device)
    with torch.no_grad():
        prob = torch.sigmoid(model(t))[0, 0].cpu().numpy()
    return quad_from_mask(prob), prob


def stats(name, ious):
    ious = np.array(ious) if len(ious) else np.array([0.0])
    return (f"{name:8s} n={len(ious):4d} mean={ious.mean():.4f} median={np.median(ious):.4f} "
            f"p05={np.percentile(ious,5):.4f} IoU>=.80={ (ious>=.80).mean():.4f} "
            f"IoU>=.90={(ious>=.90).mean():.4f}")


def draw(bgr, quad, color):
    out = bgr.copy()
    if quad is not None:
        h, w = out.shape[:2]
        pts = (quad * [w, h]).astype(np.int32)
        cv2.polylines(out, [pts], True, color, max(2, w // 200))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--width", type=float, default=1.0)
    ap.add_argument("--limit", type=int, default=1000)
    ap.add_argument("--stride", type=int, default=3)
    ap.add_argument("--extra", nargs="*", default=[])
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = PageSegNet(width=args.width).to(device)
    model.load_state_dict(torch.load(args.checkpoint, map_location=device))
    model.eval()

    _, val = load_smartdoc_records(args.frames_dir)
    sample = val[::args.stride][:args.limit]
    m_ious, o_ious = [], []
    for i, (path, quad) in enumerate(sample):
        bgr = cv2.imread(path)
        if bgr is None:
            continue
        h, w = bgr.shape[:2]
        gt = _order(quad.copy().astype("float32") / [w, h])
        mq, _ = model_detect(model, device, bgr)
        oq = opencv_detect(bgr)
        m_ious.append(poly_iou(mq, gt)); o_ious.append(poly_iou(oq, gt))
        if i < 16:
            vis = np.hstack([draw(draw(bgr, gt, (0, 255, 0)), oq, (0, 0, 255)),
                             draw(draw(bgr, gt, (0, 255, 0)), mq, (255, 128, 0))])
            cv2.imwrite(os.path.join(args.out_dir, f"cmp_{i:02d}.jpg"), vis)

    print(stats("model", m_ious))
    print(stats("opencv", o_ious))
    with open(os.path.join(args.out_dir, "metrics.txt"), "w") as f:
        f.write(stats("model", m_ious) + "\n" + stats("opencv", o_ious) + "\n")

    # report source frames + extra images (no GT, visual only)
    extras = sorted(glob.glob(os.path.join(
        os.path.dirname(args.frames_dir), "..", "..", "report_server", "reports",
        "*", "source.jpg"))) + list(args.extra)
    for j, path in enumerate(extras):
        bgr = cv2.imread(path)
        if bgr is None:
            continue
        mq, _ = model_detect(model, device, bgr)
        oq = opencv_detect(bgr)
        vis = np.hstack([draw(bgr, oq, (0, 0, 255)), draw(bgr, mq, (255, 128, 0))])
        tag = "extra" if path in args.extra else "report"
        cv2.imwrite(os.path.join(args.out_dir, f"{tag}_{j:02d}.jpg"),
                    cv2.resize(vis, (vis.shape[1] * 640 // vis.shape[0] * 2 // 2, 640)))
    print("overlays written to", args.out_dir)


if __name__ == "__main__":
    main()
