#!/bin/bash
# Save a screenshot from the connected Android device
# Usage: ./scripts/save-screenshot.sh [output_path]

OUTPUT="${1:-/tmp/adb_screencap/screen.png}"
mkdir -p "$(dirname "$OUTPUT")"

adb shell screencap -p /sdcard/screencap_tmp.png
adb pull /sdcard/screencap_tmp.png "$OUTPUT" 2>/dev/null
adb shell rm /sdcard/screencap_tmp.png

# Resize if ffmpeg is available (keep width ≤ 810px)
if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i "$OUTPUT" -vf "scale='min(810,iw)':-2" "$OUTPUT" 2>/dev/null
fi

echo "$OUTPUT"
