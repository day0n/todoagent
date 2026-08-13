#!/usr/bin/env bash
# Build TodoAgent's pinned GhosttyKit and runtime resources from upstream source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIN_FILE="$REPO_ROOT/vendor/ghostty/pins.json"
XCFRAMEWORK_DEST="$REPO_ROOT/apps/macos/Vendor/GhosttyKit.xcframework"
RESOURCE_DEST="$REPO_ROOT/apps/macos/Sources/TodoAgentApp/TerminalResources"
STAMP_FILE="$REPO_ROOT/apps/macos/Vendor/.ghostty-build-stamp"
ARTIFACT_MANIFEST="$REPO_ROOT/apps/macos/Vendor/.ghostty-artifacts.sha256"
GPL_LICENSE="$REPO_ROOT/vendor/ghostty/GPL-3.0.txt"
LICENSE_DIRECTORY="$RESOURCE_DEST/ThirdPartyLicenses"
LICENSE_MANIFEST="$LICENSE_DIRECTORY/MANIFEST.md"

GHOSTTY_REPOSITORY="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_REVISION="4dcb09ada0c0909717d92547623b26eafa50ca8a"
GHOSTTY_ARCHIVE_URL="https://github.com/ghostty-org/ghostty/archive/4dcb09ada0c0909717d92547623b26eafa50ca8a.tar.gz"
GHOSTTY_ARCHIVE_SHA256="8a67a97935fee8e3de5132c1c52a54b48cf2b5aef4f71358e4c3cfd547e690c1"
ZIG_VERSION="0.15.2"
GHOSTTY_BUILD_FEATURES="i18n=false,sentry=false,themes=false"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-ghostty.sh [--check | --force]

Builds the exact Ghostty revision recorded in vendor/ghostty/pins.json.
Prerequisites are intentionally not installed automatically.

  --check  Validate an existing framework/resource installation without building.
  --force  Rebuild even when the installed artifact fingerprint is current.
EOF
}

fail() {
  echo "setup-ghostty: $*" >&2
  exit 1
}

json_value() {
  /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]][sys.argv[3]])' \
    "$PIN_FILE" "$1" "$2"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

validate_license_bundle() {
  [[ -f "$LICENSE_MANIFEST" ]] || fail "missing third-party license manifest"
  local rows=0 line file expected actual
  while IFS= read -r line; do
    [[ "$line" =~ ^\|\ \`([^\`]*)\`\ \|\ \`([0-9a-f]{64})\`\ \|$ ]] || continue
    file="${BASH_REMATCH[1]}"
    expected="${BASH_REMATCH[2]}"
    [[ "$file" != "MANIFEST.md" ]] || fail "license manifest must not hash itself"
    [[ -f "$LICENSE_DIRECTORY/$file" ]] || fail "missing third-party license: $file"
    actual="$(sha256 "$LICENSE_DIRECTORY/$file")"
    [[ "$actual" == "$expected" ]] || fail "third-party license checksum mismatch: $file"
    rows=$((rows + 1))
  done < "$LICENSE_MANIFEST"
  [[ "$rows" -eq 30 ]] || fail "expected 30 third-party license entries, found $rows"
  [[ "$(find "$LICENSE_DIRECTORY" -type f | wc -l | tr -d ' ')" -eq 31 ]] || \
    fail "ThirdPartyLicenses must contain exactly MANIFEST plus 30 license texts"
}

build_fingerprint() {
  local xcode_identity
  xcode_identity="$(xcodebuild -version 2>/dev/null | paste -sd ';' -)"
  printf 'ghostty=%s archive=%s zig=%s features=%s xcode=%s arch=%s script=%s pins=%s' \
    "$GHOSTTY_REVISION" \
    "$GHOSTTY_ARCHIVE_SHA256" \
    "$ZIG_VERSION" \
    "$GHOSTTY_BUILD_FEATURES" \
    "$xcode_identity" \
    "$(uname -m)" \
    "$(sha256 "$SCRIPT_DIR/setup-ghostty.sh")" \
    "$(sha256 "$PIN_FILE")"
}

validate_manifest() {
  [[ -f "$PIN_FILE" ]] || fail "missing $PIN_FILE"
  [[ -f "$GPL_LICENSE" ]] || fail "missing $GPL_LICENSE"
  [[ "$(sha256 "$GPL_LICENSE")" == "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986" ]] || \
    fail "GPLv3 license text checksum mismatch"
  [[ "$(json_value ghostty repository)" == "$GHOSTTY_REPOSITORY" ]] || fail "script/repository pin mismatch"
  [[ "$(json_value ghostty revision)" == "$GHOSTTY_REVISION" ]] || fail "script/revision pin mismatch"
  [[ "$(json_value ghostty sourceArchive)" == "$GHOSTTY_ARCHIVE_URL" ]] || fail "script/archive URL pin mismatch"
  [[ "$(json_value ghostty sourceArchiveSHA256)" == "$GHOSTTY_ARCHIVE_SHA256" ]] || fail "script/archive hash pin mismatch"
  [[ "$(json_value toolchain zig)" == "$ZIG_VERSION" ]] || fail "script/Zig pin mismatch"
}

framework_header() {
  find "$1" -type f -path '*/Headers/ghostty.h' -print -quit
}

framework_library() {
  find "$1" -type f \( -name 'ghostty-internal.a' -o -name 'libghostty*.a' \) -print -quit
}

validate_installation() {
  local header library arch stamp expected_stamp
  [[ -d "$XCFRAMEWORK_DEST" ]] || fail "missing $XCFRAMEWORK_DEST; run without --check"
  [[ -f "$XCFRAMEWORK_DEST/Info.plist" ]] || fail "GhosttyKit has no Info.plist"
  header="$(framework_header "$XCFRAMEWORK_DEST")"
  [[ -n "$header" ]] || fail "GhosttyKit has no ghostty.h"
  grep -q 'ghostty_surface_new' "$header" || fail "GhosttyKit header lacks the surface API"
  library="$(framework_library "$XCFRAMEWORK_DEST")"
  [[ -n "$library" ]] || fail "GhosttyKit has no static library"
  arch="$(lipo -archs "$library")"
  [[ " $arch " == *" arm64 "* ]] || fail "GhosttyKit does not contain arm64 ($arch)"
  [[ -d "$RESOURCE_DEST/ghostty/shell-integration" ]] || fail "missing ghostty shell integration"
  [[ -d "$RESOURCE_DEST/ghostty/themes" ]] || fail "missing empty ghostty themes directory"
  [[ -z "$(find "$RESOURCE_DEST/ghostty/themes" -mindepth 1 -print -quit)" ]] || fail "bundled themes must stay disabled"
  [[ -f "$RESOURCE_DEST/terminfo/78/xterm-ghostty" ]] || fail "missing xterm-ghostty terminfo entry"
  [[ -f "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md" ]] || fail "missing bundled third-party notices"
  [[ -f "$RESOURCE_DEST/GPL-3.0.txt" ]] || fail "missing bundled GPLv3 license"
  cmp -s "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md" || \
    fail "bundled third-party notices are stale"
  cmp -s "$GPL_LICENSE" "$RESOURCE_DEST/GPL-3.0.txt" || fail "bundled GPLv3 license is stale"
  validate_license_bundle
  [[ -f "$STAMP_FILE" ]] || fail "missing build provenance stamp"
  stamp="$(cat "$STAMP_FILE")"
  expected_stamp="$(build_fingerprint)"
  [[ "$stamp" == "$expected_stamp" ]] || fail "stale Ghostty installation; rebuild required"
  [[ -s "$ARTIFACT_MANIFEST" ]] || fail "missing artifact checksum manifest"
  (cd "$REPO_ROOT" && shasum -a 256 -c "$ARTIFACT_MANIFEST" >/dev/null) || \
    fail "Ghostty artifact checksum mismatch; rebuild required"
  echo "GhosttyKit and resources match the pinned build"
}

write_artifact_manifest() {
  local temporary="$ARTIFACT_MANIFEST.new"
  (
    cd "$REPO_ROOT"
    find \
      apps/macos/Vendor/GhosttyKit.xcframework \
      apps/macos/Sources/TodoAgentApp/TerminalResources/ghostty \
      apps/macos/Sources/TodoAgentApp/TerminalResources/terminfo \
      apps/macos/Sources/TodoAgentApp/TerminalResources/THIRD_PARTY_NOTICES.md \
      apps/macos/Sources/TodoAgentApp/TerminalResources/GPL-3.0.txt \
      apps/macos/Sources/TodoAgentApp/TerminalResources/ThirdPartyLicenses \
      -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  ) > "$temporary"
  [[ -s "$temporary" ]] || fail "could not generate artifact checksum manifest"
  mv "$temporary" "$ARTIFACT_MANIFEST"
}

check_only=false
force_build=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check_only=true ;;
    --force) force_build=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if $check_only && $force_build; then
  fail "--check and --force cannot be combined"
fi

validate_manifest
if $check_only; then
  validate_installation
  exit 0
fi
if ! $force_build && (validate_installation >/dev/null 2>&1); then
  echo "GhosttyKit cache hit: $(build_fingerprint)"
  exit 0
fi

zig_bin="${TODOAGENT_ZIG:-}"
if [[ -z "$zig_bin" ]] && command -v zig >/dev/null 2>&1; then
  zig_bin="$(command -v zig)"
fi
if [[ -z "$zig_bin" ]] && command -v brew >/dev/null 2>&1; then
  brew_prefix="$(brew --prefix zig@0.15 2>/dev/null || true)"
  [[ -n "$brew_prefix" ]] && zig_bin="$brew_prefix/bin/zig"
fi
[[ -x "$zig_bin" ]] || fail "Zig $ZIG_VERSION is required. Install zig@0.15 or set TODOAGENT_ZIG to its executable."
[[ "$($zig_bin version)" == "$ZIG_VERSION" ]] || fail "expected Zig $ZIG_VERSION, got $($zig_bin version) at $zig_bin"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v lipo >/dev/null 2>&1 || fail "Xcode command-line tools are required"

# Xcode normally registers the separately downloaded Metal asset with xcrun.
# A managed/sandboxed process may be unable to read or refresh that mapping
# even though cryptexd has mounted a valid Metal.xctoolchain. Discover the
# mounted asset by its stable bundle suffix, never by a versioned mount name.
metal_toolchain=""
use_direct_metal=false
if xcrun metal --version >/dev/null 2>&1; then
  metal_toolchain="$(dirname "$(dirname "$(xcrun -f metal)")")"
else
  while IFS= read -r candidate; do
    [[ -x "$candidate/usr/bin/metal" && -x "$candidate/usr/bin/metallib" ]] || continue
    if "$candidate/usr/bin/metal" --version >/dev/null 2>&1; then
      metal_toolchain="$candidate"
      use_direct_metal=true
      break
    fi
  done < <(find /private/var/run/com.apple.security.cryptexd/mnt -maxdepth 2 \
    -type d -name 'Metal.xctoolchain' -print 2>/dev/null | sort)
fi
[[ -n "$metal_toolchain" ]] || fail "Xcode Metal Toolchain is required. Install it explicitly with: xcodebuild -downloadComponent MetalToolchain"

lock_dir="${TMPDIR:-/tmp}/todoagent-ghostty-setup.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  fail "another Ghostty setup appears to be running ($lock_dir)"
fi
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/todoagent-ghostty-build.XXXXXX")"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/todoagent-ghostty-stage.XXXXXX")"
cleanup() {
  rm -rf "$build_dir" "$stage_dir" "$lock_dir"
}
trap cleanup EXIT INT TERM

echo "Fetching Ghostty $GHOSTTY_REVISION"
archive_path="$stage_dir/ghostty-source.tar.gz"
if [[ -f "${TODOAGENT_GHOSTTY_ARCHIVE:-}" ]]; then
  cp "$TODOAGENT_GHOSTTY_ARCHIVE" "$archive_path"
else
  curl -fL --retry 3 --output "$archive_path" "$GHOSTTY_ARCHIVE_URL"
fi
[[ "$(sha256 "$archive_path")" == "$GHOSTTY_ARCHIVE_SHA256" ]] || fail "Ghostty source archive checksum mismatch"
tar xzf "$archive_path" -C "$build_dir" --strip-components=1
source_zig_version="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$build_dir/build.zig.zon")"
[[ "$source_zig_version" == "$ZIG_VERSION" ]] || fail "Ghostty source pins Zig ${source_zig_version:-unknown}, expected $ZIG_VERSION"

# Ghostty's build step invokes `/usr/bin/xcrun ... metal` directly and exposes
# no compiler override. If xcrun cannot see an otherwise valid mounted Metal
# asset, patch only this disposable source tree to call that exact toolchain.
# The SDK and module cache flags reproduce xcrun's required environment without
# changing Xcode, /Library/Developer/Toolchains, or the pinned source archive.
if $use_direct_metal; then
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  metallib_step="$build_dir/src/build/MetallibStep.zig"
  module_cache="$build_dir/.metal-module-cache"
  mkdir -p "$module_cache"
  /usr/bin/python3 - "$metallib_step" "$metal_toolchain/usr/bin/metal" \
    "$metal_toolchain/usr/bin/metallib" "$sdk_path" "$module_cache" <<'PY'
import json
import pathlib
import sys

source_path, metal, metallib, sdk, module_cache = sys.argv[1:]
path = pathlib.Path(source_path)
source = path.read_text()
old_metal = 'run_ir.addArgs(&.{ "/usr/bin/xcrun", "-sdk", sdk, "metal", "-o" });'
old_metallib = 'run_lib.addArgs(&.{ "/usr/bin/xcrun", "-sdk", sdk, "metallib", "-o" });'
if source.count(old_metal) != 1 or source.count(old_metallib) != 1:
    raise SystemExit("Ghostty MetallibStep shape changed; refusing an unverified patch")
new_metal = (
    "_ = sdk;\n    run_ir.addArgs(&.{ "
    f"{json.dumps(metal)}, \"-isysroot\", {json.dumps(sdk)}, "
    f"{json.dumps('-fmodules-cache-path=' + module_cache)}, \"-o\" }});"
)
new_metallib = f'run_lib.addArgs(&.{{ {json.dumps(metallib)}, "-o" }});'
path.write_text(source.replace(old_metal, new_metal).replace(old_metallib, new_metallib))
PY
  echo "Using mounted Metal toolchain: $metal_toolchain"
fi

# The pinned revision's macOS SharedDeps unconditionally links GNU libintl
# even when `-Di18n=false`. Apply the missing feature gate in scratch so this
# closed-source product build does not accidentally statically link LGPL code.
shared_deps="$build_dir/src/build/SharedDeps.zig"
/usr/bin/python3 - "$shared_deps" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = '''        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
'''
new = '''        if (self.config.i18n) {
            if (b.lazyDependency("libintl", .{
                .target = target,
                .optimize = optimize,
            })) |libintl_dep| {
                step.linkLibrary(libintl_dep.artifact("intl"));
                try static_libs.append(
                    b.allocator,
                    libintl_dep.artifact("intl").getEmittedBin(),
                );
            }
        }
'''
if source.count(old) != 1:
    raise SystemExit("Ghostty libintl dependency shape changed; refusing an unverified patch")
path.write_text(source.replace(old, new))
PY

echo "Building GhosttyKit with Zig $ZIG_VERSION"
zig_global_cache="${TODOAGENT_ZIG_GLOBAL_CACHE_DIR:-${TMPDIR:-/tmp}/todoagent-zig-global-cache}"
zig_local_cache="$build_dir/.zig-cache"
mkdir -p "$zig_global_cache" "$zig_local_cache"

# Zig 0.15's HTTP client can fail against the dependency CDN even when curl
# succeeds. Populate the isolated package cache ourselves, checking every
# archive against the content hash committed in Ghostty's build.zig.zon.
mkdir -p "$stage_dir/zig-dependencies"
discover_zig_dependencies() {
  /usr/bin/python3 - "$@" <<'PY'
import pathlib
import re
import sys

for name in sys.argv[1:]:
    source = pathlib.Path(name).read_text()
    for match in re.finditer(
        r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"',
        source,
        re.MULTILINE,
    ):
        print(f"{match.group(1)}\t{match.group(2)}")
PY
}

# Re-scan newly populated packages until every transitive URL dependency is in
# the cache. A git+https URL pinned with `#<commit>` is downloaded through the
# provider's immutable commit tarball because Zig's git HTTP path has the same
# proxy/CDN incompatibility; the declared Zig content hash is still authoritative.
while true; do
  dependency_list="$stage_dir/zig-dependencies/list"
  zon_files=()
  while IFS= read -r zon; do zon_files+=("$zon"); done < <(find "$build_dir" -name build.zig.zon -print)
  while IFS= read -r zon; do zon_files+=("$zon"); done < <(find "$zig_global_cache/p" -name build.zig.zon -print)
  discover_zig_dependencies "${zon_files[@]}" | LC_ALL=C sort -u > "$dependency_list"
  fetched_any=false
  while IFS=$'\t' read -r dependency_url dependency_hash; do
    [[ -n "$dependency_url" && -n "$dependency_hash" ]] || continue
    [[ -d "$zig_global_cache/p/$dependency_hash" ]] && continue
    fetch_url="$dependency_url"
    if [[ "$dependency_url" =~ ^git\+https://github.com/([^/]+)/([^#]+)#([0-9a-fA-F]{40})$ ]]; then
      fetch_url="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/archive/${BASH_REMATCH[3]}.tar.gz"
    elif [[ "$dependency_url" == git+* ]]; then
      fail "unsupported pinned git dependency URL: $dependency_url"
    fi
    dependency_name="${fetch_url##*/}"
    dependency_archive="$stage_dir/zig-dependencies/$(printf '%s' "$dependency_url" | shasum -a 256 | awk '{print $1}')-$dependency_name"
    curl -fL --retry 3 --output "$dependency_archive" "$fetch_url"
    fetched_hash="$("$zig_bin" fetch --global-cache-dir "$zig_global_cache" "$dependency_archive")"
    [[ "$fetched_hash" == "$dependency_hash" ]] || \
      fail "dependency content hash mismatch for $dependency_url (got $fetched_hash, expected $dependency_hash)"
    fetched_any=true
  done < "$dependency_list"
  $fetched_any || break
done
(
  cd "$build_dir"
  ZIG_GLOBAL_CACHE_DIR="$zig_global_cache" \
  ZIG_LOCAL_CACHE_DIR="$zig_local_cache" \
  "$zig_bin" build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-macos-app=false \
    -Di18n=false \
    -Dsentry=false \
    -Demit-themes=false
)

[[ -d "$build_dir/macos/GhosttyKit.xcframework" ]] || fail "build did not produce GhosttyKit.xcframework"
mkdir -p "$stage_dir/Vendor" "$stage_dir/TerminalResources/ghostty"
cp -R "$build_dir/macos/GhosttyKit.xcframework" "$stage_dir/Vendor/"
cp -R "$build_dir/zig-out/share/ghostty/shell-integration" "$stage_dir/TerminalResources/ghostty/"
mkdir -p "$stage_dir/TerminalResources/ghostty/themes"
cp -R "$build_dir/zig-out/share/terminfo" "$stage_dir/TerminalResources/terminfo"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$stage_dir/TerminalResources/THIRD_PARTY_NOTICES.md"
cp "$GPL_LICENSE" "$stage_dir/TerminalResources/GPL-3.0.txt"

staged_header="$(framework_header "$stage_dir/Vendor/GhosttyKit.xcframework")"
staged_library="$(framework_library "$stage_dir/Vendor/GhosttyKit.xcframework")"
[[ -n "$staged_header" && -n "$staged_library" ]] || fail "staged GhosttyKit is incomplete"
grep -q 'ghostty_surface_new' "$staged_header" || fail "staged GhosttyKit lacks the surface API"
[[ " $(lipo -archs "$staged_library") " == *" arm64 "* ]] || fail "staged GhosttyKit lacks arm64"
[[ -d "$stage_dir/TerminalResources/ghostty/shell-integration" ]] || fail "staged shell integration is missing"
[[ -d "$stage_dir/TerminalResources/ghostty/themes" ]] || fail "staged themes are missing"
[[ -z "$(find "$stage_dir/TerminalResources/ghostty/themes" -mindepth 1 -print -quit)" ]] || fail "themes were unexpectedly emitted"
[[ -f "$stage_dir/TerminalResources/terminfo/78/xterm-ghostty" ]] || fail "staged xterm-ghostty terminfo is missing"
cmp -s "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$stage_dir/TerminalResources/THIRD_PARTY_NOTICES.md" || fail "staged notices mismatch"
cmp -s "$GPL_LICENSE" "$stage_dir/TerminalResources/GPL-3.0.txt" || fail "staged GPLv3 license mismatch"

# All validation happens in scratch space. Only complete, mutually matching
# framework/resources replace the current installation.
rm -rf "$XCFRAMEWORK_DEST.new" "$RESOURCE_DEST/ghostty.new" "$RESOURCE_DEST/terminfo.new" \
  "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md.new" "$RESOURCE_DEST/GPL-3.0.txt.new"
mv "$stage_dir/Vendor/GhosttyKit.xcframework" "$XCFRAMEWORK_DEST.new"
mv "$stage_dir/TerminalResources/ghostty" "$RESOURCE_DEST/ghostty.new"
mv "$stage_dir/TerminalResources/terminfo" "$RESOURCE_DEST/terminfo.new"
mv "$stage_dir/TerminalResources/THIRD_PARTY_NOTICES.md" "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md.new"
mv "$stage_dir/TerminalResources/GPL-3.0.txt" "$RESOURCE_DEST/GPL-3.0.txt.new"
rm -rf "$XCFRAMEWORK_DEST" "$RESOURCE_DEST/ghostty" "$RESOURCE_DEST/terminfo" \
  "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md" "$RESOURCE_DEST/GPL-3.0.txt"
mv "$XCFRAMEWORK_DEST.new" "$XCFRAMEWORK_DEST"
mv "$RESOURCE_DEST/ghostty.new" "$RESOURCE_DEST/ghostty"
mv "$RESOURCE_DEST/terminfo.new" "$RESOURCE_DEST/terminfo"
mv "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md.new" "$RESOURCE_DEST/THIRD_PARTY_NOTICES.md"
mv "$RESOURCE_DEST/GPL-3.0.txt.new" "$RESOURCE_DEST/GPL-3.0.txt"
write_artifact_manifest
printf '%s\n' "$(build_fingerprint)" > "$STAMP_FILE"

validate_installation
