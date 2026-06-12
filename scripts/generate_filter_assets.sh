#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="${TMPDIR:-/tmp}/camscan-magic-filter-venv"

if [ ! -f "$VENV_DIR/bin/activate" ]; then
  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

if ! python - <<'PY'
import importlib.util
import sys

missing = [
    name for name in ("cv2", "numpy")
    if importlib.util.find_spec(name) is None
]
if missing:
    sys.exit(1)
PY
then
  pip install opencv-python-headless numpy
fi

python "$ROOT_DIR/scripts/generate_step0_samples.py" "$@"
python "$ROOT_DIR/scripts/generate_step1_aspect_samples.py" "$@"
python "$ROOT_DIR/scripts/generate_magic_filter_steps.py" "$@"
python "$ROOT_DIR/scripts/generate_simple_filter_samples.py" "$@"

# 影除去 (deshadow) は onnxruntime が必要。リポジトリの .venv を優先して使う。
if [ -x "$ROOT_DIR/.venv/bin/python" ] && "$ROOT_DIR/.venv/bin/python" -c "import onnxruntime" 2>/dev/null; then
  "$ROOT_DIR/.venv/bin/python" "$ROOT_DIR/scripts/generate_deshadow_filter_samples.py" "$@"
else
  pip install onnxruntime >/dev/null
  python "$ROOT_DIR/scripts/generate_deshadow_filter_samples.py" "$@"
fi
