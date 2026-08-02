import type { Store } from "../db/index.ts";
import type { Expert, Run } from "../types.ts";
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

  const finish = (status: Run["status"], error: string | null): DirectRunResult => {
    store.updateRun(runId, { status, error, endedAt: new Date().toISOString() });
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
