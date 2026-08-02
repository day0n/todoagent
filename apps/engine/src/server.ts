import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";
import {
  Store,
  approvePlanAndContinue,
  bus,
  defaultDbPath,
  deliverMessage,
  detectAll,
  isGitRepo,
  resolveEscalationAndContinue,
  runDirect,
  runPipeline,
  type BusEvent,
} from "@todoagent/core";
import {
  EXPERT_ROLES,
  RUNTIME_KINDS,
  TASK_STATUSES,
  type Channel,
  type Expert,
  type Run,
  type Task,
  type TaskStatus,
} from "@todoagent/core/types";

const PORT = Number(process.env["TODOAGENT_PORT"] ?? 8787);
const store = new Store(defaultDbPath());
const app = new Hono();

/**
 * Localhost only, and deliberately unauthenticated.
 *
 * Every adapter runs its CLI with tool confirmation bypassed
 * (`--permission-mode bypassPermissions`, `--yolo`, `--always-approve`), which
 * is acceptable for a single-user tool on the loopback interface and dangerous
 * anywhere else: exposing this port lets anyone who can reach it execute
 * arbitrary code on this machine under your credentials. Adding auth is a
 * prerequisite for any non-loopback deployment.
 */
app.use("*", cors({ origin: ["http://localhost:3000", "http://127.0.0.1:3000"] }));

/** In-flight runs, so a second start cannot race the first. */
const active = new Map<string, AbortController>();

/**
 * Resolves runs the database still thinks are executing.
 *
 * `active` lives in memory, so after a crash or restart nothing is driving those
 * rows — but they still read as `running`. The UI then shows "in progress"
 * forever, and cancelling was impossible: that endpoint looked for an
 * AbortController that no longer existed and returned 409, leaving the user with
 * no way to either resume or clear the run.
 *
 * They are marked failed rather than silently deleted: the goal, the plan, the
 * reviews and the branches are all still there, and saying what happened is more
 * useful than pretending the run never existed.
 */
/**
 * Why a run cannot be resumed, or null if it can.
 *
 * Mirrors the orchestrator's own guard so the refusal is synchronous. The resume
 * endpoints hand work to a background promise and answer immediately, so an error
 * thrown in there reaches a console and never the user.
 */
/**
 * Is another run already working in this project's repository?
 *
 * `active` is keyed by run id, which only stopped the SAME run from being started
 * twice. Two different runs on one repository were free to proceed together — and
 * they both merge into the same working branch and both create worktrees off the
 * same HEAD. Concurrent git merges into one branch interleave and corrupt the
 * result, which no amount of retrying undoes.
 *
 * Returns the conflicting run's id, or null when the repository is free.
 */
function projectBusyWith(projectId: string, exceptRunId?: string): string | null {
  for (const activeRunId of active.keys()) {
    if (activeRunId === exceptRunId) continue;
    if (store.getRun(activeRunId)?.projectId === projectId) return activeRunId;
  }
  return null;
}

function resumeBlockedReason(run: Run): string | null {
  if (run.status === "cancelled") {
    return "this run was cancelled; start a new one instead of resuming it";
  }
  if (run.status === "completed") return "this run has already finished";
  if (run.status === "budget_exceeded") {
    return "this run exhausted its token budget; start a new one with a higher ceiling";
  }
  /*
   * The BUDGET is checked, not just the status.
   *
   * A run can be parked at a gate with its ceiling already breached — the last
   * turn before the gate can carry it over. Its status is `blocked_on_human`, so a
   * status-only check let the resume through: the ruling was recorded, the API
   * answered ok, and the pipeline then died in the background with
   * BudgetExceededError having spent nothing.
   *
   * That is the exact failure both call sites' comments exist to prevent, arriving
   * by a route those comments did not cover. It is worse than an ordinary error
   * here: the user has just written out a considered judgment and it is discarded
   * silently.
   *
   * Found on a real parked run: spent 2,110,081 of a 2,000,000 ceiling while
   * showing 需要你裁决 with a live submit button. Same condition `runOne` applies
   * before spawning, where zero means unlimited.
   */
  if (run.budgetTokens > 0 && run.spentTokens >= run.budgetTokens) {
    return `this run has already spent ${run.spentTokens.toLocaleString()} of its ${run.budgetTokens.toLocaleString()} token ceiling, so it cannot continue; start a new one with a higher budget`;
  }
  return null;
}

function reconcileOrphanedRuns(): void {
  const orphaned = store.listRunningRuns();
  if (orphaned.length === 0) return;
  for (const run of orphaned) {
    store.updateRun(run.id, {
      status: "failed",
      error:
        "The engine restarted while this run was executing, so it was interrupted. Any completed subtask work is still on its branch.",
      endedAt: new Date().toISOString(),
    });
    /*
     * The card is moved too, or a crash strands it permanently.
     *
     * A card started from the board sits at in_progress with a run id. Marking
     * only the RUN as failed leaves the board saying work is happening when
     * nothing is running, and there is no path out of it: the board's live-run
     * inference stays true forever, so it polls indefinitely watching a value
     * that will never change again.
     *
     * This is the fourth place a run reaches a terminal state — the other three
     * are launch and the two resume endpoints — and the only one that runs before
     * the server accepts traffic.
     */
    syncTaskFromRun(run.id);
  }
  console.log(`Reconciled ${orphaned.length} interrupted run(s) from a previous process.`);
}

// ── Health and runtimes ─────────────────────────────────────

app.get("/api/health", (c) => c.json({ ok: true, db: defaultDbPath(), activeRuns: active.size }));

app.get("/api/runtimes", async (c) => {
  const detected = await detectAll();
  return c.json({
    detected,
    // Detection proves the binary exists, nothing more — a CLI with expired
    // credentials looks identical here. The UI must say so.
    known: RUNTIME_KINDS,
    missing: RUNTIME_KINDS.filter((k) => !detected.some((d) => d.kind === k)),
  });
});

// ── Experts, teams, projects ────────────────────────────────

const ExpertBody = z.object({
  name: z.string().min(1).max(60),
  description: z.string().max(500).default(""),
  runtimeKind: z.enum(RUNTIME_KINDS as unknown as [string, ...string[]]),
  model: z.string().nullable().default(null),
  systemPrompt: z.string().max(20000).default(""),
  capabilities: z.array(z.string().min(1).max(60)).max(24).default([]),
});

app.get("/api/experts", (c) => c.json(store.listExperts()));

app.post("/api/experts", async (c) => {
  const parsed = ExpertBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  if (store.getExpertByName(parsed.data.name)) {
    return c.json({ error: `an expert named ${parsed.data.name} already exists` }, 409);
  }

  /*
   * The runtime has to exist on this machine.
   *
   * Same reasoning as the git check on projects: without it the expert is created
   * happily, joins the roster, gets routed work, and then every turn assigned to it
   * fails — at run time, far from the cause, after its stage-mates have already
   * spent real tokens.
   *
   * Detection only proves the binary is present; credentials can still be expired,
   * which is why the message points at `doctor --probe` rather than claiming the
   * runtime works.
   */
  const detected = await detectAll();
  if (!detected.some((d) => d.kind === parsed.data.runtimeKind)) {
    const available = detected.map((d) => d.kind).join(", ") || "none";
    return c.json(
      {
        error: `${parsed.data.runtimeKind} is not installed on this machine, so this expert could never run. Available: ${available}. Install its CLI and try again — then \`pnpm doctor --probe\` to confirm its credentials are valid.`,
      },
      400,
    );
  }

  const expert = store.createExpert({
    ...parsed.data,
    runtimeKind: parsed.data.runtimeKind as (typeof RUNTIME_KINDS)[number],
  });
  return c.json(expert, 201);
});

app.get("/api/teams", (c) =>
  c.json(
    store.listTeams().map((t) => ({
      ...t,
      members: store.roster(t.id).map(({ member, expert }) => ({
        role: member.role,
        expertId: expert.id,
        name: expert.name,
        runtimeKind: expert.runtimeKind,
        capabilities: expert.capabilities,
      })),
    })),
  ),
);

const TeamBody = z.object({
  name: z.string().min(1).max(60),
  members: z
    .array(
      z.object({
        expertId: z.string().min(1),
        role: z.enum(EXPERT_ROLES as unknown as [string, ...string[]]),
      }),
    )
    .default([]),
});

app.post("/api/teams", async (c) => {
  const parsed = TeamBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const existing = store.getTeamByName(parsed.data.name);
  if (existing) return c.json({ error: "team name already in use" }, 409);

  try {
    const team = store.tx(() => {
      const t = store.createTeam(parsed.data.name);
      for (const m of parsed.data.members) {
        if (!store.getExpert(m.expertId)) throw new Error(`unknown expert: ${m.expertId}`);
        store.addTeamMember(t.id, m.expertId, m.role as (typeof EXPERT_ROLES)[number]);
      }
      return t;
    });
    return c.json(team, 201);
  } catch (err) {
    return c.json({ error: err instanceof Error ? err.message : String(err) }, 400);
  }
});

app.get("/api/projects", (c) => c.json(store.listProjects()));

const ProjectBody = z.object({
  name: z.string().min(1).max(120),
  repoPath: z.string().min(1),
  teamId: z.string().min(1),
});

app.post("/api/projects", async (c) => {
  const parsed = ProjectBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  if (store.roster(parsed.data.teamId).length === 0) {
    return c.json({ error: "team has no members" }, 400);
  }

  /*
   * Resolved to an absolute path.
   *
   * A relative path would be interpreted against the ENGINE's working directory,
   * which the user cannot see or predict — so it would silently point somewhere
   * other than where they meant.
   */
  const repoPath = resolve(parsed.data.repoPath);

  /*
   * Validated here, not at run time.
   *
   * The pipeline refuses to run outside a git repository, because worktree
   * isolation is the only thing stopping parallel agents from overwriting each
   * other. Without this check the failure surfaced as far from its cause as
   * possible: the project was created happily and then every single run failed.
   */
  if (!(await isGitRepo(repoPath))) {
    return c.json(
      {
        error: `${repoPath} is not a git repository. TodoAgent isolates each subtask in a git worktree, so the project must be a repo (run \`git init\` there first).`,
      },
      400,
    );
  }

  return c.json(store.createProject({ ...parsed.data, repoPath }), 201);
});

// ── Runs ────────────────────────────────────────────────────

app.get("/api/runs", (c) => {
  const runs = store.listRuns(100);
  return c.json(
    runs.map((r) => {
      const project = store.getProject(r.projectId);
      return { ...r, projectName: project?.name ?? "(deleted)" };
    }),
  );
});

/** Everything the run view needs, in one round trip. */
app.get("/api/runs/:id", (c) => {
  const id = c.req.param("id");
  const run = store.getRun(id);
  if (!run) return c.json({ error: "not found" }, 404);

  const experts = new Map(store.listExperts().map((e) => [e.id, e]));
  const nameOf = (eid: string | null): string =>
    eid === null ? "" : (experts.get(eid)?.name ?? eid.slice(0, 8));

  return c.json({
    run,
    project: store.getProject(run.projectId),
    subtasks: store.listSubTasks(id).map((s) => ({ ...s, assigneeName: nameOf(s.assignedExpertId) })),
    /*
     * `output` is deliberately omitted.
     *
     * Measured on a realistic run (6 subtasks x 2 rounds): this endpoint returned
     * 292 KB, of which 211 KB — 72% — was attempt output that the UI never
     * renders. The client refetches on every structural event, so a single stage
     * moved ~11 MB to display nothing.
     *
     * The data is not lost: it stays in the DB, and the live text a user actually
     * watches arrives over SSE as `agent:text`. If a per-attempt transcript view
     * is ever wanted, it belongs behind its own endpoint rather than on every
     * poll of the whole run.
     */
    attempts: store.listAttempts(id).map(({ output, ...a }) => ({
      ...a,
      expertName: nameOf(a.expertId),
      // Size only, so the UI can indicate a transcript exists without shipping it.
      outputChars: output?.length ?? 0,
    })),
    reviews: store.listReviews(id).map((r) => ({ ...r, reviewerName: nameOf(r.reviewerExpertId) })),
    adjudications: store.listAdjudications(id),
    discussion: store.listDiscussion(id).map((m) => ({ ...m, authorName: nameOf(m.authorExpertId) })),
    active: active.has(id),
  });
});

/**
 * One attempt's full transcript, fetched on demand.
 *
 * The run overview strips `output` because it dominated the payload (211 KB of
 * 292 KB) for text it never renders. Without this endpoint that text was
 * unreachable: 72 transcripts sat in the database and reloading a finished run
 * showed no agent output at all, because the live cards only exist inside the SSE
 * session that produced them.
 */
app.get("/api/runs/:id/attempts/:attemptId", (c) => {
  const id = c.req.param("id");
  if (!store.getRun(id)) return c.json({ error: "not found" }, 404);

  const attempt = store.getAttempt(c.req.param("attemptId"));
  if (!attempt) return c.json({ error: "not found" }, 404);
  // Guards against reading another run's transcript by guessing an id.
  if (attempt.runId !== id) return c.json({ error: "not found" }, 404);

  const expert = store.getExpert(attempt.expertId);
  return c.json({ ...attempt, expertName: expert?.name ?? attempt.expertId.slice(0, 8) });
});

const RunBody = z.object({
  projectId: z.string().min(1),
  goal: z.string().min(1).max(20000),
  acceptance: z.string().max(20000).nullable().default(null),
  budgetTokens: z.number().int().min(0).max(200_000_000).default(2_000_000),
  soloMode: z.boolean().default(false),
  /** Skips the plan gate. Useful for automation; costly when the plan is wrong. */
  autoApprovePlan: z.boolean().default(false),
});

app.post("/api/runs", async (c) => {
  const parsed = RunBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const project = store.getProject(parsed.data.projectId);
  if (!project) return c.json({ error: "unknown project" }, 400);

  /*
   * One run per repository at a time.
   *
   * Two runs on the same project both merge into the same working branch and both
   * cut worktrees from the same HEAD. Concurrent git merges into one branch
   * interleave and corrupt the result — a failure the user cannot undo, unlike
   * simply being told to wait.
   */
  const busy = projectBusyWith(parsed.data.projectId);
  if (busy !== null) {
    return c.json(
      { error: `another run is already working in this repository (run ${busy})`, busyRunId: busy },
      409,
    );
  }

  const run = store.createRun(parsed.data);
  launch(run.id, parsed.data.autoApprovePlan);
  return c.json(run, 201);
});

/** Approves a parked plan and resumes the pipeline. */
app.post("/api/runs/:id/approve-plan", (c) => {
  const id = c.req.param("id");
  const run = store.getRun(id);
  if (!run) return c.json({ error: "not found" }, 404);
  if (run.gate !== "plan_approval") return c.json({ error: `run is not at the plan gate (gate=${run.gate})` }, 409);
  if (active.has(id)) return c.json({ error: "run already executing" }, 409);
  /*
   * Checked HERE, synchronously.
   *
   * The orchestrator refuses to resume a cancelled or finished run, but this
   * handler answers `ok: true` before that rejection happens and then logs it to
   * the console — so the user saw success while nothing ran. A predictable refusal
   * has to be an HTTP error, not a background log line.
   */
  const notResumable = resumeBlockedReason(run);
  if (notResumable !== null) return c.json({ error: notResumable }, 409);
  // Resuming re-enters the merge path, so it needs the same repository lock as a
  // fresh start.
  const busy = projectBusyWith(run.projectId, id);
  if (busy !== null) {
    return c.json({ error: `another run is working in this repository (run ${busy})` }, 409);
  }

  const controller = new AbortController();
  active.set(id, controller);
  void approvePlanAndContinue({ store, runId: id, signal: controller.signal })
    .catch((err: unknown) => {
      console.error(`[run ${id}] resume failed:`, err);
    })
    .finally(() => {
      active.delete(id);
      /*
       * The card is synced here too, and this is the path that matters most.
       *
       * The plan gate is ON by default, so a run started from a card parks almost
       * immediately and finishes through THIS resume rather than through `launch`.
       * Wiring only `launch` would leave every normally-completing card stuck at
       * in_progress — the common case, not an edge one.
       */
      syncTaskFromRun(id);
    });

  return c.json({ ok: true });
});

/** Records a human decision on an escalated judgment call. */
const EscalationBody = z.object({ adjudicationId: z.string().min(1), decision: z.string().min(1).max(8000) });

app.post("/api/runs/:id/resolve", async (c) => {
  const id = c.req.param("id");
  const run = store.getRun(id);
  if (!run) return c.json({ error: "not found" }, 404);
  const parsed = EscalationBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  // Same shape as approve-plan's gate check. Without it, a ruling posted at the
  // plan gate (or with gate cleared) answered ok and then ran the resume path,
  // clearing whatever gate was actually holding the run.
  if (run.gate !== "adjudication") {
    return c.json({ error: `run is not at the adjudication gate (gate=${run.gate})` }, 409);
  }
  if (active.has(id)) return c.json({ error: "run already executing" }, 409);
  // Synchronous refusal, same reason as the plan gate: this handler answers before
  // the orchestrator's own guard can reject, so the error would never reach the
  // user. Also prevents recording a ruling on a run that will never act on it.
  const notResumable = resumeBlockedReason(run);
  if (notResumable !== null) return c.json({ error: notResumable }, 409);
  // Acting on a ruling re-runs the stages and merges, so it takes the repository
  // lock too. Refused BEFORE the decision is recorded: storing a ruling that is
  // never acted on would make the record claim it was applied.
  const busy = projectBusyWith(run.projectId, id);
  if (busy !== null) {
    return c.json({ error: `another run is working in this repository (run ${busy})` }, 409);
  }
  /*
   * Checked HERE, synchronously — same class of hole as resumeBlockedReason.
   *
   * `resolveEscalationAndContinue` throws `adjudication not found` on a missing
   * id, but this handler used to answer `{ ok: true, resumed: true }` first and
   * only then run that check in a background promise. A forged id therefore
   * looked like success in the UI, after which `.catch` marked the whole run
   * `failed`. Verified with a probe: HTTP 200, then a background failure.
   *
   * Belonging to another run is the same timing trap: the write would land on
   * the foreign row, then the resume would throw and this run would be marked
   * failed for an id that was never its own.
   */
  const adjudication = store.getAdjudication(parsed.data.adjudicationId);
  if (!adjudication) {
    return c.json({ error: `adjudication not found: ${parsed.data.adjudicationId}` }, 404);
  }
  if (adjudication.runId !== id) {
    return c.json({ error: "that adjudication belongs to a different run" }, 409);
  }
  // The resume path needs the subtask immediately after writing the ruling. A
  // missing row used to be discovered only after `{ ok: true }`, with the decision
  // already persisted and the run then marked failed in `.catch`.
  if (!store.getSubTask(adjudication.subTaskId)) {
    return c.json({ error: `subtask not found: ${adjudication.subTaskId}` }, 404);
  }

  /*
   * Recording the decision is only half of it — the blocked subtask has to be
   * restarted with the ruling in hand.
   *
   * This endpoint used to write the decision and return, and nothing read it: the
   * subtask stayed `blocked` forever, so the system could ask a human to settle a
   * dispute but never act on the answer.
   */
  const controller = new AbortController();
  active.set(id, controller);
  void resolveEscalationAndContinue({
    store,
    runId: id,
    adjudicationId: parsed.data.adjudicationId,
    decision: parsed.data.decision,
    signal: controller.signal,
  })
    .then((res) => {
      console.log(`[run ${id}] resumed after ruling: ${res.status}${res.error ? `: ${res.error}` : ""}`);
    })
    .catch((err: unknown) => {
      console.error(`[run ${id}] resume after ruling failed:`, err);
      store.updateRun(id, {
        status: "failed",
        error: err instanceof Error ? err.message : String(err),
        endedAt: new Date().toISOString(),
      });
    })
    .finally(() => {
      active.delete(id);
      // The third and last path a run can reach a terminal state through. All
      // three sync, because a card that only tracks some of them is worse than
      // one that tracks none: it would be right often enough to be trusted.
      syncTaskFromRun(id);
    });

  return c.json({ ok: true, resumed: true });
});

app.post("/api/runs/:id/cancel", (c) => {
  const id = c.req.param("id");
  const run = store.getRun(id);
  if (!run) return c.json({ error: "not found" }, 404);

  const controller = active.get(id);
  if (controller) {
    controller.abort();
    // The gate is cleared too: a cancelled run is not waiting for anything, and
    // leaving it set kept offering "approve plan" / "submit decision" on a stopped
    // run — which then failed asynchronously after the API had already said ok.
    store.updateRun(id, { status: "cancelled", gate: null, endedAt: new Date().toISOString() });
    /*
     * Synced here rather than left to `launch`'s finally.
     *
     * That finally does fire eventually, but only once the aborted pipeline
     * actually settles — which can be tens of seconds while an agent CLI is
     * mid-turn. The person just clicked cancel; the card should move now.
     * `syncTaskFromRun` is idempotent, so the later call is a no-op.
     */
    syncTaskFromRun(id);
    return c.json({ ok: true, reaped: true });
  }

  /*
   * No controller, but the row is not finished: an orphan from a previous engine
   * process. Cancelling used to 409 here, which left the user stuck — the UI said
   * "in progress" and the only control offered refused to work. Nothing is
   * running, so marking it cancelled is both accurate and the way out.
   */
  if (run.status === "running" || run.status === "blocked_on_human") {
    store.updateRun(id, { status: "cancelled", gate: null, endedAt: new Date().toISOString() });
    /*
     * This is the path that NEEDS the sync, and it is a common one.
     *
     * Nothing is driving the run, so there is no `finally` anywhere that will fire
     * — the card would sit at in_progress permanently and the board would poll it
     * forever. A run parked at a gate is exactly this case: `approve-plan` creates
     * its own controller, which means the run is not in `active` while it waits.
     *
     * And the plan gate is on by default, so every card-started run parks there.
     * Reading the plan, deciding it is wrong, and cancelling is the ordinary way
     * to use this feature.
     */
    syncTaskFromRun(id);
    return c.json({ ok: true, reaped: false });
  }

  return c.json({ error: `run already finished (status=${run.status})` }, 409);
});

// ── SSE ─────────────────────────────────────────────────────

/**
 * Live event stream for one run.
 *
 * Replay is by `Last-Event-ID`: events are persisted before they are broadcast,
 * so a client that reconnects can always catch up from the table rather than
 * silently missing whatever happened while it was away.
 */
app.get("/api/runs/:id/events", (c) => {
  const id = c.req.param("id");
  if (!store.getRun(id)) return c.json({ error: "not found" }, 404);

  const lastHeader = c.req.header("Last-Event-ID") ?? c.req.query("lastEventId") ?? "0";
  const parsedLast = Number.parseInt(lastHeader, 10);
  let cursor = Number.isFinite(parsedLast) && parsedLast > 0 ? parsedLast : 0;

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let closed = false;
      const send = (ev: { id: number; type: string; payload: unknown; createdAt: string; attemptId: string | null }): void => {
        if (closed) return;
        /*
         * No `event:` field, deliberately.
         *
         * EventSource does NOT deliver a named event to `onmessage` — only to a
         * matching addEventListener. Naming them forced the client to keep an
         * allowlist of every event type, and that list silently drifts: any
         * event added here without a matching client entry is dropped with no
         * error anywhere. The type already travels inside `data`, so sending
         * everything as a default-type message removes the whole failure class.
         */
        const frame = `id: ${ev.id}\ndata: ${JSON.stringify({
          id: ev.id,
          type: ev.type,
          attemptId: ev.attemptId,
          payload: ev.payload,
          createdAt: ev.createdAt,
        })}\n\n`;
        try {
          controller.enqueue(encoder.encode(frame));
        } catch {
          closed = true;
        }
      };

      /*
       * Backlog first, in id order, DRAINED IN PAGES.
       *
       * A single capped read silently truncated long runs: the limit was 2000 and a
       * measured long run emits ~2880 events, so everything past the cap was never
       * sent. The tail is the worst part to lose — `verify:done`,
       * `merge:needs_human` and `run:completed` all arrive at the end, and the web
       * client derives the verification report and the conflict list from the
       * stream. Reopening a long finished run therefore showed no verification and
       * no conflicts, indistinguishable from a run that produced neither.
       */
      const PAGE = 1000;
      /*
       * A backstop, not a policy. Reaching it means something pathological, so it
       * reports itself rather than stopping quietly — silence would look exactly
       * like a complete replay.
       */
      const MAX_REPLAY = 100_000;
      let replayed = 0;
      for (;;) {
        const page = store.eventsAfter(id, cursor, PAGE);
        for (const ev of page) {
          send(ev);
          cursor = ev.id;
        }
        replayed += page.length;
        if (page.length < PAGE) break;
        if (replayed >= MAX_REPLAY) {
          send({
            id: cursor,
            attemptId: null,
            type: "replay:truncated",
            payload: { replayed, note: "history was too long to replay in full" },
            createdAt: new Date().toISOString(),
          });
          break;
        }
      }

      const unsub = bus.subscribe(id, (ev: BusEvent) => {
        // Drop anything already replayed — the backlog and the live feed overlap
        // by design, and a duplicate would render twice.
        if (ev.id <= cursor) return;
        cursor = ev.id;
        send(ev);
      });

      // Proxies and browsers drop an idle SSE connection; a comment frame keeps
      // it warm without polluting the event log.
      const heartbeat = setInterval(() => {
        if (closed) return;
        try {
          controller.enqueue(encoder.encode(": keepalive\n\n"));
        } catch {
          closed = true;
        }
      }, 15000);

      const shutdown = (): void => {
        closed = true;
        clearInterval(heartbeat);
        unsub();
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      };

      c.req.raw.signal.addEventListener("abort", shutdown, { once: true });
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
});

// ── Channels ────────────────────────────────────────────────
//
// Chat is the workspace. These endpoints sit above the execution layer: a
// message is durable conversation, and a task is a board card that MAY later
// point at a pipeline run. Nothing here starts agents on its own.

app.get("/api/channels", (c) => c.json(store.listChannels()));

const ChannelBody = z.object({
  name: z.string().min(1).max(120),
  purpose: z.string().max(500).default(""),
  kind: z.enum(["channel", "dm"]).default("channel"),
  projectId: z.string().min(1).nullable().default(null),
  dmExpertId: z.string().min(1).nullable().default(null),
});

app.post("/api/channels", async (c) => {
  const parsed = ChannelBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  /*
   * Referenced rows are checked here rather than trusted.
   *
   * The schema carries no foreign keys by design, so an unknown id would insert
   * happily and only surface later as a channel whose project cannot be loaded —
   * a channel that renders but can never run anything.
   */
  if (body.projectId !== null && !store.getProject(body.projectId)) {
    return c.json({ error: `unknown project ${body.projectId}` }, 400);
  }
  if (body.dmExpertId !== null && !store.getExpert(body.dmExpertId)) {
    return c.json({ error: `unknown expert ${body.dmExpertId}` }, 400);
  }
  // A DM is a conversation with somebody; without that id it is an empty room
  // wearing a person's name.
  if (body.kind === "dm" && body.dmExpertId === null) {
    return c.json({ error: "a dm needs dmExpertId" }, 400);
  }

  return c.json(store.createChannel(body), 201);
});

app.get("/api/channels/:id/messages", (c) => {
  const channel = store.getChannel(c.req.param("id"));
  if (!channel) return c.json({ error: "unknown channel" }, 404);

  const raw = Number(c.req.query("limit") ?? 200);
  // Clamped rather than trusted: this is the only unbounded read in the app, and
  // `?limit=1e9` on a long-lived channel would serialise the whole table.
  const limit = Number.isFinite(raw) ? Math.min(500, Math.max(1, Math.trunc(raw))) : 200;

  return c.json({
    channel,
    messages: store.listChannelMessages(channel.id, { limit }),
  });
});

const MessageBody = z.object({
  body: z.string().min(1).max(20_000),
  authorKind: z.enum(["human", "expert"]).default("human"),
  authorId: z.string().min(1).nullable().default(null),
  /** Thread root. Omitted or null posts into the channel itself. */
  parentId: z.string().min(1).nullable().default(null),
  /**
   * The composer's "as task" toggle.
   *
   * This is the join between chat and the board: one action both says the thing
   * and creates the card, so a request does not have to be restated as a task by
   * hand.
   */
  asTask: z.boolean().default(false),
});

app.post("/api/channels/:id/messages", async (c) => {
  const channel = store.getChannel(c.req.param("id"));
  if (!channel) return c.json({ error: "unknown channel" }, 404);

  const parsed = MessageBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  if (body.authorKind === "expert") {
    if (body.authorId === null) return c.json({ error: "an expert author needs authorId" }, 400);
    if (!store.getExpert(body.authorId)) {
      return c.json({ error: `unknown expert ${body.authorId}` }, 400);
    }
  }

  if (body.parentId !== null) {
    const parent = store.getMessage(body.parentId);
    if (!parent) return c.json({ error: `unknown parent ${body.parentId}` }, 400);
    // Cross-channel threading would put a message in a channel it does not
    // belong to, where it is invisible to that channel's own stream query.
    if (parent.channelId !== channel.id) {
      return c.json({ error: "parent belongs to another channel" }, 400);
    }
    /*
     * Threads are one level deep.
     *
     * Flattening a reply-to-a-reply onto the same root would silently move the
     * message somewhere the author did not point at. Refusing says so instead,
     * and matches what the reference product exposes.
     */
    if (parent.parentId !== null) {
      return c.json({ error: "threads are one level deep; reply to the root" }, 400);
    }
  }

  // One transaction, because a half-applied "say it and track it" leaves either
  // an untracked request or a card with no conversation behind it.
  const created = store.tx(() => {
    const message = store.createMessage({
      channelId: channel.id,
      authorKind: body.authorKind,
      authorId: body.authorKind === "expert" ? body.authorId : null,
      parentId: body.parentId,
      body: body.body,
    });

    if (!body.asTask) return { message, task: null };

    const task = store.createTask({
      channelId: channel.id,
      // A board card wants a line, not an essay. The full text stays on the
      // message this points back at, so nothing is lost by trimming here.
      title: taskTitleFrom(body.body),
      status: "todo",
      assigneeKind: null,
      assigneeId: null,
      creatorKind: body.authorKind,
      creatorId: body.authorKind === "expert" ? body.authorId : null,
      sourceMessageId: message.id,
      runId: null,
    });
    return { message, task };
  });

  /*
   * Replies are delivered in the BACKGROUND, after this response is sent.
   *
   * Awaiting them here would hold the POST open for as long as the agents take —
   * up to six turns at two minutes each — so the composer would appear frozen
   * while its own message had already been stored. The client polls the stream,
   * so replies simply appear, which is also what happens when an agent answers
   * something somebody else said.
   */
  deliverInBackground(channel.id, created.message.id);

  return c.json(created, 201);
});

/**
 * In-flight chat deliveries, so shutdown can cancel them.
 *
 * Keyed by message id: without this, SIGTERM would leave agent CLIs orphaned and
 * still writing replies into a database whose owner has exited.
 */
const deliveries = new Map<string, AbortController>();

function deliverInBackground(channelId: string, messageId: string): void {
  const channel = store.getChannel(channelId);
  const message = store.getMessage(messageId);
  if (!channel || !message) return;

  /*
   * The agent runs in the channel's repository when it has one, so it can read
   * the code it is being asked about. With no project there is no repo, and the
   * engine's own working directory would be an arbitrary place the user never
   * chose — so an isolated temp directory is used instead.
   *
   * This is NOT a sandbox. Every adapter runs its CLI with tool confirmation
   * bypassed, so a reply CAN edit files in that repo; the prompt asks it not to.
   * Work that should change code goes through the pipeline, where each subtask
   * gets its own worktree and nothing merges without review.
   */
  const project = channel.projectId === null ? null : store.getProject(channel.projectId);
  const cwd = project?.repoPath ?? tmpdir();

  const controller = new AbortController();
  deliveries.set(messageId, controller);

  void deliverMessage({
    store,
    message,
    channel,
    experts: store.listExperts(),
    cwd,
    signal: controller.signal,
  })
    .then((res) => {
      if (res.posted.length > 0 || res.failed.length > 0 || res.truncated) {
        console.log(
          `[chat ${channel.name}] ${res.posted.length} reply(ies)` +
            (res.failed.length > 0
              ? `, ${res.failed.length} failed: ${res.failed.map((f) => `${f.expertName} (${f.error})`).join("; ")}`
              : "") +
            (res.truncated ? ", truncated at the turn ceiling" : ""),
        );
      }
    })
    .catch((err: unknown) => {
      // A failed delivery must not take the process down: the user's own message
      // is already stored, and this is work happening on their behalf afterwards.
      console.error(`[chat ${channel.name}] delivery crashed:`, err);
    })
    .finally(() => deliveries.delete(messageId));
}

/** First line of a message, trimmed to a board-card length. */
function taskTitleFrom(body: string): string {
  const firstLine = body.split("\n", 1)[0]?.trim() ?? "";
  const source = firstLine.length > 0 ? firstLine : body.trim();
  return source.length <= 120 ? source : `${source.slice(0, 119)}…`;
}

app.get("/api/messages/:id/replies", (c) => {
  const message = store.getMessage(c.req.param("id"));
  if (!message) return c.json({ error: "unknown message" }, 404);
  return c.json({ root: message, replies: store.listThreadReplies(message.id) });
});

// ── Tasks ───────────────────────────────────────────────────

app.get("/api/channels/:id/tasks", (c) => {
  const channel = store.getChannel(c.req.param("id"));
  if (!channel) return c.json({ error: "unknown channel" }, 404);
  return c.json({ channel, board: store.board(channel.id), tasks: store.listTasks(channel.id) });
});

const TaskBody = z.object({
  /**
   * Titles, plural.
   *
   * The reference product's create dialog is a title field plus "Add Another",
   * so entering several at once is the normal case rather than a bulk-import
   * special case. Everything else about a task is set later, on the board.
   */
  titles: z.array(z.string().min(1).max(200)).min(1).max(50),
  creatorKind: z.enum(["human", "expert"]).default("human"),
  creatorId: z.string().min(1).nullable().default(null),
});

app.post("/api/channels/:id/tasks", async (c) => {
  const channel = store.getChannel(c.req.param("id"));
  if (!channel) return c.json({ error: "unknown channel" }, 404);

  const parsed = TaskBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  if (body.creatorKind === "expert" && body.creatorId !== null && !store.getExpert(body.creatorId)) {
    return c.json({ error: `unknown expert ${body.creatorId}` }, 400);
  }

  // All or none: a partial batch would leave the user comparing what they typed
  // against what appeared.
  const tasks = store.tx(() =>
    body.titles.map((title) =>
      store.createTask({
        channelId: channel.id,
        title: title.trim(),
        status: "todo",
        assigneeKind: null,
        assigneeId: null,
        creatorKind: body.creatorKind,
        creatorId: body.creatorKind === "expert" ? body.creatorId : null,
        sourceMessageId: null,
        runId: null,
      }),
    ),
  );

  return c.json(tasks, 201);
});

const TaskPatch = z.object({
  title: z.string().min(1).max(200).optional(),
  // `needs_you` is deliberately absent: only run outcomes and agent questions
  // park a task there. A person moves it out by answering, re-dispatching, or
  // closing it — never in by hand.
  status: z.enum(["todo", "in_progress", "in_review", "done"]).optional(),
  note: z.string().max(2000).optional(),
  /** ISO date to pin into 我的一天, or null to unpin. */
  myDay: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable().optional(),
  /**
   * Assignment, as one unit.
   *
   * Kind and id are a pair — `expert` with no id, or an id with no kind, are both
   * unresolvable. Accepting them separately would let a caller build exactly
   * those states across two requests.
   */
  assignee: z
    .object({
      kind: z.enum(["human", "expert"]),
      id: z.string().min(1).nullable().default(null),
    })
    .nullable()
    .optional(),
});

app.patch("/api/tasks/:id", async (c) => {
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);

  const parsed = TaskPatch.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  const patch: Parameters<typeof store.updateTask>[1] = {};
  if (body.title !== undefined) patch.title = body.title.trim();
  if (body.status !== undefined) {
    patch.status = body.status;
    // Leaving needs_you by any route clears the parked question — a card in
    // "done" still showing "codex 提问…" would be describing the past as present.
    if (task.status === "needs_you") {
      patch.needsKind = null;
      patch.needsText = null;
    }
  }
  if (body.note !== undefined) patch.note = body.note;
  if (body.myDay !== undefined) patch.myDay = body.myDay;

  if (body.assignee !== undefined) {
    if (body.assignee === null) {
      // Unclaiming clears both halves; leaving a dangling id would render as an
      // assignee nobody can resolve.
      patch.assigneeKind = null;
      patch.assigneeId = null;
    } else {
      const { kind, id } = body.assignee;
      if (kind === "expert") {
        if (id === null) return c.json({ error: "an expert assignee needs an id" }, 400);
        if (!store.getExpert(id)) return c.json({ error: `unknown expert ${id}` }, 400);
      }
      patch.assigneeKind = kind;
      patch.assigneeId = kind === "expert" ? id : null;
    }
  }

  store.updateTask(task.id, patch);
  return c.json(store.getTask(task.id));
});

// ── Lists & todo views ──────────────────────────────────────
//
// The todoagent surface. Lists ARE channels — the table was kept and the
// vocabulary changed — and the aggregated views (today / needs / done) are
// derived at read time rather than stored, per the 2026-08-02 decision.

const DEFAULT_LIST_NAME = "收件箱";

/** The list quick-added tasks land in when none is chosen. Created on demand. */
function defaultList(): Channel {
  const existing = store
    .listChannels()
    .find((ch) => ch.kind === "channel" && ch.archivedAt === null && ch.name === DEFAULT_LIST_NAME);
  if (existing) return existing;
  return store.createChannel({
    name: DEFAULT_LIST_NAME,
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
}

function sameLocalDay(iso: string, now: Date): boolean {
  const d = new Date(iso);
  return (
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate()
  );
}

/**
 * 我的一天, derived (方案 B):
 * everything alive right now (needs_you / in_progress / in_review), plus todos
 * created today, plus tasks finished today so the day's wins stay visible.
 * `myDay` is a manual pin on top of that, not the mechanism.
 */
function inToday(t: Task, now: Date): boolean {
  if (t.status === "needs_you" || t.status === "in_progress" || t.status === "in_review") return true;
  if (t.myDay !== null && sameLocalDay(`${t.myDay}T00:00:00`, now)) return true;
  if (t.status === "todo" && sameLocalDay(t.createdAt, now)) return true;
  if (t.status === "done" && sameLocalDay(t.updatedAt, now)) return true;
  return false;
}

app.get("/api/lists", (c) => {
  const tasks = store.listAllTasks();
  const open = new Map<string, number>();
  for (const t of tasks) {
    if (t.status !== "done") open.set(t.channelId, (open.get(t.channelId) ?? 0) + 1);
  }
  const now = new Date();
  const lists = store
    .listChannels()
    .filter((ch) => ch.kind === "channel" && ch.archivedAt === null)
    .map((ch) => ({
      ...ch,
      openCount: open.get(ch.id) ?? 0,
      repoPath: ch.projectId === null ? null : (store.getProject(ch.projectId)?.repoPath ?? null),
    }));
  const counts = {
    today: tasks.filter((t) => t.status !== "done" && inToday(t, now)).length,
    needs: tasks.filter((t) => t.status === "needs_you").length,
    done: tasks.filter((t) => t.status === "done").length,
  };
  return c.json({ lists, counts });
});

const ListBody = z.object({
  name: z.string().min(1).max(120),
  color: z.string().max(32).nullable().default(null),
  /** Binding a repository is what makes the list's tasks dispatchable. */
  repoPath: z.string().min(1).nullable().default(null),
});

app.post("/api/lists", async (c) => {
  const parsed = ListBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const { name, color, repoPath } = parsed.data;

  let projectId: string | null = null;
  if (repoPath !== null) {
    const abs = resolve(repoPath);
    if (!(await isGitRepo(abs))) {
      return c.json({ error: `${abs} 不是 git 仓库。先在那里运行 git init。` }, 400);
    }
    const existing = store.listProjects().find((p) => resolve(p.repoPath) === abs);
    if (existing) {
      projectId = existing.id;
    } else {
      // Projects carry a team from the pipeline era; reuse one or make a stub.
      const team = store.listTeams()[0] ?? store.createTeam("todoagent");
      projectId = store.createProject({ name, repoPath: abs, teamId: team.id }).id;
    }
  }

  const list = store.createChannel({
    name,
    purpose: "",
    kind: "channel",
    projectId,
    dmExpertId: null,
    color,
  });
  return c.json(list, 201);
});

const ListPatch = z.object({
  name: z.string().min(1).max(120).optional(),
  color: z.string().max(32).nullable().optional(),
  archived: z.boolean().optional(),
});

app.patch("/api/lists/:id", async (c) => {
  const list = store.getChannel(c.req.param("id"));
  if (!list) return c.json({ error: "unknown list" }, 404);

  const parsed = ListPatch.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  const patch: Parameters<typeof store.updateChannel>[1] = {};
  if (body.name !== undefined) patch.name = body.name.trim();
  if (body.color !== undefined) patch.color = body.color;
  if (body.archived !== undefined) patch.archivedAt = body.archived ? new Date().toISOString() : null;
  store.updateChannel(list.id, patch);
  return c.json(store.getChannel(list.id));
});

/**
 * Tasks for one view, pre-grouped by status.
 *
 * Grouped here rather than in the client so `TASK_STATUSES` stays the single
 * source of truth for which groups exist and in what order.
 */
app.get("/api/tasks", (c) => {
  const view = c.req.query("view") ?? "today";
  const all = store.listAllTasks();
  const now = new Date();

  let picked: Task[];
  if (view === "today") picked = all.filter((t) => inToday(t, now));
  else if (view === "needs") picked = all.filter((t) => t.status === "needs_you");
  else if (view === "done") picked = all.filter((t) => t.status === "done");
  else if (view.startsWith("list:")) {
    const id = view.slice("list:".length);
    if (!store.getChannel(id)) return c.json({ error: "unknown list" }, 404);
    picked = all.filter((t) => t.channelId === id);
  } else {
    return c.json({ error: `unknown view ${view}` }, 400);
  }

  const groups = Object.fromEntries(TASK_STATUSES.map((s) => [s, [] as Task[]])) as Record<
    TaskStatus,
    Task[]
  >;
  for (const t of picked) (groups[t.status] ?? groups.todo).push(t);
  groups.done.reverse(); // finished list reads newest-first
  return c.json({ view, groups });
});

const QuickTaskBody = z.object({
  title: z.string().min(1).max(500),
  note: z.string().max(2000).default(""),
  /** Absent means the 收件箱 default list. */
  listId: z.string().min(1).nullable().default(null),
});

app.post("/api/tasks", async (c) => {
  const parsed = QuickTaskBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  const list = body.listId === null ? defaultList() : store.getChannel(body.listId);
  if (!list) return c.json({ error: "unknown list" }, 404);

  const task = store.createTask({
    channelId: list.id,
    title: body.title.trim(),
    note: body.note,
    status: "todo",
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: null,
    runId: null,
  });
  return c.json(task, 201);
});

app.delete("/api/tasks/:id", (c) => {
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);

  // A live run must not keep spending tokens for a card that no longer exists.
  if (task.runId !== null) abortRun(task.runId);
  store.deleteTask(task.id);
  return c.json({ ok: true });
});

/** Stops a task's live run. The card returns to todo via the usual sync. */
app.post("/api/tasks/:id/cancel", (c) => {
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);
  if (task.runId === null) return c.json({ error: "这张卡没有进行中的执行" }, 409);

  const stopped = abortRun(task.runId);
  if (!stopped) return c.json({ error: "执行已经结束了" }, 409);
  return c.json({ ok: true, task: store.getTask(task.id) });
});

/**
 * Aborts a run if it is still alive. Returns whether anything was stopped.
 * Shared by task cancel and task delete; run-level cancel keeps its own route.
 */
function abortRun(runId: string): boolean {
  const controller = active.get(runId);
  if (controller) {
    controller.abort();
    store.updateRun(runId, { status: "cancelled", gate: null, endedAt: new Date().toISOString() });
    syncTaskFromRun(runId);
    return true;
  }
  const run = store.getRun(runId);
  if (run && (run.status === "running" || run.status === "blocked_on_human")) {
    // Stale `running` with no driver — a crash artifact. Settle it now.
    store.updateRun(runId, { status: "cancelled", gate: null, endedAt: new Date().toISOString() });
    syncTaskFromRun(runId);
    return true;
  }
  return false;
}

/** The main-agent conversation timeline. Posting into it arrives with M4. */
app.get("/api/chat/history", (c) => c.json(store.listAgentChat()));

const TaskRunBody = z.object({
  budgetTokens: z.number().int().min(0).max(200_000_000).default(2_000_000),
});

/**
 * Dispatches a board card to one agent, directly.
 *
 * The todoagent default path: no decomposition, no cross-review, no
 * verification. The card's assigned expert (or the first expert on file) gets
 * the task text and works in the repository itself; the card's status then
 * tracks the run's outcome. The six-phase pipeline still exists behind
 * `POST /api/runs` for a future deep mode.
 */
app.post("/api/tasks/:id/run", async (c) => {
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);

  const parsed = TaskRunBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);

  const channel = store.getChannel(task.channelId);
  if (!channel) return c.json({ error: "the card's channel is gone" }, 409);

  /*
   * A channel with no repository cannot execute anything: the agent needs a
   * working directory. The composer already says this when the card is
   * created; this is the enforcement.
   */
  if (channel.projectId === null) {
    return c.json(
      { error: "此频道未关联仓库，任务无法执行。把任务放到关联了仓库的频道里。" },
      400,
    );
  }
  // Captured after the null check so the closure below keeps the narrowing; TS
  // widens a property back to `string | null` inside a callback.
  const projectId = channel.projectId;
  const project = store.getProject(projectId);
  if (!project) return c.json({ error: "the channel's project is gone" }, 409);

  // Same repository lock as a direct run: two runs merging into one branch
  // interleave and corrupt the result, which the user cannot undo.
  const busy = projectBusyWith(channel.projectId);
  if (busy !== null) {
    return c.json(
      { error: `another run is already working in this repository (run ${busy})`, busyRunId: busy },
      409,
    );
  }

  // An already-running card must not start a second run: the first would keep
  // going with nothing pointing at it, and the card would track only the second.
  if (task.runId !== null) {
    const existing = store.getRun(task.runId);
    if (existing !== null && (existing.status === "running" || existing.status === "blocked_on_human")) {
      return c.json({ error: "这张卡已经在执行了", runId: task.runId }, 409);
    }
  }

  /*
   * The goal is the source message when there is one, not the card title.
   *
   * A card title is deliberately trimmed to the message's first line, and the
   * detail — constraints, examples, what "done" means — is in the rest of the
   * text. Feeding the title alone to the planner would throw that away at the
   * exact moment it matters most.
   */
  const source = task.sourceMessageId === null ? null : store.getMessage(task.sourceMessageId);
  const goal = source !== null && source.body.trim() !== "" ? source.body : task.title;

  /*
   * Who executes: the card's assignee when it is an expert, otherwise the
   * first expert on file. Resolved BEFORE the run row exists, so a board with
   * no experts refuses cleanly instead of creating a run that can only fail.
   */
  const assigned =
    task.assigneeKind === "expert" && task.assigneeId !== null
      ? store.getExpert(task.assigneeId)
      : null;
  const expert = assigned ?? store.listExperts()[0] ?? null;
  if (expert === null) {
    return c.json({ error: "没有可用的 agent。先运行 pnpm seed 或在团队页创建一个专家。" }, 400);
  }

  // One transaction: a run whose card was never updated would execute with
  // nothing on the board pointing at it.
  const run = store.tx(() => {
    const created = store.createRun({
      projectId: channel.projectId as string,
      goal,
      acceptance: null,
      budgetTokens: parsed.data.budgetTokens,
      soloMode: true,
    });
    store.updateTask(task.id, {
      runId: created.id,
      status: "in_progress",
      // Re-dispatch is how a needs_you card gets unstuck, so the parked
      // question is consumed here rather than lingering next to a live run.
      needsKind: null,
      needsText: null,
      assigneeKind: "expert",
      assigneeId: expert.id,
    });
    return created;
  });

  launchDirect(run.id, expert);
  return c.json({ run, task: store.getTask(task.id) }, 201);
});

// ── Launch ──────────────────────────────────────────────────

/**
 * Moves a card to match its run's outcome.
 *
 * A no-op for runs started directly, which have no card. The mapping is
 * deliberate:
 *
 *   completed → in_review, never done. Nobody reviewed this work; a person
 *     still has to look. Auto-completing would claim an approval nobody gave.
 *   failed / budget_exceeded → needs_you. A person decides what happens next
 *     (re-dispatch, hand-fix, close); silently returning to todo hid failures
 *     in the backlog.
 *   cancelled → todo. The user stopped it on purpose; there is nothing to ask.
 */
function syncTaskFromRun(runId: string): void {
  const task = store.getTaskByRunId(runId);
  if (!task) return;
  const run = store.getRun(runId);
  if (!run) return;

  const next =
    run.status === "completed"
      ? "in_review"
      : run.status === "cancelled"
        ? "todo"
        : run.status === "failed" || run.status === "budget_exceeded"
          ? "needs_you"
          : null;

  // `running` and `blocked_on_human` leave the card alone: it is already
  // in_progress, and a gate is surfaced on the run page rather than the board.
  if (next === null || task.status === next) return;

  if (next === "needs_you") {
    store.updateTask(task.id, {
      status: next,
      needsKind: "failed",
      needsText: (run.error ?? "执行失败，看看日志再决定。").slice(0, 500),
    });
  } else {
    store.updateTask(task.id, { status: next, needsKind: null, needsText: null });
  }
}

/**
 * Direct dispatch driver. Same lifecycle contract as `launch`: registered in
 * `active` so cancel and shutdown reach it, and the card is synced in
 * `finally` so a crash moves it too.
 */
function launchDirect(runId: string, expert: Expert): void {
  const controller = new AbortController();
  active.set(runId, controller);
  void runDirect({ store, runId, expert, signal: controller.signal })
    .then((res) => {
      console.log(`[run ${runId}] ${res.status}${res.error ? `: ${res.error}` : ""}`);
    })
    .catch((err: unknown) => {
      console.error(`[run ${runId}] crashed:`, err);
      store.updateRun(runId, {
        status: "failed",
        error: err instanceof Error ? err.message : String(err),
        endedAt: new Date().toISOString(),
      });
    })
    .finally(() => {
      active.delete(runId);
      syncTaskFromRun(runId);
    });
}

function launch(runId: string, autoApprovePlan: boolean): void {
  const controller = new AbortController();
  active.set(runId, controller);
  void runPipeline({ store, runId, signal: controller.signal, autoApprovePlan })
    .then((res) => {
      console.log(`[run ${runId}] ${res.status}${res.error ? `: ${res.error}` : ""}`);
    })
    .catch((err: unknown) => {
      console.error(`[run ${runId}] crashed:`, err);
      store.updateRun(runId, {
        status: "failed",
        error: err instanceof Error ? err.message : String(err),
        endedAt: new Date().toISOString(),
      });
    })
    .finally(() => {
      active.delete(runId);
      /*
       * In `finally`, so a crash moves the card too.
       *
       * `catch` has already written `status: failed` by the time this runs, so the
       * sync sees the real outcome rather than a stale `running`.
       */
      syncTaskFromRun(runId);
    });
}

// Before accepting traffic: resolve rows left `running` by a previous process,
// so no client can observe a run that nothing is driving.
reconcileOrphanedRuns();

serve({ fetch: app.fetch, port: PORT, hostname: "127.0.0.1" }, (info) => {
  console.log(`TodoAgent engine on http://127.0.0.1:${info.port}`);
  console.log(`Database: ${defaultDbPath()}`);
  console.log("Loopback only — the agent CLIs run with tool confirmation bypassed.");
});

// Cancel in-flight work rather than orphaning agent subprocesses on exit.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    for (const [, controller] of active) controller.abort();
    // Chat deliveries too: they hold live CLI processes that would otherwise keep
    // writing replies into a database whose owner has already exited.
    for (const [, controller] of deliveries) controller.abort();
    store.close();
    process.exit(0);
  });
}
