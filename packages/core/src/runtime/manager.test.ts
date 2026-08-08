import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Store } from "../db/index.ts";
import type { DetectedRuntime, ExecutionTarget, RuntimeKind } from "../types.ts";
import { RuntimeManager } from "./manager.ts";
import type { RuntimeProbeResult } from "./probe.ts";

function successfulProbe(target: ExecutionTarget): RuntimeProbeResult {
  return {
    kind: target.runtimeKind,
    ok: true,
    output: "TODOAGENT_OK",
    error: null,
    durationMs: 1,
    eventCount: 1,
    eventTypes: ["status"],
  };
}

async function fixture(): Promise<{
  store: Store;
  dbPath: string;
  executable: string;
  dispose: () => Promise<void>;
}> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-runtime-manager-test-"));
  const executable = join(dir, "claude");
  await writeFile(executable, "#!/bin/sh\nexit 0\n", "utf8");
  await chmod(executable, 0o755);
  const dbPath = join(dir, "test.db");
  const store = new Store(dbPath);
  return {
    store,
    dbPath,
    executable,
    async dispose() {
      store.close();
      await rm(dir, { recursive: true, force: true });
    },
  };
}

test("refresh preserves ready only while path and version are unchanged", async () => {
  const f = await fixture();
  try {
    let claude: DetectedRuntime | null = {
      kind: "claude",
      execPath: f.executable,
      version: "1.0.0",
    };
    const detect = async (kind: RuntimeKind): Promise<DetectedRuntime | null> =>
      kind === "claude" ? claude : null;
    const manager = new RuntimeManager(f.store, { detect, probe: async (t) => successfulProbe(t) });

    await manager.refresh();
    assert.equal(manager.list().find((r) => r.kind === "claude")?.status, "unverified");
    assert.equal((await manager.verify("claude")).status, "ready");

    // Simulates an Engine restart with a new Store connection: readiness is a
    // database fact, not an in-memory flag on the first manager.
    const restartedStore = new Store(f.dbPath);
    try {
      const restarted = new RuntimeManager(restartedStore, {
        detect,
        probe: async (t) => successfulProbe(t),
      });
      await restarted.refresh();
      assert.equal(restarted.getReadyTarget("claude")?.execPath, f.executable);

      claude = { ...claude, version: "2.0.0" };
      await restarted.refresh();
      const changed = restarted.list().find((r) => r.kind === "claude");
      assert.equal(changed?.status, "unverified", "a new binary must earn readiness again");
      assert.equal(changed?.verifiedAt, null);

      claude = null;
      await restarted.refresh();
      assert.equal(restarted.list().find((r) => r.kind === "claude")?.status, "missing");
      assert.equal(restarted.getReadyTarget("claude"), null);
    } finally {
      restartedStore.close();
    }
  } finally {
    await f.dispose();
  }
});

test("verify deduplicates concurrent probes and persists auth failures", async () => {
  const f = await fixture();
  try {
    let release: (result: RuntimeProbeResult) => void = () => {
      throw new Error("probe was not started");
    };
    let calls = 0;
    const manager = new RuntimeManager(f.store, {
      detect: async (kind) =>
        kind === "claude"
          ? { kind, execPath: f.executable, version: "1.0.0" }
          : null,
      probe: () => {
        calls++;
        return new Promise((resolve) => {
          release = resolve;
        });
      },
    });
    await manager.refresh();

    const first = manager.verify("claude");
    const second = manager.verify("claude");
    assert.equal(first, second, "one button double-click must not spend two real turns");
    assert.equal(calls, 1);
    assert.equal(manager.list().find((r) => r.kind === "claude")?.status, "verifying");

    release({
      kind: "claude",
      ok: false,
      output: "",
      error: "not authenticated; run claude login",
      durationMs: 1,
      eventCount: 1,
      eventTypes: ["error"],
    });
    const result = await first;
    assert.equal(result.status, "auth_required");
    assert.equal(f.store.getLocalRuntime("claude")?.status, "auth_required");
  } finally {
    await f.dispose();
  }
});

test("verify returns a persisted failure when the probe throws or the CLI is missing", async () => {
  const f = await fixture();
  try {
    const manager = new RuntimeManager(f.store, {
      detect: async (kind) =>
        kind === "claude"
          ? { kind, execPath: f.executable, version: "1.0.0" }
          : null,
      probe: async () => {
        throw new Error("protocol handshake failed");
      },
    });
    await manager.refresh();
    const failed = await manager.verify("claude");
    assert.equal(failed.status, "error");
    assert.match(failed.verifyError ?? "", /handshake/);
    assert.notEqual(f.store.getLocalRuntime("claude")?.status, "verifying");

    const missing = await manager.verify("codex");
    assert.equal(missing.status, "missing");
    assert.match(missing.verifyError ?? "", /not installed/);
  } finally {
    await f.dispose();
  }
});

test("execution failures invalidate only the same CLI snapshot and only for runtime faults", async () => {
  const f = await fixture();
  try {
    const manager = new RuntimeManager(f.store, {
      detect: async (kind) =>
        kind === "claude"
          ? { kind, execPath: f.executable, version: "1.0.0" }
          : null,
      probe: async (target) => successfulProbe(target),
    });
    await manager.refresh();
    await manager.verify("claude");
    const target = manager.getReadyTarget("claude");
    assert.ok(target);

    manager.recordExecutionFailure(target, "tests failed: expected 2, received 3");
    assert.equal(f.store.getLocalRuntime("claude")?.status, "ready", "task failures are not CLI failures");

    manager.recordExecutionFailure({ ...target, version: "stale" }, "spawn failed: ENOENT");
    assert.equal(f.store.getLocalRuntime("claude")?.status, "ready", "an old run cannot invalidate a new snapshot");

    manager.recordExecutionFailure(target, "authentication expired; please sign in");
    assert.equal(f.store.getLocalRuntime("claude")?.status, "auth_required");
    assert.equal(manager.getReadyTarget("claude"), null);
  } finally {
    await f.dispose();
  }
});

test("getReadyTarget rejects a path that is no longer executable before dispatch", async () => {
  const f = await fixture();
  try {
    const manager = new RuntimeManager(f.store, {
      detect: async (kind) =>
        kind === "claude"
          ? { kind, execPath: f.executable, version: "1.0.0" }
          : null,
      probe: async (target) => successfulProbe(target),
    });
    await manager.refresh();
    await manager.verify("claude");
    await chmod(f.executable, 0o644);

    assert.equal(manager.getReadyTarget("claude"), null);
    assert.equal(f.store.getLocalRuntime("claude")?.status, "missing");
  } finally {
    await f.dispose();
  }
});

test("a successful refresh heals only transient detection errors", async () => {
  const f = await fixture();
  try {
    let detectionError: Error | null = null;
    const detect = async (kind: RuntimeKind): Promise<DetectedRuntime | null> => {
      if (kind !== "claude") return null;
      if (detectionError !== null) throw detectionError;
      return { kind, execPath: f.executable, version: "1.0.0" };
    };
    const manager = new RuntimeManager(f.store, {
      detect,
      probe: async (target) => successfulProbe(target),
    });

    await manager.refresh();
    detectionError = new Error("database is locked");
    await manager.refresh();
    assert.equal(f.store.getLocalRuntime("claude")?.status, "error");
    assert.match(f.store.getLocalRuntime("claude")?.verifyError ?? "", /runtime detection failed/);

    detectionError = null;
    await manager.refresh();
    assert.equal(
      f.store.getLocalRuntime("claude")?.status,
      "unverified",
      "an executable that never passed a probe cannot become ready",
    );
    assert.equal(f.store.getLocalRuntime("claude")?.verifyError, null);

    await manager.verify("claude");
    detectionError = new Error("SQLITE_BUSY: database is locked");
    await manager.refresh();
    assert.equal(f.store.getLocalRuntime("claude")?.status, "error");
    detectionError = null;
    await manager.refresh();
    assert.equal(
      f.store.getLocalRuntime("claude")?.status,
      "ready",
      "the unchanged binary may recover readiness it previously earned",
    );

    // Compatibility with development builds that stored the raw message without
    // the new detection prefix.
    const ready = f.store.getLocalRuntime("claude");
    assert.ok(ready);
    f.store.upsertLocalRuntime({ ...ready, status: "error", verifyError: "database is locked" });
    await manager.refresh();
    assert.equal(f.store.getLocalRuntime("claude")?.status, "ready");
  } finally {
    await f.dispose();
  }
});

test("cheap refresh never clears a real protocol or authentication failure", async () => {
  const f = await fixture();
  try {
    let probeError = "protocol handshake failed";
    const manager = new RuntimeManager(f.store, {
      detect: async (kind) =>
        kind === "claude"
          ? { kind, execPath: f.executable, version: "1.0.0" }
          : null,
      probe: async () => ({
        kind: "claude",
        ok: false,
        output: "",
        error: probeError,
        durationMs: 1,
        eventCount: 1,
        eventTypes: ["error"],
      }),
    });
    await manager.refresh();
    assert.equal((await manager.verify("claude")).status, "error");
    await manager.refresh();
    assert.equal(f.store.getLocalRuntime("claude")?.status, "error");
    assert.equal(f.store.getLocalRuntime("claude")?.verifyError, probeError);

    probeError = "not authenticated; sign in again";
    assert.equal((await manager.verify("claude")).status, "auth_required");
    await manager.refresh();
    assert.equal(f.store.getLocalRuntime("claude")?.status, "auth_required");
    assert.equal(f.store.getLocalRuntime("claude")?.verifyError, probeError);
  } finally {
    await f.dispose();
  }
});
