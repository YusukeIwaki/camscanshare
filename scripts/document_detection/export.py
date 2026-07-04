"""Export the trained page-segmentation detector to ONNX (Android) + Core ML (iOS).

  .venv/bin/python scripts/document_detection/export.py --checkpoint tmp/docdet-v1/best.pt

Produces:
  androidapp/app/src/main/assets/document_detection/pageseg-320-fp16.onnx
  iosapp/CamScanShare/MLModels/PageSegNet.mlpackage

Input:  NCHW float32 RGB in [0,1], 1x3x320x320.
Output: N1HW float32 page probability in [0,1] (sigmoid folded into the graph).
"""

import argparse
import os
import sys
from pathlib import Path

import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seg_model import PageSegNet

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ANDROID_ASSETS = REPO_ROOT / "androidapp/app/src/main/assets/document_detection"
IOS_MLMODELS = REPO_ROOT / "iosapp/CamScanShare/MLModels"
SIZE = 320


class SigmoidWrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.sigmoid(self.net(x))


def export_onnx_fp16(model, out_path: Path):
    import onnx
    from onnxconverter_common import float16

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fp32 = out_path.with_suffix(".fp32.tmp.onnx")
    torch.onnx.export(
        model, torch.randn(1, 3, SIZE, SIZE), str(fp32),
        input_names=["input"], output_names=["output"],
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    fp16 = float16.convert_float_to_float16(onnx.load(str(fp32)), keep_io_types=True)
    onnx.save(fp16, str(out_path))
    fp32.unlink()
    print(f"exported {out_path} ({out_path.stat().st_size/1e6:.2f} MB)")


def export_coreml(model, out_path: Path):
    import coremltools as ct
    import numpy as np

    exported = torch.export.export(model, (torch.randn(1, 3, SIZE, SIZE),)).run_decompositions({})
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="input", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    print(f"exported {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--width", type=float, default=1.0)
    ap.add_argument("--onnx-only", action="store_true")
    args = ap.parse_args()

    net = PageSegNet(width=args.width)
    net.load_state_dict(torch.load(args.checkpoint, map_location="cpu"))
    net.eval()
    model = SigmoidWrapper(net).eval()

    # smoke test
    with torch.no_grad():
        y = model(torch.randn(1, 3, SIZE, SIZE))
    assert y.shape == (1, 1, SIZE, SIZE), y.shape
    print("forward ok, output", tuple(y.shape), "range", float(y.min()), float(y.max()))

    export_onnx_fp16(model, ANDROID_ASSETS / f"pageseg-{SIZE}-fp16.onnx")
    if not args.onnx_only:
        export_coreml(model, IOS_MLMODELS / "PageSegNet.mlpackage")


if __name__ == "__main__":
    main()
