import assert from "node:assert/strict";
import { test } from "node:test";
import {
  MAX_TRANSIENT_RETRIES,
  isTransientFailure,
  retryDelayMs,
} from "./transient.ts";

/**
 * Transient-failure classification.
 *
 * Worth testing on its own because both mistakes are expensive and neither is
 * visible at runtime: missing a transient failure loses a subtask's work,
 * misjudging a deterministic one burns minutes and tokens re-running something
 * that cannot succeed.
 *
 * The strings below are the REAL formats the adapters produce — verified against
 * claude.ts (`claude exited N: <stderr tail>`), acp.ts (`acp ended without a
 * completed turn (exit N)\nstderr tail: …`) and a live cursor failure — not
 * invented shapes.
 */

test("transient: the real 503 that lost a subtask in a live run", () => {
  // Verbatim from this session's engine log.
  const real = "cursor-agent exited 1\nstderr tail: Error: [unavailable] HTTP 503";
  assert.equal(isTransientFailure("failed", real), true);
});

test("transient: server unavailability and rate limits are retried", () => {
  for (const error of [
    "claude exited 1: Error: HTTP 503 Service Unavailable",
    "acp ended without a completed turn (exit 1)\nstderr tail: 502 Bad Gateway",
    "codex exited 1: overloaded_error: the model is overloaded",
    "claude exited 1: rate limit exceeded, retry after 2s",
    "HTTP 429 Too Many Requests",
    "gemini exited 1: fetch failed",
    "read ECONNRESET",
    "socket hang up",
    "Error: server is temporarily unavailable",
    "internal server error",
  ]) {
    assert.equal(isTransientFailure("failed", error), true, `should retry: ${error}`);
  }
});

test("transient: auth and setup failures are NOT retried", () => {
  /*
   * These recur identically, and the fix is a human action — log in, install the
   * CLI, grant a permission. Retrying only postpones telling the user what to do,
   * at a full process spawn each time.
   */
  for (const error of [
    "claude exited 1: not logged in. Run `claude login`.",
    "codex exited 1: 401 unauthorized",
    "HTTP 403 Forbidden",
    "invalid API key provided",
    "spawn failed: ENOENT",
    "cursor-agent: command not found",
    "permission denied",
    "quota exceeded for this billing period",
    "HTTP 402 Payment Required",
    "unsupported model: gpt-9",
    "context length exceeded",
  ]) {
    assert.equal(isTransientFailure("failed", error), false, `should NOT retry: ${error}`);
  }
});

test("transient: a deterministic signal beats a transient one in the same message", () => {
  /*
   * Real messages carry both. A gateway that returns 401 inside a "service
   * unavailable" envelope is reporting an auth problem, and the auth part is the
   * authoritative half — so the denylist is checked first.
   *
   * Erring toward "retry" would be the worse mistake: it delays the honest error
   * that tells the user what to fix.
   */
  assert.equal(
    isTransientFailure("failed", "HTTP 401 unauthorized: service temporarily unavailable"),
    false,
  );
  assert.equal(
    isTransientFailure("failed", "rate limit exceeded — also, you are not logged in"),
    false,
  );
});

test("transient: an unrecognised failure is not retried", () => {
  // The default has to be "report it" rather than "spend another spawn guessing".
  for (const error of [
    "claude exited 1: something nobody has seen before",
    "the agent produced no output",
    "exited 7",
  ]) {
    assert.equal(isTransientFailure("failed", error), false, `unknown: ${error}`);
  }
});

test("transient: only a `failed` status is eligible", () => {
  const retryable = "HTTP 503 service unavailable";

  // The user pressed stop. Respawning would override that.
  assert.equal(isTransientFailure("cancelled", retryable), false);

  /*
   * `timeout` is deliberately excluded even though the message looks retryable.
   * That is OUR watchdog firing, so the agent was alive but silent — usually a
   * genuinely stuck tool call. With a ten-minute default window, a retry doubles
   * the wait before the user learns anything.
   */
  assert.equal(isTransientFailure("timeout", retryable), false);

  // Not a failure at all.
  assert.equal(isTransientFailure("completed", retryable), false);
});

test("transient: a missing or empty message is not retried", () => {
  // Nothing to judge on, so surface it rather than guess.
  assert.equal(isTransientFailure("failed", null), false);
  assert.equal(isTransientFailure("failed", ""), false);
  assert.equal(isTransientFailure("failed", "   \n  "), false);
});

test("transient: matching ignores case", () => {
  assert.equal(isTransientFailure("failed", "HTTP 503 SERVICE UNAVAILABLE"), true);
  assert.equal(isTransientFailure("failed", "NOT LOGGED IN"), false);
});

// ── Backoff ─────────────────────────────────────────────────

test("backoff: grows, starts short, and is capped", () => {
  const first = retryDelayMs(1);
  const second = retryDelayMs(2);

  assert.ok(second > first, `expected growth, got ${first} then ${second}`);
  // Short enough that a person watching does not conclude the run has hung.
  assert.ok(first <= 2000, `first delay ${first}ms is too long to look alive`);
  // Long enough to let the far side actually recover.
  assert.ok(first >= 1000, `first delay ${first}ms is too eager`);

  // Capped, so a large attempt number cannot stall a stage.
  for (const n of [5, 10, 100]) {
    assert.ok(retryDelayMs(n) <= 12_000, `delay for attempt ${n} is unbounded`);
  }

  // Defensive: a zero or negative attempt must not produce a nonsense delay.
  assert.ok(retryDelayMs(0) > 0);
  assert.ok(retryDelayMs(-1) > 0);
});

test("budget: retries are bounded", () => {
  // A flapping provider must not be able to multiply the cost of every turn.
  assert.ok(MAX_TRANSIENT_RETRIES >= 1, "one retry is the minimum that helps");
  assert.ok(MAX_TRANSIENT_RETRIES <= 3, "more than this is a cost multiplier, not resilience");

  // Total wall clock added by a fully-exhausted retry sequence, so the tradeoff is
  // explicit rather than emergent.
  let total = 0;
  for (let i = 1; i <= MAX_TRANSIENT_RETRIES; i++) total += retryDelayMs(i);
  assert.ok(total <= 30_000, `worst-case added delay ${total}ms is too much per turn`);
});
