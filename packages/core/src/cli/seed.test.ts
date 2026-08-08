import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defaultExecutableForRuntime } from "../adapters/index.ts";
import { Store } from "../db/index.ts";
import { RUNTIME_KINDS } from "../types.ts";

/**
 * What `pnpm seed` actually writes.
 *
 * Run as a subprocess against a scratch database, because that is the only way to
 * exercise the real entry point — argv parsing, the git check, and the exit code all
 * live in `main()`.
 *
 * PATH is stubbed with all six supported CLI names, ahead of the small system PATH
 * needed for Git. `which()` also searches common install directories, so stubbing
 * only Claude is insufficient: another developer's real Codex could otherwise be
 * version-probed by this test. Providing all six names guarantees every CLI process
 * is ours, and the invocation log verifies seed only asks for `--version`.
 */

const SEED = join(fileURLToPath(new URL(".", import.meta.url)), "seed.ts");

interface Fixture {
  root: string;
  dbPath: string;
  repo: string;
  stubbedPath: string;
  stubLog: string;
  dispose: () => Promise<void>;
}

function run(args: string[], cwd: string): Promise<void> {
  return new Promise((done) => {
    const c = spawn(args[0] ?? "", args.slice(1), { cwd, stdio: "ignore" });
    c.on("close", () => done());
    c.on("error", () => done());
  });
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-seed-"));
  const repo = join(root, "myrepo");
  const binDir = join(root, "bin");
  await mkdir(repo, { recursive: true });
  await mkdir(binDir, { recursive: true });

  await run(["git", "init", "-q", "-b", "main", "."], repo);
  await writeFile(join(repo, "README.md"), "# fixture\n", "utf8");
  await run(["git", "add", "-A"], repo);
  await run(
    ["git", "-c", "user.name=T", "-c", "user.email=t@l", "commit", "-q", "-m", "init"],
    repo,
  );

  const stubLog = join(root, "cli-invocations.log");
  for (const kind of RUNTIME_KINDS) {
    const stub = join(binDir, defaultExecutableForRuntime(kind));
    await writeFile(
      stub,
      "#!/bin/sh\nprintf '%s %s\\n' \"$0\" \"$*\" >> \"$TODOAGENT_STUB_LOG\"\nprintf '9.9.9 (stub)\\n'\n",
      "utf8",
    );
    await chmod(stub, 0o755);
  }

  return {
    root,
    dbPath: join(root, "seed.db"),
    repo,
    // Deliberately excludes the ambient PATH. Git is the only external program
    // seed needs besides our six stubs, and macOS/Linux provide it in these dirs.
    stubbedPath: [binDir, "/usr/bin", "/bin"].join(delimiter),
    stubLog,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

interface Result {
  code: number | null;
  out: string;
}

function seed(f: Fixture, args: string[], opts: { db?: string } = {}): Promise<Result> {
  return new Promise((done) => {
    const child = spawn(process.execPath, ["--experimental-strip-types", SEED, ...args], {
      env: {
        ...process.env,
        TODOAGENT_DB: opts.db ?? f.dbPath,
        TODOAGENT_STUB_LOG: f.stubLog,
        PATH: f.stubbedPath,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d: Buffer) => (out += d.toString()));
    child.stderr.on("data", (d: Buffer) => (out += d.toString()));
    child.on("close", (code) => done({ code, out }));
  });
}

test("seed <repo>: detected CLIs and one repository-bound list without experts or an inbox", async () => {
  const f = await fixture();
  try {
    const res = await seed(f, [f.repo]);
    assert.equal(res.code, 0, res.out);

    const store = new Store(f.dbPath);
    try {
      assert.equal(store.listExperts().length, 0, "CLI detection must not manufacture personas");
      assert.match(res.out, /本机 CLI/);
      for (const kind of RUNTIME_KINDS) assert.match(res.out, new RegExp(`\\b${kind}\\b`));

      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      assert.ok(!lists.some((ch) => ch.name === "收件箱"), "seed must not invent a default inbox");

      const bound = lists.find((ch) => ch.name === "myrepo");
      assert.ok(bound, "a list named after the repository directory");
      assert.ok(bound.projectId, "bound to a project, which is what makes it dispatchable");

      const project = store.getProject(bound.projectId);
      assert.ok(project);
      assert.equal(project.repoPath, f.repo);

      /*
       * `project.team_id` is NOT NULL — pipeline-era schema. The compatibility
       * Team is internal and deliberately empty: direct CLI dispatch has no roster.
       */
      assert.ok(project.teamId, "an internal team satisfies the NOT NULL column");
      assert.equal(store.getTeamByName("todoagent-internal")?.id, project.teamId);
      const members = store.listTeamMembers(project.teamId);
      assert.deepEqual(members, [], "no Expert is assigned a role");

      // No DMs. `GET /api/lists` returns only `kind: "channel"`, so a DM created
      // here would be invisible in the product being seeded.
      assert.equal(
        store.listChannels().filter((ch) => ch.kind === "dm").length,
        0,
        "seed no longer creates DM channels",
      );

      const invocations = (await readFile(f.stubLog, "utf8"))
        .trim()
        .split("\n")
        .filter(Boolean);
      assert.equal(invocations.length, RUNTIME_KINDS.length, "each CLI is version-probed once");
      assert.deepEqual(
        invocations.map((line) => basename(line.split(" ")[0] ?? "")).sort(),
        RUNTIME_KINDS.map(defaultExecutableForRuntime).sort(),
      );
      assert.ok(invocations.every((line) => line.endsWith(" --version")), "seed never runs a real turn");
    } finally {
      store.close();
    }
  } finally {
    await f.dispose();
  }
});

test("seed: re-running finds what exists instead of stacking duplicates", async () => {
  const f = await fixture();
  try {
    assert.equal((await seed(f, [f.repo])).code, 0);
    assert.equal((await seed(f, [f.repo])).code, 0);

    const store = new Store(f.dbPath);
    try {
      assert.equal(store.listExperts().length, 0);
      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      assert.equal(lists.filter((l) => l.name === "myrepo").length, 1);
      assert.equal(lists.length, 1);
      assert.equal(store.listProjects().length, 1, "the project is matched by repo path");
      assert.equal(store.listTeams().length, 1, "the internal compatibility team is reused");
      assert.equal(store.listTeamMembers(store.listTeams()[0]?.id ?? "").length, 0);
    } finally {
      store.close();
    }
  } finally {
    await f.dispose();
  }
});

test("seed with no argument: detects CLIs but creates no inbox, identity, or project rows", async () => {
  const f = await fixture();
  try {
    const res = await seed(f, []);
    assert.equal(res.code, 0, res.out);
    // The message has to be honest about the limit rather than implying readiness.
    assert.match(res.out, /还没有能派发的清单/);

    const store = new Store(f.dbPath);
    try {
      assert.equal(store.listExperts().length, 0);
      assert.equal(store.listTeams().length, 0, "no project means no compatibility Team is needed");
      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      assert.deepEqual(lists, []);
      assert.equal(store.listProjects().length, 0, "no repository means no project");
    } finally {
      store.close();
    }
  } finally {
    await f.dispose();
  }
});

test("seed: a path that is not a git repository is refused, and nothing is written", async () => {
  const f = await fixture();
  try {
    const notARepo = join(f.root, "plain");
    await mkdir(notARepo, { recursive: true });
    const db = join(f.root, "untouched.db");

    const res = await seed(f, [notARepo], { db });
    assert.equal(res.code, 1, "a refusal is a failure exit, not a quiet success");
    assert.match(res.out, /不是 git 仓库/);

    /*
     * The database file must not even exist.
     *
     * The check runs BEFORE the store is opened, deliberately: `POST /api/lists`
     * refuses a non-repository path, so creating one here would produce a list the
     * HTTP API would never have allowed, and every task on it would fail at dispatch
     * with nothing on the card to explain why.
     */
    await assert.rejects(() => access(db), "the store was never opened");
  } finally {
    await f.dispose();
  }
});
