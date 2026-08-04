import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, writeFile, rm, access } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "../db/index.ts";
import { detectAll } from "../adapters/index.ts";

/**
 * What `pnpm seed` actually writes.
 *
 * Run as a subprocess against a scratch database, because that is the only way to
 * exercise the real entry point — argv parsing, the git check, and the exit code all
 * live in `main()`.
 *
 * PATH is stubbed with exactly one fake `claude` so the result does not depend on
 * which CLIs the machine happens to have installed. Without that, this suite would
 * assert a different number of experts on every developer's laptop.
 */

const SEED = join(fileURLToPath(new URL(".", import.meta.url)), "seed.ts");

interface Fixture {
  root: string;
  dbPath: string;
  repo: string;
  stubbedPath: string;
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

  /*
   * A stub that answers `--version` and nothing else.
   *
   * `detect()` resolves the executable and probes its version; it never runs a turn,
   * so this is enough to make seed believe claude is installed.
   */
  const stub = join(binDir, "claude");
  await writeFile(stub, "#!/usr/bin/env node\nprocess.stdout.write('9.9.9 (stub)\\n');\n", "utf8");
  await chmod(stub, 0o755);

  return {
    root,
    dbPath: join(root, "seed.db"),
    repo,
    stubbedPath: `${binDir}${delimiter}${process.env["PATH"] ?? ""}`,
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

test("seed <repo>: an expert, the inbox, and a list bound to the repository", async () => {
  const f = await fixture();
  try {
    const res = await seed(f, [f.repo]);
    assert.equal(res.code, 0, res.out);

    const store = new Store(f.dbPath);
    try {
      /*
       * One expert per DETECTED runtime — computed here rather than written as a
       * number.
       *
       * A stubbed PATH cannot make this deterministic: `which()` also searches
       * /opt/homebrew/bin, /usr/local/bin, ~/.local/bin and ~/.bun/bin
       * unconditionally, deliberately, so that a GUI-launched process with a minimal
       * PATH does not report every CLI as missing. Asserting a hard-coded count
       * therefore passes only on a machine with exactly that many CLIs installed.
       * The real contract is the mapping, and that is what this checks.
       */
      const detected = await detectAll();
      const experts = store.listExperts();
      assert.equal(experts.length, detected.length, "one expert per detected CLI");
      assert.deepEqual(
        [...new Set(experts.map((e) => e.runtimeKind))].sort(),
        [...new Set(detected.map((d) => d.kind))].sort(),
        "and they cover exactly the runtimes that were found",
      );
      for (const e of experts) {
        assert.ok(e.name.length > 0, "each expert is named from its profile");
        assert.ok(e.systemPrompt.length > 0, `${e.name} carries its profile's prompt`);
      }

      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      /*
       * The inbox's name must match the engine's `DEFAULT_LIST_NAME` exactly. The
       * engine finds its inbox by name and creates one on demand if it cannot, so a
       * different spelling here leaves the user with two inboxes and their tasks
       * split between them.
       */
      const inbox = lists.find((ch) => ch.name === "收件箱");
      assert.ok(inbox, `expected an inbox, saw ${lists.map((l) => l.name).join(", ")}`);
      assert.equal(inbox.projectId, null, "the inbox is a plain todo list");

      const bound = lists.find((ch) => ch.name === "myrepo");
      assert.ok(bound, "a list named after the repository directory");
      assert.ok(bound.projectId, "bound to a project, which is what makes it dispatchable");

      const project = store.getProject(bound.projectId);
      assert.ok(project);
      assert.equal(project.repoPath, f.repo);

      /*
       * `project.team_id` is NOT NULL — pipeline-era schema. A stub team satisfies
       * it, matching what `POST /api/lists` does, and every expert joins in every
       * role so the retained six-phase route does not 500 on a seeded project.
       */
      assert.ok(project.teamId, "a stub team satisfies the NOT NULL column");
      const members = store.listTeamMembers(project.teamId);
      assert.ok(members.length > 0, "the roster is populated");
      const roles = new Set(members.map((m) => m.role));
      for (const role of ["orchestrator", "maker", "reviewer", "verifier"]) {
        assert.ok(roles.has(role as never), `role ${role} is covered`);
      }

      // No DMs. `GET /api/lists` returns only `kind: "channel"`, so a DM created
      // here would be invisible in the product being seeded.
      assert.equal(
        store.listChannels().filter((ch) => ch.kind === "dm").length,
        0,
        "seed no longer creates DM channels",
      );
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
      // Experts are reused BY NAME, so two runs must leave as many as one run did.
      assert.equal(
        store.listExperts().length,
        (await detectAll()).length,
        "re-seeding reuses experts by name rather than duplicating them",
      );
      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      assert.equal(lists.filter((l) => l.name === "收件箱").length, 1);
      assert.equal(lists.filter((l) => l.name === "myrepo").length, 1);
      assert.equal(store.listProjects().length, 1, "the project is matched by repo path");
    } finally {
      store.close();
    }
  } finally {
    await f.dispose();
  }
});

test("seed with no argument: agents and the inbox, and it says nothing can run yet", async () => {
  const f = await fixture();
  try {
    const res = await seed(f, []);
    assert.equal(res.code, 0, res.out);
    // The message has to be honest about the limit rather than implying readiness.
    assert.match(res.out, /还没有能派发的清单/);

    const store = new Store(f.dbPath);
    try {
      assert.ok(store.listExperts().length > 0, "agents are still created");
      const lists = store.listChannels().filter((ch) => ch.kind === "channel");
      assert.deepEqual(lists.map((l) => l.name), ["收件箱"]);
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

/*
 * NOT TESTED HERE: the "no CLI installed" path.
 *
 * It cannot be reached from a test on a machine that has any agent CLI. `which()`
 * searches /opt/homebrew/bin, /usr/local/bin, ~/.local/bin and ~/.bun/bin in
 * addition to PATH — unconditionally and on purpose, so that a GUI-launched process
 * with a minimal PATH does not report every CLI as missing (see util/which.ts).
 * Scrubbing PATH therefore proves nothing, and a test that passed only on a machine
 * with zero CLIs installed would be worse than no test: it would sit green in CI
 * while asserting nothing.
 *
 * The branch itself is three lines — `detected.length === 0` prints a message naming
 * the CLIs to install and sets exit code 1 — and is exercised by hand.
 */
