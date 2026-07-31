import { zodToJsonSchema } from "../util/jsonschema.ts";
import type { Store } from "../db/index.ts";
import {
  AdjudicationSchema,
  PlanSchema,
  RebuttalSchema,
  ReproSchema,
  ReviewSchema,
  type Expert,
  type ExpertRole,
  type Review,
  type Run,
  type SubTask,
} from "../types.ts";
import {
  commitAll,
  createWorktree,
  currentHead,
  deleteBranchIfMerged,
  diffAgainst,
  dirtyTrackedFiles,
  git,
  isGitRepo,
  listCouncilBranches,
  mergeBranch,
  pruneWorktrees,
  type Worktree,
} from "../util/git.ts";
// Shared with the UI so the two cannot disagree about what counts as blocking.
import { isBlocking, needsHumanJudgment, needsReproduction } from "../review-rules.ts";
import { Semaphore, defaultConcurrency, mapLimit } from "../util/concurrency.ts";
import {
  adjudicatePrompt,
  discussPrompt,
  draftPrompt,
  planPrompt,
  rebuttalPrompt,
  reproPrompt,
  reviewPrompt,
  soloPrompt,
  verifyPrompt,
  type ReworkContext,
} from "./prompts.ts";
import { BudgetExceededError, recordEvent, runOne, runStructured } from "./runner.ts";

/** Hard caps. There is deliberately no "until they agree" condition anywhere. */
export const MAX_ROUNDS = 2;
export const MAX_DISCUSSION_ROUNDS = 2;
export const REVIEWERS_PER_SUBTASK = 2;

export interface PipelineOptions {
  store: Store;
  runId: string;
  signal?: AbortSignal;
  /**
   * Pauses for human plan approval. Skipping it is supported because an
   * unattended run needs to move, but it is the cheapest place to catch a bad
   * decomposition: 30 seconds here saves four wasted parallel drafts.
   */
  autoApprovePlan?: boolean;
  perAttemptTimeoutMs?: number;
  /**
   * Ceiling on simultaneous agent processes. Defaults to half the core count,
   * clamped to 2..6 — each unit of work is a whole coding CLI, not a request.
   */
  maxConcurrent?: number;
}

interface Ctx {
  store: Store;
  run: Run;
  repoPath: string;
  roster: Array<{ role: ExpertRole; expert: Expert }>;
  signal?: AbortSignal;
  perAttemptTimeoutMs?: number;
  /** Ceiling on simultaneous agent processes. See util/concurrency.ts. */
  maxConcurrent: number;
  /**
   * The actual global cap, shared by every agent turn in this run.
   *
   * `maxConcurrent` alone was not a real bound: the stage loop capped subtasks and
   * each subtask separately capped its reviewers, so the peak was the PRODUCT of
   * the two. One semaphore held around every spawn makes the limit mean what it
   * says.
   */
  slots: Semaphore;
}

/**
 * Builds the concurrency fields for a Ctx.
 *
 * One semaphore per run, shared by every agent turn in it. Kept together in a
 * helper so the three Ctx construction sites cannot drift into using different
 * limits — or worse, separate semaphores, which would silently restore the
 * multiplicative peak this exists to prevent.
 */
function makeSlots(maxConcurrent?: number): { maxConcurrent: number; slots: Semaphore } {
  const limit = maxConcurrent ?? defaultConcurrency();
  return { maxConcurrent: limit, slots: new Semaphore(limit) };
}

/** A roster entry: one expert filling one role. */
export type RosterEntry = { role: ExpertRole; expert: Expert };

/** Minimal shape needed to reconcile declared dependencies against stages. */
export interface StagedTask {
  id: string;
  stage: number;
  dependsOn: string[];
}

/**
 * Pushes each subtask past everything it depends on.
 *
 * `stage` is the only thing the executor honours — a stage runs in parallel and
 * the barrier gates the next one — while `dependsOn` was persisted and then never
 * read. So a plan that put two subtasks in the SAME stage and declared a
 * dependency between them ran them concurrently in isolated worktrees, and the
 * downstream one simply could not see its dependency's output. Silent: no error,
 * just work built on a missing prerequisite.
 *
 * Repairing the plan beats rejecting it. A rejection costs a full extra planning
 * turn to fix something mechanically derivable, and models are unreliable at
 * keeping two orderings consistent by hand.
 *
 * Unknown ids are ignored (a model sometimes invents one), and a dependency cycle
 * is left alone rather than looped over forever — the caller reports it.
 */
export function enforceDependencyStages<T extends StagedTask>(
  tasks: readonly T[],
): { tasks: T[]; promoted: Array<{ id: string; from: number; to: number }>; cycle: string[] } {
  const stages = new Map<string, number>(tasks.map((t) => [t.id, t.stage]));
  const known = new Set(stages.keys());
  const original = new Map(stages);

  // Bounded relaxation: a chain of N tasks needs at most N passes to settle, so
  // exceeding that means the graph has a cycle.
  let changed = true;
  let passes = 0;
  while (changed && passes <= tasks.length) {
    changed = false;
    passes++;
    for (const task of tasks) {
      const current = stages.get(task.id) ?? task.stage;
      let required = current;
      for (const dep of task.dependsOn) {
        if (!known.has(dep) || dep === task.id) continue;
        const depStage = stages.get(dep) ?? 0;
        if (depStage >= required) required = depStage + 1;
      }
      if (required !== current) {
        stages.set(task.id, required);
        changed = true;
      }
    }
  }

  const cycle = changed
    ? tasks
        .filter((t) => t.dependsOn.some((d) => known.has(d)))
        .map((t) => t.id)
    : [];

  const promoted: Array<{ id: string; from: number; to: number }> = [];
  const out = tasks.map((t) => {
    const to = stages.get(t.id) ?? t.stage;
    if (to !== t.stage) promoted.push({ id: t.id, from: original.get(t.id) ?? t.stage, to });
    return { ...t, stage: to };
  });

  return { tasks: out, promoted, cycle };
}

// Imported for local use AND re-exported: `export { x } from "./y"` forwards the
// binding without introducing it into this module's scope, so the pipeline could
// not actually call it.
export { isBlocking, needsHumanJudgment, needsReproduction };

function pick(roster: readonly RosterEntry[], role: ExpertRole): Expert | null {
  return roster.find((r) => r.role === role)?.expert ?? null;
}

function pickAll(roster: readonly RosterEntry[], role: ExpertRole): Expert[] {
  return roster.filter((r) => r.role === role).map((r) => r.expert);
}

/**
 * Routes a subtask to the maker whose declared capabilities best cover it.
 *
 * Capability tags are folklore that drifts with every model release, so this is
 * a data lookup, never a hardcoded "gemini does UI" mapping. The attempt and
 * review tables record what actually happened, which is what should eventually
 * calibrate this.
 */
/** Splits a capability tag into comparable words. */
function capabilityTokens(s: string): string[] {
  return s
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 0);
}

export function routeMaker(roster: readonly RosterEntry[], capability: string): Expert | null {
  const makers = pickAll(roster, "maker");
  if (makers.length === 0) return null;
  const want = capability.toLowerCase().trim();
  if (want.length > 0) {
    const exact = makers.find((m) => m.capabilities.some((c) => c.toLowerCase() === want));
    if (exact) return exact;

    /*
     * Fall back to sharing a whole WORD, not a substring.
     *
     * Raw substring matching mis-routes on short tags, and short tags are
     * common: a maker declaring "go" matched a "logo-design" subtask, because
     * "logo-design".includes("go") is true. Comparing tokens keeps
     * "frontend-aesthetics" → "frontend" working while rejecting that.
     */
    const wantTokens = new Set(capabilityTokens(want));
    const partial = makers.find((m) =>
      m.capabilities.some((c) => capabilityTokens(c).some((t) => wantTokens.has(t))),
    );
    if (partial) return partial;
  }
  return makers[0] ?? null;
}

/**
 * Reviewers for one subtask: never the author, capped, and role-preferred.
 *
 * Excluding the author is load-bearing. One expert commonly holds several roles,
 * so a naive "everyone with the reviewer role" would let an agent review its own
 * output — which looks like review in the UI while destroying the independent
 * judgment that paying for several vendors was supposed to buy.
 */
export function pickReviewers(roster: readonly RosterEntry[], authorId: string): Expert[] {
  const explicit = pickAll(roster, "reviewer").filter((e) => e.id !== authorId);
  const others = roster
    .map((r) => r.expert)
    .filter((e) => e.id !== authorId && !explicit.some((x) => x.id === e.id));
  // Dedupe: one expert may hold several roles.
  const seen = new Set<string>();
  const out: Expert[] = [];
  for (const e of [...explicit, ...others]) {
    if (seen.has(e.id)) continue;
    seen.add(e.id);
    out.push(e);
    if (out.length >= REVIEWERS_PER_SUBTASK) break;
  }
  return out;
}

function log(ctx: Ctx, type: string, payload: unknown): void {
  recordEvent(ctx.store, ctx.run.id, null, type, payload);
}

function setPhase(ctx: Ctx, phase: Run["phase"]): void {
  ctx.store.updateRun(ctx.run.id, { phase });
  ctx.run = { ...ctx.run, phase };
  log(ctx, "phase:entered", { phase });
}

/**
 * Runs one goal through the full pipeline.
 *
 * Control flow is deterministic on purpose. Free-form agent chat does not
 * converge — it collapses onto whoever spoke first, which destroys the
 * independent perspectives that are the only reason to pay several vendors.
 * Models decide content; this function decides what happens next.
 */
export async function runPipeline(opts: PipelineOptions): Promise<{ status: Run["status"]; error: string | null }> {
  const { store, runId } = opts;
  const run0 = store.getRun(runId);
  if (!run0) throw new Error(`run not found: ${runId}`);
  const project = store.getProject(run0.projectId);
  if (!project) throw new Error(`project not found: ${run0.projectId}`);

  const roster = store.roster(project.teamId).map(({ member, expert }) => ({
    role: member.role,
    expert,
  }));
  if (roster.length === 0) throw new Error("team has no members");

  const ctx: Ctx = {
    store,
    run: run0,
    repoPath: project.repoPath,
    roster,
    ...makeSlots(opts.maxConcurrent),
    ...(opts.signal ? { signal: opts.signal } : {}),
    ...(opts.perAttemptTimeoutMs !== undefined ? { perAttemptTimeoutMs: opts.perAttemptTimeoutMs } : {}),
  };

  try {
    if (!(await isGitRepo(ctx.repoPath))) {
      throw new Error(
        `${ctx.repoPath} is not a git repository — worktree isolation requires one, and without it parallel agents would overwrite each other`,
      );
    }

    if (ctx.run.soloMode) {
      /*
       * Solo mode is deliberately exempt from the clean-tree check below.
       *
       * It works directly in the repository rather than a worktree, so it SEES the
       * user's uncommitted changes and never merges — neither failure mode applies,
       * and refusing would be obstruction.
       */
      await runSolo(ctx);
    } else {
      /*
       * A dirty working tree is refused up front.
       *
       * Worktrees branch from HEAD, so an agent cannot see work that exists only in
       * the working tree: it reasons about a stale snapshot of the very files the
       * user is editing. Then git refuses the merge at the end ("your local changes
       * would be overwritten") — measured — so the entire run is spent before the
       * problem surfaces.
       *
       * The cost asymmetry decides it: a whole run's budget versus five seconds of
       * `git stash`. Untracked files are ignored (see dirtyTrackedFiles) because
       * scratch files are ubiquitous and harmless here.
       */
      const dirty = await dirtyTrackedFiles(ctx.repoPath);
      if (dirty.length > 0) {
        const shown = dirty.slice(0, 10).join(", ");
        const more = dirty.length > 10 ? ` (and ${dirty.length - 10} more)` : "";
        throw new Error(
          `the repository has uncommitted changes to ${dirty.length} tracked file(s): ${shown}${more}. ` +
            `Agents work in git worktrees branched from HEAD, so they cannot see these edits, and the ` +
            `final merge would be refused after the run had already been paid for. Commit or stash them first ` +
            `(\`git stash\`), or use single-expert mode, which works directly in your tree.`,
        );
      }
      const approved = await phasePlan(ctx, opts.autoApprovePlan === true);
      if (!approved) return { status: "blocked_on_human", error: null };
      const ledger = newLedger();
      await phaseStages(ctx, ledger);
      await phaseVerify(ctx, ledger);
    }

    return finishRun(ctx, store, runId);
  } catch (err) {
    if (err instanceof BudgetExceededError) {
      store.updateRun(runId, {
        status: "budget_exceeded",
        error: err.message,
        endedAt: new Date().toISOString(),
      });
      log(ctx, "run:budget_exceeded", { message: err.message });
      // Not a failure: partial work is still handed over, which is the whole
      // point of a ceiling rather than an unbounded run.
      return { status: "budget_exceeded", error: err.message };
    }
    const message = err instanceof Error ? err.message : String(err);
    store.updateRun(runId, { status: "failed", error: message, endedAt: new Date().toISOString() });
    log(ctx, "run:failed", { message });
    return { status: "failed", error: message };
  }
}

// ── Solo lane ───────────────────────────────────────────────

/**
 * Single-expert express lane.
 *
 * Fanning four specialists out on a typo fix is pure waste, and a system that
 * always pays the full price gets abandoned by day three. The pipeline has to be
 * able to opt out of itself.
 */
async function runSolo(ctx: Ctx): Promise<void> {
  setPhase(ctx, "draft");
  const expert = pick(ctx.roster, "maker") ?? ctx.roster[0]?.expert;
  if (!expert) throw new Error("no expert available for solo mode");

  const res = await runOne({
    store: ctx.store,
    runId: ctx.run.id,
    expert,
    kind: "draft",
    subTaskId: null,
    prompt: soloPrompt({ run: ctx.run, expert, repoPath: ctx.repoPath }),
    cwd: ctx.repoPath,
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });
  if (!res.ok) throw new Error(res.error ?? "solo attempt failed");
  log(ctx, "solo:done", { output: res.output.slice(0, 4000) });

  /*
   * Solo mode still verifies.
   *
   * The phase used to be set to "verify" and then nothing ran — the rail in the
   * UI claimed a verification that never happened. Skipping review is the point
   * of this lane; skipping the build and the tests is not, because that is the
   * one measurement telling the user whether the change actually works.
   *
   * A different expert is preferred so the check is not the author grading
   * itself, but the author is accepted rather than skipping verification when
   * only one runtime is installed.
   */
  setPhase(ctx, "verify");
  const verifier =
    pickReviewers(ctx.roster, expert.id)[0] ??
    pick(ctx.roster, "verifier") ??
    expert;

  const check = await runOne({
    store: ctx.store,
    runId: ctx.run.id,
    expert: verifier,
    kind: "verify",
    subTaskId: null,
    prompt: verifyPrompt({
      run: ctx.run,
      repoPath: ctx.repoPath,
      mergedSummary: `A single expert (${expert.name}) worked directly in the repository. Its own summary:\n\n${res.output.slice(0, 4000)}`,
    }),
    cwd: ctx.repoPath,
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });
  log(ctx, "verify:done", {
    ok: check.ok,
    report: check.output.slice(0, 8000),
    error: check.error,
    selfVerified: verifier.id === expert.id,
  });
}

// ── Phase 1: plan ───────────────────────────────────────────

async function phasePlan(ctx: Ctx, autoApprove: boolean): Promise<boolean> {
  setPhase(ctx, "plan");
  const orchestrator = pick(ctx.roster, "orchestrator") ?? ctx.roster[0]?.expert;
  if (!orchestrator) throw new Error("team has no orchestrator");

  const { value: plan, error } = await runStructured({
    store: ctx.store,
    runId: ctx.run.id,
    expert: orchestrator,
    kind: "plan",
    subTaskId: null,
    prompt: planPrompt({ run: ctx.run, roster: ctx.roster, repoPath: ctx.repoPath }),
    cwd: ctx.repoPath,
    schema: PlanSchema,
    schemaJson: zodToJsonSchema(PlanSchema),
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });

  if (!plan) throw new Error(`planning failed: ${error ?? "no plan produced"}`);

  /*
   * Reconcile declared dependencies against stages before persisting.
   *
   * `stage` is the only ordering the executor honours; `dependsOn` used to be
   * stored and never read. A plan that placed two subtasks in the same stage and
   * declared a dependency between them therefore ran them in parallel in isolated
   * worktrees, and the downstream one could not see its prerequisite — silently,
   * with no error and a plausible-looking result.
   */
  const reconciled = enforceDependencyStages(plan.subtasks);
  if (reconciled.promoted.length > 0) {
    log(ctx, "plan:dependencies_reordered", { promoted: reconciled.promoted });
  }
  if (reconciled.cycle.length > 0) {
    // Refuse rather than execute an order that cannot satisfy its own plan.
    throw new Error(
      `the plan declares a circular dependency among: ${reconciled.cycle.join(", ")}`,
    );
  }

  // Persist the plan atomically: a half-written DAG would make the stage
  // barrier fire on an incomplete stage.
  ctx.store.tx(() => {
    for (const t of reconciled.tasks) {
      const maker = routeMaker(ctx.roster, t.capability);
      ctx.store.createSubTask({
        runId: ctx.run.id,
        stage: t.stage,
        title: t.title,
        brief: t.brief,
        acceptance: t.acceptance,
        capability: t.capability,
        assignedExpertId: maker?.id ?? null,
        dependsOn: t.dependsOn,
        status: "todo",
        worktreePath: null,
        branch: null,
      });
    }
  });

  log(ctx, "plan:ready", {
    summary: plan.summary,
    subtasks: plan.subtasks.map((t) => ({ title: t.title, stage: t.stage, capability: t.capability })),
  });

  if (autoApprove) return true;

  // The human gate. The run stops here until someone approves the shape of the
  // work — cheap to hold, expensive to skip.
  ctx.store.updateRun(ctx.run.id, { status: "blocked_on_human", gate: "plan_approval" });
  log(ctx, "gate:plan_approval", { subtaskCount: plan.subtasks.length });
  return false;
}

// ── Phase 2: staged execution ───────────────────────────────

/** Accumulated merge outcomes, reported by the verify phase. */
interface MergeLedger {
  merged: string[];
  conflicted: string[];
  unmergeable: string[];
  /** Subtask ids already merged, so a second pass cannot merge them twice. */
  mergedIds: Set<string>;
}

function newLedger(): MergeLedger {
  return { merged: [], conflicted: [], unmergeable: [], mergedIds: new Set() };
}

async function phaseStages(ctx: Ctx, ledger: MergeLedger): Promise<void> {
  /*
   * Clear worktree registrations left by a previous crash.
   *
   * A killed process skips dispose(), and git keeps the registration forever —
   * flagged `prunable`, but nothing prunes it. Measured: three interrupted
   * subtasks left three permanent stale entries in the USER'S repository, and
   * creating new worktrees did not clear them. Without this, every crash adds
   * litter that never goes away.
   *
   * Only entries whose directory is already gone are removed, so a worktree
   * belonging to a concurrently running run cannot be affected.
   */
  await pruneWorktrees(ctx.repoPath);

  const stages = ctx.store.stages(ctx.run.id);
  /*
   * Recomputed after every stage, NOT once up front.
   *
   * Staging exists so later work can build on earlier work. With a single base
   * ref computed before the loop, every stage branched off the same original
   * HEAD and merging only happened at the very end — so a stage-1 subtask could
   * not see stage-0's output at all, and the ordering the orchestrator had
   * carefully planned bought nothing. Each stage now lands before the next one
   * branches.
   */
  let baseRef = (await currentHead(ctx.repoPath)) ?? "HEAD";

  for (const stage of stages) {
    if (cancelled(ctx)) {
      // Neither start new work nor merge what exists: unreviewed output must not
      // land on the user's branch after they asked the run to stop.
      log(ctx, "stage:skipped_cancelled", { stage });
      return;
    }

    const subtasks = ctx.store.listSubTasks(ctx.run.id).filter((s) => s.stage === stage && s.status === "todo");

    if (subtasks.length === 0) {
      /*
       * Nothing left to execute here, but the stage may still need MERGING.
       *
       * This used to `continue`, which skipped the merge entirely — so a subtask
       * finished on a resumed run (after a human ruling, say) had its work
       * silently abandoned on its branch. `mergeStage` is idempotent via
       * ledger.mergedIds, so re-entering a stage is safe.
       */
      await mergeStage(ctx, stage, ledger);
      baseRef = (await currentHead(ctx.repoPath)) ?? baseRef;
      continue;
    }

    log(ctx, "stage:started", { stage, count: subtasks.length });

    /*
     * Parallel within a stage, but BOUNDED. The barrier below is what makes the
     * next stage safe to start.
     *
     * Each unit here is a whole coding-CLI process that then spawns its own
     * reviewers, so unbounded fan-out on a six-subtask stage meant six execution
     * processes plus twelve review processes at once — enough to thrash the
     * machine and to trip provider rate limits, which then look like adapter
     * failures rather than the resource problem they are.
     *
     * Settled results in input order, so one failure cannot abort its siblings
     * mid-edit and leave orphaned worktrees.
     */
    const results = await mapLimit(subtasks, ctx.maxConcurrent, (s) => runSubTask(ctx, s, baseRef));

    for (const [i, r] of results.entries()) {
      const s = subtasks[i];
      if (!s) continue;
      if (r.status === "rejected") {
        const message = r.reason instanceof Error ? r.reason.message : String(r.reason);
        ctx.store.updateSubTask(s.id, { status: "failed" });
        log(ctx, "subtask:failed", { subTaskId: s.id, title: s.title, message });
        // A budget breach must stop the whole run, not just this subtask.
        if (r.reason instanceof BudgetExceededError) throw r.reason;
      }
    }

    // The barrier. This is Multica's staged child-done wake, and precisely what
    // Raft documents it does NOT do — leaving its human to hold work back.
    if (!ctx.store.stageComplete(ctx.run.id, stage)) {
      throw new Error(`stage ${stage} did not reach a terminal state for every subtask`);
    }
    log(ctx, "stage:barrier_cleared", { stage });

    // Land this stage before the next one branches, so downstream work actually
    // builds on upstream work rather than on a stale snapshot.
    await mergeStage(ctx, stage, ledger);
    baseRef = (await currentHead(ctx.repoPath)) ?? baseRef;
  }
}

/**
 * Merges every accepted subtask in one stage into the working branch.
 *
 * Only `done` subtasks are merged. A subtask sitting in `in_review` has real
 * work on its branch but unresolved findings against it, and making rejected
 * work the foundation for the next stage is worse than making the next stage
 * start from less — so it stays on its branch and is reported to the human
 * instead.
 */
async function mergeStage(ctx: Ctx, stage: number, ledger: MergeLedger): Promise<void> {
  const accepted = ctx.store
    .listSubTasks(ctx.run.id)
    .filter((s) => s.stage === stage && s.status === "done");

  for (const s of accepted) {
    // Idempotent: a stage can be revisited (a resumed run re-walks every stage),
    // and merging the same branch twice would either fail or duplicate history.
    if (ledger.mergedIds.has(s.id)) continue;

    // Read the branch from the subtask row, not from the event log. Digging it
    // out of events was unsound: a real run emits tens of thousands of them, so
    // any read cap silently drops the record and the work vanished with no error.
    if (s.branch === null) {
      ledger.unmergeable.push(s.title);
      log(ctx, "merge:no_branch", { subTaskId: s.id, title: s.title });
      continue;
    }
    const res = await mergeBranch(ctx.repoPath, s.branch);
    if (res.code === 0) {
      ledger.mergedIds.add(s.id);
      ledger.merged.push(`${s.title} (${s.branch})`);
      log(ctx, "merge:ok", { subTaskId: s.id, stage, branch: s.branch });
      /*
       * Delete only now that the commits are reachable from the working branch.
       *
       * Uses git's own merged-check (`branch -d`), so it is a no-op exactly when
       * deleting would lose work. Without this the user's repository accumulates
       * a `council/*` branch per subtask forever — measured: four leftover
       * branches after a handful of runs, with nothing ever removing them.
       */
      await deleteBranchIfMerged(ctx.repoPath, s.branch);
    } else {
      ledger.conflicted.push(`${s.title} (${s.branch}): ${res.stderr.trim().slice(0, 400)}`);
      log(ctx, "merge:conflict", {
        subTaskId: s.id,
        stage,
        branch: s.branch,
        stderr: res.stderr.slice(0, 1000),
      });
      // Leave the tree clean: a half-applied merge would poison every later
      // stage, which all branch from this same HEAD.
      await git(["merge", "--abort"], ctx.repoPath);
    }
  }
}

/** One subtask: draft → review → repro → rebuttal → discuss → adjudicate. */
async function runSubTask(
  ctx: Ctx,
  subTask: SubTask,
  baseRef: string,
  /**
   * Set when restarting a subtask that was blocked on a human ruling.
   *
   * `fromBranch` is the subtask's OWN branch, so the previous attempt is present
   * in the new worktree. Branching from the run's base instead would discard that
   * work and contradict the rework brief, which tells the author its earlier
   * attempt is already there and not to start over.
   */
  resume?: { humanDecision: string; fromBranch: string },
): Promise<void> {
  const author =
    (subTask.assignedExpertId ? ctx.store.getExpert(subTask.assignedExpertId) : null) ??
    routeMaker(ctx.roster, subTask.capability);
  if (!author) throw new Error(`no maker available for subtask ${subTask.title}`);

  let worktree: Worktree | null = null;
  try {
    worktree = await createWorktree(
      ctx.repoPath,
      subTask.title || subTask.id,
      resume?.fromBranch ?? baseRef,
    );
    ctx.store.updateSubTask(subTask.id, {
      status: "running",
      worktreePath: worktree.path,
      // Recorded now, not at disposal: if this subtask crashes mid-draft the
      // branch still exists and stays recoverable.
      branch: worktree.branch,
      assignedExpertId: author.id,
    });
    log(ctx, "subtask:started", {
      subTaskId: subTask.id,
      title: subTask.title,
      expertId: author.id,
      expertName: author.name,
      runtimeKind: author.runtimeKind,
      worktree: worktree.path,
      branch: worktree.branch,
    });

    let round = 1;
    /**
     * What the previous round concluded. Undefined on the first pass.
     *
     * Without this, a rework round re-sent the ORIGINAL prompt verbatim: the agent
     * was told to do the same task again, in a fresh session, with no idea what
     * any reviewer had said. A full agent turn for zero new information, while the
     * round counter and the `rework` verdict made the loop look functional.
     */
    let reworkContext: ReworkContext | undefined;

    if (resume) {
      /*
       * Seed the first turn with the human's ruling.
       *
       * Without this the decision would sit in the database unread — the run
       * stopped, asked a person, got an answer, and then handed the agent nothing.
       * The prior findings come along too: the author needs to know which dispute
       * was ruled on, not just the verdict text.
       */
      const priorRounds = ctx.store.listAdjudications(ctx.run.id).filter((a) => a.subTaskId === subTask.id);
      const prior = ctx.store.listReviewsForSubTask(subTask.id).filter(isBlocking);
      round = Math.max(1, ...priorRounds.map((a) => a.round)) + 1;
      reworkContext = {
        round,
        reviews: prior,
        rebuttals: ctx.store.listRebuttals(prior.map((r) => r.id)),
        rationale: priorRounds.at(-1)?.rationale ?? null,
        humanDecision: resume.humanDecision,
        nameOf: (id) => ctx.store.getExpert(id)?.name ?? id.slice(0, 8),
      };
      // Still bounded: the MAX_ROUNDS check below applies, so a ruling buys one
      // attempt rather than reopening an unbounded loop.
      log(ctx, "subtask:resumed_after_ruling", { subTaskId: subTask.id, round });
    }

    for (;;) {
      // ── draft / rework ──
      setPhaseSafe(ctx, "draft");
      const draft = await runOne({
        store: ctx.store,
        runId: ctx.run.id,
        expert: author,
        kind: "draft",
        subTaskId: subTask.id,
        prompt: draftPrompt({
          run: ctx.run,
          subTask,
          expert: author,
          ...(reworkContext ? { rework: reworkContext } : {}),
        }),
        cwd: worktree.path,
        slots: ctx.slots,
        ...(ctx.signal ? { signal: ctx.signal } : {}),
        ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
      });
      if (!draft.ok) throw new Error(draft.error ?? "draft failed");

      await commitAll(worktree.path, `council: ${subTask.title} (round ${round})`);
      const diff = await diffAgainst(worktree.path, baseRef);
      log(ctx, "subtask:drafted", {
        subTaskId: subTask.id,
        round,
        diffBytes: diff.length,
        summary: draft.output.slice(0, 2000),
      });

      // ── review (parallel, independent) ──
      setPhaseSafe(ctx, "review");
      const reviews = await collectReviews(ctx, subTask, author, diff, round, worktree.path);

      // ── repro: settle verifiable claims by experiment ──
      await settleVerifiableClaims(ctx, subTask, reviews, worktree.path);

      const fresh = ctx.store.listReviewsForSubTask(subTask.id, round);
      const blocking = fresh.filter(isBlocking);

      if (blocking.length === 0) {
        ctx.store.updateSubTask(subTask.id, { status: "done" });
        log(ctx, "subtask:accepted", { subTaskId: subTask.id, round, reason: "no blocking findings" });
        return;
      }

      // ── rebuttal ──
      setPhaseSafe(ctx, "rebuttal");
      await collectRebuttals(ctx, subTask, author, blocking, worktree.path);

      // ── discussion: only for what a test cannot settle ──
      const unresolved = blocking.filter((r) => !r.verifiable || r.reproOutcome === "inconclusive");
      if (unresolved.length > 0) {
        await runDiscussion(ctx, subTask, unresolved, round);
      }

      // ── adjudicate ──
      setPhaseSafe(ctx, "adjudicate");
      const verdict = await adjudicate(ctx, subTask, fresh, round);

      if (verdict === "proceed") {
        ctx.store.updateSubTask(subTask.id, { status: "done" });
        log(ctx, "subtask:accepted", { subTaskId: subTask.id, round, reason: "adjudicated proceed" });
        return;
      }
      if (verdict === "escalate") {
        ctx.store.updateSubTask(subTask.id, { status: "blocked" });
        ctx.store.updateRun(ctx.run.id, { status: "blocked_on_human", gate: "adjudication" });
        log(ctx, "gate:adjudication", { subTaskId: subTask.id, round });
        return;
      }
      if (round >= MAX_ROUNDS) {
        // Bounded by construction: the loop cannot run forever, and the human
        // gets the work as it stands plus the open findings.
        ctx.store.updateSubTask(subTask.id, { status: "in_review" });
        log(ctx, "subtask:rounds_exhausted", { subTaskId: subTask.id, rounds: round });
        return;
      }
      round++;
      ctx.store.updateSubTask(subTask.id, { status: "reworking" });
      ctx.store.updateRun(ctx.run.id, { round });

      /*
       * Carry the round's conclusions into the next draft.
       *
       * This is what makes a rework round worth its cost. Without it the loop
       * re-sent the original prompt to a fresh session: same task, no idea what
       * any reviewer said, no memory of its own rebuttal. A full agent turn for
       * zero new information, while the round counter made it look like progress.
       */
      const verdictRecord = ctx.store
        .listAdjudications(ctx.run.id)
        .filter((a) => a.subTaskId === subTask.id && a.round === round - 1)
        .at(-1);
      reworkContext = {
        round,
        // `blocking` already excludes nits and refuted claims, so the author is
        // handed only what actually held up the work.
        reviews: blocking,
        rebuttals: ctx.store.listRebuttals(blocking.map((r) => r.id)),
        rationale: verdictRecord?.rationale ?? null,
        humanDecision: verdictRecord?.humanDecision ?? null,
        nameOf: (id) => ctx.store.getExpert(id)?.name ?? id.slice(0, 8),
      };

      log(ctx, "subtask:rework", {
        subTaskId: subTask.id,
        nextRound: round,
        carriedFindings: blocking.length,
      });
    }
  } finally {
    // Commit before disposal so the branch survives; the worktree directory is
    // disposable, the branch is the deliverable.
    if (worktree) {
      await commitAll(worktree.path, `council: ${subTask.title} (final)`).catch(() => null);
      const st = ctx.store.getSubTask(subTask.id);
      if (st) {
        recordEvent(ctx.store, ctx.run.id, null, "subtask:branch_ready", {
          subTaskId: subTask.id,
          branch: worktree.branch,
          status: st.status,
        });
      }
      await worktree.dispose().catch(() => undefined);
    }
  }
}

/**
 * Has the user asked this run to stop?
 *
 * Checked between phases because cancellation only aborts the agent SUBPROCESS —
 * the surrounding orchestration kept going. The dangerous consequence was in
 * merging: pressing Stop still let half-finished, unreviewed work land on the
 * user's working branch, which is not reversible by pressing anything.
 */
function cancelled(ctx: Ctx): boolean {
  if (ctx.signal?.aborted === true) return true;
  // Also honour a cancel that arrived via the API rather than this signal.
  return ctx.store.getRun(ctx.run.id)?.status === "cancelled";
}

/**
 * Refuses to restart a run the user has already stopped or finished.
 *
 * Both resume paths began by writing `status: "running"`, which RESURRECTED a
 * cancelled run: cancelling does not clear the gate, so the UI still offered
 * "approve plan" on a stopped run, and pressing it carried on as if nothing had
 * happened. Checked before that write, not after.
 */
function assertResumable(run: Run): void {
  if (run.status === "cancelled") {
    throw new Error("this run was cancelled; start a new one instead of resuming it");
  }
  if (run.status === "completed") {
    throw new Error("this run has already finished");
  }
}

/** Phase is a run-level display value; concurrent subtasks race it harmlessly. */
function setPhaseSafe(ctx: Ctx, phase: Run["phase"]): void {
  ctx.store.updateRun(ctx.run.id, { phase });
  ctx.run = { ...ctx.run, phase };
}

/**
 * Independent review of one subtask's output.
 *
 * `cwd` is the WORKTREE, not the main repository. Reviewers were originally run
 * from the repo root, which produced confidently-wrong findings: the work lives
 * on a worktree branch, so a reviewer that checked the filesystem saw no changed
 * files at all and reported "the diff was never delivered" as a blocker. The
 * reproduction step then refuted its own reviewer's claim, having been pointed at
 * the correct tree — costing a full rework round on a phantom defect.
 */
async function collectReviews(
  ctx: Ctx,
  subTask: SubTask,
  author: Expert,
  diff: string,
  round: number,
  worktreePath: string,
): Promise<Review[]> {
  const reviewers = pickReviewers(ctx.roster, author.id);
  if (reviewers.length === 0) {
    log(ctx, "review:skipped", { subTaskId: subTask.id, reason: "no reviewer other than the author" });
    return [];
  }

  /*
   * Reviewers must not see each other's findings. Independence is the entire
   * value of paying for several vendors; sequential review with shared context
   * would just produce agreement with whoever went first.
   *
   * Bounded for the same reason the stage fan-out is. Note the peak is
   * multiplicative: up to `maxConcurrent` subtasks, each with up to
   * REVIEWERS_PER_SUBTASK reviewers in flight. Both factors are small and
   * configurable, but the product is what actually lands on the machine.
   */
  const settled = await mapLimit(reviewers, ctx.maxConcurrent, (reviewer) =>
    runStructured({
      store: ctx.store,
      runId: ctx.run.id,
      expert: reviewer,
      kind: "review",
      subTaskId: subTask.id,
      prompt: reviewPrompt({ run: ctx.run, subTask, diff, authorName: author.name, reviewer }),
      cwd: worktreePath,
      schema: ReviewSchema,
      schemaJson: zodToJsonSchema(ReviewSchema),
      // The reason the semaphore exists: reviewers fan out INSIDE a fan-out of
      // subtasks, so capping each level separately left the peak multiplicative.
      slots: ctx.slots,
      ...(ctx.signal ? { signal: ctx.signal } : {}),
      ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
    }).then((r) => ({ reviewer, out: r })),
  );

  const created: Review[] = [];
  for (const s of settled) {
    if (s.status === "rejected") {
      if (s.reason instanceof BudgetExceededError) throw s.reason;
      log(ctx, "review:errored", {
        subTaskId: subTask.id,
        message: s.reason instanceof Error ? s.reason.message : String(s.reason),
      });
      continue;
    }
    const { reviewer, out } = s.value;
    if (!out.value) {
      log(ctx, "review:unparsed", { subTaskId: subTask.id, reviewerId: reviewer.id, error: out.error });
      continue;
    }
    for (const f of out.value.findings) {
      created.push(
        ctx.store.createReview({
          runId: ctx.run.id,
          subTaskId: subTask.id,
          reviewerExpertId: reviewer.id,
          round,
          severity: f.severity,
          claim: f.claim,
          evidence: f.evidence,
          verifiable: f.verifiable,
          suggestedTest: f.suggestedTest,
          patch: f.patch,
          reproOutcome: null,
        }),
      );
    }
    log(ctx, "review:done", {
      subTaskId: subTask.id,
      reviewerId: reviewer.id,
      reviewerName: reviewer.name,
      overall: out.value.overall,
      findings: out.value.findings.length,
    });
  }
  return created;
}

/**
 * Turns checkable claims into evidence.
 *
 * This is the rule the whole discussion design rests on: a dispute a test can
 * settle should be settled by a test, not by three more model turns. A reviewer
 * who says "this races" is asked to produce a failing reproduction — red means
 * real, green means they were wrong. One repro beats several rounds of debate,
 * and it keeps human attention for the judgment calls only.
 */
async function settleVerifiableClaims(
  ctx: Ctx,
  subTask: SubTask,
  reviews: Review[],
  worktreePath: string,
): Promise<void> {
  const checkable = reviews.filter(
    (r) => r.verifiable && r.reproOutcome === null && r.severity !== "nit",
  );
  if (checkable.length === 0) return;

  const verifier = pick(ctx.roster, "verifier") ?? pick(ctx.roster, "reviewer");
  if (!verifier) {
    log(ctx, "repro:skipped", { subTaskId: subTask.id, reason: "no verifier in roster" });
    return;
  }

  for (const review of checkable) {
    try {
      const { value } = await runStructured({
        store: ctx.store,
        runId: ctx.run.id,
        expert: verifier,
        kind: "repro",
        subTaskId: subTask.id,
        prompt: reproPrompt({ subTask, review, worktreePath }),
        cwd: worktreePath,
        schema: ReproSchema,
        schemaJson: zodToJsonSchema(ReproSchema),
        slots: ctx.slots,
        ...(ctx.signal ? { signal: ctx.signal } : {}),
        ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
      });
      if (!value) continue;
      ctx.store.setReproOutcome(review.id, value.outcome, value.evidence.slice(0, 8000));
      log(ctx, "repro:settled", {
        subTaskId: subTask.id,
        reviewId: review.id,
        outcome: value.outcome,
        claim: review.claim,
      });
      // A refuted claim stops blocking: the evidence is in, and leaving it to
      // argue about would waste the rebuttal and adjudication turns.
      if (value.outcome === "refuted") {
        log(ctx, "repro:dismissed", { reviewId: review.id, claim: review.claim });
      }
    } catch (err) {
      if (err instanceof BudgetExceededError) throw err;
      log(ctx, "repro:errored", {
        reviewId: review.id,
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }
}

/**
 * The author's response to blocking findings.
 *
 * Runs in the worktree for the same reason review does: the author needs to be
 * able to re-check its own work while deciding whether to concede a point, and
 * from the repo root that work is invisible.
 */
async function collectRebuttals(
  ctx: Ctx,
  subTask: SubTask,
  author: Expert,
  blocking: Review[],
  worktreePath: string,
): Promise<void> {
  const { value } = await runStructured({
    store: ctx.store,
    runId: ctx.run.id,
    expert: author,
    kind: "rebuttal",
    subTaskId: subTask.id,
    prompt: rebuttalPrompt({ subTask, reviews: blocking, author }),
    cwd: worktreePath,
    schema: RebuttalSchema,
    schemaJson: zodToJsonSchema(RebuttalSchema),
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });
  if (!value) return;

  const valid = new Set(blocking.map((r) => r.id));
  for (const r of value.responses) {
    // Ignore invented ids rather than trusting the model's bookkeeping.
    if (!valid.has(r.reviewId)) continue;
    ctx.store.createRebuttal({
      reviewId: r.reviewId,
      authorExpertId: author.id,
      decision: r.decision,
      reason: r.reason,
    });
  }
  log(ctx, "rebuttal:done", { subTaskId: subTask.id, responses: value.responses.length });
}

async function adjudicate(
  ctx: Ctx,
  subTask: SubTask,
  reviews: Review[],
  round: number,
): Promise<"proceed" | "rework" | "escalate"> {
  const orchestrator = pick(ctx.roster, "orchestrator") ?? ctx.roster[0]?.expert;
  if (!orchestrator) return "proceed";

  const rebuttals = ctx.store.listRebuttals(reviews.map((r) => r.id));
  // Discussion turns for THIS subtask. Without them the orchestrator decided
  // blind: specialists debated a judgment call and their conclusion never
  // reached the verdict, so the tokens bought nothing.
  const discussion = ctx.store.listDiscussion(ctx.run.id).filter((m) => m.subTaskId === subTask.id);
  const { value } = await runStructured({
    store: ctx.store,
    runId: ctx.run.id,
    expert: orchestrator,
    kind: "adjudicate",
    subTaskId: subTask.id,
    prompt: adjudicatePrompt({
      run: ctx.run,
      subTask,
      reviews,
      rebuttals,
      discussion,
      nameOf: (id) => ctx.store.getExpert(id)?.name ?? id.slice(0, 8),
      round,
      maxRounds: MAX_ROUNDS,
    }),
    cwd: ctx.repoPath,
    schema: AdjudicationSchema,
    schemaJson: zodToJsonSchema(AdjudicationSchema),
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });

  if (!value) {
    // An unreadable verdict must not silently accept the work.
    log(ctx, "adjudicate:unparsed", { subTaskId: subTask.id, round });
    return round >= MAX_ROUNDS ? "escalate" : "rework";
  }

  ctx.store.createAdjudication({
    runId: ctx.run.id,
    subTaskId: subTask.id,
    round,
    verdict: value.verdict,
    rationale: value.rationale,
    escalatedToHuman: value.verdict === "escalate",
    humanDecision: null,
  });
  log(ctx, "adjudicate:done", {
    subTaskId: subTask.id,
    round,
    verdict: value.verdict,
    rationale: value.rationale,
    escalations: value.escalations,
  });
  return value.verdict;
}

// ── Discussion ──────────────────────────────────────────────

/**
 * A bounded, structured exchange between specialists.
 *
 * Bounded is the design, not a limitation. Termination is by round cap or by
 * participants explicitly having nothing to add — never "until they agree",
 * which is not a decidable condition. Only points a test could not settle get
 * here, so the tokens buy judgment rather than re-litigating measurable facts.
 */
export async function runDiscussion(
  ctx: Ctx,
  subTask: SubTask,
  unresolved: Review[],
  round: number,
): Promise<void> {
  const speakers = ctx.roster
    .map((r) => r.expert)
    .filter((e, i, arr) => arr.findIndex((x) => x.id === e.id) === i);
  if (speakers.length < 2) return;

  const nameOf = (id: string): string => ctx.store.getExpert(id)?.name ?? id.slice(0, 8);
  log(ctx, "discussion:started", {
    subTaskId: subTask.id,
    round,
    points: unresolved.map((r) => r.claim),
    speakers: speakers.map((s) => s.name),
  });

  for (let dr = 1; dr <= MAX_DISCUSSION_ROUNDS; dr++) {
    let contributions = 0;
    for (const speaker of speakers) {
      const history = ctx.store.listDiscussion(ctx.run.id).filter((m) => m.subTaskId === subTask.id);
      let res;
      try {
        res = await runOne({
          store: ctx.store,
          runId: ctx.run.id,
          expert: speaker,
          kind: "discuss",
          subTaskId: subTask.id,
          prompt: discussPrompt({
            run: ctx.run,
            subTask,
            speaker,
            reviews: unresolved,
            history,
            nameOf,
            round: dr,
            maxRounds: MAX_DISCUSSION_ROUNDS,
          }),
          cwd: ctx.repoPath,
          slots: ctx.slots,
          ...(ctx.signal ? { signal: ctx.signal } : {}),
          ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
        });
      } catch (err) {
        if (err instanceof BudgetExceededError) throw err;
        log(ctx, "discussion:errored", {
          speakerId: speaker.id,
          message: err instanceof Error ? err.message : String(err),
        });
        continue;
      }
      if (!res.ok) continue;

      const body = res.output.trim();
      if (body.length === 0 || /^NOTHING TO ADD\b/i.test(body)) {
        log(ctx, "discussion:pass", { subTaskId: subTask.id, speakerId: speaker.id, round: dr });
        continue;
      }
      ctx.store.addDiscussion({
        runId: ctx.run.id,
        subTaskId: subTask.id,
        round: dr,
        authorExpertId: speaker.id,
        replyToId: history.at(-1)?.id ?? null,
        body: body.slice(0, 4000),
      });
      contributions++;
      log(ctx, "discussion:message", {
        subTaskId: subTask.id,
        round: dr,
        speakerId: speaker.id,
        speakerName: speaker.name,
        body: body.slice(0, 1200),
      });
    }
    // Convergence test: a full round where nobody had anything new to say.
    if (contributions === 0) {
      log(ctx, "discussion:converged", { subTaskId: subTask.id, afterRound: dr });
      break;
    }
  }
  log(ctx, "discussion:ended", { subTaskId: subTask.id });
}

// ── Phase 6: merge + verify ─────────────────────────────────

async function phaseVerify(ctx: Ctx, ledger: MergeLedger): Promise<void> {
  setPhase(ctx, "verify");

  // Merging already happened stage by stage, so each stage could build on the
  // last. This phase only reports the outcome and runs the final measurement.
  const { merged, conflicted, unmergeable } = ledger;

  // Work that finished but was never accepted stays on its branch rather than
  // being merged; naming it here is the difference between "left for you" and
  // silently losing it.
  for (const s of ctx.store.listSubTasks(ctx.run.id)) {
    if (s.status === "in_review" && s.branch !== null) {
      unmergeable.push(`${s.title} (${s.branch}): unresolved findings, left unmerged`);
    }
  }

  // Tidy the registrations for this run's disposed worktrees, then report any
  // council/* branches still holding work so the user knows what is recoverable
  // and where. Branches are never force-deleted — see deleteBranchIfMerged.
  await pruneWorktrees(ctx.repoPath);
  const leftover = await listCouncilBranches(ctx.repoPath);
  if (leftover.length > 0) {
    log(ctx, "branches:leftover", { branches: leftover });
  }

  if (conflicted.length > 0 || unmergeable.length > 0) {
    // Surfaced, never auto-resolved: a machine-picked conflict resolution is
    // exactly the kind of silent damage this system exists to avoid.
    log(ctx, "merge:needs_human", { conflicted, unmergeable });
  }

  if (cancelled(ctx)) {
    /*
     * Skip the verifier, but keep the branch report above.
     *
     * Verifying costs a full agent turn, and there is nothing to verify — the run
     * was stopped, so no merge happened. The report of what is left on which
     * branch is exactly what a user wants after cancelling, so that part stays.
     */
    log(ctx, "verify:skipped_cancelled", {});
    return;
  }

  const verifier = pick(ctx.roster, "verifier") ?? pick(ctx.roster, "reviewer") ?? ctx.roster[0]?.expert;
  if (!verifier) return;

  const summary = [
    merged.length > 0 ? `Merged:\n${merged.map((m) => `- ${m}`).join("\n")}` : "Nothing merged cleanly.",
    conflicted.length > 0 ? `\nConflicts left for a human:\n${conflicted.map((c) => `- ${c}`).join("\n")}` : "",
    // A subtask that finished with no branch means its work is gone. Reporting
    // "nothing merged" without naming it would read as "there was nothing to do".
    unmergeable.length > 0
      ? `\nFinished but produced no branch (work not recoverable):\n${unmergeable.map((u) => `- ${u}`).join("\n")}`
      : "",
  ].join("\n");

  const res = await runOne({
    store: ctx.store,
    runId: ctx.run.id,
    expert: verifier,
    kind: "verify",
    subTaskId: null,
    prompt: verifyPrompt({ run: ctx.run, repoPath: ctx.repoPath, mergedSummary: summary }),
    cwd: ctx.repoPath,
    slots: ctx.slots,
    ...(ctx.signal ? { signal: ctx.signal } : {}),
    ...(ctx.perAttemptTimeoutMs !== undefined ? { timeoutMs: ctx.perAttemptTimeoutMs } : {}),
  });
  log(ctx, "verify:done", { ok: res.ok, report: res.output.slice(0, 8000), error: res.error });
}

/**
 * Closes out a run without clobbering a gate it stopped at.
 *
 * Marking completed unconditionally was wrong: an escalated subtask parks the run
 * with `status: blocked_on_human` mid-flight, and the tail of the pipeline then
 * overwrote that with `completed`. The UI showed a finished run while a decision
 * was still pending — and since nothing resumes a "completed" run, the escalation
 * became unreachable.
 */
function finishRun(
  ctx: Ctx,
  store: Store,
  runId: string,
): { status: Run["status"]; error: string | null } {
  const current = store.getRun(runId);
  if (current?.status === "blocked_on_human") {
    log(ctx, "run:awaiting_human", { gate: current.gate });
    return { status: "blocked_on_human", error: null };
  }
  if (current?.status === "cancelled" || ctx.signal?.aborted === true) {
    // The signal is checked too: an abort mid-flight is a cancellation even if the
    // API row has not been written yet, and writing "completed" over it would
    // report success for work the user stopped.
    if (current?.status !== "cancelled") {
      ctx.store.updateRun(runId, { status: "cancelled", endedAt: new Date().toISOString() });
    }
    /*
     * A cancelled run must not report success.
     *
     * The cancel endpoint sets `cancelled` while the pipeline is still unwinding,
     * and this function then overwrote it with `completed` — so a user who pressed
     * Stop watched the run finish and be declared successful. Same class of bug as
     * the escalation gate being clobbered: the terminal state was decided
     * elsewhere and rewritten here.
     */
    log(ctx, "run:cancelled", {});
    return { status: "cancelled", error: null };
  }
  store.updateRun(runId, { status: "completed", endedAt: new Date().toISOString() });
  log(ctx, "run:completed", {});
  return { status: "completed", error: null };
}

/**
 * Records a human ruling and restarts the subtask that was waiting for it.
 *
 * This closes the escalation loop. Before it existed, the decision was written to
 * the database and read by nothing: the subtask stayed `blocked` forever, so the
 * system's central promise — a person settles what no test can — could be asked
 * but never answered.
 */
export async function resolveEscalationAndContinue(
  opts: PipelineOptions & { adjudicationId: string; decision: string },
): Promise<{ status: Run["status"]; error: string | null }> {
  const { store, runId } = opts;
  const run = store.getRun(runId);
  if (!run) throw new Error(`run not found: ${runId}`);

  // Same resurrection guard as the plan gate: cancelling does not clear the gate,
  // so the UI still offers this action on a stopped run.
  assertResumable(run);

  const adjudication = store.resolveEscalation(opts.adjudicationId, opts.decision);
  if (!adjudication) throw new Error(`adjudication not found: ${opts.adjudicationId}`);
  if (adjudication.runId !== runId) {
    // Guards against a client posting another run's adjudication id.
    throw new Error("that adjudication belongs to a different run");
  }

  const subTask = store.getSubTask(adjudication.subTaskId);
  if (!subTask) throw new Error(`subtask not found: ${adjudication.subTaskId}`);

  const project = store.getProject(run.projectId);
  if (!project) throw new Error("project not found");
  const roster = store.roster(project.teamId).map(({ member, expert }) => ({ role: member.role, expert }));

  store.updateRun(runId, { status: "running", gate: null });
  const ctx: Ctx = {
    store,
    run: { ...run, status: "running", gate: null },
    repoPath: project.repoPath,
    roster,
    ...makeSlots(opts.maxConcurrent),
    ...(opts.signal ? { signal: opts.signal } : {}),
    ...(opts.perAttemptTimeoutMs !== undefined ? { perAttemptTimeoutMs: opts.perAttemptTimeoutMs } : {}),
  };

  try {
    const baseRef = (await currentHead(ctx.repoPath)) ?? "HEAD";
    await runSubTask(ctx, subTask, baseRef, {
      humanDecision: opts.decision,
      // Its own branch, so the previous attempt is present rather than discarded.
      fromBranch: subTask.branch ?? baseRef,
    });

    const ledger = newLedger();
    // Later stages may still be waiting behind this one.
    await phaseStages(ctx, ledger);
    await phaseVerify(ctx, ledger);
    return finishRun(ctx, store, runId);
  } catch (err) {
    if (err instanceof BudgetExceededError) {
      store.updateRun(runId, { status: "budget_exceeded", error: err.message, endedAt: new Date().toISOString() });
      return { status: "budget_exceeded", error: err.message };
    }
    const message = err instanceof Error ? err.message : String(err);
    store.updateRun(runId, { status: "failed", error: message, endedAt: new Date().toISOString() });
    log(ctx, "run:failed", { message });
    return { status: "failed", error: message };
  }
}

/** Resumes a run that was parked at the plan-approval gate. */
export async function approvePlanAndContinue(opts: PipelineOptions): Promise<{ status: Run["status"]; error: string | null }> {
  const { store, runId } = opts;
  const run = store.getRun(runId);
  if (!run) throw new Error(`run not found: ${runId}`);
  if (run.gate !== "plan_approval") throw new Error(`run ${runId} is not waiting at the plan gate`);
  assertResumable(run);

  store.updateRun(runId, { status: "running", gate: null });
  const project = store.getProject(run.projectId);
  if (!project) throw new Error("project not found");

  const roster = store.roster(project.teamId).map(({ member, expert }) => ({ role: member.role, expert }));
  const ctx: Ctx = {
    store,
    run: { ...run, status: "running", gate: null },
    repoPath: project.repoPath,
    roster,
    ...makeSlots(opts.maxConcurrent),
    ...(opts.signal ? { signal: opts.signal } : {}),
    ...(opts.perAttemptTimeoutMs !== undefined ? { perAttemptTimeoutMs: opts.perAttemptTimeoutMs } : {}),
  };

  try {
    const ledger = newLedger();
    await phaseStages(ctx, ledger);
    await phaseVerify(ctx, ledger);
    // Same gate-preserving close-out as runPipeline: an escalation raised during
    // these phases must not be overwritten with "completed".
    return finishRun(ctx, store, runId);
  } catch (err) {
    if (err instanceof BudgetExceededError) {
      store.updateRun(runId, { status: "budget_exceeded", error: err.message, endedAt: new Date().toISOString() });
      return { status: "budget_exceeded", error: err.message };
    }
    const message = err instanceof Error ? err.message : String(err);
    store.updateRun(runId, { status: "failed", error: message, endedAt: new Date().toISOString() });
    log(ctx, "run:failed", { message });
    return { status: "failed", error: message };
  }
}
