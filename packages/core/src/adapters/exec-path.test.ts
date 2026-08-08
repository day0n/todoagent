import assert from "node:assert/strict";
import { test } from "node:test";
import { RUNTIME_KINDS } from "../types.ts";
import { defaultExecutableForRuntime, execPathForRuntime } from "./types.ts";

test("all supported adapters prefer RuntimeManager's pinned executable path", () => {
  for (const kind of RUNTIME_KINDS) {
    const pinned = `/verified/bin/${kind}`;
    assert.equal(
      execPathForRuntime(kind, { cwd: "/repo", execPath: pinned }),
      pinned,
      `${kind} must not re-resolve a bare command after verification`,
    );
  }
});

test("legacy calls retain the six established executable names", () => {
  assert.deepEqual(
    RUNTIME_KINDS.map((kind) => defaultExecutableForRuntime(kind)),
    ["claude", "codex", "cursor-agent", "gemini", "kiro-cli", "grok"],
  );
});
