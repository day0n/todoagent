import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * The transcript payload contract.
 *
 * Two properties are under test, and they pull against each other:
 *
 *  1. The run overview must NOT ship attempt output. Measured on a realistic run,
 *     it was 211 KB of a 292 KB payload — for text that view never renders — and
 *     the client refetches on every structural event, so one stage moved ~11 MB.
 *  2. That output must still be REACHABLE. Stripping it without an endpoint left
 *     72 transcripts in the database with no way to read them, so reloading a
 *     finished run showed no agent output at all (the live cards only exist inside
 *     the SSE session that produced them).
 *
 * Asserting on the actual HTTP response is the point: an in-process measurement
 * cannot prove what the serialiser emits.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8803; // distinct from the SSE (8799) and reconcile (8801) suites

const BIG_OUTPUT = "x".repeat(20_000);

/**
 * A working-tree snapshot, large enough to matter in a payload.
 *
 * Same argument as `BIG_OUTPUT` one line up, and the same mistake waiting to be
 * made: a diff is capped at 2M characters and `GET /api/runs` spreads whole Run
 * objects for up to 100 rows, so a `diff` field on that type would be the
 * `attempt.output` problem again at ten times the size.
 */
const BIG_DIFF = `# git status --porcelain\n M a.txt\n?? new.txt\n\ndiff --git a/a.txt b/a.txt\n${"+padding\n".repeat(2_000)}`;

interface Fixture {
  dbPath: string;
  runId: string;
  attemptId: string;
  otherRunId: string;
  otherAttemptId: string;
  /** A run whose newest attempt produced nothing, and whose tree was clean. */
  retriedRunId: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-transcript-"));
  const dbPath = join(dir, "t.db");
  const store = new Store(dbPath);

  const expert = store.createExpert({
    name: "Scribe",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  const project = store.createProject({ name: "p", repoPath: dir, teamId: team.id });

  const run = store.createRun({ projectId: project.id, goal: "with transcripts" });
  const sub = store.createSubTask({
    runId: run.id,
    stage: 0,
    title: "a subtask",
    brief: "b",
    acceptance: "a",
    capability: "general",
    assignedExpertId: expert.id,
    dependsOn: [],
    status: "done",
    worktreePath: null,
    branch: "todoagent/x",
  });
  const attempt = store.startAttempt({
    runId: run.id,
    subTaskId: sub.id,
    expertId: expert.id,
    runtimeKind: "claude",
    kind: "draft",
  });
  store.finishAttempt(attempt.id, {
    status: "completed",
    output: BIG_OUTPUT,
    inputTokens: 5000,
    outputTokens: 800,
    costUsd: 0.0042,
  });

  // A second run, to prove one run cannot read another's transcript.
  const other = store.createRun({ projectId: project.id, goal: "unrelated" });
  const otherAttempt = store.startAttempt({
    runId: other.id,
    subTaskId: null,
    expertId: expert.id,
    runtimeKind: "claude",
    kind: "plan",
  });
  store.finishAttempt(otherAttempt.id, { status: "completed", output: "secret plan" });

  // The main run carries a working-tree snapshot, as a completed direct run does.
  store.updateRun(run.id, { diff: BIG_DIFF });

  /*
   * A run whose LAST attempt produced nothing.
   *
   * `runOneWithRetry` can append a failed attempt after a successful one, so the
   * newest row is not necessarily the one holding the work. The two attempts use
   * different runtimes on purpose, so "which executor is reported" has a wrong
   * answer available.
   */
  const retried = store.createRun({ projectId: project.id, goal: "retried" });
  const good = store.startAttempt({
    runId: retried.id,
    subTaskId: null,
    expertId: expert.id,
    runtimeKind: "codex",
    kind: "draft",
  });
  store.finishAttempt(good.id, { status: "completed", output: "the work that counts" });
  const crashed = store.startAttempt({
    runId: retried.id,
    subTaskId: null,
    expertId: expert.id,
    runtimeKind: "claude",
    kind: "draft",
  });
  // No output: a crashed retry leaves the column null.
  store.finishAttempt(crashed.id, { status: "failed" });
  // Captured, and the tree was clean — the empty string, not null.
  store.updateRun(retried.id, { diff: "" });

  store.close();

  return {
    dbPath,
    runId: run.id,
    attemptId: attempt.id,
    otherRunId: other.id,
    otherAttemptId: otherAttempt.id,
    retriedRunId: retried.id,
    dispose: () => rm(dir, { recursive: true, force: true }),
  };
}

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
    await new Promise((r) => setTimeout(r, 200));
  }
}

test("the run overview omits attempt output but reports its size", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.runId}`);
      assert.equal(res.status, 200);
      const raw = await res.text();

      /*
       * The saving, asserted on the wire rather than inferred. 20 KB of output for
       * ONE attempt; a real run has dozens, and this payload is refetched on every
       * structural event.
       */
      assert.ok(
        !raw.includes(BIG_OUTPUT),
        "attempt output must not appear in the run overview payload",
      );

      const body = JSON.parse(raw) as {
        attempts: Array<Record<string, unknown>>;
      };
      const attempt = body.attempts[0];
      assert.ok(attempt);
      assert.equal("output" in attempt, false, "the field itself is dropped, not nulled");
      // Size is kept so the UI can indicate a transcript exists without paying for it.
      assert.equal(attempt["outputChars"], BIG_OUTPUT.length);
      // Everything the overview actually renders is still present.
      assert.equal(attempt["costUsd"], 0.0042);
      assert.equal(attempt["inputTokens"], 5000);
      assert.ok(typeof attempt["expertName"] === "string");
    });
  } finally {
    await f.dispose();
  }
});

test("the transcript endpoint serves the full output", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await fetch(
        `http://127.0.0.1:${PORT}/api/runs/${f.runId}/attempts/${f.attemptId}`,
      );
      assert.equal(res.status, 200);
      const body = (await res.json()) as {
        output: string | null;
        expertName: string;
        kind: string;
        costUsd: number;
      };

      // Without this endpoint the text was unreachable: in the database, and
      // invisible after a reload.
      assert.equal(body.output, BIG_OUTPUT);
      assert.equal(body.expertName, "Scribe");
      assert.equal(body.kind, "draft");
      assert.equal(body.costUsd, 0.0042);
    });
  } finally {
    await f.dispose();
  }
});

test("an attempt from another run is not readable", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      // A valid attempt id, but under the wrong run. Without the ownership check
      // this would leak another run's transcript to anyone who can guess an id.
      const res = await fetch(
        `http://127.0.0.1:${PORT}/api/runs/${f.runId}/attempts/${f.otherAttemptId}`,
      );
      assert.equal(res.status, 404);
      const raw = await res.text();
      assert.ok(!raw.includes("secret plan"), "the other run's output must not leak");

      // And it IS readable under its own run, so the check is scoping rather than
      // blanket denial.
      const ok = await fetch(
        `http://127.0.0.1:${PORT}/api/runs/${f.otherRunId}/attempts/${f.otherAttemptId}`,
      );
      assert.equal(ok.status, 200);
      assert.equal(((await ok.json()) as { output: string }).output, "secret plan");
    });
  } finally {
    await f.dispose();
  }
});

test("unknown ids are 404, not a 500 or an empty success", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const badAttempt = await fetch(
        `http://127.0.0.1:${PORT}/api/runs/${f.runId}/attempts/does-not-exist`,
      );
      assert.equal(badAttempt.status, 404);

      const badRun = await fetch(
        `http://127.0.0.1:${PORT}/api/runs/does-not-exist/attempts/${f.attemptId}`,
      );
      assert.equal(badRun.status, 404);
    });
  } finally {
    await f.dispose();
  }
});

// ── /result: what the drawer reads ──────────────────────────

interface ResultBody {
  run: Record<string, unknown>;
  diff: string | null;
  output: string | null;
  executor: string | null;
}

test("the result endpoint serves the snapshot and the final output together", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.runId}/result`);
      assert.equal(res.status, 200);
      const body = (await res.json()) as ResultBody;

      assert.equal(body.diff, BIG_DIFF, "the whole snapshot is served, uncapped by the endpoint");
      assert.equal(body.output, BIG_OUTPUT, "and the attempt's final text alongside it");
      assert.equal(body.executor, "claude");
      assert.equal(body.run["goal"], "with transcripts");

      // One request, because the drawer opens on a click and two round trips would
      // show a header with an empty body under it.
      assert.ok(body.run["status"] !== undefined, "the run itself travels with it");
    });
  } finally {
    await f.dispose();
  }
});

test("the run overview omits the diff, as it omits attempt output", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      /*
       * The reason `diff` is not a field on the `Run` interface.
       *
       * `toRun` maps every field of that type, and `GET /api/runs` spreads whole Run
       * objects for up to 100 rows — so a 2M-character snapshot on the type would put
       * up to 200 MB in one list response. This is `attempt.output` again (211 KB of a
       * 292 KB payload, refetched on every structural event) at ten times the scale,
       * which is why it is asserted on the wire rather than argued about.
       */
      const detail = await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.runId}`);
      const detailRaw = await detail.text();
      assert.ok(!detailRaw.includes("diff --git"), "the run detail payload carries no snapshot");

      const list = await fetch(`http://127.0.0.1:${PORT}/api/runs`);
      const listRaw = await list.text();
      assert.ok(!listRaw.includes("diff --git"), "and neither does the run list");
    });
  } finally {
    await f.dispose();
  }
});

test("the result endpoint reads past a crashed retry to the attempt that worked", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const body = (await (
        await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.retriedRunId}/result`)
      ).json()) as ResultBody;

      /*
       * `runOneWithRetry` can append a failed attempt AFTER a successful one, and a
       * crashed attempt has `output: null`. Taking the newest row blindly would show
       * an empty result for a run whose work sits in the attempt before it — the
       * drawer would say the agent produced nothing on a run that produced plenty.
       */
      assert.equal(body.output, "the work that counts");
      assert.equal(
        body.executor,
        "codex",
        "the executor reported is the one that did the work, not the one that crashed",
      );
    });
  } finally {
    await f.dispose();
  }
});

test("an empty snapshot is not the same answer as no snapshot", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      /*
       * The distinction the UI depends on to avoid stating something false.
       *
       *   ""    captured, and the tree was clean → "the agent changed no files",
       *         which is a real and reportable outcome.
       *   null  never captured — the run failed, was cancelled, or predates the
       *         column → the UI must NOT claim nothing changed, because a failed run
       *         may well have edited several files before dying.
       *
       * JSON preserves both, so this is really a check that nothing along the way
       * coalesces one into the other.
       */
      const clean = (await (
        await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.retriedRunId}/result`)
      ).json()) as ResultBody;
      assert.equal(clean.diff, "", "a clean tree reports an empty snapshot");

      const never = (await (
        await fetch(`http://127.0.0.1:${PORT}/api/runs/${f.otherRunId}/result`)
      ).json()) as ResultBody;
      assert.equal(never.diff, null, "a run with no snapshot reports null");
    });
  } finally {
    await f.dispose();
  }
});

test("the result endpoint 404s an unknown run", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/does-not-exist/result`);
      assert.equal(res.status, 404);
    });
  } finally {
    await f.dispose();
  }
});
