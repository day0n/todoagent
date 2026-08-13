# Ghostty dependency pin

TodoAgent embeds Ghostty through the static `GhosttyKit.xcframework`. The
framework and runtime resources are generated, not committed. Run:

```sh
./scripts/setup-ghostty.sh
```

The script builds the exact source revision and Zig version recorded in
`pins.json`. A dependency update must change that manifest deliberately and
re-run terminal lifecycle, input, resource, and performance tests.

The generated resource layout is significant:

```text
TerminalResources/
├── ghostty/
│   ├── shell-integration/
│   └── themes/              # deliberately empty
└── terminfo/
    └── 78/xterm-ghostty
```

`ghostty` and `terminfo` must remain siblings. libghostty derives the latter
from `GHOSTTY_RESOURCES_DIR`.

Ghostty's pinned `MetallibStep.zig` invokes `/usr/bin/xcrun` directly. On a
managed process where Xcode cannot resolve its separately mounted Metal asset,
the setup script discovers the valid `Metal.xctoolchain` by bundle name and
mechanically patches only the disposable source tree to invoke `metal` and
`metallib` there. The patch supplies the macOS SDK and an isolated module cache;
it never mutates Xcode or the pinned source archive.

The build stamp includes the Ghostty revision and archive checksum, Zig version,
Xcode identity, host architecture, pin-manifest hash, and setup-script hash.
The generated `.ghostty-artifacts.sha256` records every framework and resource
file. `setup-ghostty.sh --check` verifies both; plain setup exits immediately on
a valid cache hit, while `--force` explicitly rebuilds.

The embedded-library build fixes
`-Di18n=false -Dsentry=false -Demit-themes=false`. TodoAgent owns
its localization and crash-reporting policy; disabling Ghostty's copies also
removes statically linked GNU libintl (LGPL) and Sentry/Breakpad from the
framework, reducing binary size and avoiding an unexpected reporting path.
The third-party theme collection is disabled because TodoAgent does not expose
a theme chooser; Ghostty's compiled-in defaults remain available. This avoids
shipping hundreds of unused files and their separate provenance surface.
The pinned revision declares the i18n option but its macOS dependency block
omits the corresponding guard, so setup applies that one missing guard to the
disposable source tree and fails closed if the expected source shape changes.
