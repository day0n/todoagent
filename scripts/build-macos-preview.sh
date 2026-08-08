#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PACKAGE_DIR="$ROOT_DIR/apps/macos"
ENGINE_DIR="$ROOT_DIR/apps/engine-rs"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$(mktemp -d /tmp/todoagent-build.XXXXXX)"
APP_DIR="$STAGING_DIR/TodoAgent.app"
CONTENTS_DIR="$APP_DIR/Contents"
DMG_ROOT="$STAGING_DIR/dmg-root"
DMG_PATH="$DIST_DIR/TodoAgent-0.1.0-arm64.dmg"
TEMP_DMG_PATH="$STAGING_DIR/TodoAgent-0.1.0-arm64.dmg"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

trap 'rm -rf "$STAGING_DIR"' EXIT

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "需要安装 Xcode 26+ 才能构建 TodoAgent。" >&2
  exit 1
fi

export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/todoagent-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/todoagent-swift-cache"

swift build -c release --arch arm64 --package-path "$PACKAGE_DIR"
BIN_DIR="$(swift build -c release --arch arm64 --package-path "$PACKAGE_DIR" --show-bin-path)"
cargo build --release --locked --manifest-path "$ENGINE_DIR/Cargo.toml"
ENGINE_BIN="$ENGINE_DIR/target/release/todoagent-engine"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "本轮预览只支持在 Apple Silicon 上构建 arm64 DMG。" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$DMG_ROOT"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DMG_ROOT"
cp "$BIN_DIR/TodoAgent" "$CONTENTS_DIR/MacOS/TodoAgent"
cp "$ENGINE_BIN" "$CONTENTS_DIR/Resources/todoagent-engine"
cp "$PACKAGE_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$CONTENTS_DIR/MacOS/TodoAgent" "$CONTENTS_DIR/Resources/todoagent-engine"
strip -x "$CONTENTS_DIR/MacOS/TodoAgent" "$CONTENTS_DIR/Resources/todoagent-engine"
xattr -cr "$APP_DIR"

# Ad-hoc signing keeps the local app internally consistent without requiring a
# Developer ID. This is not a public-distribution signature.
codesign --force --sign - "$CONTENTS_DIR/Resources/todoagent-engine"
codesign --force --deep --sign - "$APP_DIR"

ditto "$APP_DIR" "$DMG_ROOT/TodoAgent.app"
ln -s /Applications "$DMG_ROOT/Applications"
xattr -cr "$DMG_ROOT/TodoAgent.app"
codesign --verify --deep --strict "$DMG_ROOT/TodoAgent.app"
rm -f "$DMG_PATH" "$TEMP_DMG_PATH"
hdiutil create -volname "TodoAgent" -srcfolder "$DMG_ROOT" -ov -format UDZO "$TEMP_DMG_PATH"
ditto "$TEMP_DMG_PATH" "$DMG_PATH"

echo "$DMG_PATH"
