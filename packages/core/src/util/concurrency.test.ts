import assert from "node:assert/strict";
import { test } from "node:test";
import { Semaphore, defaultConcurrency, mapLimit } from "./concurrency.ts";

/**
 * Tests for the concurrency bound.
 *
 * The bound is the whole point of the module, and a comment claiming "at most N
 * in flight" proves nothing — so these tests measure the actual peak rather than
 * trusting the implementation. Getting this wrong is expensive in a specific way:
 * each unit of work is a whole coding-CLI process holding hundreds of megabytes,
 * so an off-by-one here is a thrashed machine and tripped rate limits, not a
 * slightly slower loop.
 */

/** Tracks how many callbacks were simultaneously in flight. */
function tracker() {
  let inFlight = 0;
  let peak = 0;
  return {
    get peak() {
      return peak;
    },
    async run<T>(fn: () => Promise<T>): Promise<T> {
      inFlight++;
      peak = Math.max(peak, inFlight);
      try {
        return await fn();
      } finally {
        inFlight--;
      }
    },
  };
}

const tick = (ms = 5): Promise<void> => new Promise((r) => setTimeout(r, ms));

test("mapLimit: never exceeds the limit", async () => {
  const t = tracker();
  const items = Array.from({ length: 30 }, (_, i) => i);
  const results = await mapLimit(items, 4, (i) => t.run(async () => {
    await tick(10);
    return i * 2;
  }));

  assert.equal(t.peak, 4, `peak concurrency was ${t.peak}, expected exactly 4`);
  assert.equal(results.length, 30);
  assert.ok(results.every((r) => r.status === "fulfilled"));
});

test("mapLimit: results stay in INPUT order regardless of completion order", async () => {
  // Deliberately inverted durations: the last item finishes first.
  const items = [50, 40, 30, 20, 10];
  const results = await mapLimit(items, 5, async (ms) => {
    await tick(ms);
    return ms;
  });

  /*
   * Load-bearing. The stage loop indexes results against the original subtask
   * array, so a reordered result would mark the WRONG subtask as failed — damage
   * that never surfaces as an error, it just silently blames the wrong work.
   */
  assert.deepEqual(
    results.map((r) => (r.status === "fulfilled" ? r.value : null)),
    [50, 40, 30, 20, 10],
  );
});

test("mapLimit: a rejection does not abort its siblings", async () => {
  const completed: number[] = [];
  const results = await mapLimit([0, 1, 2, 3, 4], 2, async (i) => {
    await tick(5);
    if (i === 2) throw new Error(`item ${i} failed`);
    completed.push(i);
    return i;
  });

  // One failed subtask must not kill the others mid-edit and leave orphaned
  // worktrees behind.
  assert.equal(results.length, 5);
  assert.equal(results[2]?.status, "rejected");
  assert.deepEqual(completed.sort((a, b) => a - b), [0, 1, 3, 4]);
  const reason = results[2]?.status === "rejected" ? results[2].reason : null;
  assert.match(String(reason), /item 2 failed/);
});

test("mapLimit: never rejects, even when everything fails", async () => {
  const results = await mapLimit([1, 2, 3], 2, async () => {
    throw new Error("always");
  });
  // A throw from mapLimit itself would take down the whole run rather than one
  // stage, so it has to settle instead.
  assert.equal(results.length, 3);
  assert.ok(results.every((r) => r.status === "rejected"));
});

test("mapLimit: an empty input does no work", async () => {
  let called = 0;
  const results = await mapLimit([], 4, async () => {
    called++;
    return 1;
  });
  assert.deepEqual(results, []);
  assert.equal(called, 0);
});

test("mapLimit: a limit above the item count spawns no extra workers", async () => {
  const t = tracker();
  const results = await mapLimit([1, 2], 100, (i) => t.run(async () => {
    await tick(10);
    return i;
  }));
  // Spawning 100 workers for 2 items would be harmless here but wasteful in the
  // general case; the effective limit is min(limit, items.length).
  assert.equal(t.peak, 2);
  assert.equal(results.length, 2);
});

test("mapLimit: a limit of zero or negative still makes progress", async () => {
  // Clamped to 1 rather than deadlocking on a nonsensical config value.
  for (const limit of [0, -1, Number.NaN]) {
    const t = tracker();
    const results = await mapLimit([1, 2, 3], limit, (i) => t.run(async () => {
      await tick(2);
      return i;
    }));
    assert.equal(results.length, 3, `limit=${limit}`);
    assert.ok(results.every((r) => r.status === "fulfilled"), `limit=${limit}`);
    assert.equal(t.peak, 1, `limit=${limit} must serialise, not deadlock`);
  }
});

test("mapLimit: a limit of 1 runs strictly sequentially", async () => {
  const order: string[] = [];
  await mapLimit([1, 2, 3], 1, async (i) => {
    order.push(`start-${i}`);
    await tick(5);
    order.push(`end-${i}`);
    return i;
  });
  // No interleaving at all.
  assert.deepEqual(order, ["start-1", "end-1", "start-2", "end-2", "start-3", "end-3"]);
});

test("mapLimit: the index argument matches the item position", async () => {
  const seen: Array<[unknown, number]> = [];
  await mapLimit(["a", "b", "c"], 2, async (item, index) => {
    seen.push([item, index]);
    return index;
  });
  seen.sort((x, y) => x[1] - y[1]);
  assert.deepEqual(seen, [
    ["a", 0],
    ["b", 1],
    ["c", 2],
  ]);
});

test("mapLimit: work actually overlaps up to the limit", async () => {
  // Guards against a bug that satisfies the cap by serialising everything: 8
  // items of 20ms at a limit of 4 should take roughly 2 batches, not 8.
  const started = Date.now();
  await mapLimit(Array.from({ length: 8 }, (_, i) => i), 4, async () => {
    await tick(20);
    return 0;
  });
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 120, `took ${elapsed}ms — parallelism appears not to happen`);
});

test("mapLimit: a slow item does not stall the whole pool", async () => {
  const t = tracker();
  const items = [100, 5, 5, 5, 5, 5];
  const started = Date.now();
  await mapLimit(items, 3, (ms) => t.run(async () => {
    await tick(ms);
    return ms;
  }));
  const elapsed = Date.now() - started;
  // The other five finish while the slow one runs; total is bounded by the slow
  // item, not by its sum with the rest.
  assert.ok(elapsed < 200, `took ${elapsed}ms — a slow item blocked the pool`);
});

// ── Semaphore ───────────────────────────────────────────────

test("Semaphore: never exceeds its limit", async () => {
  const sem = new Semaphore(3);
  const t = tracker();
  await Promise.all(
    Array.from({ length: 20 }, () =>
      sem.run(() =>
        t.run(async () => {
          await tick(5);
          return 0;
        }),
      ),
    ),
  );
  assert.equal(t.peak, 3, `peak was ${t.peak}, expected exactly 3`);
  assert.equal(sem.active, 0, "every slot is returned");
});

test("Semaphore: a NESTED acquire does not deadlock", async () => {
  /*
   * The property the whole design depends on.
   *
   * The pipeline nests fan-out: a subtask runs a draft, then that subtask fans out
   * to reviewers. If a slot were held while waiting for another, the outer turn
   * would block forever on a pool it is itself occupying. Slots are therefore
   * acquired around ONE agent turn only and released before the next level asks.
   */
  const sem = new Semaphore(2);
  const order: string[] = [];

  const subtask = async (name: string): Promise<void> => {
    // Draft: holds a slot, then releases it.
    await sem.run(async () => {
      order.push(`${name}-draft`);
      await tick(5);
    });
    // Reviewers: ask for slots only after the draft has let go.
    await Promise.all(
      ["r1", "r2"].map((r) =>
        sem.run(async () => {
          order.push(`${name}-${r}`);
          await tick(5);
        }),
      ),
    );
  };

  // Three subtasks against a pool of two: strictly more work than slots, which is
  // exactly when a hold-while-waiting bug would hang.
  await Promise.all([subtask("a"), subtask("b"), subtask("c")]);

  assert.equal(order.length, 9, "every draft and review ran");
  assert.equal(sem.active, 0);
});

test("Semaphore: the cap holds across nested fan-out", async () => {
  /*
   * The multiplicative peak this replaced.
   *
   * Capping each level separately (mapLimit at the stage loop AND again at the
   * review fan-out) meant the true peak was the PRODUCT: six subtasks with two
   * reviewers each is twelve live CLI processes, every one holding hundreds of
   * megabytes and spawning its own build tools. One semaphore around every spawn
   * makes the number mean what it says.
   */
  const LIMIT = 3;
  const sem = new Semaphore(LIMIT);
  const t = tracker();
  const turn = () =>
    sem.run(() =>
      t.run(async () => {
        await tick(4);
        return 0;
      }),
    );

  await Promise.all(
    Array.from({ length: 6 }, async () => {
      await turn(); // draft
      await Promise.all([turn(), turn()]); // two reviewers
    }),
  );

  assert.ok(t.peak <= LIMIT, `peak was ${t.peak}, must never exceed ${LIMIT}`);
  assert.equal(t.peak, LIMIT, "and the pool is actually used, not accidentally serialised");
});

test("Semaphore: a slot is released even when the task throws", async () => {
  const sem = new Semaphore(1);
  await assert.rejects(() => sem.run(async () => {
    throw new Error("boom");
  }));
  // Leaking on failure would shrink the pool for the rest of the run — a slow
  // strangulation that looks like the agents getting slower, not like a bug.
  assert.equal(sem.active, 0);
  assert.equal(sem.available, 1);

  // And the pool still works afterwards.
  let ran = false;
  await sem.run(async () => {
    ran = true;
  });
  assert.equal(ran, true);
});

test("Semaphore: waiters are served in order", async () => {
  const sem = new Semaphore(1);
  const order: number[] = [];
  const tasks = [1, 2, 3, 4].map((n) =>
    sem.run(async () => {
      order.push(n);
      await tick(2);
    }),
  );
  await Promise.all(tasks);
  // FIFO, so a queued turn cannot be starved by later arrivals.
  assert.deepEqual(order, [1, 2, 3, 4]);
});

test("Semaphore: a non-finite or non-positive limit serialises instead of wedging", async () => {
  /*
   * Same hazard class as mapLimit's NaN bug: `maxConcurrent` is a public option and
   * `Number(process.env.X)` on an unset variable is NaN. Without sanitising, the
   * limit comparison is always false and every caller waits forever — a hang, not
   * an error.
   */
  for (const bad of [0, -5, Number.NaN]) {
    const sem = new Semaphore(bad);
    const t = tracker();
    await Promise.all(
      Array.from({ length: 3 }, () =>
        sem.run(() =>
          t.run(async () => {
            await tick(2);
            return 0;
          }),
        ),
      ),
    );
    assert.equal(t.peak, 1, `limit=${String(bad)} must serialise, not deadlock`);
    assert.equal(sem.active, 0);
  }
});

test("Semaphore: a fractional limit is floored", async () => {
  const sem = new Semaphore(2.9);
  const t = tracker();
  await Promise.all(
    Array.from({ length: 6 }, () =>
      sem.run(() =>
        t.run(async () => {
          await tick(4);
          return 0;
        }),
      ),
    ),
  );
  // Rounding up would exceed a cap the operator set deliberately.
  assert.equal(t.peak, 2);
});

test("Semaphore: accounting stays honest under load", async () => {
  const sem = new Semaphore(2);
  assert.equal(sem.available, 2);
  assert.equal(sem.active, 0);

  await sem.acquire();
  assert.equal(sem.active, 1);
  assert.equal(sem.available, 1);

  await sem.acquire();
  assert.equal(sem.active, 2);
  assert.equal(sem.available, 0, "available must not go negative");

  sem.release();
  sem.release();
  assert.equal(sem.active, 0);

  // An extra release must not create a phantom slot, which would silently raise
  // the cap for the rest of the run.
  sem.release();
  assert.equal(sem.active, 0);
  assert.equal(sem.available, 2);
});

// ── defaultConcurrency ──────────────────────────────────────

test("defaultConcurrency: stays inside a sane range", () => {
  const original = process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"];
  delete process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"];
  try {
    const n = defaultConcurrency();
    // Small on purpose: each unit is a full CLI process on the user's own
    // workstation, competing with their editor and browser.
    assert.ok(n >= 2 && n <= 6, `default was ${n}, outside 2..6`);
    assert.equal(Number.isInteger(n), true);
  } finally {
    if (original !== undefined) process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"] = original;
  }
});

test("defaultConcurrency: an env override wins", () => {
  const original = process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"];
  try {
    process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"] = "12";
    assert.equal(defaultConcurrency(), 12, "an operator with a big machine can raise it");

    // Nonsense values fall back rather than producing 0 or NaN workers.
    for (const bad of ["0", "-3", "abc", ""]) {
      process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"] = bad;
      const n = defaultConcurrency();
      assert.ok(n >= 2 && n <= 6, `${JSON.stringify(bad)} produced ${n}`);
    }
  } finally {
    if (original === undefined) delete process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"];
    else process.env["TODOAGENT_MAX_CONCURRENT_AGENTS"] = original;
  }
});
