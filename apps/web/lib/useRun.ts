"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, subscribeRun } from "./api.ts";
import type { Phase, RunDetail, StreamEvent } from "./types.ts";
import {
  applyEvent,
  emptyRunStreamState,
  needsRefetch,
  type LiveAttempt,
  type LogRow,
  type RunStreamState,
  type VerifyReport,
} from "./run-stream.ts";

/*
 * Re-exported so existing importers keep working.
 *
 * `timeline.tsx` takes a `LiveAttempt`, and the run page takes `LogRow` and
 * `VerifyReport`. They are declared in `run-stream.ts` now, where the logic that
 * produces them lives.
 */
export type { LiveAttempt, LogRow, VerifyReport };

export interface RunState extends RunStreamState {
  detail: RunDetail | null;
  connected: boolean;
  error: string | null;
  reload: () => void;
}

/**
 * Subscribes to one run: snapshot over HTTP, then live events over SSE.
 *
 * The event state machine itself lives in `run-stream.ts` as a pure function. It
 * used to sit inline in the effect below, which made ~150 lines of branching over
 * 49 event types unreachable from a test — the largest uncovered surface in this
 * app, and the reason the retry badge shipped with "NOT verified in a browser" in
 * its commit message. Forcing a real CLI into a transient failure on demand is not
 * feasible; handing `applyEvent` an `attempt:retrying` event is trivial.
 *
 * What stays here is what genuinely needs React: the SSE subscription lifecycle,
 * the debounced refetch, and the three state slices that come from HTTP rather
 * than from events.
 */
export function useRun(runId: string): RunState {
  const [detail, setDetail] = useState<RunDetail | null>(null);
  /*
   * One state slice for everything the event stream produces.
   *
   * Six separate `useState` calls meant a single event could trigger several
   * renders, and every branch had to remember which setters to touch. `applyEvent`
   * returns the same object when nothing changed, so a no-op event costs no render
   * at all.
   */
  const [stream, setStream] = useState<RunStreamState>(emptyRunStreamState);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Refetches are coalesced: a stage of five subtasks emits a burst of structural
  // events, and one refetch covers all of them.
  const refetchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reload = useCallback(() => {
    api
      .run(runId)
      .then((d) => {
        setDetail(d);
        setError(null);
        /*
         * The snapshot is authoritative for the CURRENT phase.
         *
         * The stream only contributes the phases visited while connected, so
         * opening a run mid-flight would otherwise show an empty rail until the
         * next transition.
         */
        setStream((prev) => {
          if (prev.reachedPhases.has(d.run.phase)) return prev;
          const reachedPhases = new Set<Phase>(prev.reachedPhases);
          reachedPhases.add(d.run.phase);
          return { ...prev, reachedPhases };
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
        setStream((prev) => applyEvent(prev, ev));
        // Deliberately outside the updater: a state updater must be pure, and React
        // may invoke it twice in development.
        if (needsRefetch(ev)) scheduleReload();
      },
      setConnected,
    );
    return unsubscribe;
  }, [runId, scheduleReload]);

  return { ...stream, detail, connected, error, reload };
}
