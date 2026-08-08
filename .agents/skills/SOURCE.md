# Vendored development skills

## macOS application patterns

Source: https://github.com/fayazara/macos-app-skills

Pinned commit: `a60365ae85bfc3d1f2f8b260b080d77bfb2f3ec0`

Included skills:

- `macos-patterns`
- `settings-ui`
- `build`

These files are kept verbatim so native macOS implementation guidance is
reproducible rather than following a moving branch.

License audit (2026-08-08): the pinned upstream tree has no `LICENSE` file and
GitHub reports no declared license. These copies are for local implementation
reference only. Do not include them in a public source or binary distribution
without obtaining permission from the upstream author or removing the vendored
copies first.

## Apple engineering guides

Source: https://github.com/Prisma-Labs-Dev/apple-skills

Pinned commit: `a76633bad89fc740df3c2e0d125fc3e4092a5075`

Normative engineering guides:

- `guide-swiftui-ui-patterns`
- `guide-swift-concurrency`
- `guide-swift-testing`
- `guide-swiftui-performance-audit`

Reference-only skills:

- `hig` — factual platform and accessibility lookup, not visual direction
- `xcuitest` — UI-test API lookup, not application architecture

Deliberately excluded from the project standard are SwiftData, UIKit,
iOS-specific Liquid Glass, and the alternate SwiftPM packaging guide. The Rust
Engine remains the sole persistence/process layer, and the native macOS skills
above take precedence whenever an Apple guide is iOS-centric.

The selected Apple skills are vendored under the upstream MIT license. See
`APPLE_SKILLS_LICENSE.txt` in this directory.
