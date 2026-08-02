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
// Channel layer
//
// Chat is the workspace: channels, DMs and threads, with agents as persistent
// members rather than one-shot invocations. A channel message is durable
// conversation; `DiscussionMessage` above is a transcript of one review round
// inside one subtask. Different layers, deliberately different types.
// ─────────────────────────────────────────────────────────────

/** Who acted. There is a single local human, so `human` carries no id. */
export type ActorKind = "human" | "expert";

export interface Channel {
  id: string;
  name: string;
  purpose: string;
  kind: "channel" | "dm";
  /**
   * The repository this channel's work lands in.
   *
   * Null is legitimate: a DM, or a channel used purely for discussion, has no
   * repo — and a task there cannot start a run, which the UI has to say plainly
   * rather than offering a button that fails.
   */
  projectId: string | null;
  dmExpertId: string | null;
  createdAt: string;
}

export interface Message {
  /** Total order. Not derived from `createdAt`, which collides at ms resolution. */
  seq: number;
  id: string;
  channelId: string;
  authorKind: ActorKind;
  authorId: string | null;
  /** Thread root, or null when this message is itself a root. One level deep. */
  parentId: string | null;
  body: string;
  createdAt: string;
}

/** A root message plus its thread summary, as the channel stream returns it. */
export interface MessageWithThread extends Message {
  replyCount: number;
  lastReplyAt: string | null;
}

/**
 * Board column.
 *
 * Deliberately not `SubTaskStatus`: that tracks one agent's work inside a run
 * and carries states a board has no column for (`reworking`, `blocked`,
 * `failed`).
 */
export type TaskStatus = "todo" | "in_progress" | "needs_you" | "in_review" | "done";

export const TASK_STATUSES: readonly TaskStatus[] = [
  "todo",
  "in_progress",
  "needs_you",
  "in_review",
  "done",
];

export const TASK_STATUS_LABEL: Record<TaskStatus, string> = {
  todo: "待办",
  in_progress: "进行中",
  needs_you: "需要你",
  in_review: "待确认",
  done: "已完成",
};

export type NeedsKind = "question" | "blocked" | "failed";

export interface Task {
  id: string;
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
