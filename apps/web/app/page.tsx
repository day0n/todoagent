"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError, isPinnedToday, localDayIso, subscribeBoard } from "../lib/api.ts";
import { isBoardView } from "../lib/types.ts";
import type {
  BoardColumn,
  BoardResponse,
  ChatHistory,
  ChatStatus,
  Expert,
  Task,
  TaskGroups,
  TasksResponse,
  TodoList,
  ViewCounts,
  ViewKey,
} from "../lib/types.ts";
import {
  applyBoardPoll,
  applyOptimistic,
  applyPoll,
  applyServerRow,
  applyServerRowToBoard,
  boardHasLiveRun,
  findInBoard,
  findTask,
  hasLiveRun,
  insertIntoBoard,
  insertTask,
  patchInBoard,
  removeFromBoard,
  removeTask,
} from "../lib/todo-state.ts";
import { Sidebar } from "../components/sidebar.tsx";
import { BoardPane } from "../components/board-pane.tsx";
import { TaskPane } from "../components/task-pane.tsx";
import { ChatPane } from "../components/chat-pane.tsx";
import { ResultDrawer } from "../components/result-drawer.tsx";

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
  /*
   * The day board, held separately from the grouped views.
   *
   * Two shapes rather than one because they answer different questions — four day
   * columns versus five status groups — and exactly one is populated at a time. The
   * unused one stays null, and every mutator below no-ops on null, which is what
   * lets one set of handlers serve both renderers.
   */
  const [board, setBoard] = useState<BoardResponse | null>(null);
  const [lists, setLists] = useState<TodoList[]>([]);
  /*
   * Archived lists, fetched separately from the live ones.
   *
   * Read on mount and after an archive or restore — never on the poll, which runs
   * every few seconds and has no use for them.
   */
  const [archived, setArchived] = useState<TodoList[]>([]);
  const [counts, setCounts] = useState<ViewCounts>({ today: 0, needs: 0, running: 0, done: 0 });
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
   * Which task's result drawer is open, by ID rather than by object.
   *
   * Holding the task itself would freeze a copy at the moment it was clicked, and
   * this view refreshes underneath it — on a poll, on an SSE signal, on every
   * mutation. The drawer would then go on showing a status the task no longer has.
   * Looking it up each render also closes the drawer for free when the task leaves
   * the view, which is exactly what should happen if it is no longer a member.
   */
  const [drawerTaskId, setDrawerTaskId] = useState<string | null>(null);
  /*
   * Which task's answer bar is open.
   *
   * Held here rather than in each row because the drawer opens the same bar: a
   * question can be answered from the list or after reading the diff, and two
   * independent pieces of state would let both be open at once with different
   * drafts.
   */
  const [answeringId, setAnsweringId] = useState<string | null>(null);
  /*
   * A load failure that is still true, as distinct from the toast.
   *
   * Without this the pane rendered "今天很干净" whenever the engine was
   * unreachable — stating as fact that there is no work, when in truth nothing
   * could be read. The toast alone was not enough: it dismisses itself after six
   * seconds and leaves the false sentence sitting there.
   */
  const [loadError, setLoadError] = useState<string | null>(null);
  /*
   * Tasks parked in 需要你, for the secretary panel's context card.
   *
   * Fetched separately from the view, because a task waiting on you is waiting
   * whichever view is open — and the board is only loaded for 我的一天. Without this
   * the card would vanish the moment you clicked into a list, which is precisely
   * when a reminder is most useful.
   */
  const [needsTasks, setNeedsTasks] = useState<Task[]>([]);

  // Loaded once: none of these change while the app is open. Runtimes are what
  // the machine has installed; experts are configured on /team.
  const [runtimeNames, setRuntimeNames] = useState<string[]>([]);
  const [runtimeCount, setRuntimeCount] = useState<number | null>(null);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [chat, setChat] = useState<ChatHistory | null>(null);
  const [chatStatus, setChatStatus] = useState<ChatStatus | null>(null);
  const [thinking, setThinking] = useState(false);

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
        /*
         * One shape or the other, never both.
         *
         * 我的一天 reads the board; every other view is status-grouped. Fetching both
         * would double the request rate for data one of the two renderers would
         * throw away.
         */
        const onBoard = isBoardView(view);
        const [data, sidebar] = await Promise.all([
          onBoard ? api.board() : api.tasks(view),
          api.lists(),
        ]);
        // The sidebar is never guarded: its counts are derived server-side from
        // every task, so a fresher copy is always the better one.
        setLists(sidebar.lists);
        setCounts(sidebar.counts);
        if (onBoard) {
          const incoming = data as BoardResponse;
          setBoard((current) =>
            opts.guard === false
              ? incoming
              : applyBoardPoll(current, incoming, requestedAt, mutations.current),
          );
          // Cleared so a stale grouped view cannot flash when switching back.
          setGroups(null);
        } else {
          const incoming = (data as TasksResponse).groups;
          setBoard(null);
          setGroups((current) =>
            opts.guard === false
              ? incoming
              : applyPoll(current, incoming, requestedAt, mutations.current),
          );
        }
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
    setBoard(null);
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

  /** Re-reads the conversation; the SSE `chat:message` signal calls this. */
  const loadChat = useCallback(async (): Promise<void> => {
    setChat(await api.chatHistory());
  }, []);

  /*
   * Four independent requests, deliberately NOT bundled in one `Promise.all`.
   *
   * They were, and the cost was measured: `/api/runtimes` takes 15 seconds because it
   * spawns every installed CLI to read its version, while `/api/chat/status` answers
   * in 39ms. Bundled, the fast three waited for the slow one — so for the first ~15
   * seconds after every load the secretary header showed "未检测到 CLI" with a grey
   * offline dot on a machine with six CLIs installed and the model live.
   *
   * That is not a slow render, it is a false statement with a tooltip on it. Split,
   * each lands when it lands: the panel is correct immediately and the agent count
   * fills in when the probe finishes.
   *
   * Each also gets its own failure handling now, which the shared `.catch` could not
   * do — it reset the chat history whenever the runtime probe failed, for reasons
   * that had nothing to do with the conversation.
   */
  useEffect(() => {
    // Slow: spawns each CLI. Only feeds the agent count and the fallback subtitle.
    void api
      .runtimes()
      .then((rt) => {
        setRuntimeNames(rt.detected.map((d) => d.kind));
        setRuntimeCount(rt.detected.length);
      })
      .catch(() => undefined);

    // Needed by `executorFor` to name who is running a task.
    void api
      .experts()
      .then(setExperts)
      .catch(() => undefined);

    /*
     * The empty fallback matters here specifically: the panel distinguishes "no
     * messages yet" from "still loading" by whether this is null, so a failed fetch
     * has to resolve to an empty history or the stream never renders its prompt.
     */
    void api
      .chatHistory()
      .then(setChat)
      .catch(() => setChat({ messages: [], tasks: {} }));

    // Left null on failure, which the panel reads as "still asking" — better than
    // asserting the secretary is offline because one request did not arrive.
    void api
      .chatStatus()
      .then(setChatStatus)
      .catch(() => undefined);

    // Its own request, and its own failure: an empty archived section is the
    // normal case, so a failure here must not disturb the task list.
    void loadArchived().catch(() => undefined);
  }, [loadArchived]);

  /*
   * Re-reads the parked tasks when how many there are changes.
   *
   * Keyed on `counts.needs` rather than folded into `refresh`: the count arrives with
   * every poll anyway, and fetching the full rows on each tick would be a second
   * request every few seconds to render a card that is usually absent. At zero it
   * skips the request entirely.
   *
   * KNOWN GAP: if the count stays equal while membership changes — one task answered
   * and another parked between two polls — the card shows the old pair until the next
   * time the count moves. Accepted rather than papered over with a poll-rate refetch,
   * because the window is seconds and the failure is a stale title, not a wrong action:
   * every button on the card addresses the task by id.
   */
  useEffect(() => {
    if (counts.needs === 0) {
      setNeedsTasks([]);
      return;
    }
    let alive = true;
    void api
      .tasks("needs")
      .then((res) => {
        if (alive) setNeedsTasks(res.groups.needs_you);
      })
      // A failed fetch leaves the card absent, which is the honest degradation: the
      // sidebar's dot still says something is waiting.
      .catch(() => undefined);
    return () => {
      alive = false;
    };
  }, [counts.needs]);

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
        (ev) => {
          if (ev.type === "chat:message") void loadChat().catch(() => undefined);
          else setThinking(ev.on);
        },
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
    // `loadChat` is a stable useCallback; listing it keeps the linter honest
    // without ever tearing the connection down.
  }, [loadChat]);

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
  /*
   * A live run in EITHER shape speeds the poll up.
   *
   * Asking only about `groups` would leave the board polling at the idle rate with a
   * run in flight — up to a minute to notice it finished, on the one view most
   * likely to be watching.
   */
  const fast = hasLiveRun(groups) || boardHasLiveRun(board);
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

  /**
   * An optimistic local patch, applied to whichever shape is on screen.
   *
   * Both calls are made unconditionally: the shape that is not loaded is null, and
   * every mutator returns its input unchanged for a null or an unknown id, so the
   * other call costs one comparison. Branching on the view here instead would mean
   * ten call sites each having to remember which state they are in.
   */
  const optimistic = (
    id: string,
    patch: Parameters<typeof patchInBoard>[2],
  ): void => {
    setGroups((current) => applyOptimistic(current, view, id, patch));
    setBoard((current) => patchInBoard(current, id, patch));
  };

  /** The server's row, replacing whatever was guessed, in both shapes. */
  const confirmRow = (row: Task): void => {
    setGroups((current) => applyServerRow(current, view, row));
    setBoard((current) => applyServerRowToBoard(current, row));
  };

  const addTask = async (
    title: string,
    dueDate: string | null = null,
    key?: BoardColumn["key"],
  ): Promise<void> => {
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
        ...(dueDate !== null ? { dueDate } : {}),
      });
      setGroups((current) => insertTask(current, created));
      /*
       * Inserted into the column that asked, which is the ONE place membership is
       * decided locally — and safe because nothing is inferred: the per-column add
       * button passed its own date and key, so the caller already knows where it
       * goes. Everything else arrives through the refetch below.
       */
      if (key !== undefined) setBoard((current) => insertIntoBoard(current, key, created));
      void refresh().catch(() => undefined);
    } catch (err) {
      showError(err);
    }
  };

  const toggleDone = (task: Task): void => {
    const next = task.status === "done" ? "todo" : "done";
    mutations.current += 1;
    optimistic(task.id, { status: next });

    void api
      .patchTask(task.id, { status: next })
      .then((row) => {
        confirmRow(row);
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
    optimistic(task.id, { title: next });

    void api
      .patchTask(task.id, { title: next })
      .then((row) => {
        confirmRow(row);
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
        confirmRow(row);
        void refresh().catch(() => undefined);
      })
      .catch(showError);
  };

  const cancel = (task: Task): void => {
    mutations.current += 1;
    void api
      .cancelTask(task.id)
      .then(({ task: row }) => {
        confirmRow(row);
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  /**
   * Sends an answer to a parked question and lets the work continue.
   *
   * Optimistic, unlike `dispatch` — and the difference is worth stating, since both
   * spawn a CLI. Dispatch is a decision a person is making right now, so a refusal
   * ("that repository is busy") has to arrive before the row changes. Answering is
   * the reply to a question the agent already asked: the bar closes, the row moves,
   * and if the engine refuses, the error lands in a toast and `refresh` restores the
   * truth — the answer text is the only thing lost, and it is one sentence the
   * person still has on screen.
   */
  const answerTask = (task: Task, answer: string): void => {
    setAnsweringId(null);
    mutations.current += 1;
    /*
     * The needs fields are cleared alongside the status, matching what the engine
     * writes in its transaction.
     *
     * Patching only `status` would leave a local row that is `in_progress` and still
     * carries `needsKind: "question"` — a combination the engine never produces. It
     * happens to render correctly today because every consumer branches on status
     * first, but a guess should not depend on the order of someone else's if-chain.
     */
    optimistic(task.id, { status: "in_progress", needsKind: null, needsText: null });

    void api
      .answerTask(task.id, answer)
      .then(({ task: row }) => {
        confirmRow(row);
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  /**
   * Moves a task to another list.
   *
   * Optimistic, and the local patch carries `channelId` because that is what the
   * current view's membership is checked against — `belongsInView` evicts the row
   * from a list view the moment it stops belonging, which is what makes the move
   * look like it happened. From 我的一天 the row stays, correctly: it is still
   * today's work, just filed elsewhere.
   */
  const moveTask = (task: Task, listId: string): void => {
    if (listId === task.channelId) return;
    mutations.current += 1;
    optimistic(task.id, { channelId: listId });

    void api
      .patchTask(task.id, { listId })
      .then((row) => {
        confirmRow(row);
        // The sidebar's per-list counts both changed, so re-read them.
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        // The engine refuses an unknown or archived target. Show why and put the
        // row back where it actually is.
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  /**
   * Pins a task into 我的一天, or unpins it.
   *
   * `localDayIso` rather than `toISOString().slice(0,10)`: the engine compares the
   * stored date against the LOCAL day, so a UTC date is the wrong value for most of
   * the world for part of every day.
   */
  const toggleMyDay = (task: Task): void => {
    const next = isPinnedToday(task.myDay) ? null : localDayIso();
    mutations.current += 1;
    optimistic(task.id, { myDay: next });

    void api
      .patchTask(task.id, { myDay: next })
      .then((row) => {
        confirmRow(row);
        // 我的一天's count changes, and if that is the current view its membership
        // does too — unpinning a task there should remove the row.
        void refresh().catch(() => undefined);
      })
      .catch((err: unknown) => {
        showError(err);
        void refresh({ guard: false }).catch(() => undefined);
      });
  };

  /**
   * Sets or clears a task's deadline.
   *
   * `refresh` afterwards is not decoration: the engine puts anything due today or
   * overdue into 我的一天, so setting a date can change which view a task belongs to
   * and every sidebar count with it. The optimistic patch alone would leave 我的一天
   * showing a stale membership until the next poll.
   */
  const setDue = (task: Task, dueDate: string | null): void => {
    if (dueDate === task.dueDate) return;
    mutations.current += 1;
    optimistic(task.id, { dueDate });

    void api
      .patchTask(task.id, { dueDate })
      .then((row) => {
        confirmRow(row);
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
    setBoard((current) => removeFromBoard(current, task.id));
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

  /*
   * Bind (or unbind) the repository that makes a list's tasks dispatchable.
   *
   * Async and re-throwing, unlike the handlers around it: the engine validates the
   * path, and the row's inline editor is where the rejected path is still sitting,
   * so the error belongs there rather than in the global toast.
   */
  const bindRepo = async (id: string, repoPath: string | null): Promise<void> => {
    await api.patchList(id, { repoPath });
    await refresh();
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
        : view === "running"
          ? "进行中"
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

  /*
   * The task the drawer is showing, resolved fresh on every render.
   *
   * This is why the drawer holds an id: the row it came from is replaced wholesale
   * by every poll and every SSE signal, so a captured object would keep rendering a
   * status the task has since left. Resolving from the current groups also closes
   * the drawer on its own if the task leaves the view — deleted, or evicted by a
   * status change the view filters on — rather than leaving a panel open over
   * something that is no longer there.
   */
  const drawerTask =
    drawerTaskId === null
      ? null
      : // Whichever shape is loaded holds it. Resolved fresh each render so the
        // drawer cannot show a status the task has since left.
        (findTask(groups, drawerTaskId) ?? findInBoard(board, drawerTaskId));

  /**
   * Retry after a failed load. Shared by both renderers.
   *
   * Extracted along with the two objects below because the board and the task pane
   * take the same handlers — inline copies in each branch would be two things to
   * keep in step, and the pair that drifted would be the one nobody tested.
   */
  const retryLoad = (): void => {
    setLoading(true);
    refresh({ guard: false })
      .catch((err: unknown) => {
        showError(err);
        setLoadError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setLoading(false));
  };

  const rowOps = { onMove: moveTask, onToggleMyDay: toggleMyDay, onSetDue: setDue };

  /**
   * Answering from the secretary panel.
   *
   * Switches to 我的一天 first, and that is not a convenience: the answer bar lives
   * inside the task's own card, and a parked task always sits in the board's today
   * column (live status outranks its deadline in `boardColumn`). From a list view the
   * card may not be rendered at all, so opening the bar without switching would focus
   * nothing and look broken.
   */
  const answerFromPanel = (task: Task): void => {
    setView("today");
    setDrawerTaskId(null);
    setAnsweringId(task.id);
  };

  const answerControls = {
    activeId: answeringId,
    onStart: (t: Task) => {
      // Opening the bar closes the drawer: they are two views of the same question,
      // and leaving the panel over the card being answered would hide what is being
      // typed.
      setDrawerTaskId(null);
      setAnsweringId(t.id);
    },
    onSubmit: answerTask,
    onCancel: () => setAnsweringId(null),
  };

  return (
    <>
      {/*
        The three-column grid.

        A wrapper rather than making `body` the grid: `body` is also the flex parent
        the retained pages (`/runs`, `/team`) opt into with `.page`, and switching it
        to a grid would reshape those two pages as a side effect of this one.
      */}
      <div className="shell">
      <Sidebar
        lists={lists}
        archived={archived}
        counts={counts}
        view={view}
        onSelect={setView}
        onCreate={createList}
        onRename={renameList}
        onBindRepo={bindRepo}
        onArchive={archiveList}
        onRestore={restoreList}
      />

      {/*
        Two renderers, one set of handlers.

        我的一天 buckets by day; the status and list views group by status. They are
        different shapes rather than different styling, so one component switching on
        a flag internally would carry two layouts and two sets of empty states. The
        mutations are shared, which is what keeps them from drifting.
      */}
      {isBoardView(view) ? (
        <BoardPane
          board={board}
          lists={lists}
          runtimeCount={runtimeCount}
          executorFor={executorFor}
          loading={loading}
          error={loadError}
          onRetry={retryLoad}
          onAdd={addTask}
          onToggleDone={toggleDone}
          onRenameTask={renameTask}
          onOpenResult={(t) => setDrawerTaskId(t.id)}
          onDispatch={dispatch}
          onCancel={cancel}
          onDelete={remove}
          rowOps={rowOps}
          answer={answerControls}
        />
      ) : (
        <TaskPane
          view={view}
          title={title}
          groups={groups}
          lists={lists}
          runtimeCount={runtimeCount}
          executorFor={executorFor}
          loading={loading}
          error={loadError}
          onRetry={retryLoad}
          onAdd={addTask}
          onToggleDone={toggleDone}
          onRenameTask={renameTask}
          onOpenResult={(t) => setDrawerTaskId(t.id)}
          onDispatch={dispatch}
          onCancel={cancel}
          onDelete={remove}
          rowOps={rowOps}
          answer={answerControls}
        />
      )}

      <ChatPane
        history={chat}
        status={chatStatus}
        thinking={thinking}
        runtimeNames={runtimeNames}
        onSend={async (body) => {
          try {
            await api.chatSend(body);
          } catch (err) {
            showError(err);
          } finally {
            // The stream usually beat us to it; this covers a dropped stream and
            // the error path, where the engine records the failure as a message.
            await loadChat().catch(() => undefined);
          }
        }}
        needsTasks={needsTasks}
        onAnswer={answerFromPanel}
        onOpenTask={(t) => setView(`list:${t.channelId}`)}
      />
      </div>

      {/* Outside the grid: both are `position: fixed`, so they answer to the
          viewport rather than to a column, and nesting them in a grid container
          would only invite a stacking-context surprise later. */}
      {drawerTask !== null ? (
        <ResultDrawer
          // Remounts when the task changes, so no state from the previous task's
          // panel (a expanded output section, a half-loaded fetch) survives.
          key={drawerTask.id}
          task={drawerTask}
          onClose={() => setDrawerTaskId(null)}
          onComplete={(t) => {
            toggleDone(t);
            setDrawerTaskId(null);
          }}
          onRedispatch={(t) => {
            dispatch(t);
            setDrawerTaskId(null);
          }}
          /*
           * Answering from the drawer hands off to the inline bar rather than
           * embedding a second textarea. One answer box, reachable from both places:
           * two would each need their own draft, focus handling and Esc behaviour,
           * and could disagree about which question is being answered.
           */
          onAnswer={(t) => {
            setDrawerTaskId(null);
            setAnsweringId(t.id);
          }}
        />
      ) : null}

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
