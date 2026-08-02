"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, subscribeBoard } from "../lib/api.ts";
import type {
  ChatMessage,
  Expert,
  Task,
  TaskGroups,
  TodoList,
  ViewCounts,
  ViewKey,
} from "../lib/types.ts";
import {
  applyOptimistic,
  applyPoll,
  applyServerRow,
  hasLiveRun,
  insertTask,
  removeTask,
} from "../lib/todo-state.ts";
import { Sidebar } from "../components/sidebar.tsx";
import { TaskPane } from "../components/task-pane.tsx";
import { ChatPane } from "../components/chat-pane.tsx";

/**
 * The whole product surface: sidebar, task list, agent conversation.
 *
 * This page owns all server state and every mutation; the three panes are
 * rendering. That is deliberate — a task's status is read by the sidebar counts,
 * the group it renders in, and the polling cadence at once, so exactly one place
 * gets to decide what it currently is.
 *
 * Refresh is polling, not SSE. The engine has an event bus and M3 moves to it;
 * until then a 4-second tick while something is running is honest and cheap, and
 * the reconciliation rules in `todo-state.ts` are what keep a slow response from
 * reverting a click.
 */

/*
 * Polling cadences, in descending order of desperation.
 *
 * With the invalidation stream connected, a change announces itself within
 * milliseconds, so the timer is only a backstop against a signal being missed —
 * a minute is frequent enough for that and cheap enough to ignore. The other two
 * are what M2 used and are still exactly right when the stream is down: a live run
 * changes state on its own schedule, and an idle board only changes when another
 * window touches it.
 */
const POLL_BACKSTOP_MS = 60_000;
/** No stream, and a run is live: state changes without the user touching anything. */
const POLL_FAST_MS = 4_000;
/** No stream, nothing running. */
const POLL_IDLE_MS = 15_000;

export default function Page() {
  const [view, setView] = useState<ViewKey>("today");
  const [groups, setGroups] = useState<TaskGroups | null>(null);
  const [lists, setLists] = useState<TodoList[]>([]);
  /*
   * Archived lists, fetched separately from the live ones.
   *
   * Read on mount and after an archive or restore — never on the poll, which runs
   * every few seconds and has no use for them.
   */
  const [archived, setArchived] = useState<TodoList[]>([]);
  const [counts, setCounts] = useState<ViewCounts>({ today: 0, needs: 0, done: 0 });
  const [loading, setLoading] = useState(true);
  const [toast, setToast] = useState<string | null>(null);
  /*
   * Is the invalidation stream connected?
   *
   * Drives the polling cadence and nothing visible. Starts false so a page that
   * cannot reach the stream at all still polls at the M2 rate from the first
   * moment, rather than waiting a minute to discover it is not connected.
   */
  const [streamOk, setStreamOk] = useState(false);
  /*
   * A load failure that is still true, as distinct from the toast.
   *
   * Without this the pane rendered "今天很干净" whenever the engine was
   * unreachable — stating as fact that there is no work, when in truth nothing
   * could be read. The toast alone was not enough: it dismisses itself after six
   * seconds and leaves the false sentence sitting there.
   */
  const [loadError, setLoadError] = useState<string | null>(null);

  // Loaded once: none of these change while the app is open. Runtimes are what
  // the machine has installed; experts are configured on /team.
  const [runtimeNames, setRuntimeNames] = useState<string[]>([]);
  const [runtimeCount, setRuntimeCount] = useState<number | null>(null);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [chat, setChat] = useState<ChatMessage[] | null>(null);

  /*
   * Counts local changes, so a poll that went out before one can be recognised as
   * describing a view that no longer exists. A ref rather than state: bumping it
   * must not itself trigger a render, and the polling closure has to read the
   * value at the moment the response lands rather than at the moment it subscribed.
   */
  const mutations = useRef(0);

  const showError = useCallback((err: unknown): void => {
    setToast(err instanceof ApiError || err instanceof Error ? err.message : String(err));
  }, []);

  /**
   * Re-reads the archived lists.
   *
   * Separate from `refresh` on purpose: this only changes when a list is archived
   * or restored, and folding it into the poll would fetch a second list every few
   * seconds to render a section that is usually collapsed and usually empty.
   */
  const loadArchived = useCallback(async (): Promise<void> => {
    const res = await api.lists({ archived: true });
    setArchived(res.lists);
  }, []);

  /** Re-reads the current view and the sidebar together. */
  const refresh = useCallback(
    async (opts: { guard?: boolean } = {}): Promise<void> => {
      const requestedAt = mutations.current;
      try {
        const [tasks, sidebar] = await Promise.all([api.tasks(view), api.lists()]);
        // The sidebar is never guarded: its counts are derived server-side from
        // every task, so a fresher copy is always the better one.
        setLists(sidebar.lists);
        setCounts(sidebar.counts);
        setGroups((current) =>
          opts.guard === false
            ? tasks.groups
            : applyPoll(current, tasks.groups, requestedAt, mutations.current),
        );
        // Anything on screen now came from the engine, so a previous failure is
        // no longer describing reality.
        setLoadError(null);
      } catch (err) {
        if (err instanceof ApiError && err.status === 404) {
          // The list behind `view` is gone — archived in another window. Fall
          // back rather than showing an empty pane titled after nothing.
          setView("today");
          return;
        }
        throw err;
      }
    },
    [view],
  );

  /*
   * The current `refresh`, reachable without depending on it.
   *
   * `refresh` is rebuilt whenever `view` changes, and the EventSource subscription
   * below must NOT be torn down for that: this channel has no replay, so a signal
   * arriving during the gap between closing one connection and opening the next is
   * gone for good — and the gap includes a fresh HTTP handshake. Reading the
   * function through a ref keeps one connection open for the page's whole life
   * while still calling the newest closure.
   */
  const refreshRef = useRef(refresh);
  useEffect(() => {
    refreshRef.current = refresh;
  }, [refresh]);

  // First paint, and again whenever the view changes. Unguarded: a view switch is
  // itself the user's request for that view's contents.
  useEffect(() => {
    let alive = true;
    setLoading(true);
    setGroups(null);
    refresh({ guard: false })
      .catch((err: unknown) => {
        if (!alive) return;
        showError(err);
        // Recorded as well as toasted: the toast is transient, and an empty pane
        // must not go on claiming there is no work when nothing could be read.
        setLoadError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [refresh, showError]);

  useEffect(() => {
    void Promise.all([api.runtimes(), api.experts(), api.chatHistory()])
      .then(([rt, ex, history]) => {
        setRuntimeNames(rt.detected.map((d) => d.kind));
        setRuntimeCount(rt.detected.length);
        setExperts(ex);
        setChat(history);
      })
      // A missing runtime list degrades the subtitle and the chat header; it is
      // not worth a toast over, and the task list works regardless.
      .catch(() => setChat([]));

    // Its own request, and its own failure: an empty archived section is the
    // normal case, so a failure here must not disturb the task list.
    void loadArchived().catch(() => undefined);
  }, [loadArchived]);

  /*
   * The invalidation stream: "something changed, re-read it".
   *
   * Mounted once for the page's lifetime — note the empty dependency list, which
   * only works because `refreshRef` above decouples this from `view`. It carries no
   * data by design, so the handler goes through the same guarded `refresh()` a poll
   * uses and every reconciliation rule applies unchanged.
   *
   * Closed while the tab is hidden rather than left open: a background tab holding
   * an idle connection keeps the engine writing heartbeats to a reader nobody is
   * looking at. Coming back reopens it AND refreshes immediately, because anything
   * announced while disconnected was missed for good — this channel has no replay.
   */
  useEffect(() => {
    let unsubscribe: (() => void) | null = null;

    const open = (): void => {
      if (unsubscribe !== null) return;
      unsubscribe = subscribeBoard(
        () => {
          refreshRef.current().catch(() => undefined);
        },
        (ok) => setStreamOk(ok),
      );
    };
    const close = (): void => {
      if (unsubscribe === null) return;
      unsubscribe();
      unsubscribe = null;
      // Not connected any more, so the timer below must go back to a real cadence.
      setStreamOk(false);
    };
    const onVisibility = (): void => {
      if (document.hidden) close();
      else {
        open();
        refreshRef.current().catch(() => undefined);
      }
    };

    if (!document.hidden) open();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      close();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  /*
   * Polling, now a backstop rather than the mechanism.
   *
   * Keyed on the cadence so a run starting or finishing — or the stream dropping —
   * re-arms the timer at the right interval, and on `refresh` so it always fetches
   * the visible view. The `visibilitychange` listener also forces an immediate poll
   * on return, which is exactly when the data is most likely to be stale.
   *
   * When the stream is up this fires once a minute purely to catch a missed signal.
   * When it is down, the M2 cadences take over and the app degrades to exactly what
   * it was before — which is the reason the stream carries no data: losing it costs
   * latency, never correctness.
   */
  const fast = hasLiveRun(groups);
  const cadence = streamOk ? POLL_BACKSTOP_MS : fast ? POLL_FAST_MS : POLL_IDLE_MS;
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;

    const poll = (): void => {
      refresh().catch(() => undefined);
    };
    const start = (): void => {
      if (timer !== null) return;
      timer = setInterval(poll, cadence);
    };
    const stop = (): void => {
      if (timer === null) return;
      clearInterval(timer);
      timer = null;
    };
    /*
     * Only the TIMER is managed here, not a catch-up fetch.
     *
     * The stream effect above already refreshes on return — it has to, because a
     * signal announced while its connection was closed is gone for good. Doing it
     * here as well fired two identical requests on every tab focus, which is what
     * the M2 version did before there was another listener to coordinate with.
     */
    const onVisibility = (): void => {
      if (document.hidden) stop();
      else start();
    };

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
    // `cadence`, not `fast`: it already folds in both the stream's health and
    // whether a run is live, and depending on `fast` as well would leave the timer
    // running at a stale interval whenever only the stream state changed.
  }, [refresh, cadence]);

  // Toasts dismiss themselves; an engine refusal is worth reading once, not
  // worth a click to clear.
  useEffect(() => {
    if (toast === null) return;
    const t = setTimeout(() => setToast(null), 6_000);
    return () => clearTimeout(t);
  }, [toast]);

  // ── Mutations ───────────────────────────────────────────────

  const addTask = async (title: string): Promise<void> => {
    mutations.current += 1;
    try {
      /*
       * The server's row is inserted, not a placeholder.
       *
       * A truly optimistic insert needs a fake id, and every action on that row
       * (tick, dispatch, delete) would address a task the engine has never heard
       * of until the id is swapped. Against a loopback engine the round trip is a
       * couple of milliseconds, so the honest version is also the fast one.
       */
      const created = await api.createTask({
        title,
        listId: view.startsWith("list:") ? view.slice("list:".length) : null,
      });
      setGroups((current) => insertTask(current, created));
      void refresh().catch(() => undefined);
    } catch (err) {
      showError(err);
    }
  };

  const toggleDone = (task: Task): void => {
    const next = task.status === "done" ? "todo" : "done";
    mutations.current += 1;
    setGroups((current) => applyOptimistic(current, view, task.id, { status: next }));

    void api
      .patchTask(task.id, { status: next })
      .then((row) => {
        setGroups((current) => applyServerRow(current, view, row));
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        showError(err);
        // The guess was wrong; the server is authoritative.
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  const renameTask = (task: Task, title: string): void => {
    const next = title.trim();
    // Nothing to do, and an empty title would leave a row with no label at all.
    if (next === "" || next === task.title) return;

    mutations.current += 1;
    setGroups((current) => applyOptimistic(current, view, task.id, { title: next }));

    void api
      .patchTask(task.id, { title: next })
      .then((row) => {
        setGroups((current) => applyServerRow(current, view, row));
      })
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  /**
   * Dispatch is never optimistic: it spawns a real CLI process and spends real
   * tokens, and the engine refuses it for reasons only it knows — the repository
   * is locked by another run, no agent is installed, this task is already running.
   * Those refusals are the whole reason the button waits for an answer.
   */
  const dispatch = (task: Task): void => {
    mutations.current += 1;
    void api
      .runTask(task.id)
      .then(({ task: row }) => {
        setGroups((current) => applyServerRow(current, view, row));
        void refresh().catch(() => undefined);
      })
      .catch(showError);
  };

  const cancel = (task: Task): void => {
    mutations.current += 1;
    void api
      .cancelTask(task.id)
      .then(({ task: row }) => {
        setGroups((current) => applyServerRow(current, view, row));
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  const remove = (task: Task): void => {
    mutations.current += 1;
    setGroups((current) => removeTask(current, task.id));
    void api
      .deleteTask(task.id)
      .then(() => refresh())
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  const createList = async (input: {
    name: string;
    color: string | null;
    repoPath: string | null;
  }): Promise<void> => {
    // Not caught: the inline form shows the engine's message next to the path
    // field that caused it, which is more useful than a toast across the screen.
    const created = await api.createList(input);
    await refresh({ guard: false }).catch(() => undefined);
    setView(`list:${created.id}`);
  };

  const renameList = (id: string, name: string): void => {
    setLists((current) => current.map((l) => (l.id === id ? { ...l, name } : l)));
    void api
      .patchList(id, { name })
      .then(() => refresh())
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  const archiveList = (id: string): void => {
    setLists((current) => current.filter((l) => l.id !== id));
    // Leave a view that is about to stop existing before the request lands. The
    // engine now 404s an archived list's view, so staying would bounce anyway —
    // this just avoids the flash.
    if (view === `list:${id}`) setView("today");
    void api
      .patchList(id, { archived: true })
      .then(() => Promise.all([refresh(), loadArchived()]))
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  const restoreList = (id: string): void => {
    // Optimistic in both directions: out of the archived section, and back into
    // the live list where `refresh` will confirm its position and count.
    const restored = archived.find((l) => l.id === id);
    setArchived((current) => current.filter((l) => l.id !== id));
    if (restored !== undefined) {
      setLists((current) =>
        current.some((l) => l.id === id)
          ? current
          : [...current, { ...restored, archivedAt: null }],
      );
    }
    void api
      .patchList(id, { archived: false })
      .then(() => Promise.all([refresh(), loadArchived()]))
      .catch((err: unknown) => {
        showError(err);
        void Promise.all([refresh({ guard: false }), loadArchived()]).catch(() => undefined);
      });
  };

  // ── Derived ─────────────────────────────────────────────────

  const activeList = view.startsWith("list:")
    ? (lists.find((l) => l.id === view.slice("list:".length)) ?? null)
    : null;

  const title =
    view === "today"
      ? "我的一天"
      : view === "needs"
        ? "需要你"
        : view === "done"
          ? "已完成"
          : (activeList?.name ?? "清单");

  /** Who is executing a task, by name. Null when nothing can be resolved. */
  const executorFor = (task: Task): string | null => {
    if (task.assigneeKind !== "expert" || task.assigneeId === null) return null;
    const expert = experts.find((e) => e.id === task.assigneeId);
    if (expert === undefined) return null;
    // The runtime kind is the recognisable half — a person knows "codex", not the
    // expert name they typed on /team six weeks ago.
    return expert.runtimeKind;
  };

  return (
    <>
      <Sidebar
        lists={lists}
        archived={archived}
        counts={counts}
        view={view}
        onSelect={setView}
        onCreate={createList}
        onRename={renameList}
        onArchive={archiveList}
        onRestore={restoreList}
      />

      <TaskPane
        view={view}
        title={title}
        groups={groups}
        lists={lists}
        runtimeCount={runtimeCount}
        executorFor={executorFor}
        loading={loading}
        error={loadError}
        onRetry={() => {
          setLoading(true);
          refresh({ guard: false })
            .catch((err: unknown) => {
              showError(err);
              setLoadError(err instanceof Error ? err.message : String(err));
            })
            .finally(() => setLoading(false));
        }}
        onAdd={addTask}
        onToggleDone={toggleDone}
        onRenameTask={renameTask}
        onDispatch={dispatch}
        onCancel={cancel}
        onDelete={remove}
      />

      <ChatPane messages={chat} runtimeNames={runtimeNames} />

      {toast !== null ? (
        <div className="toast" role="alert">
          <span>{toast}</span>
          <button type="button" className="x" aria-label="关闭" onClick={() => setToast(null)}>
            ×
          </button>
        </div>
      ) : null}
    </>
  );
}
