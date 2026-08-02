import type { Store } from "../db/index.ts";
import type { Expert, Run } from "../types.ts";
import { captureWorkingDiff } from "../util/git.ts";
import { BudgetExceededError, recordEvent, runOneWithRetry } from "./runner.ts";

/**
 * Direct dispatch: one task, one agent, one turn.
 *
 * This is the todoagent default path. Deliberately NOT the pipeline: no
 * decomposition, no cross-review, no verification, no worktree/merge dance.
 * The agent works in the repository itself, exactly as if the user had opened
 * the CLI there and typed the task — because that is the product promise:
 * "派发任务、标状态", nothing in between.
 *
 * The run row is still created and events still flow through the same log/SSE
 * path, so transcripts, cost accounting and the board's status sync all work
 * unchanged.
 */
export interface DirectRunOptions {
  store: Store;
  runId: string;
  expert: Expert;
  signal?: AbortSignal;
}

export interface DirectRunResult {
  status: Run["status"];
  error: string | null;
}

export async function runDirect(opts: DirectRunOptions): Promise<DirectRunResult> {
  const { store, runId, expert, signal } = opts;

  const run = store.getRun(runId);
  if (!run) throw new Error(`run not found: ${runId}`);
  const project = store.getProject(run.projectId);
  if (!project) throw new Error(`project not found: ${run.projectId}`);

  // `draft` is the closest phase in the closed union: the maker producing work.
  store.updateRun(runId, { status: "running", phase: "draft" });
  recordEvent(store, runId, null, "run:started", { mode: "direct", expert: expert.name });

  /**
   * Settles the run, and for a completed one, snapshots the working tree.
   *
   * The snapshot is awaited INSIDE this function, so it is on disk before
   * `runDirect` resolves. That ordering is load-bearing: the engine calls
   * `syncTaskFromRun` in a `.finally()` after this promise settles, which is what
   * moves the task to 待确认 and announces it over SSE. Capturing afterwards would
   * let a client be told the work is ready, open the result, and find no diff — a
   * race that would reproduce only on a slow repository.
   */
  const finish = async (status: Run["status"], error: string | null): Promise<DirectRunResult> => {
    /*
     * The terminal status lands FIRST, before the snapshot.
     *
     * `captureWorkingDiff` spawns git, and git can block on another process's
     * index lock. Writing the status first means the worst case is a run recorded
     * as completed with no diff, rather than one left reading `running` — which
     * the UI shows as permanently in progress and only a restart resolves.
     */
    store.updateRun(runId, { status, error, endedAt: new Date().toISOString() });

    /*
     * Only a completed run is snapshotted, per the M3 spec.
     *
     * A failed or cancelled run leaves the tree in whatever half-finished state it
     * reached, which is rarely worth reading and never worth trusting. The
     * consequence is that `diff` stays NULL for those runs — distinct from the
     * empty string, which means "captured, and nothing had changed". The result
     * endpoint keeps that distinction so the UI can say "no snapshot was taken"
     * instead of asserting the agent changed no files, which would be a false
     * statement about a failed run that had in fact edited several.
     */
    if (status === "completed") {
      store.updateRun(runId, { diff: await captureWorkingDiff(project.repoPath) });
    }

    const eventType =
      status === "completed"
        ? "run:completed"
        : status === "cancelled"
          ? "run:cancelled"
          : status === "budget_exceeded"
            ? "run:budget_exceeded"
            : "run:failed";
    recordEvent(store, runId, null, eventType, error === null ? {} : { message: error });
    return { status, error };
  };

  try {
    const res = await runOneWithRetry({
      store,
      runId,
      expert,
      kind: "draft",
      subTaskId: null,
      prompt: run.goal,
      cwd: project.repoPath,
      signal,
    });
    if (res.ok) return finish("completed", null);
    if (res.status === "cancelled") return finish("cancelled", res.error);
    return finish("failed", res.error);
  } catch (err) {
    if (err instanceof BudgetExceededError) return finish("budget_exceeded", err.message);
    return finish("failed", err instanceof Error ? err.message : String(err));
  }
}
