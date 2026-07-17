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

from .boundary_head_dataset import BoundaryHeadDataset
from .boundary_head_model import (
    PageBoundaryNet,
    count_parameters,
    load_base_segmentation_weights,
    load_boundary_checkpoint_state,
    quad_from_mask_and_boundary,
)
from .dataset import DetectionDataset, collect_background_pool, collect_page_pool
from .geometry import normalize_quad, poly_iou
from .seg_model import INPUT_SIZE, quad_from_mask_info
from .smartdoc import load_smartdoc_records


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


def bce_dice_loss(logits: torch.Tensor, target: torch.Tensor, positive_weight: float = 1.0) -> torch.Tensor:
    weights = torch.where(target > 0.5, positive_weight, 1.0)
    bce = F.binary_cross_entropy_with_logits(logits, target, reduction="none")
    bce = (bce * weights).sum() / weights.sum().clamp_min(1.0)
    probability = torch.sigmoid(logits)
    intersection = (probability * target).sum(dim=(1, 2, 3))
    union = probability.sum(dim=(1, 2, 3)) + target.sum(dim=(1, 2, 3))
    dice = 1.0 - (2.0 * intersection + 1.0) / (union + 1.0)
    return bce + dice.mean()


def focal_dice_boundary_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    probability = torch.sigmoid(logits)
    bce = F.binary_cross_entropy_with_logits(logits, target, reduction="none")
    pt = target * probability + (1.0 - target) * (1.0 - probability)
    alpha = target * 0.75 + (1.0 - target) * 0.25
    focal = (alpha * torch.square(1.0 - pt) * bce).mean()
    intersection = (probability * target).sum(dim=(1, 2, 3))
    union = probability.sum(dim=(1, 2, 3)) + target.sum(dim=(1, 2, 3))
    dice = 1.0 - (2.0 * intersection + 1.0) / (union + 1.0)
    return focal + dice.mean()


def multi_head_loss(
    mask_logits: torch.Tensor,
    boundary_logits: torch.Tensor,
    state_logits: torch.Tensor,
    targets: dict[str, torch.Tensor],
    args: argparse.Namespace,
) -> tuple[torch.Tensor, dict[str, float]]:
    mask_target = targets["mask"].to(mask_logits.device)
    boundary_target = targets["boundary"].to(boundary_logits.device)
    mask_loss = bce_dice_loss(mask_logits, mask_target, positive_weight=1.0)
    boundary_loss = focal_dice_boundary_loss(boundary_logits, boundary_target)
    state_target = torch.stack([targets["present"], targets["fully_visible"]], dim=1).to(state_logits.device)
    state_positive_weights = torch.tensor(
        [args.presence_positive_weight, args.full_positive_weight],
        dtype=state_logits.dtype,
        device=state_logits.device,
    )
    state_loss = F.binary_cross_entropy_with_logits(
        state_logits,
        state_target,
        pos_weight=state_positive_weights,
    )
    total = args.mask_loss_weight * mask_loss + args.boundary_loss_weight * boundary_loss + args.state_loss_weight * state_loss
    return total, {
        "total": float(total.detach().cpu()),
        "mask": float(mask_loss.detach().cpu()),
        "boundary": float(boundary_loss.detach().cpu()),
        "state": float(state_loss.detach().cpu()),
    }


def set_base_trainable(model: PageBoundaryNet, trainable: bool) -> None:
    for name, parameter in model.named_parameters():
        if name.startswith("boundary_head.") or name.startswith("state_head."):
            parameter.requires_grad = True
        else:
            parameter.requires_grad = trainable


@torch.no_grad()
def evaluate_model(
    model: PageBoundaryNet,
    records,
    device: torch.device,
    limit: int,
    stride: int,
    search_band_ratio: float,
) -> dict[str, float]:
    model.eval()
    selected = records[:: max(1, stride)]
    if limit > 0:
        selected = selected[:limit]
    mask_ious: list[float] = []
    boundary_ious: list[float] = []
    presence_hits = 0
    full_hits = 0
    accepted_sides: list[int] = []
    for record in selected:
        bgr = cv2.imread(str(record.path))
        if bgr is None:
            continue
        height, width = bgr.shape[:2]
        rgb = cv2.cvtColor(
            cv2.resize(bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_AREA),
            cv2.COLOR_BGR2RGB,
        )
        tensor = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255.0).unsqueeze(0).to(device)
        mask_logits, boundary_logits, state_logits = model(tensor)
        mask_probability = torch.sigmoid(mask_logits)[0, 0].detach().cpu().numpy()
        boundary_probability = torch.sigmoid(boundary_logits)[0, 0].detach().cpu().numpy()
        state_probability = torch.sigmoid(state_logits)[0].detach().cpu().numpy()
        mask_quad = quad_from_mask_info(mask_probability).quad
        boundary_result = quad_from_mask_and_boundary(
            mask_quad,
            boundary_probability,
            search_band_ratio=search_band_ratio,
        )
        gt = normalize_quad(record.quad, width, height)
        mask_ious.append(poly_iou(mask_quad, gt, INPUT_SIZE))
        boundary_ious.append(poly_iou(boundary_result.quad, gt, INPUT_SIZE))
        presence_hits += int(state_probability[0] >= 0.5)
        full_hits += int(state_probability[1] >= 0.5)
        accepted_sides.append(boundary_result.accepted_side_count)

    def stats(values: list[float]) -> dict[str, float]:
        array = np.asarray(values, dtype=np.float32)
        return {
            "mean": float(array.mean()) if len(array) else 0.0,
            "p05": float(np.percentile(array, 5)) if len(array) else 0.0,
            "iou_080": float(np.mean(array >= 0.80)) if len(array) else 0.0,
            "iou_090": float(np.mean(array >= 0.90)) if len(array) else 0.0,
            "iou_095": float(np.mean(array >= 0.95)) if len(array) else 0.0,
        }

    mask_stats = stats(mask_ious)
    boundary_stats = stats(boundary_ious)
    count = max(1, len(boundary_ious))
    return {
        "n": float(len(boundary_ious)),
        **{f"mask_{key}": value for key, value in mask_stats.items()},
        **{f"boundary_{key}": value for key, value in boundary_stats.items()},
        "presence_recall": presence_hits / count,
        "fully_visible_recall": full_hits / count,
        "mean_accepted_sides": float(np.mean(accepted_sides)) if accepted_sides else 0.0,
    }


def save_checkpoint(
    path: Path,
    model: PageBoundaryNet,
    epoch: int,
    stats: dict[str, float],
    args: argparse.Namespace,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "model_state": model.state_dict(),
            "epoch": epoch,
            "stats": stats,
            "args": vars(args),
            "param_count": count_parameters(model),
        },
        path,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train PageSeg spatial boundary and state heads")
    parser.add_argument("--frames-dir", default="tmp/smartdoc15/frames")
    parser.add_argument("--models-dir", default="tmp/smartdoc15/models")
    parser.add_argument("--base-checkpoint", default="tmp/docdet-v3/best.pt")
    parser.add_argument("--resume", default=None)
    parser.add_argument("--out-dir", default="tmp/docdet-boundary-v1")
    parser.add_argument("--holdout-bg", default="background05")
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--steps-per-epoch", type=int, default=180)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--head-lr", type=float, default=5e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--synth-ratio", type=float, default=0.62)
    parser.add_argument("--hard-negative-ratio", type=float, default=0.18)
    parser.add_argument("--boundary-width", type=int, default=3)
    parser.add_argument("--search-band-ratio", type=float, default=0.03)
    parser.add_argument("--mask-loss-weight", type=float, default=0.50)
    parser.add_argument("--boundary-loss-weight", type=float, default=1.0)
    parser.add_argument("--state-loss-weight", type=float, default=0.20)
    parser.add_argument("--presence-positive-weight", type=float, default=1.0)
    parser.add_argument("--full-positive-weight", type=float, default=2.0)
    parser.add_argument("--freeze-base-epochs", type=int, default=2)
    parser.add_argument("--num-workers", type=int, default=6)
    parser.add_argument("--val-limit", type=int, default=325)
    parser.add_argument("--val-stride", type=int, default=8)
    parser.add_argument("--seed", type=int, default=20260716)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--torch-cache", default="tmp/docdet-v3/torch-cache")
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def apply_smoke_overrides(args: argparse.Namespace) -> None:
    if not args.smoke:
        return
    args.epochs = 1
    args.steps_per_epoch = 2
    args.batch_size = 2
    args.num_workers = 0
    args.val_limit = 6
    args.val_stride = 400
    args.device = "cpu"
    args.freeze_base_epochs = 0


def main() -> None:
    args = parse_args()
    apply_smoke_overrides(args)
    seed_everything(args.seed)
    if "TORCH_HOME" not in os.environ:
        os.environ["TORCH_HOME"] = str(Path(args.torch_cache).resolve())
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    device = choose_device(args.device)

    train_records, val_records = load_smartdoc_records(args.frames_dir, holdout_bg=args.holdout_bg)
    base_dataset = DetectionDataset(
        train_records,
        collect_background_pool(train_records),
        collect_page_pool(args.models_dir),
        synth_ratio=args.synth_ratio,
        hard_negative_ratio=args.hard_negative_ratio,
        train=True,
        length=args.batch_size * args.steps_per_epoch,
    )
    dataset = BoundaryHeadDataset(base_dataset, boundary_width=args.boundary_width)
    loader_kwargs = {
        "batch_size": args.batch_size,
        "shuffle": True,
        "num_workers": args.num_workers,
        "drop_last": True,
    }
    if args.num_workers > 0:
        loader_kwargs["persistent_workers"] = True
    loader = DataLoader(dataset, **loader_kwargs)

    model = PageBoundaryNet(pretrained=False).to(device)
    if args.resume:
        model.load_state_dict(load_boundary_checkpoint_state(args.resume))
        initialization = {"resume": args.resume}
    else:
        missing, unexpected = load_base_segmentation_weights(model, args.base_checkpoint)
        initialization = {
            "base_checkpoint": args.base_checkpoint,
            "missing": missing,
            "unexpected": unexpected,
        }
    base_parameters = []
    head_parameters = []
    for name, parameter in model.named_parameters():
        if name.startswith("boundary_head.") or name.startswith("state_head."):
            head_parameters.append(parameter)
        else:
            base_parameters.append(parameter)
    optimizer = torch.optim.AdamW(
        [
            {"params": base_parameters, "lr": args.lr},
            {"params": head_parameters, "lr": args.head_lr},
        ],
        weight_decay=args.weight_decay,
    )
    total_steps = max(1, args.epochs * len(loader))
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer,
        T_max=total_steps,
        eta_min=args.lr * 0.05,
    )
    print(
        f"device={device} params={count_parameters(model):,} train={len(train_records)} "
        f"val={len(val_records)} steps={len(loader)} init={initialization}",
        flush=True,
    )
    (out_dir / "run.json").write_text(
        json.dumps(
            {
                "event": "run_start",
                "device": str(device),
                "parameters": count_parameters(model),
                "train_records": len(train_records),
                "val_records": len(val_records),
                "initialization": initialization,
                "args": vars(args),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )

    best_score = -1.0
    log_path = out_dir / "train.jsonl"
    for epoch in range(1, args.epochs + 1):
        set_base_trainable(model, epoch > args.freeze_base_epochs)
        model.train()
        started = time.perf_counter()
        epoch_losses: list[dict[str, float]] = []
        for step, (images, targets) in enumerate(loader, start=1):
            images = images.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            outputs = model(images)
            loss, losses = multi_head_loss(*outputs, targets, args)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            optimizer.step()
            scheduler.step()
            epoch_losses.append(losses)
            if step == 1 or step % 50 == 0 or step == len(loader):
                print(
                    f"epoch {epoch}/{args.epochs} step {step}/{len(loader)} "
                    f"loss={losses['total']:.4f} mask={losses['mask']:.4f} "
                    f"boundary={losses['boundary']:.4f} state={losses['state']:.4f}",
                    flush=True,
                )

        stats = evaluate_model(
            model,
            val_records,
            device,
            args.val_limit,
            args.val_stride,
            args.search_band_ratio,
        )
        mean_losses = {
            key: float(np.mean([values[key] for values in epoch_losses]))
            for key in epoch_losses[0]
        }
        # Reward high overlap and tail safety rather than optimizing mean alone.
        selection_score = (
            stats["boundary_mean"]
            + 0.5 * stats["boundary_p05"]
            + 0.2 * stats["boundary_iou_090"]
        )
        is_best = selection_score > best_score
        if is_best:
            best_score = selection_score
            save_checkpoint(out_dir / "best.pt", model, epoch, stats, args)
        save_checkpoint(out_dir / "last.pt", model, epoch, stats, args)
        row = {
            "event": "epoch",
            "epoch": epoch,
            "elapsed_sec": time.perf_counter() - started,
            "loss": mean_losses,
            "validation": stats,
            "selection_score": selection_score,
            "best": is_best,
        }
        with log_path.open("a") as file:
            file.write(json.dumps(row, sort_keys=True) + "\n")
        print(
            f"[epoch {epoch}] mask={stats['mask_mean']:.4f}/{stats['mask_p05']:.4f} "
            f"boundary={stats['boundary_mean']:.4f}/{stats['boundary_p05']:.4f} "
            f"IoU80={stats['boundary_iou_080']:.4f} IoU90={stats['boundary_iou_090']:.4f} "
            f"sides={stats['mean_accepted_sides']:.2f} present={stats['presence_recall']:.3f} "
            f"full={stats['fully_visible_recall']:.3f} elapsed={row['elapsed_sec']:.1f}s"
            + (" -> best" if is_best else ""),
            flush=True,
        )
    print(f"done best_score={best_score:.4f} checkpoint={out_dir / 'best.pt'}")


if __name__ == "__main__":
    main()
