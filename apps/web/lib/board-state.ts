import type { Task } from "./types.ts";

/**
 * The board's reconciliation rules: which write wins when two arrive out of order.
 *
 * Extracted after I claimed in a commit message that extraction "does not make it
 * testable either, since the difficulty is the interleaving". That was wrong, and
 * wrong against my own evidence — pulling the run stream's state machine out of
 * `useRun` made exactly this kind of ordering bug testable and caught a real one.
 *
 * The interleaving is precisely what a sequence test can express: start a poll,
 * apply a patch, land the poll, assert the patch survived. That test fails against
 * the pre-fix logic. What it does NOT cover is React's scheduling, which is not
 * where the bug was.
 *
 * Each function returns the SAME array when nothing changed, so a caller using
 * these as state updaters skips the re-render.
 */

/**
 * A poll response that may predate a local change.
 *
 * `requestedAt` is the mutation count captured before the request went out;
 * `mutationsNow` is the count when it came back. Any difference means the user
 * changed something while this was in flight, so the response describes a board
 * that no longer exists.
 *
 * Discarding it also drops other cards' updates from the same response. That is
 * the right trade: polling only runs while a run is live, so another response
 * follows within seconds, whereas silently reverting the drag the user just made
 * is a wrong state they have no way to correct.
 */
export function applyPoll(
  current: Task[] | null,
  incoming: Task[],
  requestedAt: number,
  mutationsNow: number,
): Task[] | null {
  if (requestedAt !== mutationsNow) return current;
  return incoming;
}

/**
 * An optimistic local edit, applied before the server has confirmed it.
 *
 * Only the four fields a board control can change. `updatedAt` is deliberately not
 * guessed: the server owns it, and inventing a timestamp would show a card as
 * touched at a moment nothing happened.
 */
export function applyOptimistic(
  current: Task[] | null,
  id: string,
  patch: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId" | "runId">>,
): Task[] | null {
  if (current === null) return current;
  const index = current.findIndex((t) => t.id === id);
  // A card that is not on the board — filtered out, or already removed by a poll.
  if (index === -1) return current;
  const next = current.slice();
  next[index] = { ...current[index]!, ...patch };
  return next;
}

/**
 * The authoritative row, replacing whatever was guessed for that card.
 *
 * This is the half that was missing entirely. A successful patch wrote nothing, so
 * the optimistic value stood unconfirmed until the next poll — and once a run
 * finished and polling stopped, an overwritten card stayed wrong indefinitely.
 *
 * Scoped to one id so it cannot clobber a concurrent change to another card, and
 * it does NOT insert an unknown card: a row for something no longer on the board
 * means a filter excludes it, and forcing it back would defeat the filter.
 */
export function applyServerRow(current: Task[] | null, row: Task): Task[] | null {
  if (current === null) return current;
  const index = current.findIndex((t) => t.id === row.id);
  if (index === -1) return current;
  const next = current.slice();
  next[index] = row;
  return next;
}

/**
 * Is a run live for this card?
 *
 * The board only knows a card's `runId`, never the run's status. But the engine
 * moves a finished card off `in_progress` — completed to `in_review`, failed back
 * to `todo` — so this pair is a sound inference, and it is the same condition the
 * engine's own duplicate-start check applies.
 *
 * Shared by the polling decision and the run button so the two cannot disagree
 * about whether work is in flight.
 */
export function isRunLive(task: Task): boolean {
  return task.runId !== null && task.status === "in_progress";
}

/** Does anything on the board justify polling? */
export function hasLiveRun(tasks: Task[] | null): boolean {
  return (tasks ?? []).some(isRunLive);
}
