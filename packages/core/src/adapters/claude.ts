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
import { filterBlockedArgs, type AgentAdapter, type AgentEvent, type AgentResult, type BlockedArgMode, type ExecOptions } from "./types.ts";
import type { DetectedRuntime } from "../types.ts";

/**
 * Platform-owned flags. Letting a user override the streaming protocol or the
 * permission mode would silently break parsing rather than fail loudly.
 */
const BLOCKED: Readonly<Record<string, BlockedArgMode>> = {
  "-p": "withValue",
  "--print": "withValue",
  "--output-format": "withValue",
  "--input-format": "withValue",
  "--permission-mode": "withValue",
  "--dangerously-skip-permissions": "standalone",
  "--resume": "withValue",
  "--model": "withValue",
  "--verbose": "standalone",
};

/** Exported for tests: the arg list is the whole contract with the CLI. */
export function buildArgs(prompt: string, opts: ExecOptions): string[] {
  const args = [
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    // Unattended runs cannot answer a permission prompt. Worth stating plainly:
    // this bypasses tool confirmation, which is why the whole system is
    // localhost-only and every subtask runs in a throwaway worktree.
    "--permission-mode",
    "bypassPermissions",
  ];
  if (opts.model) args.push("--model", opts.model);
  if (opts.resumeSessionId) args.push("--resume", opts.resumeSessionId);
  const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
  args.push(...kept);
  return args;
}

/**
 * Parses one line of Claude Code's stream-json.
 *
 * Verified against claude 2.1.220. Two things the shape actually demands:
 *  - The terminal event carries `type: "result"` but that key is emitted LAST,
 *    so the whole object must be parsed before dispatching on type.
 *  - `system` events include hook chatter (`subtype: hook_started` /
 *    `hook_response`) that is not agent output and must not reach the timeline.
 */
export function parseClaudeLine(line: string, ctx: LineContext): AgentEvent[] | null {
  const obj = parseJsonLine(line);
  if (!obj) return null;
  const type = asString(obj["type"]);
  if (type === null) return null;

  switch (type) {
    case "system": {
      const subtype = asString(obj["subtype"]);
      const sid = asString(obj["session_id"]);
      if (sid) ctx.sessionId = sid;
      if (subtype === "init") {
        return [{ type: "status", status: "init", ...(sid ? { sessionId: sid } : {}) }];
      }
      // Hook lifecycle noise: recorded nowhere, surfaced nowhere.
      return null;
    }

    case "assistant": {
      const msg = asRecord(obj["message"]);
      if (!msg) return null;
      const content = msg["content"];
      if (!Array.isArray(content)) return null;
      const out: AgentEvent[] = [];
      for (const raw of content) {
        const block = asRecord(raw);
        if (!block) continue;
        const bt = asString(block["type"]);
        if (bt === "text") {
          const text = asString(block["text"]) ?? "";
          if (text.length > 0) {
            ctx.lastText = text;
            out.push({ type: "text", content: text });
          }
        } else if (bt === "thinking") {
          const thinking = asString(block["thinking"]) ?? "";
          if (thinking.length > 0) out.push({ type: "thinking", content: thinking });
        } else if (bt === "tool_use") {
          out.push({
            type: "tool_use",
            tool: asString(block["name"]) ?? "unknown",
            callId: asString(block["id"]) ?? "",
            input: block["input"] ?? null,
          });
        }
      }
      return out.length > 0 ? out : null;
    }

    case "user": {
      // Tool results come back wrapped as a synthetic user turn.
      const msg = asRecord(obj["message"]);
      if (!msg) return null;
      const content = msg["content"];
      if (!Array.isArray(content)) return null;
      const out: AgentEvent[] = [];
      for (const raw of content) {
        const block = asRecord(raw);
        if (!block) continue;
        if (asString(block["type"]) !== "tool_result") continue;
        const c = block["content"];
        let text = "";
        if (typeof c === "string") text = c;
        else if (Array.isArray(c)) {
          text = c
            .map((p) => asString(asRecord(p)?.["text"]) ?? "")
            .filter((s) => s.length > 0)
            .join("\n");
        }
        out.push({
          type: "tool_result",
          tool: "",
          callId: asString(block["tool_use_id"]) ?? "",
          output: text.slice(0, 20000),
        });
      }
      return out.length > 0 ? out : null;
    }

    case "result": {
      ctx.turnCompleted = true;
      const sid = asString(obj["session_id"]);
      if (sid) ctx.sessionId = sid;
      const finalText = asString(obj["result"]);
      if (finalText && finalText.length > 0) ctx.lastText = finalText;

      const usage = asRecord(obj["usage"]);
      if (usage) {
        ctx.usage.inputTokens += asNumber(usage["input_tokens"]);
        ctx.usage.outputTokens += asNumber(usage["output_tokens"]);
        ctx.usage.cacheReadTokens += asNumber(usage["cache_read_input_tokens"]);
        ctx.usage.cacheWriteTokens += asNumber(usage["cache_creation_input_tokens"]);
      }
      ctx.usage.costUsd += asNumber(obj["total_cost_usd"]);

      if (obj["is_error"] === true) {
        ctx.failure = asString(obj["error"]) ?? finalText ?? "claude reported is_error";
        return [{ type: "error", message: ctx.failure }];
      }
      return [{ type: "status", status: "done" }];
    }

    default:
      return null;
  }
}

export class ClaudeAdapter implements AgentAdapter {
  readonly kind = "claude" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("claude");
    if (!execPath) return null;
    const version = await probeVersion(execPath);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    const spawnOpts = {
      // Resolved to an absolute path by the transport, which searches the same
      // install directories as detect() — spawn's own PATH lookup does not.
      execPath: "claude",
      args: buildArgs(prompt, opts),
      cwd: opts.cwd,
      onLine: parseClaudeLine,
      finalize: (ctx: LineContext, exitCode: number | null, stderrTail: string): AgentResult => {
        const ok = exitCode === 0 && ctx.failure === null;
        return {
          status: ok ? "completed" : "failed",
          output: ctx.lastText,
          error: ok ? null : (ctx.failure ?? `claude exited ${exitCode}: ${stderrTail.slice(-800)}`),
          sessionId: ctx.sessionId,
          durationMs: 0,
          usage: ctx.usage,
        };
      },
      ...(opts.idleTimeoutMs !== undefined ? { idleTimeoutMs: opts.idleTimeoutMs } : {}),
      ...(opts.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
      ...(opts.signal ? { signal: opts.signal } : {}),
    };
    return spawnStream(spawnOpts);
  }
}
