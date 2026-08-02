import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Project creation validation.
 *
 * The pipeline refuses to run outside a git repository, because worktree
 * isolation is the only thing stopping parallel agents from overwriting each
 * other's files. Without validation at creation time that failure surfaced as far
 * from its cause as possible: the project was created happily, and then every
 * single run failed with an error about git.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8807; // distinct from the other engine suites

interface Fixture {
  dbPath: string;
  teamId: string;
  root: string;
  repo: string;
  plainDir: string;
  dispose: () => Promise<void>;
}

async function gitInit(dir: string): Promise<void> {
  const run = (args: string[]): Promise<void> =>
    new Promise((done) => {
      const c = spawn("git", args, { cwd: dir, stdio: "ignore" });
      c.on("close", () => done());
      c.on("error", () => done());
    });
  await run(["init", "-q", "-b", "main", "."]);
  await writeFile(join(dir, "README.md"), "# fixture\n", "utf8");
  await run(["add", "-A"]);
  await run(["-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"]);
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-projects-"));
  const repo = join(root, "a-real-repo");
  const plainDir = join(root, "not-a-repo");
  await mkdir(repo, { recursive: true });
  await mkdir(plainDir, { recursive: true });
  await gitInit(repo);

  const dbPath = join(root, "p.db");
  const store = new Store(dbPath);
  const expert = store.createExpert({
    name: "Solo",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  // A second team with nobody on it, for the empty-roster case. Located through
  // the API in that test rather than threaded through here.
  store.createTeam("empty-team");
  store.close();

  return {
    dbPath,
    teamId: team.id,
    root,
    repo,
    plainDir,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

/**
 * Boots the engine, optionally from a specific working directory.
 *
 * `cwd` matters for the relative-path test: a relative repoPath is resolved
 * against the ENGINE's cwd, so leaving it to whatever directory the test runner
 * happened to start in makes the assertion depend on the machine.
 */
async function withEngine<T>(dbPath: string, fn: () => Promise<T>, cwd?: string): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: { ...process.env, TODOAGENT_DB: dbPath, TODOAGENT_PORT: String(PORT) },
    ...(cwd !== undefined ? { cwd } : {}),
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
    await new Promise((r) => setTimeout(r, 200));
  }
}

function createProject(body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${PORT}/api/projects`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("a non-git directory is refused at creation, not at run time", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await createProject({
        name: "doomed",
        repoPath: f.plainDir,
        teamId: f.teamId,
      });

      assert.equal(res.status, 400);
      const body = (await res.json()) as { error: string };
      // The message has to say what to DO about it: the user is looking at a
      // directory that exists and looks fine.
      assert.match(body.error, /not a git repository/);
      assert.match(body.error, /git init/);

      // And nothing was stored, so the failure cannot resurface later.
      const list = (await (await fetch(`http://127.0.0.1:${PORT}/api/projects`)).json()) as unknown[];
      assert.equal(list.length, 0);
    });
  } finally {
    await f.dispose();
  }
});

test("a real repository is accepted", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await createProject({ name: "good", repoPath: f.repo, teamId: f.teamId });
      assert.equal(res.status, 201);
      const project = (await res.json()) as { repoPath: string; name: string };
      assert.equal(project.name, "good");
      assert.equal(project.repoPath, resolve(f.repo));
    });
  } finally {
    await f.dispose();
  }
});

test("a relative path is resolved to an absolute one", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      /*
       * A relative path is resolved against the ENGINE's working directory, which
       * the user can neither see nor predict — so without `resolve()` it would
       * silently point somewhere other than where they meant.
       *
       * The engine is booted IN the fixture repo below, which is what makes "."
       * meaningful here. Relying on the test runner's own cwd made this assertion
       * depend on the machine: it resolved to apps/engine, which is not a git
       * repository, so the request was (correctly) rejected.
       */
      const res = await createProject({ name: "relative", repoPath: ".", teamId: f.teamId });
      assert.equal(res.status, 201);
      const project = (await res.json()) as { repoPath: string };
      assert.notEqual(project.repoPath, ".");
      assert.ok(project.repoPath.startsWith("/"), `expected an absolute path, got ${project.repoPath}`);
      // And it points at the repo the engine was launched in, not at "." verbatim.
      assert.match(project.repoPath, /a-real-repo$/);
    }, f.repo);
  } finally {
    await f.dispose();
  }
});

test("a missing directory is refused", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await createProject({
        name: "ghost",
        repoPath: join(f.root, "does-not-exist"),
        teamId: f.teamId,
      });
      // A path that is not there cannot be a repository; the same 400 covers it
      // rather than surfacing an ENOENT later.
      assert.equal(res.status, 400);
      assert.match(((await res.json()) as { error: string }).error, /not a git repository/);
    });
  } finally {
    await f.dispose();
  }
});

test("a team with no members is refused", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const teams = (await (await fetch(`http://127.0.0.1:${PORT}/api/teams`)).json()) as Array<{
        id: string;
        members: unknown[];
      }>;
      const empty = teams.find((t) => t.members.length === 0);
      assert.ok(empty, "the fixture includes a team with no members");

      const res = await createProject({ name: "no-team", repoPath: f.repo, teamId: empty.id });
      // A project whose team cannot staff a run is unusable; catching it here beats
      // failing at planning time.
      assert.equal(res.status, 400);
      assert.match(((await res.json()) as { error: string }).error, /no members/);
    });
  } finally {
    await f.dispose();
  }
});
