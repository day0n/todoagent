import assert from "node:assert/strict";
import { test } from "node:test";
import {
  MAX_EVENTS,
  MAX_LIVE_CHARS,
  applyEvent,
  emptyRunStreamState,
  needsRefetch,
  type RunStreamState,
} from "./run-stream.ts";
import type { StreamEvent } from "./types.ts";

/**
 * The run stream's state machine.
 *
 * This file is the reason `run-stream.ts` exists. The same ~150 lines used to sit
 * inside a `useEffect` in `useRun`, which made them unreachable from a test — so
 * the retry badge shipped with "NOT verified in a browser" in its commit message,
 * because forcing a real CLI into a transient failure on demand is not feasible.
 * Handing `applyEvent` an `attempt:retrying` event is trivial.
 *
 * Event shapes below are the ones the engine really emits, taken from
 * pipeline.ts/runner.ts rather than invented.
 */

let nextId = 0;

/** Builds an event with the fields the engine actually sends. */
function ev(type: string, payload: unknown, attemptId: string | null = null): StreamEvent {
  nextId++;
  return { id: nextId, type, attemptId, payload, createdAt: "2026-08-01T00:00:00.000Z" };
}

/** Walks a sequence, so a test reads as the story the user lived through. */
function play(events: StreamEvent[], from: RunStreamState = emptyRunStreamState()): RunStreamState {
  return events.reduce(applyEvent, from);
}

const started = (id: string, name = "Probe", kind = "review"): StreamEvent =>
  ev("attempt:started", { expertName: name, runtimeKind: "codex", kind, subTaskId: "s1" }, id);

// ── The retry badge, the reason this module was extracted ────

test("attempt:retrying marks the FAILED attempt, not a new one", () => {
  /*
   * A retry spawns a new attempt with its own id. The engine emits
   * `attempt:retrying` against the id that FAILED, so the card the user is already
   * watching can say another try follows instead of a bare failure appearing next
   * to a mysterious new card.
   */
  const state = play([
    started("a1"),
    ev("attempt:finished", { status: "failed", error: "HTTP 503 service unavailable" }, "a1"),
    ev("attempt:retrying", { attempt: 1, of: 2, reason: "HTTP 503 service unavailable" }, "a1"),
    // The replacement turn, with a different id.
    started("a2"),
  ]);

  const failed = state.live.get("a1");
  assert.deepEqual(failed?.retrying, { attempt: 1, of: 2 });
  // Still `failed` — it did fail. The badge reports both facts.
  assert.equal(failed?.status, "failed");
  assert.match(failed?.error ?? "", /503/);

  // The retry marker belongs to the old attempt only.
  assert.equal(state.live.get("a2")?.retrying, null);
  assert.equal(state.live.get("a2")?.status, "running");
});

test("attempt:retrying for an unknown attempt is ignored", () => {
  // Reachable on a mid-run reconnect whose replay starts after `attempt:started`.
  const before = emptyRunStreamState();
  const after = applyEvent(before, ev("attempt:retrying", { attempt: 1, of: 2 }, "ghost"));
  assert.equal(after.live.size, 0);
});

test("attempt:retrying falls back to 1/1 when the payload is malformed", () => {
  // The engine always sends both, but a client must not render NaN if it does not.
  const state = play([started("a1"), ev("attempt:retrying", { attempt: "two" }, "a1")]);
  assert.deepEqual(state.live.get("a1")?.retrying, { attempt: 1, of: 1 });
});

// ── Identity, which React depends on ────────────────────────

test("an event that changes nothing returns the SAME state object", () => {
  /*
   * Not a micro-optimisation. `applyEvent` is used as a React state updater, so
   * returning a fresh object for a no-op event re-renders the run page — and
   * `agent:*` events for unknown attempts arrive in bursts after a reconnect.
   */
  const state = play([started("a1")]);

  /*
   * Only the FIREHOSE is a true no-op. An `agent:*` event never enters the log, so
   * one that cannot be attached to a card leaves the state untouched entirely.
   */
  for (const noop of [
    ev("agent:text", { content: "x" }, "ghost"),
    ev("agent:unknown_kind", { content: "x" }, "a1"),
  ]) {
    assert.equal(applyEvent(state, noop), state, `${noop.type} must be a no-op`);
  }
});

test("a structural event for an unknown attempt is logged but changes nothing else", () => {
  /*
   * My first version of the test above expected these to be no-ops too, and that
   * was wrong about the code rather than a bug in it: the event DID happen — the
   * engine emitted it — so the log has to record it. Silently dropping it would
   * lose the only evidence, which is the same reasoning as logging an `agent:*`
   * event that carries no attempt id.
   *
   * What must NOT change is `live`: there is no card to attach it to.
   */
  const state = play([started("a1")]);

  for (const orphan of [
    ev("attempt:retrying", { attempt: 1, of: 2 }, "ghost"),
    ev("attempt:finished", { status: "completed" }, "ghost"),
  ]) {
    const after = applyEvent(state, orphan);
    assert.notEqual(after, state, `${orphan.type} must be recorded`);
    assert.equal(after.log.length, state.log.length + 1);
    assert.equal(after.live, state.live, "no card exists, so live must keep its identity");
  }
});

test("a real change produces a new object but shares untouched slices", () => {
  const before = play([started("a1")]);
  const after = applyEvent(before, ev("agent:text", { content: "hi" }, "a1"));

  assert.notEqual(after, before, "the root must change so React re-renders");
  assert.notEqual(after.live, before.live, "the live map changed");
  // Slices the event did not touch keep their identity, so consumers memoised on
  // them do not re-render.
  assert.equal(after.log, before.log);
  assert.equal(after.reachedPhases, before.reachedPhases);
});

// ── The firehose ────────────────────────────────────────────

test("agent:text accumulates and never enters the log", () => {
  const state = play([
    started("a1"),
    ev("agent:text", { content: "Hello " }, "a1"),
    ev("agent:text", { content: "world" }, "a1"),
  ]);

  assert.equal(state.live.get("a1")?.text, "Hello world");
  // Per-token chatter in the log would bury every structural event; only
  // `attempt:started` is there.
  assert.deepEqual(
    state.log.map((r) => r.type),
    ["attempt:started"],
  );
});

test("live text is capped, keeping the most recent output", () => {
  /*
   * The tail is what matters: this is a live view, and the full transcript is in
   * the database. Keeping the head would freeze the card on an agent's opening
   * words while it kept working.
   */
  const state = play([
    started("a1"),
    ev("agent:text", { content: "A".repeat(MAX_LIVE_CHARS) }, "a1"),
    ev("agent:text", { content: "TAIL" }, "a1"),
  ]);

  const text = state.live.get("a1")?.text ?? "";
  assert.equal(text.length, MAX_LIVE_CHARS);
  assert.ok(text.endsWith("TAIL"), "the newest output must survive");
  assert.ok(!text.startsWith("A".repeat(10)) || text.length === MAX_LIVE_CHARS);
});

test("tool events track the current call and count it", () => {
  const state = play([
    started("a1"),
    ev("agent:tool_use", { tool: "read_file" }, "a1"),
    ev("agent:tool_result", { tool: "read_file" }, "a1"),
    ev("agent:tool_use", { tool: "bash" }, "a1"),
  ]);

  const live = state.live.get("a1");
  // Cleared on result, set again on the next call — this drives "正在执行 X".
  assert.equal(live?.currentTool, "bash");
  assert.equal(live?.toolCount, 2, "the count is cumulative, not the in-flight count");
});

test("a tool call with no name still reads as a tool", () => {
  const state = play([started("a1"), ev("agent:tool_use", {}, "a1")]);
  assert.equal(state.live.get("a1")?.currentTool, "tool");
});

test("an agent event with no attempt id goes to the log rather than vanishing", () => {
  /*
   * The firehose guard requires BOTH a non-null attemptId and an `agent:` prefix.
   * An `agent:*` event without an id cannot be attached to any card, so it falls
   * through to the log — dropping it would lose it entirely.
   */
  const state = applyEvent(emptyRunStreamState(), ev("agent:error", { message: "orphaned" }, null));
  assert.deepEqual(
    state.log.map((r) => r.type),
    ["agent:error"],
  );
});

// ── Attempt completion ──────────────────────────────────────

test("attempt:finished maps status and clears the in-flight tool", () => {
  const done = play([
    started("a1"),
    ev("agent:tool_use", { tool: "bash" }, "a1"),
    ev("attempt:finished", { status: "completed" }, "a1"),
  ]);
  assert.equal(done.live.get("a1")?.status, "done");
  assert.equal(done.live.get("a1")?.currentTool, null, "a finished turn is not running a tool");

  // Anything other than `completed` is a failure for display purposes, including
  // timeout and cancelled.
  for (const status of ["failed", "timeout", "cancelled"]) {
    const state = play([started("a1"), ev("attempt:finished", { status }, "a1")]);
    assert.equal(state.live.get("a1")?.status, "failed", `${status} must read as failed`);
  }
});

test("attempt:finished keeps an earlier agent:error when it carries none", () => {
  // `agent:error` often has the specific message and the terminal event does not,
  // so overwriting with undefined would discard the only useful detail.
  const state = play([
    started("a1"),
    ev("agent:error", { message: "rate limit exceeded" }, "a1"),
    ev("attempt:finished", { status: "failed" }, "a1"),
  ]);
  assert.equal(state.live.get("a1")?.error, "rate limit exceeded");
});

// ── Phases ──────────────────────────────────────────────────

test("phases accumulate without duplicating", () => {
  const state = play([
    ev("phase:entered", { phase: "plan" }),
    ev("phase:entered", { phase: "draft" }),
    ev("phase:entered", { phase: "plan" }),
    ev("phase:entered", { phase: "" }),
  ]);

  assert.deepEqual([...state.reachedPhases].sort(), ["draft", "plan"]);
  // Every phase event is still logged, even the ones that changed nothing.
  assert.equal(state.log.filter((r) => r.type === "phase:entered").length, 4);
});

test("a repeated phase does not churn the reachedPhases set", () => {
  const first = play([ev("phase:entered", { phase: "plan" })]);
  const again = applyEvent(first, ev("phase:entered", { phase: "plan" }));
  // The log grows, so the root changes — but the set must keep its identity.
  assert.equal(again.reachedPhases, first.reachedPhases);
});

// ── Verify and merge ────────────────────────────────────────

test("verify:done records the report and its verdict", () => {
  const failed = play([ev("verify:done", { ok: false, report: "2 tests failed" })]);
  assert.deepEqual(failed.verifyReport, { text: "2 tests failed", ok: false });

  // solo:done carries `output` and no `ok`, and is only emitted after success.
  const solo = play([ev("solo:done", { output: "did the thing" })]);
  assert.deepEqual(solo.verifyReport, { text: "did the thing", ok: true });

  // An empty report is not a report.
  const empty = play([ev("verify:done", { ok: true, report: "" })]);
  assert.equal(empty.verifyReport, null);
});

test("merge:needs_human separates conflicts from unmergeable work", () => {
  const state = play([
    ev("merge:needs_human", { conflicted: ["a (branch-a): CONFLICT"], unmergeable: ["b"] }),
  ]);
  assert.deepEqual(state.mergeConflicts, ["a (branch-a): CONFLICT"]);
  assert.deepEqual(state.unmergeable, ["b"]);

  // Missing arrays degrade to empty rather than crashing the page.
  const partial = play([ev("merge:needs_human", {})]);
  assert.deepEqual(partial.mergeConflicts, []);
  assert.deepEqual(partial.unmergeable, []);
});

// ── The log ─────────────────────────────────────────────────

test("the log is capped and keeps the newest events", () => {
  let state = emptyRunStreamState();
  for (let i = 0; i < MAX_EVENTS + 50; i++) {
    state = applyEvent(state, ev("subtask:accepted", { n: i }));
  }

  assert.equal(state.log.length, MAX_EVENTS);
  // A real run emits far more than the cap, and the recent end is the useful one.
  const last = state.log[state.log.length - 1]?.payload as { n: number };
  assert.equal(last.n, MAX_EVENTS + 49);
});

test("search text is precomputed, lowercased and bounded", () => {
  const state = play([ev("subtask:failed", { title: "Add JSDoc To Greet", huge: "X".repeat(5000) })]);
  const row = state.log[0];

  assert.ok(row?.search.includes("add jsdoc to greet"), "payload text must be searchable");
  assert.ok(row?.search.includes("subtask:failed"), "the type must be searchable too");
  // Bounded so filtering does not stringify megabytes on every keystroke.
  assert.ok((row?.search.length ?? 0) <= 2000);
});

test("a malformed payload does not break the log row", () => {
  for (const payload of [null, undefined, "a string", 42, []]) {
    const state = applyEvent(emptyRunStreamState(), ev("weird:event", payload));
    assert.equal(state.log.length, 1);
    assert.equal(typeof state.log[0]?.search, "string");
  }
});

// ── Refetch classification ──────────────────────────────────

test("needsRefetch is false for events handled in full", () => {
  /*
   * These four are applied completely on the client, so refetching after them
   * would be a request that changes nothing. `agent:*` matters most: it is the
   * firehose, and one refetch per token would flood the engine.
   */
  for (const e of [
    ev("agent:text", { content: "x" }, "a1"),
    ev("phase:entered", { phase: "draft" }),
    started("a1"),
    ev("attempt:retrying", { attempt: 1, of: 2 }, "a1"),
    ev("merge:needs_human", { conflicted: [] }),
  ]) {
    assert.equal(needsRefetch(e), false, `${e.type} must not refetch`);
  }
});

test("needsRefetch is true for anything that changes server state", () => {
  // `attempt:finished` included: usage and cost land on the row, not in the event.
  for (const e of [
    ev("attempt:finished", { status: "completed" }, "a1"),
    ev("subtask:accepted", {}),
    ev("review:done", {}),
    ev("run:completed", {}),
    // An unrecognised type refetches rather than being silently dropped, so a new
    // engine event cannot go unnoticed by an older client.
    ev("something:new_in_a_later_version", {}),
  ]) {
    assert.equal(needsRefetch(e), true, `${e.type} must refetch`);
  }
});

test("an agent event with no attempt id still refetches", () => {
  // It could not be attached to a card, so the server is the authority on what it
  // meant.
  assert.equal(needsRefetch(ev("agent:error", { message: "x" }, null)), true);
});

// ── A whole run ─────────────────────────────────────────────

test("a realistic sequence ends in the state the page renders", () => {
  const state = play([
    ev("phase:entered", { phase: "plan" }),
    started("p1", "Atlas", "plan"),
    ev("agent:text", { content: "decomposing" }, "p1"),
    ev("attempt:finished", { status: "completed" }, "p1"),
    ev("phase:entered", { phase: "draft" }),
    started("d1", "Vector", "draft"),
    ev("agent:tool_use", { tool: "write_file" }, "d1"),
    ev("agent:tool_result", {}, "d1"),
    ev("attempt:finished", { status: "completed" }, "d1"),
    ev("phase:entered", { phase: "review" }),
    // One reviewer 503s, is retried, and the replacement succeeds.
    started("r1", "Probe", "review"),
    ev("attempt:finished", { status: "failed", error: "HTTP 503" }, "r1"),
    ev("attempt:retrying", { attempt: 1, of: 2 }, "r1"),
    started("r2", "Probe", "review"),
    ev("attempt:finished", { status: "completed" }, "r2"),
    ev("phase:entered", { phase: "verify" }),
    ev("verify:done", { ok: true, report: "all green" }),
  ]);

  assert.deepEqual([...state.reachedPhases].sort(), ["draft", "plan", "review", "verify"]);
  assert.equal(state.live.size, 4);
  assert.equal(state.verifyReport?.ok, true);

  // The failed reviewer reads as "failed, retried" rather than as a dead end.
  assert.equal(state.live.get("r1")?.status, "failed");
  assert.deepEqual(state.live.get("r1")?.retrying, { attempt: 1, of: 2 });
  assert.equal(state.live.get("r2")?.status, "done");

  // Streaming prose stays out of the log, while tool boundaries remain as the
  // durable execution record shown in a task conversation.
  assert.ok(!state.log.some((r) => r.type === "agent:text"));
  assert.deepEqual(
    state.log.filter((r) => r.type.startsWith("agent:")).map((r) => r.type),
    ["agent:tool_use", "agent:tool_result"],
  );
});
