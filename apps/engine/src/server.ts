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
  detectAll,
  isGitRepo,
  resolveEscalationAndContinue,
  runPipeline,
  type BusEvent,
} from "@council/core";
import { EXPERT_ROLES, RUNTIME_KINDS } from "@council/core/types";

const PORT = Number(process.env["COUNCIL_PORT"] ?? 8787);
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

function resumeBlockedReason(status: string): string | null {
  if (status === "cancelled") {
    return "this run was cancelled; start a new one instead of resuming it";
  }
  if (status === "completed") return "this run has already finished";
  if (status === "budget_exceeded") {
    return "this run exhausted its token budget; start a new one with a higher ceiling";
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
        error: `${repoPath} is not a git repository. Council isolates each subtask in a git worktree, so the project must be a repo (run \`git init\` there first).`,
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
  const notResumable = resumeBlockedReason(run.status);
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
    .finally(() => active.delete(id));

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
  if (active.has(id)) return c.json({ error: "run already executing" }, 409);
  // Synchronous refusal, same reason as the plan gate: this handler answers before
  // the orchestrator's own guard can reject, so the error would never reach the
  // user. Also prevents recording a ruling on a run that will never act on it.
  const notResumable = resumeBlockedReason(run.status);
  if (notResumable !== null) return c.json({ error: notResumable }, 409);
  // Acting on a ruling re-runs the stages and merges, so it takes the repository
  // lock too. Refused BEFORE the decision is recorded: storing a ruling that is
  // never acted on would make the record claim it was applied.
  const busy = projectBusyWith(run.projectId, id);
  if (busy !== null) {
    return c.json({ error: `another run is working in this repository (run ${busy})` }, 409);
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
    .finally(() => active.delete(id));

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

// ── Launch ──────────────────────────────────────────────────

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
    .finally(() => active.delete(runId));
}

// Before accepting traffic: resolve rows left `running` by a previous process,
// so no client can observe a run that nothing is driving.
reconcileOrphanedRuns();

serve({ fetch: app.fetch, port: PORT, hostname: "127.0.0.1" }, (info) => {
  console.log(`Council engine on http://127.0.0.1:${info.port}`);
  console.log(`Database: ${defaultDbPath()}`);
  console.log("Loopback only — the agent CLIs run with tool confirmation bypassed.");
});

// Cancel in-flight work rather than orphaning agent subprocesses on exit.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    for (const [, controller] of active) controller.abort();
    store.close();
    process.exit(0);
  });
}
