import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * One run per repository.
 *
 * `active` is keyed by run id, which only ever stopped the SAME run from starting
 * twice. Two DIFFERENT runs on one repository were free to proceed together — and
 * they both merge into the same working branch and both cut worktrees from the
 * same HEAD. Concurrent git merges into one branch interleave and corrupt the
 * result, which the user cannot undo; being told to wait costs them nothing.
 *
 * A fake `claude` that stalls gives a deterministic window in which a run is
 * genuinely in flight, so the guard is exercised rather than assumed.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8805; // distinct from the SSE/reconcile/transcript suites

/** Seconds the fake planner stalls, holding the run in `active`. */
const STALL_SECONDS = 5;

interface Harness {
  dbPath: string;
  projectA: string;
  projectB: string;
  dispose: () => Promise<void>;
}

/**
 * A fake planner that stalls, then returns a valid one-subtask plan.
 *
 * Stalling is the whole point: it keeps the run in `active` long enough to assert
 * on the lock. It then emits a real plan so the run parks cleanly at the approval
 * gate instead of failing for an unrelated reason.
 */
const FAKE_CLAUDE = `#!/usr/bin/env node
const plan = JSON.stringify({
  summary: "one step",
  subtasks: [{
    id: "a", title: "t", brief: "b", acceptance: "a",
    capability: "general", stage: 0, dependsOn: [],
  }],
});
setTimeout(() => {
  process.stdout.write(JSON.stringify({
    is_error: false,
    session_id: "fake",
    result: plan,
    usage: { input_tokens: 10, output_tokens: 5 },
    type: "result",
  }) + "\\n");
}, ${STALL_SECONDS} * 1000);
`;

async function gitRepo(dir: string): Promise<void> {
  const run = (args: string[]): Promise<void> =>
    new Promise((resolve) => {
      const c = spawn("git", args, { cwd: dir, stdio: "ignore" });
      c.on("close", () => resolve());
      c.on("error", () => resolve());
    });
  await run(["init", "-q", "-b", "main", "."]);
  await writeFile(join(dir, "README.md"), "# fixture\n", "utf8");
  await run(["add", "-A"]);
  await run(["-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"]);
}

async function fixture(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-lock-"));
  const binDir = join(root, "bin");
  const repoA = join(root, "repo-a");
  const repoB = join(root, "repo-b");
  await mkdir(binDir, { recursive: true });
  await mkdir(repoA, { recursive: true });
  await mkdir(repoB, { recursive: true });
  await gitRepo(repoA);
  await gitRepo(repoB);

  for (const name of ["claude", "codex"]) {
    const p = join(binDir, name);
    await writeFile(p, FAKE_CLAUDE, "utf8");
    await chmod(p, 0o755);
  }

  const dbPath = join(root, "lock.db");
  const store = new Store(dbPath);
  const expert = store.createExpert({
    name: "Planner",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "orchestrator");
  store.addTeamMember(team.id, expert.id, "maker");
  const projectA = store.createProject({ name: "a", repoPath: repoA, teamId: team.id }).id;
  const projectB = store.createProject({ name: "b", repoPath: repoB, teamId: team.id }).id;
  store.close();

  return {
    dbPath,
    projectA,
    projectB,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

async function withEngine<T>(h: Harness, fn: () => Promise<T>): Promise<T> {
  const binDir = join(h.dbPath, "..", "bin");
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: h.dbPath,
      TODOAGENT_PORT: String(PORT),
      // Fakes ahead of the real CLIs, so no real agent turn is spent.
      PATH: `${binDir}${delimiter}${process.env["PATH"] ?? ""}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const deadline = Date.now() + 30_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error("engine did not start within 30s");
      try {
        const res = await fetch(`http://127.0.0.1:${PORT}/api/health`);
        if (res.ok) break;
      } catch {
        /* not listening yet */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    return await fn();
  } finally {
    child.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 250));
  }
}

function startRun(projectId: string, goal: string): Promise<Response> {
  return fetch(`http://127.0.0.1:${PORT}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ projectId, goal, budgetTokens: 100_000 }),
  });
}

test("a second run on the same repository is refused while the first works", async () => {
  const h = await fixture();
  try {
    await withEngine(h, async () => {
      const first = await startRun(h.projectA, "first");
      assert.equal(first.status, 201);
      const firstRun = (await first.json()) as { id: string };

      // The planner is stalling, so this run is genuinely in flight.
      const second = await startRun(h.projectA, "second");

      /*
       * The guard. Both runs would merge into the same working branch and cut
       * worktrees from the same HEAD; interleaved git merges corrupt the branch in
       * a way no retry undoes.
       */
      assert.equal(second.status, 409, "a concurrent run on one repository must be refused");
      const body = (await second.json()) as { error: string; busyRunId?: string };
      assert.match(body.error, /already working in this repository/);
      // The conflicting run is named, so the user can go look at it rather than
      // guessing why they were refused.
      assert.equal(body.busyRunId, firstRun.id);
    });
  } finally {
    await h.dispose();
  }
});

test("a run on a DIFFERENT repository is allowed", async () => {
  const h = await fixture();
  try {
    await withEngine(h, async () => {
      const first = await startRun(h.projectA, "on repo a");
      assert.equal(first.status, 201);

      const other = await startRun(h.projectB, "on repo b");
      /*
       * The lock must be per repository, not global. Making it global would be the
       * easy mistake and would needlessly serialise unrelated work — the hazard is
       * two agents merging into ONE branch, which cannot happen across repos.
       */
      assert.equal(other.status, 201, "different repositories must not block each other");
    });
  } finally {
    await h.dispose();
  }
});

test("the repository frees up once the run stops working", async () => {
  const h = await fixture();
  try {
    await withEngine(h, async () => {
      const first = await startRun(h.projectA, "first");
      const firstRun = (await first.json()) as { id: string };

      // Blocked while in flight.
      assert.equal((await startRun(h.projectA, "blocked")).status, 409);

      // Cancelling releases the lock; the run is no longer touching the repo.
      const cancel = await fetch(`http://127.0.0.1:${PORT}/api/runs/${firstRun.id}/cancel`, {
        method: "POST",
      });
      assert.equal(cancel.status, 200);

      // The abort has to propagate out of the pipeline before `active` is cleared.
      const deadline = Date.now() + 20_000;
      let allowed: Response | null = null;
      for (;;) {
        const attempt = await startRun(h.projectA, "after cancel");
        if (attempt.status === 201) {
          allowed = attempt;
          break;
        }
        void attempt.text();
        if (Date.now() > deadline) break;
        await new Promise((r) => setTimeout(r, 300));
      }
      assert.ok(allowed, "the repository must become available again after a cancel");
    });
  } finally {
    await h.dispose();
  }
});
