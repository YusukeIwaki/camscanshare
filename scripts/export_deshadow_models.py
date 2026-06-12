#!/usr/bin/env python3
"""Regenerate the committed 影除去 (deshadow) model assets from upstream.

Produces:
  - androidapp/app/src/main/assets/deshadow/gcnet-512-fp16.onnx
  - androidapp/app/src/main/assets/deshadow/drnet-1024-fp16.onnx
  - iosapp/CamScanShare/MLModels/GCNet.mlpackage
  - iosapp/CamScanShare/MLModels/DRNet.mlpackage

Sources:
  - Model code: https://github.com/ZZZHANG-jx/GCDRNet (cloned into tmp/)
  - Checkpoints: https://huggingface.co/FahNos/GCDRnet (gcnet.pkl / drnet.pkl)

Requires the repository .venv (torch, onnx, onnxconverter-common, coremltools):
    .venv/bin/python scripts/export_deshadow_models.py
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GCDR_DIR = REPO_ROOT / "tmp" / "deshadow-repos" / "GCDRNet"
GCDR_GIT = "https://github.com/ZZZHANG-jx/GCDRNet"
HF_BASE = "https://huggingface.co/FahNos/GCDRnet/resolve/main"
ANDROID_ASSETS = REPO_ROOT / "androidapp/app/src/main/assets/deshadow"
IOS_MLMODELS = REPO_ROOT / "iosapp/CamScanShare/MLModels"

GC_SIZE = 512
DR_SIZE = 1024


def ensure_upstream() -> None:
    if not GCDR_DIR.exists():
        GCDR_DIR.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", GCDR_GIT, str(GCDR_DIR)], check=True)
    for name in ("gcnet", "drnet"):
        target = GCDR_DIR / "checkpoints" / name / "checkpoint.pkl"
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            print(f"downloading {name}.pkl ...")
            urllib.request.urlretrieve(f"{HF_BASE}/{name}.pkl", target)


def load_models():
    import torch

    sys.path.insert(0, str(GCDR_DIR))
    sys.path.insert(0, str(GCDR_DIR / "models" / "UNeXt"))
    spec = importlib.util.spec_from_file_location("gcdr_utils", GCDR_DIR / "utils.py")
    gcdr_utils = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gcdr_utils)
    from models.UNeXt.unext import (
        UNext_full_resolution_padding,
        UNext_full_resolution_padding_L_py_L,
    )

    gcnet = UNext_full_resolution_padding(num_classes=3, input_channels=3, img_size=512)
    gcnet.load_state_dict(gcdr_utils.convert_state_dict(
        torch.load(GCDR_DIR / "checkpoints/gcnet/checkpoint.pkl", map_location="cpu")["model_state"]))
    gcnet.eval()

    drnet = UNext_full_resolution_padding_L_py_L(num_classes=3, input_channels=6, img_size=512)
    drnet.load_state_dict(gcdr_utils.convert_state_dict(
        torch.load(GCDR_DIR / "checkpoints/drnet/checkpoint.pkl", map_location="cpu")["model_state"]))
    drnet.eval()

    class DRNetWrapper(torch.nn.Module):
        def __init__(self, net):
            super().__init__()
            self.net = net

        def forward(self, x):
            pred, _, _, _ = self.net(x)
            return pred

    return gcnet, DRNetWrapper(drnet)


def export_onnx_fp16(model, shape, out_path: Path) -> None:
    import onnx
    import torch
    from onnxconverter_common import float16

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fp32_path = out_path.with_suffix(".fp32.tmp.onnx")
    torch.onnx.export(
        model, torch.randn(*shape), str(fp32_path),
        input_names=["input"], output_names=["output"],
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    fp16_model = float16.convert_float_to_float16(onnx.load(str(fp32_path)), keep_io_types=True)
    onnx.save(fp16_model, str(out_path))
    fp32_path.unlink()
    print(f"exported {out_path} ({out_path.stat().st_size / 1e6:.1f} MB)")


def export_coreml(model, shape, out_path: Path) -> None:
    import coremltools as ct
    import numpy as np
    import torch

    exported = torch.export.export(model, (torch.randn(*shape),)).run_decompositions({})
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="input", shape=shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    print(f"exported {out_path}")


def main() -> None:
    ensure_upstream()
    gcnet, drnet = load_models()
    export_onnx_fp16(gcnet, (1, 3, GC_SIZE, GC_SIZE), ANDROID_ASSETS / "gcnet-512-fp16.onnx")
    export_onnx_fp16(drnet, (1, 6, DR_SIZE, DR_SIZE), ANDROID_ASSETS / "drnet-1024-fp16.onnx")
    export_coreml(gcnet, (1, 3, GC_SIZE, GC_SIZE), IOS_MLMODELS / "GCNet.mlpackage")
    export_coreml(drnet, (1, 6, DR_SIZE, DR_SIZE), IOS_MLMODELS / "DRNet.mlpackage")


if __name__ == "__main__":
    main()
