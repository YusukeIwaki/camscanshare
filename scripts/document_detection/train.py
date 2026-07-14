from __future__ import annotations

import argparse
import json
import os
import random
import time
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from .dataset import DetectionDataset, collect_background_pool, collect_page_pool, load_smartdoc_records
from .evaluate import evaluate_checkpoint, format_stats, metric_stats, model_detect
from .geometry import normalize_quad, poly_iou
from .seg_model import INPUT_SIZE, PageSegNet, count_parameters, load_checkpoint_state, quad_from_mask


def choose_device(requested: str) -> torch.device:
    if requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def bce_dice_boundary_loss(logits: torch.Tensor, target: torch.Tensor, boundary_weight: float = 2.0) -> torch.Tensor:
    prob = torch.sigmoid(logits)
    if boundary_weight > 0:
        dilated = F.max_pool2d(target, kernel_size=5, stride=1, padding=2)
        eroded = -F.max_pool2d(-target, kernel_size=5, stride=1, padding=2)
        edge = (dilated - eroded).clamp(0, 1)
        weights = 1.0 + boundary_weight * edge
    else:
        weights = torch.ones_like(target)

    bce = F.binary_cross_entropy_with_logits(logits, target, reduction="none")
    bce = (bce * weights).sum() / weights.sum().clamp_min(1.0)

    inter = (prob * target).sum(dim=(1, 2, 3))
    union = prob.sum(dim=(1, 2, 3)) + target.sum(dim=(1, 2, 3))
    dice = 1.0 - (2.0 * inter + 1.0) / (union + 1.0)
    return bce + dice.mean()


@torch.no_grad()
def evaluate_model_on_records(
    model: PageSegNet,
    records,
    device: torch.device,
    limit: int,
    stride: int,
) -> dict[str, float]:
    model.eval()
    sample = records[:: max(1, stride)]
    if limit > 0:
        sample = sample[:limit]
    ious: list[float] = []
    for record in sample:
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            continue
        h, w = bgr.shape[:2]
        gt = normalize_quad(record.quad, w, h)
        pred, _ = model_detect(model, device, bgr)
        ious.append(poly_iou(pred, gt, INPUT_SIZE))
    return metric_stats(ious)


def append_log(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as file:
        file.write(line.rstrip() + "\n")


def save_checkpoint(
    path: Path,
    model: PageSegNet,
    epoch: int,
    stats: dict[str, float],
    args: argparse.Namespace,
    param_count: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "model_state": model.state_dict(),
            "epoch": epoch,
            "stats": stats,
            "args": vars(args),
            "param_count": param_count,
        },
        path,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train MobileNetV3 page segmentation detector.")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--models-dir", default="tmp/smartdoc15/models")
    parser.add_argument("--out-dir", default="tmp/docdet-v3")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--steps-per-epoch", type=int, default=400)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--synth-ratio", type=float, default=0.62)
    parser.add_argument("--hard-negative-ratio", type=float, default=0.18)
    parser.add_argument("--boundary-weight", type=float, default=2.0)
    parser.add_argument("--num-workers", type=int, default=6)
    parser.add_argument("--val-limit", type=int, default=800)
    parser.add_argument("--val-stride", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20260615)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--resume", default=None)
    parser.add_argument("--no-pretrained", action="store_true")
    parser.add_argument("--smoke", action="store_true", help="Tiny CPU run that exercises data, training, checkpoint, eval and overlays.")
    return parser.parse_args()


def apply_smoke_overrides(args: argparse.Namespace) -> None:
    if not args.smoke:
        return
    args.epochs = 1
    args.steps_per_epoch = 2
    args.batch_size = 2
    args.num_workers = 0
    args.val_limit = 12
    args.val_stride = 180
    args.device = "cpu"
    args.no_pretrained = True


def main() -> None:
    args = parse_args()
    apply_smoke_overrides(args)
    seed_everything(args.seed)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = out_dir / "train.log"
    device = choose_device(args.device)
    if not args.no_pretrained and "TORCH_HOME" not in os.environ:
        os.environ["TORCH_HOME"] = str(out_dir / "torch-cache")

    train_records, val_records = load_smartdoc_records(args.frames_dir, holdout_bg=args.holdout_bg)
    page_pool = collect_page_pool(args.models_dir)
    background_pool = collect_background_pool(train_records)

    model = PageSegNet(pretrained=not args.no_pretrained).to(device)
    param_count = count_parameters(model)
    if args.resume:
        model.load_state_dict(load_checkpoint_state(args.resume))
        print(f"resumed from {args.resume}")

    dataset = DetectionDataset(
        train_records,
        background_pool,
        page_pool,
        synth_ratio=args.synth_ratio,
        hard_negative_ratio=args.hard_negative_ratio,
        train=True,
        length=args.batch_size * args.steps_per_epoch,
    )
    loader_kwargs = {
        "batch_size": args.batch_size,
        "shuffle": True,
        "num_workers": args.num_workers,
        "drop_last": True,
    }
    if args.num_workers > 0:
        loader_kwargs["persistent_workers"] = True
    dataloader = DataLoader(dataset, **loader_kwargs)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    total_steps = max(1, args.epochs * len(dataloader))
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=total_steps, eta_min=args.lr * 0.05)

    run_meta = {
        "event": "run_start",
        "device": str(device),
        "train_records": len(train_records),
        "val_records": len(val_records),
        "page_pool": len(page_pool),
        "background_pool": len(background_pool),
        "params": param_count,
        "smoke": bool(args.smoke),
        "args": vars(args),
    }
    append_log(log_path, json.dumps(run_meta, sort_keys=True))
    print(f"device: {device}")
    print(f"SmartDoc train={len(train_records)} val={len(val_records)} page_pool={len(page_pool)} backgrounds={len(background_pool)}")
    print(f"model parameters: {param_count:,}")

    best_mean = -1.0
    best_path = out_dir / "best.pt"
    last_path = out_dir / "last.pt"
    global_step = 0
    for epoch in range(1, args.epochs + 1):
        started = time.perf_counter()
        model.train()
        losses: list[float] = []
        for step, (images, masks) in enumerate(dataloader, start=1):
            images = images.to(device, non_blocking=True)
            masks = masks.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            logits = model(images)
            loss = bce_dice_boundary_loss(logits, masks, boundary_weight=args.boundary_weight)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            optimizer.step()
            scheduler.step()
            global_step += 1
            losses.append(float(loss.detach().cpu()))
            if step == 1 or step % 50 == 0 or step == len(dataloader):
                print(
                    f"epoch {epoch}/{args.epochs} step {step}/{len(dataloader)} "
                    f"loss={losses[-1]:.4f} lr={scheduler.get_last_lr()[0]:.2e}",
                    flush=True,
                )

        stats = evaluate_model_on_records(model, val_records, device, args.val_limit, args.val_stride)
        avg_loss = float(np.mean(losses)) if losses else 0.0
        elapsed = time.perf_counter() - started
        save_checkpoint(last_path, model, epoch, stats, args, param_count)
        is_best = stats["mean"] > best_mean
        if is_best:
            best_mean = stats["mean"]
            save_checkpoint(best_path, model, epoch, stats, args, param_count)
            (out_dir / "best.txt").write_text(f"epoch={epoch} mean={best_mean:.6f} stats={stats}\n")

        log_entry = {
            "event": "epoch",
            "epoch": epoch,
            "loss": avg_loss,
            "lr": scheduler.get_last_lr()[0],
            "elapsed_sec": elapsed,
            "best": is_best,
            "global_step": global_step,
            "val": stats,
        }
        append_log(log_path, json.dumps(log_entry, sort_keys=True))
        print(
            f"[epoch {epoch}] loss={avg_loss:.4f} "
            f"{format_stats('val', stats)} elapsed={elapsed:.1f}s"
            + (" -> best" if is_best else ""),
            flush=True,
        )

    print(f"done. best mean IoU={best_mean:.4f} checkpoint={best_path}")

    if args.smoke:
        print("running smoke evaluation and overlay generation...")
        metrics = evaluate_checkpoint(
            best_path,
            frames_dir=args.frames_dir,
            out_dir=out_dir / "eval-smoke",
            report_out_dir=out_dir / "report-overlays",
            holdout_bg=args.holdout_bg,
            limit=12,
            stride=180,
            max_overlays=8,
            report_limit=8,
            device_name="cpu",
        )
        if "model" in metrics:
            print(format_stats("model", metrics["model"]))
        print(format_stats("baseline", metrics["baseline"]))
        print(f"smoke overlays: {out_dir / 'eval-smoke'} and {out_dir / 'report-overlays'}")


if __name__ == "__main__":
    main()
