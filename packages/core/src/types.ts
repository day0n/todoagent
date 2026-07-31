import { z } from "zod";

// ─────────────────────────────────────────────────────────────
// Organization layer — semantics borrowed from Raft's team model
// ─────────────────────────────────────────────────────────────

/**
 * A local coding CLI we know how to drive.
 *
 * Two transport families sit behind these names: stream-json over stdout
 * (claude, cursor, gemini), line-delimited JSONL (codex), and JSON-RPC over
 * stdio (kiro, via ACP). The adapter layer hides that split entirely.
 */
export type RuntimeKind = "claude" | "codex" | "cursor" | "gemini" | "kiro" | "grok";

export const RUNTIME_KINDS: readonly RuntimeKind[] = [
  "claude",
  "codex",
  "cursor",
  "gemini",
  "kiro",
  "grok",
];

/** A CLI detected on this machine. */
export interface DetectedRuntime {
  kind: RuntimeKind;
  execPath: string;
  version: string;
}

/**
 * Pipeline position. Orthogonal to `capabilities` — a team may hold two makers
 * with different specialties, and one expert may serve several roles.
 */
/**
 * Pipeline position.
 *
 * Every value here is one the orchestrator actually selects. A `researcher` role
 * was declared and described in the UI ("returns evidence and uncertainty, not the
 * deliverable") but nothing ever picked it — so a user who created one got an
 * expert that silently never worked. Removed rather than justified by inventing a
 * research phase nobody asked for; the union is a promise about behaviour.
 */
export type ExpertRole = "orchestrator" | "maker" | "reviewer" | "verifier";

export const EXPERT_ROLES: readonly ExpertRole[] = [
  "orchestrator",
  "maker",
  "reviewer",
  "verifier",
];

/**
 * A configured specialist: an identity bound to one local runtime.
 *
 * `capabilities` are free-form domain tags ("frontend-aesthetics", "debugging").
 * They are DATA, not logic: which runtime is good at what is folklore that
 * drifts with every model release, so routing reads this table and the
 * historical outcome records rather than any hardcoded mapping.
 */
export interface Expert {
  id: string;
  name: string;
  description: string;
  runtimeKind: RuntimeKind;
  model: string | null;
  systemPrompt: string;
  capabilities: string[];
  createdAt: string;
}

export interface Team {
  id: string;
  name: string;
  createdAt: string;
}

export interface TeamMember {
  teamId: string;
  expertId: string;
  role: ExpertRole;
}

export interface Project {
  id: string;
  name: string;
  repoPath: string;
  teamId: string;
  createdAt: string;
}

// ─────────────────────────────────────────────────────────────
// Execution layer — semantics borrowed from Multica
// (parent issue / child issue + issue_stage barrier, and the
//  issue-vs-task split that gives retries somewhere to live)
// ─────────────────────────────────────────────────────────────

/**
 * Deterministic pipeline. Control flow lives in code; models only supply
 * content. Free-form agent chat does not converge — it collapses onto whoever
 * spoke first, destroying the independent perspectives that are the entire
 * reason to pay for several vendors.
 */
export type Phase = "plan" | "draft" | "review" | "rebuttal" | "adjudicate" | "verify";

export const PHASES: readonly Phase[] = [
  "plan",
  "draft",
  "review",
  "rebuttal",
  "adjudicate",
  "verify",
];

export type RunStatus =
  | "running"
  | "blocked_on_human"
  | "completed"
  | "failed"
  | "cancelled"
  | "budget_exceeded";

/** What the run needs from the human before it can move. */
/**
 * What the run needs from a human before it can move.
 *
 * Both values are ones the pipeline actually sets. A `final_review` member was
 * declared and never assigned anywhere — a union member that cannot occur is a
 * claim the code does not honour, and it forces every reader to wonder which
 * branch handles it.
 */
export type HumanGate = "plan_approval" | "adjudication";

export interface Run {
  id: string;
  projectId: string;
  goal: string;
  acceptance: string | null;
  status: RunStatus;
  phase: Phase;
  /** Non-null only when status is `blocked_on_human`. */
  gate: HumanGate | null;
  /** Hard ceiling. Exceeding it stops the run and surrenders partial output. */
  budgetTokens: number;
  spentTokens: number;
  /** Single-expert express lane: skip fan-out entirely for small work. */
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

/**
 * States the stage barrier accepts as finished. Single source of truth — the
 * barrier query and the pipeline must not disagree about what "done" means.
 *
 * `in_review` is deliberately included. It is where a subtask lands when it
 * exhausts its rework rounds with findings still open: the agents have finished
 * and a human needs to look. That is a normal outcome, so excluding it made the
 * barrier reject the stage and abort the entire run over an expected result.
 *
 * `reworking` is deliberately excluded. Another draft is still coming, and
 * opening the next stage would let downstream work build on output that is
 * about to change underneath it.
 */
export const TERMINAL_SUBTASK_STATUS: ReadonlySet<string> = new Set<SubTaskStatus>([
  "done",
  "failed",
  "blocked",
  "in_review",
]);

export interface SubTask {
  id: string;
  runId: string;
  /**
   * Barrier group. Every subtask in stage N must reach a terminal state before
   * stage N+1 opens — this is Multica's staged-child-done wake, and it is what
   * Raft explicitly does NOT do ("Raft will not automatically hold one task
   * until another finishes"), leaving the human as the dependency engine.
   */
  stage: number;
  title: string;
  brief: string;
  acceptance: string;
  capability: string;
  assignedExpertId: string | null;
  dependsOn: string[];
  status: SubTaskStatus;
  /** Dedicated git worktree. Parallel writes to one tree always collide. */
  worktreePath: string | null;
  /**
   * Git branch carrying this subtask's committed work — the deliverable.
   *
   * Durable because it outlives its worktree: the directory is disposed the
   * moment the subtask finishes, while the merge phase runs only after every
   * subtask is done.
   */
  branch: string | null;
  createdAt: string;
}

export type AttemptStatus = "running" | "completed" | "failed" | "timeout" | "cancelled";

/** One concrete agent invocation. Separate from SubTask so retries have a home. */
export interface Attempt {
  id: string;
  runId: string;
  subTaskId: string | null;
  expertId: string;
  runtimeKind: RuntimeKind;
  /** Why this agent was woken. Mirrors Multica's trigger reasons. */
  kind: "plan" | "draft" | "review" | "rebuttal" | "adjudicate" | "verify" | "discuss" | "repro";
  sessionId: string | null;
  status: AttemptStatus;
  output: string | null;
  error: string | null;
  inputTokens: number;
  outputTokens: number;
  /**
   * Provider-stated spend in USD, when the runtime reports it.
   *
   * Zero means "not reported", not "free". Only some runtimes state a price:
   * Grok reports exact ticks of 1e-10 USD and Kiro reports credits. Their own
   * figure beats any local tokens-times-rate estimate, because request-level
   * pricing rules (xAI bills 2x past a 200K prompt) cannot be reconstructed
   * from aggregated token counts.
   */
  costUsd: number;
  startedAt: string;
  endedAt: string | null;
}

/** Append-only. Backs SSE replay via Last-Event-ID and post-hoc inspection. */
export interface EventRow {
  id: number;
  runId: string;
  attemptId: string | null;
  seq: number;
  type: string;
  payload: string;
  createdAt: string;
}

// ─────────────────────────────────────────────────────────────
// Discussion layer — net-new; neither Multica nor Raft has it
// ─────────────────────────────────────────────────────────────

export type Severity = "blocker" | "major" | "nit";

/**
 * A structured critique of one subtask's output by another expert.
 *
 * `verifiable` is the load-bearing field. It splits every dispute into two
 * paths: a claim that can be checked ("this races") is settled by making the
 * claimant write a failing repro — red means real, green means they were
 * wrong — while a claim that cannot ("this hierarchy reads badly") is the only
 * kind worth escalating to a human. One repro beats three rounds of debate.
 */
export interface Review {
  id: string;
  runId: string;
  subTaskId: string;
  reviewerExpertId: string;
  round: number;
  severity: Severity;
  claim: string;
  evidence: string;
  verifiable: boolean;
  suggestedTest: string | null;
  patch: string | null;
  /** Set once a repro attempt has run. */
  reproOutcome: "confirmed" | "refuted" | "inconclusive" | null;
  createdAt: string;
}

export interface Rebuttal {
  id: string;
  reviewId: string;
  authorExpertId: string;
  decision: "accept" | "reject";
  reason: string;
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

/**
 * One turn in a bounded discussion thread. Bounded is the whole point: hard
 * caps on rounds and budget, with "no new blockers" as the convergence test.
 * There is deliberately no "until they agree" termination condition, because
 * that is not decidable.
 */
export interface DiscussionMessage {
  id: string;
  runId: string;
  subTaskId: string;
  round: number;
  authorExpertId: string;
  /** Who this turn addresses, for UI threading. */
  replyToId: string | null;
  body: string;
  createdAt: string;
}

// ─────────────────────────────────────────────────────────────
// Agent-produced schemas
//
// CLI agents emit text, not objects. Every schema below is parsed with zod and
// retried on mismatch — structured-output failure is a NORMAL path here, not an
// exception. (codex exec also accepts --output-schema natively; claude does not.)
// ─────────────────────────────────────────────────────────────

export const PlanSchema = z.object({
  summary: z.string().min(1),
  subtasks: z
    .array(
      z.object({
        id: z.string().min(1),
        title: z.string().min(1),
        brief: z.string().min(1),
        acceptance: z.string().min(1),
        capability: z.string().min(1),
        stage: z.number().int().min(0),
        dependsOn: z.array(z.string()).default([]),
      }),
    )
    .min(1)
    /*
     * Capped, because each subtask is expensive in a way the model cannot feel.
     *
     * One subtask costs a draft plus two reviews, and often a reproduction, a
     * rebuttal and an adjudication on top — roughly six full agent turns. An
     * uncapped plan of fifty subtasks is therefore ~300 turns; the budget ceiling
     * would stop it, but only after spending everything, and the plan gate would
     * ask a human to review a fifty-item list.
     *
     * A plan that genuinely needs more than this is a sign the goal should be split
     * into separate runs, which is also cheaper to steer.
     */
    .max(12)
    /*
     * Ids must be unique.
     *
     * Duplicates do not crash anything, which is the problem: each subtask gets its
     * own row regardless, so `dependsOn: ["a"]` silently becomes an ambiguous
     * reference and the ordering the planner intended is unknowable. At six agent
     * turns per subtask, executing a plan the model did not think through is
     * expensive — and the repair prompt states the exact duplicate, which a model
     * fixes readily.
     */
    .refine(
      (subtasks) => new Set(subtasks.map((s) => s.id)).size === subtasks.length,
      (subtasks) => {
        // Counted rather than filtered with a Set. `Set.add()` returns the SET,
        // which is always truthy, so the obvious-looking `filter(id => !seen.add(id))`
        // silently matched nothing and the message read "repeated: " with no ids —
        // and that message is what the repair prompt feeds back to the model.
        const counts = new Map<string, number>();
        for (const s of subtasks) counts.set(s.id, (counts.get(s.id) ?? 0) + 1);
        const repeated = [...counts.entries()].filter(([, n]) => n > 1).map(([id]) => id);
        return { message: `subtask ids must be unique; repeated: ${repeated.join(", ")}` };
      },
    ),
});
export type PlanOutput = z.infer<typeof PlanSchema>;

/**
 * Truncates instead of rejecting.
 *
 * A hard `.max()` would fail the whole review and burn a retry, discarding real
 * findings over their length — and a finding's substance is almost always at the
 * start. Unbounded was not an option either: these strings flow verbatim into the
 * rework prompt, so one enormous `patch` failed the next turn as a provider
 * rejection, which reads like an adapter bug rather than an oversized field.
 *
 * The cut is marked so a reader can tell truncation from an agent that stopped
 * mid-sentence.
 */
function cappedText(limit: number): z.ZodEffects<z.ZodString, string, string> {
  return z.string().transform((s) =>
    s.length > limit ? `${s.slice(0, limit)}\n…[truncated ${s.length - limit} chars]` : s,
  );
}

export const ReviewSchema = z.object({
  overall: z.enum(["approve", "request_changes"]),
  findings: z
    .array(
      z.object({
        severity: z.enum(["blocker", "major", "nit"]),
        claim: cappedText(2_000).pipe(z.string().min(1)),
        evidence: cappedText(8_000).default(""),
        verifiable: z.boolean(),
        suggestedTest: cappedText(4_000).nullable().default(null),
        // The largest field by nature — a suggested change can legitimately be a
        // sizeable snippet.
        patch: cappedText(12_000).nullable().default(null),
      }),
    )
    /*
     * Capped at 40 findings.
     *
     * Every blocking finding costs a rebuttal entry, possibly a reproduction turn,
     * and a line in the rework brief. A reviewer that returns hundreds has stopped
     * reviewing and started listing, and the prompt already tells it to group
     * similar items rather than produce a wall.
     */
    .max(40)
    .default([]),
});
export type ReviewOutput = z.infer<typeof ReviewSchema>;

export const RebuttalSchema = z.object({
  responses: z
    .array(
      z.object({
        reviewId: z.string().min(1),
        decision: z.enum(["accept", "reject"]),
        reason: z.string().min(1),
      }),
    )
    .default([]),
});
export type RebuttalOutput = z.infer<typeof RebuttalSchema>;

export const AdjudicationSchema = z.object({
  verdict: z.enum(["proceed", "rework", "escalate"]),
  rationale: z.string().min(1),
  escalations: z
    .array(z.object({ reviewId: z.string(), question: z.string() }))
    .default([]),
});
export type AdjudicationOutput = z.infer<typeof AdjudicationSchema>;

export const ReproSchema = z.object({
  outcome: z.enum(["confirmed", "refuted", "inconclusive"]),
  evidence: z.string().min(1),
});
export type ReproOutput = z.infer<typeof ReproSchema>;
