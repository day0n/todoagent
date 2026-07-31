import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@council/core";

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
  const root = await mkdtemp(join(tmpdir(), "council-taskrun-"));
  const repo = join(root, "repo");
  const binDir = join(root, "bin");
  await mkdir(repo, { recursive: true });
  await mkdir(binDir, { recursive: true });

  // A real git repository: worktree isolation is not mocked anywhere in this repo.
  await git(["init", "-q", "-b", "main", "."], repo);
  await writeFile(join(repo, "README.md"), "# fixture\n", "utf8");
  await git(["add", "-A"], repo);
  await git(["-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"], repo);

  for (const name of AGENT_EXECUTABLES) {
    const path = join(binDir, name);
    await writeFile(
      path,
      `#!/usr/bin/env node\nprocess.stderr.write(${JSON.stringify(`${name} is stubbed\n`)});\nprocess.exit(3);\n`,
      "utf8",
    );
    await chmod(path, 0o755);
  }

  const dbPath = join(root, "t.db");
  const store = new Store(dbPath);
  const expert = store.createExpert({
    name: "Solo",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const team = store.createTeam("t");
  for (const role of ["orchestrator", "maker", "reviewer", "verifier"] as const) {
    store.addTeamMember(team.id, expert.id, role);
  }
  const project = store.createProject({ name: "p", repoPath: repo, teamId: team.id });

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
    stubbedPath: `${binDir}${delimiter}${process.env["PATH"] ?? ""}`,
    repoChannelId: withRepo.id,
    plainChannelId: plain.id,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

async function withEngine<T>(f: Fixture, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    // PATH goes to the CHILD: the engine spawns the CLIs, not this process.
    env: { ...process.env, COUNCIL_DB: f.dbPath, COUNCIL_PORT: String(PORT), PATH: f.stubbedPath },
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
      assert.equal((await post("/api/tasks/nope/run")).status, 404);
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
      const res = await post(`/api/tasks/${id}/run`);

      /*
       * Refused rather than started. The pipeline isolates each subtask in a git
       * worktree, so with no repo every run fails at the first step — and the
       * composer already promised this would not execute.
       */
      assert.equal(res.status, 400);
      assert.match((await json<{ error: string }>(res)).error, /未关联仓库/);

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

// ── The link ────────────────────────────────────────────────

test("run: the card records its run and moves to in_progress", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "把 README 补一句", false);
      const res = await post(`/api/tasks/${id}/run`);

      assert.equal(res.status, 201);
      const body = await json<{ run: { id: string }; task: { runId: string; status: string } }>(res);
      // The whole point of the feature: task.run_id was never set before this.
      assert.equal(body.task.runId, body.run.id);
      assert.equal(body.task.status, "in_progress");
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
        await post(`/api/tasks/${id}/run`),
      );

      assert.equal(res.task.title, "给首页加空状态", "the card stays a one-liner");
      assert.equal(res.run.goal, detail, "but the run gets the whole request");
      assert.match(res.run.goal, /筛选无结果/);
    });
  } finally {
    await f.dispose();
  }
});

test("run: a failed run puts the card back in todo, keeping the run link", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "会失败的任务", false);
      const started = await json<{ run: { id: string } }>(await post(`/api/tasks/${id}/run`));

      // Every CLI is a refusing stub, so the planner cannot produce a plan.
      await waitForRun(started.run.id, (s) => s === "failed" || s === "cancelled");

      const task = await json<{ tasks: Array<{ status: string; runId: string | null }> }>(
        await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`),
      );
      const card = task.tasks.find((t) => t.runId === started.run.id);

      /*
       * Back to todo, not left in_progress: a card claiming work is happening when
       * nothing is running is the misleading state. `run_id` is preserved so the
       * card still links to the attempt that failed.
       */
      assert.equal(card?.status, "todo");
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

      const first = await post(`/api/tasks/${a}/run`);
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
      const second = await post(`/api/tasks/${b}/run`);
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
      const board = await json<{ tasks: Array<{ id: string; status: string; runId: string | null }> }>(
        await fetch(`${BASE}/api/channels/${f.repoChannelId}/tasks`),
      );
      const card = board.tasks.find((t) => t.id === task.id);

      /*
       * Back to todo. Marking only the RUN as failed left the board saying work
       * was happening with no way out — the web board's live-run inference would
       * stay true forever, so it polls indefinitely watching a value that can
       * never change again.
       */
      assert.equal(card?.status, "todo");
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

test("run: the same card cannot start a second run while its first is live", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const id = await makeCard(f.repoChannelId, "只跑一次", false);
      const first = await json<{ run: { id: string } }>(await post(`/api/tasks/${id}/run`));

      // Otherwise the first run keeps going with nothing pointing at it, and the
      // card tracks only the second.
      const again = await post(`/api/tasks/${id}/run`);
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
