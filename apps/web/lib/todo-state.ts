import type { Task, TaskGroups, TaskStatus, ViewKey } from "./types.ts";
import { GROUP_ORDER } from "./types.ts";

/**
 * Reconciliation rules for the grouped task views: which write wins when two
 * arrive out of order, and where a task lands when its status changes locally.
 *
 * This is the grouped successor to `board-state.ts`, which held the same rules
 * for a flat `Task[]`. The lesson from that file is kept: the interleaving IS
 * testable as a sequence — start a poll, apply a local change, land the poll,
 * assert the change survived — and that test caught a real bug where a slow
 * response reverted whatever the user had just done.
 *
 * The grouping adds a failure mode a flat array did not have. A local status
 * change has to MOVE a task between arrays, and a version that only rewrote the
 * task in place would leave it rendered under its old heading — ticked off, but
 * still sitting under 待办. So every mutator here removes by id first and then
 * inserts, rather than patching where it found it.
 *
 * Each function returns the SAME object when nothing changed, so a caller using
 * these as React state updaters skips the re-render.
 */

export function emptyGroups(): TaskGroups {
  return { todo: [], in_progress: [], needs_you: [], in_review: [], done: [] };
}

/** Every task across every group, in render order. */
export function allTasks(groups: TaskGroups | null): Task[] {
  if (groups === null) return [];
  return GROUP_ORDER.flatMap((status) => groups[status] ?? []);
}

export function findTask(groups: TaskGroups | null, id: string): Task | null {
  if (groups === null) return null;
  for (const status of GROUP_ORDER) {
    const hit = (groups[status] ?? []).find((t) => t.id === id);
    if (hit !== undefined) return hit;
  }
  return null;
}

/** The groups worth rendering: declared order, empties dropped. */
export function visibleGroups(
  groups: TaskGroups | null,
): Array<{ status: TaskStatus; tasks: Task[] }> {
  if (groups === null) return [];
  const out: Array<{ status: TaskStatus; tasks: Task[] }> = [];
  for (const status of GROUP_ORDER) {
    const tasks = groups[status] ?? [];
    if (tasks.length > 0) out.push({ status, tasks });
  }
  return out;
}

/**
 * A poll response that may predate a local change.
 *
 * `requestedAt` is the mutation count captured before the request went out;
 * `mutationsNow` is the count when it came back. Any difference means the user
 * changed something while this was in flight, so the response describes a view
 * that no longer exists.
 *
 * Discarding it also drops other tasks' updates from the same response. That is
 * the right trade: another poll follows within seconds, whereas silently
 * reverting the tick the user just made is a wrong state they cannot correct.
 */
export function applyPoll(
  current: TaskGroups | null,
  incoming: TaskGroups,
  requestedAt: number,
  mutationsNow: number,
): TaskGroups | null {
  if (requestedAt !== mutationsNow) return current;
  return incoming;
}

/** Drops a task from whichever group holds it. */
export function removeTask(current: TaskGroups | null, id: string): TaskGroups | null {
  if (current === null) return current;
  let touched = false;
  const next = emptyGroups();
  for (const status of GROUP_ORDER) {
    const tasks = current[status] ?? [];
    const kept = tasks.filter((t) => t.id !== id);
    if (kept.length !== tasks.length) touched = true;
    next[status] = kept;
  }
  return touched ? next : current;
}

/**
 * Puts a task into the group its own status names.
 *
 * Appended for every group except `done`, which the engine returns newest-first —
 * so a task ticked off now belongs at the top of that list rather than the
 * bottom of it.
 */
function insertByStatus(groups: TaskGroups, task: Task): void {
  const bucket = groups[task.status] ?? groups.todo;
  if (task.status === "done") bucket.unshift(task);
  else bucket.push(task);
}

/** Adds a newly created task. Used by quick-add before the server answers. */
export function insertTask(current: TaskGroups | null, task: Task): TaskGroups | null {
  if (current === null) return current;
  const next = emptyGroups();
  for (const status of GROUP_ORDER) next[status] = (current[status] ?? []).slice();
  insertByStatus(next, task);
  return next;
}

/**
 * Does this task still belong in the view being displayed?
 *
 * Only the two views defined BY a status can evict a task, and only those are
 * decided here:
 *
 *   needs — holds exactly `needs_you`, so answering or completing one drops it
 *   done  — holds exactly `done`, so un-ticking one drops it
 *
 * `today` and a single list are deliberately never evicted from. The engine's
 * 我的一天 already includes tasks finished today and todos created today, so a
 * status change inside that view keeps membership; and a list is membership by
 * `channelId`, which no status change touches. Re-deriving the engine's
 * `inToday` here would be a second copy of a rule that is allowed to evolve, and
 * the next poll is authoritative regardless.
 */
export function belongsInView(view: ViewKey, task: Task): boolean {
  if (view === "needs") return task.status === "needs_you";
  if (view === "done") return task.status === "done";
  /*
   * A list view evicts a task that left the list.
   *
   * Unlike `today`, this is not a rule that can drift: a list's membership IS
   * `channelId`, by definition, so checking it here duplicates nothing the engine
   * might change later. Without it, moving a task to another list left the row
   * sitting in the list it had just left until the next poll replaced the whole
   * view — the move looked like it had failed.
   */
  if (view.startsWith("list:")) return task.channelId === view.slice("list:".length);
  return true;
}

/**
 * An optimistic local status change.
 *
 * Moves the task to its new group, or out of the view entirely when the change
 * makes it ineligible — ticking off the last 需要你 task should empty that view
 * immediately, not leave it sitting there looking unfinished.
 *
 * `updatedAt` is deliberately not guessed: the server owns it, and inventing a
 * timestamp would show a task as touched at a moment nothing happened.
 */
export function applyOptimistic(
  current: TaskGroups | null,
  view: ViewKey,
  id: string,
  patch: Partial<
    Pick<
      Task,
      | "status"
      | "title"
      | "note"
      | "runId"
      | "needsKind"
      | "needsText"
      | "channelId"
      | "myDay"
      | "dueDate"
    >
  >,
): TaskGroups | null {
  if (current === null) return current;
  const existing = findTask(current, id);
  // Not on screen: filtered out, or already removed by a poll that landed first.
  if (existing === null) return current;

  const updated: Task = { ...existing, ...patch };
  const dropped = removeTask(current, id) ?? current;
  if (!belongsInView(view, updated)) return dropped;

  const next = emptyGroups();
  for (const status of GROUP_ORDER) next[status] = (dropped[status] ?? []).slice();
  insertByStatus(next, updated);
  return next;
}

/**
 * The authoritative row, replacing whatever was guessed for that task.
 *
 * This is the half that was missing from the board and stayed wrong
 * indefinitely: a successful PATCH wrote nothing back, so the optimistic value
 * stood unconfirmed until the next poll — and once polling stopped, an
 * overwritten task never corrected itself.
 *
 * Scoped to one id so it cannot clobber a concurrent change to another task, and
 * it does NOT insert an unknown task: a row for something not on screen means a
 * view filter excludes it, and forcing it back would defeat the filter.
 */
export function applyServerRow(
  current: TaskGroups | null,
  view: ViewKey,
  row: Task,
): TaskGroups | null {
  if (current === null) return current;
  if (findTask(current, row.id) === null) return current;

  const dropped = removeTask(current, row.id) ?? current;
  if (!belongsInView(view, row)) return dropped;

  const next = emptyGroups();
  for (const status of GROUP_ORDER) next[status] = (dropped[status] ?? []).slice();
  insertByStatus(next, row);
  return next;
}

/**
 * Is a run live for this task?
 *
 * The view only knows a task's `runId`, never the run's status. But the engine
 * moves a finished task off `in_progress` — completed to `in_review`, failed to
 * `needs_you`, cancelled to `todo` — so this pair is a sound inference, and it is
 * the same condition the engine's own duplicate-dispatch check applies.
 *
 * Shared by the polling cadence and the dispatch button so the two cannot
 * disagree about whether work is in flight.
 */
export function isRunLive(task: Task): boolean {
  return task.runId !== null && task.status === "in_progress";
}

/** Does anything on screen justify the fast poll? */
export function hasLiveRun(groups: TaskGroups | null): boolean {
  return (groups?.in_progress ?? []).some(isRunLive);
}
