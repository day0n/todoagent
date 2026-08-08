import type { RuntimeInfo, RuntimeKind, RuntimeStatus } from "./types.ts";

export const RUNTIME_KINDS = [
  "claude",
  "codex",
  "cursor",
  "gemini",
  "kiro",
  "grok",
] as const satisfies readonly RuntimeKind[];

export const RUNTIME_LABEL: Record<RuntimeKind, string> = {
  claude: "Claude Code",
  codex: "Codex",
  cursor: "Cursor Agent",
  gemini: "Gemini CLI",
  kiro: "Kiro CLI",
  grok: "Grok CLI",
};

export const RUNTIME_STATUS_LABEL: Record<RuntimeStatus, string> = {
  missing: "未安装",
  unverified: "待验证",
  verifying: "验证中",
  ready: "可用",
  auth_required: "需要登录",
  error: "异常",
};

/** A localStorage value is untrusted in exactly the same way as an API value. */
export function isRuntimeKind(value: unknown): value is RuntimeKind {
  return typeof value === "string" && (RUNTIME_KINDS as readonly string[]).includes(value);
}

/**
 * Picker precedence is product behaviour, kept pure so both regressions and future
 * callers cannot silently invent a different default.
 */
export function preferredRuntimeKind(
  runtimes: readonly RuntimeInfo[],
  taskRuntime: RuntimeKind | null | undefined,
  lastExplicit: RuntimeKind | null,
): RuntimeKind | null {
  const ready = runtimes.filter((runtime) => runtime.status === "ready");
  const usable = new Set(ready.map((runtime) => runtime.kind));
  if (taskRuntime !== null && taskRuntime !== undefined && usable.has(taskRuntime)) {
    return taskRuntime;
  }
  if (lastExplicit !== null && usable.has(lastExplicit)) return lastExplicit;
  return ready.length === 1 ? ready[0]!.kind : null;
}

/** Engine labels are display data, but old engines may omit them. */
export function runtimeLabel(kind: RuntimeKind, label?: string | null): string {
  return label?.trim() || RUNTIME_LABEL[kind];
}
