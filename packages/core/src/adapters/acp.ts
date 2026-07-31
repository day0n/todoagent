import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { asNumber, asRecord, asString, DEFAULT_IDLE_TIMEOUT_MS, TOOL_IDLE_TIMEOUT_MS, newLineContext, parseJsonLine } from "./process.ts";
import { whichSync } from "../util/which.ts";
import type { AgentEvent, AgentResult, ExecOptions } from "./types.ts";

/**
 * Agent Client Protocol transport: JSON-RPC 2.0 over line-delimited stdio.
 *
 * Unlike the stream-json adapters this is bidirectional — the agent asks us
 * things mid-turn — so it cannot reuse `spawnStream`, which closes stdin.
 *
 * Verified against Kiro CLI Agent 2.12.2. Handshake:
 *   → initialize {protocolVersion, clientCapabilities}
 *   ← {protocolVersion, agentCapabilities, agentInfo}
 *   → session/new {cwd, mcpServers}          ← {sessionId, modes}
 *   → session/prompt {sessionId, prompt[]}   ← {stopReason}
 * with session/update notifications streaming in between.
 */

const PROTOCOL_VERSION = 1;

/** Text arrives one character at a time, so chunks are coalesced to this size. */
const TEXT_FLUSH_CHARS = 120;
const TEXT_FLUSH_MS = 400;

/**
 * Scale of the provider-reported cost unit. xAI states spend in whole ticks of
 * 1e-10 USD, which keeps sub-cent turn costs exact in integers rather than
 * drifting through floating point.
 */
const COST_USD_TICKS_PER_USD = 10_000_000_000;

export interface AcpOptions extends ExecOptions {
  execPath: string;
  /** e.g. ["acp", "-a"] — `-a` trusts all tools, required for headless runs. */
  args: string[];
  /** Handshake budget. A wedged startup should fail fast, not hang for 10m. */
  handshakeTimeoutMs?: number;
}

interface Pending {
  resolve: (v: Record<string, unknown>) => void;
  reject: (e: Error) => void;
}

export function runAcp(prompt: string, opts: AcpOptions): {
  events: AsyncIterable<AgentEvent>;
  result: Promise<AgentResult>;
  cancel: () => void;
} {
  const ctx = newLineContext();
  const startedAt = Date.now();
  const idleMs = opts.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;
  const handshakeMs = opts.handshakeTimeoutMs ?? 90_000;

  const queue: AgentEvent[] = [];
  let notify: (() => void) | null = null;
  let closed = false;
  const push = (ev: AgentEvent): void => {
    queue.push(ev);
    notify?.();
  };

  // ── Text coalescing ────────────────────────────────────────
  let textBuf = "";
  let thoughtBuf = "";
  let flushTimer: NodeJS.Timeout | null = null;

  const flushText = (): void => {
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
    if (thoughtBuf.length > 0) {
      push({ type: "thinking", content: thoughtBuf });
      thoughtBuf = "";
    }
    if (textBuf.length > 0) {
      push({ type: "text", content: textBuf });
      textBuf = "";
    }
  };

  const scheduleFlush = (): void => {
    if (flushTimer) return;
    flushTimer = setTimeout(flushText, TEXT_FLUSH_MS);
  };

  // Absolute path for the same reason as the stream-json transport: `which`
  // searches install directories that spawn's PATH lookup does not, so a bare
  // name could be detected and then fail with ENOENT.
  const resolved = whichSync(opts.execPath) ?? opts.execPath;

  const child = spawn(resolved, opts.args, {
    cwd: opts.cwd,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let stderrTail = "";
  child.stderr?.on("data", (c: Buffer) => {
    stderrTail = (stderrTail + c.toString()).slice(-8000);
  });

  let nextId = 0;
  const pending = new Map<number, Pending>();

  const write = (msg: Record<string, unknown>): void => {
    if (child.stdin?.writable !== true) return;
    child.stdin.write(`${JSON.stringify(msg)}\n`);
  };

  const request = (method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> => {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      write({ jsonrpc: "2.0", id, method, params });
    });
  };

  // ── Watchdogs ──────────────────────────────────────────────
  let killedBy: "idle" | "timeout" | "cancel" | "handshake" | null = null;
  let idleTimer: NodeJS.Timeout | null = null;

  const armIdle = (): void => {
    if (idleMs <= 0) return;
    if (idleTimer) clearTimeout(idleTimer);
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
    if (idleTimer) clearTimeout(idleTimer);
    if (hardTimer) clearTimeout(hardTimer);
    if (child.exitCode !== null || child.signalCode !== null) return;
    child.kill("SIGTERM");
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 5000).unref();
  }

  const onAbort = (): void => {
    killedBy = "cancel";
    kill();
  };
  opts.signal?.addEventListener("abort", onAbort, { once: true });
  armIdle();

  // ── session/update dispatch ────────────────────────────────
  function handleUpdate(params: Record<string, unknown>): void {
    const update = asRecord(params["update"]);
    if (!update) return;
    const kind = asString(update["sessionUpdate"]);

    switch (kind) {
      case "agent_message_chunk": {
        const text = asString(asRecord(update["content"])?.["text"]) ?? "";
        if (text.length === 0) return;
        textBuf += text;
        ctx.lastText += text;
        if (textBuf.length >= TEXT_FLUSH_CHARS) flushText();
        else scheduleFlush();
        return;
      }
      case "agent_thought_chunk": {
        const text = asString(asRecord(update["content"])?.["text"]) ?? "";
        if (text.length === 0) return;
        thoughtBuf += text;
        if (thoughtBuf.length >= TEXT_FLUSH_CHARS) flushText();
        else scheduleFlush();
        return;
      }
      case "tool_call": {
        flushText();
        ctx.toolInFlight++;
        push({
          type: "tool_use",
          tool: asString(update["title"]) ?? asString(update["kind"]) ?? "tool",
          callId: asString(update["toolCallId"]) ?? "",
          input: update["rawInput"] ?? null,
        });
        return;
      }
      case "tool_call_update": {
        const status = asString(update["status"]);
        // Only a settled status closes the call; "in_progress" updates would
        // otherwise decrement the in-flight count early and shrink the watchdog.
        if (status !== "completed" && status !== "failed") return;
        ctx.toolInFlight = Math.max(0, ctx.toolInFlight - 1);
        const content = update["content"];
        let out = "";
        if (Array.isArray(content)) {
          out = content
            .map((c) => {
              const rec = asRecord(c);
              return asString(asRecord(rec?.["content"])?.["text"]) ?? asString(rec?.["text"]) ?? "";
            })
            .filter((s) => s.length > 0)
            .join("\n");
        }
        push({
          type: "tool_result",
          tool: asString(update["title"]) ?? "",
          callId: asString(update["toolCallId"]) ?? "",
          output: (out || status).slice(0, 20000),
        });
        return;
      }
      default:
        return;
    }
  }

  /** Kiro reports spend in credits, not tokens — recorded as cost, not usage. */
  function handleKiroMetadata(params: Record<string, unknown>): void {
    const metering = params["meteringUsage"];
    if (!Array.isArray(metering)) return;
    for (const raw of metering) {
      const rec = asRecord(raw);
      if (!rec) continue;
      if (asString(rec["unit"]) === "credit") ctx.usage.costUsd += asNumber(rec["value"]);
    }
  }

  /**
   * Reads an ACP `_meta.usage` block, which some agents attach to results.
   *
   * Grok is the only runtime that states its own price
   * (`_meta.usage.costUsdTicks`, in ticks of 1e-10 USD). That figure is better
   * than any local estimate: xAI bills a request at 2x once its prompt reaches
   * 200K tokens, and aggregated token counts cannot say which requests crossed
   * that line. When present, the provider's number wins over arithmetic.
   */
  function applyMetaUsage(container: Record<string, unknown> | null): void {
    const usage = asRecord(asRecord(container?.["_meta"])?.["usage"]);
    if (!usage) return;
    ctx.usage.inputTokens += asNumber(usage["inputTokens"] ?? usage["input_tokens"]);
    ctx.usage.outputTokens += asNumber(usage["outputTokens"] ?? usage["output_tokens"]);
    ctx.usage.cacheReadTokens += asNumber(usage["cacheReadTokens"] ?? usage["cachedInputTokens"]);
    ctx.usage.cacheWriteTokens += asNumber(usage["cacheWriteTokens"]);
    const ticks = asNumber(usage["costUsdTicks"]);
    if (ticks !== 0) ctx.usage.costUsd += ticks / COST_USD_TICKS_PER_USD;
  }

  if (child.stdout) {
    createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => {
      armIdle();
      const msg = parseJsonLine(line);
      if (!msg) return;

      const id = msg["id"];
      const method = asString(msg["method"]);

      // Response to one of our requests.
      if (typeof id === "number" && method === null) {
        const p = pending.get(id);
        if (!p) return;
        pending.delete(id);
        const err = asRecord(msg["error"]);
        if (err) {
          p.reject(new Error(asString(err["message"]) ?? "acp error"));
          return;
        }
        p.resolve(asRecord(msg["result"]) ?? {});
        return;
      }

      if (method === null) return;

      // Agent-initiated request: must be answered or the turn stalls forever.
      if (typeof id === "number") {
        if (method === "session/request_permission") {
          const params = asRecord(msg["params"]) ?? {};
          const options = params["options"];
          let optionId = "allow";
          if (Array.isArray(options)) {
            // Prefer an allow-ish option; fall back to the first offered.
            const preferred = options
              .map((o) => asRecord(o))
              .find((o) => {
                const k = asString(o?.["kind"]) ?? asString(o?.["optionId"]) ?? "";
                return /allow/i.test(k);
              });
            optionId =
              asString(preferred?.["optionId"]) ??
              asString(asRecord(options[0])?.["optionId"]) ??
              "allow";
          }
          write({ jsonrpc: "2.0", id, result: { outcome: { outcome: "selected", optionId } } });
          return;
        }
        // Unknown request: reply with an error so the agent stops waiting.
        write({ jsonrpc: "2.0", id, error: { code: -32601, message: `unsupported: ${method}` } });
        return;
      }

      // Notifications.
      if (method === "session/update") {
        handleUpdate(asRecord(msg["params"]) ?? {});
        return;
      }
      if (method === "_kiro.dev/metadata") {
        handleKiroMetadata(asRecord(msg["params"]) ?? {});
        return;
      }
    });
  }

  // ── Drive the conversation ─────────────────────────────────
  const withTimeout = async <T>(p: Promise<T>, ms: number, what: string): Promise<T> => {
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        p,
        new Promise<never>((_, rej) => {
          timer = setTimeout(() => {
            killedBy = "handshake";
            rej(new Error(`${what} timed out after ${Math.round(ms / 1000)}s`));
          }, ms);
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  };

  const drive = async (): Promise<void> => {
    await withTimeout(
      request("initialize", {
        protocolVersion: PROTOCOL_VERSION,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      }),
      handshakeMs,
      "acp initialize",
    );

    const session = await withTimeout(
      request("session/new", { cwd: opts.cwd, mcpServers: [] }),
      handshakeMs,
      "acp session/new",
    );
    const sessionId = asString(session["sessionId"]);
    if (sessionId === null) throw new Error("acp session/new returned no sessionId");
    ctx.sessionId = sessionId;
    push({ type: "status", status: "init", sessionId });

    // The system prompt has no dedicated ACP field, so it rides the first turn.
    const text = opts.systemPrompt ? `${opts.systemPrompt}\n\n---\n\n${prompt}` : prompt;
    const res = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text }],
    });
    ctx.turnCompleted = true;
    // Grok attaches its self-reported spend to the prompt result.
    applyMetaUsage(res);
    const stop = asString(res["stopReason"]) ?? "end_turn";
    // refusal / max_tokens are real failures; end_turn and a client-side cancel
    // are not.
    if (stop !== "end_turn" && stop !== "cancelled") {
      ctx.failure = `acp stopReason: ${stop}`;
    }
  };

  const result = new Promise<AgentResult>((resolve) => {
    let settled = false;
    const settle = (exitCode: number | null): void => {
      if (settled) return;
      settled = true;
      flushText();
      if (idleTimer) clearTimeout(idleTimer);
      if (hardTimer) clearTimeout(hardTimer);
      opts.signal?.removeEventListener("abort", onAbort);
      closed = true;
      notify?.();

      const durationMs = Date.now() - startedAt;
      const base = {
        output: ctx.lastText,
        sessionId: ctx.sessionId,
        usage: ctx.usage,
        durationMs,
      };

      if (killedBy === "idle") {
        resolve({ ...base, status: "timeout", error: `no output for ${Math.round(idleMs / 1000)}s (idle watchdog)` });
        return;
      }
      if (killedBy === "timeout" || killedBy === "handshake") {
        resolve({ ...base, status: "timeout", error: ctx.failure ?? "acp timeout" });
        return;
      }
      if (killedBy === "cancel") {
        resolve({ ...base, status: "cancelled", error: "cancelled" });
        return;
      }

      const ok = ctx.failure === null && ctx.turnCompleted;
      resolve({
        ...base,
        status: ok ? "completed" : "failed",
        error: ok
          ? null
          : (ctx.failure ??
            `acp ended without a completed turn (exit ${exitCode})${stderrTail ? `\nstderr tail: ${stderrTail.slice(-600)}` : ""}`),
      });
    };

    child.on("error", (err) => {
      ctx.failure = `spawn failed: ${err.message}`;
      settle(null);
    });
    child.on("close", (code) => settle(code));

    drive().then(
      () => {
        // Turn finished cleanly — close stdin so the agent exits on its own.
        child.stdin?.end();
        // Backstop in case it lingers after its turn.
        setTimeout(() => kill(), 3000).unref();
      },
      (err: unknown) => {
        ctx.failure = ctx.failure ?? String(err instanceof Error ? err.message : err);
        push({ type: "error", message: ctx.failure });
        kill();
      },
    );
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
