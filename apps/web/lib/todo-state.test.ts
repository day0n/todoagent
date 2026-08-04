import assert from "node:assert/strict";
import { test } from "node:test";
import {
  allTasks,
  applyOptimistic,
  applyPoll,
  applyServerRow,
  belongsInView,
  emptyGroups,
  findTask,
  hasLiveRun,
  insertTask,
  isRunLive,
  removeTask,
  visibleGroups,
} from "./todo-state.ts";
import type { Task, TaskGroups, TaskStatus } from "./types.ts";

/**
 * Tests for the grouped view's reconciliation rules.
 *
 * The interesting cases are all about ORDERING and MOVEMENT, which is where the
 * flat board version of this logic had real bugs:
 *
 *   - a slow poll landing after a local change reverted it
 *   - a successful PATCH wrote nothing back, so a guess stood forever
 *
 * The grouping adds a third: a status change has to move a task to another
 * array. Patching it where it sits leaves a ticked-off task rendered under 待办,
 * which looks like the click did nothing.
 */

function task(id: string, status: TaskStatus, over: Partial<Task> = {}): Task {
  return {
    id,
    channelId: "list-1",
    title: `task ${id}`,
    status,
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
    createdAt: "2026-08-02T10:00:00.000Z",
    updatedAt: "2026-08-02T10:00:00.000Z",
    ...over,
  };
}

function groups(over: Partial<Record<TaskStatus, Task[]>> = {}): TaskGroups {
  return { ...emptyGroups(), ...over };
}

// ── applyPoll ───────────────────────────────────────────────

test("applyPoll: a response that predates a local change is discarded", () => {
  /*
   * The load-bearing case. The user ticked something off while this request was
   * in flight, so the response describes a view that no longer exists. Applying
   * it would un-tick the task in front of them.
   */
  const current = groups({ done: [task("a", "done")] });
  const incoming = groups({ todo: [task("a", "todo")] });

  const out = applyPoll(current, incoming, 0, 1);
  assert.equal(out, current, "stale response must be dropped, identity preserved");
});

test("applyPoll: a response with no intervening change is applied", () => {
  const current = groups({ todo: [task("a", "todo")] });
  const incoming = groups({ in_progress: [task("a", "in_progress")] });

  assert.equal(applyPoll(current, incoming, 3, 3), incoming);
});

test("applyPoll: the very first response is applied", () => {
  const incoming = groups({ todo: [task("a", "todo")] });
  assert.equal(applyPoll(null, incoming, 0, 0), incoming);
});

// ── applyOptimistic ─────────────────────────────────────────

test("applyOptimistic: a status change MOVES the task between groups", () => {
  /*
   * The grouping-specific bug. Rewriting the task in place would leave it in
   * `todo` with `status: "done"` — struck through, but still under 待办.
   */
  const before = groups({ todo: [task("a", "todo"), task("b", "todo")] });

  const after = applyOptimistic(before, "today", "a", { status: "done" });

  assert.deepEqual(
    after?.todo.map((t) => t.id),
    ["b"],
    "the ticked task must leave 待办",
  );
  assert.deepEqual(after?.done.map((t) => t.id), ["a"]);
  assert.equal(after?.done[0]?.status, "done");
});

test("applyOptimistic: does not mutate the previous state", () => {
  // A caller holding the old object (a render in flight) must not see it change.
  const before = groups({ todo: [task("a", "todo")] });
  applyOptimistic(before, "today", "a", { status: "done" });

  assert.deepEqual(before.todo.map((t) => t.id), ["a"]);
  assert.deepEqual(before.done, []);
});

test("applyOptimistic: a completed task goes to the TOP of 已完成", () => {
  // The engine returns that group newest-first, so appending would file a task
  // finished just now below one finished last week.
  const before = groups({
    todo: [task("new", "todo")],
    done: [task("old", "done")],
  });

  const after = applyOptimistic(before, "today", "new", { status: "done" });
  assert.deepEqual(after?.done.map((t) => t.id), ["new", "old"]);
});

test("applyOptimistic: leaving needs_you evicts the task from the 需要你 view", () => {
  /*
   * That view is DEFINED by the status, so a task that is no longer needs_you is
   * no longer a member. Keeping it would show a view whose own heading contradicts
   * its contents.
   */
  const before = groups({ needs_you: [task("a", "needs_you"), task("b", "needs_you")] });

  const after = applyOptimistic(before, "needs", "a", { status: "done" });

  assert.deepEqual(after?.needs_you.map((t) => t.id), ["b"]);
  assert.deepEqual(after?.done, [], "it must not reappear under another heading");
  assert.equal(allTasks(after).length, 1);
});

test("applyOptimistic: un-ticking evicts the task from the 已完成 view", () => {
  const before = groups({ done: [task("a", "done")] });

  const after = applyOptimistic(before, "done", "a", { status: "todo" });

  assert.deepEqual(allTasks(after), [], "the view holds only done tasks");
});

test("applyOptimistic: 我的一天 keeps a task whose status changed", () => {
  /*
   * Deliberately different from the two status-defined views: the engine's
   * 我的一天 already includes tasks finished today, so ticking one off moves it to
   * the 已完成 group and it stays on screen.
   */
  const before = groups({ todo: [task("a", "todo")] });

  const after = applyOptimistic(before, "today", "a", { status: "done" });
  assert.deepEqual(after?.done.map((t) => t.id), ["a"]);
});

test("applyOptimistic: a list view keeps a task whose status changed", () => {
  // Membership there is by list id, which no status change touches.
  const before = groups({ todo: [task("a", "todo", { channelId: "list-7" })] });

  const after = applyOptimistic(before, "list:list-7", "a", { status: "done" });
  assert.deepEqual(after?.done.map((t) => t.id), ["a"]);
});

test("applyOptimistic: an unknown id leaves the state untouched", () => {
  // Reachable: a poll removed the task between render and click.
  const before = groups({ todo: [task("a", "todo")] });
  assert.equal(applyOptimistic(before, "today", "missing", { status: "done" }), before);
});

test("applyOptimistic: a non-status patch keeps the task in its group", () => {
  const before = groups({ todo: [task("a", "todo"), task("b", "todo")] });

  const after = applyOptimistic(before, "today", "b", { title: "renamed" });

  assert.deepEqual(after?.todo.map((t) => t.id), ["a", "b"], "order must be stable");
  assert.equal(after?.todo[1]?.title, "renamed");
});

test("applyOptimistic: null state stays null", () => {
  assert.equal(applyOptimistic(null, "today", "a", { status: "done" }), null);
});

// ── applyServerRow ──────────────────────────────────────────

test("applyServerRow: the authoritative row replaces the guess", () => {
  /*
   * Without this, a successful dispatch left the task showing whatever the UI
   * assumed. Once polling stopped, that guess was permanent.
   */
  const before = groups({ in_progress: [task("a", "in_progress")] });
  const row = task("a", "in_progress", { runId: "run-9", updatedAt: "2026-08-02T11:00:00.000Z" });

  const after = applyServerRow(before, "today", row);

  assert.equal(after?.in_progress[0]?.runId, "run-9");
  assert.equal(after?.in_progress[0]?.updatedAt, "2026-08-02T11:00:00.000Z");
});

test("applyServerRow: a row whose status changed moves group", () => {
  const before = groups({ todo: [task("a", "todo")] });
  const row = task("a", "in_progress", { runId: "run-1" });

  const after = applyServerRow(before, "today", row);

  assert.deepEqual(after?.todo, []);
  assert.deepEqual(after?.in_progress.map((t) => t.id), ["a"]);
});

test("applyServerRow: a task not on screen is NOT inserted", () => {
  /*
   * A row for something absent means a view filter excludes it. Forcing it in
   * would defeat the filter — the 需要你 view would start showing done tasks.
   */
  const before = groups({ todo: [task("a", "todo")] });
  assert.equal(applyServerRow(before, "today", task("z", "todo")), before);
});

test("applyServerRow: a row that no longer belongs to the view is evicted", () => {
  const before = groups({ needs_you: [task("a", "needs_you")] });
  const row = task("a", "in_progress", { runId: "run-2" });

  assert.deepEqual(allTasks(applyServerRow(before, "needs", row)), []);
});

// ── The interleaving ────────────────────────────────────────

test("a local change survives a poll that was already in flight", () => {
  /*
   * The sequence that motivated all of the above, as it actually happens:
   *
   *   1. a poll goes out          (mutation count 0)
   *   2. the user ticks a task    (count becomes 1, applied optimistically)
   *   3. the poll lands, still describing the pre-tick view
   *   4. the PATCH answers with the real row
   *
   * Step 3 must not un-tick it, and step 4 must confirm it.
   */
  let mutations = 0;
  let state: TaskGroups | null = groups({ todo: [task("a", "todo"), task("b", "todo")] });

  const requestedAt = mutations; // 1

  mutations += 1; // 2
  state = applyOptimistic(state, "today", "a", { status: "done" });
  assert.deepEqual(state?.done.map((t) => t.id), ["a"]);

  const stale = groups({ todo: [task("a", "todo"), task("b", "todo")] }); // 3
  state = applyPoll(state, stale, requestedAt, mutations);
  assert.deepEqual(state?.done.map((t) => t.id), ["a"], "the tick must survive the stale poll");
  assert.deepEqual(state?.todo.map((t) => t.id), ["b"]);

  const confirmed = task("a", "done", { updatedAt: "2026-08-02T12:00:00.000Z" }); // 4
  state = applyServerRow(state, "today", confirmed);
  assert.equal(state?.done[0]?.updatedAt, "2026-08-02T12:00:00.000Z");
});

test("a poll that goes out AFTER the change is authoritative", () => {
  // The counterpart: once the mutation is reflected in the request, the response
  // describes the current view and must win — including other tasks' updates.
  let state: TaskGroups | null = groups({ todo: [task("a", "todo")] });
  const mutations = 1;

  state = applyOptimistic(state, "today", "a", { status: "done" });
  const fresh = groups({ done: [task("a", "done")], todo: [task("new", "todo")] });

  state = applyPoll(state, fresh, mutations, mutations);
  assert.equal(state, fresh);
});

// ── Insert / remove / read helpers ──────────────────────────

test("insertTask: a new task appears in the group its status names", () => {
  const before = groups({ todo: [task("a", "todo")] });
  const after = insertTask(before, task("b", "todo"));

  assert.deepEqual(after?.todo.map((t) => t.id), ["a", "b"], "quick-add appends");
  assert.deepEqual(before.todo.map((t) => t.id), ["a"], "previous state untouched");
});

test("removeTask: returns the SAME object when the id was not present", () => {
  // Identity is the re-render signal; a fresh object for a no-op would repaint
  // the whole list on every failed lookup.
  const before = groups({ todo: [task("a", "todo")] });
  assert.equal(removeTask(before, "nope"), before);
});

test("removeTask: drops the task from whichever group holds it", () => {
  const before = groups({ in_review: [task("a", "in_review"), task("b", "in_review")] });
  assert.deepEqual(removeTask(before, "b")?.in_review.map((t) => t.id), ["a"]);
});

test("findTask: locates a task in any group, null when absent", () => {
  const g = groups({ needs_you: [task("n", "needs_you")], done: [task("d", "done")] });
  assert.equal(findTask(g, "d")?.id, "d");
  assert.equal(findTask(g, "n")?.id, "n");
  assert.equal(findTask(g, "x"), null);
  assert.equal(findTask(null, "d"), null);
});

test("visibleGroups: empty groups are dropped, declared order kept", () => {
  /*
   * The order is the product's priority claim, not the state machine's: what
   * needs a person, then what is moving, then what waits on them, then the
   * backlog, then the archive.
   */
  const g = groups({
    todo: [task("t", "todo")],
    needs_you: [task("n", "needs_you")],
    done: [task("d", "done")],
  });

  assert.deepEqual(
    visibleGroups(g).map((x) => x.status),
    ["needs_you", "todo", "done"],
    "in_progress and in_review are empty and must not render a heading",
  );
});

test("visibleGroups: an entirely empty view yields nothing to render", () => {
  assert.deepEqual(visibleGroups(emptyGroups()), []);
  assert.deepEqual(visibleGroups(null), []);
});

test("allTasks: flattens in render order", () => {
  const g = groups({ todo: [task("t", "todo")], needs_you: [task("n", "needs_you")] });
  assert.deepEqual(allTasks(g).map((t) => t.id), ["n", "t"]);
  assert.deepEqual(allTasks(null), []);
});

// ── Liveness ────────────────────────────────────────────────

test("isRunLive: needs BOTH a run id and the in_progress status", () => {
  assert.equal(isRunLive(task("a", "in_progress", { runId: "r1" })), true);
  assert.equal(isRunLive(task("a", "in_progress")), false, "no run id — nothing to track");
  assert.equal(
    isRunLive(task("a", "in_review", { runId: "r1" })),
    false,
    "a finished run keeps its id on the task",
  );
  assert.equal(
    isRunLive(task("a", "needs_you", { runId: "r1", needsKind: "failed" })),
    false,
    "a failed run is over and is waiting on a person",
  );
});

test("hasLiveRun: decides the polling cadence", () => {
  assert.equal(hasLiveRun(null), false, "nothing loaded yet must not poll fast");
  assert.equal(hasLiveRun(emptyGroups()), false);
  assert.equal(hasLiveRun(groups({ in_review: [task("a", "in_review", { runId: "r" })] })), false);
  assert.equal(
    hasLiveRun(groups({ in_progress: [task("a", "in_progress", { runId: "r" })] })),
    true,
  );
});

// ── View membership ─────────────────────────────────────────

test("belongsInView: status evicts from the status views, never from 我的一天", () => {
  assert.equal(belongsInView("needs", task("a", "needs_you")), true);
  assert.equal(belongsInView("needs", task("a", "todo")), false);
  assert.equal(belongsInView("done", task("a", "done")), true);
  assert.equal(belongsInView("done", task("a", "in_review")), false);

  /*
   * `today` keeps its members through any status change, deliberately.
   *
   * Its membership rule lives in the engine (`inToday`) and is allowed to evolve;
   * re-deriving it here would be a second copy that drifts. A list view is the
   * opposite case — see below.
   */
  for (const status of ["todo", "in_progress", "needs_you", "in_review", "done"] as TaskStatus[]) {
    assert.equal(belongsInView("today", task("a", status)), true);
    assert.equal(belongsInView("list:list-1", task("a", status)), true);
  }
});

test("belongsInView: a list view evicts a task that changed lists", () => {
  /*
   * Membership of a list IS `channelId`, by definition, so checking it duplicates
   * no rule the engine could change later.
   *
   * Without this, moving a task to another list left the row sitting in the list it
   * had just left until the next poll replaced the whole view — for up to a minute
   * with the stream connected, which reads as a move that silently failed.
   */
  assert.equal(belongsInView("list:list-1", task("a", "todo")), true);
  assert.equal(
    belongsInView("list:list-1", task("a", "todo", { channelId: "list-2" })),
    false,
    "a task whose channelId moved away is no longer a member",
  );

  // The aggregate views do not care which list a task lives in.
  assert.equal(belongsInView("today", task("a", "todo", { channelId: "list-2" })), true);
  assert.equal(belongsInView("needs", task("a", "needs_you", { channelId: "list-2" })), true);
});

test("applyOptimistic: moving a task out of the visible list removes the row", () => {
  const groups = emptyGroups();
  groups.todo = [task("a", "todo"), task("b", "todo")];

  const after = applyOptimistic(groups, "list:list-1", "a", { channelId: "list-2" });
  assert.deepEqual(
    (after?.todo ?? []).map((t) => t.id),
    ["b"],
    "the moved task leaves the view it was moved out of",
  );

  // Seen from 我的一天, the same move keeps the task on screen — it is still today's
  // work, just filed elsewhere.
  const inToday = applyOptimistic(groups, "today", "a", { channelId: "list-2" });
  assert.equal((inToday?.todo ?? []).length, 2);
});
