import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { resolveModel, type ResolvedModel } from "./model.ts";

/**
 * What a finished worker turn actually amounts to.
 *
 * A single-turn CLI has no way to ask for help other than saying so in its final
 * output. Before this existed the engine read every `completed` run as work
 * delivered, so a run that ended with "which database should I use?" landed in
 * 待确认 looking finished — the user found out only by opening it.
 *
 * `done` keeps the M0 behaviour (待确认, a person confirms). `question` and
 * `blocked` park the card in 需要你 with the text that explains why.
 */
export type OutcomeKind = "done" | "question" | "blocked";

export interface Outcome {
  kind: OutcomeKind;
  /** The question or the obstacle, verbatim from the worker. Empty for `done`. */
  text: string;
  /** How this was decided. Logged, and asserted on in tests. */
  via: "model" | "heuristic";
}

/** `needsText` is a card subtitle, not a document. */
const MAX_NEEDS_TEXT = 500;

/**
 * A paragraph longer than this is prose, not a question.
 *
 * A question mark inside a long block is far more likely to be code, a quoted
 * error, or a rhetorical aside in a summary. Requiring brevity is what keeps
 * "I refactored the parser. Should it also handle `a?b:c`?" (short, asks) apart
 * from a 900-character report that happens to contain a `?`.
 */
const MAX_QUESTION_PARAGRAPH = 400;

/** Only the tail is classified: a worker's ask is always at the end. */
const CLASSIFY_TAIL = 4_000;

/**
 * The whole classification budget, model call included.
 *
 * Classification is an enhancement, not a gate. If the model is slow, absent, or
 * broken, the card must still move — a task stuck at 进行中 because a side-channel
 * LLM call hung is strictly worse than one classified imperfectly.
 */
const CLASSIFY_TIMEOUT_MS = 15_000;

const SYSTEM_PROMPT = `你在判断一个编码 agent 的最终输出属于哪一类。

只输出一个 JSON 对象，不要代码块，不要解释：
{"kind":"done|question|blocked","text":"…"}

分类标准：
- done：活干完了。即使它顺带说明了做法或提了建议，只要没有在等你回应，就是 done。
- question：它在向人提问，需要回答才能继续。text = 问题原文。
- blocked：它没干完，因为遇到了自己解决不了的障碍（缺凭据、缺文件、需要人决策）。text = 障碍原因。

text 只在 question / blocked 时填，控制在 200 字以内，用输出里的原话。done 时 text 为空字符串。`;

/** Trailing-whitespace-trimmed paragraphs, blank-line separated, empties dropped. */
function paragraphs(text: string): string[] {
  return text
    .replace(/\s+$/, "")
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p !== "");
}

/**
 * Classification with no model: does the output end by asking something?
 *
 * Deliberately narrow. This runs whenever `TODOAGENT_MODEL` is unset — which the
 * milestone requires to be a fully working configuration — so it has to be right
 * far more often than it is clever. Two rules:
 *
 *   the LAST paragraph asks, and it is SHORT  → question
 *   anything else                             → done
 *
 * It never returns `blocked`. There is no textual signal for "I gave up" that is
 * not also present in ordinary narration ("I couldn't find X, so I used Y" is a
 * completed task), and a card wrongly parked in 需要你 costs a person a click to
 * discover nothing is wrong.
 */
export function classifyHeuristic(output: string): Outcome {
  const paras = paragraphs(output);
  const last = paras[paras.length - 1];
  if (last === undefined) return { kind: "done", text: "", via: "heuristic" };

  const asks = last.includes("?") || last.includes("？");
  if (asks && last.length <= MAX_QUESTION_PARAGRAPH) {
    return { kind: "question", text: last.slice(0, MAX_NEEDS_TEXT), via: "heuristic" };
  }
  return { kind: "done", text: "", via: "heuristic" };
}

/** Pulls the first JSON object out of a reply that may be fenced or chatty. */
function extractJson(reply: string): unknown {
  const trimmed = reply.trim();
  try {
    return JSON.parse(trimmed);
  } catch {
    /* not bare JSON — look for an embedded object */
  }
  // Greedy to the LAST brace: a nested object would otherwise truncate.
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(trimmed.slice(start, end + 1));
  } catch {
    return null;
  }
}

/** Validates the model's answer, returning null when it is unusable. */
function readOutcome(parsed: unknown): Outcome | null {
  if (parsed === null || typeof parsed !== "object") return null;
  const rec = parsed as Record<string, unknown>;
  const kind = rec["kind"];
  if (kind !== "done" && kind !== "question" && kind !== "blocked") return null;
  const rawText = typeof rec["text"] === "string" ? rec["text"].trim() : "";
  /*
   * A question with no text is not usable: the card would park in 需要你 saying
   * nothing, which is the worst of both outcomes — the user is interrupted and not
   * told why. Treated as a parse failure so the heuristic gets its turn.
   */
  if (kind !== "done" && rawText === "") return null;
  return {
    kind,
    text: kind === "done" ? "" : rawText.slice(0, MAX_NEEDS_TEXT),
    via: "model",
  };
}

/** One non-streaming turn. Returns the assistant's text, concatenated. */
async function askModel(resolved: ResolvedModel, output: string, extraNudge: string): Promise<string> {
  const tail = output.length > CLASSIFY_TAIL ? output.slice(-CLASSIFY_TAIL) : output;
  const runtime: ModelRuntime = resolved.runtime;

  const reply = await runtime.complete(resolved.model, {
    systemPrompt: SYSTEM_PROMPT + extraNudge,
    messages: [
      {
        role: "user",
        content: `以下是编码 agent 的最终输出（可能只是尾部）：\n\n${tail}`,
        timestamp: Date.now(),
      },
    ],
    // No tools: this is a judgement call on text, and a tool loop is exactly the
    // kind of open-ended work a 15-second budget cannot contain.
    tools: [],
  });

  const parts: string[] = [];
  for (const block of reply.content) {
    if (typeof block === "object" && block !== null && "type" in block && block.type === "text") {
      const text = (block as { text?: unknown }).text;
      if (typeof text === "string") parts.push(text);
    }
  }
  return parts.join("");
}

export interface ClassifyDeps {
  /**
   * Resolves the configured model, or explains why it cannot.
   *
   * Injected so a test can drive the model path without an LLM, and so the
   * unconfigured case is reachable without mutating the environment.
   */
  resolve?: () => Promise<
    { ok: true; resolved: ResolvedModel } | { ok: false; reason: string }
  >;
  /** Overall budget including retry. Lowered in tests. */
  timeoutMs?: number;
  log?: (message: string) => void;
}

/**
 * Classifies a finished worker's output: model when configured, heuristic otherwise.
 *
 * This function does not throw. Every failure — no model, no credentials, a
 * timeout, malformed JSON twice over — resolves to the heuristic's answer, because
 * the caller is on the path that moves a card out of 进行中 and there is no
 * acceptable way for it to fail.
 */
export async function classifyOutcome(
  output: string,
  deps: ClassifyDeps = {},
): Promise<Outcome> {
  const fallback = classifyHeuristic(output);
  // Nothing to classify: an empty final output is the M0 `done` case.
  if (output.trim() === "") return fallback;

  const resolve = deps.resolve ?? resolveModel;
  const budget = deps.timeoutMs ?? CLASSIFY_TIMEOUT_MS;
  const log = deps.log ?? ((m: string) => console.log(`[classify] ${m}`));

  let timer: ReturnType<typeof setTimeout> | null = null;
  try {
    const attempt = async (): Promise<Outcome> => {
      const res = await resolve();
      if (!res.ok) {
        log(`no model (${res.reason.slice(0, 80)}) — heuristic`);
        return fallback;
      }

      // Two tries, the second stating the failure plainly. A text-first model
      // getting JSON wrong once is routine; twice means it will not comply.
      for (let i = 0; i < 2; i++) {
        const nudge = i === 0 ? "" : "\n\n上一次回复不是合法 JSON。这次只输出 JSON 对象本身。";
        const reply = await askModel(res.resolved, output, nudge);
        const parsed = readOutcome(extractJson(reply));
        if (parsed !== null) return parsed;
        log(`unparseable reply (try ${i + 1}/2): ${reply.trim().slice(0, 120)}`);
      }
      log("model would not produce usable JSON — heuristic");
      return fallback;
    };

    const timeout = new Promise<Outcome>((resolveTimeout) => {
      timer = setTimeout(() => {
        log(`timed out after ${budget}ms — heuristic`);
        resolveTimeout(fallback);
      }, budget);
    });

    return await Promise.race([attempt(), timeout]);
  } catch (err) {
    // Provider outage, network error, a shape the SDK rejected: all the same here.
    log(`failed (${err instanceof Error ? err.message : String(err)}) — heuristic`);
    return fallback;
  } finally {
    /*
     * Cleared on every exit, including the fast one.
     *
     * A pending 15-second timer keeps the event loop alive, which in a test run
     * means the process hangs after the last assertion instead of exiting.
     */
    if (timer !== null) clearTimeout(timer);
  }
}
