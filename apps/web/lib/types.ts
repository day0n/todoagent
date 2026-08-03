/**
 * Client-side mirrors of the engine's wire shapes.
 *
 * Deliberately declared here rather than imported from @todoagent/core: the web
 * app talks to the engine over HTTP and should survive the engine returning a
 * slightly older or newer shape. Every field is read defensively at the point of
 * use, so a missing one degrades the display instead of blanking the page.
 */

export type RuntimeKind = "claude" | "codex" | "cursor" | "gemini" | "kiro" | "grok";

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
  expertId: string;
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
  repoPath: string | null;
  createdAt: string;
}

/** Sidebar counts for the three aggregated views, computed by the engine. */
export interface ViewCounts {
  today: number;
  needs: number;
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
export type ViewKey = "today" | "needs" | "done" | `list:${string}`;

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

export type NeedsKind = "question" | "blocked" | "failed";

export interface Task {
  id: string;
  /** The list this task belongs to. Named for the underlying table. */
  channelId: string;
  title: string;
  status: TaskStatus;
  note: string;
  myDay: string | null;
  needsKind: NeedsKind | null;
  needsText: string | null;
  assigneeKind: ActorKind | null;
  assigneeId: string | null;
  creatorKind: ActorKind;
  creatorId: string | null;
  sourceMessageId: string | null;
  runId: string | null;
  createdAt: string;
  updatedAt: string;
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

/** One turn of the main-agent conversation. Posting into it arrives with M4. */
export interface ChatMessage {
  id: string;
  role: "user" | "agent";
  body: string;
  /** Ids of tasks this message created or referenced. */
  taskRefs: string[];
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
  messages: ChatMessage[];
  tasks: Record<string, ChatTaskCard>;
}

/** Whether the main agent can run, and if not, the banner text explaining why. */
export type ChatStatus = { ready: true; model: string } | { ready: false; reason: string };
