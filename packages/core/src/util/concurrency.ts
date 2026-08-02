import { cpus } from "node:os";

/**
 * Default ceiling on simultaneous agent processes.
 *
 * Deliberately small. Each unit of work here is a whole coding-CLI process — not
 * a thread and not an HTTP request — routinely holding hundreds of megabytes and
 * spawning its own build tools and language servers. Unbounded fan-out on a
 * six-subtask stage meant six of those at once, each pulling in two reviewers:
 * enough to thrash a laptop and to trip provider rate limits, which surface as
 * adapter failures rather than as the resource problem they are.
 *
 * Multica caps the same thing at 20 for a machine dedicated to the daemon; this
 * runs on the user's own workstation while they use it, so it starts lower.
 */
export function defaultConcurrency(): number {
  const fromEnv = Number.parseInt(process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"] ?? "", 10);
  if (Number.isFinite(fromEnv) && fromEnv > 0) return fromEnv;
  const cores = cpus().length;
  // Leave headroom for the engine, the browser, and whatever the user is doing.
  return Math.max(2, Math.min(6, Math.floor(cores / 2) || 2));
}

/**
 * A counting semaphore, for capping work that is nested rather than flat.
 *
 * `mapLimit` bounds one call site, which is not enough here: the stage loop caps
 * subtasks AND each subtask's review fan-out caps reviewers, so the real peak was
 * the PRODUCT — up to `maxConcurrent` × `REVIEWERS_PER_SUBTASK` live CLI
 * processes. Six subtasks with two reviewers each is twelve full agent processes,
 * each holding hundreds of megabytes and spawning its own build tools.
 *
 * Acquired around a single agent turn, never held while waiting for another slot,
 * so nesting cannot deadlock: a subtask releases its draft slot before its
 * reviewers ask for theirs.
 */
export class Semaphore {
  private readonly limit: number;
  private inFlight = 0;
  private readonly waiting: Array<() => void> = [];

  constructor(limit: number) {
    // Same sanitisation as mapLimit: a non-finite or non-positive limit would
    // otherwise wedge every caller forever instead of just serialising them.
    this.limit = Number.isFinite(limit) ? Math.max(1, Math.floor(limit)) : 1;
  }

  get available(): number {
    return Math.max(0, this.limit - this.inFlight);
  }

  get active(): number {
    return this.inFlight;
  }

  /** Resolves when a slot is free. The caller must release it. */
  async acquire(): Promise<void> {
    if (this.inFlight < this.limit) {
      this.inFlight++;
      return;
    }
    await new Promise<void>((resolve) => this.waiting.push(resolve));
    this.inFlight++;
  }

  release(): void {
    this.inFlight = Math.max(0, this.inFlight - 1);
    const next = this.waiting.shift();
    // The woken waiter increments the counter itself, so releasing does not
    // hand over the slot directly — that keeps `active` honest if a waiter is
    // cancelled between wake-up and resume.
    if (next) next();
  }

  /** Runs `fn` holding one slot, releasing it even if `fn` throws. */
  async run<T>(fn: () => Promise<T>): Promise<T> {
    await this.acquire();
    try {
      return await fn();
    } finally {
      this.release();
    }
  }
}

/**
 * Runs `fn` over `items` with at most `limit` in flight.
 *
 * Returns settled results in INPUT ORDER, matching `Promise.allSettled`, because
 * callers index the results against the original array — a reordered result would
 * mark the wrong subtask as failed, which is the kind of damage that never
 * surfaces as an error.
 *
 * Never rejects: a thrown error becomes a rejected entry, so one bad item cannot
 * abort its siblings mid-edit and leave orphaned worktrees behind.
 */
export async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<Array<PromiseSettledResult<R>>> {
  const results = new Array<PromiseSettledResult<R>>(items.length);
  if (items.length === 0) return results;

  /*
   * Sanitise before clamping.
   *
   * `Math.min(NaN, n)` is NaN and `Math.max(1, NaN)` is still NaN, so a
   * non-finite limit produced `Array.from({length: NaN})` — zero workers, and a
   * results array left full of holes. That is worse than a deadlock: the caller
   * indexes those results and reads `.status` off `undefined`, crashing the whole
   * stage instead of the one item.
   *
   * NaN is reachable from ordinary code — `maxConcurrent` is a public option, and
   * `Number(process.env.X)` on an unset variable is NaN.
   */
  const requested = Number.isFinite(limit) ? Math.floor(limit) : 1;
  const effective = Math.max(1, Math.min(requested, items.length));
  let next = 0;

  const worker = async (): Promise<void> => {
    for (;;) {
      const index = next++;
      if (index >= items.length) return;
      const item = items[index];
      if (item === undefined) {
        // Only reachable for a sparse array; recorded rather than skipped so the
        // result length still matches the input.
        results[index] = { status: "rejected", reason: new Error(`missing item at ${index}`) };
        continue;
      }
      try {
        results[index] = { status: "fulfilled", value: await fn(item, index) };
      } catch (reason) {
        results[index] = { status: "rejected", reason };
      }
    }
  };

  await Promise.all(Array.from({ length: effective }, () => worker()));
  return results;
}
