import assert from "node:assert/strict";
import { test } from "node:test";
import {
  applyOptimistic,
  applyPoll,
  applyServerRow,
  hasLiveRun,
  isRunLive,
} from "./board-state.ts";
import type { Task } from "./types.ts";

/**
 * Board reconciliation: which write wins when two arrive out of order.
 *
 * This file exists because I claimed, in the commit that fixed the race, that
 * extracting the logic "does not make it testable either, since the difficulty is
 * the interleaving". That was wrong — and wrong against my own evidence, since
 * pulling the run stream's state machine out of `useRun` had made exactly this
 * class of ordering bug testable and caught a real one in the process.
 *
 * The interleaving is the easy part to express: capture a mutation count, land a
 * patch, then land the poll that predates it. What a unit test cannot cover is
 * React's scheduling — and that was never where the bug lived.
 */

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    channelId: "c1",
    title: `task ${id}`,
    status: "todo",
    note: "",
    myDay: null,
    needsKind: null,
    needsText: null,
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: null,
    runId: null,
    createdAt: "2026-08-01T00:00:00.000Z",
    updatedAt: "2026-08-01T00:00:00.000Z",
    ...over,
  };
}

// ── The race, expressed as a sequence ───────────────────────

test("a poll issued BEFORE a local change is discarded", () => {
  /*
   * The exact bug, in the order it happened:
   *
   *   1. poll goes out          (mutations = 0)
   *   2. user drags a card      (mutations = 1, optimistic write applied)
   *   3. poll comes back        carrying data from step 1
   *
   * `load` replaced the whole array, so step 3 snapped the card back to 待办 — and
   * nothing corrected it, because the patch's success path wrote nothing. The card
   * stayed wrong until the next poll, or forever once the run ended and polling
   * stopped.
   */
  const board = [task("a"), task("b")];

  const requestedAt = 0; // captured when the poll went out

  // The drag.
  const afterDrag = applyOptimistic(board, "a", { status: "in_progress" });
  const mutationsNow = 1;

  // The stale response, describing a board where "a" is still todo.
  const settled = applyPoll(afterDrag, board, requestedAt, mutationsNow);

  assert.equal(
    settled?.find((t) => t.id === "a")?.status,
    "in_progress",
    "the user's drag must survive a poll that predates it",
  );
  assert.equal(settled, afterDrag, "a discarded poll returns the same array — no re-render");
});

test("a poll issued AFTER the last change is applied in full", () => {
  // The normal case. Nothing changed while it was in flight, so the server is the
  // authority — including for cards the user never touched.
  const stale = [task("a"), task("b", { status: "todo" })];
  const fresh = [task("a"), task("b", { status: "in_review" })];

  const settled = applyPoll(stale, fresh, 3, 3);

  assert.equal(settled, fresh, "an up-to-date response replaces the array wholesale");
  assert.equal(settled?.find((t) => t.id === "b")?.status, "in_review");
});

test("the discarded poll's cost is named: other cards' updates are dropped too", () => {
  /*
   * Discarding the whole response also loses an unrelated card's update. That is
   * the accepted trade rather than an oversight: polling only runs while a run is
   * live, so another response follows within seconds, whereas silently reverting
   * the drag the user just made is a wrong state they cannot correct.
   */
  const board = [task("a"), task("b", { status: "todo" })];
  const afterDrag = applyOptimistic(board, "a", { status: "in_progress" });
  // The server also moved "b" — genuine news, in a response we must reject.
  const incoming = [task("a"), task("b", { status: "in_review" })];

  const settled = applyPoll(afterDrag, incoming, 0, 1);

  assert.equal(settled?.find((t) => t.id === "b")?.status, "todo", "b's update is lost for now");
  assert.equal(settled?.find((t) => t.id === "a")?.status, "in_progress", "a's drag is kept");
});

test("patch then server row: the authoritative value replaces the guess", () => {
  /*
   * The half that was missing entirely. Without `applyServerRow` the optimistic
   * value stood unconfirmed forever once polling stopped.
   *
   * The server's row also carries what the guess could not: `updatedAt`, and an
   * assignee pair the engine may have normalised.
   */
  const board = [task("a")];
  const guessed = applyOptimistic(board, "a", { status: "in_progress" });
  assert.equal(guessed?.[0]?.updatedAt, "2026-08-01T00:00:00.000Z", "the guess invents no timestamp");

  const authoritative = task("a", {
    status: "in_progress",
    runId: "run-1",
    updatedAt: "2026-08-01T00:05:00.000Z",
  });
  const settled = applyServerRow(guessed, authoritative);

  assert.equal(settled?.[0], authoritative);
  assert.equal(settled?.[0]?.runId, "run-1", "the run id only the server knew");
  assert.equal(settled?.[0]?.updatedAt, "2026-08-01T00:05:00.000Z");
});

test("a full drag lifecycle survives a poll landing at every point", () => {
  /*
   * Sweeps the poll across the whole sequence. The card must read `in_progress`
   * at the end regardless of when the stale response arrives — that is the property
   * the fix is really claiming.
   */
  const original = [task("a"), task("b")];

  for (const landsAt of ["before-patch", "between", "after-server-row"] as const) {
    let state: Task[] | null = original;
    let mutations = 0;

    const pollRequestedAt = mutations;

    if (landsAt === "before-patch") {
      // Harmless: nothing has changed yet, so applying it is correct.
      state = applyPoll(state, original, pollRequestedAt, mutations);
    }

    mutations++;
    state = applyOptimistic(state, "a", { status: "in_progress" });

    if (landsAt === "between") {
      state = applyPoll(state, original, pollRequestedAt, mutations);
    }

    state = applyServerRow(state, task("a", { status: "in_progress", runId: "run-1" }));

    if (landsAt === "after-server-row") {
      state = applyPoll(state, original, pollRequestedAt, mutations);
    }

    assert.equal(
      state?.find((t) => t.id === "a")?.status,
      "in_progress",
      `a stale poll landing ${landsAt} must not revert the card`,
    );
  }
});

// ── Identity, which React depends on ────────────────────────

test("nothing-changed cases return the same array", () => {
  // These are used as state updaters, so a fresh array re-renders every card.
  const board = [task("a")];

  assert.equal(applyOptimistic(board, "missing", { status: "done" }), board);
  assert.equal(applyServerRow(board, task("missing")), board);
  assert.equal(applyPoll(board, [task("x")], 0, 1), board);

  // Null means "not loaded yet"; every function passes it through untouched.
  assert.equal(applyOptimistic(null, "a", { status: "done" }), null);
  assert.equal(applyServerRow(null, task("a")), null);
});

test("a real change copies the array but not the untouched rows", () => {
  const a = task("a");
  const b = task("b");
  const next = applyOptimistic([a, b], "a", { status: "done" });

  assert.notEqual(next, null);
  assert.notEqual(next?.[0], a, "the edited row is a new object");
  assert.equal(next?.[1], b, "an untouched row keeps its identity");
  assert.equal(a.status, "todo", "the input row is not mutated");
});

test("a server row for a card not on the board is not inserted", () => {
  /*
   * A filter may be excluding it — `创建者` and `负责人` both narrow the list. Forcing
   * the row back in would defeat the filter the user set.
   */
  const filtered = [task("a")];
  assert.equal(applyServerRow(filtered, task("hidden", { status: "done" })), filtered);
});

// ── The live-run inference ──────────────────────────────────

test("a run is live only with both a run id and in_progress", () => {
  /*
   * The board never sees a run's status, only the card's. But the engine moves a
   * finished card off in_progress — completed to in_review, failed back to todo —
   * so this pair is sound, and it matches the engine's own duplicate-start check.
   */
  assert.equal(isRunLive(task("a", { runId: "r1", status: "in_progress" })), true);

  // A card dragged to in_progress by hand has no run behind it.
  assert.equal(isRunLive(task("a", { status: "in_progress" })), false);
  // A finished run: the id remains so the card can still link to it.
  assert.equal(isRunLive(task("a", { runId: "r1", status: "in_review" })), false);
  assert.equal(isRunLive(task("a", { runId: "r1", status: "todo" })), false);
  assert.equal(isRunLive(task("a", { runId: "r1", status: "done" })), false);
});

test("polling is armed only when something is actually running", () => {
  // An idle board polling forever would be a request every 6s watching a value
  // that only changes when the user themselves changes it.
  assert.equal(hasLiveRun(null), false);
  assert.equal(hasLiveRun([]), false);
  assert.equal(hasLiveRun([task("a"), task("b", { status: "done" })]), false);
  assert.equal(
    hasLiveRun([task("a"), task("b", { runId: "r1", status: "in_progress" })]),
    true,
    "one live card is enough",
  );
});
