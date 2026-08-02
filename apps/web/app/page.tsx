"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError } from "../lib/api.ts";
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

/** While a run is live the view changes without the user touching anything. */
const POLL_FAST_MS = 4_000;
/** Otherwise only another window can change it. */
const POLL_IDLE_MS = 15_000;

export default function Page() {
  const [view, setView] = useState<ViewKey>("today");
  const [groups, setGroups] = useState<TaskGroups | null>(null);
  const [lists, setLists] = useState<TodoList[]>([]);
  const [counts, setCounts] = useState<ViewCounts>({ today: 0, needs: 0, done: 0 });
  const [loading, setLoading] = useState(true);
  const [toast, setToast] = useState<string | null>(null);
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
  }, []);

  /*
   * Polling, paused while the tab is hidden.
   *
   * Keyed on the cadence so a run starting or finishing re-arms the timer at the
   * other interval, and on `refresh` so it always fetches the visible view. The
   * `visibilitychange` listener also forces an immediate poll on return, which is
   * exactly when the data is most likely to be stale.
   */
  const fast = hasLiveRun(groups);
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;

    const poll = (): void => {
      refresh().catch(() => undefined);
    };
    const start = (): void => {
      if (timer !== null) return;
      timer = setInterval(poll, fast ? POLL_FAST_MS : POLL_IDLE_MS);
    };
    const stop = (): void => {
      if (timer === null) return;
      clearInterval(timer);
      timer = null;
    };
    const onVisibility = (): void => {
      if (document.hidden) stop();
      else {
        poll();
        start();
      }
    };

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [refresh, fast]);

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
    // Leave a view that is about to stop existing before the request lands.
    if (view === `list:${id}`) setView("today");
    void api
      .patchList(id, { archived: true })
      .then(() => refresh())
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
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
        counts={counts}
        view={view}
        onSelect={setView}
        onCreate={createList}
        onRename={renameList}
        onArchive={archiveList}
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
