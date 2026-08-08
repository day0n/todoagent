import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Store } from "../db/index.ts";
import type { ExecutionTarget } from "../types.ts";
import { runOne } from "./runner.ts";

test("a direct execution target runs and records an attempt without any Expert row", async () => {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-direct-target-test-"));
  const executable = join(dir, "claude-pinned");
  await writeFile(
    executable,
    `#!/usr/bin/env node
process.stdout.write(JSON.stringify({
  type: "result",
  is_error: false,
  session_id: "direct-session",
  result: "done",
  usage: { input_tokens: 2, output_tokens: 3 }
}) + "\\n");
`,
    "utf8",
  );
  await chmod(executable, 0o755);

  const store = new Store(join(dir, "test.db"));
  try {
    const project = store.createProject({
      name: "direct",
      repoPath: dir,
      // No FK by design; the direct path has no team dependency.
      teamId: "legacy-compat-only",
    });
    const target: ExecutionTarget = {
      runtimeKind: "claude",
      displayName: "Claude Code",
      execPath: executable,
      version: "test",
    };
    const run = store.createRun({
      projectId: project.id,
      goal: "do it",
      runtimeKind: target.runtimeKind,
      runtimeExecPath: target.execPath,
      runtimeVersion: target.version,
    });

    const result = await runOne({
      store,
      runId: run.id,
      target,
      kind: "draft",
      subTaskId: null,
      prompt: "do it",
      cwd: dir,
      timeoutMs: 60_000,
    });

    assert.equal(result.ok, true);
    const attempt = store.getAttempt(result.attemptId);
    assert.equal(attempt?.expertId, null);
    assert.equal(attempt?.runtimeKind, "claude");
    assert.equal(store.getRun(run.id)?.runtimeExecPath, executable);
    assert.equal(store.listExperts().length, 0, "direct dispatch must not synthesize an Expert");
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});
