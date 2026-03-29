#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="${TMPDIR:-/tmp}/camscan-magic-filter-venv"

if [ ! -d "$VENV_DIR" ]; then
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

exec python "$ROOT_DIR/scripts/generate_magic_filter_steps.py" "$@"
