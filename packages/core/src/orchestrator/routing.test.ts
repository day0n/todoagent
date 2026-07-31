import assert from "node:assert/strict";
import { test } from "node:test";
import { pickReviewers, routeMaker, type RosterEntry } from "./pipeline.ts";
import type { Expert, ExpertRole, RuntimeKind } from "../types.ts";

/**
 * Routing decides who does the work and who checks it.
 *
 * The reviewer-selection tests matter most: one expert commonly holds several
 * roles, so a bug here produces SELF-REVIEW — which still renders as review in
 * the UI while quietly destroying the independent judgment that paying for
 * several vendors was meant to buy. That failure is invisible unless asserted.
 */

let seq = 0;
function expert(name: string, kind: RuntimeKind, capabilities: string[]): Expert {
  seq++;
  return {
    id: `e${seq}-${name}`,
    name,
    description: "",
    runtimeKind: kind,
    model: null,
    systemPrompt: "",
    capabilities,
    createdAt: new Date(0).toISOString(),
  };
}

function entry(e: Expert, role: ExpertRole): RosterEntry {
  return { role, expert: e };
}

// ── routeMaker ──────────────────────────────────────────────

test("routeMaker: exact capability match wins", () => {
  const iris = expert("Iris", "gemini", ["frontend-aesthetics", "css"]);
  const atlas = expert("Atlas", "claude", ["backend", "api"]);
  const roster = [entry(iris, "maker"), entry(atlas, "maker")];
  assert.equal(routeMaker(roster, "backend")?.name, "Atlas");
  assert.equal(routeMaker(roster, "frontend-aesthetics")?.name, "Iris");
});

test("routeMaker: matching is case- and whitespace-insensitive", () => {
  const atlas = expert("Atlas", "claude", ["Backend"]);
  const roster = [entry(atlas, "maker")];
  assert.equal(routeMaker(roster, "  BACKEND  ")?.name, "Atlas");
});

test("routeMaker: falls back to a shared word", () => {
  const iris = expert("Iris", "gemini", ["frontend-aesthetics"]);
  const atlas = expert("Atlas", "claude", ["backend"]);
  const roster = [entry(atlas, "maker"), entry(iris, "maker")];
  // The plan says "frontend"; Iris declared "frontend-aesthetics".
  assert.equal(routeMaker(roster, "frontend")?.name, "Iris");
});

test("routeMaker: a short tag does not match an unrelated word containing it", () => {
  const backend = expert("Gopher", "claude", ["go"]);
  const designer = expert("Iris", "gemini", ["logo-design"]);
  const roster = [entry(backend, "maker"), entry(designer, "maker")];
  /*
   * Regression guard. Substring matching sent "logo-design" work to the maker
   * declaring "go", because "logo-design".includes("go") is true. Short tags are
   * common — ux, go, ai, db, ci — so this mis-routed constantly and silently:
   * the wrong specialist simply did the work and nothing flagged it.
   */
  assert.equal(routeMaker(roster, "logo-design")?.name, "Iris");
  assert.equal(routeMaker(roster, "go")?.name, "Gopher");
});

test("routeMaker: an unknown capability still gets a maker", () => {
  const atlas = expert("Atlas", "claude", ["backend"]);
  const roster = [entry(atlas, "maker")];
  // Better a deterministic fallback than an unassigned subtask.
  assert.equal(routeMaker(roster, "quantum-holography")?.name, "Atlas");
  assert.equal(routeMaker(roster, "")?.name, "Atlas");
});

test("routeMaker: returns null when nobody holds the maker role", () => {
  const probe = expert("Probe", "codex", ["debugging"]);
  assert.equal(routeMaker([entry(probe, "reviewer")], "debugging"), null);
  assert.equal(routeMaker([], "anything"), null);
});

test("routeMaker: only makers are considered, even on an exact match", () => {
  const probe = expert("Probe", "codex", ["debugging"]);
  const atlas = expert("Atlas", "claude", ["backend"]);
  const roster = [entry(probe, "reviewer"), entry(atlas, "maker")];
  // Probe declares the exact tag but is not a maker — routing must not pull a
  // reviewer into authoring work.
  assert.equal(routeMaker(roster, "debugging")?.name, "Atlas");
});

test("routeMaker: is deterministic across calls", () => {
  const a = expert("A", "claude", ["general"]);
  const b = expert("B", "cursor", ["general"]);
  const roster = [entry(a, "maker"), entry(b, "maker")];
  const first = routeMaker(roster, "general")?.id;
  for (let i = 0; i < 5; i++) assert.equal(routeMaker(roster, "general")?.id, first);
});

// ── pickReviewers ───────────────────────────────────────────

test("pickReviewers: never includes the author", () => {
  const atlas = expert("Atlas", "claude", []);
  const probe = expert("Probe", "codex", []);
  // Atlas both writes and reviews — the common real configuration.
  const roster = [entry(atlas, "maker"), entry(atlas, "reviewer"), entry(probe, "reviewer")];
  const reviewers = pickReviewers(roster, atlas.id);
  assert.ok(
    reviewers.every((r) => r.id !== atlas.id),
    "an agent must not review its own output",
  );
  assert.deepEqual(reviewers.map((r) => r.name), ["Probe"]);
});

test("pickReviewers: deduplicates an expert holding several roles", () => {
  const atlas = expert("Atlas", "claude", []);
  const probe = expert("Probe", "codex", []);
  const roster = [
    entry(atlas, "maker"),
    entry(probe, "reviewer"),
    entry(probe, "verifier"),
    entry(probe, "orchestrator"),
  ];
  const reviewers = pickReviewers(roster, atlas.id);
  // Otherwise Probe reviews three times, tripling cost while adding no new
  // perspective — and three identical verdicts read as consensus.
  assert.equal(reviewers.length, 1);
  assert.equal(reviewers[0]?.name, "Probe");
});

test("pickReviewers: caps the panel at two", () => {
  const author = expert("Author", "claude", []);
  const roster: RosterEntry[] = [entry(author, "maker")];
  for (let i = 0; i < 6; i++) {
    roster.push(entry(expert(`R${i}`, "codex", []), "reviewer"));
  }
  const reviewers = pickReviewers(roster, author.id);
  // Every extra reviewer is a full agent turn; two independent opinions is the
  // deliberate cost/benefit point.
  assert.equal(reviewers.length, 2);
});

test("pickReviewers: prefers explicit reviewers over other roles", () => {
  const author = expert("Author", "claude", []);
  const warden = expert("Warden", "kiro", []);
  const iris = expert("Iris", "gemini", []);
  const roster = [
    entry(author, "maker"),
    entry(iris, "maker"),
    entry(warden, "reviewer"),
  ];
  const reviewers = pickReviewers(roster, author.id);
  assert.equal(reviewers[0]?.name, "Warden", "the declared reviewer comes first");
  // A second maker is still usable as a reviewer rather than leaving the panel
  // short — some review beats none.
  assert.equal(reviewers.length, 2);
  assert.ok(reviewers.some((r) => r.name === "Iris"));
});

test("pickReviewers: falls back to non-reviewer roles when needed", () => {
  const author = expert("Author", "claude", []);
  const probe = expert("Probe", "codex", []);
  const roster = [entry(author, "maker"), entry(probe, "verifier")];
  const reviewers = pickReviewers(roster, author.id);
  assert.deepEqual(reviewers.map((r) => r.name), ["Probe"]);
});

test("pickReviewers: returns empty when the author is the only expert", () => {
  const solo = expert("Solo", "claude", []);
  const roster = [entry(solo, "maker"), entry(solo, "reviewer"), entry(solo, "verifier")];
  const reviewers = pickReviewers(roster, solo.id);
  /*
   * Empty, NOT self-review. A single-runtime setup genuinely cannot cross-review,
   * and the pipeline logs `review:skipped` for it. Silently letting the author
   * review itself would manufacture the appearance of independent scrutiny.
   */
  assert.deepEqual(reviewers, []);
});

test("pickReviewers: an empty roster yields no reviewers", () => {
  assert.deepEqual(pickReviewers([], "anyone"), []);
});

test("pickReviewers: an unknown author id does not exclude anyone", () => {
  const a = expert("A", "claude", []);
  const b = expert("B", "codex", []);
  const roster = [entry(a, "reviewer"), entry(b, "reviewer")];
  assert.equal(pickReviewers(roster, "not-in-roster").length, 2);
});

test("pickReviewers: prefers cross-vendor reviewers in a realistic roster", () => {
  // The seeded default: claude authors, codex and kiro review.
  const atlas = expert("Atlas", "claude", ["backend"]);
  const probe = expert("Probe", "codex", ["debugging"]);
  const warden = expert("Warden", "kiro", ["architecture"]);
  const roster = [
    entry(atlas, "orchestrator"),
    entry(atlas, "maker"),
    entry(probe, "reviewer"),
    entry(probe, "verifier"),
    entry(warden, "reviewer"),
  ];
  const reviewers = pickReviewers(roster, atlas.id);
  assert.equal(reviewers.length, 2);
  const kinds = new Set(reviewers.map((r) => r.runtimeKind));
  assert.equal(kinds.size, 2, "two different vendors, so the perspectives are independent");
  assert.ok(!kinds.has("claude"), "the author's vendor is excluded");
});
