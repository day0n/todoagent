import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { AgentEvent, AgentResult, TokenUsage } from "./types.ts";
import { EMPTY_USAGE } from "./types.ts";
import { whichSync } from "../util/which.ts";

/** Default no-new-events window. A silent agent is usually a wedged agent. */
export const DEFAULT_IDLE_TIMEOUT_MS = 10 * 60 * 1000;

/**
 * A long build is not a hang, so an in-flight tool call gets its own, longer
 * budget than the generic idle window. Multica splits these the same way.
 */
export const TOOL_IDLE_TIMEOUT_MS = 20 * 60 * 1000;

export interface SpawnStreamOptions {
  execPath: string;
  args: string[];
  cwd: string;
  env?: Record<string, string>;
  idleTimeoutMs?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
  /**
   * Parses one stdout line into zero or more normalized events. Returning
   * `null` for a line means "not for me" (banner text, blank line, non-JSON) —
   * these CLIs interleave human-readable noise with their protocol.
   */
  onLine: (line: string, ctx: LineContext) => AgentEvent[] | null;
  /** Called after the process exits, to build the terminal result. */
  finalize: (ctx: LineContext, exitCode: number | null, stderrTail: string) => AgentResult;
}

/** Mutable state an adapter accumulates while parsing its stream. */
export interface LineContext {
  sessionId: string | null;
  /** Last text the adapter judged to be the final answer. */
  lastText: string;
  usage: TokenUsage;
  /** Adapter-declared failure, distinct from a nonzero exit. */
  failure: string | null;
  /** Set when the vendor signalled its turn finished cleanly. */
  turnCompleted: boolean;
  /** Non-fatal vendor warnings. Codex ships these as `item.type: "error"`. */
  warnings: string[];
  toolInFlight: number;
}

export function newLineContext(): LineContext {
  return {
    sessionId: null,
    lastText: "",
    usage: { ...EMPTY_USAGE },
    failure: null,
    turnCompleted: false,
    warnings: [],
    toolInFlight: 0,
  };
}

const STDERR_TAIL_LIMIT = 8000;

/**
 * Signals a child AND everything it spawned.
 *
 * Agent CLIs are process trees: they run builds, test suites, language servers.
 * `child.kill()` signals only the direct child, so a grandchild keeps the stdout
 * pipe open and the `close` event never fires — the watchdog fires, the process
 * survives, and the run hangs anyway. Because the child is spawned detached it
 * leads its own process group, so a negative pid reaches the whole group.
 */
function signalTree(child: { pid?: number | undefined; kill: (s: NodeJS.Signals) => boolean }, sig: NodeJS.Signals): void {
  const pid = child.pid;
  if (pid !== undefined) {
    try {
      process.kill(-pid, sig);
      return;
    } catch {
      // ESRCH (already gone) or EPERM: fall through to the direct kill.
    }
  }
  try {
    child.kill(sig);
  } catch {
    /* already reaped */
  }
}

/**
 * Spawns a CLI, streams normalized events, and resolves one terminal result.
 *
 * Shape mirrors Multica's `Backend.Execute` → `Session{Messages, Result}`: the
 * event channel closes before the result settles, so a consumer can drain the
 * stream and then read the outcome without racing.
 */
export function spawnStream(opts: SpawnStreamOptions): {
  events: AsyncIterable<AgentEvent>;
  result: Promise<AgentResult>;
  cancel: () => void;
} {
  const ctx = newLineContext();
  const startedAt = Date.now();
  const idleMs = opts.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;

  const queue: AgentEvent[] = [];
  let notify: (() => void) | null = null;
  let closed = false;

  const push = (ev: AgentEvent): void => {
    queue.push(ev);
    notify?.();
  };

  // Resolve to an absolute path rather than trusting spawn's PATH lookup.
  // `which` searches extra install directories (/opt/homebrew/bin, ~/.local/bin)
  // that Node's spawn does not, so a bare name could be DETECTED and then fail
  // with ENOENT — an engine started from a GUI app or launchd would list every
  // runtime as available and fail every run.
  const resolved = whichSync(opts.execPath) ?? opts.execPath;

  const child = spawn(resolved, opts.args, {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    // stdin must be closed, not inherited: codex blocks on "Reading additional
    // input from stdin..." when it stays open, and never reaches its turn.
    stdio: ["ignore", "pipe", "pipe"],
    // Own process group, so the watchdog can signal the whole TREE.
    //
    // Without this, killing the CLI leaves its children alive holding the stdout
    // pipe open — so `close` never fires and the watchdog fails to free the run.
    // Measured: a wedged process survived a 400ms idle timeout for the full 30s
    // its grandchild ran. Agent CLIs spawn build tools and test runners
    // constantly, so this is the common case, not an edge case.
    detached: true,
  });

  let stderrTail = "";
  child.stderr?.on("data", (chunk: Buffer) => {
    stderrTail = (stderrTail + chunk.toString()).slice(-STDERR_TAIL_LIMIT);
  });

  // ── Watchdogs ──────────────────────────────────────────────
  let killedBy: "idle" | "timeout" | "cancel" | null = null;
  let idleTimer: NodeJS.Timeout | null = null;

  const clearIdle = (): void => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = null;
  };

  const armIdle = (): void => {
    if (idleMs <= 0) return;
    clearIdle();
    const window = ctx.toolInFlight > 0 ? Math.max(idleMs, TOOL_IDLE_TIMEOUT_MS) : idleMs;
    idleTimer = setTimeout(() => {
      killedBy = "idle";
      kill();
    }, window);
  };

  const hardTimer =
    opts.timeoutMs && opts.timeoutMs > 0
      ? setTimeout(() => {
          killedBy = "timeout";
          kill();
        }, opts.timeoutMs)
      : null;

  function kill(): void {
    clearIdle();
    if (hardTimer) clearTimeout(hardTimer);
    if (child.exitCode !== null || child.signalCode !== null) return;
    // SIGTERM first so the CLI can flush its transcript, SIGKILL as backstop.
    signalTree(child, "SIGTERM");
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) signalTree(child, "SIGKILL");
    }, 3000).unref();
  }

  const onAbort = (): void => {
    killedBy = "cancel";
    kill();
  };
  // An already-aborted signal never fires its listener, so the state has to be
  // read up front. Without this, cancelling a run before the process spawned let
  // the agent run to completion — burning budget and possibly writing files
  // after the user had asked it to stop.
  if (opts.signal?.aborted === true) {
    killedBy = "cancel";
    // Deferred so `result` is already wired before it settles.
    setImmediate(() => kill());
  } else {
    opts.signal?.addEventListener("abort", onAbort, { once: true });
  }

  armIdle();

  // ── Line parsing ───────────────────────────────────────────
  if (child.stdout) {
    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
    rl.on("line", (line) => {
      let evs: AgentEvent[] | null = null;
      try {
        evs = opts.onLine(line, ctx);
      } catch (err) {
        // A parse bug must not take the run down; surface it and keep reading.
        push({ type: "error", message: `parse error: ${String(err)}` });
      }
      for (const ev of evs ?? []) {
        if (ev.type === "tool_use") ctx.toolInFlight++;
        if (ev.type === "tool_result") ctx.toolInFlight = Math.max(0, ctx.toolInFlight - 1);
        push(ev);
      }
      /*
       * Re-armed AFTER the line is processed, not before.
       *
       * The window length depends on ctx.toolInFlight, so arming first computed
       * it from the PREVIOUS state: the very line announcing a tool call still
       * got the short generic window, and an agent that then went quiet running a
       * build was killed by the watchdog the extended budget exists to prevent.
       */
      armIdle();
    });
  }

  const result = new Promise<AgentResult>((resolve) => {
    let settled = false;
    const settle = (exitCode: number | null): void => {
      if (settled) return;
      settled = true;
      clearIdle();
      if (hardTimer) clearTimeout(hardTimer);
      opts.signal?.removeEventListener("abort", onAbort);

      closed = true;
      notify?.();

      const base = opts.finalize(ctx, exitCode, stderrTail);
      const durationMs = Date.now() - startedAt;

      if (killedBy === "idle") {
        resolve({
          ...base,
          status: "timeout",
          error: `no output for ${Math.round(idleMs / 1000)}s (idle watchdog)`,
          durationMs,
        });
        return;
      }
      if (killedBy === "timeout") {
        resolve({ ...base, status: "timeout", error: "wall-clock timeout", durationMs });
        return;
      }
      if (killedBy === "cancel") {
        resolve({ ...base, status: "cancelled", error: "cancelled", durationMs });
        return;
      }
      resolve({ ...base, durationMs });
    };

    child.on("error", (err) => {
      ctx.failure = `spawn failed: ${err.message}`;
      settle(null);
    });
    child.on("close", (code) => settle(code));
  });

  const events: AsyncIterable<AgentEvent> = {
    async *[Symbol.asyncIterator]() {
      while (true) {
        while (queue.length > 0) {
          const ev = queue.shift();
          if (ev !== undefined) yield ev;
        }
        if (closed) return;
        await new Promise<void>((r) => {
          notify = () => {
            notify = null;
            r();
          };
        });
      }
    },
  };

  return { events, result, cancel: onAbort };
}

/** Parses a JSON line, returning null instead of throwing on non-JSON noise. */
export function parseJsonLine(line: string): Record<string, unknown> | null {
  const trimmed = line.trim();
  if (trimmed.length === 0 || (trimmed[0] !== "{" && trimmed[0] !== "[")) return null;
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function asString(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

export function asNumber(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

export function asRecord(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

/** Runs a CLI just to read a version string. */
export async function probeVersion(
  execPath: string,
  args: string[] = ["--version"],
): Promise<string | null> {
  return new Promise((resolve) => {
    const child = spawn(execPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    child.stdout?.on("data", (c: Buffer) => (out += c.toString()));
    child.stderr?.on("data", (c: Buffer) => (out += c.toString()));
    const timer = setTimeout(() => child.kill("SIGKILL"), 15000);
    child.on("error", () => {
      clearTimeout(timer);
      resolve(null);
    });
    child.on("close", () => {
      clearTimeout(timer);
      const line = out.split("\n").map((l) => l.trim()).find((l) => l.length > 0);
      resolve(line ?? null);
    });
  });
}
