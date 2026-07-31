import type { Phase, StreamEvent } from "./types.ts";

/**
 * The pure half of the run stream: event in, new state out.
 *
 * Extracted from `useRun`, where ~150 lines of state machine sat inside a
 * `useEffect` and were therefore untestable — the largest uncovered surface in
 * the web app, and the reason the retry badge shipped with "NOT verified" in its
 * commit message. Forcing a real CLI into a transient failure on demand is not
 * something I can do; feeding this function an `attempt:retrying` event is
 * trivial.
 *
 * `apps/web`'s test script says why this belongs here rather than in a component:
 * "Scoped to lib/ — .tsx components need a DOM renderer, while the pure logic
 * there does not."
 *
 * Only EVENT-DRIVEN state lives here. `detail`, `connected` and `error` come from
 * HTTP and from the SSE connection itself, so they stay in the hook.
 */

/** Live text accumulated for one attempt, keyed by attempt id. */
export interface LiveAttempt {
  attemptId: string;
  expertName: string;
  runtimeKind: string;
  kind: string;
  subTaskId: string | null;
  text: string;
  thinking: string;
  /** Most recent tool call, so the UI can say what it is doing right now. */
  currentTool: string | null;
  toolCount: number;
  status: "running" | "done" | "failed";
  error: string | null;
  /**
   * Set when this failure was transient and another attempt followed.
   *
   * A retry spawns a NEW attempt with a new id, so without this the user sees a
   * failed card and then an unrelated-looking new one — the system reads as
   * flailing when it is in fact recovering. The engine emits `attempt:retrying`
   * against the FAILED attempt's id precisely so this card can say so.
   */
  retrying: { attempt: number; of: number } | null;
}

export interface VerifyReport {
  text: string;
  ok: boolean;
}

/** One row in the event log, with its search text precomputed. */
export interface LogRow {
  id: number;
  type: string;
  payload: unknown;
  createdAt: string;
  /** Lowercased type + payload, built once at insert. */
  search: string;
}

export interface RunStreamState {
  log: LogRow[];
  live: Map<string, LiveAttempt>;
  /** Phases this run has actually visited, maintained incrementally. */
  reachedPhases: Set<Phase>;
  verifyReport: VerifyReport | null;
  mergeConflicts: string[];
  unmergeable: string[];
}

export const MAX_EVENTS = 3000;
/** Live text is displayed, not archived — the DB holds the full transcript. */
export const MAX_LIVE_CHARS = 40_000;
/** Only this much of a payload is searchable; whole payloads can be huge. */
export const MAX_SEARCH_CHARS = 2000;

export function emptyRunStreamState(): RunStreamState {
  return {
    log: [],
    live: new Map(),
    reachedPhases: new Set(),
    verifyReport: null,
    mergeConflicts: [],
    unmergeable: [],
  };
}

function asRecord(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {};
}
function s(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function strList(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => String(x)) : [];
}

/** Appends without slicing when under the cap, to avoid a copy per event. */
function appendCapped(current: string, addition: string): string {
  const joined = current + addition;
  return joined.length > MAX_LIVE_CHARS ? joined.slice(-MAX_LIVE_CHARS) : joined;
}

/**
 * Does this event mean the server's shape changed?
 *
 * Kept separate from `applyEvent` because refetching is a side effect the hook
 * owns and debounces — a stage of five subtasks emits a burst of structural
 * events, and one refetch covers all of them.
 */
export function needsRefetch(ev: StreamEvent): boolean {
  // The firehose never changes structure, and it is by far the highest volume.
  if (ev.attemptId !== null && ev.type.startsWith("agent:")) return false;
  switch (ev.type) {
    // Handled here in full; the server has nothing to add.
    case "phase:entered":
    case "attempt:started":
    case "attempt:retrying":
    case "merge:needs_human":
      return false;
    default:
      // Everything else: let the server state the new shape rather than
      // reimplementing its transitions on the client.
      return true;
  }
}

/**
 * Applies one event.
 *
 * Returns the SAME object when nothing changed, so a caller using this as a React
 * state updater skips the re-render. Every branch copies only the slice it
 * touches, for the same reason.
 *
 * Derived values (phases reached, the verify report, merge conflicts) are
 * maintained INCREMENTALLY rather than recomputed from the log. That is a
 * correctness-of-performance issue, not a micro-optimisation: deriving them with
 * `useMemo` over the event array made each one rescan the whole history on every
 * arriving event, and `agent:text` is a firehose — so the cost was quadratic in
 * event count, exactly when the UI needs to stay responsive.
 */
export function applyEvent(state: RunStreamState, ev: StreamEvent): RunStreamState {
  const p = asRecord(ev.payload);

  // ── The firehose: live text, no structural work ──
  if (ev.attemptId !== null && ev.type.startsWith("agent:")) {
    const cur = state.live.get(ev.attemptId);
    // An event for an attempt we never saw start: nothing to attach it to. Can
    // happen on a mid-run reconnect whose replay begins after `attempt:started`.
    if (!cur) return state;

    const next = { ...cur };
    if (ev.type === "agent:text") {
      next.text = appendCapped(next.text, s(p["content"]));
    } else if (ev.type === "agent:thinking") {
      next.thinking = appendCapped(next.thinking, s(p["content"]));
    } else if (ev.type === "agent:tool_use") {
      next.currentTool = s(p["tool"]) || "tool";
      next.toolCount = next.toolCount + 1;
    } else if (ev.type === "agent:tool_result") {
      next.currentTool = null;
    } else if (ev.type === "agent:error") {
      next.error = s(p["message"]);
    } else {
      // An unrecognised agent:* event is not a structural change either, so it is
      // dropped rather than logged — the log would fill with noise.
      return state;
    }

    const live = new Map(state.live);
    live.set(next.attemptId, next);
    return { ...state, live };
  }

  /*
   * Everything else is structural and goes in the log.
   *
   * Note the guard above requires BOTH a non-null attemptId and an `agent:`
   * prefix, so an `agent:*` event with no attempt id lands here. That is correct:
   * it cannot be attached to a card, and dropping it silently would lose it
   * entirely.
   */
  const row: LogRow = {
    id: ev.id,
    type: ev.type,
    payload: ev.payload,
    createdAt: ev.createdAt,
    // Built once here rather than JSON.stringify-ing every row on every keystroke
    // while filtering.
    search: `${ev.type} ${JSON.stringify(ev.payload ?? "")}`
      .slice(0, MAX_SEARCH_CHARS)
      .toLowerCase(),
  };
  const log = state.log.length >= MAX_EVENTS ? state.log.slice(-MAX_EVENTS + 1) : state.log.slice();
  log.push(row);
  const next: RunStreamState = { ...state, log };

  switch (ev.type) {
    case "phase:entered": {
      const phase = s(p["phase"]) as Phase;
      if (phase.length === 0 || next.reachedPhases.has(phase)) return next;
      const reachedPhases = new Set(next.reachedPhases);
      reachedPhases.add(phase);
      return { ...next, reachedPhases };
    }

    case "attempt:started": {
      if (ev.attemptId === null) return next;
      const live = new Map(next.live);
      live.set(ev.attemptId, {
        attemptId: ev.attemptId,
        expertName: s(p["expertName"]),
        runtimeKind: s(p["runtimeKind"]),
        kind: s(p["kind"]),
        subTaskId: typeof p["subTaskId"] === "string" ? p["subTaskId"] : null,
        text: "",
        thinking: "",
        currentTool: null,
        toolCount: 0,
        status: "running",
        error: null,
        retrying: null,
      });
      return { ...next, live };
    }

    /*
     * A transient failure that is being retried.
     *
     * Emitted against the FAILED attempt's id, so it lands on the card the user is
     * already looking at rather than appearing as a new one. The attempt stays
     * `failed` — it did fail — but the card can say another try follows.
     */
    case "attempt:retrying": {
      if (ev.attemptId === null) return next;
      const cur = next.live.get(ev.attemptId);
      if (!cur) return next;
      const live = new Map(next.live);
      live.set(cur.attemptId, {
        ...cur,
        retrying: {
          attempt: typeof p["attempt"] === "number" ? p["attempt"] : 1,
          of: typeof p["of"] === "number" ? p["of"] : 1,
        },
      });
      return { ...next, live };
    }

    case "attempt:finished": {
      if (ev.attemptId === null) return next;
      const cur = next.live.get(ev.attemptId);
      if (!cur) return next;
      const live = new Map(next.live);
      live.set(cur.attemptId, {
        ...cur,
        status: s(p["status"]) === "completed" ? "done" : "failed",
        // Preserved when the payload carries no error: an `agent:error` may have
        // recorded a better message already.
        error: typeof p["error"] === "string" ? p["error"] : cur.error,
        currentTool: null,
      });
      return { ...next, live };
    }

    case "verify:done":
    case "solo:done": {
      const text = s(p["report"]) || s(p["output"]);
      if (text.length === 0) return next;
      // `ok` defaults to true because `solo:done` carries no such field and is
      // only emitted after a successful turn.
      return { ...next, verifyReport: { text, ok: p["ok"] !== false } };
    }

    case "merge:needs_human":
      return {
        ...next,
        mergeConflicts: strList(p["conflicted"]),
        unmergeable: strList(p["unmergeable"]),
      };

    default:
      return next;
  }
}
