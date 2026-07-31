import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  commitAll,
  createWorktree,
  currentHead,
  deleteBranchIfMerged,
  diffAgainst,
  git,
  isGitRepo,
  listCouncilBranches,
  mergeBranch,
  pruneWorktrees,
} from "./git.ts";

/**
 * Worktree isolation is the precondition for running several agents at once, so
 * these tests use real git rather than a mock — the failure mode being guarded
 * against (agents silently overwriting each other, or their work vanishing) is
 * exactly the kind a mock would hide.
 */

async function repo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "council-git-test-"));
  await git(["init", "-q", "-b", "main", "."], dir);
  await writeFile(join(dir, "a.txt"), "one\n", "utf8");
  await git(["add", "-A"], dir);
  await git(
    ["-c", "user.name=T", "-c", "user.email=t@localhost", "commit", "-q", "-m", "init"],
    dir,
  );
  return dir;
}

test("isGitRepo distinguishes a repo from a plain directory", async () => {
  const dir = await repo();
  const plain = await mkdtemp(join(tmpdir(), "council-plain-"));
  try {
    assert.equal(await isGitRepo(dir), true);
    assert.equal(await isGitRepo(plain), false);
    // The pipeline refuses to start without this — parallel agents in one tree
    // would overwrite each other.
    assert.equal(await isGitRepo("/definitely/not/here"), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
    await rm(plain, { recursive: true, force: true });
  }
});

test("dispose removes the directory but KEEPS the branch", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "keeps-branch");
    await writeFile(join(wt.path, "new.txt"), "content\n", "utf8");
    const sha = await commitAll(wt.path, "work");
    assert.ok(sha, "the commit should exist");

    await wt.dispose();

    /*
     * Regression guard. dispose() used to delete the branch as well, which threw
     * away every agent's output: subtasks are disposed as they finish, and the
     * merge phase runs afterwards — so by the time it looked for these branches
     * they were already gone and the whole run produced nothing.
     */
    assert.equal(existsSync(wt.path), false, "the working directory is disposable");
    const branches = await git(["branch", "--list", wt.branch], dir);
    assert.ok(branches.stdout.includes(wt.branch), "the branch is the deliverable and must survive");

    const show = await git(["show", "--stat", "--oneline", wt.branch], dir);
    assert.ok(show.stdout.includes("new.txt"), "the committed work is still reachable");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("deleteBranch REFUSES to drop unmerged work", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "unmerged");
    await writeFile(join(wt.path, "x.txt"), "only copy of this work\n", "utf8");
    await commitAll(wt.path, "work");
    await wt.dispose();

    /*
     * The data-loss guard. A council/* branch is frequently the ONLY copy of an
     * agent's output — a subtask that failed review, or one whose run crashed —
     * so deletion uses git's merged-check (`branch -d`) rather than a force
     * delete. It is a no-op exactly when it would destroy something.
     */
    const deleted = await wt.deleteBranch();
    assert.equal(deleted, false, "an unmerged branch must not be deleted");

    const branches = await git(["branch", "--list", wt.branch], dir);
    assert.ok(branches.stdout.includes(wt.branch), "the branch survives");
    const show = await git(["show", `${wt.branch}:x.txt`], dir);
    assert.match(show.stdout, /only copy of this work/, "and the work is still readable");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("deleteBranch drops a branch whose work is already merged", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "merged");
    await writeFile(join(wt.path, "y.txt"), "y\n", "utf8");
    await commitAll(wt.path, "work");
    await wt.dispose();
    assert.equal((await mergeBranch(dir, wt.branch)).code, 0);

    // Now nothing is lost by deleting it, so the repository gets tidied instead
    // of accumulating one branch per subtask forever.
    assert.equal(await wt.deleteBranch(), true);
    const branches = await git(["branch", "--list", wt.branch], dir);
    assert.equal(branches.stdout.trim(), "");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("pruneWorktrees clears registrations left by a crash", async () => {
  const dir = await repo();
  try {
    const wts = [
      await createWorktree(dir, "crash-a"),
      await createWorktree(dir, "crash-b"),
      await createWorktree(dir, "crash-c"),
    ];
    const live = await createWorktree(dir, "still-running");

    /*
     * Simulate a killed process: the directories vanish without dispose() ever
     * running. git keeps the registration forever, flagged `prunable`, and
     * nothing prunes it on its own — measured as three permanent stale entries in
     * the user's repository that new worktrees did not clear.
     */
    for (const wt of wts) await rm(wt.path, { recursive: true, force: true });

    const before = await git(["worktree", "list"], dir);
    assert.equal(
      before.stdout.split("\n").filter((l) => l.includes("prunable")).length,
      3,
      "three stale registrations exist before pruning",
    );

    await pruneWorktrees(dir);

    const after = await git(["worktree", "list"], dir);
    assert.equal(
      after.stdout.split("\n").filter((l) => l.includes("prunable")).length,
      0,
      "stale registrations are gone",
    );
    // A worktree whose directory still exists must be untouched, or pruning would
    // break a concurrently running subtask.
    assert.ok(after.stdout.includes(live.path), "the live worktree survives pruning");

    await live.dispose();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("listCouncilBranches reports leftover work and ignores other branches", async () => {
  const dir = await repo();
  try {
    await git(["branch", "feature/unrelated"], dir);
    const a = await createWorktree(dir, "left-a");
    await writeFile(join(a.path, "a.txt"), "a\n", "utf8");
    await commitAll(a.path, "a");
    await a.dispose();

    const listed = await listCouncilBranches(dir);
    // Used to tell the user exactly what is recoverable and where; a plain
    // "nothing merged" message would not say that.
    assert.deepEqual(listed, [a.branch]);
    assert.ok(!listed.includes("feature/unrelated"), "unrelated branches are not reported");
    assert.ok(!listed.includes("main"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("deleteBranchIfMerged tolerates a branch that does not exist", async () => {
  const dir = await repo();
  try {
    // Reachable when two cleanup paths race; must report false, not throw.
    assert.equal(await deleteBranchIfMerged(dir, "council/never-existed"), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("dispose is idempotent", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "twice");
    await wt.dispose();
    // The pipeline's finally block can run twice on some failure paths.
    await assert.doesNotReject(() => wt.dispose());
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("parallel worktrees are genuinely isolated", async () => {
  const dir = await repo();
  try {
    const [a, b] = await Promise.all([
      createWorktree(dir, "agent-a"),
      createWorktree(dir, "agent-b"),
    ]);
    try {
      assert.notEqual(a.path, b.path);
      assert.notEqual(a.branch, b.branch);

      // Both edit the SAME file — the collision this design exists to prevent.
      await writeFile(join(a.path, "a.txt"), "from agent A\n", "utf8");
      await writeFile(join(b.path, "a.txt"), "from agent B\n", "utf8");
      await commitAll(a.path, "A");
      await commitAll(b.path, "B");

      const showA = await git(["show", `${a.branch}:a.txt`], dir);
      const showB = await git(["show", `${b.branch}:a.txt`], dir);
      assert.equal(showA.stdout.trim(), "from agent A");
      assert.equal(showB.stdout.trim(), "from agent B", "neither agent saw the other's edit");
    } finally {
      await a.dispose();
      await b.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("createWorktree sanitizes a title into a usable branch name", async () => {
  const dir = await repo();
  try {
    // Plan titles are model-generated prose: spaces, slashes, punctuation, CJK.
    const wt = await createWorktree(dir, "Add dark mode / 深色模式 (v2)!");
    try {
      assert.match(wt.branch, /^council\//);
      assert.ok(!wt.branch.includes(" "), "a space would break the ref");
      const rev = await git(["rev-parse", "--verify", wt.branch], dir);
      assert.equal(rev.code, 0, "the branch must be a valid ref");
    } finally {
      await wt.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("createWorktree keeps a CJK title legible in the branch name", async () => {
  const dir = await repo();
  try {
    /*
     * The branch IS the deliverable — see the note on `subtask.branch` in
     * schema.sql. It is what the user is left holding in their own repository, so
     * it has to say which piece of work it was.
     *
     * The previous sanitiser kept `[a-zA-Z0-9._-]` and replaced everything else,
     * which erased every CJK character: two different Chinese titles produced
     * branch names distinguishable only by their timestamp suffix. A real leftover
     * branch in the demo repo read `council/------------ms96bmug`. The old test
     * passed throughout, because "no spaces and a valid ref" is true of
     * `council/----------` too.
     */
    const a = await createWorktree(dir, "给首页加一个空状态");
    const b = await createWorktree(dir, "修复登录时的空指针");
    try {
      assert.ok(a.branch.includes("给首页加一个空状态"), `title lost: ${a.branch}`);
      assert.ok(b.branch.includes("修复登录时的空指针"), `title lost: ${b.branch}`);
      assert.ok(
        !/^council\/-+/.test(a.branch),
        `the name must not collapse to dashes: ${a.branch}`,
      );

      // git's own arbiter, not a guess about what it accepts.
      for (const wt of [a, b]) {
        const check = await git(["check-ref-format", "--branch", wt.branch], dir);
        assert.equal(check.code, 0, `git rejected ${wt.branch}`);
      }
    } finally {
      await a.dispose();
      await b.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("createWorktree gives two identical titles distinct branches", async () => {
  const dir = await repo();
  try {
    /*
     * A timestamp alone is not unique. `Date.now()` is evaluated before the
     * worktree lock is taken, so concurrent callers share a millisecond —
     * serialising the git command does not separate the names it was handed. With
     * two subtasks sharing a title the second add failed outright:
     *
     *   fatal: a branch named 'council/Add-tests-ms9cx928' already exists
     *
     * Reachable in practice: a plan is model-generated and nothing enforces
     * distinct titles, so a planner emitting "Add tests" twice would lose that
     * whole subtask before it started. Seen in a real parallel run where two of
     * three branches shared the suffix `ms9cwcnz` and only differing titles saved
     * them.
     */
    const results = await Promise.all(
      Array.from({ length: 4 }, () => createWorktree(dir, "Add tests")),
    );
    try {
      const names = new Set(results.map((w) => w.branch));
      assert.equal(names.size, results.length, `branch names collided: ${[...names].join(", ")}`);
      for (const wt of results) {
        const check = await git(["check-ref-format", "--branch", wt.branch], dir);
        assert.equal(check.code, 0, `git rejected ${wt.branch}`);
      }
    } finally {
      for (const wt of results) await wt.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("createWorktree survives titles that sanitize down to nothing", async () => {
  const dir = await repo();
  try {
    // An all-punctuation title would otherwise leave an empty ref component, and
    // a leading dash or a trailing dot is rejected outright by git.
    for (const title of ["...", "---", "@{", "..", "!!!"]) {
      const wt = await createWorktree(dir, title);
      try {
        const check = await git(["check-ref-format", "--branch", wt.branch], dir);
        assert.equal(check.code, 0, `git rejected ${wt.branch} (from ${title})`);
      } finally {
        await wt.dispose();
      }
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("createWorktree fails loudly on a bad base ref", async () => {
  const dir = await repo();
  try {
    // Silently falling back to HEAD would build on the wrong base.
    await assert.rejects(() => createWorktree(dir, "bad-base", "no-such-ref"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("commitAll returns null when the agent changed nothing", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "no-op");
    try {
      // A distinguishable no-op matters: an agent that edited nothing should not
      // look like one that produced a commit.
      assert.equal(await commitAll(wt.path, "nothing"), null);
    } finally {
      await wt.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("commitAll picks up new, modified, and deleted files", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "all-changes");
    try {
      await writeFile(join(wt.path, "added.txt"), "new\n", "utf8");
      await writeFile(join(wt.path, "a.txt"), "modified\n", "utf8");
      await rm(join(wt.path, "a.txt"));
      const sha = await commitAll(wt.path, "mixed");
      assert.ok(sha);
      const show = await git(["show", "--stat", "--oneline", sha], wt.path);
      assert.ok(show.stdout.includes("added.txt"));
      assert.ok(show.stdout.includes("a.txt"), "a deletion is a change too");
    } finally {
      await wt.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("diffAgainst reports committed work, and uncommitted as a fallback", async () => {
  const dir = await repo();
  try {
    const base = await currentHead(dir);
    assert.ok(base);

    const wt = await createWorktree(dir, "diffing", base);
    try {
      // Uncommitted: the reviewer still needs to see something.
      await writeFile(join(wt.path, "a.txt"), "changed\n", "utf8");
      const uncommitted = await diffAgainst(wt.path, base);
      assert.ok(uncommitted.includes("changed"), "uncommitted edits must be visible to a reviewer");

      await commitAll(wt.path, "committed");
      const committed = await diffAgainst(wt.path, base);
      assert.ok(committed.includes("changed"));
      assert.ok(committed.includes("a.txt"));
    } finally {
      await wt.dispose();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a branch survives disposal and can then be merged", async () => {
  const dir = await repo();
  try {
    const wt = await createWorktree(dir, "mergeable");
    await writeFile(join(wt.path, "feature.txt"), "feature\n", "utf8");
    await commitAll(wt.path, "feat");
    // Exactly the pipeline's ordering: dispose every worktree, then merge.
    await wt.dispose();

    const merge = await mergeBranch(dir, wt.branch);
    assert.equal(merge.code, 0, `merge failed: ${merge.stderr}`);
    const files = await git(["ls-files"], dir);
    assert.ok(files.stdout.includes("feature.txt"), "the work landed on the main branch");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a conflicting merge reports failure instead of silently resolving", async () => {
  const dir = await repo();
  try {
    const base = await currentHead(dir);
    assert.ok(base);
    const a = await createWorktree(dir, "conflict-a", base);
    const b = await createWorktree(dir, "conflict-b", base);
    await writeFile(join(a.path, "a.txt"), "version A\n", "utf8");
    await writeFile(join(b.path, "a.txt"), "version B\n", "utf8");
    await commitAll(a.path, "A");
    await commitAll(b.path, "B");
    await a.dispose();
    await b.dispose();

    assert.equal((await mergeBranch(dir, a.branch)).code, 0);
    const second = await mergeBranch(dir, b.branch);
    // A machine-picked resolution is precisely the silent damage this system is
    // built to avoid, so a conflict must surface rather than be papered over.
    assert.notEqual(second.code, 0, "a real conflict must be reported");
    await git(["merge", "--abort"], dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("git() never throws on a failed command", async () => {
  const dir = await repo();
  try {
    const res = await git(["no-such-subcommand"], dir);
    // Callers branch on `code`; a throw here would take down a whole run.
    assert.notEqual(res.code, 0);
    assert.ok(res.stderr.length > 0);
    const missing = await git(["status"], "/nonexistent/path/xyz");
    assert.notEqual(missing.code, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
