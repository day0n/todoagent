#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PACKAGE_DIR="$ROOT_DIR/apps/macos"
ENGINE_DIR="$ROOT_DIR/apps/engine-rs"
GHOSTTY_SETUP="$ROOT_DIR/scripts/setup-ghostty.sh"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP_LINK="$DIST_DIR/TodoAgent.app"
STAGING_DIR="$(mktemp -d /tmp/todoagent-build.XXXXXX)"
APP_DIR="$STAGING_DIR/TodoAgent.app"
CONTENTS_DIR="$APP_DIR/Contents"
DMG_ROOT="$STAGING_DIR/dmg-root"
DMG_PATH="$DIST_DIR/TodoAgent-0.1.0-arm64.dmg"
# Desktop may be backed by iCloud Drive. Its File Provider adds FinderInfo to
# copied app bundles asynchronously, which invalidates an otherwise correct
# code signature. Keep the directly launchable preview in the user's native
# temporary directory and reserve `dist/` for the immutable DMG artifact. This
# is a disposable daily build, so callers should not persist its path.
PREVIEW_ROOT="${TODOAGENT_PREVIEW_ROOT:-${TMPDIR:-/tmp}TodoAgentPreview}"
DIST_APP_PATH="$PREVIEW_ROOT/TodoAgent.app"
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

verify_license_bundle() {
  local bundle_path="$1"
  local license_dir
  license_dir="$(find "$bundle_path/Contents/Resources" -type d -name ThirdPartyLicenses -print -quit)"
  [[ -n "$license_dir" && -f "$license_dir/MANIFEST.md" ]] || {
    echo "发布包缺少 ThirdPartyLicenses/MANIFEST.md。" >&2
    return 1
  }
  local rows=0 file expected actual
  # Parse the Markdown table into a tab-delimited stream first. Matching the
  # literal table pipes directly with zsh's regex operator is error-prone
  # because an unescaped `|` becomes alternation and can match an empty row.
  while IFS=$'\t' read -r file expected; do
    [[ -f "$license_dir/$file" ]] || {
      echo "发布包缺少第三方许可：$file" >&2
      return 1
    }
    actual="$(shasum -a 256 "$license_dir/$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
      echo "发布包第三方许可校验失败：$file" >&2
      return 1
    }
    rows=$((rows + 1))
  done < <(
    awk -F '|' '
      $2 ~ /^[[:space:]]*`[^`]+`[[:space:]]*$/ &&
      $3 ~ /^[[:space:]]*`[0-9a-f]+`[[:space:]]*$/ {
        gsub(/^[[:space:]]*`|`[[:space:]]*$/, "", $2)
        gsub(/^[[:space:]]*`|`[[:space:]]*$/, "", $3)
        if (length($3) == 64) print $2 "\t" $3
      }
    ' "$license_dir/MANIFEST.md"
  )
  [[ "$rows" -eq 30 ]] || {
    echo "发布包第三方许可条目应为 30，实际为 $rows。" >&2
    return 1
  }
  [[ "$(find "$license_dir" -type f | wc -l | tr -d ' ')" -eq 31 ]] || {
    echo "发布包 ThirdPartyLicenses 文件数必须为 31。" >&2
    return 1
  }
  local provenance="$bundle_path/Contents/Resources/GHOSTTY_SOURCE_PROVENANCE.md"
  [[ -f "$provenance" ]] || {
    echo "发布包缺少 Ghostty exact source provenance。" >&2
    return 1
  }
  cmp -s "$ROOT_DIR/vendor/ghostty/dependency-licenses.md" "$provenance" || {
    echo "发布包 Ghostty exact source provenance 已过期。" >&2
    return 1
  }
}

if [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "需要安装 Xcode 26+ 才能构建 TodoAgent。" >&2
  exit 1
fi

export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/todoagent-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/todoagent-swift-cache"

# SwiftPM deliberately references a generated, pinned Ghostty XCFramework. A
# clean checkout has no opaque binary in Git, so make the build dependency
# explicit and reproducible before asking SwiftPM to resolve the package.
if ! "$GHOSTTY_SETUP" --check; then
  "$GHOSTTY_SETUP"
fi

swift build --disable-sandbox -c release --arch arm64 \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SWIFT_SCRATCH_DIR"
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SWIFT_SCRATCH_DIR" \
  --show-bin-path)"
cargo build --release --locked --bins --manifest-path "$ENGINE_DIR/Cargo.toml"
ENGINE_BIN="$ENGINE_DIR/target/release/todoagent-engine"
TERMINAL_RUNNER_BIN="$ENGINE_DIR/target/release/todoagent-terminal-runner"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "本轮预览只支持在 Apple Silicon 上构建 arm64 DMG。" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$DMG_ROOT"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DMG_ROOT"
cp "$BIN_DIR/TodoAgent" "$CONTENTS_DIR/MacOS/TodoAgent"
# A signed macOS app must keep its SwiftPM resource bundle inside the standard
# Resources directory. TodoAgentResourceBundle resolves this packaged location
# before falling back to SwiftPM's generated development accessor.
cp -R "$BIN_DIR/TodoAgentNative_TodoAgentApp.bundle" "$CONTENTS_DIR/Resources/"
cp "$ENGINE_BIN" "$CONTENTS_DIR/Resources/todoagent-engine"
cp "$TERMINAL_RUNNER_BIN" "$CONTENTS_DIR/Resources/todoagent-terminal-runner"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$CONTENTS_DIR/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/vendor/ghostty/dependency-licenses.md" \
  "$CONTENTS_DIR/Resources/GHOSTTY_SOURCE_PROVENANCE.md"
cp "$PACKAGE_DIR/Resources/TodoAgent.icns" "$CONTENTS_DIR/Resources/TodoAgent.icns"
cp "$PACKAGE_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
verify_license_bundle "$APP_DIR"
chmod +x \
  "$CONTENTS_DIR/MacOS/TodoAgent" \
  "$CONTENTS_DIR/Resources/todoagent-engine" \
  "$CONTENTS_DIR/Resources/todoagent-terminal-runner"

# The generated SwiftPM resource accessor contains a build-machine fallback.
# Remove that disposable source bundle, then execute the staged App itself so
# the release must resolve Contents/Resources and initialize Ghostty without
# help from the scratch build directory.
rm -rf "$BIN_DIR/TodoAgentNative_TodoAgentApp.bundle"
"$CONTENTS_DIR/MacOS/TodoAgent" --verify-packaged-resources >/dev/null

strip -x \
  "$CONTENTS_DIR/MacOS/TodoAgent" \
  "$CONTENTS_DIR/Resources/todoagent-engine" \
  "$CONTENTS_DIR/Resources/todoagent-terminal-runner"
xattr -cr "$APP_DIR"

# Sign inside-out with an ad-hoc identity for local preview builds. Credentials
# are stored in an account-private Application Support file, so rebuilds no
# longer depend on a stable Keychain code-signing requirement.
codesign --force --timestamp=none \
  --options runtime \
  --identifier org.niuzj.todoagent.engine \
  --sign - \
  "$CONTENTS_DIR/Resources/todoagent-engine"
codesign --force --timestamp=none \
  --options runtime \
  --identifier org.niuzj.todoagent.terminal-runner \
  --sign - \
  "$CONTENTS_DIR/Resources/todoagent-terminal-runner"
codesign --force --timestamp=none \
  --options runtime \
  --identifier org.niuzj.todoagent \
  --sign - \
  "$APP_DIR"

# Keep the signed development app outside Desktop/iCloud File Provider, then
# expose the established dist/TodoAgent.app path as a disposable symlink.
# Day-to-day testing can open that path without copying into /Applications.
mkdir -p "$DIST_DIR" "$PREVIEW_ROOT"
rm -rf "$DIST_APP_PATH"
ditto --noextattr --noqtn "$APP_DIR" "$DIST_APP_PATH"
verify_bundle "$DIST_APP_PATH"

ditto --noextattr --noqtn "$APP_DIR" "$DMG_ROOT/TodoAgent.app"
ln -s /Applications "$DMG_ROOT/Applications"
verify_bundle "$DMG_ROOT/TodoAgent.app"
rm -f "$DMG_PATH" "$TEMP_DMG_PATH"
hdiutil create -volname "TodoAgent" -srcfolder "$DMG_ROOT" -ov -format UDZO "$TEMP_DMG_PATH"
ditto "$TEMP_DMG_PATH" "$DMG_PATH"
verify_bundle "$DIST_APP_PATH"
rm -rf "$DIST_APP_LINK"
ln -s "$DIST_APP_PATH" "$DIST_APP_LINK"

echo "$DIST_APP_LINK -> $DIST_APP_PATH"
echo "$DMG_PATH"
