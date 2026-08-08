import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { execFile } from "node:child_process";
import { homedir, platform, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { serve } from "@hono/node-server";
import { Hono, type Context, type Next } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";
import {
  RuntimeManager,
  Store,
  approvePlanAndContinue,
  bus,
  defaultDbPath,
  deliverMessage,
  detectAll,
  git,
  isGitRepo,
  newId,
  recordEvent,
  resolveEscalationAndContinue,
  runDirect,
  runPipeline,
  type BusEvent,
} from "@todoagent/core";
import {
  EXPERT_ROLES,
  RUNTIME_DISPLAY_NAMES,
  RUNTIME_KINDS,
  TASK_STATUSES,
  type AgentChatAttachment,
  type ExecutionTarget,
  type RuntimeInfo,
  type RuntimeKind,
  type Run,
  type Task,
  type TaskStatus,
} from "@todoagent/core/types";
import { classifyOutcome } from "./agent/classifier.ts";
import {
  assistantWorkspaceDir,
  createSecretary,
  ensureAssistantWorkspace,
  type SecretaryInit,
} from "./agent/secretary.ts";
import { isAllowedOrigin } from "./origin.ts";
import { installProxyDispatcher } from "./proxy.ts";

/*
 * Before any model call can happen.
 *
 * Here rather than in `dev.ts` because a proxy is a property of the machine, not of
 * development mode — `pnpm start` needs it too. A no-op when no proxy is configured,
 * and inert in the test suites: they set no API key, so nothing dials out.
 */
installProxyDispatcher();

const PORT = Number(process.env["TODOAGENT_PORT"] ?? 8787);
const store = new Store(defaultDbPath());

/**
 * Internal owner for tasks that are not in a user-created list.
 *
 * It is never returned by /api/lists. The visible “任务” entry is a smart view
 * over every task, including tasks owned by custom lists; this row only satisfies
 * the historical NOT NULL task.channel_id column.
 */
const SYSTEM_TASK_LIST_NAME = "__todoagent_tasks__";
const LEGACY_INBOX_NAME = "收件箱";
function systemTaskList() {
  return store.listChannels().find((list) => list.kind === "channel" && list.name === SYSTEM_TASK_LIST_NAME) ??
    store.createChannel({
      name: SYSTEM_TASK_LIST_NAME,
      purpose: "TodoAgent system task owner",
      kind: "channel",
      projectId: null,
      dmExpertId: null,
      color: null,
    });
}
const systemTasks = systemTaskList();

// “收件箱” was created automatically by older builds. Move its tasks into the
// system owner and archive the shell so an upgrade immediately matches the new
// Tasks + user-created Lists model without losing any task history.
for (const legacy of store.listChannels().filter(
  (list) => list.kind === "channel" && list.name === LEGACY_INBOX_NAME && list.archivedAt === null,
)) {
  for (const task of store.listAllTasks().filter((candidate) => candidate.channelId === legacy.id)) {
    store.updateTask(task.id, { channelId: systemTasks.id });
  }
  store.updateChannel(legacy.id, { archivedAt: new Date().toISOString() });
}
const runtimeManager = new RuntimeManager(store);
const app = new Hono();

/** Opens the operating system's trusted folder chooser without accepting shell input. */
function chooseDirectory(): Promise<string | null> {
  const currentPlatform = platform();
  const command = currentPlatform === "darwin" ? "/usr/bin/osascript" : "zenity";
  const args = currentPlatform === "darwin"
    ? ["-e", "set chosenFolder to choose folder with prompt \"选择 TodoAgent 工作目录\"", "-e", "POSIX path of chosenFolder"]
    : ["--file-selection", "--directory", "--title=选择 TodoAgent 工作目录"];
  if (currentPlatform !== "darwin" && currentPlatform !== "linux") {
    return Promise.reject(new Error("当前系统暂不支持目录选择器，请直接粘贴目录路径。"));
  }
  return new Promise((resolveChoice, rejectChoice) => {
    execFile(command, args, { timeout: 120_000, maxBuffer: 64 * 1024 }, (error, stdout) => {
      if (error) {
        // AppleScript -128 and zenity exit 1 both mean the person pressed Cancel.
        const code = "code" in error ? error.code : null;
        if (code === 1 || String(error.message).includes("-128")) return resolveChoice(null);
        rejectChoice(error);
        return;
      }
      const raw = stdout.trim();
      if (raw === "") return resolveChoice(null);
      try {
        const path = realpathSync(raw);
        if (!statSync(path).isDirectory()) throw new Error("选择的路径不是目录");
        resolveChoice(path);
      } catch (reason) {
        rejectChoice(reason);
      }
    });
  });
}

// ── Chat image uploads ───────────────────────────────────────
//
// Stored on disk rather than in SQLite: chat images can run into the
// megabytes, and `agent_chat` already holds the full conversation history in
// one table — inlining binary blobs there would make every unrelated read of
// that table (history, backfill, migration) drag them along.

function defaultUploadsDir(): string {
  const home = process.env["HOME"] ?? homedir();
  return process.env["TODOAGENT_UPLOADS_DIR"] ?? join(home, ".todoagent", "uploads");
}
const uploadsDir = defaultUploadsDir();
mkdirSync(uploadsDir, { recursive: true });

const UPLOAD_MEDIA_EXT: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/gif": "gif",
};
const UPLOAD_EXT_CONTENT_TYPE: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  webp: "image/webp",
  gif: "image/gif",
};
// The id IS the filename, so the id in the URL must not be able to walk the
// filesystem — a fixed alphabet plus a known extension makes that structural
// rather than something a sanitizer has to get right on every call.
const UPLOAD_ID_RE = /^[a-zA-Z0-9-]+\.(png|jpg|jpeg|webp|gif)$/;

/** Writes one incoming image to disk and returns its chat-message attachment record. */
function saveUploadedImage(img: {
  mediaType: string;
  data: string;
  width?: number;
  height?: number;
}): AgentChatAttachment {
  const ext = UPLOAD_MEDIA_EXT[img.mediaType] ?? "png";
  const id = `${newId()}.${ext}`;
  writeFileSync(join(uploadsDir, id), Buffer.from(img.data, "base64"));
  return {
    id,
    mediaType: img.mediaType,
    url: `/api/uploads/${id}`,
    ...(img.width !== undefined ? { width: img.width } : {}),
    ...(img.height !== undefined ? { height: img.height } : {}),
  };
}

/**
 * Localhost only, and deliberately unauthenticated.
 *
 * Every adapter runs its CLI with tool confirmation bypassed
 * (`--permission-mode bypassPermissions`, `--yolo`, `--always-approve`), which
 * is acceptable for a single-user tool on the loopback interface and dangerous
 * anywhere else: exposing this port lets anyone who can reach it execute
 * arbitrary code on this machine under your credentials. Adding auth is a
 * prerequisite for any non-loopback deployment.
 *
 * The allowlist was pinned to port 3000, which broke any other dev port with a
 * symptom that reads as a client bug: the browser blocks the response while curl
 * against the same endpoint returns 200, so the app renders its shell with no
 * data and no error. Widening to any loopback port does not enlarge the attack
 * surface — a process that can bind a local port can already reach this API
 * directly, and a remote page's origin cannot match — but it only holds because
 * the pattern above is anchored.
 */
app.use(
  "*",
  cors({
    // Hono hands back whatever this returns as `Access-Control-Allow-Origin`, so
    // a rejection must be null rather than a fallback origin.
    origin: (origin) => (origin !== "" && isAllowedOrigin(origin) ? origin : null),
  }),
);

/**
 * Announces a board change after any successful mutation of a task or list.
 *
 * Middleware rather than a call at the end of each handler, because there are ten
 * such routes and the failure mode of forgetting one is silent: that mutation just
 * does not reach other windows until the backstop poll, which looks like ordinary
 * lag rather than a missing line of code. A route added later gets this for free.
 *
 * Two conditions, both load-bearing:
 *
 *   GET is skipped        — reading changes nothing.
 *   4xx/5xx is skipped    — a refusal changed nothing either. Dispatch returning
 *                           409 because the repository is locked, or 400 because
 *                           the list has no repo, must not tell every client to
 *                           re-read state that is exactly as they left it.
 *
 * `syncTaskFromRun` is deliberately NOT covered here: it is called from the run
 * lifecycle rather than from a request, and it is the single most important
 * publisher — it is what moves a task out of 进行中 when an agent finishes.
 */
app.use("/api/*", async (c: Context, next: Next) => {
  await next();
  if (c.req.method === "GET") return;
  if (c.res.status >= 400) return;

  /*
   * Matched here rather than by registering several `app.use` paths.
   *
   * Whether `app.use("/api/tasks", …)` also matches `/api/tasks/:id` is a Hono
   * matching detail, and registering both `/api/tasks` and `/api/tasks/*` to be
   * safe would fire the middleware twice on the same request under one of the two
   * readings. One registration with an explicit test is unambiguous.
   *
   * Channels are included because a list IS a channel row, and the legacy channel
   * routes can still create tasks.
   */
  const path = new URL(c.req.url).pathname;
  if (!/^\/api\/(tasks|lists|channels)(\/|$)/.test(path)) return;
  bus.publishBoard();
});

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

app.post("/api/system/pick-directory", async (c) => {
  try {
    return c.json({ path: await chooseDirectory() });
  } catch (reason) {
    const message = reason instanceof Error ? reason.message : String(reason);
    return c.json({ error: `无法打开目录选择器：${message}` }, 500);
  }
});

function runtimeKind(value: string): RuntimeKind | null {
  return (RUNTIME_KINDS as readonly string[]).includes(value) ? (value as RuntimeKind) : null;
}

/** Counts live direct runs by the immutable runtime snapshot on their Run row. */
function activeRuntimeCounts(): Partial<Record<RuntimeKind, number>> {
  const counts: Partial<Record<RuntimeKind, number>> = {};
  for (const runId of active.keys()) {
    const kind = store.getRun(runId)?.runtimeKind ?? null;
    if (kind !== null) counts[kind] = (counts[kind] ?? 0) + 1;
  }
  return counts;
}

type RuntimeHttpInfo = RuntimeInfo & { label: string };

/**
 * New runtime records plus the old detection envelope during the UI migration.
 *
 * `detected` deliberately contains only path/version facts. A caller must read
 * `runtimes[].status === "ready"` before offering execution: installed is not the
 * same thing as authenticated.
 */
function runtimeEnvelope(): {
  runtimes: RuntimeHttpInfo[];
  detected: Array<{ kind: RuntimeKind; execPath: string; version: string }>;
  known: readonly RuntimeKind[];
  missing: RuntimeKind[];
} {
  const infos = runtimeManager.list(activeRuntimeCounts());
  const runtimes = infos.map((info) => ({ ...info, label: info.displayName }));
  return {
    runtimes,
    detected: infos.flatMap((info) =>
      info.execPath === null || info.version === null
        ? []
        : [{ kind: info.kind, execPath: info.execPath, version: info.version }],
    ),
    known: RUNTIME_KINDS,
    missing: infos.filter((info) => info.status === "missing").map((info) => info.kind),
  };
}

app.get("/api/runtimes", (c) => c.json(runtimeEnvelope()));

app.post("/api/runtimes/refresh", async (c) => {
  await runtimeManager.refresh();
  return c.json(runtimeEnvelope());
});

app.post("/api/runtimes/:kind/verify", async (c) => {
  const kind = runtimeKind(c.req.param("kind"));
  if (kind === null) return c.json({ error: "unknown runtime kind" }, 400);

  // A failed authentication/protocol probe is a STATE, not an HTTP failure.
  // Returning it lets the settings screen render the actionable error without
  // treating a correctly completed verification request as a broken network call.
  const info = await runtimeManager.verify(kind);
  return c.json({ ...info, label: info.displayName });
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
      expertName: nameOf(a.expertId) || RUNTIME_DISPLAY_NAMES[a.runtimeKind],
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

  const expert = attempt.expertId === null ? null : store.getExpert(attempt.expertId);
  return c.json({
    ...attempt,
    expertName:
      expert?.name ??
      (attempt.expertId === null
        ? RUNTIME_DISPLAY_NAMES[attempt.runtimeKind]
        : attempt.expertId.slice(0, 8)),
  });
});

/**
 * Everything the result drawer needs, in one request.
 *
 * `diff` is read separately from the run rather than living on it: it is capped at
 * 2M characters and `GET /api/runs` spreads whole Run objects for up to 100 rows,
 * so carrying it on the type would put a hundred snapshots in one list response.
 * Same lesson as `attempt.output`, which was 211 KB of a 292 KB payload for text
 * that view never rendered.
 *
 * `null` and `""` are DIFFERENT answers and both reach the client:
 *
 *   null  no snapshot was taken — the run failed, was cancelled, or predates the
 *         column. The UI must not claim the agent changed nothing.
 *   ""    a snapshot was taken and the tree was clean. The agent genuinely
 *         changed no files, which is a real and reportable outcome.
 */
/**
 * The newest attempt that actually produced text, and who ran it.
 *
 * Not simply the last attempt: `runOneWithRetry` can add a failed attempt after a
 * successful one, and a crashed retry has `output: null`. Taking the last row
 * blindly would show an empty result for a run whose work is sitting in the attempt
 * before it. Attempts come back ordered by `started_at`, so this walks backwards to
 * the most recent one with content.
 *
 * Shared by the result endpoint and by classification, which must judge the same
 * text the user will read. Two copies of this walk would eventually disagree, and
 * the failure would be a card parked on a question the drawer does not show.
 */
function finalOutputOf(runId: string): {
  output: string | null;
  executor: string | null;
  sessionId: string | null;
} {
  const attempts = store.listAttempts(runId);
  let output: string | null = null;
  let executor: string | null = null;
  let sessionId: string | null = null;
  for (let i = attempts.length - 1; i >= 0; i--) {
    const a = attempts[i];
    if (a === undefined) continue;
    if (executor === null) executor = a.runtimeKind;
    // The newest session id wins even when that attempt produced no text: resuming
    // is about the conversation, not about who said something last.
    if (sessionId === null && a.sessionId !== null) sessionId = a.sessionId;
    if (a.output !== null && a.output.trim() !== "") {
      output = a.output;
      executor = a.runtimeKind;
      break;
    }
  }
  return { output, executor, sessionId };
}

app.get("/api/runs/:id/result", (c) => {
  const id = c.req.param("id");
  const run = store.getRun(id);
  if (!run) return c.json({ error: "not found" }, 404);

  const { output, executor } = finalOutputOf(id);
  return c.json({ run, diff: store.getRunDiff(id), output, executor });
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

/**
 * Board invalidation stream.
 *
 * Sends "something changed, re-read it" and NOTHING else. The client answers by
 * calling the same fetch-and-reconcile path a poll uses, so there is exactly one
 * code path from server state to UI state regardless of what triggered it. Pushing
 * task rows down this stream instead would create a second one, and the two would
 * eventually disagree — with the loser being whichever arrived second.
 *
 * That also makes failure cheap: if this connection dies, the client degrades to
 * polling and stays correct. Nothing is persisted and nothing is replayed on
 * reconnect, because a missed hint costs one poll interval, not a lost update.
 *
 * Separate from `/api/runs/:id/events`, which replays a persisted per-run log by
 * `Last-Event-ID`. Different guarantees, different lifetime, different channel on
 * the bus — see `publishBoard`.
 */
app.get("/api/stream", (c) => {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let closed = false;

      const write = (frame: string): void => {
        if (closed) return;
        try {
          controller.enqueue(encoder.encode(frame));
        } catch {
          closed = true;
        }
      };

      /*
       * An immediate frame, before anything has changed.
       *
       * EventSource does not fire `onopen` until the response body starts arriving,
       * and @hono/node-server does not flush headers on their own. Without this the
       * client cannot tell "connected and idle" from "still connecting", so it
       * would sit on the fast polling fallback while a perfectly good stream was
       * open.
       */
      write(`data: ${JSON.stringify({ type: "stream:ready" })}\n\n`);

      const unsub = bus.subscribeBoard((ev) => {
        // No `event:` field, matching the run stream: EventSource delivers a NAMED
        // event only to a matching addEventListener, never to `onmessage`, so
        // naming it would require the client to keep a list that silently drifts.
        write(`data: ${JSON.stringify(ev)}\n\n`);
      });
      const unsubChat = bus.subscribeChat((ev) => {
        write(`data: ${JSON.stringify(ev)}\n\n`);
      });

      // A comment frame, so an idle connection is not dropped by the browser or a
      // proxy. 25s is under the usual 30s idle timeouts and cheap enough to ignore.
      const heartbeat = setInterval(() => write(": keepalive\n\n"), 25_000);

      const shutdown = (): void => {
        closed = true;
        clearInterval(heartbeat);
        unsub();
        unsubChat();
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

app.get("/api/channels", (c) =>
  c.json(store.listChannels().filter((channel) => channel.name !== SYSTEM_TASK_LIST_NAME)),
);

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
   * ISO date the task is due, or null to clear it.
   *
   * Same shape as `myDay` and for the same reason: a deadline people care about is
   * a day, not an instant. No range check — a date in the past is exactly what an
   * overdue task has, and one far in the future is a legitimate someday.
   */
  dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable().optional(),
  /**
   * Move the task to another list.
   *
   * `store.updateTask` has accepted `channelId` since M1; the HTTP surface simply
   * never exposed it, so a task created in the wrong list could not be moved
   * without editing the database. Not nullable: every task belongs to exactly one
   * list, and "no list" is not a state the board can render.
   */
  listId: z.string().min(1).optional(),
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
  if (body.dueDate !== undefined) patch.dueDate = body.dueDate;

  if (body.listId !== undefined) {
    const target = store.getChannel(body.listId);
    // 400 rather than 404, following the assignee check below: the task URL is
    // correct, it is the body that names something unusable.
    if (!target || target.kind !== "channel") {
      return c.json({ error: `unknown list ${body.listId}` }, 400);
    }
    /*
     * An archived list is refused.
     *
     * `GET /api/tasks?view=list:<id>` 404s an archived list, so a task moved into
     * one would be unreachable from every view except by un-archiving — the task
     * would look deleted while still counting toward totals.
     */
    if (target.archivedAt !== null) {
      return c.json({ error: "这个清单已归档。先恢复它，或者选另一个清单。" }, 400);
    }
    patch.channelId = target.id;
  }

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

function sameLocalDay(iso: string, now: Date): boolean {
  const d = new Date(iso);
  return (
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate()
  );
}

/**
 * Today as `YYYY-MM-DD` in the SERVER's timezone.
 *
 * Not `toISOString().slice(0, 10)`, which is UTC and therefore a different day from
 * the user's for part of every day outside Greenwich. Engine and browser run on the
 * same machine here, so the local calendar day is the one both agree on — the web
 * client computes the identical string in `localDayIso`.
 */
function localDayIso(now: Date): string {
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${now.getFullYear()}-${m}-${d}`;
}

/**
 * 我的一天, derived (方案 B):
 * everything alive right now (needs_you / in_progress / in_review), plus todos
 * created today, plus tasks finished today so the day's wins stay visible, plus
 * anything DUE today or already overdue. `myDay` is a manual pin on top of that,
 * not the mechanism.
 */
function inToday(t: Task, now: Date): boolean {
  if (t.status === "needs_you" || t.status === "in_progress" || t.status === "in_review") return true;
  // Finished work stays visible for the rest of the day it was finished, and no longer.
  if (t.status === "done") return sameLocalDay(t.updatedAt, now);
  if (t.myDay !== null && sameLocalDay(`${t.myDay}T00:00:00`, now)) return true;
  /*
   * An explicit deadline DECIDES, and that includes deciding against today.
   *
   * Due today or overdue is today's business — which is what makes a deadline mean
   * something: a task due Friday appears on Friday without anyone pinning it, and
   * keeps appearing while it is late.
   *
   * The `return` rather than a fallthrough is the load-bearing half. A task created
   * today but due next week used to land in 我的一天 on the created-today rule
   * below, which was defensible for a single aggregate view and is plainly wrong on
   * a day board: the user said when they want it, and that is not now. An explicit
   * date is a stronger signal than the accident of when the card was typed.
   *
   * String comparison is sound because the format is zero-padded `YYYY-MM-DD`,
   * which sorts lexicographically the same way it sorts chronologically.
   */
  if (t.dueDate !== null) return t.dueDate <= localDayIso(now);
  return sameLocalDay(t.createdAt, now);
}

/** The board's columns, in display order. */
const BOARD_KEYS = ["today", "tomorrow", "dayAfter", "later"] as const;
type BoardKey = (typeof BOARD_KEYS)[number];

/** `YYYY-MM-DD`, `n` days from `now`, local time. */
function dayOffset(now: Date, n: number): string {
  // Constructed from calendar parts so month and year rollover and daylight-saving
  // transitions are the platform's problem rather than arithmetic on milliseconds.
  return localDayIso(new Date(now.getFullYear(), now.getMonth(), now.getDate() + n));
}

/**
 * Which column a task belongs in, or null when it belongs on no column at all.
 *
 * Exactly one column per task, decided here rather than in the client. Two places
 * deciding membership is how a card renders twice or not at all — the same reason
 * `/api/tasks` groups by status server-side.
 *
 * Precedence, and every step of it is a judgement worth stating:
 *
 *   live status   — a task running right now, or waiting on you, is today's business
 *                   whatever its deadline says. You are watching it.
 *   done          — only the day it was finished, so the day's wins stay visible
 *                   without last month's history piling up.
 *   manual pin    — 我的一天. Beats the deadline, and that ordering is deliberate:
 *                   a deadline says "must be done BY", a pin says "I am doing this
 *                   today". Starting something due Thursday on Tuesday is ordinary,
 *                   and the pin is an explicit click the user just made. A stale pin
 *                   (yesterday's) does not count, so it falls through.
 *   deadline      — the user named a day. Overdue rolls into today.
 *   created today — the weakest signal, and the last resort.
 */
function boardColumn(t: Task, now: Date): BoardKey | null {
  if (inToday(t, now)) return "today";
  // Finished on an earlier day: it is done, and the board is about what is not.
  if (t.status === "done") return null;
  if (t.dueDate === dayOffset(now, 1)) return "tomorrow";
  if (t.dueDate === dayOffset(now, 2)) return "dayAfter";
  // Everything else: due further out, or carrying no deadline at all.
  return "later";
}

/**
 * Calendar navigation uses the same four-column shape with a different anchor day.
 *
 * The real-today endpoint keeps its overdue rollover rules above. A future or past
 * anchor is a planning view instead: only a deadline ON the selected day belongs to
 * its first column, otherwise looking at next Friday would make every task due before
 * Friday appear overdue there. Live work remains visible because hiding an agent that
 * is currently running just because the calendar moved would be a dangerous lie.
 */
function boardColumnFrom(t: Task, anchor: Date, isCurrentDay: boolean): BoardKey | null {
  if (isCurrentDay) return boardColumn(t, anchor);

  const anchorIso = localDayIso(anchor);
  if (t.status === "needs_you" || t.status === "in_progress" || t.status === "in_review") {
    return "today";
  }
  if (t.status === "done") return sameLocalDay(t.updatedAt, anchor) ? "today" : null;
  if (t.myDay === anchorIso) return "today";
  if (t.dueDate === anchorIso) return "today";
  if (t.dueDate === dayOffset(anchor, 1)) return "tomorrow";
  if (t.dueDate === dayOffset(anchor, 2)) return "dayAfter";
  if (t.dueDate !== null) return "later";
  return sameLocalDay(t.createdAt, anchor) ? "today" : "later";
}

/** Strict local-date parsing for `?date=YYYY-MM-DD`; rejects rollover like Feb 31. */
function parseLocalDay(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (match === null) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsed = new Date(year, month - 1, day);
  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    return null;
  }
  return parsed;
}

app.get("/api/lists", (c) => {
  /*
   * `?archived=1` returns the archived lists INSTEAD of the live ones.
   *
   * A separate view rather than an extra field on every row: archiving is rare and
   * restoring is rarer, so the sidebar reads this once on mount and after an
   * archive or restore, and the default response — which the poll fetches
   * repeatedly — carries nothing extra.
   *
   * `counts` is computed over all tasks either way. Those three numbers describe
   * the aggregate views, which are defined by task status and do not care whether
   * a task's list is archived.
   */
  const wantArchived = c.req.query("archived") === "1";
  const tasks = store.listAllTasks();
  const open = new Map<string, number>();
  for (const t of tasks) {
    if (t.status !== "done") open.set(t.channelId, (open.get(t.channelId) ?? 0) + 1);
  }
  /*
   * Parked tasks, per list, split by what it would COST you to deal with them.
   *
   * Two buckets rather than one, because the sidebar draws a different dot for
   * each and the distinction is the whole point: answering a question is a
   * sentence and a few seconds, while a dead run wants you to go fix something.
   * One number summing both is what the old aggregate 需要你 badge did, and it
   * could not be used to decide whether to look now.
   *
   * A `needs_you` row with no `needs_kind` violates an invariant, but if one
   * exists it counts as BROKEN: the answer endpoint refuses anything that is not
   * a question, so repair is the only action actually available on it.
   */
  const asking = new Map<string, number>();
  const broken = new Map<string, number>();
  for (const t of tasks) {
    if (t.status !== "needs_you") continue;
    const bucket = t.needsKind === "question" ? asking : broken;
    bucket.set(t.channelId, (bucket.get(t.channelId) ?? 0) + 1);
  }
  const now = new Date();
  const lists = store
    .listChannels()
    .filter(
      (ch) =>
        ch.kind === "channel" &&
        ch.name !== SYSTEM_TASK_LIST_NAME &&
        ch.name !== LEGACY_INBOX_NAME &&
        (wantArchived ? ch.archivedAt !== null : ch.archivedAt === null),
    )
    .map((ch) => ({
      ...ch,
      openCount: open.get(ch.id) ?? 0,
      askingCount: asking.get(ch.id) ?? 0,
      brokenCount: broken.get(ch.id) ?? 0,
      repoPath: ch.projectId === null ? null : (store.getProject(ch.projectId)?.repoPath ?? null),
    }));
  const counts = {
    tasks: tasks.filter((task) => task.status !== "done").length,
    today: tasks.filter((t) => t.status !== "done" && inToday(t, now)).length,
    needs: tasks.filter((t) => t.status === "needs_you").length,
    /*
     * Live runs, for the sidebar's 状态 section.
     *
     * Sent with the other counts rather than derived from the board, because the
     * sidebar shows it in every view — including the list views, which never load
     * board data.
     */
    running: tasks.filter((t) => t.status === "in_progress").length,
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
  if (name.trim() === "任务" || name.trim() === SYSTEM_TASK_LIST_NAME || name.trim() === LEGACY_INBOX_NAME) {
    return c.json({ error: "这个名称由系统保留，请换一个清单名称。" }, 400);
  }

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
  /**
   * Bind (or unbind, with null) the repository that makes this list's tasks
   * dispatchable.
   *
   * Creation has accepted a repo since M6, but a list made without one — the
   * inbox every install starts with — had no way to gain a repo later. The user's
   * first collision with dispatch is exactly there: capture a few tasks, try to
   * hand one to an agent, and find no affordance anywhere that explains why not.
   */
  repoPath: z.string().min(1).nullable().optional(),
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
  if (body.repoPath !== undefined) {
    if (body.repoPath === null) {
      patch.projectId = null;
    } else {
      // Same validation and project reuse as creation: one project row per
      // absolute path, whichever list bound it first.
      const abs = resolve(body.repoPath);
      if (!(await isGitRepo(abs))) {
        return c.json({ error: `${abs} 不是 git 仓库。先在那里运行 git init。` }, 400);
      }
      const existing = store.listProjects().find((p) => resolve(p.repoPath) === abs);
      if (existing) {
        patch.projectId = existing.id;
      } else {
        const team = store.listTeams()[0] ?? store.createTeam("todoagent");
        patch.projectId = store.createProject({
          name: body.name?.trim() ?? list.name,
          repoPath: abs,
          teamId: team.id,
        }).id;
      }
    }
  }
  store.updateChannel(list.id, patch);
  const after = store.getChannel(list.id);
  if (!after) return c.json({ error: "unknown list" }, 404);
  // Same shape the collection endpoint serves: the caller that just bound a repo
  // is about to re-render the dispatch affordance, and needs the path to do it.
  return c.json({
    ...after,
    repoPath: after.projectId === null ? null : (store.getProject(after.projectId)?.repoPath ?? null),
  });
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
  else if (view === "tasks") picked = all;
  else if (view === "needs") picked = all.filter((t) => t.status === "needs_you");
  // Everything with a live run, for the sidebar's 进行中 entry. A count with nothing
  // to click would be the one number on screen that goes nowhere.
  else if (view === "running") picked = all.filter((t) => t.status === "in_progress");
  else if (view === "done") picked = all.filter((t) => t.status === "done");
  else if (view.startsWith("list:")) {
    const id = view.slice("list:".length);
    const list = store.getChannel(id);
    if (!list) return c.json({ error: "unknown list" }, 404);
    /*
     * An archived list is 404 here, not an empty view.
     *
     * It has left the sidebar, so a client asking for it is working from a stale
     * copy — another window archived it, or this one has an old id in hand. The
     * web app already falls back to 我的一天 on a 404, and answering 200 instead
     * left it displaying a pane titled after a list the user cannot see or reach.
     * The tasks are still there and come back with the list if it is restored.
     */
    if (list.archivedAt !== null) return c.json({ error: "list is archived" }, 404);
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

/**
 * The day board: every uncompleted task bucketed into four columns.
 *
 * A separate endpoint rather than another `view=` on `/api/tasks`, because the shape
 * genuinely differs — that one groups by status inside one view, this one buckets by
 * day and each column needs its own date and counts. Squeezing both into one
 * response would make every caller branch on which kind it got.
 *
 * `/api/tasks` stays for the list and status views, which are still status-grouped.
 */
app.get("/api/board", (c) => {
  const now = new Date();
  const requestedDate = c.req.query("date");
  const anchor = requestedDate === undefined ? now : parseLocalDay(requestedDate);
  if (anchor === null) return c.json({ error: "date must be a real YYYY-MM-DD calendar day" }, 400);
  const anchorIso = localDayIso(anchor);
  const isCurrentDay = anchorIso === localDayIso(now);
  const all = store.listAllTasks();

  const columns = BOARD_KEYS.map((key, i) => ({
    key,
    /*
     * The date is computed HERE and sent down.
     *
     * The client could derive it, but then two implementations of "what day is the
     * third column" would have to agree — including across midnight, when the
     * engine's answer changes and a browser tab left open overnight would still be
     * bucketing against yesterday. One source, sent with the data it describes.
     *
     * `later` carries no date: it is a bucket, not a day.
     */
    date: key === "later" ? null : dayOffset(anchor, i),
    /** `Date.getDay()`, so the client renders 周二 without parsing the string. */
    weekday:
      key === "later"
        ? null
        : new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate() + i).getDay(),
    tasks: [] as Task[],
  }));
  const byKey = new Map(columns.map((col) => [col.key, col]));

  for (const t of all) {
    const key = boardColumnFrom(t, anchor, isCurrentDay);
    if (key === null) continue;
    byKey.get(key)?.tasks.push(t);
  }

  /*
   * Within a column: what needs a person first, then what is moving, then the rest.
   *
   * Same precedence the status groups use in the old pane, so the two views cannot
   * disagree about which card is most urgent. Ties keep `listAllTasks`'s created_at
   * order, which is stable — a card must not jump position between polls.
   */
  const rank: Record<TaskStatus, number> = {
    needs_you: 0,
    in_progress: 1,
    in_review: 2,
    todo: 3,
    done: 4,
  };
  for (const col of columns) {
    col.tasks.sort((a, b) => rank[a.status] - rank[b.status]);
  }

  return c.json({
    today: anchorIso,
    columns: columns.map((col) => ({
      ...col,
      /*
       * Counts for the progress bar, computed server-side alongside the membership
       * they describe.
       *
       * Only the today column can ever have a `done` count: a task finished on an
       * earlier day leaves the board, and one finished today lands in today whatever
       * its deadline was. So a future column's bar is structurally always empty —
       * the client should render it only where it means something rather than
       * showing three bars at 0% that read as failure instead of "not yet due".
       */
      done: col.tasks.filter((t) => t.status === "done").length,
      total: col.tasks.length,
    })),
  });
});

const QuickTaskBody = z.object({
  title: z.string().min(1).max(500),
  note: z.string().max(2000).default(""),
  /** Null/absent means the smart Tasks overview, not a visible default list. */
  listId: z.string().min(1).nullable().default(null),
  /** Optional deadline, `YYYY-MM-DD`. Absent means no deadline. */
  dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable().default(null),
});

app.post("/api/tasks", async (c) => {
  const parsed = QuickTaskBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const body = parsed.data;

  const list = body.listId === null ? systemTasks : store.getChannel(body.listId);
  if (!list) return c.json({ error: "unknown list" }, 404);

  const task = store.createTask({
    channelId: list.id,
    title: body.title.trim(),
    note: body.note,
    status: "todo",
    dueDate: body.dueDate,
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

// ── Main agent (chat) ───────────────────────────────────────

/**
 * Lazy, cached, retryable-on-config-change initialization.
 *
 * Keyed by the env fingerprint so a user who fixes TODOAGENT_MODEL and hits
 * send again gets a fresh attempt without restarting — but an unchanged bad
 * config is not re-probed on every request.
 */
let secretaryInit: { key: string; promise: Promise<SecretaryInit> } | null = null;

function secretaryConfigKey(): string {
  return [
    process.env["TODOAGENT_MODEL"] ?? "",
    process.env["TODOAGENT_API_KEY"] ?? "",
    process.env["TODOAGENT_AGENT_DIR"] ?? "",
    process.env["TODOAGENT_ASSISTANT_WORKSPACE"] ?? "",
  ].join("\u0000");
}

function getSecretary(): Promise<SecretaryInit> {
  const key = secretaryConfigKey();
  if (secretaryInit === null || secretaryInit.key !== key) {
    secretaryInit = {
      key,
      promise: createSecretary({
        store,
        defaultListId: () => systemTasks.id,
        publishBoard: (taskId) => bus.publishBoard(taskId),
      }),
    };
  }
  return secretaryInit.promise;
}

/** Whether chat can work right now, and if not, exactly why. */
app.get("/api/chat/status", async (c) => {
  const init = await getSecretary();
  return c.json(init.ready ? { ready: true, model: init.secretary.model } : { ready: false, reason: init.reason });
});

const AssistantFileBody = z.object({ content: z.string().max(200_000) });
const SAFE_REF_NAME = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,119}\.md$/;

/** The assistant's deliberately tiny, transparent memory workspace. */
app.get("/api/assistant/workspace", (c) => {
  const dir = ensureAssistantWorkspace();
  const refDir = join(dir, "ref");
  return c.json({
    path: assistantWorkspaceDir(),
    memory: readFileSync(join(dir, "MEMORY.md"), "utf8"),
    refs: readdirSync(refDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && SAFE_REF_NAME.test(entry.name))
      .map((entry) => entry.name)
      .sort(),
  });
});

app.put("/api/assistant/memory", async (c) => {
  const parsed = AssistantFileBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const dir = ensureAssistantWorkspace();
  writeFileSync(join(dir, "MEMORY.md"), parsed.data.content, "utf8");
  // Existing live secretary sessions retain their own compacted context. A fresh
  // conversation (or Engine restart) loads the edited memory, avoiding a silent
  // mid-conversation identity change.
  return c.json({ ok: true, content: parsed.data.content });
});

app.get("/api/assistant/ref/:name", (c) => {
  const name = c.req.param("name");
  if (!SAFE_REF_NAME.test(name)) return c.json({ error: "invalid ref name" }, 400);
  const path = join(ensureAssistantWorkspace(), "ref", name);
  if (!existsSync(path)) return c.json({ error: "not found" }, 404);
  return c.json({ name, content: readFileSync(path, "utf8") });
});

app.put("/api/assistant/ref/:name", async (c) => {
  const name = c.req.param("name");
  if (!SAFE_REF_NAME.test(name)) return c.json({ error: "引用文件名必须以 .md 结尾，只能包含字母、数字、点、横线和下划线。" }, 400);
  const parsed = AssistantFileBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  writeFileSync(join(ensureAssistantWorkspace(), "ref", name), parsed.data.content, "utf8");
  return c.json({ ok: true, name, content: parsed.data.content });
});

// ── Chat sessions ─────────────────────────────────────────────
//
// Many independent conversations with the secretary, switcher-selected —
// `chat_session` rows in `packages/core`. A person can hold several at once;
// this is what makes that possible instead of one global chat timeline.

app.get("/api/chat/sessions", (c) => {
  const archived = c.req.query("archived") === "1";
  return c.json(store.listChatSessions({ archived }));
});

const ChatSessionBody = z.object({ title: z.string().max(200).default("") });

app.post("/api/chat/sessions", async (c) => {
  const parsed = ChatSessionBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  return c.json(store.createChatSession({ title: parsed.data.title }), 201);
});

const ChatSessionPatchBody = z.object({
  title: z.string().max(200).optional(),
  archived: z.boolean().optional(),
});

app.patch("/api/chat/sessions/:id", async (c) => {
  const id = c.req.param("id");
  if (!store.getChatSession(id)) return c.json({ error: "not found" }, 404);
  const parsed = ChatSessionPatchBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);

  store.patchChatSession(id, {
    ...(parsed.data.title !== undefined ? { title: parsed.data.title } : {}),
    ...(parsed.data.archived !== undefined
      ? { archivedAt: parsed.data.archived ? new Date().toISOString() : null }
      : {}),
  });

  // An archived thread leaves the switcher's default list, so there is no
  // point keeping its AgentSession warm — closing it here rather than
  // waiting for the LRU to get around to it.
  if (parsed.data.archived === true) {
    void getSecretary().then((init) => {
      if (init.ready) init.secretary.closeSession(id);
    });
  }

  return c.json(store.getChatSession(id));
});

app.get("/api/uploads/:id", (c) => {
  const id = c.req.param("id");
  if (!UPLOAD_ID_RE.test(id)) return c.json({ error: "bad id" }, 400);
  const path = join(uploadsDir, id);
  if (!existsSync(path)) return c.json({ error: "not found" }, 404);
  const ext = id.slice(id.lastIndexOf(".") + 1);
  return new Response(readFileSync(path), {
    headers: {
      "Content-Type": UPLOAD_EXT_CONTENT_TYPE[ext] ?? "application/octet-stream",
      // Attachment ids are content-addressed by random id, never reused for
      // different bytes, so a cached copy is never stale.
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
});

/**
 * The conversation timeline, plus a resolution map for the task cards
 * embedded in it. Resolved here because a `taskRefs` id is useless to the
 * client without a title, and the client's current view may not contain the
 * task at all.
 */
app.get("/api/chat/history", (c) => {
  const sessionId = c.req.query("sessionId") ?? store.defaultChatSession().id;
  const messages = store.listAgentChat(sessionId);
  const tasks: Record<string, { id: string; title: string; status: string; channelId: string }> = {};
  for (const m of messages) {
    for (const id of m.taskRefs) {
      if (tasks[id] !== undefined) continue;
      const t = store.getTask(id);
      if (t) tasks[id] = { id: t.id, title: t.title, status: t.status, channelId: t.channelId };
    }
  }
  return c.json({ sessionId, messages, tasks });
});

const ChatImage = z.object({
  mediaType: z.enum(["image/png", "image/jpeg", "image/webp", "image/gif"]),
  // Base64, no `data:` prefix. Capped generously above the client's own
  // ~1600px-long-edge resize target, as a backstop rather than the real limit.
  data: z.string().min(1).max(15_000_000),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
});

const ChatBody = z
  .object({
    sessionId: z.string().min(1),
    body: z.string().max(4000).default(""),
    images: z.array(ChatImage).max(4).default([]),
  })
  // A message needs SOME content — but that content can be entirely a
  // picture, e.g. "what does this mean" is implicit in the image itself.
  .refine((v) => v.body.trim() !== "" || v.images.length > 0, {
    message: "body 或 images 至少要有一个",
  });

app.post("/api/chat", async (c) => {
  const parsed = ChatBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const { sessionId } = parsed.data;
  if (!store.getChatSession(sessionId)) return c.json({ error: "unknown sessionId" }, 404);

  const init = await getSecretary();
  if (!init.ready) return c.json({ error: init.reason }, 503);
  const secretary = init.secretary;

  /*
   * One turn at a time PER SESSION. steer/followUp queueing exists in the
   * SDK, but silently splicing a second request into a running turn muddles
   * taskRefs attribution; an honest 409 is better until a real need shows up.
   *
   * Scoped to this session only — a reply streaming in session A must never
   * block a person from sending in session B, which is the entire point of
   * letting several conversations be live at once.
   */
  if (secretary.isBusy(sessionId)) return c.json({ error: "上一轮还没结束，稍等几秒再发。" }, 409);

  const attachments = parsed.data.images.map(saveUploadedImage);
  const userRow = store.appendAgentChat({ sessionId, role: "user", body: parsed.data.body, attachments });
  bus.publishChat({ type: "chat:message", sessionId });
  bus.publishChat({ type: "chat:thinking", on: true, sessionId });

  try {
    const turn = await secretary.turn(sessionId, parsed.data.body, {
      images: parsed.data.images.map((img) => ({ mediaType: img.mediaType, data: img.data })),
      onDelta: (text) => bus.publishChat({ type: "chat:delta", sessionId, text }),
    });
    const agentRow = store.appendAgentChat({
      sessionId,
      role: "agent",
      body: turn.reply,
      taskRefs: turn.taskRefs,
    });
    bus.publishChat({ type: "chat:message", sessionId });
    return c.json({ user: userRow, agent: agentRow }, 201);
  } catch (err) {
    // The failure is recorded IN the conversation: a chat where the agent
    // silently says nothing looks like the app ate the message.
    const message = err instanceof Error ? err.message : String(err);
    const agentRow = store.appendAgentChat({
      sessionId,
      role: "agent",
      body: `这轮出错了：${message}`,
    });
    bus.publishChat({ type: "chat:message", sessionId });
    return c.json({ user: userRow, agent: agentRow, error: message }, 500);
  } finally {
    bus.publishChat({ type: "chat:thinking", on: false, sessionId });
  }
});

interface ResolvedWorkspace {
  projectId: string;
  repositoryRoot: string;
  workingDirectory: string;
}

/**
 * Resolves a user-visible directory into the two paths a task conversation needs:
 * the git root for locking/diffs, and the (possibly nested) cwd for the CLI.
 * Both are canonical real paths so a symlink cannot bypass the repository lock.
 */
async function resolveTaskWorkspace(input: string, name: string): Promise<ResolvedWorkspace | string> {
  const absolute = resolve(input.trim());
  if (!existsSync(absolute)) return `工作目录不存在：${absolute}`;
  try {
    if (!statSync(absolute).isDirectory()) return `工作目录不是文件夹：${absolute}`;
  } catch {
    return `无法读取工作目录：${absolute}`;
  }
  if (!(await isGitRepo(absolute))) return `${absolute} 不是 git 仓库中的目录。`;

  const rootResult = await git(["rev-parse", "--show-toplevel"], absolute);
  if (rootResult.code !== 0 || rootResult.stdout.trim() === "") {
    return `无法确定 ${absolute} 的 git 仓库根目录。`;
  }

  let workingDirectory: string;
  let repositoryRoot: string;
  try {
    workingDirectory = realpathSync(absolute);
    repositoryRoot = realpathSync(rootResult.stdout.trim());
  } catch {
    return `无法解析工作目录的真实路径：${absolute}`;
  }

  const home = realpathSync(homedir());
  if (repositoryRoot === "/" || repositoryRoot === home) {
    return "不能把系统根目录或整个用户目录作为任务仓库。请选择具体项目。";
  }

  let project = store.listProjects().find((candidate) => {
    try {
      return realpathSync(candidate.repoPath) === repositoryRoot;
    } catch {
      return resolve(candidate.repoPath) === repositoryRoot;
    }
  });
  if (!project) {
    const team = store.listTeams()[0] ?? store.createTeam("todoagent-internal");
    project = store.createProject({ name, repoPath: repositoryRoot, teamId: team.id });
  }
  return { projectId: project.id, repositoryRoot, workingDirectory };
}

const TaskRunBody = z.object({
  runtimeKind: z.enum(["claude", "codex", "cursor", "gemini", "kiro", "grok"]),
  budgetTokens: z.number().int().min(0).max(200_000_000).default(2_000_000),
});

type DispatchResult =
  | { ok: true; run: Run; task: Task }
  | { ok: false; code: 400 | 404 | 409; error: string; busyRunId?: string };

/**
 * Dispatches a board card to one explicitly selected local CLI — the ONE
 * dispatch path.
 *
 * Shared by the HTTP route and the secretary's `dispatch_task` tool, so every
 * guard (runtime readiness, repository lock, needs_you consumption) holds no
 * matter who asks. The todoagent default path: no decomposition, no
 * cross-review, no verification. The six-phase pipeline still exists behind
 * `POST /api/runs` for a future deep mode.
 */
function dispatchCard(
  taskId: string,
  budgetTokens: number,
  selectedRuntime: RuntimeKind,
): DispatchResult {
  const task = store.getTask(taskId);
  if (!task) return { ok: false, code: 404, error: "unknown task" };

  const channel = store.getChannel(task.channelId);
  if (!channel) return { ok: false, code: 409, error: "the card's channel is gone" };

  /*
   * A channel with no repository cannot execute anything: the agent needs a
   * working directory. The composer already says this when the card is
   * created; this is the enforcement.
   */
  if (channel.projectId === null) {
    return { ok: false, code: 400, error: "此清单未绑定仓库，任务无法执行。把任务移到绑定了仓库的清单里。" };
  }
  const project = store.getProject(channel.projectId);
  if (!project) return { ok: false, code: 409, error: "the channel's project is gone" };

  // Same repository lock as a direct run: two runs merging into one branch
  // interleave and corrupt the result, which the user cannot undo.
  const busy = projectBusyWith(channel.projectId);
  if (busy !== null) {
    return {
      ok: false,
      code: 409,
      error: `another run is already working in this repository (run ${busy})`,
      busyRunId: busy,
    };
  }

  // An already-running card must not start a second run: the first would keep
  // going with nothing pointing at it, and the card would track only the second.
  if (task.runId !== null) {
    const existing = store.getRun(task.runId);
    if (existing !== null && (existing.status === "running" || existing.status === "blocked_on_human")) {
      return { ok: false, code: 409, error: "这张卡已经在执行了" };
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
   * The caller chooses the CLI. There is intentionally no assignee or
   * "first expert" fallback: silently picking a different paid local runtime is
   * both surprising and capable of sending the task to the wrong credentials.
   *
   * `getReadyTarget` also rechecks the persisted absolute executable path. This
   * happens before the transaction below, so a stale install can never create a
   * Run row or move the card.
   */
  const target = runtimeManager.getReadyTarget(selectedRuntime);
  if (target === null) {
    const info = runtimeManager.list().find((item) => item.kind === selectedRuntime);
    const detail =
      info?.status === "missing"
        ? "尚未安装"
        : info?.status === "auth_required"
          ? "需要重新登录"
          : info?.status === "verifying"
            ? "正在验证"
            : "尚未验证可用";
    return {
      ok: false,
      code: 409,
      error: `${info?.displayName ?? selectedRuntime} ${detail}，请先到设置页验证连接。`,
    };
  }

  // One transaction: a run whose card was never updated would execute with
  // nothing on the board pointing at it.
  const run = store.tx(() => {
    const created = store.createRun({
      projectId: channel.projectId as string,
      taskId: task.id,
      trigger: "dispatch",
      userMessage: goal,
      repositoryRoot: project.repoPath,
      workingDirectory: project.repoPath,
      goal,
      acceptance: null,
      budgetTokens,
      soloMode: true,
      runtimeKind: target.runtimeKind,
      runtimeExecPath: target.execPath,
      runtimeVersion: target.version,
    });
    store.updateTask(task.id, {
      runId: created.id,
      runtimeKind: target.runtimeKind,
      workingDirectory: project.repoPath,
      status: "in_progress",
      // Re-dispatch is how a needs_you card gets unstuck, so the parked
      // question is consumed here rather than lingering next to a live run.
      needsKind: null,
      needsText: null,
      assigneeKind: null,
      assigneeId: null,
    });
    return created;
  });

  launchDirect(run.id, target);
  const after = store.getTask(task.id);
  return { ok: true, run, task: after ?? task };
}

/** Runtimes whose CLI can continue a prior session by id. */
const RESUMABLE_RUNTIMES = new Set(["claude", "cursor"]);

/** Tail of the previous output carried into a stitched prompt. */
const STITCH_TAIL = 6_000;

/**
 * The prompt for a run that continues after a human answered.
 *
 * Two shapes, chosen by whether the CLI can reload its own session:
 *
 *   real resume — the answer, with the question quoted for orientation. The model
 *     still has the entire conversation, so restating it would only add noise.
 *   stitched — goal, previous output, answer, and an instruction to continue.
 *     Everything the worker knew is gone, so it all has to be in the text. This
 *     costs tokens twice over and is accepted deliberately (PLAN.md §7-3).
 */
function answerPrompt(opts: {
  resumed: boolean;
  goal: string;
  previousOutput: string;
  question: string | null;
  answer: string;
}): string {
  if (opts.resumed) {
    return opts.question === null || opts.question === ""
      ? opts.answer
      : `你上一轮问：${opts.question}\n\n我的回答：${opts.answer}\n\n按这个回答继续完成任务。`;
  }
  const tail =
    opts.previousOutput.length > STITCH_TAIL
      ? opts.previousOutput.slice(-STITCH_TAIL)
      : opts.previousOutput;
  return [
    `你之前在做这个任务：${opts.goal}`,
    "",
    "你上一轮的输出（含你提出的问题）：",
    tail,
    "",
    `用户的回答：${opts.answer}`,
    "",
    "按回答继续完成任务。",
  ].join("\n");
}

const AnswerBody = z.object({ answer: z.string().min(1).max(4000) });

/**
 * Answers a parked question and continues the work.
 *
 * This is the return leg of the product's central promise: a task that got stuck
 * comes back to you, and what you type goes to the agent that asked. Before it
 * existed a `question` card had no action at all — the M3 delivery notes recorded
 * it as a known dead end.
 *
 * A NEW run is created rather than reopening the old one. The previous run is a
 * finished, immutable record with its own diff, transcript and cost; continuing to
 * append to it would make "what did this run do" unanswerable. The card follows the
 * new run, and its history stays walkable through the runs it pointed at.
 */
app.post("/api/tasks/:id/answer", async (c) => {
  const parsed = AnswerBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const answer = parsed.data.answer.trim();
  if (answer === "") return c.json({ error: "回答不能为空。" }, 400);

  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);

  /*
   * Only a parked QUESTION can be answered.
   *
   * `blocked` and `failed` are refused here on purpose: nobody asked anything, so
   * there is no question for the text to answer. Those cards offer 重派, which is a
   * different action with a different prompt — feeding a reply into a run that never
   * asked would produce an agent responding to a conversation it did not have.
   */
  if (task.status !== "needs_you" || task.needsKind !== "question") {
    return c.json(
      { error: "只有「需要你」里 agent 提问的任务可以回答。失败或受阻的任务用重派。" },
      409,
    );
  }
  if (task.runId === null) {
    return c.json({ error: "这张卡没有关联的执行记录，无法续跑。" }, 409);
  }

  const previous = store.getRun(task.runId);
  if (!previous) return c.json({ error: "关联的执行记录已不存在。" }, 409);

  // Same repository lock as dispatch: two agents writing one working tree
  // interleave their edits, and the user cannot untangle the result.
  const busy = projectBusyWith(previous.projectId);
  if (busy !== null) {
    return c.json(
      { error: `这个仓库正在跑另一个任务（run ${busy}），等它结束再回答。`, busyRunId: busy },
      409,
    );
  }

  /*
   * A reply belongs to the CLI that asked the question. The task's current
   * selection is intentionally ignored: it can be changed by a later UI edit,
   * while the session id below is meaningful only to the runtime snapshot on
   * the previous Run.
   */
  if (
    previous.runtimeKind === null ||
    previous.runtimeExecPath === null ||
    previous.runtimeVersion === null
  ) {
    return c.json(
      { error: "这条历史执行没有保存本机 CLI 快照，无法安全续跑；请重新派发任务。" },
      409,
    );
  }
  const currentTarget = runtimeManager.getReadyTarget(previous.runtimeKind);
  if (currentTarget === null) {
    return c.json(
      { error: "提出问题的本机 CLI 当前不可用，请先到设置页重新验证连接。" },
      409,
    );
  }
  if (
    currentTarget.execPath !== previous.runtimeExecPath ||
    currentTarget.version !== previous.runtimeVersion
  ) {
    return c.json(
      { error: "提出问题后本机 CLI 的路径或版本发生了变化，不能跨运行时恢复会话；请重新派发任务。" },
      409,
    );
  }
  const target: ExecutionTarget = {
    runtimeKind: previous.runtimeKind,
    displayName: currentTarget.displayName,
    execPath: previous.runtimeExecPath,
    version: previous.runtimeVersion,
  };

  const { output, sessionId } = finalOutputOf(task.runId);
  const previousOutput = output ?? "";

  /*
   * Real resume needs three things to line up, not one.
   *
   * A session id alone is not enough: it belongs to a specific CLI's on-disk
   * conversation store, so replaying it under a different runtime resolves to
   * nothing. And `resumeSessionId` is ignored in SILENCE by every adapter that does
   * not support it — codex would start cold with a prompt that assumes shared
   * context, which looks like it worked and quietly drops the whole conversation.
   */
  const canResume =
    sessionId !== null && sessionId !== "" && RESUMABLE_RUNTIMES.has(target.runtimeKind);
  const question = task.needsText;
  const goal = answerPrompt({
    resumed: canResume,
    goal: previous.goal,
    previousOutput,
    question,
    answer,
  });

  // One transaction: a run whose card was never repointed would execute with
  // nothing on the board tracking it, and the card would keep offering 回答.
  const run = store.tx(() => {
    const created = store.createRun({
      projectId: previous.projectId,
      taskId: task.id,
      parentRunId: previous.id,
      trigger: "dispatch",
      userMessage: answer,
      repositoryRoot: previous.repositoryRoot ?? store.getProject(previous.projectId)?.repoPath ?? null,
      workingDirectory: previous.workingDirectory ?? store.getProject(previous.projectId)?.repoPath ?? null,
      goal,
      acceptance: null,
      budgetTokens: previous.budgetTokens,
      soloMode: true,
      runtimeKind: target.runtimeKind,
      runtimeExecPath: target.execPath,
      runtimeVersion: target.version,
    });
    store.updateTask(task.id, {
      runId: created.id,
      runtimeKind: target.runtimeKind,
      workingDirectory: previous.workingDirectory ?? store.getProject(previous.projectId)?.repoPath ?? null,
      status: "in_progress",
      // The question has been answered, so it stops being something you owe.
      needsKind: null,
      needsText: null,
      assigneeKind: null,
      assigneeId: null,
    });
    return created;
  });

  /*
   * The answer is recorded as an event on the new run.
   *
   * Without it the transcript starts mid-conversation: a resumed run's prompt is
   * just "我的回答：…" and the question it answers lives on a different run entirely.
   * This is the only durable link between the two.
   */
  recordEvent(store, run.id, null, "run:answer", {
    question,
    answer,
    resumed: canResume,
    previousRunId: previous.id,
  });

  launchDirect(run.id, target, canResume ? sessionId : null, {
    // Prepared even when resuming succeeds, and used only if the CLI rejects the
    // session id — see `launchDirect`.
    fallbackPrompt: canResume
      ? answerPrompt({ resumed: false, goal: previous.goal, previousOutput, question, answer })
      : null,
  });

  const after = store.getTask(task.id);
  return c.json({ run, task: after ?? task, resumed: canResume }, 201);
});

app.post("/api/tasks/:id/run", async (c) => {
  const parsed = TaskRunBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);

  const res = dispatchCard(c.req.param("id"), parsed.data.budgetTokens, parsed.data.runtimeKind);
  if (!res.ok) {
    return c.json(
      res.busyRunId === undefined ? { error: res.error } : { error: res.error, busyRunId: res.busyRunId },
      res.code,
    );
  }
  return c.json({ run: res.run, task: res.task }, 201);
});

/** One task's durable, human-driven CLI conversation. */
app.get("/api/tasks/:id/thread", (c) => {
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);
  const list = store.getChannel(task.channelId);
  const defaultProject = list?.projectId === null || list?.projectId === undefined
    ? null
    : store.getProject(list.projectId);
  const runs = store.listRunsForTask(task.id);
  const turns = runs.map((run) => {
    const { output, executor } = finalOutputOf(run.id);
    return {
      run,
      message: run.userMessage ?? run.goal,
      output,
      executor,
      attempts: store.listAttempts(run.id).map(({ output: _output, ...attempt }) => ({
        ...attempt,
        expertName: RUNTIME_DISPLAY_NAMES[attempt.runtimeKind],
        outputChars: _output?.length ?? 0,
      })),
      events: store.eventsAfter(run.id, 0, 2_000).filter((event) =>
        event.type === "agent:tool_use" ||
        event.type === "agent:tool_result" ||
        event.type === "agent:error" ||
        event.type === "agent:status" ||
        event.type === "attempt:started" ||
        event.type === "attempt:completed" ||
        event.type === "attempt:failed"
      ),
    };
  });

  const knownWorkspaces = [...new Map(
    store
      .listChannels()
      .flatMap((channel) => {
        if (channel.projectId === null) return [];
        const project = store.getProject(channel.projectId);
        return project ? [[project.repoPath, { name: channel.name, path: project.repoPath }] as const] : [];
      }),
  ).values()];

  return c.json({
    task,
    list: list === null
      ? null
      : { id: list.id, name: list.name === SYSTEM_TASK_LIST_NAME ? "任务" : list.name },
    defaultWorkingDirectory: defaultProject?.repoPath ?? null,
    knownWorkspaces,
    turns,
    activeRunId: task.runId !== null && active.has(task.runId) ? task.runId : null,
    replyCount: turns.reduce((count, turn) => count + 1 + (turn.output === null ? 0 : 1), 0),
  });
});

const TaskMessageBody = z.object({
  message: z.string().min(1).max(100_000),
  runtimeKind: z.enum(["claude", "codex", "cursor", "gemini", "kiro", "grok"]).optional(),
  workingDirectory: z.string().min(1).max(4096).optional(),
});

function taskConversationPrompt(task: Task, previousRuns: Run[], message: string): string {
  const history = previousRuns.slice(-6).flatMap((run) => {
    const output = finalOutputOf(run.id).output;
    return [
      `用户：${(run.userMessage ?? run.goal).slice(-4_000)}`,
      output === null ? "" : `CLI：${output.slice(-6_000)}`,
    ].filter(Boolean);
  });
  return [
    `你正在继续任务「${task.title}」的对话。`,
    task.note.trim() === "" ? "" : `任务备注：${task.note}`,
    history.length === 0 ? "" : `此前对话摘要（最近轮次）：\n${history.join("\n\n")}`,
    `用户的新消息：${message}`,
    "继续在当前工作目录完成用户要求，并清楚汇报实际操作和结果。",
  ].filter(Boolean).join("\n\n");
}

/**
 * Sends one human-authored message to a task's real local CLI.
 *
 * The first message locks Runtime + cwd. Later messages create new immutable Run
 * rows and resume the vendor session only when every identity snapshot still
 * matches; otherwise the durable task thread is stitched into a cold turn.
 */
app.post("/api/tasks/:id/messages", async (c) => {
  const parsed = TaskMessageBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: parsed.error.issues }, 400);
  const task = store.getTask(c.req.param("id"));
  if (!task) return c.json({ error: "unknown task" }, 404);
  if (task.status === "done") return c.json({ error: "任务已完成；先重新打开任务再继续对话。" }, 409);

  if (task.runId !== null) {
    const current = store.getRun(task.runId);
    if (current && (current.status === "running" || current.status === "blocked_on_human")) {
      return c.json({ error: "上一轮还在执行，请等它结束或先取消。" }, 409);
    }
  }

  const previousRuns = store.listRunsForTask(task.id);
  // Databases from before task conversations may remember an old CLI choice but
  // not a working directory. That is not an established session: the human must
  // still be free to choose both values for the first real conversation turn.
  const sessionEstablished =
    task.runtimeKind !== null &&
    task.workingDirectory !== null &&
    task.workingDirectory !== undefined;
  const runtimeKind = sessionEstablished
    ? task.runtimeKind
    : (parsed.data.runtimeKind ?? task.runtimeKind);
  if (runtimeKind === undefined || runtimeKind === null) {
    return c.json({ error: "第一次发送消息前请选择本机 CLI。" }, 400);
  }
  if (sessionEstablished && parsed.data.runtimeKind !== undefined && parsed.data.runtimeKind !== task.runtimeKind) {
    return c.json({ error: "这个任务已经建立了 CLI 会话；切换 Runtime 请新建任务。" }, 409);
  }

  const requestedDirectory = sessionEstablished
    ? task.workingDirectory
    : (parsed.data.workingDirectory ?? task.workingDirectory);
  if (requestedDirectory === undefined || requestedDirectory === null) {
    return c.json({ error: "第一次发送消息前请选择工作目录。" }, 400);
  }
  const workspace = await resolveTaskWorkspace(requestedDirectory, task.title);
  if (typeof workspace === "string") return c.json({ error: workspace }, 400);
  if (
    sessionEstablished &&
    task.workingDirectory !== null &&
    task.workingDirectory !== undefined &&
    realpathSync(task.workingDirectory) !== workspace.workingDirectory
  ) {
    return c.json({ error: "这个任务已经锁定了工作目录；换目录请新建任务。" }, 409);
  }

  const busy = projectBusyWith(workspace.projectId);
  if (busy !== null) {
    return c.json({ error: `这个仓库正在执行另一个任务（run ${busy}）。`, busyRunId: busy }, 409);
  }
  const target = runtimeManager.getReadyTarget(runtimeKind);
  if (target === null) {
    return c.json({ error: `${RUNTIME_DISPLAY_NAMES[runtimeKind]} 尚未验证可用，请先到设置页验证连接。` }, 409);
  }

  const previous = previousRuns.at(-1) ?? null;
  const previousResult = previous === null ? null : finalOutputOf(previous.id);
  const canResume =
    previous !== null &&
    previousResult?.sessionId !== null &&
    previousResult?.sessionId !== undefined &&
    previous.runtimeKind === target.runtimeKind &&
    previous.runtimeExecPath === target.execPath &&
    previous.runtimeVersion === target.version &&
    previous.workingDirectory === workspace.workingDirectory &&
    RESUMABLE_RUNTIMES.has(target.runtimeKind);
  const coldPrompt = taskConversationPrompt(task, previousRuns, parsed.data.message.trim());
  const goal = canResume ? parsed.data.message.trim() : coldPrompt;

  const run = store.tx(() => {
    const created = store.createRun({
      projectId: workspace.projectId,
      taskId: task.id,
      parentRunId: previous?.id ?? null,
      trigger: "task_chat",
      userMessage: parsed.data.message.trim(),
      repositoryRoot: workspace.repositoryRoot,
      workingDirectory: workspace.workingDirectory,
      goal,
      acceptance: null,
      budgetTokens: 2_000_000,
      soloMode: true,
      runtimeKind: target.runtimeKind,
      runtimeExecPath: target.execPath,
      runtimeVersion: target.version,
    });
    store.updateTask(task.id, {
      runId: created.id,
      runtimeKind: target.runtimeKind,
      workingDirectory: workspace.workingDirectory,
      status: "in_progress",
      needsKind: null,
      needsText: null,
    });
    return created;
  });
  recordEvent(store, run.id, null, "run:message", {
    message: parsed.data.message.trim(),
    workingDirectory: workspace.workingDirectory,
    resumed: canResume,
    previousRunId: previous?.id ?? null,
  });
  launchDirect(run.id, target, canResume ? previousResult?.sessionId : null, {
    fallbackPrompt: canResume ? coldPrompt : null,
  });
  bus.publishBoard(task.id);
  return c.json({ run, task: store.getTask(task.id), resumed: canResume }, 201);
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

  /*
   * A task chat completes one CLI TURN, not the person's todo. After a successful
   * answer the card waits for the next human message (or an explicit Done click).
   * Treating every turn as finished work moved conversational tasks to 待确认 and
   * made the second message look like a redispatch instead of a reply.
   */
  if (run.trigger === "task_chat") {
    if (run.status === "running" || run.status === "blocked_on_human") return;
    if (run.status === "completed") {
      store.updateTask(task.id, {
        status: "needs_you",
        needsKind: "reply",
        needsText: "本轮回复完成，可以继续对话或标记任务完成。",
      });
    } else if (run.status === "cancelled") {
      store.updateTask(task.id, {
        status: "needs_you",
        needsKind: "reply",
        needsText: "本轮已取消，已产生的文件改动仍保留在工作目录中。",
      });
    } else {
      store.updateTask(task.id, {
        status: "needs_you",
        needsKind: "failed",
        needsText: (run.error ?? "本轮执行失败，请查看记录后重试。 ").slice(0, 500),
      });
    }
    bus.publishBoard(task.id);
    return;
  }

  /*
   * A completed run is not necessarily finished work.
   *
   * The classifier writes its verdict onto the run before this is called, and it is
   * read from the row rather than passed in as an argument — that is what keeps this
   * function a pure mapping of (run, task) to a card state. It has eleven call sites
   * (a cancel, a reconcile on boot, a resumed plan gate, two launch drivers) and any
   * of them can fire after the first one. With the verdict held only in a local
   * variable, the first call parked a question in 需要你 and the next call saw
   * `completed`, mapped it to 待确认 and threw the question away.
   *
   * `kind: null` — an older run, or classification that never ran — means the M0
   * behaviour, which is why that case reads as `in_review`.
   */
  const outcome = run.status === "completed" ? store.getRunOutcome(runId) : { kind: null, text: null };
  const parked = outcome.kind === "question" || outcome.kind === "blocked";

  const next =
    run.status === "completed"
      ? parked
        ? "needs_you"
        : "in_review"
      : run.status === "cancelled"
        ? "todo"
        : run.status === "failed" || run.status === "budget_exceeded"
          ? "needs_you"
          : null;

  // `running` and `blocked_on_human` leave the card alone: it is already
  // in_progress, and a gate is surfaced on the run page rather than the board.
  if (next === null || task.status === next) return;

  if (next === "needs_you") {
    /*
     * Three ways to land here, and they are not interchangeable.
     *
     * A classified question or obstacle carries the worker's own words and offers
     * 回答 or 重派 in the UI. A failure carries the run's error and offers 重派 only.
     * Labelling a question as `failed` would hide the answer path entirely — the
     * dead end this milestone exists to close.
     */
    store.updateTask(task.id, {
      status: next,
      needsKind: parked ? (outcome.kind as "question" | "blocked") : "failed",
      needsText: parked
        ? (outcome.text ?? "").slice(0, 500)
        : (run.error ?? "执行失败，看看日志再决定。").slice(0, 500),
    });
  } else {
    store.updateTask(task.id, { status: next, needsKind: null, needsText: null });
  }

  /*
   * The publish that matters most.
   *
   * Every other board change originates in a request, so the client that caused it
   * already knows. This one does not: an agent finished on its own schedule, and
   * without this announcement nothing on screen moves until the next poll. It sits
   * after the early returns above so it fires only when a status actually changed —
   * a `running` run reaching this function changes nothing and must stay quiet.
   */
  bus.publishBoard(task.id);
}

/**
 * Direct dispatch driver. Same lifecycle contract as `launch`: registered in
 * `active` so cancel and shutdown reach it, and the card is synced in
 * `finally` so a crash moves it too.
 */
/**
 * Did this failure come from an unusable session id?
 *
 * Matched on prose because that is all a CLI gives us: neither claude nor cursor
 * has an exit code or a structured field for "that session is gone". The match is
 * kept narrow — only failures that mention the session machinery — because the
 * consequence of a false positive is one wasted cold retry, while retrying every
 * failure would respawn a CLI that is simply not installed.
 */
function isSessionError(error: string | null): boolean {
  if (error === null) return false;
  return /session|resume|conversation/i.test(error);
}

function launchDirect(
  runId: string,
  target: ExecutionTarget,
  resumeSessionId?: string | null,
  opts: { fallbackPrompt?: string | null } = {},
): void {
  const controller = new AbortController();
  active.set(runId, controller);
  void (async () => {
    let res = await runDirect({
      store,
      runId,
      target,
      signal: controller.signal,
      ...(resumeSessionId ? { resumeSessionId } : {}),
    });
    console.log(`[run ${runId}] ${res.status}${res.error ? `: ${res.error}` : ""}`);

    /*
     * Real resume failed — retry cold, once, with the context the session would
     * have carried.
     *
     * A session store gets pruned, a machine gets a fresh checkout, a CLI upgrades
     * its format: the id we recorded is simply no longer loadable. Handing the user
     * `claude exited 1: no conversation found for …` would be reporting our own
     * implementation detail as their problem, when the work is still perfectly
     * doable — the stitched prompt exists for exactly this.
     *
     * The retry reuses THIS run rather than creating another. Its attempt list then
     * shows both tries, which is the honest record, and the card keeps pointing at
     * one run. `goal` is rewritten because it must describe the prompt actually
     * sent; leaving the resume-shaped prompt there would make the transcript
     * unreadable.
     */
    const fallbackPrompt = opts.fallbackPrompt ?? null;
    if (
      res.status === "failed" &&
      resumeSessionId !== null &&
      resumeSessionId !== undefined &&
      resumeSessionId !== "" &&
      fallbackPrompt !== null &&
      isSessionError(res.error) &&
      !controller.signal.aborted
    ) {
      console.log(`[run ${runId}] resume rejected, retrying without a session`);
      recordEvent(store, runId, null, "run:resume_degraded", { error: res.error });
      store.updateRun(runId, { goal: fallbackPrompt, error: null, endedAt: null });
      res = await runDirect({ store, runId, target, signal: controller.signal });
      console.log(`[run ${runId}] retry ${res.status}${res.error ? `: ${res.error}` : ""}`);
    }

    // Ordinary task/build failures leave a verified CLI ready. Only failures
    // classified by RuntimeManager as executable, protocol or authentication
    // problems invalidate it for subsequent dispatches.
    if (res.status === "failed") runtimeManager.recordExecutionFailure(target, res.error);

    /*
     * Deregistered BEFORE classification, not in the `finally` alone.
     *
     * Classification can take up to fifteen seconds, and for that whole window the
     * run is already `completed` while its controller is still in `active`. A
     * cancel arriving in the gap would find it, write `status: cancelled` over a
     * finished run and send the card back to 待办 — losing work that is sitting on
     * disk. The `finally` below still deletes, harmlessly.
     */
    active.delete(runId);
    if (res.status !== "completed") return;

    // Task-chat turns are deliberately human-driven. The CLI exiting cleanly
    // means "this reply ended", not "the todo is done", so no outcome classifier
    // is allowed to auto-promote the card.
    if (store.getRun(runId)?.trigger === "task_chat") return;

    /*
     * Classify before the card moves.
     *
     * The verdict is persisted on the run rather than handed to `syncTaskFromRun`,
     * so every one of its other call sites reaches the same answer later. This
     * cannot throw — `classifyOutcome` resolves to the heuristic on any failure —
     * but it is still guarded, because the one thing that must not happen here is
     * a card stranded at 进行中 by a side-channel LLM call.
     */
    try {
      const { output } = finalOutputOf(runId);
      const outcome = await classifyOutcome(output ?? "");
      store.updateRun(runId, { outcomeKind: outcome.kind, outcomeText: outcome.text });
      if (outcome.kind !== "done") {
        console.log(`[run ${runId}] ${outcome.kind} (${outcome.via}): ${outcome.text.slice(0, 80)}`);
      }
    } catch (err) {
      console.error(`[run ${runId}] classification failed, treating as done:`, err);
    }
  })()
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

// Detection is cheap (`--version` only) and never spends model quota. Do it
// before the socket opens so the first settings-page read is complete, then keep
// it fresh for CLIs installed or upgraded while TodoAgent stays open.
if (process.env["TODOAGENT_DISABLE_RUNTIME_DISCOVERY"] !== "1") {
  try {
    await runtimeManager.start();
  } catch (err) {
    // Individual detector failures are represented as `missing`; this guard is
    // only for an unexpected manager/storage failure. The rest of TodoAgent is
    // still useful, and dispatch will refuse because no target can be `ready`.
    console.error("Initial runtime detection failed:", err);
  }
}
serve({ fetch: app.fetch, port: PORT, hostname: "127.0.0.1" }, (info) => {
  console.log(`TodoAgent engine on http://127.0.0.1:${info.port}`);
  console.log(`Database: ${defaultDbPath()}`);
  console.log("Loopback only — the agent CLIs run with tool confirmation bypassed.");
});

// Cancel in-flight work rather than orphaning agent subprocesses on exit.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    runtimeManager.stop();
    for (const [, controller] of active) controller.abort();
    // Chat deliveries too: they hold live CLI processes that would otherwise keep
    // writing replies into a database whose owner has already exited.
    for (const [, controller] of deliveries) controller.abort();
    store.close();
    process.exit(0);
  });
}
