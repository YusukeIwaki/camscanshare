from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import torch

from .seg_model import INPUT_SIZE, PageSegNet, count_parameters, load_checkpoint_state

LEGACY_COREML_NAMES = ("PageSegMobileNetV3Small.mlpackage",)


def load_export_model(checkpoint: Path) -> PageSegNet:
    model = PageSegNet(pretrained=False, include_sigmoid=True)
    model.load_state_dict(load_checkpoint_state(checkpoint))
    model.eval()
    return model


def export_onnx(model: PageSegNet, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    torch.onnx.export(
        model,
        dummy,
        str(out_path),
        input_names=["input"],
        output_names=["probability"],
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    print(f"exported ONNX fp32: {out_path} ({out_path.stat().st_size / 1e6:.2f} MB)")


def export_onnx_fp16(in_path: Path, out_path: Path) -> None:
    try:
        import onnx
        from onnxconverter_common import float16
    except Exception as exc:
        print(f"skipping ONNX fp16 conversion; dependency unavailable: {exc}")
        return
    model = onnx.load(str(in_path))
    fp16_model = float16.convert_float_to_float16(model, keep_io_types=True)
    onnx.save(fp16_model, str(out_path))
    print(f"exported ONNX fp16: {out_path} ({out_path.stat().st_size / 1e6:.2f} MB)")


def export_coreml(model: PageSegNet, out_path: Path) -> None:
    import coremltools as ct
    import numpy as np

    out_path.parent.mkdir(parents=True, exist_ok=True)
    exported = torch.export.export(model, (torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE),)).run_decompositions({})
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="input", shape=(1, 3, INPUT_SIZE, INPUT_SIZE), dtype=np.float32)],
        outputs=[ct.TensorType(name="probability", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.save(str(out_path))
    print(f"exported Core ML fp16: {out_path}")


def replace_path(source: Path, target: Path) -> None:
    if target.exists():
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
    shutil.copytree(source, target)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export document detector with sigmoid folded into the graph.")
    parser.add_argument("--checkpoint", default="tmp/docdet-v3/best.pt")
    parser.add_argument("--out-dir", default="tmp/docdet-v3/export")
    parser.add_argument("--coreml-name", default="PageSegNet.mlpackage")
    parser.add_argument("--ios-models-dir", default=None)
    parser.add_argument("--onnx-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    checkpoint = Path(args.checkpoint)
    out_dir = Path(args.out_dir)
    model = load_export_model(checkpoint)
    with torch.no_grad():
        y = model(torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE))
    if tuple(y.shape) != (1, 1, INPUT_SIZE, INPUT_SIZE):
        raise RuntimeError(f"unexpected output shape: {tuple(y.shape)}")
    print(f"forward ok: shape={tuple(y.shape)} range=({float(y.min()):.4f}, {float(y.max()):.4f})")
    print(f"parameters: {count_parameters(model):,}")

    onnx_fp32 = out_dir / f"pageseg-mnv3s-{INPUT_SIZE}-sigmoid.fp32.onnx"
    onnx_fp16 = out_dir / f"pageseg-mnv3s-{INPUT_SIZE}-sigmoid.fp16.onnx"
    export_onnx(model, onnx_fp32)
    export_onnx_fp16(onnx_fp32, onnx_fp16)
    if not args.onnx_only:
        coreml_path = out_dir / args.coreml_name
        export_coreml(model, coreml_path)
        if args.ios_models_dir:
            ios_models_dir = Path(args.ios_models_dir)
            target_path = ios_models_dir / args.coreml_name
            ios_models_dir.mkdir(parents=True, exist_ok=True)
            replace_path(coreml_path, target_path)
            print(f"copied Core ML package to iOS app: {target_path}")
            for legacy_name in LEGACY_COREML_NAMES:
                legacy_path = ios_models_dir / legacy_name
                if legacy_path != target_path and legacy_path.exists():
                    if legacy_path.is_dir():
                        shutil.rmtree(legacy_path)
                    else:
                        legacy_path.unlink()
                    print(f"removed legacy Core ML package from iOS app: {legacy_path}")


if __name__ == "__main__":
    main()
