/**
 * Pure review-triage rules, shared by the orchestrator and the UI.
 *
 * Deliberately a LEAF module with no imports at all — not even type imports from
 * `types.ts`. The web app bundles this for the browser, and anything reachable
 * from `packages/core/src/index.ts` pulls in `node:sqlite`, `node:child_process`
 * and git plumbing. Parameters are therefore structural rather than named types.
 *
 * These predicates were duplicated: once in the pipeline, once inline in the run
 * page. They encode the design's central rule, so two copies meant the UI could
 * disagree with the engine about what is blocking — and the copy that drifts is
 * invisible until someone notices the numbers do not match.
 */

export type ReviewSeverity = "blocker" | "major" | "nit";
export type ReproOutcome = "confirmed" | "refuted" | "inconclusive" | null;

export interface TriageInput {
  severity: ReviewSeverity;
  reproOutcome: ReproOutcome;
}

/**
 * Does this finding hold up the work?
 *
 * Two independent reasons it does not:
 *
 *  - It is a `nit`. Local preferences do not gate delivery.
 *  - Its reproduction PASSED. This is the payoff of the whole
 *    verifiable/unverifiable split: once a checkable claim has been tested and
 *    did not hold, the matter is settled, and arguing further is exactly the
 *    waste this pipeline exists to avoid. Before this was enforced, a disproven
 *    finding still cost a rebuttal turn, an adjudication turn, and potentially a
 *    full rework round — while a `repro:dismissed` event claimed it had been
 *    dropped and nothing actually had.
 *
 * A finding whose reproduction was INCONCLUSIVE still blocks: "we could not
 * tell" is not evidence of absence, and it routes to discussion instead.
 *
 * Refuted evidence stays on the record either way; only its power to hold up the
 * work is removed.
 */
export function isBlocking(review: TriageInput): boolean {
  if (review.severity === "nit") return false;
  if (review.reproOutcome === "refuted") return false;
  return true;
}

/**
 * Should this finding be settled by running something, rather than argued?
 *
 * `verifiable` is the reviewer's own claim that a test could decide the matter,
 * and nits are excluded because spending a full agent turn reproducing a naming
 * preference is not worth it.
 */
export function needsReproduction(review: TriageInput & { verifiable: boolean }): boolean {
  return review.verifiable && review.severity !== "nit" && review.reproOutcome === null;
}

/**
 * Is this a dispute only a human can settle?
 *
 * Either the reviewer said no test could decide it, or a test was attempted and
 * could not tell. Everything else has evidence and should be decided on that
 * evidence instead of consuming a person's attention.
 */
export function needsHumanJudgment(review: TriageInput & { verifiable: boolean }): boolean {
  if (!isBlocking(review)) return false;
  return !review.verifiable || review.reproOutcome === "inconclusive";
}
