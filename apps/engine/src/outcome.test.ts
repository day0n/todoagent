import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";
import type { RuntimeKind, Task } from "@todoagent/core/types";

/**
 * The 需要你 loop, end to end: a worker asks, the card parks, a person answers,
 * the work continues.
 *
 * Driven through a stub CLI that speaks claude's real stream-json protocol and
 * exits 0 — unlike the stubs in `task-run.test.ts`, which all refuse. That
 * difference is the point: a REFUSING stub only ever exercises the failure path,
 * and everything this milestone adds happens after a run succeeds.
 *
 * The stub also records its argv, which is how the resume assertions check that
 * `--resume <sessionId>` actually reached the command line rather than merely
 * being set on an options object.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8817; // distinct from every other engine suite (8799–8816)
const BASE = `http://127.0.0.1:${PORT}`;

const AGENT_EXECUTABLES = ["claude", "codex", "gemini", "cursor-agent", "grok", "kiro-cli"] as const;

/** The session id the stub reports, so resume has something concrete to carry. */
const SESSION_ID = "sess-abc-123";

interface Fixture {
  root: string;
  dbPath: string;
  stubbedPath: string;
  /** Where the stub reads what to say. Rewritten per test. */
  scriptPath: string;
  /** Where the stub appends one JSON line per invocation. */
  argvLog: string;
  listId: string;
  runtimeKind: RuntimeKind;
  dispose: () => Promise<void>;
}

async function git(args: string[], cwd: string): Promise<void> {
  await new Promise<void>((done) => {
    const c = spawn("git", args, { cwd, stdio: "ignore" });
    c.on("close", () => done());
    c.on("error", () => done());
  });
}

/**
 * A stub that behaves like a real CLI turn.
 *
 * Reads `scriptPath` for the text to emit, logs its own argv, then speaks claude's
 * protocol: an init line carrying a session id, an assistant text block, and a
 * `result` line whose `result` field the adapter takes as the final output.
 */
function stubSource(scriptPath: string, argvLog: string, protocol: "claude" | "codex"): string {
  /*
   * The protocol has to match the adapter, per executable.
   *
   * Writing claude's stream-json for every CLI does not work: codex's parser reads
   * an entirely different vocabulary (`thread.started`, `item.completed`,
   * `turn.completed`) and its adapter requires `turn.completed` before it will call
   * a turn successful. A stub that speaks the wrong dialect exits 0 having said
   * nothing the parser understood, so the run FAILS — and a test asserting on the
   * answer path then fails for a reason that has nothing to do with answering.
   */
  const emit =
    protocol === "claude"
      ? `say({ type: "system", subtype: "init", session_id: SID });
say({ type: "assistant", message: { content: [{ type: "text", text: script.text }] } });
say({ type: "result", subtype: "success", is_error: false, session_id: SID, result: script.text, usage: { input_tokens: 10, output_tokens: 5 } });`
      : `say({ type: "thread.started", thread_id: SID });
say({ type: "turn.started" });
say({ type: "item.completed", item: { type: "agent_message", text: script.text } });
say({ type: "turn.completed", usage: { input_tokens: 10, output_tokens: 5 } });`;

  return `#!/usr/bin/env node
const fs = require("node:fs");
const SID = ${JSON.stringify(SESSION_ID)};
const args = process.argv.slice(2);
if (args.includes("--version") || args.includes("-v")) {
  process.stdout.write("stub 1.0.0\\n");
  process.exit(0);
}
fs.appendFileSync(${JSON.stringify(argvLog)}, JSON.stringify({ argv: args }) + "\\n");
let script = { text: "done", exit: 0 };
try { script = JSON.parse(fs.readFileSync(${JSON.stringify(scriptPath)}, "utf8")); } catch {}
if (args.join(" ").includes("TODOAGENT_OK")) script = { text: "TODOAGENT_OK", exit: 0 };
if (script.exit !== 0) {
  process.stderr.write(String(script.stderr ?? "stub failure"));
  process.exit(script.exit);
}
const say = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
${emit}
process.exit(0);
`;
}

async function fixture(runtimeKind = "claude"): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-outcome-"));
  const repo = join(root, "repo");
  const binDir = join(root, "bin");
  const scriptPath = join(root, "script.json");
  const argvLog = join(root, "argv.jsonl");
  await mkdir(repo, { recursive: true });
  await mkdir(binDir, { recursive: true });
  await writeFile(argvLog, "", "utf8");
  await writeFile(scriptPath, JSON.stringify({ text: "done", exit: 0 }), "utf8");

  await git(["init", "-q", "-b", "main", "."], repo);
  await writeFile(join(repo, "README.md"), "# fixture\n", "utf8");
  await git(["add", "-A"], repo);
  await git(["-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"], repo);

  /*
   * Every CLI is stubbed with the same cooperative SCRIPT but its own PROTOCOL, so
   * switching the expert's runtimeKind switches which resume behaviour is under
   * test and nothing else. Only claude and codex are exercised here — they are the
   * two sides of the resume divide — and the rest speak stream-json because that is
   * what their adapters read.
   */
  for (const name of AGENT_EXECUTABLES) {
    const path = join(binDir, name);
    await writeFile(path, stubSource(scriptPath, argvLog, name === "codex" ? "codex" : "claude"), "utf8");
    await chmod(path, 0o755);
  }

  const dbPath = join(root, "o.db");
  const store = new Store(dbPath);
  // Projects still carry a compatibility team id, but direct CLI execution
  // must work with an empty Expert table.
  const team = store.createTeam("t");
  const project = store.createProject({ name: "p", repoPath: repo, teamId: team.id });
  const list = store.createChannel({
    name: "工作",
    purpose: "",
    kind: "channel",
    projectId: project.id,
    dmExpertId: null,
  });
  store.close();

  return {
    root,
    dbPath,
    stubbedPath: `${binDir}${delimiter}${process.env["PATH"] ?? ""}`,
    scriptPath,
    argvLog,
    listId: list.id,
    runtimeKind: runtimeKind as RuntimeKind,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

async function withEngine<T>(f: Fixture, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: f.dbPath,
      TODOAGENT_PORT: String(PORT),
      PATH: f.stubbedPath,
      // No model: these tests pin the HEURISTIC path, which the milestone requires
      // to be a fully working configuration on its own.
      TODOAGENT_MODEL: "",
      TODOAGENT_API_KEY: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const deadline = Date.now() + 30_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error("engine did not start within 30s");
      try {
        if ((await fetch(`${BASE}/api/health`)).ok) break;
      } catch {
        /* not listening yet */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    const verified = await post(`/api/runtimes/${f.runtimeKind}/verify`);
    assert.equal(verified.status, 200);
    assert.equal((await json<{ status: string }>(verified)).status, "ready");
    return await fn();
  } finally {
    child.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 200));
  }
}

function post(path: string, body: unknown = {}): Promise<Response> {
  return fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function runCard(f: Fixture, taskId: string): Promise<Response> {
  return post(`/api/tasks/${taskId}/run`, { runtimeKind: f.runtimeKind });
}

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

async function say(f: Fixture, text: string, exit = 0): Promise<void> {
  await writeFile(f.scriptPath, JSON.stringify({ text, exit }), "utf8");
}

async function newCard(f: Fixture, title: string): Promise<string> {
  const created = await json<{ id: string }>(
    await post("/api/tasks", { title, listId: f.listId }),
  );
  return created.id;
}

/**
 * Reads one card back through the list view.
 *
 * There is no `GET /api/tasks/:id` — the board only ever reads whole views — so
 * this goes through the endpoint the UI actually uses and finds the row. That is
 * the better test anyway: it proves the card is reachable where a person would
 * look at it, not merely that a database row changed.
 */
async function getTask(f: Fixture, id: string): Promise<Task> {
  const res = await json<{ groups: Record<string, Task[]> }>(
    await fetch(`${BASE}/api/tasks?view=list%3A${f.listId}`),
  );
  for (const rows of Object.values(res.groups)) {
    const found = rows.find((t) => t.id === id);
    if (found !== undefined) return found;
  }
  throw new Error(`task ${id} is not in the list view at all`);
}

/** Polls a card until it leaves in_progress, then returns it. */
async function settle(f: Fixture, taskId: string): Promise<Task> {
  const deadline = Date.now() + 60_000;
  let task = await getTask(f, taskId);
  while (Date.now() < deadline) {
    if (task.status !== "in_progress" && task.status !== "todo") return task;
    await new Promise((r) => setTimeout(r, 200));
    task = await getTask(f, taskId);
  }
  throw new Error(`card ${taskId} never settled; last status ${task.status}`);
}

/** One run's recorded events, read straight from the store. */
function eventsOf(f: Fixture, runId: string): Array<{ type: string; payload: unknown }> {
  const store = new Store(f.dbPath);
  try {
    return store.eventsAfter(runId, 0);
  } finally {
    store.close();
  }
}

async function argvLines(f: Fixture): Promise<string[][]> {
  const raw = await readFile(f.argvLog, "utf8");
  return raw
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => (JSON.parse(l) as { argv: string[] }).argv);
}

// ── Classification, heuristic path ──────────────────────────

test("outcome: a worker that ends by asking parks the card with its question", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      await say(f, "我看了 config.ts。\n\n数据库用 postgres 还是 sqlite？");
      const id = await newCard(f, "接数据库");
      await runCard(f, id);

      const task = await settle(f, id);
      /*
       * The whole reason this milestone exists. Before it, this run was `completed`
       * and the card sat in 待确认 looking like delivered work — the user found out
       * it was a question only by opening it.
       */
      assert.equal(task.status, "needs_you");
      assert.equal(task.needsKind, "question");
      assert.equal(task.needsText, "数据库用 postgres 还是 sqlite？");
    });
  } finally {
    await f.dispose();
  }
});

test("outcome: the verdict is persisted on the run, not just applied once", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      await say(f, "写好了。\n\n要我把旧文件删掉吗？");
      const id = await newCard(f, "清理");
      await runCard(f, id);
      const task = await settle(f, id);
      assert.equal(task.needsKind, "question");

      /*
       * `syncTaskFromRun` runs from eleven call sites and maps (run, task) to a card
       * state. With the verdict held only in a local variable, the first call parked
       * the question and the NEXT one — a cancel, a reconcile on boot, a resumed gate
       * — saw `completed`, mapped it to 待确认 and discarded the question. Persisting
       * it is what makes that function order-independent, so the column existing is
       * the invariant worth pinning.
       */
      const store = new Store(f.dbPath);
      try {
        const outcome = store.getRunOutcome(task.runId ?? "");
        assert.equal(outcome.kind, "question");
        assert.equal(outcome.text, "要我把旧文件删掉吗？");
      } finally {
        store.close();
      }
    });
  } finally {
    await f.dispose();
  }
});

test("outcome: ordinary completion still goes to 待确认", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      // The M0 behaviour, pinned so classification cannot quietly capture it.
      await say(f, "改完了。app.ts 的返回值换成 new，加了一行注释。");
      const id = await newCard(f, "改返回值");
      await runCard(f, id);

      const task = await settle(f, id);
      assert.equal(task.status, "in_review");
      assert.equal(task.needsKind, null);
    });
  } finally {
    await f.dispose();
  }
});

test("outcome: a failing run is still 失败, not a question", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      await say(f, "", 3);
      const id = await newCard(f, "会失败的任务");
      await runCard(f, id);

      const task = await settle(f, id);
      assert.equal(task.status, "needs_you");
      // `failed` offers 重派 only. Mislabelling it `question` would offer an answer
      // box for a question nobody asked.
      assert.equal(task.needsKind, "failed");
    });
  } finally {
    await f.dispose();
  }
});

// ── The answer endpoint's guards ────────────────────────────

test("answer: unknown task is 404", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const res = await post("/api/tasks/nope/answer", { answer: "用 sqlite" });
      assert.equal(res.status, 404);
    });
  } finally {
    await f.dispose();
  }
});

test("answer: a card that is not asking anything is 409", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      // A plain todo card: nothing asked, nothing to answer.
      const todo = await newCard(f, "还没派发");
      const res = await post(`/api/tasks/${todo}/answer`, { answer: "随便" });
      assert.equal(res.status, 409);
      assert.match((await json<{ error: string }>(res)).error, /重派/);

      // And a FAILED card, which is in needs_you but was never a question. This is
      // the distinction the endpoint exists to keep: 重派 handles that one.
      await say(f, "", 3);
      const failed = await newCard(f, "失败的");
      await runCard(f, failed);
      const settled = await settle(f, failed);
      assert.equal(settled.needsKind, "failed");
      assert.equal((await post(`/api/tasks/${failed}/answer`, { answer: "再试" })).status, 409);
    });
  } finally {
    await f.dispose();
  }
});

test("answer: an empty or oversized answer is rejected", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      await say(f, "好了。\n\n端口用哪个？");
      const id = await newCard(f, "选端口");
      await runCard(f, id);
      await settle(f, id);

      assert.equal((await post(`/api/tasks/${id}/answer`, { answer: "" })).status, 400);
      assert.equal((await post(`/api/tasks/${id}/answer`, { answer: "   " })).status, 400);
      assert.equal((await post(`/api/tasks/${id}/answer`, {})).status, 400);
      assert.equal(
        (await post(`/api/tasks/${id}/answer`, { answer: "x".repeat(4001) })).status,
        400,
      );
      // The card is untouched by a rejected answer.
      assert.equal((await getTask(f, id)).status, "needs_you");
    });
  } finally {
    await f.dispose();
  }
});

// ── Answer and continue ────────────────────────────────────

test("answer: the card continues, and claude resumes the real session", async () => {
  const f = await fixture("claude");
  try {
    await withEngine(f, async () => {
      await say(f, "看完了。\n\n数据库用 postgres 还是 sqlite？");
      const id = await newCard(f, "接数据库");
      await runCard(f, id);
      const parked = await settle(f, id);
      assert.equal(parked.needsKind, "question");
      const firstRunId = parked.runId;

      // Simulate a stale UI edit after the question was asked. Answering must
      // ignore the task's mutable preference and use the immutable runtime
      // snapshot on the run that owns SESSION_ID.
      const external = new Store(f.dbPath);
      external.updateTask(id, { runtimeKind: "codex" });
      external.close();

      // The answer arrives, and the worker now finishes cleanly.
      await say(f, "好，用 sqlite，已经接完了。");
      const res = await post(`/api/tasks/${id}/answer`, { answer: "用 sqlite" });
      assert.equal(res.status, 201);
      const body = await json<{ run: { id: string }; task: Task; resumed: boolean }>(res);

      assert.equal(body.resumed, true, "claude can continue a session by id");
      assert.notEqual(body.run.id, firstRunId, "a new run, so the old record stays immutable");
      assert.equal(body.task.status, "in_progress");
      assert.equal(body.task.needsKind, null, "the question is no longer owed");
      assert.equal(body.task.needsText, null);
      assert.equal(body.task.runId, body.run.id);
      assert.equal(body.task.runtimeKind, "claude", "answering cannot switch the session to codex");

      // The loop closes: the follow-up run finishes as ordinary work.
      const done = await settle(f, id);
      assert.equal(done.status, "in_review");

      /*
       * Read AFTER settling, which is not incidental.
       *
       * `launchDirect` is fire-and-forget — the 201 above is sent while the CLI is
       * still being spawned — so checking argv straight after the response is a race
       * that loses on a fast machine. Waiting for the card to settle means the second
       * turn has definitely run.
       *
       * Asserting on argv rather than on an options object: argv is the contract with
       * the CLI, and `resumeSessionId` reaching an adapter that drops it is exactly
       * the failure this milestone had to rule out.
       */
      const runs = await argvLines(f);
      const resumed = runs.filter((a) => a.includes("--resume"));
      assert.equal(resumed.length, 1, `exactly one resumed turn, saw ${runs.length} total`);
      assert.equal(resumed[0]?.[resumed[0].indexOf("--resume") + 1], SESSION_ID);

      // The answer is recorded against the new run, which is the only durable link
      // back to the question it answers.
      const answered = eventsOf(f, body.run.id).find((e) => e.type === "run:answer");
      assert.ok(answered, "run:answer must be on the new run's timeline");
      const payload = answered.payload as { answer: string; question: string; resumed: boolean };
      assert.equal(payload.answer, "用 sqlite");
      assert.match(payload.question, /postgres/);
      assert.equal(payload.resumed, true);
    });
  } finally {
    await f.dispose();
  }
});

test("answer: codex cannot resume, so the prompt carries the whole context", async () => {
  const f = await fixture("codex");
  try {
    await withEngine(f, async () => {
      await say(f, "我停在这里了。\n\n要用哪个 API 版本？");
      const id = await newCard(f, "调接口");
      await runCard(f, id);
      await settle(f, id);

      await say(f, "用 v2，做完了。");
      const res = await post(`/api/tasks/${id}/answer`, { answer: "用 v2" });
      assert.equal(res.status, 201);
      const body = await json<{ run: { id: string; goal: string }; resumed: boolean }>(res);

      /*
       * `resumeSessionId` is ignored in SILENCE by adapters that do not support it,
       * so passing it to codex would look like it worked while dropping the entire
       * conversation. The stitched prompt is what keeps the worker informed, at the
       * cost of re-sending its own output (PLAN.md §7-3 accepts this).
       */
      assert.equal(body.resumed, false);
      assert.match(body.run.goal, /要用哪个 API 版本/, "the question comes along");
      assert.match(body.run.goal, /用 v2/, "so does the answer");
      assert.match(body.run.goal, /调接口|你之前在做这个任务/, "and the original goal");

      const resumed = (await argvLines(f)).filter((a) => a.includes("--resume"));
      assert.equal(resumed.length, 0, "codex must never be handed --resume");
    });
  } finally {
    await f.dispose();
  }
});

test("answer: a second question after answering parks the card again", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      await say(f, "开始了。\n\n用哪个端口？");
      const id = await newCard(f, "起服务");
      await runCard(f, id);
      assert.equal((await settle(f, id)).needsKind, "question");

      // The worker asks again rather than finishing. The loop is a feature: the
      // card comes back with the new question instead of being stuck.
      await say(f, "好。\n\n那要不要开 TLS？");
      await post(`/api/tasks/${id}/answer`, { answer: "用 8080" });

      const again = await settle(f, id);
      assert.equal(again.status, "needs_you");
      assert.equal(again.needsKind, "question");
      assert.equal(again.needsText, "那要不要开 TLS？", "the NEW question, not the old one");
    });
  } finally {
    await f.dispose();
  }
});
