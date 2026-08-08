import assert from "node:assert/strict";
import { chmod, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExecutionTarget } from "../types.ts";
import { probeRuntime } from "./probe.ts";

const PREFIX = "todoagent-runtime-probe-";

async function probeDirs(): Promise<Set<string>> {
  return new Set((await readdir(tmpdir())).filter((name) => name.startsWith(PREFIX)));
}

async function fakeClaude(body: string): Promise<{ path: string; dispose: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-probe-cli-test-"));
  const path = join(dir, "claude");
  await writeFile(path, `#!/usr/bin/env node\n${body}\n`, "utf8");
  await chmod(path, 0o755);
  return { path, dispose: () => rm(dir, { recursive: true, force: true }) };
}

function target(execPath: string): ExecutionTarget {
  return {
    runtimeKind: "claude",
    displayName: "Claude Code",
    execPath,
    version: "test",
  };
}

test("a real probe uses the pinned executable and always removes its temporary repo", async () => {
  const fake = await fakeClaude(`
process.stdout.write(JSON.stringify({
  type: "result",
  is_error: false,
  session_id: "probe-session",
  result: "TODOAGENT_OK",
  usage: { input_tokens: 1, output_tokens: 1 }
}) + "\\n");
`);
  const before = await probeDirs();
  try {
    // The complete suite launches many child processes in parallel. Keep this
    // comfortably above a saturated CI runner's process-start delay; the test is
    // about path pinning and cleanup, not watchdog timing (covered elsewhere).
    const result = await probeRuntime(target(fake.path), { timeoutMs: 60_000, idleTimeoutMs: 30_000 });
    assert.equal(result.ok, true);
    assert.equal(result.output, "TODOAGENT_OK");
    assert.ok(result.eventCount > 0);
  } finally {
    await fake.dispose();
  }
  const after = await probeDirs();
  assert.deepEqual(after, before, "the disposable repository must not leak on success");
});

test("a zero-event process is a failed verification and its temporary repo is removed", async () => {
  const fake = await fakeClaude("process.exit(0);");
  const before = await probeDirs();
  try {
    const result = await probeRuntime(target(fake.path), { timeoutMs: 60_000, idleTimeoutMs: 30_000 });
    assert.equal(result.ok, false);
    assert.equal(result.eventCount, 0);
    assert.match(result.error ?? "", /no parseable events/);
  } finally {
    await fake.dispose();
  }
  const after = await probeDirs();
  assert.deepEqual(after, before, "the disposable repository must not leak on failure");
});
