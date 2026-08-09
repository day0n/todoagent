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
DIST_APP_PATH="$DIST_DIR/TodoAgent.app"
TEMP_DMG_PATH="$STAGING_DIR/TodoAgent-0.1.0-arm64.dmg"
SWIFT_SCRATCH_DIR="$STAGING_DIR/swift-build"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

trap 'rm -rf "$STAGING_DIR"' EXIT

clear_bundle_xattrs() {
  local bundle_path="$1"
  xattr -cr "$bundle_path"
  xattr -d com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$bundle_path" 2>/dev/null || true
}

verify_bundle() {
  local bundle_path="$1"
  local attempt
  for attempt in 1 2 3; do
    clear_bundle_xattrs "$bundle_path"
    if codesign --verify --deep --strict "$bundle_path" 2>/dev/null; then
      return 0
    fi
  done
  codesign --verify --deep --strict --verbose=2 "$bundle_path"
}

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "需要安装 Xcode 26+ 才能构建 TodoAgent。" >&2
  exit 1
fi

export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/todoagent-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/todoagent-swift-cache"

swift build --disable-sandbox -c release --arch arm64 \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SWIFT_SCRATCH_DIR"
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SWIFT_SCRATCH_DIR" \
  --show-bin-path)"
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

# Sign inside-out with an ad-hoc identity for local preview builds. Credentials
# are stored in an account-private Application Support file, so rebuilds no
# longer depend on a stable Keychain code-signing requirement.
codesign --force --timestamp=none \
  --identifier org.niuzj.todoagent.engine \
  --sign - \
  "$CONTENTS_DIR/Resources/todoagent-engine"
codesign --force --timestamp=none \
  --identifier org.niuzj.todoagent \
  --sign - \
  "$APP_DIR"

# Keep a directly launchable development build in dist. Day-to-day testing can
# open this app in place and does not require copying it into /Applications.
mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP_PATH"
ditto --noextattr --noqtn "$APP_DIR" "$DIST_APP_PATH"
verify_bundle "$DIST_APP_PATH"

ditto --noextattr --noqtn "$APP_DIR" "$DMG_ROOT/TodoAgent.app"
ln -s /Applications "$DMG_ROOT/Applications"
verify_bundle "$DMG_ROOT/TodoAgent.app"
rm -f "$DMG_PATH" "$TEMP_DMG_PATH"
hdiutil create -volname "TodoAgent" -srcfolder "$DMG_ROOT" -ov -format UDZO "$TEMP_DMG_PATH"
ditto "$TEMP_DMG_PATH" "$DMG_PATH"

echo "$DIST_APP_PATH"
echo "$DMG_PATH"
