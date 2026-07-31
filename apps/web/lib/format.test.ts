import assert from "node:assert/strict";
import { test } from "node:test";
import { fmtDuration, fmtRelative, fmtTokens, fmtUsd } from "./api.ts";

/**
 * Tests for the display formatters.
 *
 * These look trivial and are not: each one encodes a claim the user reads as
 * fact. `fmtUsd` in particular has to distinguish "no runtime reported a price"
 * from "this was free" — rendering $0.00 for a run that genuinely cost money is
 * a straightforwardly false statement, and the person reading it has no way to
 * tell.
 */

// ── fmtUsd ──────────────────────────────────────────────────

test("fmtUsd: zero is 'not reported', not free", () => {
  /*
   * The load-bearing case. Most runtimes report nothing at all — their spend sits
   * inside a subscription — so zero means "unknown", and the caller renders
   * nothing rather than a number that would be a lie.
   */
  assert.equal(fmtUsd(0), null);
  assert.equal(fmtUsd(-1), null, "a negative figure is nonsense, not a credit");
});

test("fmtUsd: a sub-cent amount is shown as a bound, not rounded to zero", () => {
  // A single agent turn routinely costs well under a cent. "$0.00" would read as
  // free; "<$0.01" is honest about the magnitude.
  assert.equal(fmtUsd(0.0042), "<$0.01");
  assert.equal(fmtUsd(0.009), "<$0.01");
});

test("fmtUsd: normal amounts get two decimals", () => {
  assert.equal(fmtUsd(0.01), "$0.01");
  assert.equal(fmtUsd(1.5), "$1.50");
  assert.equal(fmtUsd(12.345), "$12.35");
});

test("fmtUsd: non-finite input yields null instead of '$NaN'", () => {
  // Reachable from a malformed API response; the UI must degrade, not print junk.
  assert.equal(fmtUsd(Number.NaN), null);
  assert.equal(fmtUsd(Number.POSITIVE_INFINITY), null);
});

// ── fmtTokens ───────────────────────────────────────────────

test("fmtTokens: scales by magnitude", () => {
  assert.equal(fmtTokens(0), "0");
  assert.equal(fmtTokens(999), "999");
  assert.equal(fmtTokens(1_000), "1.0k");
  assert.equal(fmtTokens(12_500), "12.5k");
  assert.equal(fmtTokens(999_999), "1000.0k");
  assert.equal(fmtTokens(1_000_000), "1.00M");
  assert.equal(fmtTokens(1_189_890), "1.19M");
});

test("fmtTokens: a real budget reads sensibly", () => {
  // The default ceiling is 2M and a real run spent ~560k; both must be legible
  // side by side in the header.
  assert.equal(fmtTokens(559_514), "559.5k");
  assert.equal(fmtTokens(2_000_000), "2.00M");
});

// ── fmtDuration ─────────────────────────────────────────────

test("fmtDuration: seconds, minutes, hours", () => {
  const start = "2026-07-31T12:00:00.000Z";
  assert.equal(fmtDuration(start, "2026-07-31T12:00:05.000Z"), "5s");
  assert.equal(fmtDuration(start, "2026-07-31T12:00:59.000Z"), "59s");
  assert.equal(fmtDuration(start, "2026-07-31T12:04:00.000Z"), "4m 0s");
  assert.equal(fmtDuration(start, "2026-07-31T12:07:12.000Z"), "7m 12s");
  assert.equal(fmtDuration(start, "2026-07-31T14:30:00.000Z"), "2h 30m");
});

test("fmtDuration: a null end means still running, measured to now", () => {
  const justNow = new Date(Date.now() - 3000).toISOString();
  const out = fmtDuration(justNow, null);
  // Elapsed time on a live run has to keep counting rather than showing a dash.
  assert.match(out, /^\ds$/, `expected a small seconds value, got ${out}`);
});

test("fmtDuration: a malformed timestamp degrades to a dash", () => {
  assert.equal(fmtDuration("not-a-date", null), "—");
  assert.equal(fmtDuration("2026-07-31T12:00:00.000Z", "garbage"), "—");
});

test("fmtDuration: a clock skew backwards clamps to zero", () => {
  // The engine and the browser can disagree; a negative duration would render as
  // "-3s" and look like a bug in the run rather than in the clock.
  assert.equal(fmtDuration("2026-07-31T12:00:10.000Z", "2026-07-31T12:00:00.000Z"), "0s");
});

// ── fmtRelative ─────────────────────────────────────────────

test("fmtRelative: recent times are described, not timestamped", () => {
  const ago = (ms: number): string => new Date(Date.now() - ms).toISOString();
  assert.equal(fmtRelative(ago(5_000)), "刚刚");
  assert.equal(fmtRelative(ago(5 * 60_000)), "5 分钟前");
  assert.equal(fmtRelative(ago(3 * 3_600_000)), "3 小时前");
  assert.equal(fmtRelative(ago(2 * 86_400_000)), "2 天前");
});

test("fmtRelative: a malformed timestamp degrades to a dash", () => {
  assert.equal(fmtRelative("nonsense"), "—");
  assert.equal(fmtRelative(""), "—");
});

test("fmtRelative: a future timestamp does not read as a past one", () => {
  // Clock skew again: "-2 分钟前" would be worse than treating it as just now.
  const future = new Date(Date.now() + 120_000).toISOString();
  assert.equal(fmtRelative(future), "刚刚");
});
