import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { Store } from "../db/index.ts";
import { Semaphore } from "../util/concurrency.ts";
import { BudgetExceededError, runOne } from "./runner.ts";

/**
 * What happens to a turn while it WAITS for a concurrency slot.
 *
 * Adding the semaphore introduced a gap between "asked to run" and "actually
 * running", and the original ordering recorded the attempt row and the
 * `attempt:started` event before acquiring a slot. That produced confident
 * misinformation rather than an error, which is the failure class this whole
 * project keeps running into:
 *
 *  - the UI showed six agents "thinking" when the limit was three;
 *  - `startedAt` was stamped at enqueue, so queue time was billed as agent time —
 *    corrupting the exact timing data meant to calibrate expert routing;
 *  - the budget was read before the wait, so every queued turn could overshoot the
 *    ceiling by one full agent run.
 *
 * The slot is held manually here, which makes the queued window precise instead of
 * relying on timing luck.
 */

const SETTLE_MS = 250;
const tick = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** A fake `claude` that answers immediately. */
const FAKE = `#!/usr/bin/env node
process.stdout.write(JSON.stringify({
  is_error: false,
  session_id: "fake",
  result: "done",
  usage: { input_tokens: 100, output_tokens: 20 },
  type: "result",
}) + "\\n");
`;

interface Fixture {
  store: Store;
  runId: string;
  expertId: string;
  cwd: string;
  dispose: () => Promise<void>;
}

async function fixture(budgetTokens = 0): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "council-queue-"));
  const binDir = join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const fake = join(binDir, "claude");
  await writeFile(fake, FAKE, "utf8");
  await chmod(fake, 0o755);

  const originalPath = process.env["PATH"] ?? "";
  process.env["PATH"] = `${binDir}${delimiter}${originalPath}`;

  const store = new Store(join(root, "q.db"));
  const expert = store.createExpert({
    name: "Queued",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  const project = store.createProject({ name: "p", repoPath: root, teamId: team.id });
  const run = store.createRun({ projectId: project.id, goal: "g", budgetTokens });

  return {
    store,
    runId: run.id,
    expertId: expert.id,
    cwd: root,
    async dispose() {
      process.env["PATH"] = originalPath;
      store.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

function start(f: Fixture, slots: Semaphore): Promise<{ ok: boolean; attemptId: string }> {
  const expert = f.store.getExpert(f.expertId);
  assert.ok(expert);
  return runOne({
    store: f.store,
    runId: f.runId,
    expert,
    kind: "draft",
    subTaskId: null,
    prompt: "go",
    cwd: f.cwd,
    timeoutMs: 60_000,
    slots,
  });
}

test("a queued turn records nothing until it actually starts", async () => {
  const f = await fixture();
  try {
    const slots = new Semaphore(1);
    // Occupy the only slot, so the turn below is definitely queued.
    await slots.acquire();

    const pending = start(f, slots);
    await tick(SETTLE_MS);

    /*
     * The UI-honesty assertion.
     *
     * `attempt:started` used to be emitted here, so with a limit of three and six
     * subtasks a user saw six cards claiming to be thinking while three processes
     * existed. "Looks like it is working" is precisely the bug class this system is
     * built to avoid.
     */
    assert.equal(
      f.store.listAttempts(f.runId).length,
      0,
      "no attempt row may exist while the turn is still queued",
    );
    assert.equal(
      f.store.eventsAfter(f.runId, 0, 100).length,
      0,
      "no event may be broadcast for a turn that has not started",
    );

    slots.release();
    const res = await pending;
    assert.equal(res.ok, true);
    // And once it runs, everything is recorded exactly once.
    assert.equal(f.store.listAttempts(f.runId).length, 1);
    const started = f.store.eventsAfter(f.runId, 0, 100).filter((e) => e.type === "attempt:started");
    assert.equal(started.length, 1);
  } finally {
    await f.dispose();
  }
});

test("startedAt excludes queue time", async () => {
  const f = await fixture();
  try {
    const slots = new Semaphore(1);
    await slots.acquire();

    const enqueuedAt = Date.now();
    const pending = start(f, slots);
    const WAIT = 600;
    await tick(WAIT);
    slots.release();
    await pending;

    const attempt = f.store.listAttempts(f.runId)[0];
    assert.ok(attempt);
    const startedAt = Date.parse(attempt.startedAt);

    /*
     * A turn that waited five minutes and ran for one used to report six minutes of
     * work. That number is not cosmetic: the run history is the only honest source
     * for calibrating which expert is actually good at what, and folding queue time
     * into it makes a fast expert on a busy pool look slow.
     */
    assert.ok(
      startedAt - enqueuedAt >= WAIT - 50,
      `startedAt was stamped ${startedAt - enqueuedAt}ms after enqueue, expected at least ${WAIT}ms`,
    );
  } finally {
    await f.dispose();
  }
});

test("budget spent by siblings while queued is respected", async () => {
  const f = await fixture(1_000);
  try {
    const slots = new Semaphore(1);
    await slots.acquire();

    const pending = start(f, slots);
    await tick(SETTLE_MS);
    // A sibling turn finishes and exhausts the ceiling while this one waits.
    f.store.addSpend(f.runId, 5_000);
    slots.release();

    /*
     * The pre-check at the top of runOne is no longer "immediately before the spawn"
     * once a semaphore sits between them. Without re-reading after the wait, every
     * queued turn spends a full agent run against a budget that is already gone.
     */
    await assert.rejects(() => pending, BudgetExceededError);
    assert.equal(
      f.store.listAttempts(f.runId).length,
      0,
      "no attempt may be recorded for a turn that could not afford to run",
    );
  } finally {
    await f.dispose();
  }
});

test("a cancel that lands while queued stops the turn", async () => {
  const f = await fixture();
  try {
    const slots = new Semaphore(1);
    await slots.acquire();

    const pending = start(f, slots);
    await tick(SETTLE_MS);
    // The user presses Stop while this turn is still in line.
    f.store.updateRun(f.runId, { status: "cancelled", endedAt: new Date().toISOString() });
    slots.release();

    // Spawning after a cancel wastes tokens and can write files the user no longer
    // wants — the cancel has to be seen at the point of spawning, not only before
    // the wait.
    await assert.rejects(() => pending, /cancelled/);
    assert.equal(f.store.listAttempts(f.runId).length, 0);
  } finally {
    await f.dispose();
  }
});

test("an abort signal that fires while queued stops the turn", async () => {
  const f = await fixture();
  try {
    const slots = new Semaphore(1);
    await slots.acquire();

    const controller = new AbortController();
    const expert = f.store.getExpert(f.expertId);
    assert.ok(expert);
    const pending = runOne({
      store: f.store,
      runId: f.runId,
      expert,
      kind: "draft",
      subTaskId: null,
      prompt: "go",
      cwd: f.cwd,
      timeoutMs: 60_000,
      slots,
      signal: controller.signal,
    });

    await tick(SETTLE_MS);
    // The signal path matters separately from the database status: an in-process
    // abort fires before any row is written.
    controller.abort();
    slots.release();

    await assert.rejects(() => pending, /cancelled/);
    assert.equal(f.store.listAttempts(f.runId).length, 0);
  } finally {
    await f.dispose();
  }
});

test("the slot is released after a queued turn is rejected", async () => {
  const f = await fixture(1_000);
  try {
    const slots = new Semaphore(1);
    await slots.acquire();

    const pending = start(f, slots);
    await tick(SETTLE_MS);
    f.store.addSpend(f.runId, 5_000);
    slots.release();
    await assert.rejects(() => pending);

    /*
     * A rejected turn must hand its slot back. Leaking here would shrink the pool
     * permanently — presenting as the agents getting mysteriously slower rather than
     * as a bug, since nothing errors.
     */
    assert.equal(slots.active, 0, "the slot was returned");
    assert.equal(slots.available, 1);
  } finally {
    await f.dispose();
  }
});
