import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface GitResult {
  code: number;
  stdout: string;
  stderr: string;
}

/**
 * Serialises worktree metadata changes, per repository.
 *
 * `git worktree add` scans `.git/worktrees/*` while registering the new entry, so
 * two concurrent adds can have one reading a registration the other has created
 * but not finished writing. Git reports that as a fatal error and the whole add
 * fails:
 *
 *   fatal: could not read .git/worktrees/agent-8/commondir: Undefined error: 0
 *
 * Measured on this machine: 16 concurrent adds over 12 rounds produced 1 failure
 * in 192 (0.5%), while 2 concurrent over 60 rounds produced none — so it needs
 * real concurrency to show up, which is exactly what this system does. The
 * pipeline runs subtasks through `mapLimit(subtasks, maxConcurrent, …)` and every
 * one of them creates a worktree, with a default concurrency of 6.
 *
 * It first appeared as a flaky test, and treating it as one would have been the
 * wrong call: the same race makes a parallel subtask fail to START in production,
 * randomly, in the feature this product is built around.
 *
 * Per repository rather than global, since separate repos have independent
 * `.git/worktrees` directories and serialising across them would be pure loss.
 * `remove` and `prune` mutate the same directory, so they take the lock too.
 *
 * The cost is small and bounded: an add takes tens of milliseconds, so six of
 * them serialise in well under a second, once, at the start of a stage. The AGENTS
 * still run fully in parallel — that is the parallelism that matters.
 */
const worktreeLocks = new Map<string, Promise<void>>();

function withWorktreeLock<T>(repoPath: string, fn: () => Promise<T>): Promise<T> {
  const previous = worktreeLocks.get(repoPath) ?? Promise.resolve();
  // Chained onto both outcomes: one failed operation must not wedge the queue
  // behind it, which would be a worse bug than the race being fixed.
  const run = previous.then(fn, fn);

  const tail: Promise<void> = run.then(
    () => {
      if (worktreeLocks.get(repoPath) === tail) worktreeLocks.delete(repoPath);
    },
    () => {
      if (worktreeLocks.get(repoPath) === tail) worktreeLocks.delete(repoPath);
    },
  );
  worktreeLocks.set(repoPath, tail);
  return run;
}

/** Runs a git command. Never throws on a nonzero exit — callers inspect `code`. */
export function git(args: string[], cwd: string): Promise<GitResult> {
  return new Promise((resolve) => {
    const child = spawn("git", args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (c: Buffer) => (stdout += c.toString()));
    child.stderr?.on("data", (c: Buffer) => (stderr += c.toString()));
    child.on("error", (e) => resolve({ code: -1, stdout, stderr: `${stderr}${e.message}` }));
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

export async function isGitRepo(path: string): Promise<boolean> {
  const r = await git(["rev-parse", "--is-inside-work-tree"], path);
  return r.code === 0 && r.stdout.trim() === "true";
}

/**
 * Tracked files with uncommitted modifications.
 *
 * These are the ones that matter before a run starts. A worktree branches from
 * HEAD, so the agent cannot see work that is only in the working tree — it
 * silently reasons about a stale snapshot. Worse, git then refuses the merge at
 * the very end ("your local changes would be overwritten"), so the whole run is
 * spent before the problem appears.
 *
 * UNTRACKED files are excluded on purpose: scratch notes and build output are
 * everywhere, they are invisible to a worktree anyway, and they only collide if
 * the agent happens to create the same path. Refusing to run because of them
 * would be obstruction, not protection.
 */
export async function dirtyTrackedFiles(repoPath: string): Promise<string[]> {
  // -uno: report modifications to tracked files, ignore untracked ones.
  const res = await git(["status", "--porcelain", "-uno"], repoPath);
  if (res.code !== 0) return [];
  return res.stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
    // "XY path" — keep the path, drop the status letters.
    .map((l) => l.replace(/^\S+\s+/, ""));
}

export async function currentHead(repoPath: string): Promise<string | null> {
  const r = await git(["rev-parse", "HEAD"], repoPath);
  return r.code === 0 ? r.stdout.trim() : null;
}

export interface Worktree {
  path: string;
  branch: string;
  /**
   * Removes the worktree directory. Safe to call twice.
   *
   * The BRANCH is deliberately kept: it is the deliverable, and the merge phase
   * runs after every subtask has been disposed. Deleting it here would throw
   * away all the agent's work and leave the merge with nothing to reference.
   * Use `deleteBranch` for the branch, once its contents are merged or rejected.
   */
  dispose(): Promise<void>;
  /**
   * Drops the branch, but ONLY if its commits are reachable elsewhere.
   *
   * Returns false — leaving the branch intact — when deleting would lose work.
   * A `council/*` branch is often the only copy of an agent's output (a subtask
   * that failed review, or one whose run crashed), so git's own merged-check is
   * the arbiter rather than a force delete.
   */
  deleteBranch(): Promise<boolean>;
}

/**
 * Creates an isolated git worktree for one subtask.
 *
 * This is not an optimization — it is the precondition for running several
 * agents at once. Parallel agents editing one working tree will always collide,
 * and a collision mid-edit produces a file that neither agent intended.
 *
 * Each worktree gets its own branch off `baseRef`, so the orchestrator can diff
 * and merge each contribution independently.
 */
export async function createWorktree(
  repoPath: string,
  name: string,
  baseRef = "HEAD",
): Promise<Worktree> {
  const safe = name.replace(/[^a-zA-Z0-9._-]/g, "-").slice(0, 60);
  const branch = `council/${safe}-${Date.now().toString(36)}`;
  const root = await mkdtemp(join(tmpdir(), "council-wt-"));
  const path = join(root, safe || "work");

  // Only the git call is serialised; mkdtemp above is per-caller and safe.
  const add = await withWorktreeLock(repoPath, () =>
    git(["worktree", "add", "-b", branch, path, baseRef], repoPath),
  );
  if (add.code !== 0) {
    await rm(root, { recursive: true, force: true });
    throw new Error(`git worktree add failed: ${add.stderr.trim() || add.stdout.trim()}`);
  }

  let disposed = false;
  return {
    path,
    branch,
    async dispose() {
      if (disposed) return;
      disposed = true;
      // --force because the agent will have left uncommitted edits behind.
      // Locked as well: removal rewrites the same .git/worktrees directory that a
      // concurrent add is scanning, so it can break that add just as easily.
      await withWorktreeLock(repoPath, () =>
        git(["worktree", "remove", "--force", path], repoPath),
      );
      await rm(root, { recursive: true, force: true });
    },
    async deleteBranch() {
      return deleteBranchIfMerged(repoPath, branch);
    },
  };
}

/**
 * Removes registrations for worktrees whose directories are gone.
 *
 * Necessary because a crash skips `dispose()`, and git keeps the registration
 * forever — marked `prunable`, but nothing prunes it. Measured: three killed
 * subtasks left three permanent stale entries, and creating new worktrees did not
 * clear them. That litter accumulates in the USER'S repository, run after run.
 *
 * Safe by construction: git only prunes entries whose working directory no longer
 * exists, so a live worktree cannot be affected.
 */
export async function pruneWorktrees(repoPath: string): Promise<void> {
  // The third mutator of .git/worktrees, so it takes the same lock. Pruning while
  // an add is registering is the same race read from the other side.
  await withWorktreeLock(repoPath, () => git(["worktree", "prune"], repoPath));
}

/**
 * Deletes a branch only if its commits are already reachable elsewhere.
 *
 * Uses `-d`, never `-D`. A `council/*` branch may hold the ONLY copy of an
 * agent's work — a subtask that failed review, or one whose run crashed — and
 * force-deleting it would destroy that silently. git's own merged-check is the
 * right arbiter, so this is a no-op precisely when the work would be lost.
 */
export async function deleteBranchIfMerged(repoPath: string, branch: string): Promise<boolean> {
  const res = await git(["branch", "-d", branch], repoPath);
  return res.code === 0;
}

/** Lists leftover `council/*` branches, so unmerged work can be reported. */
export async function listCouncilBranches(repoPath: string): Promise<string[]> {
  const res = await git(["branch", "--list", "council/*", "--format=%(refname:short)"], repoPath);
  if (res.code !== 0) return [];
  return res.stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}

/**
 * Commits everything in a worktree, so the contribution survives disposal.
 * Returns the commit sha, or null when there was nothing to commit.
 */
export async function commitAll(worktreePath: string, message: string): Promise<string | null> {
  await git(["add", "-A"], worktreePath);
  const status = await git(["status", "--porcelain"], worktreePath);
  if (status.stdout.trim().length === 0) return null;
  const commit = await git(
    ["-c", "user.name=Council", "-c", "user.email=council@localhost", "commit", "-m", message],
    worktreePath,
  );
  if (commit.code !== 0) return null;
  const head = await git(["rev-parse", "HEAD"], worktreePath);
  return head.code === 0 ? head.stdout.trim() : null;
}

/** Diff of a worktree against its base, for review prompts and the UI. */
export async function diffAgainst(worktreePath: string, baseRef: string): Promise<string> {
  const r = await git(["diff", `${baseRef}...HEAD`], worktreePath);
  if (r.code === 0 && r.stdout.trim().length > 0) return r.stdout;
  // Fall back to uncommitted changes when the agent never committed.
  const un = await git(["diff", "HEAD"], worktreePath);
  return un.code === 0 ? un.stdout : "";
}

export async function mergeBranch(repoPath: string, branch: string): Promise<GitResult> {
  return git(
    [
      "-c",
      "user.name=Council",
      "-c",
      "user.email=council@localhost",
      "merge",
      "--no-ff",
      "-m",
      `council: merge ${branch}`,
      branch,
    ],
    repoPath,
  );
}
