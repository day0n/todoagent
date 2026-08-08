/**
 * Client-side mirrors of the engine's wire shapes.
 *
 * Deliberately declared here rather than imported from @todoagent/core: the web
 * app talks to the engine over HTTP and should survive the engine returning a
 * slightly older or newer shape. Every field is read defensively at the point of
 * use, so a missing one degrades the display instead of blanking the page.
 */

export type RuntimeKind = "claude" | "codex" | "cursor" | "gemini" | "kiro" | "grok";

/** The Runtime Manager's persisted view of one supported local CLI. */
export type RuntimeStatus =
  | "missing"
  | "unverified"
  | "verifying"
  | "ready"
  | "auth_required"
  | "error";

export interface RuntimeInfo {
  kind: RuntimeKind;
  label: string;
  status: RuntimeStatus;
  execPath: string | null;
  version: string | null;
  detectedAt: string | null;
  verifiedAt: string | null;
  verifyError: string | null;
  activeRuns: number;
}

/**
 * Runtime discovery's new shape plus the old fields kept during the migration.
 * New UI reads `runtimes`; older clients can continue reading the three mirrors.
 */
export interface RuntimeEnvelope {
  runtimes: RuntimeInfo[];
  detected: DetectedRuntime[];
  known: string[];
  missing: string[];
}

export type Phase = "plan" | "draft" | "review" | "rebuttal" | "adjudicate" | "verify";

export const PHASE_ORDER: readonly Phase[] = [
  "plan",
  "draft",
  "review",
  "rebuttal",
  "adjudicate",
  "verify",
];

export const PHASE_LABEL: Record<Phase, string> = {
  plan: "拆解",
  draft: "并行执行",
  review: "交叉评审",
  rebuttal: "反驳",
  adjudicate: "裁决",
  verify: "验证",
};

export type RunStatus =
  | "running"
  | "blocked_on_human"
  | "completed"
  | "failed"
  | "cancelled"
  | "budget_exceeded";

export const STATUS_LABEL: Record<RunStatus, string> = {
  running: "进行中",
  blocked_on_human: "等你决定",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消",
  budget_exceeded: "预算耗尽",
};

export interface Run {
  id: string;
  projectId: string;
  projectName?: string;
  taskId?: string | null;
  parentRunId?: string | null;
  trigger?: "dispatch" | "task_chat" | null;
  userMessage?: string | null;
  repositoryRoot?: string | null;
  workingDirectory?: string | null;
  goal: string;
  acceptance: string | null;
  status: RunStatus;
  phase: Phase;
  /** Only gates the engine actually sets; see HumanGate in @todoagent/core. */
  gate: "plan_approval" | "adjudication" | null;
  budgetTokens: number;
  spentTokens: number;
  soloMode: boolean;
  round: number;
  createdAt: string;
  endedAt: string | null;
  error: string | null;
  /** Immutable local CLI snapshot captured when this run was dispatched. */
  runtimeKind?: RuntimeKind | null;
  runtimeExecPath?: string | null;
  runtimeVersion?: string | null;
}

export type SubTaskStatus =
  | "todo"
  | "running"
  | "in_review"
  | "reworking"
  | "done"
  | "blocked"
  | "failed";

export interface SubTask {
  id: string;
  runId: string;
  stage: number;
  title: string;
  brief: string;
  acceptance: string;
  capability: string;
  assignedExpertId: string | null;
  assigneeName?: string;
  dependsOn: string[];
  status: SubTaskStatus;
  worktreePath: string | null;
}

export interface Attempt {
  id: string;
  runId: string;
  subTaskId: string | null;
  /** Null for the direct local-CLI path; retained for historical pipeline attempts. */
  expertId: string | null;
  expertName?: string;
  runtimeKind: RuntimeKind;
  kind: "plan" | "draft" | "review" | "rebuttal" | "adjudicate" | "verify" | "discuss" | "repro";
  status: "running" | "completed" | "failed" | "timeout" | "cancelled";
  /**
   * Size of the agent's final text, not the text itself.
   *
   * The run endpoint deliberately omits `output`: measured at 211 KB of a 292 KB
   * payload on a realistic run, for content this UI never renders, refetched on
   * every structural event. Live text arrives over SSE instead. Declaring
   * `output` here would be a type that is always null in practice.
   */
  outputChars: number;
  error: string | null;
  inputTokens: number;
  outputTokens: number;
  /**
   * Provider-stated spend in USD. Zero means "not reported", not "free".
   *
   * Only some runtimes state a price — Grok reports exact ticks of 1e-10 USD,
   * Kiro reports credits. The engine has always returned this field; the web
   * type simply never declared it, so a real figure was recorded end-to-end and
   * then invisible in the only place a person would look.
   */
  costUsd: number;
  startedAt: string;
  endedAt: string | null;
}

/**
 * One attempt's full transcript, fetched on demand.
 *
 * Exists because the run overview strips `output` — it was 211 KB of a 292 KB
 * payload, refetched on every structural event, for text that view never renders.
 * Reading a transcript is an explicit action instead of a permanent tax.
 */
export interface AttemptTranscript extends Omit<Attempt, "outputChars"> {
  output: string | null;
}

export interface Review {
  id: string;
  runId: string;
  subTaskId: string;
  reviewerExpertId: string;
  reviewerName?: string;
  round: number;
  severity: "blocker" | "major" | "nit";
  claim: string;
  evidence: string;
  /**
   * The split that drives the whole review panel: a checkable claim gets a
   * red/green repro verdict, an uncheckable one is what a human is for.
   */
  verifiable: boolean;
  suggestedTest: string | null;
  patch: string | null;
  reproOutcome: "confirmed" | "refuted" | "inconclusive" | null;
  createdAt: string;
}

export interface Adjudication {
  id: string;
  runId: string;
  subTaskId: string;
  round: number;
  verdict: "proceed" | "rework" | "escalate";
  rationale: string;
  escalatedToHuman: boolean;
  humanDecision: string | null;
  createdAt: string;
}

export interface DiscussionMessage {
  id: string;
  runId: string;
  subTaskId: string;
  round: number;
  authorExpertId: string;
  authorName?: string;
  body: string;
  createdAt: string;
}

export interface Expert {
  id: string;
  name: string;
  description: string;
  runtimeKind: RuntimeKind;
  model: string | null;
  systemPrompt: string;
  capabilities: string[];
}

export interface TeamMemberView {
  role: string;
  expertId: string;
  name: string;
  runtimeKind: RuntimeKind;
  capabilities: string[];
}

export interface Team {
  id: string;
  name: string;
  members: TeamMemberView[];
}

export interface Project {
  id: string;
  name: string;
  repoPath: string;
  teamId: string;
}

export interface RunDetail {
  run: Run;
  project: Project | null;
  subtasks: SubTask[];
  attempts: Attempt[];
  reviews: Review[];
  adjudications: Adjudication[];
  discussion: DiscussionMessage[];
  active: boolean;
}

export interface StreamEvent {
  id: number;
  type: string;
  attemptId: string | null;
  payload: unknown;
  createdAt: string;
}

export interface DetectedRuntime {
  kind: RuntimeKind;
  execPath: string;
  version: string;
}

// ─────────────────────────────────────────────────────────────
// Todo layer
//
// The product surface: lists, tasks, and the agent conversation. A list IS a
// channel row in the database — the table was kept and the vocabulary changed —
// which is why a task still carries `channelId` on the wire.
// ─────────────────────────────────────────────────────────────

/** Who acted. There is a single local human, so `human` carries no id. */
export type ActorKind = "human" | "expert";

/**
 * A list, as `GET /api/lists` returns it.
 *
 * `repoPath` is what makes the list's tasks dispatchable: no repository means no
 * working directory for an agent, so those tasks are todo-only. The UI has to
 * say that by omitting the dispatch button rather than offering one that 400s.
 */
export interface TodoList {
  id: string;
  name: string;
  purpose: string;
  kind: "channel" | "dm";
  projectId: string | null;
  dmExpertId: string | null;
  /** Sidebar swatch, e.g. "#3a3a3c". Null renders the default grey. */
  color: string | null;
  /** Archived lists keep their tasks but leave the sidebar. */
  archivedAt: string | null;
  /** Tasks not yet done. Drives the sidebar count. */
  openCount: number;
  /**
   * Parked tasks on this list that are waiting on a SENTENCE from you.
   *
   * Drives the blue dot. Split from `brokenCount` because the two cost wildly
   * different amounts of your attention — answering is seconds, and one number
   * summing both is exactly what the removed 需要你 badge did: unusable for
   * deciding whether to look now.
   */
  askingCount: number;
  /** Parked tasks whose run is dead (`blocked` / `failed`). Drives the warm dot. */
  brokenCount: number;
  repoPath: string | null;
  createdAt: string;
}

/** Sidebar counts for the three aggregated views, computed by the engine. */
export interface ViewCounts {
  /** All unfinished tasks across the system Tasks view. */
  tasks: number;
  today: number;
  needs: number;
  /** Tasks with a live run, for the sidebar's 状态 section. */
  running: number;
  done: number;
}

export interface ListsResponse {
  lists: TodoList[];
  counts: ViewCounts;
}

/**
 * Which set of tasks the middle pane is showing.
 *
 * A template literal rather than a plain string, so `view=list:` with no id — or
 * a typo'd aggregate name — is a compile error instead of a 400 at runtime.
 */
/**
 * Which view the task pane is showing.
 *
 * `today` is the day board — four day columns rather than status groups, so it
 * reads through `api.board()`. The rest are status-grouped lists through
 * `api.tasks()`. That split is why `isBoardView` exists rather than callers
 * comparing strings.
 */
export type ViewKey = "today" | "tasks" | "needs" | "running" | "done" | `list:${string}`;

/** Does this view render as the day board? Only 我的一天 does. */
export function isBoardView(view: ViewKey): boolean {
  return view === "today";
}

/**
 * Task status.
 *
 * Deliberately not `SubTaskStatus`: that tracks one agent's work inside a run
 * and carries states this surface has no group for (`reworking`, `blocked`,
 * `failed`).
 */
export type TaskStatus = "todo" | "in_progress" | "needs_you" | "in_review" | "done";

/**
 * Group render order, which is NOT the state machine's order.
 *
 * What needs a person comes first, then what is moving on its own, then what is
 * waiting on them, then the backlog, then the archive. The engine returns an
 * object keyed by status; this array is what decides the reading order, and
 * `TaskGroups` is keyed off it so a new status cannot be added without landing
 * somewhere on screen.
 */
export const GROUP_ORDER: readonly TaskStatus[] = [
  "needs_you",
  "in_progress",
  "in_review",
  "todo",
  "done",
];

export const TASK_STATUS_LABEL: Record<TaskStatus, string> = {
  todo: "待办",
  in_progress: "进行中",
  needs_you: "需要你",
  in_review: "待确认",
  done: "已完成",
};

/**
 * The statuses a person can set directly.
 *
 * `needs_you` is absent because the engine refuses it: that status is a
 * conclusion the runtime reached, and it always carries a `needsKind`. Letting
 * the UI ask for it would be asking for a row that violates that invariant.
 */
export type SettableTaskStatus = Exclude<TaskStatus, "needs_you">;

export type NeedsKind = "question" | "reply" | "blocked" | "failed";

export interface Task {
  id: string;
  /** The list this task belongs to. Named for the underlying table. */
  channelId: string;
  title: string;
  status: TaskStatus;
  note: string;
  myDay: string | null;
  /**
   * ISO date (`YYYY-MM-DD`) this task is due. Null means no deadline.
   *
   * A date, not a timestamp — "Friday" is what a deadline means to a person. The
   * engine puts anything due today or overdue into 我的一天 automatically, so a
   * deadline changes what you see rather than only decorating a row.
   */
  dueDate: string | null;
  needsKind: NeedsKind | null;
  needsText: string | null;
  assigneeKind: ActorKind | null;
  assigneeId: string | null;
  creatorKind: ActorKind;
  creatorId: string | null;
  sourceMessageId: string | null;
  runId: string | null;
  /** CLI explicitly chosen for the latest dispatch, if this task has been run. */
  runtimeKind?: RuntimeKind | null;
  /** Locked working directory for this task's CLI conversation. */
  workingDirectory?: string | null;
  createdAt: string;
  updatedAt: string;
}

/** The day board's four columns, in display order. */
export type BoardKey = "today" | "tomorrow" | "dayAfter" | "later";

export interface BoardColumn {
  key: BoardKey;
  /**
   * `YYYY-MM-DD` for the three dated columns, null for 以后.
   *
   * Sent by the engine rather than derived here: the client would otherwise keep
   * bucketing against yesterday in a tab left open overnight, and two
   * implementations of "what day is the third column" would have to agree.
   */
  date: string | null;
  /** `Date.getDay()`, so 周二 renders without parsing the date string. */
  weekday: number | null;
  tasks: Task[];
  /** Only the today column can be non-zero — finishing a task moves it there. */
  done: number;
  total: number;
}

export interface BoardResponse {
  /** The engine's idea of today, for comparing against a stale client clock. */
  today: string;
  columns: BoardColumn[];
}

/** Tasks for one view, pre-grouped by the engine. Every key is present. */
export type TaskGroups = Record<TaskStatus, Task[]>;

export interface TasksResponse {
  view: string;
  groups: TaskGroups;
}

/**
 * What a finished run left behind, as `GET /api/runs/:id/result` returns it.
 *
 * `diff` distinguishes two answers that must not be collapsed:
 *
 *   null  no snapshot was taken — the run failed, was cancelled, or predates the
 *         column. The UI must not claim the agent changed nothing, because a run
 *         that died mid-edit may well have changed several files.
 *   ""    a snapshot WAS taken and the tree was clean. The agent genuinely changed
 *         no files, which is a real outcome worth stating.
 */
export interface RunResult {
  run: Run;
  diff: string | null;
  /** The newest attempt's final text, skipping crashed retries that produced none. */
  output: string | null;
  /** Runtime that did the work, e.g. "codex". Null when no attempt exists. */
  executor: string | null;
}

export interface TaskThreadTurn {
  run: Run;
  message: string;
  output: string | null;
  executor: string | null;
  attempts: Attempt[];
  /** Durable, user-visible execution record for this turn. */
  events: StreamEvent[];
}

export interface AssistantWorkspace {
  path: string;
  memory: string;
  refs: string[];
}

export interface TaskThread {
  task: Task;
  list: { id: string; name: string } | null;
  defaultWorkingDirectory: string | null;
  knownWorkspaces: Array<{ name: string; path: string }>;
  turns: TaskThreadTurn[];
  activeRunId: string | null;
  replyCount: number;
}

/**
 * One independent conversation thread with the secretary.
 *
 * Several of these can exist side by side — a person picks one from the
 * header's switcher rather than the app holding a single global chat.
 */
export interface ChatSession {
  id: string;
  /** Empty until renamed; the switcher falls back to a relative-time label. */
  title: string;
  createdAt: string;
  /** Bumped on every message, so the switcher can sort by recent activity. */
  updatedAt: string;
  /** Archived threads keep their messages but leave the switcher's default list. */
  archivedAt: string | null;
}

/** An image sent alongside a chat message. */
export interface ChatAttachment {
  id: string;
  /** e.g. "image/png". Only images are supported today. */
  mediaType: string;
  /** Where the engine serves the stored file, e.g. "/api/uploads/:id". */
  url: string;
  width?: number;
  height?: number;
}

/** One turn of the main-agent conversation. Posting into it arrives with M4. */
export interface ChatMessage {
  id: string;
  sessionId: string;
  role: "user" | "agent";
  body: string;
  /** Ids of tasks this message created or referenced. */
  taskRefs: string[];
  /** Images sent with this message, if any. */
  attachments: ChatAttachment[];
  createdAt: string;
}

/** What a `taskRefs` id resolves to, for the inline card in the chat. */
export interface ChatTaskCard {
  id: string;
  title: string;
  status: TaskStatus;
  channelId: string;
}

export interface ChatHistory {
  sessionId: string;
  messages: ChatMessage[];
  tasks: Record<string, ChatTaskCard>;
}

/** Whether the main agent can run, and if not, the banner text explaining why. */
export type ChatStatus = { ready: true; model: string } | { ready: false; reason: string };
