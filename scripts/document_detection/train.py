"""Train the page-segmentation document detector.

Usage:
  .venv/bin/python scripts/document_detection/train.py \
      --frames-dir tmp/smartdoc15/frames \
      --models-dir tmp/smartdoc15/models \
      --out-dir tmp/docdet \
      --epochs 12 --batch-size 32 --steps-per-epoch 400

Val IoU is the *quad* IoU (extract quad from predicted mask, compare with GT quad
polygon), which is what actually matters for the app, not pixel IoU.
"""

import argparse
import glob
import os
import random
import sys

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dataset import (INPUT_SIZE, DetectionDataset, load_smartdoc_records)
from seg_model import PageSegNet, quad_from_mask


def dice_bce_loss(logits, target):
    bce = F.binary_cross_entropy_with_logits(logits, target)
    prob = torch.sigmoid(logits)
    inter = (prob * target).sum((1, 2, 3))
    union = prob.sum((1, 2, 3)) + target.sum((1, 2, 3))
    dice = 1 - (2 * inter + 1) / (union + 1)
    return bce + dice.mean()


def poly_iou(quad_a, quad_b, size=INPUT_SIZE):
    ma = np.zeros((size, size), np.uint8)
    mb = np.zeros((size, size), np.uint8)
    cv2.fillConvexPoly(ma, (quad_a * size).astype(np.int32), 1)
    cv2.fillConvexPoly(mb, (quad_b * size).astype(np.int32), 1)
    inter = np.logical_and(ma, mb).sum()
    union = np.logical_or(ma, mb).sum()
    return inter / union if union else 0.0


@torch.no_grad()
def evaluate(model, records, device, limit=600, stride=8):
    model.eval()
    ious = []
    sample = records[::stride][:limit]
    for path, quad in sample:
        img = cv2.imread(path)
        if img is None:
            continue
        h, w = img.shape[:2]
        gt = quad.copy().astype("float32")
        gt[:, 0] /= w
        gt[:, 1] /= h
        rgb = cv2.cvtColor(cv2.resize(img, (INPUT_SIZE, INPUT_SIZE)), cv2.COLOR_BGR2RGB)
        t = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255).unsqueeze(0).to(device)
        prob = torch.sigmoid(model(t))[0, 0].cpu().numpy()
        pred = quad_from_mask(prob)
        ious.append(poly_iou(pred, gt) if pred is not None else 0.0)
    ious = np.array(ious) if ious else np.array([0.0])
    return {
        "n": len(ious),
        "mean": float(ious.mean()),
        "median": float(np.median(ious)),
        "p05": float(np.percentile(ious, 5)),
        "iou90": float((ious >= 0.90).mean()),
        "iou80": float((ious >= 0.80).mean()),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--models-dir", default=None)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch-size", type=int, default=32)
    ap.add_argument("--steps-per-epoch", type=int, default=400)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--synth-ratio", type=float, default=0.5)
    ap.add_argument("--num-workers", type=int, default=6)
    ap.add_argument("--width", type=float, default=1.0)
    ap.add_argument("--resume", default=None)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print("device:", device)

    train_recs, val_recs = load_smartdoc_records(args.frames_dir)
    print(f"smartdoc train={len(train_recs)} val={len(val_recs)}")

    # page pool: clean A4 pages to warp for synthetic composites
    page_pool = []
    if args.models_dir:
        page_pool += glob.glob(os.path.join(args.models_dir, "02-edited", "*.png"))
        page_pool += glob.glob(os.path.join(args.models_dir, "01-original", "*.png"))
    print("page pool:", len(page_pool))

    # backgrounds for synthetic composites: cluttered real scenes.
    # Use the most cluttered SmartDoc background (bg05) frames + report sources.
    bg_paths = glob.glob(os.path.join(args.frames_dir, "background05", "*", "*.jpeg"))[::5]
    report_srcs = glob.glob(os.path.join(
        os.path.dirname(args.frames_dir), "..", "..", "report_server", "reports",
        "*", "source.jpg"))
    bg_paths += [p for p in report_srcs if os.path.exists(p)]
    random.shuffle(bg_paths)
    print("background pool:", len(bg_paths))

    ds = DetectionDataset(train_recs, bg_paths, page_pool,
                          synth_ratio=args.synth_ratio, train=True,
                          length=args.batch_size * args.steps_per_epoch)
    dl = DataLoader(ds, batch_size=args.batch_size, shuffle=True,
                    num_workers=args.num_workers, drop_last=True, persistent_workers=True)

    model = PageSegNet(width=args.width).to(device)
    if args.resume and os.path.exists(args.resume):
        model.load_state_dict(torch.load(args.resume, map_location=device))
        print("resumed from", args.resume)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)

    best = -1.0
    for epoch in range(args.epochs):
        model.train()
        running = 0.0
        for i, (img, mask) in enumerate(dl):
            img, mask = img.to(device), mask.to(device)
            opt.zero_grad()
            loss = dice_bce_loss(model(img), mask)
            loss.backward()
            opt.step()
            running += loss.item()
            if i % 50 == 0:
                print(f"  e{epoch} step {i}/{len(dl)} loss {loss.item():.4f}", flush=True)
        sched.step()
        stats = evaluate(model, val_recs, device)
        print(f"[epoch {epoch}] loss {running/len(dl):.4f} val {stats}", flush=True)
        torch.save(model.state_dict(), os.path.join(args.out_dir, "last.pt"))
        if stats["mean"] > best:
            best = stats["mean"]
            torch.save(model.state_dict(), os.path.join(args.out_dir, "best.pt"))
            with open(os.path.join(args.out_dir, "best.txt"), "w") as f:
                f.write(f"epoch {epoch} {stats}\n")
            print(f"  -> new best mean IoU {best:.4f}", flush=True)

    print("done. best mean IoU:", best)


if __name__ == "__main__":
    main()
