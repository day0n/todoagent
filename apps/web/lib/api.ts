import type {
  AttemptTranscript,
  ChatHistory,
  ChatMessage,
  ChatStatus,
  DetectedRuntime,
  Expert,
  ListsResponse,
  Project,
  Run,
  RunDetail,
  RunResult,
  SettableTaskStatus,
  StreamEvent,
  Task,
  TasksResponse,
  Team,
  TodoList,
  ViewKey,
} from "./types.ts";

export const ENGINE =
  process.env["NEXT_PUBLIC_ENGINE_URL"] ?? "http://127.0.0.1:8787";

export class ApiError extends Error {
  readonly status: number;

  // Explicit field rather than a constructor parameter property: those are not
  // erasable syntax, so Node's strip-only type stripping rejects the whole file
  // with ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX. Next.js compiles via SWC and accepts
  // them, which is why this stayed hidden until a plain `node --test` imported
  // this module directly.
  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

/**
 * Fetch wrapper that never returns a half-typed value.
 *
 * The engine is a separate local process, so "engine not running" is the single
 * most common failure and deserves a message a person can act on rather than a
 * bare TypeError from fetch.
 */
async function req<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${ENGINE}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
      cache: "no-store",
    });
  } catch {
    throw new ApiError(
      `无法连接引擎 (${ENGINE})。请先在项目根目录运行 pnpm dev。`,
      0,
    );
  }
  if (!res.ok) {
    let detail = `${res.status}`;
    try {
      const body: unknown = await res.json();
      if (body !== null && typeof body === "object" && "error" in body) {
        const e = (body as { error: unknown }).error;
        detail = typeof e === "string" ? e : JSON.stringify(e);
      }
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(detail, res.status);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export const api = {
  health: () => req<{ ok: boolean; db: string; activeRuns: number }>("/api/health"),

  runtimes: () =>
    req<{ detected: DetectedRuntime[]; known: string[]; missing: string[] }>("/api/runtimes"),

  experts: () => req<Expert[]>("/api/experts"),

  createExpert: (body: Omit<Expert, "id">) =>
    req<Expert>("/api/experts", { method: "POST", body: JSON.stringify(body) }),

  teams: () => req<Team[]>("/api/teams"),

  projects: () => req<Project[]>("/api/projects"),

  createProject: (body: { name: string; repoPath: string; teamId: string }) =>
    req<Project>("/api/projects", { method: "POST", body: JSON.stringify(body) }),

  run: (id: string) => req<RunDetail>(`/api/runs/${id}`),

  /**
   * One attempt's full transcript, on demand.
   *
   * Separate from `run` because output dominated that payload (211 KB of 292 KB)
   * for text the overview never renders, and it was refetched on every structural
   * event. Fetched one at a time only when a user asks to read it.
   */
  attempt: (runId: string, attemptId: string) =>
    req<AttemptTranscript>(`/api/runs/${runId}/attempts/${attemptId}`),

  createRun: (body: {
    projectId: string;
    goal: string;
    acceptance?: string | null;
    budgetTokens?: number;
    soloMode?: boolean;
    autoApprovePlan?: boolean;
  }) => req<Run>("/api/runs", { method: "POST", body: JSON.stringify(body) }),

  approvePlan: (id: string) =>
    req<{ ok: true }>(`/api/runs/${id}/approve-plan`, { method: "POST" }),

  resolve: (id: string, adjudicationId: string, decision: string) =>
    req<{ ok: true }>(`/api/runs/${id}/resolve`, {
      method: "POST",
      body: JSON.stringify({ adjudicationId, decision }),
    }),

  cancel: (id: string) => req<{ ok: true }>(`/api/runs/${id}/cancel`, { method: "POST" }),

  // ── Lists ───────────────────────────────────────────────────

  /**
   * Every unarchived list, plus the three aggregate counts.
   *
   * One request rather than two: the counts change on the same writes the lists
   * do, and fetching them separately would let the sidebar show a badge that
   * disagrees with the list beside it.
   */
  /**
   * `archived: true` returns the archived lists INSTEAD of the live ones.
   *
   * Read on mount and after an archive or restore, never on the poll — which is
   * why it is a separate request rather than an extra field on every row.
   */
  lists: (opts: { archived?: boolean } = {}) =>
    req<ListsResponse>(`/api/lists${opts.archived === true ? "?archived=1" : ""}`),

  /**
   * Creates a list, optionally bound to a repository.
   *
   * `repoPath` is validated by the engine — it must be an existing git
   * repository — so a bad path comes back as a 400 with a sentence to show,
   * never as a list that silently cannot execute anything.
   */
  createList: (body: { name: string; color?: string | null; repoPath?: string | null }) =>
    req<TodoList>("/api/lists", { method: "POST", body: JSON.stringify(body) }),

  /** Renames, recolours, or archives a list. Archiving keeps its tasks. */
  patchList: (
    id: string,
    patch: { name?: string; color?: string | null; archived?: boolean },
  ) => req<TodoList>(`/api/lists/${id}`, { method: "PATCH", body: JSON.stringify(patch) }),

  // ── Tasks ───────────────────────────────────────────────────

  /**
   * One view's tasks, pre-grouped by status.
   *
   * Grouped by the engine so `GROUP_ORDER` here decides only the reading order,
   * not the membership — two places deciding which group a task belongs to is
   * how a task ends up rendered twice or not at all.
   */
  tasks: (view: ViewKey) => req<TasksResponse>(`/api/tasks?view=${encodeURIComponent(view)}`),

  /** Quick add. Absent `listId` lands the task in the default 收件箱 list. */
  createTask: (body: { title: string; note?: string; listId?: string | null }) =>
    req<Task>("/api/tasks", { method: "POST", body: JSON.stringify(body) }),

  /**
   * Patches a task.
   *
   * `status` is `SettableTaskStatus`: the engine rejects `needs_you` because that
   * status is a conclusion a runtime reached and always carries a `needsKind`.
   * Typing it out here means the UI cannot even ask.
   */
  patchTask: (
    taskId: string,
    patch: {
      title?: string;
      status?: SettableTaskStatus;
      note?: string;
      myDay?: string | null;
    },
  ) => req<Task>(`/api/tasks/${taskId}`, { method: "PATCH", body: JSON.stringify(patch) }),

  deleteTask: (taskId: string) =>
    req<{ ok: true }>(`/api/tasks/${taskId}`, { method: "DELETE" }),

  /**
   * Dispatches a task to one agent, directly.
   *
   * Never optimistic: this spawns a real CLI process and spends real tokens, and
   * the engine can refuse it (no repository on the list, another run already
   * holding the repository lock, this task already running, no agent installed).
   * The caller has to await the answer and show the refusal.
   */
  runTask: (taskId: string, opts: { budgetTokens?: number } = {}) =>
    req<{ run: Run; task: Task }>(`/api/tasks/${taskId}/run`, {
      method: "POST",
      body: JSON.stringify(opts),
    }),

  /** Aborts a task's live run. The task returns to todo. */
  cancelTask: (taskId: string) =>
    req<{ ok: true; task: Task }>(`/api/tasks/${taskId}/cancel`, { method: "POST" }),

  /**
   * Answers a parked question and continues the work.
   *
   * Accepted only for a `needs_you` task whose `needsKind` is `question` — a
   * failure or an obstacle has no question to answer and takes 重派 instead. Like
   * `runTask` this spawns a real CLI, so the engine can refuse it (repository busy,
   * no agent installed) and the caller has to show that refusal.
   *
   * `resumed` reports whether the runtime continued its own session or the prompt
   * had to carry the context. Nothing renders it today; it is the one signal that
   * distinguishes the two paths when reading a log.
   */
  answerTask: (taskId: string, answer: string) =>
    req<{ run: Run; task: Task; resumed: boolean }>(`/api/tasks/${taskId}/answer`, {
      method: "POST",
      body: JSON.stringify({ answer }),
    }),

  /**
   * What a finished run left behind: the working-tree snapshot and the final output.
   *
   * One request rather than two, because the drawer opens on a click and a second
   * round trip would render a header with an empty body under it. Kept off the run
   * detail endpoint deliberately — a snapshot is capped at 2M characters, and that
   * payload is refetched on every structural event.
   */
  runResult: (runId: string) => req<RunResult>(`/api/runs/${runId}/result`),

  /** The main-agent conversation, plus title resolution for its inline cards. */
  chatHistory: () => req<ChatHistory>("/api/chat/history"),

  /** Whether the main agent can run right now, with the banner text when not. */
  chatStatus: () => req<ChatStatus>("/api/chat/status"),

  /**
   * One chat turn. Resolves when the agent has answered — tool calls included —
   * so the caller should show the thinking state from the stream, not a spinner
   * on this promise alone.
   */
  chatSend: (body: string) =>
    req<{ user: ChatMessage; agent: ChatMessage }>("/api/chat", {
      method: "POST",
      body: JSON.stringify({ body }),
    }),
};

/**
 * Subscribes to a run's event stream.
 *
 * `EventSource` handles reconnection and replays `Last-Event-ID` for us, and the
 * engine persists events before broadcasting them — so a dropped connection
 * catches up from the table rather than losing whatever happened while away.
 */
export function subscribeRun(
  runId: string,
  onEvent: (ev: StreamEvent) => void,
  onError?: (open: boolean) => void,
): () => void {
  const source = new EventSource(`${ENGINE}/api/runs/${runId}/events`);

  /*
   * `onmessage` alone is sufficient, and that is the point.
   *
   * This used to also register an allowlist of ~50 named event types, because
   * EventSource does not route a named event to onmessage. That list silently
   * drifted: any event the engine started emitting without a matching client
   * entry was dropped with no error. The engine now sends every event as a
   * default-type message with its type inside `data`, so nothing can be missed.
   */
  source.onmessage = (e: MessageEvent<string>) => {
    try {
      onEvent(JSON.parse(e.data) as StreamEvent);
    } catch {
      /* a malformed frame must not kill the stream */
    }
  };

  source.onopen = () => onError?.(true);
  source.onerror = () => onError?.(false);

  return () => source.close();
}

/**
 * Subscribes to board invalidation.
 *
 * The engine sends "something changed" and no data, so `onChange` is expected to
 * re-read through the same path a poll uses. That is the point: one code path
 * turns server state into UI state regardless of what triggered it, so there is no
 * second path to disagree with the first.
 *
 * `onHealth` drives the polling cadence rather than any UI. EventSource reconnects
 * on its own with its own backoff, so a dropped connection needs no handling here
 * beyond telling the caller to poll faster until it returns.
 */
export function subscribeBoard(
  onChange: () => void,
  onHealth?: (open: boolean) => void,
  onChat?: (ev: { type: "chat:message" } | { type: "chat:thinking"; on: boolean }) => void,
): () => void {
  const source = new EventSource(`${ENGINE}/api/stream`);

  /** Has this connection ever been up? Distinguishes a first open from a re-open. */
  let everOpen = false;
  /** Current believed state, so a transition is only acted on once. */
  let healthy = false;

  /**
   * Called whenever the connection is observably alive.
   *
   * The RE-OPEN branch is the whole reason this is not a one-line `onHealth(true)`.
   * EventSource reconnects by itself after an outage, but this channel has no
   * replay — so every change announced while it was down is gone for good. Without
   * a re-read on reconnect the page stayed stale until the 60s backstop poll
   * happened to fire: measured at 65 seconds to notice a task created 3 seconds
   * after the engine came back. The tab-hide path already did this; an automatic
   * reconnect is the same problem arriving without a visibility event.
   *
   * Guarded on the unhealthy→healthy transition so it fires exactly once per
   * outage, rather than on every frame that follows one.
   */
  const markHealthy = (): void => {
    if (healthy) return;
    healthy = true;
    onHealth?.(true);
    if (everOpen) onChange();
    everOpen = true;
  };

  source.onmessage = (e: MessageEvent<string>) => {
    // Any frame at all proves the connection is live. `onopen` should have said so
    // already, but a browser that delivers data before firing it would otherwise
    // leave the caller polling at the fallback rate over a working stream.
    markHealthy();
    try {
      const ev = JSON.parse(e.data) as { type?: string; on?: boolean };
      if (ev.type === "board:changed") onChange();
      else if (ev.type === "chat:message") onChat?.({ type: "chat:message" });
      else if (ev.type === "chat:thinking") onChat?.({ type: "chat:thinking", on: ev.on === true });
      // `stream:ready` needs no action beyond the health signal above: its only job
      // is to start the response body so the browser fires `onopen`.
    } catch {
      /* a malformed frame must not kill the stream */
    }
  };

  source.onopen = markHealthy;

  /**
   * The mirror of `markHealthy`, and guarded for the same reason.
   *
   * A retrying EventSource fires `onerror` on every failed attempt, so an
   * unguarded version reported `false` several times per outage. React's state
   * setter happens to bail out when the value is identical, which is why this was
   * harmless in practice — but that makes the contract depend on a detail of the
   * one current caller. Reporting transitions only is what the name `onHealth`
   * already implies.
   *
   * An error arriving before any successful open reports nothing, which is correct:
   * the caller starts out assuming no stream, so nothing has changed.
   */
  source.onerror = () => {
    if (!healthy) return;
    healthy = false;
    onHealth?.(false);
  };

  return () => source.close();
}

export function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

/**
 * Formats a provider-stated cost.
 *
 * Returns null for zero rather than "$0.00", because zero means "this runtime
 * did not report a price" — not "this was free". Rendering $0.00 for a run that
 * genuinely cost money would be a straightforwardly false statement, and only
 * some runtimes report at all (Grok in exact 1e-10 USD ticks, Kiro in credits).
 *
 * Sub-cent totals are normal for a single turn, so they are shown as a bound
 * rather than rounded away to zero.
 */
export function fmtUsd(n: number): string | null {
  if (!Number.isFinite(n) || n <= 0) return null;
  if (n < 0.01) return "<$0.01";
  return `$${n.toFixed(2)}`;
}

export function fmtDuration(startIso: string, endIso: string | null): string {
  const start = Date.parse(startIso);
  const end = endIso ? Date.parse(endIso) : Date.now();
  if (!Number.isFinite(start) || !Number.isFinite(end)) return "—";
  const s = Math.max(0, Math.round((end - start) / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export function fmtRelative(iso: string): string {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "—";
  const diff = Date.now() - t;
  const m = Math.round(diff / 60000);
  if (m < 1) return "刚刚";
  if (m < 60) return `${m} 分钟前`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} 小时前`;
  return `${Math.round(h / 24)} 天前`;
}
