import type { DiscussionMessage, Expert, ExpertRole, Rebuttal, Review, Run, SubTask } from "../types.ts";

/**
 * Every prompt here states the output contract inline. Unlike Multica, which
 * hands agents a CLI and a skill file and lets the model decide what to do next,
 * these prompts ask for exactly one artifact — because the control flow lives in
 * pipeline.ts, not in the model's judgment.
 */

const JSON_ONLY = [
  "Respond with ONLY a single JSON object.",
  "No markdown fences. No commentary before or after the object.",
].join(" ");

export function rosterBlock(roster: Array<{ role: ExpertRole; expert: Expert }>): string {
  const lines = roster.map(({ role, expert }) => {
    const caps = expert.capabilities.length > 0 ? expert.capabilities.join(", ") : "none declared";
    return `- ${expert.name} — role: ${role}; runtime: ${expert.runtimeKind}; capabilities: ${caps}${
      expert.description ? `; ${expert.description}` : ""
    }`;
  });
  return lines.join("\n");
}

export function planPrompt(args: {
  run: Run;
  roster: Array<{ role: ExpertRole; expert: Expert }>;
  repoPath: string;
}): string {
  const capabilities = [
    ...new Set(args.roster.flatMap(({ expert }) => expert.capabilities)),
  ].sort();
  return `You are the orchestrator of a small team of specialist coding agents.

GOAL
${args.run.goal}
${args.run.acceptance ? `\nACCEPTANCE CRITERIA\n${args.run.acceptance}` : ""}

REPOSITORY
${args.repoPath}

TEAM ROSTER
${rosterBlock(args.roster)}

AVAILABLE CAPABILITY TAGS
${capabilities.length > 0 ? capabilities.join(", ") : "(none declared — use descriptive tags)"}

YOUR TASK
Read the repository as needed, then decompose the goal into subtasks.

Rules:
1. Each subtask must be independently executable in its OWN copy of the
   repository. Two subtasks in the same stage MUST NOT need to edit the same
   file — they run in parallel in isolated worktrees and would conflict.
2. Use \`stage\` to express ordering. Everything in stage 0 starts at once;
   stage 1 begins only after every stage-0 subtask finishes. Put work that
   depends on earlier output in a later stage.
3. Prefer FEWER subtasks. Two well-scoped subtasks beat six trivial ones —
   every subtask costs a full agent run plus reviews.
4. \`capability\` should match a tag above when one fits, so the work routes to
   the specialist best suited to it.
5. \`acceptance\` must be concrete enough that a reviewer can check it without
   asking you what you meant.
6. If the goal is small enough for one agent, return exactly one subtask.

${JSON_ONLY}

Schema:
{
  "summary": "one sentence on the approach",
  "subtasks": [
    {
      "id": "kebab-case-id",
      "title": "short title",
      "brief": "what to do, with enough detail to act without further questions",
      "acceptance": "how a reviewer verifies this is done",
      "capability": "capability tag",
      "stage": 0,
      "dependsOn": []
    }
  ]
}`;
}

/** What came back from the previous round, for a rework turn. */
export interface ReworkContext {
  round: number;
  reviews: Review[];
  rebuttals: Rebuttal[];
  /** The adjudicator's stated reason for sending this back. */
  rationale: string | null;
  /**
   * A human's ruling on a dispute no test could settle.
   *
   * Carried because this is the ONE input the agents cannot derive themselves —
   * it is the whole reason the run stopped and asked. Recording it without
   * delivering it would make the escalation pointless.
   */
  humanDecision: string | null;
  nameOf: (expertId: string) => string;
}

/**
 * Builds the rework brief.
 *
 * Load-bearing, and it did not exist: a rework round used to re-send the ORIGINAL
 * draft prompt verbatim. The agent was told to do the same task again, in a fresh
 * session, with no idea what any reviewer had said — a full agent turn bought for
 * zero new information. The round counter and the `rework` verdict made the
 * mechanism look functional while it accomplished nothing.
 */
function reworkBlock(rework: ReworkContext): string {
  const byId = new Map(rework.rebuttals.map((r) => [r.reviewId, r]));
  const items = rework.reviews
    .map((r) => {
      const own = byId.get(r.id);
      const lines = [
        `- (${r.severity}${r.verifiable ? ", verifiable" : ", judgment call"}) ${r.claim}`,
        `  evidence: ${r.evidence || "(none given)"}`,
      ];
      if (r.reproOutcome !== null) {
        lines.push(
          `  reproduction: ${r.reproOutcome.toUpperCase()}${
            r.reproOutcome === "confirmed"
              ? " — this was reproduced against your code, so it is real"
              : ""
          }`,
        );
      }
      if (r.suggestedTest !== null) lines.push(`  suggested test: ${r.suggestedTest}`);
      if (r.patch !== null) lines.push(`  suggested change: ${r.patch}`);
      if (own) {
        lines.push(`  YOUR previous response: ${own.decision} — ${own.reason}`);
      }
      return lines.join("\n");
    })
    .join("\n");

  return `

=== THIS IS A REWORK (round ${rework.round}) ===

Your previous attempt is already in this worktree — read it before changing
anything. Do NOT start over; fix what the findings below identify.

FINDINGS THAT ARE STILL OPEN
${items || "(none recorded)"}
${rework.rationale ? `\nWHY THIS CAME BACK\n${rework.rationale}\n` : ""}${
    rework.humanDecision
      ? `
A HUMAN HAS RULED ON THIS
${rework.humanDecision}

This is the one input you cannot derive yourself — the run stopped and asked a
person precisely because no test could settle it. Follow the ruling even if you
argued the other way earlier, and do not re-litigate it.
`
      : ""
  }
Rules for this round:
- A finding you previously ACCEPTED must actually be fixed now. Agreeing and then
  not acting on it is the worst possible outcome — it costs a round and changes
  nothing.
- A finding you previously REJECTED and still believe is wrong: leave the code as
  it is and say so plainly in your summary. Do not silently cave to make the
  review pass; if you were right, the reviewer needs to hear the argument again.
- A REPRODUCED failure is demonstrated, not alleged. Fix it, or explain concretely
  why the reproduction does not reflect real usage.
- Do not fix things nobody raised. Scope creep here restarts the review cycle.
`;
}

export function draftPrompt(args: {
  run: Run;
  subTask: SubTask;
  expert: Expert;
  rework?: ReworkContext;
}): string {
  return `${args.expert.systemPrompt ? `${args.expert.systemPrompt}\n\n---\n\n` : ""}You are working as part of a team on one subtask. You are in a dedicated git
worktree — the whole repository is yours to edit, and your changes will be
reviewed and merged separately.

OVERALL GOAL (context only — do NOT attempt the whole thing)
${args.run.goal}

YOUR SUBTASK: ${args.subTask.title}
${args.subTask.brief}

ACCEPTANCE CRITERIA
${args.subTask.acceptance}

Rules:
- Do the work. Edit files, run commands, verify your change compiles or runs.
- Stay inside your subtask's scope. Another agent owns the rest.
- Do NOT commit; the orchestrator handles commits.
- When you finish, summarise what you changed and how you verified it. Be
  concrete: name the files and the command you ran.${args.rework ? reworkBlock(args.rework) : ""}`;
}

export function reviewPrompt(args: {
  run: Run;
  subTask: SubTask;
  diff: string;
  authorName: string;
  reviewer: Expert;
}): string {
  const diff = args.diff.trim().length > 0 ? args.diff.slice(0, 60000) : "(no textual diff produced)";
  return `${args.reviewer.systemPrompt ? `${args.reviewer.systemPrompt}\n\n---\n\n` : ""}You are reviewing another agent's work. Be specific and adversarial: your job
is to find real problems, not to be agreeable.

OVERALL GOAL
${args.run.goal}

SUBTASK REVIEWED: ${args.subTask.title}
${args.subTask.brief}

ACCEPTANCE CRITERIA
${args.subTask.acceptance}

AUTHOR
${args.authorName}

DIFF
\`\`\`diff
${diff}
\`\`\`

THE ONE RULE THAT MATTERS
For every finding, decide whether it is VERIFIABLE — that is, whether a test,
a command, or a reproduction could settle it objectively.

- "this crashes when input is empty", "this races", "this leaks a handle",
  "this query is O(n^2)" → verifiable: true. Supply \`suggestedTest\`: a
  concrete test or command that would FAIL if you are right. Your claim will
  be checked by actually running it, so do not assert what you cannot reproduce.
- "this naming is confusing", "this hierarchy reads badly", "this spacing is
  wrong", "this API shape will age poorly" → verifiable: false. These are
  judgment calls; state the tradeoff plainly.

SEVERITY, FOR JUDGMENT CALLS SPECIFICALLY
A judgment call is not automatically a nit. Rate it by how expensive it is to
reverse later, not by how objective it feels:
- \`major\` — a choice that will be hard to undo once code depends on it: the
  shape or naming of an exported API, a data model, an error-handling contract,
  a structure other modules will mirror.
- \`nit\` — a local preference with no downstream consequence: an internal
  variable name, the ordering of independent statements, a comment's wording.
Only findings at \`major\` or above are discussed and adjudicated; anything you
mark \`nit\` is recorded and then ignored. Under-rating a consequential design
disagreement as a nit is how it silently ships.

Do not report style or formatting nits that an autoformatter handles.
Do not report anything outside this diff.
If the work is genuinely fine, return an empty findings array — inventing
findings to look thorough wastes everyone's budget.

${JSON_ONLY}

Schema:
{
  "overall": "approve" | "request_changes",
  "findings": [
    {
      "severity": "blocker" | "major" | "nit",
      "claim": "one sentence stating the defect",
      "evidence": "file:line plus why it fails",
      "verifiable": true,
      "suggestedTest": "a command or test that fails if the claim is true, else null",
      "patch": "a concrete replacement snippet, or null"
    }
  ]
}`;
}

export function reproPrompt(args: { subTask: SubTask; review: Review; worktreePath: string }): string {
  return `A reviewer made a claim about this code that they say is objectively
checkable. Settle it by experiment, not opinion.

CLAIM
${args.review.claim}

STATED EVIDENCE
${args.review.evidence || "(none given)"}

SUGGESTED TEST
${args.review.suggestedTest ?? "(none given — design a minimal one yourself)"}

YOUR TASK
1. Write the smallest test or script that would FAIL if the claim is true.
2. Run it against the current code in ${args.worktreePath}.
3. Report what actually happened.

Rules:
- Do not fix the underlying problem. You are measuring, not repairing.
- "confirmed" means you observed the failure. Paste the actual output.
- "refuted" means the test ran and passed, so the claim does not hold here.
- "inconclusive" means you could not set up a fair test — say why. Do not use
  this to avoid committing to an answer.

${JSON_ONLY}

Schema:
{ "outcome": "confirmed" | "refuted" | "inconclusive", "evidence": "what you ran and what it printed" }`;
}

export function rebuttalPrompt(args: {
  subTask: SubTask;
  reviews: Review[];
  author: Expert;
}): string {
  const items = args.reviews
    .map((r) => {
      const repro =
        r.reproOutcome === null
          ? ""
          : `\n  reproduction: ${r.reproOutcome.toUpperCase()}${
              r.reproOutcome === "confirmed"
                ? " — this was reproduced against your code, so accepting it is usually correct."
                : r.reproOutcome === "refuted"
                  ? " — the test passed, so the claim did not hold. Rejecting it is reasonable."
                  : ""
            }`;
      return `- [${r.id}] (${r.severity}${r.verifiable ? ", verifiable" : ", judgment"}) ${r.claim}\n  evidence: ${r.evidence || "(none)"}${repro}`;
    })
    .join("\n");

  return `${args.author.systemPrompt ? `${args.author.systemPrompt}\n\n---\n\n` : ""}Reviewers raised the findings below about YOUR work on "${args.subTask.title}".
Respond to each one. This is your only chance to push back.

FINDINGS
${items}

Rules:
- Where a finding was REPRODUCED, accepting it is usually right. Rejecting a
  reproduced failure requires you to explain why the reproduction is invalid.
- Where a finding was REFUTED by test, you may reject it and cite that.
- Disagreeing is legitimate. Conceding a point you believe is wrong just to
  seem cooperative is worse than arguing — the whole point of separate
  reviewers is independent judgment.
- Keep each reason to one or two sentences.
- Respond to every reviewId listed, and invent none.

${JSON_ONLY}

Schema:
{ "responses": [ { "reviewId": "...", "decision": "accept" | "reject", "reason": "..." } ] }`;
}

export function adjudicatePrompt(args: {
  run: Run;
  subTask: SubTask;
  reviews: Review[];
  rebuttals: Rebuttal[];
  /**
   * Turns from the bounded discussion, when one happened.
   *
   * Load-bearing: the discussion exists to inform this verdict. It used to be
   * omitted here, so specialists debated a judgment call and the orchestrator
   * decided without ever seeing what they concluded — the tokens bought nothing.
   */
  discussion: DiscussionMessage[];
  nameOf: (expertId: string) => string;
  round: number;
  maxRounds: number;
}): string {
  const byId = new Map(args.rebuttals.map((r) => [r.reviewId, r]));
  const items = args.reviews
    .map((r) => {
      const reb = byId.get(r.id);
      return [
        `- [${r.id}] (${r.severity}${r.verifiable ? ", verifiable" : ", judgment"}) ${r.claim}`,
        `  evidence: ${r.evidence || "(none)"}`,
        `  reproduction: ${r.reproOutcome ?? "not tested"}`,
        `  author response: ${reb ? `${reb.decision} — ${reb.reason}` : "(no response)"}`,
      ].join("\n");
    })
    .join("\n");

  const transcript =
    args.discussion.length === 0
      ? ""
      : `\nTEAM DISCUSSION (on the points no test could settle)\n${args.discussion
          .map((m) => `${args.nameOf(m.authorExpertId)} (round ${m.round}): ${m.body}`)
          .join("\n\n")}\n`;

  return `You are the orchestrator, deciding whether one subtask is finished.

OVERALL GOAL
${args.run.goal}

SUBTASK: ${args.subTask.title}
ACCEPTANCE: ${args.subTask.acceptance}

ROUND ${args.round} of ${args.maxRounds} (no further rounds after the last)

FINDINGS AND RESPONSES
${items || "(no findings were raised)"}
${transcript}
DECIDE
- "proceed": nothing outstanding blocks acceptance. Unresolved nits do not block.
- "rework": at least one blocker or major finding stands, and another attempt
  can plausibly fix it. Do not choose this on the final round.
- "escalate": a genuine disagreement remains that no test can settle — the
  reviewer and author disagree on a judgment call. Escalate ONLY these.

Critical: do NOT escalate anything a test could have decided. A verifiable
finding that was never reproduced should be reworked or dismissed on the
evidence, not handed to a human. Humans are for taste, tradeoffs, and priorities.

${JSON_ONLY}

Schema:
{
  "verdict": "proceed" | "rework" | "escalate",
  "rationale": "two or three sentences",
  "escalations": [ { "reviewId": "...", "question": "the specific question for the human" } ]
}`;
}

export function discussPrompt(args: {
  run: Run;
  subTask: SubTask;
  speaker: Expert;
  reviews: Review[];
  history: DiscussionMessage[];
  nameOf: (expertId: string) => string;
  round: number;
  maxRounds: number;
}): string {
  const open = args.reviews
    .filter((r) => r.severity !== "nit")
    .map(
      (r) =>
        `- [${r.id}] (${r.severity}${r.verifiable ? ", verifiable" : ", judgment"}) ${r.claim} — reproduction: ${r.reproOutcome ?? "not tested"}`,
    )
    .join("\n");

  const transcript =
    args.history.length === 0
      ? "(you are speaking first)"
      : args.history
          .map((m) => `${args.nameOf(m.authorExpertId)}: ${m.body}`)
          .join("\n\n");

  return `${args.speaker.systemPrompt ? `${args.speaker.systemPrompt}\n\n---\n\n` : ""}You are in a short, bounded working discussion with the other specialists on
this team about one unresolved point. This is round ${args.round} of at most ${args.maxRounds}.

OVERALL GOAL
${args.run.goal}

SUBTASK: ${args.subTask.title}
ACCEPTANCE: ${args.subTask.acceptance}

OPEN POINTS
${open || "(none — say so and stop)"}

DISCUSSION SO FAR
${transcript}

Rules for your turn:
- Say something NEW. Restating agreement adds nothing and burns budget.
- If you think a previous speaker is wrong, say so and why. Converging on
  whoever spoke first is the failure mode this process exists to prevent.
- If a point is testable, say what test would settle it rather than arguing.
- If you have nothing to add, reply with exactly: NOTHING TO ADD
- Four sentences maximum. Plain prose, no JSON, no headings.`;
}

export function verifyPrompt(args: { run: Run; repoPath: string; mergedSummary: string }): string {
  return `All subtask work for this goal has been merged. Verify the result.

GOAL
${args.run.goal}
${args.run.acceptance ? `\nACCEPTANCE CRITERIA\n${args.run.acceptance}` : ""}

REPOSITORY
${args.repoPath}

WHAT WAS MERGED
${args.mergedSummary}

YOUR TASK
1. Discover how this project builds and tests itself — read package.json,
   Makefile, Cargo.toml, or whatever is present. Do not guess commands.
2. Run the build, then the tests, then the linter if one exists.
3. Report exactly what you ran and what happened.

Rules:
- Report failures plainly, with the real output. A verification that hides a
  failing test is worse than no verification.
- If no build or test setup exists, say that instead of inventing a result.
- Do not fix anything. You are the last honest measurement in this pipeline.`;
}

export function soloPrompt(args: { run: Run; expert: Expert; repoPath: string }): string {
  return `${args.expert.systemPrompt ? `${args.expert.systemPrompt}\n\n---\n\n` : ""}Complete this task directly. It was judged small enough not to need a team.

GOAL
${args.run.goal}
${args.run.acceptance ? `\nACCEPTANCE CRITERIA\n${args.run.acceptance}` : ""}

REPOSITORY
${args.repoPath}

Do the work, verify it, and summarise what you changed and how you checked it.`;
}
