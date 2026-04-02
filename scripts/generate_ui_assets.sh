#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
BASE_URL="${ASSET_BASE_URL:-http://127.0.0.1:4321}"
STUDIO_URL="$BASE_URL/mockups/asset-studio.html"
SESSION_NAME="${AGENT_BROWSER_SESSION:-camscanshare-ui-assets-$$}"
TMP_DIR="${TMPDIR:-/tmp}/camscanshare-ui-assets"

MASTER_DIR="$ROOT_DIR/docs/public/generated/ui-assets"
ICON_SVG_SOURCE="$ROOT_DIR/docs/public/mockups/app-icon.svg"
IOS_ICON_SVG_SOURCE="$ROOT_DIR/docs/public/mockups/app-icon-ios.svg"
ICON_FOREGROUND_SVG_SOURCE="$ROOT_DIR/docs/public/mockups/app-icon-foreground.svg"
ICON_MONOCHROME_SVG_SOURCE="$ROOT_DIR/docs/public/mockups/app-icon-monochrome.svg"
ANDROID_DRAWABLE_DIR="$ROOT_DIR/androidapp/app/src/main/res/drawable"
ANDROID_MIPMAP_BASE="$ROOT_DIR/androidapp/app/src/main/res"
IOS_ASSET_DIR="$ROOT_DIR/iosapp/CamScanShare/Assets.xcassets"

DOCS_PID=""

cleanup() {
  if [[ -n "$DOCS_PID" ]]; then
    kill "$DOCS_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_cmd agent-browser
require_cmd curl

if command -v magick >/dev/null 2>&1; then
  MAGICK=(magick)
else
  require_cmd convert
  MAGICK=(convert)
fi

mkdir -p "$TMP_DIR" "$MASTER_DIR" "$ANDROID_DRAWABLE_DIR" "$IOS_ASSET_DIR"

if ! curl -sf "$STUDIO_URL" >/dev/null 2>&1; then
  (
    cd "$DOCS_DIR"
    npm run dev -- --host 127.0.0.1 --port 4321 >"$TMP_DIR/docs-dev.log" 2>&1
  ) &
  DOCS_PID=$!

  for _ in {1..40}; do
    if curl -sf "$STUDIO_URL" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if ! curl -sf "$STUDIO_URL" >/dev/null 2>&1; then
  echo "Docs server did not become ready at $STUDIO_URL" >&2
  exit 1
fi

capture_asset() {
  local asset_id="$1"
  local width="$2"
  local height="$3"
  local output_path="$4"

  mkdir -p "$(dirname "$output_path")"
  agent-browser --session "$SESSION_NAME" open "${STUDIO_URL}?asset=${asset_id}" >/dev/null
  agent-browser --session "$SESSION_NAME" set viewport "$width" "$height" >/dev/null
  agent-browser --session "$SESSION_NAME" wait 300 >/dev/null
  agent-browser --session "$SESSION_NAME" screenshot "$output_path" >/dev/null
}

render_svg() {
  local input_path="$1"
  local width="$2"
  local height="$3"
  local output_path="$4"

  mkdir -p "$(dirname "$output_path")"
  rsvg-convert -w "$width" -h "$height" "$input_path" >"$output_path"
}

resize_exact() {
  local input_path="$1"
  local size="$2"
  local output_path="$3"

  mkdir -p "$(dirname "$output_path")"
  "${MAGICK[@]}" "$input_path" -resize "${size}x${size}" -background none -gravity center -extent "${size}x${size}" "$output_path"
}

resize_box() {
  local input_path="$1"
  local width="$2"
  local height="$3"
  local output_path="$4"

  mkdir -p "$(dirname "$output_path")"
  "${MAGICK[@]}" "$input_path" -resize "${width}x${height}!" "$output_path"
}

cp "$ICON_SVG_SOURCE" "$MASTER_DIR/app-icon.svg"
cp "$IOS_ICON_SVG_SOURCE" "$MASTER_DIR/app-icon-ios.svg"
cp "$ICON_FOREGROUND_SVG_SOURCE" "$MASTER_DIR/app-icon-foreground.svg"
cp "$ICON_MONOCHROME_SVG_SOURCE" "$MASTER_DIR/app-icon-monochrome.svg"
render_svg "$ICON_SVG_SOURCE" 1024 1024 "$MASTER_DIR/app-icon.png"
render_svg "$IOS_ICON_SVG_SOURCE" 1024 1024 "$MASTER_DIR/app-icon-ios.png"
render_svg "$ICON_FOREGROUND_SVG_SOURCE" 1024 1024 "$MASTER_DIR/app-icon-foreground.png"
render_svg "$ICON_MONOCHROME_SVG_SOURCE" 1024 1024 "$MASTER_DIR/app-icon-monochrome.png"
capture_asset "filter-original" 384 480 "$MASTER_DIR/filter-original.png"
capture_asset "filter-sharpen" 384 480 "$MASTER_DIR/filter-sharpen.png"
capture_asset "filter-bw" 384 480 "$MASTER_DIR/filter-bw.png"
capture_asset "filter-magic" 384 480 "$MASTER_DIR/filter-magic.png"
capture_asset "filter-whiteboard" 384 480 "$MASTER_DIR/filter-whiteboard.png"
capture_asset "filter-vivid" 384 480 "$MASTER_DIR/filter-vivid.png"

for density in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  name="${density%%:*}"
  size="${density##*:}"
  resize_exact "$MASTER_DIR/app-icon.png" "$size" "$ANDROID_MIPMAP_BASE/mipmap-$name/ic_launcher.png"
done

for density in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  name="${density%%:*}"
  size="${density##*:}"
  resize_exact "$MASTER_DIR/app-icon-foreground.png" "$size" "$ANDROID_MIPMAP_BASE/mipmap-$name/ic_launcher_foreground.png"
  resize_exact "$MASTER_DIR/app-icon-monochrome.png" "$size" "$ANDROID_MIPMAP_BASE/mipmap-$name/ic_launcher_monochrome.png"
done

resize_box "$MASTER_DIR/filter-original.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_original.png"
resize_box "$MASTER_DIR/filter-sharpen.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_sharpen.png"
resize_box "$MASTER_DIR/filter-bw.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_bw.png"
resize_box "$MASTER_DIR/filter-magic.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_magic.png"
resize_box "$MASTER_DIR/filter-whiteboard.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_whiteboard.png"
resize_box "$MASTER_DIR/filter-vivid.png" 192 240 "$ANDROID_DRAWABLE_DIR/filter_thumbnail_vivid.png"

declare -A IOS_FILTERS=(
  [FilterOriginal.imageset]="filter-original.png"
  [FilterSharpen.imageset]="filter-sharpen.png"
  [FilterBW.imageset]="filter-bw.png"
  [FilterMagic.imageset]="filter-magic.png"
  [FilterWhiteboard.imageset]="filter-whiteboard.png"
  [FilterVivid.imageset]="filter-vivid.png"
)

for dir_name in "${!IOS_FILTERS[@]}"; do
  mkdir -p "$IOS_ASSET_DIR/$dir_name"
  resize_box "$MASTER_DIR/${IOS_FILTERS[$dir_name]}" 384 480 "$IOS_ASSET_DIR/$dir_name/thumbnail.png"
done

declare -a IOS_ICON_SPECS=(
  "icon-20@2x.png:40"
  "icon-20@3x.png:60"
  "icon-29@2x.png:58"
  "icon-29@3x.png:87"
  "icon-40@2x.png:80"
  "icon-40@3x.png:120"
  "icon-60@2x.png:120"
  "icon-60@3x.png:180"
  "icon-76.png:76"
  "icon-76@2x.png:152"
  "icon-83.5@2x.png:167"
  "icon-1024.png:1024"
)

mkdir -p "$IOS_ASSET_DIR/AppIcon.appiconset"
for spec in "${IOS_ICON_SPECS[@]}"; do
  file_name="${spec%%:*}"
  size="${spec##*:}"
  resize_exact "$MASTER_DIR/app-icon-ios.png" "$size" "$IOS_ASSET_DIR/AppIcon.appiconset/$file_name"
done

agent-browser --session "$SESSION_NAME" close >/dev/null || true

echo "Generated shared UI assets:"
echo "  $MASTER_DIR"
echo "  $ANDROID_DRAWABLE_DIR"
echo "  $ANDROID_MIPMAP_BASE/mipmap-*"
echo "  $IOS_ASSET_DIR"
