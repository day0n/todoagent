import assert from "node:assert/strict";
import { test } from "node:test";
import { subscribeBoard } from "./api.ts";

/**
 * The invalidation subscription's state machine.
 *
 * Worth pinning because the bug it encodes was invisible everywhere else. The
 * first version called `onHealth(true)` on reconnect and nothing more — so after
 * an engine restart the page sat stale until the 60s backstop poll fired.
 * Measured: 65 seconds to notice a task created 3 seconds after the engine came
 * back, while the EventSource itself was demonstrably OPEN the whole time. The
 * transport was fine; the missing piece was a re-read.
 *
 * That is not a fault a transport test would catch, and not one the engine's SSE
 * suite can see either — the frames were correct, nobody asked for them. It is a
 * sequence, which is exactly what a unit test expresses: open, drop, re-open,
 * assert a refetch happened.
 */

type Handler = ((e: { data: string }) => void) | null;

/**
 * Stand-in for the browser's EventSource.
 *
 * Only the four members `subscribeBoard` touches, plus manual triggers. Faked
 * rather than driven through a real connection because the interesting states —
 * "errored and retrying", "re-opened after an outage" — are precisely the ones a
 * live socket makes hard to produce on demand.
 */
class FakeEventSource {
  static last: FakeEventSource | null = null;

  onmessage: Handler = null;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;
  readonly url: string;

  constructor(url: string) {
    this.url = url;
    FakeEventSource.last = this;
  }

  close(): void {
    this.closed = true;
  }

  // ── Triggers ──
  emitOpen(): void {
    this.onopen?.();
  }
  emitError(): void {
    this.onerror?.();
  }
  emit(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }
  emitRaw(data: string): void {
    this.onmessage?.({ data });
  }
}

/** Installs the fake for one test and restores whatever was there. */
function withFakeEventSource<T>(fn: () => T): T {
  const g = globalThis as { EventSource?: unknown };
  const before = g.EventSource;
  g.EventSource = FakeEventSource;
  try {
    return fn();
  } finally {
    if (before === undefined) delete g.EventSource;
    else g.EventSource = before;
  }
}

interface Harness {
  changes: number;
  health: boolean[];
  source: FakeEventSource;
  stop: () => void;
}

function subscribe(): Harness {
  const state = { changes: 0, health: [] as boolean[] };
  const stop = subscribeBoard(
    () => {
      state.changes += 1;
    },
    (ok) => state.health.push(ok),
  );
  const source = FakeEventSource.last;
  assert.ok(source, "subscribeBoard must have constructed an EventSource");
  return {
    get changes() {
      return state.changes;
    },
    get health() {
      return state.health;
    },
    source,
    stop,
  };
}

test("the FIRST open does not trigger a refetch", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();

    /*
     * The mount effect already fetches, so refetching on the first open would send
     * two identical requests on every page load. Only a RE-open means something may
     * have been missed.
     */
    assert.equal(h.changes, 0, "no refetch on the initial connection");
    assert.deepEqual(h.health, [true], "but the caller is told the stream is up");
    h.stop();
  });
});

test("a board:changed frame triggers a refetch", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    h.source.emit({ type: "board:changed", taskId: "t1" });
    assert.equal(h.changes, 1);

    h.source.emit({ type: "board:changed", taskId: null });
    assert.equal(h.changes, 2, "every announcement is acted on");
    h.stop();
  });
});

test("stream:ready reports health without refetching", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    // The engine's opening frame. Its only job is to start the response body so the
    // browser fires `onopen`; acting on it as a change would refetch on every
    // connect.
    h.source.emit({ type: "stream:ready" });
    assert.equal(h.changes, 0);
    assert.deepEqual(h.health, [true]);
    h.stop();
  });
});

test("a RE-open after an outage DOES trigger a refetch", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    assert.equal(h.changes, 0);

    /*
     * The regression this file exists for.
     *
     * This channel has no replay, so everything announced while the connection was
     * down is gone for good. Without the refetch below, the page stayed stale until
     * the 60-second backstop poll — measured at 65 seconds to notice a change made
     * 3 seconds after the engine returned, with the socket open the entire time.
     */
    h.source.emitError();
    h.source.emitOpen();

    assert.equal(h.changes, 1, "reconnecting re-reads what was missed");
    assert.deepEqual(h.health, [true, false, true], "and the cadence follows the outage");
    h.stop();
  });
});

test("a re-open fires ONCE per outage, not on every following frame", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    h.source.emitError();
    h.source.emitOpen();
    assert.equal(h.changes, 1);

    // `onopen` can fire again, and frames follow it. Neither is a new outage, and
    // treating them as one would refetch repeatedly over a healthy connection.
    h.source.emitOpen();
    h.source.emit({ type: "stream:ready" });
    assert.equal(h.changes, 1, "still one refetch for one outage");

    // A second outage is its own event.
    h.source.emitError();
    h.source.emitOpen();
    assert.equal(h.changes, 2);
    h.stop();
  });
});

test("a frame arriving without onopen still counts as connected", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    /*
     * Belt and braces for a browser that delivers data before firing `onopen`. Left
     * unhandled, the caller would keep polling at the fallback rate over a stream
     * that was plainly working — the frames are the proof.
     */
    h.source.emit({ type: "board:changed", taskId: null });
    assert.deepEqual(h.health, [true]);
    assert.equal(h.changes, 1);
    h.stop();
  });
});

test("an error is reported so the caller can poll faster", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    h.source.emitError();
    // EventSource retries on its own; the caller's job is only to fall back to a
    // real polling cadence while it does.
    assert.deepEqual(h.health, [true, false]);
    h.stop();
  });
});

test("repeated errors do not spam the health callback", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    h.source.emitError();
    h.source.emitError();
    h.source.emitError();
    /*
     * A retrying EventSource can fire `onerror` on every attempt. The guard is on
     * the TRANSITION, so a caller storing this in React state is not re-rendered
     * once per retry for a value that has not changed.
     */
    assert.deepEqual(h.health, [true, false], "one transition, one report");
    h.stop();
  });
});

test("a malformed frame does not kill the stream", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();

    h.source.emitRaw("not json at all");
    h.source.emitRaw("");
    assert.equal(h.changes, 0, "garbage is ignored rather than thrown");

    // And the subscription still works afterwards, which is the actual requirement.
    h.source.emit({ type: "board:changed", taskId: null });
    assert.equal(h.changes, 1);
    h.stop();
  });
});

test("an unknown event type is ignored, not treated as a change", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    h.source.emitOpen();
    // Forward compatibility: the engine may add frame types, and a client that
    // refetched on all of them would turn any new diagnostic into load.
    h.source.emit({ type: "something:else" });
    h.source.emit({ noTypeAtAll: true });
    assert.equal(h.changes, 0);
    h.stop();
  });
});

test("the returned function closes the connection", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    assert.equal(h.source.closed, false);
    h.stop();
    assert.equal(h.source.closed, true, "a leaked stream keeps the engine writing heartbeats");
  });
});

test("it connects to the engine's stream endpoint", () => {
  withFakeEventSource(() => {
    const h = subscribe();
    assert.match(h.source.url, /\/api\/stream$/);
    h.stop();
  });
});
