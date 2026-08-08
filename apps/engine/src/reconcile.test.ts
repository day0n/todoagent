import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Startup reconciliation and orphan cancellation.
 *
 * A `running` row is only true while some process is driving it, and that fact
 * lives in memory. After a crash or restart nothing is driving those rows, yet
 * they still read as running — so the UI showed "in progress" forever on work
 * nothing was doing, and the cancel button could not help: it looked for an
 * AbortController that no longer existed and returned 409. The user had no way to
 * resume and no way to clear.
 *
 * Boots the real server against a throwaway database, because the behaviour under
 * test is what happens at process start.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8801; // distinct from the SSE suite so they can run together

interface Harness {
  dbPath: string;
  store: Store;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-reconcile-"));
  const dbPath = join(dir, "reconcile.db");
  const store = new Store(dbPath);
  return {
    dbPath,
    store,
    async dispose() {
      store.close();
      await rm(dir, { recursive: true, force: true });
    },
  };
}

function seedProject(store: Store, dir: string): string {
  const expert = store.createExpert({
    name: "R",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
  const team = store.createTeam("reconcile-team");
  store.addTeamMember(team.id, expert.id, "maker");
  return store.createProject({ name: "p", repoPath: dir, teamId: team.id }).id;
}

/** Boots the engine and waits for it to answer, then stops it. */
async function withEngine<T>(dbPath: string, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: dbPath,
      TODOAGENT_PORT: String(PORT),
      TODOAGENT_DISABLE_RUNTIME_DISCOVERY: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const deadline = Date.now() + 30_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error("engine did not start within 30s");
      try {
        const res = await fetch(`http://127.0.0.1:${PORT}/api/health`);
        if (res.ok) break;
      } catch {
        /* not listening yet */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    return await fn();
  } finally {
    child.kill("SIGKILL");
    // Give the port a moment to free so consecutive tests do not collide.
    await new Promise((r) => setTimeout(r, 200));
  }
}

test("reconcile: a run left running by a dead process is resolved at startup", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "interrupted work" });
    // Simulate a crash mid-execution.
    f.store.updateRun(run.id, { status: "running", phase: "draft" });
    assert.equal(f.store.getRun(run.id)?.status, "running");
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`);
      assert.equal(res.status, 200);
      const body = (await res.json()) as { run: { status: string; error: string | null; endedAt: string | null } };

      // No client may observe a run that nothing is driving.
      assert.notEqual(body.run.status, "running", "a stale row must not still read as running");
      assert.equal(body.run.status, "failed");
      assert.match(body.run.error ?? "", /restarted/i, "the reason is stated, not hidden");
      assert.ok(body.run.endedAt !== null, "the run is closed out");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("reconcile: a run parked at the plan gate is left alone", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "waiting for approval" });
    f.store.updateRun(run.id, { status: "blocked_on_human", gate: "plan_approval" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`);
      const body = (await res.json()) as { run: { status: string; gate: string | null } };

      /*
       * Load-bearing distinction. A parked run is CORRECTLY not executing — it is
       * waiting on a person, and its plan is still valid. Reconciling it would
       * throw away a decomposition the user was about to approve and charge them
       * for it again.
       */
      assert.equal(body.run.status, "blocked_on_human");
      assert.equal(body.run.gate, "plan_approval");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("reconcile: finished runs are untouched", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const completed = f.store.createRun({ projectId, goal: "done" });
    f.store.updateRun(completed.id, { status: "completed", endedAt: new Date(0).toISOString() });
    const failed = f.store.createRun({ projectId, goal: "broke" });
    f.store.updateRun(failed.id, { status: "failed", error: "original reason" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const a = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${completed.id}`)).json()) as {
        run: { status: string };
      };
      assert.equal(a.run.status, "completed");

      const b = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${failed.id}`)).json()) as {
        run: { status: string; error: string | null };
      };
      assert.equal(b.run.status, "failed");
      // The original diagnosis must survive; overwriting it would destroy the
      // only record of why the run failed.
      assert.equal(b.run.error, "original reason");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("cancel: an orphaned run can be cleared instead of 409", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    // Parked, so startup reconciliation deliberately leaves it — but nothing is
    // executing it either, which is precisely the state that used to be a
    // dead end.
    const run = f.store.createRun({ projectId, goal: "stuck" });
    f.store.updateRun(run.id, { status: "blocked_on_human", gate: "plan_approval" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/cancel`, {
        method: "POST",
      });
      assert.equal(res.status, 200, "cancelling a run nothing is driving must work");
      const body = (await res.json()) as { ok: boolean; reaped: boolean };
      assert.equal(body.ok, true);
      // Nothing to reap: no subprocess was killed, the row was just closed out.
      assert.equal(body.reaped, false);

      const after = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`)).json()) as {
        run: { status: string; endedAt: string | null };
      };
      assert.equal(after.run.status, "cancelled");
      assert.ok(after.run.endedAt !== null);
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("cancel: clears the gate so no stale action stays on offer", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "parked then stopped" });
    f.store.updateRun(run.id, { status: "blocked_on_human", gate: "plan_approval" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/cancel`, {
        method: "POST",
      });
      assert.equal(res.status, 200);

      const after = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`)).json()) as {
        run: { status: string; gate: string | null };
      };
      assert.equal(after.run.status, "cancelled");
      /*
       * A cancelled run waits for nothing.
       *
       * Leaving the gate set kept the UI offering "approve plan" on a stopped run —
       * and pressing it resurrected the run, because both resume paths began by
       * writing `status: running`.
       */
      assert.equal(after.run.gate, null, "a stopped run must not still advertise a gate");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("resume: a cancelled run is refused synchronously, not after saying ok", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "cancelled but still gated" });
    // Deliberately keeps the gate set: this is the state an older cancel left
    // behind, and the guard must hold regardless of how the row got here.
    f.store.updateRun(run.id, { status: "cancelled", gate: "plan_approval" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/approve-plan`, {
        method: "POST",
      });

      /*
       * The refusal must be the HTTP response.
       *
       * This handler passes the work to a background promise and answered
       * `ok: true` immediately, so the orchestrator's own rejection landed in a
       * console log the user never sees — they were told the plan was approved
       * while nothing ran at all.
       */
      assert.equal(res.status, 409, "a predictable refusal must not be reported as success");
      const body = (await res.json()) as { error?: string; ok?: boolean };
      assert.equal(body.ok, undefined);
      assert.match(String(body.error), /cancelled/);

      // And the row is untouched by the attempt.
      const after = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`)).json()) as {
        run: { status: string };
      };
      assert.equal(after.run.status, "cancelled", "the run must not be resurrected");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("resume: a ruling is refused on a cancelled run rather than recorded", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "escalated then cancelled" });
    const sub = f.store.createSubTask({
      runId: run.id,
      stage: 0,
      title: "s",
      brief: "b",
      acceptance: "a",
      capability: "general",
      assignedExpertId: null,
      dependsOn: [],
      status: "blocked",
      worktreePath: null,
      branch: "todoagent/s",
    });
    const adj = f.store.createAdjudication({
      runId: run.id,
      subTaskId: sub.id,
      round: 1,
      verdict: "escalate",
      rationale: "a taste call",
      escalatedToHuman: true,
      humanDecision: null,
    });
    f.store.updateRun(run.id, { status: "cancelled", gate: "adjudication" });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/resolve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ adjudicationId: adj.id, decision: "use the flat shape" }),
      });
      assert.equal(res.status, 409);

      // Nothing may be recorded either: storing a ruling that will never be acted
      // on makes the record claim a decision was applied when it was not.
      const detail = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`)).json()) as {
        adjudications: Array<{ humanDecision: string | null }>;
      };
      assert.equal(detail.adjudications[0]?.humanDecision, null);
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("cancel: an already-finished run is refused", async () => {
  const f = await fixture();
  try {
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "done" });
    f.store.updateRun(run.id, { status: "completed", endedAt: new Date(0).toISOString() });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/cancel`, {
        method: "POST",
      });
      // Cancelling completed work would rewrite history for no benefit.
      assert.equal(res.status, 409);

      const res404 = await fetch(`http://127.0.0.1:${PORT}/api/runs/nope/cancel`, { method: "POST" });
      assert.equal(res404.status, 404, "an unknown run is a 404, not a silent success");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

/**
 * Builds a run parked at a gate with its token ceiling already breached.
 *
 * Not contrived: the turn immediately before a gate can carry the run past its
 * budget, leaving `status: blocked_on_human` and `spent > budget` at once. Found
 * on a real run — 2,110,081 spent of a 2,000,000 ceiling — while the UI showed
 * 需要你裁决 with a live submit button.
 */
function seedExhaustedGate(
  store: Store,
  gate: "plan_approval" | "adjudication",
): { runId: string; adjudicationId: string } {
  const projectId = seedProject(store, "/tmp");
  const run = store.createRun({ projectId, goal: "parked with no budget left", budgetTokens: 1000 });
  const sub = store.createSubTask({
    runId: run.id,
    stage: 0,
    title: "s",
    brief: "b",
    acceptance: "a",
    capability: "general",
    assignedExpertId: null,
    dependsOn: [],
    status: "blocked",
    worktreePath: null,
    branch: "todoagent/s",
  });
  const adj = store.createAdjudication({
    runId: run.id,
    subTaskId: sub.id,
    round: 1,
    verdict: "escalate",
    rationale: "a taste call no test can settle",
    escalatedToHuman: true,
    humanDecision: null,
  });
  // Status says "waiting for a human", spend says "nothing more can run".
  store.updateRun(run.id, { status: "blocked_on_human", gate, spentTokens: 1500 });
  return { runId: run.id, adjudicationId: adj.id };
}

test("resume: a ruling is refused when the budget is already spent", async () => {
  const f = await fixture();
  try {
    /*
     * `resumeBlockedReason` checked only `status`, and `blocked_on_human` is not in
     * its list — so the ruling was recorded, the API answered ok, and the pipeline
     * then died in the background with BudgetExceededError having spent nothing.
     *
     * Worse than an ordinary error: the user has just written out a considered
     * judgment, and it was discarded silently.
     */
    const { runId, adjudicationId } = seedExhaustedGate(f.store, "adjudication");
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}/resolve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ adjudicationId, decision: "use the flat shape" }),
      });

      assert.equal(res.status, 409);
      const body = (await res.json()) as { error: string };
      // The message has to say what to DO — the run looks resumable on screen.
      assert.match(body.error, /budget|ceiling/i);
      assert.match(body.error, /1,500/, "states what was spent");

      // And nothing may be recorded: a stored ruling claims a decision was applied.
      const detail = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}`)).json()) as {
        adjudications: Array<{ humanDecision: string | null }>;
      };
      assert.equal(detail.adjudications[0]?.humanDecision, null);
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("resume: approving a plan is refused when the budget is already spent", async () => {
  const f = await fixture();
  try {
    // The guard has two call sites and they share it, so both are pinned. Covering
    // one would be the partial fix this whole session has been removing.
    const { runId } = seedExhaustedGate(f.store, "plan_approval");
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}/approve-plan`, {
        method: "POST",
      });
      assert.equal(res.status, 409);
      assert.match(((await res.json()) as { error: string }).error, /budget|ceiling/i);

      // Still parked, not silently advanced.
      const detail = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}`)).json()) as {
        run: { status: string; gate: string | null };
      };
      assert.equal(detail.run.status, "blocked_on_human");
      assert.equal(detail.run.gate, "plan_approval");
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("resume: a ruling is refused when the run is not at the adjudication gate", async () => {
  const f = await fixture();
  try {
    // approve-plan already refuses off-gate; resolve used to skip the check and
    // answer ok, then clear whatever gate was actually holding the run.
    const { runId, adjudicationId } = seedExhaustedGate(f.store, "plan_approval");
    // Spend under the ceiling so the refusal is specifically about the gate.
    f.store.updateRun(runId, { spentTokens: 10 });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}/resolve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ adjudicationId, decision: "use the flat shape" }),
      });
      assert.equal(res.status, 409);
      assert.match(((await res.json()) as { error: string }).error, /adjudication gate/i);

      const detail = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${runId}`)).json()) as {
        run: { status: string; gate: string | null };
        adjudications: Array<{ humanDecision: string | null }>;
      };
      assert.equal(detail.run.status, "blocked_on_human");
      assert.equal(detail.run.gate, "plan_approval");
      assert.equal(detail.adjudications[0]?.humanDecision, null);
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});

test("resume: a forged adjudication id is refused before the API claims success", async () => {
  const f = await fixture();
  try {
    /*
     * Two things pinned at once:
     *
     * 1. Budget guard negative case — 10 of 1,000,000 spent must NOT be the reason.
     * 2. The forged-id hole — the endpoint used to answer `{ ok: true, resumed: true }`
     *    and only then throw `adjudication not found` in the background, so a test
     *    that merely checked `body.error` was undefined would vacuously pass.
     *
     * Deliberately never reaches the resume path: that would launch the pipeline
     * and spawn the operator's real CLI, which default tests must never do.
     */
    const projectId = seedProject(f.store, "/tmp");
    const run = f.store.createRun({ projectId, goal: "plenty left", budgetTokens: 1_000_000 });
    f.store.updateRun(run.id, { status: "blocked_on_human", gate: "adjudication", spentTokens: 10 });
    f.store.close();

    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/resolve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ adjudicationId: "no-such-adjudication", decision: "x" }),
      });

      assert.equal(res.status, 404);
      const body = (await res.json()) as { error?: string; ok?: boolean };
      assert.match(body.error ?? "", /adjudication not found/i);
      assert.equal(body.ok, undefined, "must not claim success for a forged id");
      assert.ok(
        !/budget|ceiling/i.test(body.error ?? ""),
        `a run with 10 of 1,000,000 spent must not be refused for budget; got: ${body.error}`,
      );

      // The run must stay parked — the old hole marked it `failed` via .catch.
      const detail = (await (await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}`)).json()) as {
        run: { status: string; error: string | null };
      };
      assert.equal(detail.run.status, "blocked_on_human");
      assert.equal(detail.run.error, null);
    });
  } finally {
    await f.dispose().catch(() => undefined);
  }
});
