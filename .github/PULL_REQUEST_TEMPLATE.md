## Summary

<!-- What user-visible or engineering outcome does this PR deliver? -->

## Scope

<!-- List the components changed and explicitly note important out-of-scope work. -->

## Validation

- [ ] `cargo fmt --manifest-path apps/engine-rs/Cargo.toml --all -- --check`
- [ ] `cargo clippy --manifest-path apps/engine-rs/Cargo.toml --locked --all-targets -- -D warnings`
- [ ] `cargo test --manifest-path apps/engine-rs/Cargo.toml --locked`
- [ ] Swift strict-concurrency tests from `CONTRIBUTING.md`
- [ ] `git diff --check`
- [ ] Relevant real CLI fresh/resume flow, when Runtime behavior changed
- [ ] Preview App/DMG and isolated Engine handshake, when packaging changed

Actual results and intentionally skipped checks:

<!-- Never mark an unrun check as passed. Explain environment blockers. -->

## Safety and data

- [ ] No credential, token, private terminal content, or user-specific path was added.
- [ ] User files and dirty worktrees are preserved.
- [ ] IPC stdout remains NDJSON-only.
- [ ] Schema/migration, process, Hook, permission, and privacy effects are documented below.

Safety/data notes:

<!-- Write "None" only after checking. -->

## Documentation and compatibility

- [ ] Tests cover success, failure, cancellation/recovery, and idempotency where relevant.
- [ ] `README.md`, `TODO.md`, `docs/`, module README, and `CHANGELOG.md` are updated as needed.
- [ ] Current behavior is not described as shipped before it is validated.
- [ ] Third-party pin, hash, license, NOTICE, and provenance changes are included when applicable.

## Screenshots or recordings

<!-- Required for visible UI changes. Remove private task and terminal content. -->
