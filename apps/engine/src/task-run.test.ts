import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Starting a pipeline run from a board card.
 *
 * This is the seam between the two halves of the product: chat and the board
 * describe work, the pipeline does it. `task.run_id` sat in the schema unset for
 * the whole build, so the board was decorative — cards could be dragged but never
 * executed.
 *
 * Every agent executable is shadowed with a stub that refuses, so no test here
 * can reach a CLI the user installed. That matters twice over: it keeps the suite
 * off their quota, and a refusing stub is exactly what exercises the failure path
 * the card has to reflect.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8813; // distinct from the other engine suites
const BASE = `http://127.0.0.1:${PORT}`;

/** Every CLI this repo can spawn. Absence is not a safety mechanism. */
const AGENT_EXECUTABLES = ["claude", "codex", "gemini", "cursor-agent", "grok", "kiro-cli"] as const;

interface Fixture {
  dbPath: string;
  repo: string;
  /** PATH with the stubs in front, for the engine child process. */
  stubbedPath: string;
  repoChannelId: string;
  plainChannelId: string;
  dispose: () => Promise<void>;
}

async function git(args: string[], cwd: string): Promise<void> {
  await new Promise<void>((done) => {
    const c = spawn("git", args, { cwd, stdio: "ignore" });
    c.on("close", () => done());
    c.on("error", () => done());
  });
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-taskrun-"));
  const repo = join(root, "repo");
  const binDir = join(root, "bin");
  await mkdir(repo, { recursive: true });
  await mkdir(binDir, { recursive: true });
  const canonicalRepo = await realpath(repo);

  // A real git repository: worktree isolation is not mocked anywhere in this repo.
  await git(["init", "-q", "-b", "main", "."], repo);
  await writeFile(join(repo, "README.md"), "# fixture\n", "utf8");
  await git(["add", "-A"], repo);
  await git(["-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"], repo);

  for (const name of AGENT_EXECUTABLES) {
    const path = join(binDir, name);
    await writeFile(
      path,
      `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args.includes("--version") || args.includes("-v")) {
  process.stdout.write(${JSON.stringify(`${name} 1.0.0\n`)});
  process.exit(0);
}
if (args.join(" ").includes("TODOAGENT_OK")) {
  const say = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
  say({ type: "system", subtype: "init", session_id: "probe-session" });
  say({ type: "assistant", message: { content: [{ type: "text", text: "TODOAGENT_OK" }] } });
  say({ type: "result", subtype: "success", is_error: false, session_id: "probe-session", result: "TODOAGENT_OK", usage: { input_tokens: 1, output_tokens: 1 } });
  process.exit(0);
}
process.stderr.write(${JSON.stringify(`${name} is stubbed\n`)});
process.exit(3);
`,
      "utf8",
    );
    await chmod(path, 0o755);
  }

  const dbPath = join(root, "t.db");
  const store = new Store(dbPath);
  // Direct dispatch must not depend on any Expert row. The empty compatibility
  // team exists only because Project still carries its historical team_id.
  const team = store.createTeam("t");
  const project = store.createProject({ name: "p", repoPath: canonicalRepo, teamId: team.id });

  const withRepo = store.createChannel({
    name: "demo",
    purpose: "",
    kind: "channel",
    projectId: project.id,
    dmExpertId: null,
  });
  // A channel with no repository is a legitimate state — a DM, or a
  // discussion-only channel. It can hold cards but cannot execute them.
  const plain = store.createChannel({
    name: "chat-only",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
  store.close();

  return {
    dbPath,
    repo: canonicalRepo,
    stubbedPath: `${binDir}${delimiter}${process.env["PATH"] ?? ""}`,
    repoChannelId: withRepo.id,
    plainChannelId: plain.id,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

test("task chat: first human message locks the real workspace and preserves a durable turn", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.plainChannelId, "在指定仓库里对话", false);

      const empty = await json<{
        turns: unknown[];
        defaultWorkingDirectory: string | null;
        knownWorkspaces: Array<{ path: string }>;
      }>(await fetch(`${BASE}/api/tasks/${id}/thread`));
      assert.deepEqual(empty.turns, []);
      assert.equal(empty.defaultWorkingDirectory, null, "an unbound list does not guess a cwd");
      assert.ok(empty.knownWorkspaces.some((workspace) => workspace.path === f.repo));

      assert.equal(
        (await post(`/api/tasks/${id}/messages`, { message: "先看一下项目" })).status,
        400,
        "the first message cannot silently choose a CLI or cwd",
      );

      const startedResponse = await post(`/api/tasks/${id}/messages`, {
        message: "先看一下项目，不要猜需求",
        runtimeKind: "claude",
        workingDirectory: f.repo,
      });
      assert.equal(startedResponse.status, 201);
      const started = await json<{
        run: {
          id: string;
          taskId: string | null;
          trigger: string | null;
          userMessage: string | null;
          repositoryRoot: string | null;
          workingDirectory: string | null;
          runtimeKind: string | null;
        };
        task: { runtimeKind: string | null; workingDirectory: string | null };
      }>(startedResponse);
      assert.equal(started.run.taskId, id);
      assert.equal(started.run.trigger, "task_chat");
      assert.equal(started.run.userMessage, "先看一下项目，不要猜需求");
      assert.equal(started.run.repositoryRoot, f.repo);
      assert.equal(started.run.workingDirectory, f.repo);
      assert.equal(started.run.runtimeKind, "claude");
      assert.equal(started.task.runtimeKind, "claude");
      assert.equal(started.task.workingDirectory, f.repo);

      await waitForRun(started.run.id, (status) => status !== "running");
      const thread = await json<{
        turns: Array<{
          message: string;
          run: { id: string; workingDirectory: string | null };
          events: Array<{ type: string }>;
        }>;
        activeRunId: string | null;
      }>(await fetch(`${BASE}/api/tasks/${id}/thread`));
      assert.equal(thread.turns.length, 1);
      assert.equal(thread.turns[0]?.message, "先看一下项目，不要猜需求");
      assert.equal(thread.turns[0]?.run.id, started.run.id);
      assert.equal(thread.turns[0]?.run.workingDirectory, f.repo);
      assert.equal(thread.activeRunId, null);

      const changed = await post(`/api/tasks/${id}/messages`, {
        message: "换一个运行时",
        runtimeKind: "codex",
        workingDirectory: f.repo,
      });
      assert.equal(changed.status, 409, "a task conversation cannot switch runtime after it starts");
    });
  } finally {
    await f.dispose();
  }
});

async function withEngine<T>(f: Fixture, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    // PATH goes to the CHILD: the engine spawns the CLIs, not this process.
    env: { ...process.env, TODOAGENT_DB: f.dbPath, TODOAGENT_PORT: String(PORT), PATH: f.stubbedPath },
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
    const verified = await post("/api/runtimes/claude/verify");
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

function runCard(taskId: string, runtimeKind = "claude"): Promise<Response> {
  return post(`/api/tasks/${taskId}/run`, { runtimeKind });
}

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

/** Creates a card, optionally from a message so the source-body path is covered. */
async function makeCard(channelId: string, body: string, asTask: boolean): Promise<string> {
  if (asTask) {
    const res = await json<{ task: { id: string } }>(
      await post(`/api/channels/${channelId}/messages`, { body, asTask: true }),
    );
    return res.task.id;
  }
  const tasks = await json<Array<{ id: string }>>(
    await post(`/api/channels/${channelId}/tasks`, { titles: [body] }),
  );
  return tasks[0]!.id;
}

async function waitForRun(runId: string, until: (status: string) => boolean): Promise<string> {
  const deadline = Date.now() + 60_000;
  let status = "";
  while (Date.now() < deadline) {
    const res = await json<{ run: { status: string } }>(await fetch(`${BASE}/api/runs/${runId}`));
    status = res.run.status;
    if (until(status)) return status;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`run ${runId} never satisfied the condition; last status ${status}`);
}

// ── Refusals ────────────────────────────────────────────────

test("run: an unknown card is 404", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      assert.equal((await runCard("nope")).status, 404);
    });
  } finally {
    await f.dispose();
  }
});

test("run: a channel with no repository is refused, not attempted", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.plainChannelId, "无仓库的任务", false);
      const res = await runCard(id);

      /*
       * Refused rather than started. The pipeline isolates each subtask in a git
       * worktree, so with no repo every run fails at the first step — and the
       * composer already promised this would not execute.
       */
      assert.equal(res.status, 400);
      assert.match((await json<{ error: string }>(res)).error, /未绑定仓库/);

      // And the card is untouched, so nothing looks like it started.
      const board = await json<{ tasks: Array<{ status: string; runId: string | null }> }>(
        await fetch(`${BASE}/api/channels/${f.plainChannelId}/tasks`),
      );
      assert.equal(board.tasks[0]?.status, "todo");
      assert.equal(board.tasks[0]?.runId, null);
    });
  } finally {
    await f.dispose();
  }
});

test("run: requires an explicit verified CLI before writing task or run state", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "先选本机 CLI", false);

      assert.equal((await post(`/api/tasks/${id}/run`)).status, 400, "runtimeKind is required");
      assert.equal(
        (await post(`/api/tasks/${id}/run`, { runtimeKind: "imaginary" })).status,
        400,
        "unknown runtime kinds are schema errors",
      );
      assert.equal(
        (await runCard(id, "codex")).status,
        409,
        "installed but unverified is not executable",
      );

      const list = await json<{ tasks: Array<{ id: string; status: string; runId: string | null }> }>(
        await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`),
      );
      const card = list.tasks.find((task) => task.id === id);
      assert.equal(card?.status, "todo");
      assert.equal(card?.runId, null, "all readiness refusals happen before database writes");
    });
  } finally {
    await f.dispose();
  }
});

// ── The link ────────────────────────────────────────────────

test("run: the card records its run and moves to in_progress", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "把 README 补一句", false);
      const res = await runCard(id);

      assert.equal(res.status, 201);
      const body = await json<{
        run: {
          id: string;
          runtimeKind: string | null;
          runtimeExecPath: string | null;
          runtimeVersion: string | null;
        };
        task: {
          runId: string;
          status: string;
          runtimeKind: string | null;
          assigneeKind: string | null;
          assigneeId: string | null;
        };
      }>(res);
      // The whole point of the feature: task.run_id was never set before this.
      assert.equal(body.task.runId, body.run.id);
      assert.equal(body.task.status, "in_progress");
      assert.equal(body.task.runtimeKind, "claude");
      assert.equal(body.task.assigneeKind, null, "direct CLI dispatch creates no Expert claim");
      assert.equal(body.task.assigneeId, null);
      assert.equal(body.run.runtimeKind, "claude");
      assert.ok(body.run.runtimeExecPath?.endsWith("/claude"));
      assert.match(body.run.runtimeVersion ?? "", /1\.0\.0/);
    });
  } finally {
    await f.dispose();
  }
});

test("run: the goal is the source message, not the truncated card title", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      /*
       * The subtle one. A card title is deliberately trimmed to the message's
       * first line, and the detail — constraints, examples, what "done" means —
       * lives in the rest of the text. Planning from the title alone would discard
       * it at the exact moment it matters most.
       */
      const detail = "给首页加空状态\n必须区分三种：无数据、筛选无结果、加载失败\n每种给不同的行动按钮";
      const id = await makeCard(f.repoChannelId, detail, true);

      const res = await json<{ run: { id: string; goal: string }; task: { title: string } }>(
        await runCard(id),
      );

      assert.equal(res.task.title, "给首页加空状态", "the card stays a one-liner");
      assert.equal(res.run.goal, detail, "but the run gets the whole request");
      assert.match(res.run.goal, /筛选无结果/);
    });
  } finally {
    await f.dispose();
  }
});

test("run: a failed run parks the card in needs_you with the reason attached", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "会失败的任务", false);
      const started = await json<{ run: { id: string } }>(await runCard(id));

      // Every CLI is a refusing stub, so the agent cannot do the work.
      await waitForRun(started.run.id, (s) => s === "failed" || s === "cancelled");

      const task = await json<{
        tasks: Array<{
          status: string;
          runId: string | null;
          needsKind: string | null;
          needsText: string | null;
        }>;
      }>(await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`));
      const card = task.tasks.find((t) => t.runId === started.run.id);

      /*
       * needs_you, not todo: a failure silently returning to the backlog is a
       * hidden failure. A person decides what happens next, and the card carries
       * the reason so they can decide without digging. `run_id` is preserved so
       * the card still links to the attempt that failed.
       */
      assert.equal(card?.status, "needs_you");
      assert.equal(card?.needsKind, "failed");
      assert.ok((card?.needsText ?? "").length > 0, "the reason travels with the card");
      assert.equal(card?.runId, started.run.id);
    });
  } finally {
    await f.dispose();
  }
});

test("run: a second run is refused while the first is live", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const a = await makeCard(f.repoChannelId, "第一个", false);
      const b = await makeCard(f.repoChannelId, "第二个", false);

      const first = await runCard(a);
      assert.equal(first.status, 201);

      /*
       * One run per repository. Two runs merge into the same branch and cut
       * worktrees from the same HEAD; concurrent merges interleave and corrupt the
       * result, which the user cannot undo — unlike being told to wait.
       *
       * Racy by nature: the first run may already have failed against the stubs,
       * in which case 201 is also correct. Both answers are checked rather than
       * asserting on a timing-dependent one.
       */
      const second = await runCard(b);
      assert.ok(
        second.status === 409 || second.status === 201,
        `expected 409 (locked) or 201 (first already finished), got ${second.status}`,
      );
      if (second.status === 409) {
        assert.match((await json<{ error: string }>(second)).error, /another run/);
      }
    });
  } finally {
    await f.dispose();
  }
});

test("reconcile: an interrupted run releases its card instead of stranding it", async () => {
  const f = await fixture();
  try {
    /*
     * The state a crash leaves behind: a run still marked `running`, and a card
     * pointing at it from in_progress. Written directly rather than by starting a
     * real run, because the whole point is what happens when NOTHING is driving it.
     */
    const store = new Store(f.dbPath);
    const project = store.listProjects()[0]!;
    const run = store.createRun({ projectId: project.id, goal: "interrupted" });
    const task = store.createTask({
      channelId: f.repoChannelId,
      title: "被中断的任务",
      status: "in_progress",
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: run.id,
    });
    assert.equal(store.getRun(run.id)?.status, "running", "the fixture must look live");
    store.close();

    // Booting is what triggers reconciliation, before any traffic is accepted.
    await withEngine(f, async () => {
      const board = await json<{
        tasks: Array<{ id: string; status: string; runId: string | null; needsKind: string | null }>;
      }>(await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`));
      const card = board.tasks.find((t) => t.id === task.id);

      /*
       * Parked in needs_you. Marking only the RUN as failed left the board saying
       * work was happening with no way out — and silently returning to todo would
       * hide that the engine died under this task. A person decides what's next.
       */
      assert.equal(card?.status, "needs_you");
      assert.equal(card?.needsKind, "failed");
      assert.equal(card?.runId, run.id, "the link to the interrupted run is kept");

      const detail = await json<{ run: { status: string; error: string | null } }>(
        await fetch(`${BASE}/api/runs/${run.id}`),
      );
      assert.equal(detail.run.status, "failed");
      assert.match(detail.run.error ?? "", /restarted/);
    });
  } finally {
    await f.dispose();
  }
});

test("cancel: a run parked at a gate releases its card", async () => {
  const f = await fixture();
  try {
    /*
     * The state written directly is the state that matters: a run parked at the
     * plan gate, with no AbortController driving it. That is not contrived — the
     * approve-plan endpoint creates its own controller, so a parked run is NOT in
     * `active` while it waits, and the plan gate is on by default, so every
     * card-started run passes through here.
     *
     * Before the fix, cancelling in this state wrote `status: cancelled` and
     * nothing else. No `finally` exists anywhere to catch it, so the card sat at
     * in_progress permanently and the web board polled it forever. Reading a plan,
     * deciding it is wrong, and cancelling is the ordinary way to use this.
     */
    const store = new Store(f.dbPath);
    const project = store.listProjects()[0]!;
    const run = store.createRun({ projectId: project.id, goal: "parked" });
    store.updateRun(run.id, { status: "blocked_on_human", gate: "plan_approval" });
    const task = store.createTask({
      channelId: f.repoChannelId,
      title: "计划不对，取消掉",
      status: "in_progress",
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: run.id,
    });
    store.close();

    await withEngine(f, async () => {
      const res = await post(`/api/runs/${run.id}/cancel`);
      assert.equal(res.status, 200);
      // No controller existed, so nothing was reaped — this is the orphan path.
      assert.equal((await json<{ reaped: boolean }>(res)).reaped, false);

      const board = await json<{ tasks: Array<{ id: string; status: string; runId: string | null }> }>(
        await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`),
      );
      const card = board.tasks.find((t) => t.id === task.id);

      assert.equal(card?.status, "todo", "the card must be released, not left executing");
      assert.equal(card?.runId, run.id, "the link to the cancelled run is kept");

      const detail = await json<{ run: { status: string; gate: string | null } }>(
        await fetch(`${BASE}/api/runs/${run.id}`),
      );
      assert.equal(detail.run.status, "cancelled");
      // The gate is cleared too, or the UI keeps offering "approve plan" on a
      // stopped run.
      assert.equal(detail.run.gate, null);
    });
  } finally {
    await f.dispose();
  }
});

test("run: the same card cannot start a second run while its first is live", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "只跑一次", false);
      const first = await json<{ run: { id: string } }>(await runCard(id));

      // Otherwise the first run keeps going with nothing pointing at it, and the
      // card tracks only the second.
      const again = await runCard(id);
      assert.ok(
        again.status === 409 || again.status === 201,
        `expected 409 or 201 (if the first already failed), got ${again.status}`,
      );

      await waitForRun(first.run.id, (s) => s === "failed" || s === "cancelled");
    });
  } finally {
    await f.dispose();
  }
});
