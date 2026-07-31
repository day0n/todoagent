// Consolidated: node:fs/promises was imported on two separate lines.
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { z } from "zod";
import { getAdapter } from "../adapters/index.ts";
import type { AgentEvent } from "../adapters/types.ts";
import type { Store } from "../db/index.ts";
import type { Attempt, Expert } from "../types.ts";
import type { Semaphore } from "../util/concurrency.ts";
import { bus } from "./bus.ts";
import { repairPrompt, tryParse } from "./structured.ts";

export class BudgetExceededError extends Error {
  readonly spent: number;
  readonly budget: number;

  // Fields are declared explicitly rather than as constructor parameter
  // properties: those are not erasable syntax, so Node's strip-only type
  // stripping rejects the file outright with ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX.
  constructor(spent: number, budget: number) {
    super(`token budget exhausted: ${spent} >= ${budget}`);
    this.name = "BudgetExceededError";
    this.spent = spent;
    this.budget = budget;
  }
}

export interface RunOneOptions {
  store: Store;
  runId: string;
  expert: Expert;
  kind: Attempt["kind"];
  subTaskId: string | null;
  prompt: string;
  cwd: string;
  /** Per-attempt wall clock. Zero leaves liveness to the idle watchdog. */
  timeoutMs?: number;
  idleTimeoutMs?: number;
  signal?: AbortSignal;
  /** Native structured output — codex only; others fall back to reparsing. */
  outputSchemaPath?: string | null;
  /**
   * Global cap on live agent processes for this run.
   *
   * Held here because this is the SINGLE point where a CLI is spawned. Capping at
   * the call sites was multiplicative instead: the stage loop bounded subtasks and
   * each subtask separately bounded its reviewers, so the true peak was the
   * product — six subtasks with two reviewers each is twelve full CLI processes,
   * every one holding hundreds of megabytes and spawning its own build tools.
   */
  slots?: Semaphore;
}

export interface RunOneResult {
  attemptId: string;
  ok: boolean;
  output: string;
  error: string | null;
  sessionId: string | null;
}

/**
 * Ceiling on any single string inside an event payload.
 *
 * Generous enough that ordinary agent chatter is never touched, small enough that
 * one pathological turn cannot produce a multi-megabyte row. Adapters already cap
 * tool OUTPUT at 20k, but text and thinking content were unbounded — an agent that
 * dumps a large file into its reply wrote the whole thing to the event log and then
 * pushed it down every open SSE connection as a single frame.
 */
export const MAX_EVENT_STRING = 24_000;

/**
 * Truncates long strings in an event payload, visibly.
 *
 * Truncation is marked rather than silent: a transcript that just stops looks like
 * the agent stopped, which is a materially different diagnosis. The full text is
 * still available in `attempt.output` via the transcript endpoint.
 */
export function boundPayload(payload: unknown): unknown {
  if (typeof payload === "string") {
    return payload.length > MAX_EVENT_STRING
      ? `${payload.slice(0, MAX_EVENT_STRING)}\n…[truncated ${payload.length - MAX_EVENT_STRING} chars in the event log; full text is in the attempt transcript]`
      : payload;
  }
  if (Array.isArray(payload)) return payload.map(boundPayload);
  if (payload !== null && typeof payload === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(payload)) out[k] = boundPayload(v);
    return out;
  }
  return payload;
}

/** Persists an event and broadcasts it. Order matters: durability, then fan-out. */
function record(
  store: Store,
  runId: string,
  attemptId: string | null,
  type: string,
  rawPayload: unknown,
): void {
  // Bounded once, here, because this is the single point where every event enters
  // both the database and the live stream.
  const payload = boundPayload(rawPayload);
  const id = store.appendEvent({ runId, attemptId, type, payload });
  bus.publish({
    id,
    runId,
    attemptId,
    seq: id,
    type,
    payload,
    createdAt: new Date().toISOString(),
  });
}

/**
 * Executes one agent turn end to end: streams its events into the log, records
 * usage against the run budget, and returns the final text.
 *
 * Budget is checked BEFORE spawning, not after. A ceiling that is only enforced
 * afterwards has already let the run overshoot by one full agent turn.
 */
export async function runOne(opts: RunOneOptions): Promise<RunOneResult> {
  const { store, runId, expert, prompt, cwd } = opts;

  const run = store.getRun(runId);
  if (!run) throw new Error(`run not found: ${runId}`);
  // Cheap pre-check, so an already-exhausted run does not even join the queue.
  if (run.budgetTokens > 0 && run.spentTokens >= run.budgetTokens) {
    throw new BudgetExceededError(run.spentTokens, run.budgetTokens);
  }

  /*
   * The slot is taken FIRST — before the attempt row and before any event.
   *
   * Ordering it after them was wrong in two ways, both of which produced confident
   * misinformation rather than an error:
   *
   *  - `attempt:started` reached the UI while the turn was still queued, so with a
   *    limit of 3 and six subtasks the user saw six cards claiming to be "thinking"
   *    when three processes existed. Exactly the "looks like it is working" class of
   *    bug this system is built to avoid.
   *  - `startedAt` was stamped at enqueue, so queue time counted as agent time. A
   *    turn that waited five minutes and ran for one reported six minutes of work,
   *    corrupting the very timing data meant to calibrate expert routing.
   *
   * Waiting happens before the slot is held and it is released as soon as the turn
   * ends, so nesting cannot deadlock: a subtask gives up its draft slot before its
   * reviewers ask for theirs.
   */
  await opts.slots?.acquire();
  try {
    /*
     * Re-checked after waiting, because the world moved while this turn queued.
     *
     * Siblings may have spent the remaining budget, or the user may have pressed
     * Stop. The pre-check above is no longer "immediately before the spawn" once a
     * semaphore sits between them, and a stale reading lets every queued turn
     * overshoot the ceiling by one full agent run.
     */
    const fresh = store.getRun(runId);
    if (!fresh) throw new Error(`run not found: ${runId}`);
    if (fresh.budgetTokens > 0 && fresh.spentTokens >= fresh.budgetTokens) {
      throw new BudgetExceededError(fresh.spentTokens, fresh.budgetTokens);
    }
    if (opts.signal?.aborted === true || fresh.status === "cancelled") {
      throw new Error("the run was cancelled while this turn was waiting for a slot");
    }

    const attempt = store.startAttempt({
      runId,
      subTaskId: opts.subTaskId,
      expertId: expert.id,
      runtimeKind: expert.runtimeKind,
      kind: opts.kind,
    });

    record(store, runId, attempt.id, "attempt:started", {
      expertId: expert.id,
      expertName: expert.name,
      runtimeKind: expert.runtimeKind,
      kind: opts.kind,
      subTaskId: opts.subTaskId,
    });

    const adapter = getAdapter(expert.runtimeKind);
    const execution = adapter.execute(prompt, {
      cwd,
      model: expert.model,
      systemPrompt: expert.systemPrompt,
      ...(opts.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
      ...(opts.idleTimeoutMs !== undefined ? { idleTimeoutMs: opts.idleTimeoutMs } : {}),
      ...(opts.signal ? { signal: opts.signal } : {}),
      ...(opts.outputSchemaPath ? { outputSchemaPath: opts.outputSchemaPath } : {}),
    });

    // Drain the stream concurrently with waiting on the result: the adapter closes
    // the event channel before settling, so consuming it cannot deadlock.
    const drain = (async () => {
      for await (const ev of execution.events as AsyncIterable<AgentEvent>) {
        record(store, runId, attempt.id, `agent:${ev.type}`, ev);
      }
    })();

    const result = await execution.result;
    await drain;

    /*
     * Bookkeeping stays inside the slot.
     *
     * These are microsecond-scale SQLite writes, so holding the slot through them
     * costs nothing — and it is more honest: the turn is not finished until its
     * spend is recorded. Recording after the release would let a queued sibling
     * start against a budget that does not yet include this turn.
     */
    const spentThisTurn = result.usage.inputTokens + result.usage.outputTokens;
    store.finishAttempt(attempt.id, {
      status: result.status,
      output: result.output,
      error: result.error,
      sessionId: result.sessionId,
      inputTokens: result.usage.inputTokens,
      outputTokens: result.usage.outputTokens,
      costUsd: result.usage.costUsd,
    });
    const spend = store.addSpend(runId, spentThisTurn);

    record(store, runId, attempt.id, "attempt:finished", {
      status: result.status,
      error: result.error,
      durationMs: result.durationMs,
      tokens: spentThisTurn,
      costUsd: result.usage.costUsd,
      spentTotal: spend.spent,
    });

    return {
      attemptId: attempt.id,
      ok: result.status === "completed",
      output: result.output,
      error: result.error,
      sessionId: result.sessionId,
    };
  } finally {
    // Released even on a throw, or one failed turn would shrink the pool for the
    // rest of the run.
    opts.slots?.release();
  }
}

/**
 * Runs an agent and insists on a schema-conforming object.
 *
 * Retries are part of the contract, not an error path: these are text-first CLIs
 * and a first-shot parse failure is routine. Each retry feeds back the exact
 * validation error, which converges far faster than repeating the ask.
 */
export async function runStructured<T>(
  opts: RunOneOptions & {
    // Input pinned to `unknown` so T binds to zod's output type — see tryParse.
    schema: z.ZodType<T, z.ZodTypeDef, unknown>;
    maxAttempts?: number;
    schemaJson?: unknown;
  },
): Promise<{ value: T | null; attemptIds: string[]; error: string | null }> {
  const maxAttempts = opts.maxAttempts ?? 3;
  const attemptIds: string[] = [];
  let prompt = opts.prompt;
  let lastError: string | null = null;

  // Codex can enforce a schema natively; writing it to disk lets the CLI do the
  // work instead of us reparsing prose.
  let schemaDir: string | null = null;
  let schemaPath: string | null = null;
  if (opts.schemaJson !== undefined && opts.expert.runtimeKind === "codex") {
    schemaDir = await mkdtemp(join(tmpdir(), "council-schema-"));
    schemaPath = join(schemaDir, "schema.json");
    await writeFile(schemaPath, JSON.stringify(opts.schemaJson), "utf8");
  }

  try {
    for (let i = 0; i < maxAttempts; i++) {
      const res = await runOne({
        ...opts,
        prompt,
        ...(schemaPath ? { outputSchemaPath: schemaPath } : {}),
      });
      attemptIds.push(res.attemptId);

      if (!res.ok) {
        lastError = res.error ?? "agent failed";
        // A failed run is not a parse problem — retrying the same prompt against a
        // broken runtime just burns budget.
        break;
      }

      const parsed = tryParse(opts.schema, res.output);
      if (parsed.ok && parsed.value !== null) {
        return { value: parsed.value, attemptIds, error: null };
      }

      lastError = parsed.error;
      record(opts.store, opts.runId, res.attemptId, "structured:reparse", {
        error: parsed.error,
        attempt: i + 1,
        of: maxAttempts,
      });
      prompt = repairPrompt(opts.prompt, parsed.error ?? "unknown", res.output);
    }

    return { value: null, attemptIds, error: lastError };
  } finally {
    /*
     * Remove the schema directory on EVERY exit path.
     *
     * It was never removed at all: measured 418 abandoned `council-schema-*`
     * directories in this machine's temp space, one per structured codex turn. The
     * function has several returns and can throw (budget, cancellation), so a
     * `finally` is the only placement that covers them.
     *
     * Safe here because `runOne` awaits the process before returning, so nothing is
     * still reading the file. Failure to clean up must not mask the real result, so
     * the error is swallowed — a leaked temp directory is not worth losing a
     * completed plan over.
     */
    if (schemaDir !== null) {
      await rm(schemaDir, { recursive: true, force: true }).catch(() => undefined);
    }
  }
}

export { record as recordEvent };
