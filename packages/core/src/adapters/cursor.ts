import { which } from "../util/which.ts";
import {
  asNumber,
  asRecord,
  asString,
  parseJsonLine,
  probeVersion,
  spawnStream,
  type LineContext,
} from "./process.ts";
import {
  filterBlockedArgs,
  type AgentAdapter,
  type AgentEvent,
  type AgentResult,
  type BlockedArgMode,
  type ExecOptions,
} from "./types.ts";
import type { DetectedRuntime } from "../types.ts";

const BLOCKED: Readonly<Record<string, BlockedArgMode>> = {
  "-p": "standalone",
  "--print": "standalone",
  "--output-format": "withValue",
  "--force": "standalone",
  "--yolo": "standalone",
  "--trust": "standalone",
  "--workspace": "withValue",
  "--model": "withValue",
  "--resume": "withValue",
  "--continue": "standalone",
  "--mode": "withValue",
  "--plan": "standalone",
  // Worktree isolation is the orchestrator's job — it must own the path so it
  // can diff and merge the result. Letting cursor pick its own hides the tree.
  "-w": "withValue",
  "--worktree": "withValue",
};

function buildArgs(prompt: string, opts: ExecOptions): string[] {
  const args = [
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    // Headless runs cannot answer prompts: --force auto-approves tools and
    // --trust skips the workspace-trust question.
    "--force",
    "--trust",
    "--workspace",
    opts.cwd,
  ];
  if (opts.model) args.push("--model", opts.model);
  if (opts.resumeSessionId) args.push("--resume", opts.resumeSessionId);
  const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
  args.push(...kept);
  return args;
}

/**
 * Reads a usage number that may arrive in either casing.
 *
 * Cursor is inconsistent across versions — Multica's cursor.go carries a struct
 * accepting both `input_tokens` and `inputTokens` for every field. Rather than
 * pick one and silently record zeros, accept both.
 */
function usageNum(rec: Record<string, unknown>, ...keys: string[]): number {
  for (const k of keys) {
    const n = asNumber(rec[k]);
    if (n !== 0) return n;
  }
  return 0;
}

function applyCursorUsage(ctx: LineContext, rec: Record<string, unknown>): void {
  const nested = asRecord(rec["usage"]);
  const src = nested ?? rec;
  ctx.usage.inputTokens += usageNum(src, "input_tokens", "inputTokens");
  ctx.usage.outputTokens += usageNum(src, "output_tokens", "outputTokens");
  ctx.usage.cacheReadTokens += usageNum(
    src,
    "cached_input_tokens",
    "cachedInputTokens",
    "cacheReadTokens",
    "cache_read_input_tokens",
    "cacheReadInputTokens",
  );
  ctx.usage.cacheWriteTokens += usageNum(
    src,
    "cacheWriteTokens",
    "cache_creation_input_tokens",
    "cacheCreationInputTokens",
  );
}

/**
 * Renders a cursor tool result as text.
 *
 * Every tool has its own result shape, all nested under `result.success`. These are
 * the shapes actually captured from cursor-agent 2026.07.23:
 *
 *   readToolCall  → { content, totalLines, fileSize, ... }
 *   editToolCall  → { message, diffString, linesAdded, ... }
 *   globToolCall  → { files: [...], totalFiles, ... }
 *
 * There is no common `output` field, so the useful line has to be picked per shape.
 * Falling back to JSON keeps an unknown tool legible instead of blank — the point of
 * the timeline is to show what the agent did.
 */
function cursorToolOutput(detail: Record<string, unknown> | null): string {
  const result = asRecord(detail?.["result"]);
  if (!result) return "";

  // Failures are surfaced verbatim: a tool that errored is exactly what a reviewer
  // needs to see.
  const failure = asRecord(result["error"]) ?? asRecord(result["failure"]);
  if (failure) return JSON.stringify(failure);

  const success = asRecord(result["success"]);
  if (!success) return JSON.stringify(result);

  // Human-meaningful fields first, in the order a reader would want them.
  for (const key of ["message", "content", "diffString"]) {
    const value = asString(success[key]);
    if (value !== null && value.length > 0) return value;
  }
  const files = success["files"];
  if (Array.isArray(files)) return files.map((f) => String(f)).join("\n");

  return JSON.stringify(success);
}

/** Extracts text from a content-block array (assistant message payloads). */
function blocksToEvents(content: unknown, ctx: LineContext): AgentEvent[] {
  if (!Array.isArray(content)) return [];
  const out: AgentEvent[] = [];
  for (const raw of content) {
    const block = asRecord(raw);
    if (!block) continue;
    const bt = asString(block["type"]);
    if (bt === "text" || bt === "output_text") {
      const text = asString(block["text"]) ?? "";
      if (text.length > 0) {
        ctx.lastText = text;
        out.push({ type: "text", content: text });
      }
    } else if (bt === "thinking") {
      const text = asString(block["text"]) ?? "";
      if (text.length > 0) out.push({ type: "thinking", content: text });
    } else if (bt === "tool_use") {
      out.push({
        type: "tool_use",
        tool: asString(block["name"]) ?? "unknown",
        callId: asString(block["id"]) ?? "",
        input: block["input"] ?? null,
      });
    }
  }
  return out;
}

/**
 * Parses one line of `cursor-agent -p --output-format stream-json`.
 *
 * Event vocabulary taken from Multica's cursor.go (system / assistant /
 * thinking / tool_call / tool_use / tool_result / result / error / text /
 * step_finish), which tracks a wider version range than a single local capture
 * would. Not verified against a live run on this machine: cursor-agent's stored
 * credentials are currently invalid, so it exits before emitting any protocol.
 */
export function parseCursorLine(line: string, ctx: LineContext): AgentEvent[] | null {
  const obj = parseJsonLine(line);
  if (!obj) return null;
  const type = asString(obj["type"]);
  if (type === null) return null;

  switch (type) {
    case "system": {
      const sid = asString(obj["session_id"]);
      if (sid) ctx.sessionId = sid;
      const subtype = asString(obj["subtype"]) ?? "system";
      return [{ type: "status", status: subtype, ...(sid ? { sessionId: sid } : {}) }];
    }

    case "assistant": {
      const msg = asRecord(obj["message"]);
      if (!msg) return null;
      if (msg["usage"] !== undefined) applyCursorUsage(ctx, msg);
      const out = blocksToEvents(msg["content"], ctx);
      return out.length > 0 ? out : null;
    }

    case "text": {
      const text = asString(obj["text"]) ?? "";
      if (text.length === 0) return null;
      ctx.lastText = text;
      return [{ type: "text", content: text }];
    }

    case "thinking": {
      // Deltas would flood the timeline; only the settled block is recorded.
      if (asString(obj["subtype"]) === "delta") return null;
      const text = asString(obj["text"]) ?? "";
      return text.length > 0 ? [{ type: "thinking", content: text }] : null;
    }

    case "tool_call": {
      /*
       * The tool name is the KEY inside `tool_call`, not a `tool_name` field.
       *
       * Captured from cursor-agent 2026.07.23:
       *   { type: "tool_call", subtype: "completed", call_id: "...",
       *     tool_call: { editToolCall: { args: {...}, result: { success: {...} } },
       *                  toolCallId: "...", startedAtMs: "..." } }
       *
       * There is no `tool_name` and no top-level `output` anywhere. Reading those —
       * which is what a translation of Multica's Go struct suggested — meant every
       * cursor tool call rendered as "unknown" with empty output. It looked like the
       * agent was doing nothing legible, which is indistinguishable from an agent
       * that actually did nothing.
       */
      const subtype = asString(obj["subtype"]);
      const inner = asRecord(obj["tool_call"]);
      const callId =
        asString(obj["call_id"]) ?? asString(inner?.["toolCallId"]) ?? asString(obj["tool_id"]) ?? "";

      // e.g. "editToolCall" → "edit". Falls back to the raw key if the suffix
      // convention ever changes, which is still far better than "unknown".
      const namedKey = inner
        ? Object.keys(inner).find((k) => k.endsWith("ToolCall") && asRecord(inner[k]) !== null)
        : undefined;
      const tool = namedKey ? namedKey.replace(/ToolCall$/, "") : (asString(obj["tool_name"]) ?? "unknown");
      const detail = namedKey ? asRecord(inner?.[namedKey]) : null;

      if (subtype === "started") {
        return [{ type: "tool_use", tool, callId, input: detail?.["args"] ?? obj["parameters"] ?? null }];
      }
      if (subtype === "completed") {
        return [{ type: "tool_result", tool, callId, output: cursorToolOutput(detail).slice(0, 20000) }];
      }
      return null;
    }

    /*
     * Transport churn, surfaced rather than swallowed.
     *
     * A real capture included `connection/reconnecting`, `retry/starting` and
     * `retry/resuming` — cursor drops and resumes its own connection mid-turn.
     * Dropping these silently meant a run that had genuinely stalled for thirty
     * seconds looked identical to one that was hung, with nothing in the timeline to
     * explain the gap. They are status lines, so they cost nothing and answer the
     * first question a user asks.
     */
    case "connection":
    case "retry": {
      const subtype = asString(obj["subtype"]) ?? type;
      const attempt = asNumber(obj["attempt"]);
      return [
        {
          type: "status",
          status: `${type}: ${subtype}${attempt > 0 ? ` (attempt ${attempt})` : ""}`,
        },
      ];
    }

    case "tool_use":
      return [
        {
          type: "tool_use",
          tool: asString(obj["tool_name"]) ?? "unknown",
          callId: asString(obj["tool_id"]) ?? asString(obj["call_id"]) ?? "",
          input: obj["parameters"] ?? null,
        },
      ];

    case "tool_result":
      return [
        {
          type: "tool_result",
          tool: asString(obj["tool_name"]) ?? "",
          callId: asString(obj["tool_id"]) ?? asString(obj["call_id"]) ?? "",
          output: (asString(obj["output"]) ?? "").slice(0, 20000),
        },
      ];

    case "result": {
      ctx.turnCompleted = true;
      const sid = asString(obj["session_id"]);
      if (sid) ctx.sessionId = sid;
      const text = asString(obj["result"]);
      if (text && text.length > 0) ctx.lastText = text;
      applyCursorUsage(ctx, obj);
      if (obj["is_error"] === true) {
        ctx.failure = asString(obj["error"]) ?? text ?? "cursor reported is_error";
        return [{ type: "error", message: ctx.failure }];
      }
      return [{ type: "status", status: "done" }];
    }

    case "error": {
      const msg = asString(obj["error"]) ?? asString(obj["detail"]) ?? "cursor error";
      ctx.failure = msg;
      return [{ type: "error", message: msg }];
    }

    case "step_finish":
      return null;

    default:
      return null;
  }
}

export class CursorAdapter implements AgentAdapter {
  readonly kind = "cursor" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("cursor-agent");
    if (!execPath) return null;
    const version = await probeVersion(execPath, ["--version"]);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    return spawnStream({
      execPath: "cursor-agent",
      args: buildArgs(prompt, opts),
      cwd: opts.cwd,
      onLine: parseCursorLine,
      finalize: (ctx: LineContext, exitCode: number | null, stderrTail: string): AgentResult => {
        const ok = exitCode === 0 && ctx.failure === null;
        let error: string | null = null;
        if (!ok) {
          error = ctx.failure ?? `cursor-agent exited ${exitCode}`;
          // Auth failure is the single most likely cause of a silent exit, and
          // it is fixable only by a human running `cursor-agent login`.
          if (/authentication|log ?in/i.test(stderrTail)) {
            error = `cursor-agent is not authenticated — run \`cursor-agent login\`. (${stderrTail.trim().slice(0, 200)})`;
          } else if (stderrTail.length > 0) {
            error += `\nstderr tail: ${stderrTail.slice(-600)}`;
          }
        }
        return {
          status: ok ? "completed" : "failed",
          output: ctx.lastText,
          error,
          sessionId: ctx.sessionId,
          durationMs: 0,
          usage: ctx.usage,
        };
      },
      ...(opts.idleTimeoutMs !== undefined ? { idleTimeoutMs: opts.idleTimeoutMs } : {}),
      ...(opts.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
      ...(opts.signal ? { signal: opts.signal } : {}),
    });
  }
}
