/**
 * Tells a transient agent failure from a deterministic one.
 *
 * A dependency-free leaf module, like `review-rules.ts` and `mentions.ts`, because
 * the decision it encodes is expensive in BOTH directions and therefore worth
 * testing on its own:
 *
 *  - Not retrying a transient failure loses real work. Observed in a live run:
 *    `cursor-agent exited 1` with `Error: [unavailable] HTTP 503` permanently
 *    killed a subtask, and a second 503 killed another — the user asked for three
 *    things and got one.
 *  - Retrying a deterministic failure burns minutes and tokens for nothing. A CLI
 *    that is not logged in will fail identically forever, and each attempt is a
 *    full process spawn.
 *
 * So the denylist is checked FIRST and wins. A real message can contain both
 * kinds of signal — `401 unauthorized: service temporarily unavailable` — and in
 * that case the authoritative part is the auth failure. Guessing wrong toward
 * "retry" is the more expensive mistake, since it delays the honest error report
 * that tells the user what to fix.
 */

import type { AgentResultStatus } from "../adapters/types.ts";

/**
 * Failures that will recur identically. Checked before anything else.
 *
 * These are the ones where the fix is a human action — log in, install the CLI,
 * grant a permission — so retrying only postpones telling them.
 */
const DETERMINISTIC = [
  // Auth. Every vendor words this differently.
  "not logged in",
  "unauthorized",
  "unauthenticated",
  "authentication",
  "invalid api key",
  "invalid_api_key",
  "no api key",
  "api key not found",
  "forbidden",
  "http 401",
  "http 403",
  "401 ",
  "403 ",
  // Missing or unusable executable.
  "enoent",
  "command not found",
  "no such file",
  "permission denied",
  "eacces",
  "spawn failed",
  // The request itself is wrong, so repeating it changes nothing.
  "http 400",
  "http 404",
  "http 422",
  "invalid request",
  "unsupported model",
  "model not found",
  "context length",
  "too long",
  // Quota, as opposed to rate limiting: exhausted credit does not refill in
  // seconds, so a retry inside one run cannot help.
  "quota exceeded",
  "insufficient credit",
  "insufficient_quota",
  "billing",
  "payment required",
  "http 402",
];

/**
 * Failures that plausibly succeed on a second attempt moments later.
 *
 * Deliberately narrow. Anything not listed here is treated as deterministic,
 * because the default has to be "report it" rather than "spend more on it".
 */
const TRANSIENT = [
  // Server-side unavailability.
  "http 502",
  "http 503",
  "http 504",
  "502 ",
  "503 ",
  "504 ",
  "bad gateway",
  "gateway timeout",
  "service unavailable",
  "unavailable",
  "overloaded",
  "temporarily",
  "try again",
  "internal server error",
  "http 500",
  // Rate limiting — the one throttle that clears on its own.
  "rate limit",
  "rate_limit",
  "ratelimit",
  "too many requests",
  "http 429",
  "429 ",
  // Network faults.
  "econnreset",
  "econnrefused",
  "etimedout",
  "enetunreach",
  "ehostunreach",
  "eai_again",
  "socket hang up",
  "fetch failed",
  "network error",
  "connection closed",
  "connection reset",
  "stream error",
];

/**
 * Should this failure be retried?
 *
 * `status` matters as much as the message:
 *
 *  - `cancelled` is never retried. The user stopped it.
 *  - `timeout` is never retried either, and that is a judgment call. It is OUR
 *    watchdog firing, so the agent was alive but silent — often a genuinely stuck
 *    tool call rather than a blip. With a ten-minute default window, retrying
 *    doubles the wait before the user learns anything, which is worse than
 *    reporting a hang promptly.
 *  - `completed` cannot be a failure at all.
 */
export function isTransientFailure(status: AgentResultStatus, error: string | null): boolean {
  if (status !== "failed") return false;
  if (error === null || error.trim() === "") {
    // A failure with no message gives nothing to judge on, and the safe default is
    // to surface it rather than to spend another spawn guessing.
    return false;
  }

  const text = error.toLowerCase();

  // Deny wins. See the module note: a message carrying both signals is reporting
  // an auth or setup problem wrapped in a generic transport error.
  for (const needle of DETERMINISTIC) {
    if (text.includes(needle)) return false;
  }
  for (const needle of TRANSIENT) {
    if (text.includes(needle)) return true;
  }
  return false;
}

/**
 * How long to wait before attempt number `n` (1-based).
 *
 * Exponential from a small base, because the failures worth retrying clear in
 * seconds — a 503 during a deploy, a burst rate limit. Long enough to let the far
 * side recover, short enough that a person watching a run does not conclude it
 * has hung. Capped so a large `n` cannot stall a stage.
 */
export function retryDelayMs(attempt: number): number {
  const base = 1500;
  const max = 12_000;
  return Math.min(max, base * 2 ** Math.max(0, attempt - 1));
}

/**
 * Extra spawns allowed after the first failure.
 *
 * Two, so a subtask survives a brief outage without a flapping provider being
 * able to triple the cost of every turn in the run.
 */
export const MAX_TRANSIENT_RETRIES = 2;
