# TodoAgent for macOS

This directory contains the native macOS 26+ preview. It is intentionally
parallel to the existing Web/TypeScript application.

## Current modes

- `DemoRepository` is the default and provides deterministic, fully interactive
  preview data without reading the old database or launching a CLI.
- `EngineRepository` is the production adapter for the bundled Rust sidecar. It
  is present for protocol integration but is not selected by default yet.

## Local build

1. Install Xcode 26+ and accept Apple's Xcode license.
2. Run `scripts/build-macos-preview.sh` from the repository root.
3. The unsigned local artifacts are written to `dist/TodoAgent.app` and
   `dist/TodoAgent-0.1.0-preview-arm64.dmg`.

The script uses `/Applications/Xcode.app` without changing the machine-wide
`xcode-select` setting. It compiles and strips the arm64 Rust sidecar, embeds it
in App Resources, and ad-hoc signs both the sidecar and app bundle.
