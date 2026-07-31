import type { z } from "zod";

/**
 * Extracts the first plausible JSON object from an agent's prose.
 *
 * CLI agents emit text, not objects. Even under a strict instruction they wrap
 * JSON in prose, fence it in markdown, or append a closing remark. Treating
 * that as an error would fail most turns; treating it as the normal case and
 * digging the object out is what actually works.
 */
export function extractJson(text: string): string | null {
  const trimmed = text.trim();
  if (trimmed.length === 0) return null;

  // Fenced block first — the most common shape.
  const fence = /```(?:json)?\s*\n([\s\S]*?)\n?```/.exec(trimmed);
  if (fence?.[1]) {
    const inner = fence[1].trim();
    if (inner.startsWith("{") || inner.startsWith("[")) return inner;
  }

  // Otherwise scan for a balanced object, respecting strings and escapes so a
  // brace inside a string literal cannot end the scan early.
  const start = trimmed.search(/[{[]/);
  if (start < 0) return null;
  const open = trimmed[start];
  const close = open === "{" ? "}" : "]";
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < trimmed.length; i++) {
    const ch = trimmed[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      escaped = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return trimmed.slice(start, i + 1);
    }
  }
  return null;
}

export interface ParseAttemptResult<T> {
  ok: boolean;
  value: T | null;
  error: string | null;
}

/**
 * The third type parameter pins `T` to zod's OUTPUT type.
 *
 * With a bare `z.ZodType<T>`, TypeScript unifies against the input side, so any
 * field carrying `.default()` infers as optional — which contradicts runtime,
 * where the default has already been applied by the time we read it.
 */
export function tryParse<T>(
  schema: z.ZodType<T, z.ZodTypeDef, unknown>,
  text: string,
): ParseAttemptResult<T> {
  const json = extractJson(text);
  if (json === null) {
    return { ok: false, value: null, error: "no JSON object found in the response" };
  }
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch (err) {
    return { ok: false, value: null, error: `JSON parse failed: ${String(err)}` };
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .slice(0, 8)
      .map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`)
      .join("; ");
    return { ok: false, value: null, error: `schema mismatch: ${issues}` };
  }
  return { ok: true, value: parsed.data, error: null };
}

/** A correction turn that tells the agent exactly what was wrong. */
export function repairPrompt(original: string, error: string, previous: string): string {
  return [
    "Your previous response could not be parsed.",
    `Problem: ${error}`,
    "",
    "Reply with ONLY a single valid JSON object matching the requested schema.",
    "No markdown fences, no commentary before or after.",
    "",
    "--- Your previous response (for reference) ---",
    previous.slice(0, 3000),
    "",
    "--- Original request ---",
    original,
  ].join("\n");
}
