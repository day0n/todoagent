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
  execPathForRuntime,
  filterBlockedArgs,
  type AgentAdapter,
  type AgentEvent,
  type AgentResult,
  type BlockedArgMode,
  type ExecOptions,
} from "./types.ts";
import type { DetectedRuntime } from "../types.ts";

const BLOCKED: Readonly<Record<string, BlockedArgMode>> = {
  "-p": "withValue",
  "--prompt": "withValue",
  "-o": "withValue",
  "--output-format": "withValue",
  "-m": "withValue",
  "--model": "withValue",
  "-y": "standalone",
  "--yolo": "standalone",
  "--approval-mode": "withValue",
};

function buildArgs(prompt: string, opts: ExecOptions): string[] {
  // Gemini CLI and Qwen Code share a lineage (Qwen Code is a Gemini CLI fork),
  // so the flag surface matches Multica's qwen backend: -p, stream-json output,
  // -m for model, and a bypass flag that non-interactive mode requires before
  // it will run write/shell tools at all.
  const args = ["-p", prompt, "--output-format", "stream-json", "--yolo"];
  if (opts.model) args.push("-m", opts.model);
  const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
  args.push(...kept);
  return args;
}

/**
 * Parses Gemini CLI's stream-json.
 *
 * NOT verified against a live run — this machine has `gemini` on PATH but the
 * adapter was written from the Qwen Code protocol Multica documents. Treat the
 * event names as provisional: `todoagent doctor --probe gemini` captures a real
 * transcript so the mapping can be corrected against it.
 */
export function parseGeminiLine(line: string, ctx: LineContext): AgentEvent[] | null {
  const obj = parseJsonLine(line);
  if (!obj) return null;
  const type = asString(obj["type"]);
  if (type === null) return null;

  switch (type) {
    case "system": {
      const sid = asString(obj["session_id"]) ?? asString(obj["sessionId"]);
      if (sid) ctx.sessionId = sid;
      return [{ type: "status", status: asString(obj["subtype"]) ?? "system", ...(sid ? { sessionId: sid } : {}) }];
    }
    case "assistant": {
      const msg = asRecord(obj["message"]);
      const content = msg?.["content"];
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
          const text = asString(block["thinking"]) ?? asString(block["text"]) ?? "";
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
      return out.length > 0 ? out : null;
    }
    case "user": {
      const msg = asRecord(obj["message"]);
      const content = msg?.["content"];
      if (!Array.isArray(content)) return null;
      const out: AgentEvent[] = [];
      for (const raw of content) {
        const block = asRecord(raw);
        if (!block || asString(block["type"]) !== "tool_result") continue;
        const c = block["content"];
        const text =
          typeof c === "string"
            ? c
            : Array.isArray(c)
              ? c.map((p) => asString(asRecord(p)?.["text"]) ?? "").join("\n")
              : "";
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
      const text = asString(obj["result"]);
      if (text && text.length > 0) ctx.lastText = text;
      const usage = asRecord(obj["usage"]);
      if (usage) {
        ctx.usage.inputTokens += asNumber(usage["input_tokens"]);
        ctx.usage.outputTokens += asNumber(usage["output_tokens"]);
      }
      if (obj["is_error"] === true) {
        ctx.failure = asString(obj["error"]) ?? "gemini reported is_error";
        return [{ type: "error", message: ctx.failure }];
      }
      return [{ type: "status", status: "done" }];
    }
    default:
      return null;
  }
}

export class GeminiAdapter implements AgentAdapter {
  readonly kind = "gemini" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("gemini");
    if (!execPath) return null;
    const version = await probeVersion(execPath, ["--version"]);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    return spawnStream({
      execPath: execPathForRuntime(this.kind, opts),
      args: buildArgs(prompt, opts),
      cwd: opts.cwd,
      onLine: parseGeminiLine,
      finalize: (ctx: LineContext, exitCode: number | null, stderrTail: string): AgentResult => {
        const ok = exitCode === 0 && ctx.failure === null;
        let error: string | null = null;
        if (!ok) {
          error = ctx.failure ?? `gemini exited ${exitCode}`;
          // Observed locally: gemini 0.19.4 exits 1 within ~2s when no key is
          // configured. Without this the operator sees a generic exit code and
          // has to go read stderr to learn it is a credentials problem.
          if (/GEMINI_API_KEY|must specify the/i.test(stderrTail)) {
            error =
              "gemini has no credentials — set GEMINI_API_KEY (or sign in) before using this runtime.";
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
