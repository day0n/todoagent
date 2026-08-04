import assert from "node:assert/strict";
import { test } from "node:test";
import {
  applyBoardPoll,
  applyServerRowToBoard,
  boardHasLiveRun,
  boardTasks,
  findInBoard,
  insertIntoBoard,
  patchInBoard,
  removeFromBoard,
} from "./todo-state.ts";
import type { BoardColumn, BoardResponse, Task, TaskStatus } from "./types.ts";

/**
 * Reconciliation for the day board.
 *
 * The rule every mutator here follows is PATCH IN PLACE, never re-bucket. Which
 * column a task belongs to is the engine's decision — live status beats a deadline,
 * a manual pin beats a deadline, overdue rolls into today, a completion counts only
 * on the day it happened — and a second implementation of that in the client would
 * eventually disagree with the first. The visible symptom would be a card in two
 * columns or in none.
 *
 * So these tests pin two things: that a local change is visible immediately, and
 * that it does NOT move the card. The refetch that follows every mutation does the
 * moving.
 */

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    channelId: "list-1",
    title: `task ${id}`,
    status: "todo",
    note: "",
    myDay: null,
    dueDate: null,
    needsKind: null,
    needsText: null,
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: null,
    runId: null,
    createdAt: "2026-08-04T10:00:00.000Z",
    updatedAt: "2026-08-04T10:00:00.000Z",
    ...over,
  };
}

function col(key: BoardColumn["key"], tasks: Task[], date: string | null = "2026-08-04"): BoardColumn {
  return {
    key,
    date,
    weekday: date === null ? null : 2,
    tasks,
    done: tasks.filter((t) => t.status === "done").length,
    total: tasks.length,
  };
}

function board(cols: BoardColumn[]): BoardResponse {
  return { today: "2026-08-04", columns: cols };
}

/** A board with one task in today and one in tomorrow. */
function twoColumns(): BoardResponse {
  return board([
    col("today", [task("a"), task("b")]),
    col("tomorrow", [task("c", { dueDate: "2026-08-05" })], "2026-08-05"),
  ]);
}

// ── Reading ─────────────────────────────────────────────────

test("findInBoard: locates a task in any column", () => {
  const b = twoColumns();
  assert.equal(findInBoard(b, "a")?.id, "a");
  assert.equal(findInBoard(b, "c")?.id, "c");
  assert.equal(findInBoard(b, "nope"), null);
  assert.equal(findInBoard(null, "a"), null);
});

test("boardTasks: flattens in column then row order", () => {
  assert.deepEqual(
    boardTasks(twoColumns()).map((t) => t.id),
    ["a", "b", "c"],
  );
  assert.deepEqual(boardTasks(null), []);
});

test("boardHasLiveRun: needs BOTH a run id and in_progress", () => {
  /*
   * Drives the polling cadence, so it has to be asked of whichever shape is on
   * screen. A board holding a running task that answered false would poll at the
   * idle rate and take up to a minute to notice the run finished.
   */
  assert.equal(boardHasLiveRun(twoColumns()), false);
  assert.equal(
    boardHasLiveRun(board([col("today", [task("a", { status: "in_progress", runId: "r1" })])])),
    true,
  );
  // A status with no run, or a run id on a settled task, is not live.
  assert.equal(boardHasLiveRun(board([col("today", [task("a", { status: "in_progress" })])])), false);
  assert.equal(
    boardHasLiveRun(board([col("today", [task("a", { status: "in_review", runId: "r1" })])])),
    false,
  );
});

// ── Patching in place ───────────────────────────────────────

test("patchInBoard: the change is visible and the card does NOT move", () => {
  const b = twoColumns();
  const after = patchInBoard(b, "c", { status: "done" });

  // Still in tomorrow, even though a completed task belongs in today by the
  // engine's rules. Re-bucketing here is exactly what would drift.
  assert.equal(after?.columns[1]?.tasks[0]?.status, "done");
  assert.deepEqual(
    after?.columns.map((x) => x.tasks.map((t) => t.id)),
    [["a", "b"], ["c"]],
    "membership is unchanged",
  );
});

test("patchInBoard: counts are recomputed, not carried forward", () => {
  const b = board([col("today", [task("a"), task("b")])]);
  assert.equal(b.columns[0]?.done, 0);

  const after = patchInBoard(b, "a", { status: "done" });
  /*
   * The engine's `done`/`total` describe the membership it sent. After a local patch
   * they are stale, and a progress bar still claiming the old figure while the tick
   * is visibly filled is the kind of inconsistency a poll would hide a second later
   * and nobody would ever diagnose.
   */
  assert.equal(after?.columns[0]?.done, 1);
  assert.equal(after?.columns[0]?.total, 2);
});

test("patchInBoard: an unknown id and a null board are no-ops", () => {
  const b = twoColumns();
  // The same object back, so a React state setter skips the re-render.
  assert.equal(patchInBoard(b, "nope", { status: "done" }), b);
  assert.equal(patchInBoard(null, "a", { status: "done" }), null);
});

test("patchInBoard: does not touch the columns it did not change", () => {
  const b = twoColumns();
  const after = patchInBoard(b, "a", { title: "renamed" });
  // Referential identity on the untouched column: cheap, and it keeps a large
  // board from re-rendering every column for a one-card change.
  assert.equal(after?.columns[1], b.columns[1]);
  assert.notEqual(after?.columns[0], b.columns[0]);
});

// ── Server confirmation ─────────────────────────────────────

test("applyServerRowToBoard: replaces the guess, still in place", () => {
  const b = twoColumns();
  const confirmed = task("a", { status: "in_progress", runId: "r1", updatedAt: "2026-08-04T11:00:00.000Z" });
  const after = applyServerRowToBoard(b, confirmed);

  assert.equal(after?.columns[0]?.tasks[0]?.runId, "r1");
  assert.equal(after?.columns[0]?.tasks[0]?.updatedAt, "2026-08-04T11:00:00.000Z");
  assert.deepEqual(after?.columns.map((x) => x.tasks.length), [2, 1]);
});

test("applyServerRowToBoard: a task the board does not hold is ignored", () => {
  /*
   * Not inserted, deliberately. The engine decides membership, and a row this view
   * does not hold is one it is not showing — a chat-created card while the board
   * shows tomorrow's work, say. Inserting it would put a card in a column no rule
   * chose for it.
   */
  const b = twoColumns();
  assert.equal(applyServerRowToBoard(b, task("elsewhere")), b);
});

// ── Insert and remove ───────────────────────────────────────

test("insertIntoBoard: puts a new task in the column that asked for it", () => {
  const b = twoColumns();
  const fresh = task("d", { dueDate: "2026-08-05" });
  const after = insertIntoBoard(b, "tomorrow", fresh);

  assert.deepEqual(
    after?.columns[1]?.tasks.map((t) => t.id),
    ["c", "d"],
    "appended to the named column",
  );
  assert.equal(after?.columns[1]?.total, 2);
  assert.equal(after?.columns[0], b.columns[0], "other columns untouched");
});

test("insertIntoBoard: a task already present is not added twice", () => {
  // The refetch can beat the optimistic insert. Without this guard the card
  // renders twice until the next poll replaces the whole board.
  const b = twoColumns();
  assert.equal(insertIntoBoard(b, "today", task("a")), b);
});

test("removeFromBoard: drops the task and updates the count", () => {
  const b = board([col("today", [task("a", { status: "done" }), task("b")])]);
  const after = removeFromBoard(b, "a");
  assert.deepEqual(after?.columns[0]?.tasks.map((t) => t.id), ["b"]);
  assert.equal(after?.columns[0]?.total, 1);
  assert.equal(after?.columns[0]?.done, 0, "the completed one left, so the bar empties");
  assert.equal(removeFromBoard(b, "nope"), b);
});

// ── Poll guarding ───────────────────────────────────────────

test("applyBoardPoll: a response older than a local change is discarded", () => {
  /*
   * The interleaving this exists for, and the same contract `applyPoll` holds for
   * the grouped views: a poll that went out BEFORE the user's click describes a
   * board that no longer exists. Landing it would revert the click, and the user
   * has no way to tell that happened.
   */
  const current = patchInBoard(twoColumns(), "a", { status: "done" }) as BoardResponse;
  const stale = twoColumns(); // as the server saw it before the tick

  const kept = applyBoardPoll(current, stale, 1, 2);
  assert.equal(kept, current, "the stale response is dropped whole");
  assert.equal(kept.columns[0]?.tasks[0]?.status, "done", "the local change survives");

  // Counts matched: this response reflects everything local, so it wins.
  const fresh = applyBoardPoll(current, stale, 2, 2);
  assert.notEqual(fresh, current);
  assert.equal(fresh.columns[0]?.tasks[0]?.status, "todo", "the server is authoritative");
});

test("applyBoardPoll: the first load is never discarded", () => {
  // Nothing to protect yet, so a mismatch must not leave the board empty forever.
  const incoming = twoColumns();
  const first = applyBoardPoll(null, incoming, 0, 3);
  assert.equal(first.columns.length, 2);
});

test("applyBoardPoll: counts are normalised from the tasks that arrived", () => {
  // Defensive: the engine computes these, but a client that trusted them blindly
  // would render a wrong bar forever if they ever disagreed with the array.
  const lying: BoardResponse = {
    today: "2026-08-04",
    columns: [{ key: "today", date: "2026-08-04", weekday: 2, tasks: [task("a", { status: "done" })], done: 0, total: 99 }],
  };
  const after = applyBoardPoll(null, lying, 0, 0);
  assert.equal(after.columns[0]?.done, 1);
  assert.equal(after.columns[0]?.total, 1);
});

// ── The whole sequence ──────────────────────────────────────

test("the interleaving: tick, stale poll lands, server confirms", () => {
  /*
   * The sequence that caught a real bug in the grouped views, replayed here.
   * Each step is a real moment in one interaction.
   */
  let b: BoardResponse | null = twoColumns();
  let mutations = 0;

  // A poll goes out.
  const requestedAt = mutations;

  // The user ticks a card off before it comes back.
  mutations += 1;
  b = patchInBoard(b, "b", { status: "done" });
  assert.equal(findInBoard(b, "b")?.status, "done");

  // The poll lands, describing the world before the tick.
  b = applyBoardPoll(b, twoColumns(), requestedAt, mutations);
  assert.equal(findInBoard(b, "b")?.status, "done", "the tick was not reverted");

  // The PATCH answers, and the server's row replaces the guess.
  const confirmed = task("b", { status: "done", updatedAt: "2026-08-04T12:00:00.000Z" });
  b = applyServerRowToBoard(b, confirmed);
  assert.equal(findInBoard(b, "b")?.updatedAt, "2026-08-04T12:00:00.000Z");

  // A later poll, now in step, re-buckets properly — a completed task moves to today.
  const moved = board([
    col("today", [task("a"), task("b", { status: "done" })]),
    col("tomorrow", [task("c", { dueDate: "2026-08-05" })], "2026-08-05"),
  ]);
  mutations += 0;
  b = applyBoardPoll(b, moved, mutations, mutations);
  assert.deepEqual(
    b.columns.map((x) => x.tasks.map((t) => t.id)),
    [["a", "b"], ["c"]],
    "the engine, not the client, did the bucketing",
  );
});

test("every status can be patched without losing the card", () => {
  // A cheap sweep: each status transition must keep exactly one copy on the board.
  for (const status of ["todo", "in_progress", "needs_you", "in_review", "done"] as TaskStatus[]) {
    const after = patchInBoard(twoColumns(), "a", { status });
    assert.equal(boardTasks(after).filter((t) => t.id === "a").length, 1, status);
    assert.equal(findInBoard(after, "a")?.status, status, status);
  }
});
