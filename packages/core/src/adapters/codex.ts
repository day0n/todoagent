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
  "--json": "standalone",
  "-s": "withValue",
  "--sandbox": "withValue",
  "--dangerously-bypass-approvals-and-sandbox": "standalone",
  "-C": "withValue",
  "--cd": "withValue",
  "-m": "withValue",
  "--model": "withValue",
  "--output-schema": "withValue",
  "--skip-git-repo-check": "standalone",
};

function buildArgs(prompt: string, opts: ExecOptions): string[] {
  const args = [
    "exec",
    "--json",
    // The agent writes inside its own throwaway worktree, so it needs write
    // access there. `workspace-write` keeps it scoped to that tree rather than
    // handing over the whole machine.
    "-s",
    "workspace-write",
    "--skip-git-repo-check",
    "-C",
    opts.cwd,
  ];
  if (opts.model) args.push("-m", opts.model);
  // Codex is the one runtime with native structured output — when the caller
  // supplies a schema we let the CLI enforce it instead of reparsing prose.
  if (opts.outputSchemaPath) args.push("--output-schema", opts.outputSchemaPath);
  const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
  args.push(...kept);
  args.push(prompt);
  return args;
}

/**
 * Parses one line of `codex exec --json`.
 *
 * Verified against codex-cli 0.146.0. The critical finding: an item with
 * `type: "error"` is NOT necessarily a failed turn. A stock install emits these
 * for benign local conditions — a clamped hook timeout, truncated skill
 * descriptions — and then completes normally. Mapping them to failure would
 * mark essentially every codex run failed. They are recorded as warnings; real
 * failure is the absence of `turn.completed` plus a nonzero exit.
 */
export function parseCodexLine(line: string, ctx: LineContext): AgentEvent[] | null {
  const obj = parseJsonLine(line);
  if (!obj) return null;
  const type = asString(obj["type"]);
  if (type === null) return null;

  switch (type) {
    case "thread.started": {
      const id = asString(obj["thread_id"]);
      if (id) ctx.sessionId = id;
      return [{ type: "status", status: "init", ...(id ? { sessionId: id } : {}) }];
    }

    case "turn.started":
      return [{ type: "status", status: "turn_started" }];

    case "turn.completed": {
      ctx.turnCompleted = true;
      const usage = asRecord(obj["usage"]);
      if (usage) {
        ctx.usage.inputTokens += asNumber(usage["input_tokens"]);
        ctx.usage.outputTokens += asNumber(usage["output_tokens"]);
        ctx.usage.cacheReadTokens += asNumber(usage["cached_input_tokens"]);
        ctx.usage.cacheWriteTokens += asNumber(usage["cache_write_input_tokens"]);
      }
      return [{ type: "status", status: "done" }];
    }

    case "turn.failed": {
      const err = asRecord(obj["error"]);
      ctx.failure = asString(err?.["message"]) ?? "codex turn failed";
      return [{ type: "error", message: ctx.failure }];
    }

    case "item.started":
    case "item.updated":
    case "item.completed": {
      const item = asRecord(obj["item"]);
      if (!item) return null;
      const itemType = asString(item["type"]);
      // Only terminal item states carry settled content; earlier states would
      // duplicate every chunk onto the timeline.
      const isCompleted = type === "item.completed";

      switch (itemType) {
        case "agent_message": {
          if (!isCompleted) return null;
          const text = asString(item["text"]) ?? "";
          if (text.length === 0) return null;
          ctx.lastText = text;
          return [{ type: "text", content: text }];
        }
        case "reasoning": {
          if (!isCompleted) return null;
          const text = asString(item["text"]) ?? asString(item["summary"]) ?? "";
          return text.length > 0 ? [{ type: "thinking", content: text }] : null;
        }
        case "command_execution": {
          const cmd = asString(item["command"]) ?? "";
          const id = asString(item["id"]) ?? "";
          if (!isCompleted) {
            return [{ type: "tool_use", tool: "shell", callId: id, input: { command: cmd } }];
          }
          const out = asString(item["aggregated_output"]) ?? asString(item["output"]) ?? "";
          return [{ type: "tool_result", tool: "shell", callId: id, output: out.slice(0, 20000) }];
        }
        case "file_change": {
          const id = asString(item["id"]) ?? "";
          if (!isCompleted) {
            return [{ type: "tool_use", tool: "edit", callId: id, input: item["changes"] ?? null }];
          }
          return [{ type: "tool_result", tool: "edit", callId: id, output: "applied" }];
        }
        case "error": {
          // See the doc comment: benign local warnings arrive under this type.
          const msg = asString(item["message"]) ?? "unknown codex item error";
          ctx.warnings.push(msg);
          return [{ type: "status", status: `warning: ${msg.slice(0, 200)}` }];
        }
        default:
          return null;
      }
    }

    default:
      return null;
  }
}

export class CodexAdapter implements AgentAdapter {
  readonly kind = "codex" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("codex");
    if (!execPath) return null;
    const version = await probeVersion(execPath);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    return spawnStream({
      execPath: "codex",
      args: buildArgs(prompt, opts),
      cwd: opts.cwd,
      onLine: parseCodexLine,
      finalize: (ctx: LineContext, exitCode: number | null, stderrTail: string): AgentResult => {
        // stderr is not a failure signal here: a stock codex install streams MCP
        // transport errors for unrelated servers on every run.
        const ok = exitCode === 0 && ctx.failure === null && ctx.turnCompleted;
        let error: string | null = null;
        if (!ok) {
          error =
            ctx.failure ??
            (ctx.turnCompleted
              ? `codex exited ${exitCode}`
              : `codex produced no completed turn (exit ${exitCode})`);
          if (stderrTail.length > 0) error += `\nstderr tail: ${stderrTail.slice(-600)}`;
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
