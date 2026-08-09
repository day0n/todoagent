# TodoAgent engineering rules

## Branches and product scope

- `master` is the canonical native macOS product branch.
- `legacy/web` preserves the former Web and Node.js implementation.
- Name new branches for their purpose, such as `feature/...`, `fix/...`, or
  `legacy/...`. Do not use a `codex/` prefix.
- Keep the legacy source available for compatibility fixtures and reference
  unless a separate cleanup task explicitly removes it.

## Safety

- Never print, log, commit, or persist a Gemini API key outside the local
  credential store.
- Preserve user changes in a dirty worktree. Do not reset, overwrite, commit,
  or push unrelated work.
- Keep Engine stdout reserved for NDJSON IPC. Diagnostics belong on stderr or
  in the application log.

## Native validation

Before committing native changes, run the relevant checks:

```sh
cargo fmt --manifest-path apps/engine-rs/Cargo.toml --all -- --check
cargo clippy --manifest-path apps/engine-rs/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path apps/engine-rs/Cargo.toml --locked
swift test --disable-sandbox --package-path apps/macos \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
git diff --check
```

For a release candidate, also run `./scripts/build-macos-preview.sh` and verify
the bundled arm64 Engine handshake against an isolated database. Daily local
testing can open `dist/TodoAgent.app` directly; reinstalling is unnecessary.
