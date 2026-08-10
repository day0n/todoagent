#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SOURCE_SVG="$ROOT_DIR/apps/macos/Resources/TodoAgentAppIcon.svg"
APP_ICON_DIR="$ROOT_DIR/apps/macos/Resources/Assets.xcassets/AppIcon.appiconset"
OUTPUT_ICNS="$ROOT_DIR/apps/macos/Resources/TodoAgent.icns"

if [[ ! -x /opt/homebrew/bin/rsvg-convert ]]; then
  echo "缺少 rsvg-convert；请先安装 librsvg。" >&2
  exit 1
fi

mkdir -p "$APP_ICON_DIR"

render_icon() {
  local pixels="$1"
  local output="$2"
  /opt/homebrew/bin/rsvg-convert \
    --width "$pixels" \
    --height "$pixels" \
    "$SOURCE_SVG" \
    --output "$output"
}

render_icon 16 "$APP_ICON_DIR/icon_16x16.png"
render_icon 32 "$APP_ICON_DIR/icon_16x16@2x.png"
render_icon 32 "$APP_ICON_DIR/icon_32x32.png"
render_icon 64 "$APP_ICON_DIR/icon_32x32@2x.png"
render_icon 128 "$APP_ICON_DIR/icon_128x128.png"
render_icon 256 "$APP_ICON_DIR/icon_128x128@2x.png"
render_icon 256 "$APP_ICON_DIR/icon_256x256.png"
render_icon 512 "$APP_ICON_DIR/icon_256x256@2x.png"
render_icon 512 "$APP_ICON_DIR/icon_512x512.png"
render_icon 1024 "$APP_ICON_DIR/icon_512x512@2x.png"

python3 "$ROOT_DIR/scripts/build-icns.py" "$APP_ICON_DIR" "$OUTPUT_ICNS"
echo "$OUTPUT_ICNS"
