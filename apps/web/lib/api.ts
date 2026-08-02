import type {
  AttemptTranscript,
  Channel,
  DetectedRuntime,
  Expert,
  Message,
  MessageWithThread,
  Project,
  Run,
  RunDetail,
  StreamEvent,
  Task,
  TaskStatus,
  Team,
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

  runs: () => req<Run[]>("/api/runs"),

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

  // ── Channels ────────────────────────────────────────────────

  channels: () => req<Channel[]>("/api/channels"),

  createChannel: (body: {
    name: string;
    purpose?: string;
    kind?: "channel" | "dm";
    projectId?: string | null;
    dmExpertId?: string | null;
  }) => req<Channel>("/api/channels", { method: "POST", body: JSON.stringify(body) }),

  /**
   * A channel's root messages with their thread summaries.
   *
   * The engine clamps `limit` to 1..500 rather than trusting it, so asking for
   * more than that quietly returns 500 instead of erroring.
   */
  messages: (channelId: string, limit?: number) =>
    req<{ channel: Channel; messages: MessageWithThread[] }>(
      `/api/channels/${channelId}/messages${limit === undefined ? "" : `?limit=${limit}`}`,
    ),

  /**
   * Posts a message, optionally creating a board card from it.
   *
   * `asTask` is the join between chat and the board: one action both says the
   * thing and tracks it, in a single transaction, so a request never has to be
   * restated by hand.
   */
  postMessage: (
    channelId: string,
    body: {
      body: string;
      authorKind?: "human" | "expert";
      authorId?: string | null;
      parentId?: string | null;
      asTask?: boolean;
    },
  ) =>
    req<{ message: Message; task: Task | null }>(`/api/channels/${channelId}/messages`, {
      method: "POST",
      body: JSON.stringify(body),
    }),

  /** One thread's replies. Threads are one level deep. */
  replies: (messageId: string) =>
    req<{ root: Message; replies: Message[] }>(`/api/messages/${messageId}/replies`),

  /**
   * A channel's board.
   *
   * Every column is present even when empty — a Kanban board with a missing
   * column is a layout bug rather than a state worth rendering.
   */
  tasks: (channelId: string) =>
    req<{ channel: Channel; board: Record<TaskStatus, Task[]>; tasks: Task[] }>(
      `/api/channels/${channelId}/tasks`,
    ),

  /** Creates one or more cards. All or none: a partial batch is never stored. */
  createTasks: (channelId: string, titles: string[]) =>
    req<Task[]>(`/api/channels/${channelId}/tasks`, {
      method: "POST",
      body: JSON.stringify({ titles }),
    }),

  /**
   * Starts a pipeline run for a card.
   *
   * Never optimistic: this spawns real CLI processes and spends real tokens, and
   * the engine can refuse it (no repository on the channel, another run already
   * holding the repository lock, this card already running). The caller has to
   * await the answer and show it.
   */
  runTask: (taskId: string, opts: { budgetTokens?: number } = {}) =>
    req<{ run: Run; task: Task }>(`/api/tasks/${taskId}/run`, {
      method: "POST",
      body: JSON.stringify(opts),
    }),

  /**
   * Patches a card.
   *
   * `assignee` is one unit rather than two fields: `expert` with no id, or an id
   * with no kind, are both unresolvable, and accepting them separately would let
   * the UI build exactly those states across two requests. `null` unclaims.
   */
  patchTask: (
    taskId: string,
    patch: {
      title?: string;
      status?: TaskStatus;
      assignee?: { kind: "human" | "expert"; id?: string | null } | null;
    },
  ) => req<Task>(`/api/tasks/${taskId}`, { method: "PATCH", body: JSON.stringify(patch) }),
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
