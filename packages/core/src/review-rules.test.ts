import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isBlocking,
  needsHumanJudgment,
  needsReproduction,
  type ReproOutcome,
  type ReviewSeverity,
} from "./review-rules.ts";

/**
 * These three predicates ARE the design.
 *
 * They decide what stops delivery, what gets settled by experiment, and what is
 * worth a person's attention. Everything else in the pipeline is plumbing around
 * them, so each rule is pinned here — including the combinations that look
 * redundant, because those are exactly the ones a future edit would "simplify"
 * back into a bug.
 */

const SEVERITIES: ReviewSeverity[] = ["blocker", "major", "nit"];
const OUTCOMES: ReproOutcome[] = [null, "confirmed", "refuted", "inconclusive"];

// ── isBlocking ──────────────────────────────────────────────

test("isBlocking: a nit never blocks, whatever the reproduction said", () => {
  for (const reproOutcome of OUTCOMES) {
    assert.equal(
      isBlocking({ severity: "nit", reproOutcome }),
      false,
      `nit with reproOutcome=${String(reproOutcome)}`,
    );
  }
});

test("isBlocking: a refuted claim never blocks, whatever its severity", () => {
  for (const severity of SEVERITIES) {
    /*
     * The payoff of the verifiable/unverifiable split. Once a checkable claim has
     * been tested and did NOT hold, the matter is settled — arguing further is
     * the waste this pipeline exists to avoid. Before this was enforced, a
     * disproven finding still cost a rebuttal turn, an adjudication turn, and
     * potentially a full rework round.
     */
    assert.equal(
      isBlocking({ severity, reproOutcome: "refuted" }),
      false,
      `${severity} refuted by test`,
    );
  }
});

test("isBlocking: an untested blocker or major does block", () => {
  assert.equal(isBlocking({ severity: "blocker", reproOutcome: null }), true);
  assert.equal(isBlocking({ severity: "major", reproOutcome: null }), true);
});

test("isBlocking: a confirmed failure blocks", () => {
  // Reproduced means the defect is real and demonstrated.
  assert.equal(isBlocking({ severity: "blocker", reproOutcome: "confirmed" }), true);
  assert.equal(isBlocking({ severity: "major", reproOutcome: "confirmed" }), true);
});

test("isBlocking: an inconclusive reproduction still blocks", () => {
  /*
   * "We could not tell" is not evidence of absence. Treating inconclusive like
   * refuted would let a real defect through whenever the verifier failed to set
   * up a fair test — which is the failure mode most likely to be silent.
   */
  assert.equal(isBlocking({ severity: "blocker", reproOutcome: "inconclusive" }), true);
  assert.equal(isBlocking({ severity: "major", reproOutcome: "inconclusive" }), true);
});

// ── needsReproduction ───────────────────────────────────────

test("needsReproduction: only for a checkable, consequential, untested claim", () => {
  assert.equal(
    needsReproduction({ severity: "blocker", verifiable: true, reproOutcome: null }),
    true,
  );
  assert.equal(
    needsReproduction({ severity: "major", verifiable: true, reproOutcome: null }),
    true,
  );
});

test("needsReproduction: never for an unverifiable claim", () => {
  // No test can arbitrate taste; sending it down the repro path burns a turn to
  // learn nothing.
  for (const severity of SEVERITIES) {
    assert.equal(
      needsReproduction({ severity, verifiable: false, reproOutcome: null }),
      false,
      severity,
    );
  }
});

test("needsReproduction: never for a nit", () => {
  // A full agent turn to reproduce a naming preference is not worth it.
  assert.equal(needsReproduction({ severity: "nit", verifiable: true, reproOutcome: null }), false);
});

test("needsReproduction: not repeated once an outcome exists", () => {
  for (const reproOutcome of ["confirmed", "refuted", "inconclusive"] as const) {
    assert.equal(
      needsReproduction({ severity: "blocker", verifiable: true, reproOutcome }),
      false,
      `already ${reproOutcome}`,
    );
  }
});

// ── needsHumanJudgment ──────────────────────────────────────

test("needsHumanJudgment: an unverifiable blocking finding reaches a human", () => {
  // Taste, tradeoffs, and priorities are what a person is for.
  assert.equal(
    needsHumanJudgment({ severity: "blocker", verifiable: false, reproOutcome: null }),
    true,
  );
  assert.equal(
    needsHumanJudgment({ severity: "major", verifiable: false, reproOutcome: null }),
    true,
  );
});

test("needsHumanJudgment: an inconclusive test reaches a human", () => {
  assert.equal(
    needsHumanJudgment({ severity: "major", verifiable: true, reproOutcome: "inconclusive" }),
    true,
  );
});

test("needsHumanJudgment: a decided claim does NOT reach a human", () => {
  /*
   * The rule the whole discussion design rests on: a dispute a test could settle
   * is settled by a test, never escalated. Confirmed means fix it; refuted means
   * drop it. Neither needs a person.
   */
  assert.equal(
    needsHumanJudgment({ severity: "blocker", verifiable: true, reproOutcome: "confirmed" }),
    false,
  );
  assert.equal(
    needsHumanJudgment({ severity: "blocker", verifiable: true, reproOutcome: "refuted" }),
    false,
  );
});

test("needsHumanJudgment: an untested verifiable claim does not reach a human", () => {
  // It should be reproduced first. Escalating here would hand over a question a
  // machine could have answered.
  assert.equal(
    needsHumanJudgment({ severity: "blocker", verifiable: true, reproOutcome: null }),
    false,
  );
});

test("needsHumanJudgment: a nit never reaches a human", () => {
  for (const verifiable of [true, false]) {
    assert.equal(
      needsHumanJudgment({ severity: "nit", verifiable, reproOutcome: null }),
      false,
      `nit verifiable=${verifiable}`,
    );
  }
});

// ── Cross-rule invariants ───────────────────────────────────

test("nothing that fails isBlocking can need human judgment", () => {
  // A finding that does not hold up the work must never consume attention.
  for (const severity of SEVERITIES) {
    for (const reproOutcome of OUTCOMES) {
      for (const verifiable of [true, false]) {
        const review = { severity, reproOutcome, verifiable };
        if (needsHumanJudgment(review)) {
          assert.equal(isBlocking(review), true, JSON.stringify(review));
        }
      }
    }
  }
});

test("reproduction and human judgment are mutually exclusive", () => {
  /*
   * The core split, stated as an invariant: every finding is settled by
   * EXPERIMENT or by a PERSON, never queued for both. Overlap would mean paying
   * for a reproduction and then escalating the same question anyway.
   */
  for (const severity of SEVERITIES) {
    for (const reproOutcome of OUTCOMES) {
      for (const verifiable of [true, false]) {
        const review = { severity, reproOutcome, verifiable };
        assert.ok(
          !(needsReproduction(review) && needsHumanJudgment(review)),
          `both paths claimed ${JSON.stringify(review)}`,
        );
      }
    }
  }
});

test("every blocking finding has a route out", () => {
  // A blocker that neither gets reproduced nor escalated would stall silently.
  for (const severity of ["blocker", "major"] as const) {
    for (const verifiable of [true, false]) {
      for (const reproOutcome of OUTCOMES) {
        const review = { severity, reproOutcome, verifiable };
        if (!isBlocking(review)) continue;
        const routed =
          needsReproduction(review) ||
          needsHumanJudgment(review) ||
          // Confirmed: the author is asked to fix it in the rework round.
          reproOutcome === "confirmed";
        assert.ok(routed, `no route for ${JSON.stringify(review)}`);
      }
    }
  }
});
