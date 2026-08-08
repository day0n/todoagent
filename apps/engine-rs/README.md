# TodoAgent Rust Engine

The Engine is an app-bundled sidecar. It communicates exclusively over
versioned NDJSON on stdin/stdout and never opens a TCP port.

By default its fresh native data lives in:

- `~/Library/Application Support/TodoAgent/todoagent.sqlite3`
- `~/Library/Application Support/TodoAgent/Attachments`
- `~/Library/Logs/TodoAgent`

It does not inspect or modify the legacy `~/.todoagent` directory. Tests and
local smoke runs can set `TODOAGENT_NATIVE_DATA_DIR` to an isolated directory.

Protocol fixtures shared with Swift live in `protocol/fixtures` at the
repository root.
