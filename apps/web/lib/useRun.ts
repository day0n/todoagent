"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, subscribeRun } from "./api.ts";
import type { Phase, RunDetail, StreamEvent } from "./types.ts";

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

const MAX_EVENTS = 3000;
/** Live text is displayed, not archived — the DB holds the full transcript. */
const MAX_LIVE_CHARS = 40_000;
/** Only this much of a payload is searchable; whole payloads can be huge. */
const MAX_SEARCH_CHARS = 2000;

export interface RunState {
  detail: RunDetail | null;
  log: LogRow[];
  live: Map<string, LiveAttempt>;
  /** Phases this run has actually visited, maintained incrementally. */
  reachedPhases: Set<Phase>;
  verifyReport: VerifyReport | null;
  mergeConflicts: string[];
  unmergeable: string[];
  connected: boolean;
  error: string | null;
  reload: () => void;
}

function asRecord(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
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
 * Subscribes to one run: snapshot over HTTP, then live events over SSE.
 *
 * Derived values (phases reached, the verify report, merge conflicts) are
 * maintained INCREMENTALLY rather than recomputed from the event array.
 *
 * That is a correctness-of-performance issue, not a micro-optimisation. Deriving
 * them with useMemo over `events` made every one of them rescan the entire
 * history on every arriving event — and `agent:text` is a firehose, so the cost
 * was quadratic in event count. A single subtask already produces a few hundred
 * events and four parallel ones produce thousands, which is exactly when the UI
 * needs to stay responsive. The structural events these values depend on are
 * rare, so tracking them as they arrive is O(1) per event.
 */
export function useRun(runId: string): RunState {
  const [detail, setDetail] = useState<RunDetail | null>(null);
  const [log, setLog] = useState<LogRow[]>([]);
  const [live, setLive] = useState<Map<string, LiveAttempt>>(new Map());
  const [reachedPhases, setReachedPhases] = useState<Set<Phase>>(new Set());
  const [verifyReport, setVerifyReport] = useState<VerifyReport | null>(null);
  const [mergeConflicts, setMergeConflicts] = useState<string[]>([]);
  const [unmergeable, setUnmergeable] = useState<string[]>([]);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Refetches are coalesced: a stage of five subtasks emits a burst of
  // structural events, and one refetch covers all of them.
  const refetchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reload = useCallback(() => {
    api
      .run(runId)
      .then((d) => {
        setDetail(d);
        setError(null);
        // The snapshot is authoritative for the current phase; the stream only
        // adds the ones visited while connected.
        setReachedPhases((prev) => {
          if (prev.has(d.run.phase)) return prev;
          const next = new Set(prev);
          next.add(d.run.phase);
          return next;
        });
      })
      .catch((err: unknown) => setError(err instanceof ApiError ? err.message : String(err)));
  }, [runId]);

  const scheduleReload = useCallback(() => {
    if (refetchTimer.current !== null) return;
    refetchTimer.current = setTimeout(() => {
      refetchTimer.current = null;
      reload();
    }, 350);
  }, [reload]);

  useEffect(() => {
    reload();
    return () => {
      if (refetchTimer.current !== null) clearTimeout(refetchTimer.current);
    };
  }, [reload]);

  useEffect(() => {
    const unsubscribe = subscribeRun(
      runId,
      (ev: StreamEvent) => {
        const p = asRecord(ev.payload);

        // ── The firehose: live text, no structural work ──
        if (ev.attemptId !== null && ev.type.startsWith("agent:")) {
          // Deliberately not added to the log: per-token chatter belongs in the
          // live cards, and the log hides it by default anyway.
          setLive((prev) => {
            const cur = prev.get(ev.attemptId as string);
            if (!cur) return prev;
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
              return prev;
            }
            const map = new Map(prev);
            map.set(next.attemptId, next);
            return map;
          });
          return;
        }

        // ── Everything else is structural and goes in the log ──
        setLog((prev) => {
          const row: LogRow = {
            id: ev.id,
            type: ev.type,
            payload: ev.payload,
            createdAt: ev.createdAt,
            // Built once here rather than JSON.stringify-ing every row on every
            // keystroke while filtering.
            search: `${ev.type} ${JSON.stringify(ev.payload ?? "")}`
              .slice(0, MAX_SEARCH_CHARS)
              .toLowerCase(),
          };
          const next = prev.length >= MAX_EVENTS ? prev.slice(-MAX_EVENTS + 1) : prev.slice();
          next.push(row);
          return next;
        });

        switch (ev.type) {
          case "phase:entered": {
            const phase = s(p["phase"]) as Phase;
            if (phase.length > 0) {
              setReachedPhases((prev) => {
                if (prev.has(phase)) return prev;
                const next = new Set(prev);
                next.add(phase);
                return next;
              });
            }
            return;
          }

          case "attempt:started": {
            if (ev.attemptId === null) return;
            setLive((prev) => {
              const map = new Map(prev);
              map.set(ev.attemptId as string, {
                attemptId: ev.attemptId as string,
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
              });
              return map;
            });
            return;
          }

          case "attempt:finished": {
            if (ev.attemptId !== null) {
              setLive((prev) => {
                const cur = prev.get(ev.attemptId as string);
                if (!cur) return prev;
                const map = new Map(prev);
                map.set(cur.attemptId, {
                  ...cur,
                  status: s(p["status"]) === "completed" ? "done" : "failed",
                  error: typeof p["error"] === "string" ? p["error"] : cur.error,
                  currentTool: null,
                });
                return map;
              });
            }
            scheduleReload();
            return;
          }

          case "verify:done":
          case "solo:done": {
            const text = s(p["report"]) || s(p["output"]);
            if (text.length > 0) setVerifyReport({ text, ok: p["ok"] !== false });
            scheduleReload();
            return;
          }

          case "merge:needs_human": {
            setMergeConflicts(strList(p["conflicted"]));
            setUnmergeable(strList(p["unmergeable"]));
            return;
          }

          default:
            // Any other structural change: let the server state the new shape
            // rather than reimplementing its transitions here.
            scheduleReload();
            return;
        }
      },
      setConnected,
    );
    return unsubscribe;
  }, [runId, scheduleReload]);

  return {
    detail,
    log,
    live,
    reachedPhases,
    verifyReport,
    mergeConflicts,
    unmergeable,
    connected,
    error,
    reload,
  };
}
