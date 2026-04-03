#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_opencv_xcframework.sh [options]

Builds iosapp/Vendor/opencv2.xcframework from OpenCV source and repacks it into
the static-library xcframework layout used by this repository.

Options:
  --version <tag>     OpenCV tag to build. Default: 4.13.0
  --output <path>     Output xcframework path.
                      Default: iosapp/Vendor/opencv2.xcframework
  --work-dir <path>   Reuse a work directory instead of a temporary directory.
  --keep-work         Do not delete the work directory after finishing.
  -h, --help          Show this help.
EOF
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION="4.13.0"
OUTPUT_PATH="$REPO_ROOT/iosapp/Vendor/opencv2.xcframework"
WORK_DIR=""
KEEP_WORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd curl tar python3 cmake xcodebuild shasum

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/camscanshare-opencv.XXXXXX")"
else
  mkdir -p "$WORK_DIR"
fi

cleanup() {
  if [[ "$KEEP_WORK" -eq 1 ]]; then
    echo "Keeping work directory: $WORK_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SOURCE_ARCHIVE="$WORK_DIR/opencv-${VERSION}.tar.gz"
SOURCE_DIR="$WORK_DIR/src"
BUILD_DIR="$WORK_DIR/build"
REPACK_DIR="$WORK_DIR/repack"
TMP_OUTPUT="$WORK_DIR/opencv2.xcframework"
SOURCE_URL="https://github.com/opencv/opencv/archive/refs/tags/${VERSION}.tar.gz"

mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$REPACK_DIR"

echo "Downloading OpenCV ${VERSION} source..."
curl -L --fail --show-error "$SOURCE_URL" -o "$SOURCE_ARCHIVE"

echo "Extracting sources..."
tar -xzf "$SOURCE_ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"

COMMON_BUILD_ARGS=(
  --build_only_specified_archs
  --legacy_build
  --disable-swift
)

echo "Building iphoneos (arm64)..."
python3 "$SOURCE_DIR/platforms/ios/build_framework.py" \
  "$BUILD_DIR/iphoneos" \
  --iphoneos_archs arm64 \
  "${COMMON_BUILD_ARGS[@]}"

echo "Building iphonesimulator (x86_64,arm64)..."
python3 "$SOURCE_DIR/platforms/ios/build_framework.py" \
  "$BUILD_DIR/iphonesimulator" \
  --iphonesimulator_archs x86_64,arm64 \
  "${COMMON_BUILD_ARGS[@]}"

echo "Repacking framework binaries as static libraries..."
mkdir -p "$REPACK_DIR/device/Headers/opencv2" "$REPACK_DIR/sim/Headers/opencv2"
cp "$BUILD_DIR/iphoneos/opencv2.framework/Versions/A/opencv2" "$REPACK_DIR/device/libopencv_merged.a"
cp "$BUILD_DIR/iphonesimulator/opencv2.framework/Versions/A/opencv2" "$REPACK_DIR/sim/libopencv_merged.a"
cp -R "$BUILD_DIR/iphoneos/opencv2.framework/Versions/A/Headers/." "$REPACK_DIR/device/Headers/opencv2"
cp -R "$BUILD_DIR/iphonesimulator/opencv2.framework/Versions/A/Headers/." "$REPACK_DIR/sim/Headers/opencv2"

rm -rf "$TMP_OUTPUT"
echo "Creating xcframework..."
xcodebuild -create-xcframework \
  -library "$REPACK_DIR/device/libopencv_merged.a" \
  -headers "$REPACK_DIR/device/Headers" \
  -library "$REPACK_DIR/sim/libopencv_merged.a" \
  -headers "$REPACK_DIR/sim/Headers" \
  -output "$TMP_OUTPUT"

rm -rf "$OUTPUT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")"
mv "$TMP_OUTPUT" "$OUTPUT_PATH"

echo "Generated $OUTPUT_PATH"
shasum -a 256 \
  "$OUTPUT_PATH/ios-arm64/libopencv_merged.a" \
  "$OUTPUT_PATH/ios-arm64_x86_64-simulator/libopencv_merged.a"
