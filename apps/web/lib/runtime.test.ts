import assert from "node:assert/strict";
import test from "node:test";
import { isRuntimeKind, preferredRuntimeKind } from "./runtime.ts";
import type { RuntimeInfo, RuntimeKind, RuntimeStatus } from "./types.ts";

function runtime(kind: RuntimeKind, status: RuntimeStatus): RuntimeInfo {
  return {
    kind,
    label: kind,
    status,
    execPath: status === "missing" ? null : `/bin/${kind}`,
    version: status === "missing" ? null : "1.0.0",
    detectedAt: null,
    verifiedAt: null,
    verifyError: null,
    activeRuns: 0,
  };
}

test("task runtime wins when it is still ready", () => {
  const runtimes = [runtime("claude", "ready"), runtime("codex", "ready")];
  assert.equal(preferredRuntimeKind(runtimes, "claude", "codex"), "claude");
});

test("last explicit runtime is used when the task has no usable previous choice", () => {
  const runtimes = [runtime("claude", "auth_required"), runtime("codex", "ready")];
  assert.equal(preferredRuntimeKind(runtimes, "claude", "codex"), "codex");
});

test("the sole ready runtime is preselected, but several ready runtimes are not guessed", () => {
  assert.equal(
    preferredRuntimeKind([runtime("claude", "missing"), runtime("codex", "ready")], null, null),
    "codex",
  );
  assert.equal(
    preferredRuntimeKind([runtime("claude", "ready"), runtime("codex", "ready")], null, null),
    null,
  );
});

test("stale localStorage values are rejected", () => {
  assert.equal(isRuntimeKind("claude"), true);
  assert.equal(isRuntimeKind("shell"), false);
  assert.equal(isRuntimeKind(null), false);
});
