#!/usr/bin/env node
/**
 * End-to-end check of the todoagent loop, against a REAL local CLI.
 *
 * This is the acceptance evidence for the product as it now exists, so it mocks
 * nothing: it starts the actual engine over HTTP, creates a list bound to a
 * throwaway git repository, adds a card, dispatches it to an installed agent, and
 * then asserts on what the API reports back.
 *
 * Driven through the HTTP surface rather than by calling the orchestrator directly.
 * That is the point — the web app has no other way in, so a check that bypassed it
 * could pass while the product was unusable. It also covers the pieces that only
 * exist at that layer: the repository lock, outcome classification, and the answer
 * endpoint's guards.
 *
 * `--ask` runs the other half of the loop: a worker that asks a question, a card
 * parked in 需要你, an answer, and a resumed run that finishes.
 *
 * It spends real tokens, which is why it is a separate command and not part of
 * `pnpm test`.
 *
 * The six-phase pipeline check this replaces asserted cross-vendor review,
 * decomposition and worktree isolation — none of which the product does any more.
 * That pipeline is still in the codebase behind `POST /api/runs`; it simply is not
 * what a person uses, so it is no longer what the end-to-end check exercises.
 */
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { detectAll } from "../adapters/index.ts";
import { git } from "../util/git.ts";
import type { RuntimeKind, Task } from "../types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
/** The engine's own entry point, four levels up out of packages/core. */
const SERVER = join(HERE, "..", "..", "..", "..", "apps", "engine", "src", "server.ts");

/** Distinct from every test suite's port (8799–8817) so both can run at once. */
const PORT = Number(process.env["TODOAGENT_E2E_PORT"] ?? 8850);
const BASE = `http://127.0.0.1:${PORT}`;

/** Runtimes that can continue a session by id, so `--ask` can predict `resumed`. */
const RESUMABLE = new Set<RuntimeKind>(["claude", "cursor"]);

/**
 * One agent turn against a real CLI, plus classification.
 *
 * Generous because it is bounded by somebody else's model: a cold `claude` turn
 * that reads a file and writes another routinely takes over a minute, and a
 * failure here should mean "wedged", not "slower than I guessed".
 */
const TURN_TIMEOUT_MS = 10 * 60 * 1000;

/*
 * The goal is the card TITLE, capped at 500 characters by `QuickTaskBody`.
 *
 * A quick-added card has no source message, so `dispatchCard` uses the title
 * verbatim as the run's goal — which makes the title the entire prompt. Both of
 * these are written to fit.
 */
const PLAIN_GOAL =
  "在 src/text.ts 里新建并导出 slugify(input: string): string：转小写、去首尾空白、" +
  "把连续空白和标点压成单个连字符。直接做完，不要问任何问题。";

/**
 * A goal whose FIRST action must be a question.
 *
 * Phrased as mechanically as possible. "Do the work but ask if unsure" produces a
 * worker that just does the work — it is a capable agent and the task is
 * unambiguous — and then this check would fail for model compliance rather than for
 * anything about the product. Making the question itself the first deliverable is
 * what makes the run reproducible.
 */
const ASK_GOAL =
  "分两步。第一步：只输出一个问题——src/config.ts 的配置项用扁平结构还是嵌套结构？" +
  "问完立刻停下，这一步禁止创建或修改任何文件。第二步（等我回答后）：按我的回答创建 src/config.ts。";

const ANSWER = "用扁平结构，键名用 snake_case。";

interface Check {
  name: string;
  ok: boolean;
  detail: string;
}

const checks: Check[] = [];
function check(name: string, ok: boolean, detail = ""): boolean {
  checks.push({ name, ok, detail });
  console.log(`  [${ok ? "PASS" : "FAIL"}] ${name}${detail ? ` — ${detail}` : ""}`);
  return ok;
}

async function req<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  let parsed: unknown = null;
  try {
    parsed = await res.json();
  } catch {
    /* 204, or a non-JSON error page */
  }
  return { status: res.status, body: parsed as T };
}

/** A real repository with something to read, so the agent has honest work. */
async function scaffoldRepo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-e2e-"));
  await writeFile(
    join(dir, "package.json"),
    `${JSON.stringify(
      { name: "todoagent-e2e-fixture", version: "1.0.0", type: "module", scripts: { test: "node --test" } },
      null,
      2,
    )}\n`,
    "utf8",
  );
  await writeFile(
    join(dir, "README.md"),
    "# Fixture\n\nA scratch repository used by TodoAgent's end-to-end check.\n",
    "utf8",
  );
  await git(["init", "-q", "-b", "main", "."], dir);
  await git(["add", "-A"], dir);
  await git(
    ["-c", "user.name=TodoAgent", "-c", "user.email=todoagent@localhost", "commit", "-q", "-m", "chore: fixture"],
    dir,
  );
  return dir;
}

interface Engine {
  stop: () => void;
  /** Engine stdout+stderr, for the classification line and failure diagnosis. */
  log: () => string;
}

async function startEngine(dbPath: string): Promise<Engine> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: { ...process.env, TODOAGENT_DB: dbPath, TODOAGENT_PORT: String(PORT) },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  child.stdout.on("data", (d: Buffer) => (log += d.toString()));
  child.stderr.on("data", (d: Buffer) => (log += d.toString()));

  const deadline = Date.now() + 30_000;
  for (;;) {
    if (child.exitCode !== null) throw new Error(`engine exited ${child.exitCode}:\n${log}`);
    if (Date.now() > deadline) {
      child.kill("SIGKILL");
      throw new Error(`engine did not answer on ${BASE} within 30s:\n${log}`);
    }
    try {
      if ((await fetch(`${BASE}/api/health`, { signal: AbortSignal.timeout(2_000) })).ok) break;
    } catch {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  return { stop: () => child.kill("SIGKILL"), log: () => log };
}

/** Reads one card back through the view the UI uses. */
async function card(listId: string, taskId: string): Promise<Task> {
  const { body } = await req<{ groups: Record<string, Task[]> }>(
    "GET",
    `/api/tasks?view=list:${listId}`,
  );
  for (const rows of Object.values(body.groups ?? {})) {
    const hit = rows.find((t) => t.id === taskId);
    if (hit) return hit;
  }
  throw new Error(`card ${taskId} is not in list ${listId} at all`);
}

/** Waits until the card is neither queued nor running. */
async function settle(listId: string, taskId: string, label: string): Promise<Task> {
  const deadline = Date.now() + TURN_TIMEOUT_MS;
  let last = "";
  for (;;) {
    const t = await card(listId, taskId);
    if (t.status !== "in_progress" && t.status !== "todo") return t;
    if (t.status !== last) {
      console.log(`    …${label}: ${t.status}`);
      last = t.status;
    }
    if (Date.now() > deadline) {
      throw new Error(`${label}: still ${t.status} after ${TURN_TIMEOUT_MS / 1000}s`);
    }
    await new Promise((r) => setTimeout(r, 2_000));
  }
}

interface RunResult {
  run: { id: string; status: string; goal: string };
  diff: string | null;
  output: string | null;
  executor: string | null;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const askMode = args.includes("--ask");
  const keep = args.includes("--keep");
  const wanted = args.find((a) => a.startsWith("--runtime="))?.split("=")[1] ?? null;
  const budgetM = Number(args.find((a) => a.startsWith("--budget="))?.split("=")[1] ?? "2");

  console.log(`TodoAgent end-to-end check${askMode ? " (--ask: question → answer → resume)" : ""}\n`);

  /*
   * No CLI is a hard error, not a skip.
   *
   * A green run that tested nothing is worse than a red one: this command exists to
   * be believed.
   */
  const detected = await detectAll();
  if (detected.length === 0) {
    console.error(
      "PATH 上没有编码 CLI，无法做端到端验证。先装一个并登录（claude / codex / cursor-agent / gemini / kiro-cli / grok）。",
    );
    process.exitCode = 1;
    return;
  }

  const preference: RuntimeKind[] = ["claude", "codex", "cursor", "kiro", "grok", "gemini"];
  const available = [...detected].sort(
    (a, b) => preference.indexOf(a.kind) - preference.indexOf(b.kind),
  );
  const picked = wanted === null ? available[0] : available.find((d) => d.kind === wanted);
  if (picked === undefined) {
    console.error(
      `--runtime=${wanted} 不在已装列表里：${available.map((d) => d.kind).join(", ")}`,
    );
    process.exitCode = 1;
    return;
  }

  console.log(`Detected: ${detected.map((d) => d.kind).join(", ")}`);
  console.log(`Using:    ${picked.kind} (${picked.version})`);
  const hasModel = (process.env["TODOAGENT_MODEL"] ?? "").trim() !== "";
  console.log(`Classify: ${hasModel ? `model (${process.env["TODOAGENT_MODEL"]})` : "heuristic (no TODOAGENT_MODEL)"}`);
  if (askMode) {
    console.log(`Resume:   ${RESUMABLE.has(picked.kind) ? "real session resume expected" : "stitched prompt expected"}`);
  }

  const repo = await scaffoldRepo();
  /*
   * The database lives OUTSIDE the fixture repository.
   *
   * Inside it, sqlite's three files (`e2e.db`, `-wal`, `-shm`) showed up as
   * untracked entries in the captured snapshot — noise in the one artifact whose
   * whole purpose is showing what the agent changed.
   */
  const dbPath = join(dirname(repo), `${repo.split("/").at(-1) ?? "e2e"}.db`);
  console.log(`\nRepo: ${repo}`);

  let engine: Engine | null = null;
  try {
    engine = await startEngine(dbPath);

    // ── Setup, through the same API the UI uses ──
    const expert = await req<{ id: string }>("POST", "/api/experts", {
      name: `E2E-${picked.kind}`,
      description: "end-to-end fixture agent",
      runtimeKind: picked.kind,
      systemPrompt:
        "You are running inside an automated end-to-end check. Be concise and concrete, and follow the task's instructions about ordering exactly.",
      capabilities: ["general"],
    });
    if (!check("expert created", expert.status === 201, `HTTP ${expert.status}`)) return;

    const list = await req<{ id: string; name: string }>("POST", "/api/lists", {
      name: "e2e",
      repoPath: repo,
    });
    if (!check("list bound to the repository", list.status === 201, `HTTP ${list.status}`)) return;
    const listId = list.body.id;

    const task = await req<Task>("POST", "/api/tasks", {
      title: askMode ? ASK_GOAL : PLAIN_GOAL,
      listId,
    });
    if (!check("card created", task.status === 201, `HTTP ${task.status}`)) return;
    const taskId = task.body.id;

    // ── Dispatch ──
    console.log("\nDispatching…");
    const started = Date.now();
    const dispatched = await req<{ run: { id: string }; error?: string }>(
      "POST",
      `/api/tasks/${taskId}/run`,
      { budgetTokens: Math.round(budgetM * 1_000_000) },
    );
    if (
      !check(
        "dispatch accepted",
        dispatched.status === 201,
        dispatched.status === 201 ? `run ${dispatched.body.run.id.slice(0, 8)}` : `HTTP ${dispatched.status}: ${dispatched.body.error ?? ""}`,
      )
    ) {
      return;
    }
    const firstRunId = dispatched.body.run.id;

    const settled = await settle(listId, taskId, "first run");
    const elapsed = ((Date.now() - started) / 1000).toFixed(0);
    console.log(`\nFirst run settled in ${elapsed}s → ${settled.status}\n`);
    console.log("Assertions:");

    if (askMode) {
      // ── The question half of the loop ──
      const parked = check(
        "card parked in 需要你",
        settled.status === "needs_you",
        `status=${settled.status}`,
      );
      if (!parked) {
        console.log(
          "        (the worker may simply not have asked — check the output below before blaming the product)",
        );
      }
      check(
        "classified as a question, not a failure",
        settled.needsKind === "question",
        `needsKind=${String(settled.needsKind)}`,
      );
      check(
        "the question text is on the card",
        (settled.needsText ?? "").trim() !== "",
        JSON.stringify((settled.needsText ?? "").slice(0, 90)),
      );

      // The run itself succeeded; only the CARD is parked. Conflating the two would
      // make a question look like a failure everywhere a run status is shown.
      const first = await req<RunResult>("GET", `/api/runs/${firstRunId}/result`);
      check(
        "the run stayed completed",
        first.body.run?.status === "completed",
        `status=${String(first.body.run?.status)}`,
      );
      console.log(`\n  worker said: ${JSON.stringify((first.body.output ?? "").slice(-220))}\n`);

      // ── Answering guards, then the answer ──
      const unknown = await req("POST", "/api/tasks/does-not-exist/answer", { answer: "x" });
      check("answering an unknown card is 404", unknown.status === 404, `HTTP ${unknown.status}`);
      const empty = await req("POST", `/api/tasks/${taskId}/answer`, { answer: "   " });
      check("an empty answer is refused", empty.status === 400, `HTTP ${empty.status}`);

      console.log("\nAnswering…");
      const answered = await req<{ run: { id: string; goal: string }; task: Task; resumed: boolean; error?: string }>(
        "POST",
        `/api/tasks/${taskId}/answer`,
        { answer: ANSWER },
      );
      if (
        !check(
          "answer accepted",
          answered.status === 201,
          answered.status === 201 ? "" : `HTTP ${answered.status}: ${answered.body.error ?? ""}`,
        )
      ) {
        return;
      }

      check(
        "a NEW run was created",
        answered.body.run.id !== firstRunId,
        "the finished run stays an immutable record",
      );
      check(
        "the card is running again with the question cleared",
        answered.body.task.status === "in_progress" &&
          answered.body.task.needsKind === null &&
          answered.body.task.needsText === null,
        `status=${answered.body.task.status} needsKind=${String(answered.body.task.needsKind)}`,
      );
      check(
        `resume path matches the runtime (${picked.kind})`,
        answered.body.resumed === RESUMABLE.has(picked.kind),
        `resumed=${answered.body.resumed}`,
      );
      if (answered.body.resumed) {
        // A resumed prompt carries the answer; the model still holds the rest.
        check(
          "the resumed prompt carries the answer",
          answered.body.run.goal.includes(ANSWER),
          JSON.stringify(answered.body.run.goal.slice(0, 90)),
        );
      } else {
        /*
         * The stitched prompt has to carry everything the session would have: the
         * original goal, the worker's own previous output, and the answer. This is
         * the codex path (PLAN.md §7-3).
         */
        const goal = answered.body.run.goal;
        check(
          "the stitched prompt carries goal, previous output and answer",
          goal.includes(ANSWER) && goal.includes("你之前在做这个任务") && goal.length > 200,
          `${goal.length} chars`,
        );
      }

      const finished = await settle(listId, taskId, "resumed run");
      check(
        "the resumed run finishes into 待确认",
        finished.status === "in_review",
        `status=${finished.status}`,
      );
      check("no question left on the card", finished.needsKind === null, String(finished.needsKind));

      const second = await req<RunResult>("GET", `/api/runs/${answered.body.run.id}/result`);
      check(
        "the resumed run left a snapshot",
        typeof second.body.diff === "string",
        second.body.diff === null ? "diff is null" : `${second.body.diff.length} chars`,
      );
      check(
        "and it created the file the answer asked for",
        (second.body.diff ?? "").includes("config.ts"),
        JSON.stringify((second.body.diff ?? "").slice(0, 120)),
      );
    } else {
      // ── The plain half: work delivered, waiting for a person ──
      check(
        "card lands in 待确认, not done",
        settled.status === "in_review",
        `status=${settled.status} (nobody reviewed it yet, so it must not auto-complete)`,
      );
      check("no needs state on a clean completion", settled.needsKind === null, String(settled.needsKind));

      const result = await req<RunResult>("GET", `/api/runs/${firstRunId}/result`);
      check("the result endpoint answers", result.status === 200, `HTTP ${result.status}`);
      check("the run completed", result.body.run?.status === "completed", String(result.body.run?.status));
      /*
       * `diff` distinguishes two answers the drawer must not conflate: null means no
       * snapshot was taken, "" means one was taken and the tree was clean.
       */
      check(
        "a working-tree snapshot was captured",
        typeof result.body.diff === "string",
        result.body.diff === null ? "diff is null — nothing was captured" : `${result.body.diff.length} chars`,
      );
      check(
        "the snapshot shows the file the agent was asked to create",
        (result.body.diff ?? "").includes("text.ts"),
        JSON.stringify((result.body.diff ?? "").slice(0, 120)),
      );
      check(
        "the transcript is readable",
        (result.body.output ?? "").trim() !== "",
        `${(result.body.output ?? "").length} chars`,
      );
      check(
        "the executor is reported",
        result.body.executor === picked.kind,
        `executor=${String(result.body.executor)}`,
      );

      /*
       * The work is genuinely on disk, not merely described in a payload.
       *
       * `-uall` is required, not decorative: plain `--porcelain` collapses an
       * untracked directory to `?? src/` and never names the files inside it, so
       * this check reported "the file does not exist" for work that plainly did.
       * `captureWorkingDiff` passes the same flag for the same reason.
       */
      const status = await git(["status", "--porcelain", "-uall"], repo);
      check(
        "the file exists in the working tree",
        status.stdout.includes("text.ts"),
        JSON.stringify(status.stdout.trim().slice(0, 120)),
      );

      // Completing it is the last step of the loop the user performs by hand.
      const done = await req<Task>("PATCH", `/api/tasks/${taskId}`, { status: "done" });
      check("confirming moves it to 已完成", done.body?.status === "done", String(done.body?.status));
    }

    // Classification is announced in the engine log either way, which is the only
    // place the model-vs-heuristic path is visible.
    const classifyLine = (engine.log().match(/\[classify\].*|\] (question|blocked) \(\w+\).*/g) ?? []).at(-1);
    console.log(`\nEngine classify line: ${classifyLine ?? "(none — a plain completion says nothing)"}`);
  } finally {
    engine?.stop();
  }

  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} checks passed.`);
  if (failed.length > 0) {
    console.log("\nFailures:");
    for (const f of failed) console.log(`  ${f.name}${f.detail ? `: ${f.detail}` : ""}`);
    console.log(`\nFixture kept for inspection: ${repo}`);
    process.exitCode = 1;
    return;
  }

  if (keep) {
    console.log(`\nFixture kept: ${repo}`);
    console.log(`Database:     ${dbPath}`);
  } else {
    await rm(repo, { recursive: true, force: true }).catch(() => undefined);
    // The database sits outside the repo now, so it needs removing separately —
    // along with sqlite's WAL and shared-memory sidecars.
    for (const suffix of ["", "-wal", "-shm"]) {
      await rm(`${dbPath}${suffix}`, { force: true }).catch(() => undefined);
    }
    console.log("\n(fixture cleaned up — pass --keep to inspect it)");
  }
}

main().catch((err) => {
  console.error("\nE2E crashed:", err);
  process.exitCode = 1;
});
