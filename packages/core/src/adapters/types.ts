import type { DetectedRuntime, RuntimeKind } from "../types.ts";

/**
 * Normalized event from any CLI. Every adapter flattens its vendor protocol
 * (claude/cursor stream-json, codex JSONL, gemini stream-json) into this shape,
 * so the orchestrator and the UI never learn a vendor dialect.
 *
 * This is Multica's `agent.Message` translated to TypeScript — a design already
 * proven across its 18 backends.
 */
export type AgentEvent =
  | { type: "text"; content: string }
  | { type: "thinking"; content: string }
  | { type: "tool_use"; tool: string; callId: string; input: unknown }
  | { type: "tool_result"; tool: string; callId: string; output: string }
  | { type: "status"; status: string; sessionId?: string }
  | { type: "error"; message: string };

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  costUsd: number;
}

export const EMPTY_USAGE: TokenUsage = {
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  costUsd: 0,
};

export type AgentResultStatus = "completed" | "failed" | "timeout" | "cancelled";

export interface AgentResult {
  status: AgentResultStatus;
  /** Final user-facing output the adapter selected from the stream. */
  output: string;
  error: string | null;
  sessionId: string | null;
  durationMs: number;
  usage: TokenUsage;
}

export interface ExecOptions {
  cwd: string;
  model?: string | null;
  /**
   * Carried inline for runtimes that cannot pick it up from disk. Multica
   * writes a per-task context file (CLAUDE.md / AGENTS.md / QWEN.md) instead
   * for most providers; we do both — file for durability, flag where supported.
   */
  systemPrompt?: string | null;
  resumeSessionId?: string | null;
  /**
   * No-new-events watchdog. Zero disables it. A separate, longer budget applies
   * while a tool call is in flight, because a long build is not a hang.
   */
  idleTimeoutMs?: number;
  /** Hard wall-clock cap. Zero means liveness is the watchdog's job alone. */
  timeoutMs?: number;
  signal?: AbortSignal;
  /** Appended after platform-owned args, and filtered against blockedArgs. */
  extraArgs?: string[];
  /** JSON Schema path for runtimes with native structured output (codex). */
  outputSchemaPath?: string | null;
}

/** A running execution: a live event stream plus exactly one terminal result. */
export interface AgentRun {
  events: AsyncIterable<AgentEvent>;
  result: Promise<AgentResult>;
  cancel(): void;
}

export interface AgentAdapter {
  readonly kind: RuntimeKind;
  /** Returns null when the CLI is absent from PATH. */
  detect(): Promise<DetectedRuntime | null>;
  execute(prompt: string, opts: ExecOptions): AgentRun;
}

/**
 * How a user-supplied CLI flag is rejected.
 *
 * Platform-owned flags must be unspoofable. Multica learned this the hard way:
 * without the guard, a custom arg can silently switch off the streaming
 * protocol and the entire parse chain goes quiet instead of failing loudly.
 */
export type BlockedArgMode = "standalone" | "withValue";

/** Strips platform-owned flags from user args, returning what survives. */
export function filterBlockedArgs(
  args: readonly string[],
  blocked: Readonly<Record<string, BlockedArgMode>>,
): { kept: string[]; dropped: string[] } {
  const kept: string[] = [];
  const dropped: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === undefined) continue;
    // Tolerate --flag=value as well as --flag value.
    const eq = arg.indexOf("=");
    const bare = eq > 0 ? arg.slice(0, eq) : arg;
    const mode = blocked[bare];
    if (mode === undefined) {
      kept.push(arg);
      continue;
    }
    dropped.push(arg);
    if (mode === "withValue" && eq < 0) {
      const next = args[i + 1];
      if (next !== undefined && !next.startsWith("-")) {
        dropped.push(next);
        i++;
      }
    }
  }
  return { kept, dropped };
}
