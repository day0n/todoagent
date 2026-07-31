import type { DetectedRuntime, RuntimeKind } from "../types.ts";
import { RUNTIME_KINDS } from "../types.ts";
import { ClaudeAdapter } from "./claude.ts";
import { CodexAdapter } from "./codex.ts";
import { CursorAdapter } from "./cursor.ts";
import { GeminiAdapter } from "./gemini.ts";
import { GrokAdapter } from "./grok.ts";
import { KiroAdapter } from "./kiro.ts";
import type { AgentAdapter } from "./types.ts";

export * from "./types.ts";
export { parseClaudeLine } from "./claude.ts";
export { parseCodexLine } from "./codex.ts";
export { parseCursorLine } from "./cursor.ts";
export { parseGeminiLine } from "./gemini.ts";
export { newLineContext, type LineContext } from "./process.ts";

const REGISTRY: Readonly<Record<RuntimeKind, () => AgentAdapter>> = {
  claude: () => new ClaudeAdapter(),
  codex: () => new CodexAdapter(),
  cursor: () => new CursorAdapter(),
  gemini: () => new GeminiAdapter(),
  kiro: () => new KiroAdapter(),
  grok: () => new GrokAdapter(),
};

export function getAdapter(kind: RuntimeKind): AgentAdapter {
  const make = REGISTRY[kind];
  if (!make) throw new Error(`unknown runtime kind: ${kind}`);
  return make();
}

/** Probes every known CLI. Absent ones are simply missing from the result. */
export async function detectAll(): Promise<DetectedRuntime[]> {
  const results = await Promise.all(
    RUNTIME_KINDS.map(async (kind) => {
      try {
        return await getAdapter(kind).detect();
      } catch {
        return null;
      }
    }),
  );
  return results.filter((r): r is DetectedRuntime => r !== null);
}
