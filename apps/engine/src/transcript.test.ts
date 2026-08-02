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

interface Fixture {
  dbPath: string;
  runId: string;
  attemptId: string;
  otherRunId: string;
  otherAttemptId: string;
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
  store.close();

  return {
    dbPath,
    runId: run.id,
    attemptId: attempt.id,
    otherRunId: other.id,
    otherAttemptId: otherAttempt.id,
    dispose: () => rm(dir, { recursive: true, force: true }),
  };
}

async function withEngine<T>(dbPath: string, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: { ...process.env, TODOAGENT_DB: dbPath, TODOAGENT_PORT: String(PORT) },
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
