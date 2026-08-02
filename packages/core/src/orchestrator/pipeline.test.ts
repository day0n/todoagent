import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { Store } from "../db/index.ts";
import { approvePlanAndContinue, resolveEscalationAndContinue, runPipeline } from "./pipeline.ts";
import { git } from "../util/git.ts";

/**
 * Full-pipeline integration test driven by FAKE agent CLIs.
 *
 * The fakes are put on PATH ahead of the real binaries, so the adapters spawn
 * them through the ordinary code path — real prompts, real stream-json parsing,
 * real worktrees, real git, real database. Only the model is substituted.
 *
 * This exists because the collaboration phases were unverifiable otherwise.
 * Three real multi-agent runs produced ZERO discussion turns: reaching that code
 * requires a reviewer to independently rate a judgment call as `major`, which is
 * a matter of model whim. A scripted reviewer makes the mechanism itself
 * testable — rounds, convergence, and the routing between reproduction and human
 * judgment — in seconds and without spending tokens.
 */

/** The review a fake reviewer returns, per scenario. */
function reviewFor(behaviour: string): unknown {
  switch (behaviour) {
    case "clean":
      return { overall: "approve", findings: [] };
    case "nit-only":
      return {
        overall: "approve",
        findings: [
          {
            severity: "nit",
            claim: "naming could be clearer",
            evidence: "",
            verifiable: false,
            suggestedTest: null,
            patch: null,
          },
        ],
      };
    case "refuted":
    case "confirmed":
    case "inconclusive":
      // A checkable claim, so the pipeline must route it to reproduction.
      return {
        overall: "request_changes",
        findings: [
          {
            severity: "blocker",
            claim: "this crashes on empty input",
            evidence: "note.txt:1",
            verifiable: true,
            suggestedTest: "node --test",
            patch: null,
          },
        ],
      };
    default:
      // Unverifiable AND major: the only combination that reaches discussion.
      return {
        overall: "request_changes",
        findings: [
          {
            severity: "major",
            claim: "this API shape will age badly",
            evidence: "note.txt:1",
            verifiable: false,
            suggestedTest: null,
            patch: null,
          },
        ],
      };
  }
}

/**
 * The fake CLI, written in Node rather than shell.
 *
 * The first attempt used a `/bin/sh` script, and the JSON it had to emit needed
 * three levels of quoting — shell single-quotes, the JSON envelope, and the
 * JSON-encoded string inside `result`. The escaping was wrong and every review
 * came back unparseable; worse, the "clean review" case still PASSED because a
 * failed parse and an empty findings list are indistinguishable from outside.
 * Building the payload with JSON.stringify removes the entire hazard class.
 */
function fakeAgentScript(
  behaviour: string,
  format: "claude" | "codex",
  artifactDir: string,
): string {
  /**
   * The doomed subtask's title, used to fail one draft and not the other.
   *
   * Targeted by TITLE because the draft prompt carries `YOUR SUBTASK: <title>`,
   * which is the only thing distinguishing two concurrent draft invocations of the
   * same fake binary.
   */
  const DOOMED = "Add the doomed file";

  const plan = {
    summary: "one step",
    subtasks: [
      {
        id: "a",
        title: "Add the file",
        brief: "create note.txt",
        acceptance: "note.txt exists",
        capability: "general",
        stage: 0,
        dependsOn: [],
      },
      // A second subtask exists only for the partial-failure scenario: one
      // survivor plus one casualty is what distinguishes "partial" from "total".
      ...(behaviour === "partial-failure"
        ? [
            {
              id: "b",
              title: DOOMED,
              brief: "this one's agent will fail",
              acceptance: "never met",
              capability: "general",
              stage: 0,
              dependsOn: [],
            },
          ]
        : []),
    ],
  };
  const repro = {
    outcome:
      behaviour === "confirmed"
        ? "confirmed"
        : behaviour === "inconclusive"
          ? "inconclusive"
          : "refuted",
    evidence: "ran the test",
  };
  const discussionTurn =
    behaviour === "silent-discussion"
      ? "NOTHING TO ADD"
      : "I think the flat shape is easier to extend later.";

  const config = {
    plan: JSON.stringify(plan),
    /**
     * Which subtask's draft should die, or "" for none.
     *
     * `partial-failure` kills the second of two, leaving one survivor whose work
     * still merges. `total-failure` kills the only one, so nothing merges — the
     * two cases have to report differently, and that distinction is the point.
     */
    doomed:
      behaviour === "partial-failure"
        ? DOOMED
        : behaviour === "total-failure"
          ? "Add the file"
          : "",
    review: JSON.stringify(reviewFor(behaviour)),
    rebuttal: JSON.stringify({
      responses: [{ reviewId: "IGNORED", decision: "reject", reason: "I disagree" }],
    }),
    repro: JSON.stringify(repro),
    adjudication: JSON.stringify({
      verdict: "proceed",
      rationale: "nothing outstanding",
      escalations: [],
    }),
    // Used only by the "rework" scenario, on the FIRST adjudication.
    adjudicationRework: JSON.stringify({
      verdict: "rework",
      rationale: "the blocker stands and another attempt can fix it",
      escalations: [],
    }),
    // Used only by the "escalate" scenario, on the FIRST adjudication.
    adjudicationEscalate: JSON.stringify({
      verdict: "escalate",
      rationale: "the reviewer and author disagree on a taste call no test can settle",
      escalations: [{ reviewId: "unknown", question: "flat or nested?" }],
    }),
    discussionTurn,
    behaviour,
    artifactDir,
  };

  // CommonJS, not ESM: the file must be named exactly `claude` for the adapter to
  // spawn it, so it has no .mjs extension, and the temp directory has no
  // package.json declaring "type": "module" — Node therefore loads it as CJS and
  // an `import` statement would be a syntax error.
  /*
   * Each fake must speak ITS OWN runtime's protocol.
   *
   * A single claude-shaped fake produced zero reviews and cost real debugging
   * time: the reviewer is a codex expert, and the codex parser only recognises
   * `thread.started` / `item.completed` / `turn.completed`. A claude-style
   * `result` event is silently ignored by it, so every review came back
   * unparseable — with no error, because "no findings" and "failed to parse" look
   * identical from outside.
   *
   * The prompt is also passed differently: claude uses `-p <prompt>` while codex
   * appends it positionally. Taking the longest argv entry covers both, since a
   * prompt is always far longer than any flag.
   */
  const emitFn =
    format === "codex"
      ? `function emit(result) {
  process.stdout.write(JSON.stringify({ type: "thread.started", thread_id: "fake-thread" }) + "\\n");
  process.stdout.write(JSON.stringify({ type: "turn.started" }) + "\\n");
  // A stock codex install emits benign warnings under item.type "error" and still
  // completes; including one keeps the fake honest about that.
  process.stdout.write(JSON.stringify({ type: "item.completed", item: { id: "w0", type: "error", message: "clamping hook timeout" } }) + "\\n");
  process.stdout.write(JSON.stringify({ type: "item.completed", item: { id: "m0", type: "agent_message", text: result } }) + "\\n");
  process.stdout.write(JSON.stringify({ type: "turn.completed", usage: { input_tokens: 10, output_tokens: 5, cached_input_tokens: 0 } }) + "\\n");
}`
      : `function emit(result) {
  // "type" is written LAST, mirroring the real claude terminal event — a parser
  // that peeks at a prefix instead of parsing the whole object would miss it.
  process.stdout.write(
    JSON.stringify({
      is_error: false,
      session_id: "fake-session",
      result,
      usage: { input_tokens: 10, output_tokens: 5 },
      type: "result",
    }) + "\\n",
  );
}`;

  return `#!/usr/bin/env node
const { writeFileSync, readFileSync, mkdirSync } = require("node:fs");
const { join } = require("node:path");
const C = ${JSON.stringify(config)};
const argv = process.argv.slice(2);
const prompt = argv.reduce((longest, a) => (a.length > longest.length ? a : longest), "");

// Record every prompt so a test can assert what the pipeline ACTUALLY sent,
// rather than trusting that a code path was reached. Filenames are unique per
// process because reviewers run concurrently and would otherwise race.
mkdirSync(C.artifactDir, { recursive: true });
writeFileSync(join(C.artifactDir, "prompt-" + process.pid + "-" + Date.now() + ".txt"), prompt);

/** Persisted across invocations: each agent turn is a separate process. */
function bump(name) {
  const p = join(C.artifactDir, name);
  let n = 0;
  try { n = Number(readFileSync(p, "utf8")) || 0; } catch {}
  n++;
  writeFileSync(p, String(n));
  return n;
}

${emitFn}

if (prompt.includes("decompose the goal")) {
  emit(C.plan);
} else if (prompt.includes("You are working as part of a team on one subtask")) {
  /*
   * A non-zero exit with no output, which is what a provider outage looks like
   * from here. The real case that prompted this: cursor-agent exited 1 with
   * "Error: [unavailable] HTTP 503" in its stderr tail.
   *
   * No backticks in this comment: it lives INSIDE the template literal that builds
   * this script, so one would close the template early. That is what broke the
   * first version of this edit.
   */
  if (C.doomed && prompt.includes("YOUR SUBTASK: " + C.doomed)) {
    process.stderr.write("Error: [unavailable] HTTP 503\\n");
    process.exit(1);
  }
  writeFileSync("note.txt", "hello from the maker\\n");
  emit("created note.txt");
} else if (prompt.includes("You are reviewing another agent")) {
  /*
   * A provider outage during review, which is what one API incident looks like
   * from here — both reviewers of a subtask hit the same endpoint.
   *
   * The draft above still succeeds, so this isolates the review step: the work
   * exists and is good, and the only thing missing is that anybody checked it.
   */
  if (C.behaviour === "review-outage") {
    process.stderr.write("Error: [unavailable] HTTP 503\\n");
    process.exit(1);
  }
  emit(C.review);
} else if (prompt.includes("Respond to each one")) {
  /*
   * Read the review ids out of the prompt, exactly as a real model must.
   *
   * A static id does not work, and that is the pipeline behaving correctly:
   * collectRebuttals discards any response naming an id that does not exist, so a
   * model cannot invent bookkeeping. The first version of this fake sent
   * "IGNORED" and its rebuttals were silently dropped — which surfaced only
   * because a test asserted on the prompt CONTENT of the next round rather than
   * on whether the code path ran.
   */
  const ids = [...prompt.matchAll(/- \\[([0-9a-fA-F-]{36})\\]/g)].map((m) => m[1]);
  emit(JSON.stringify({
    responses: ids.map((id) => ({ reviewId: id, decision: "reject", reason: "I disagree" })),
  }));
} else if (prompt.includes("bounded working discussion")) {
  emit(C.discussionTurn);
} else if (prompt.includes("Settle it by experiment")) {
  emit(C.repro);
} else if (prompt.includes("deciding whether one subtask is finished")) {
  // The rework scenario sends the work back exactly once, then accepts it — so
  // the loop is exercised without depending on the round cap to stop it.
  const n = bump("adjudications");
  if (C.behaviour === "rework" && n === 1) emit(C.adjudicationRework);
  else if (C.behaviour === "escalate" && n === 1) emit(C.adjudicationEscalate);
  else emit(C.adjudication);
} else if (prompt.includes("Verify the result")) {
  emit("ran the build, all good");
} else {
  emit("generic reply");
}
`;
}

interface Harness {
  repo: string;
  dbPath: string;
  binDir: string;
  /** Where the fakes record every prompt they were sent. */
  artifactDir: string;
  originalPath: string;
  runId: string;
  store: Store;
  /** Reads back the prompts the pipeline actually sent, in arrival order. */
  prompts: () => Promise<string[]>;
  dispose: () => Promise<void>;
}

async function setup(behaviour: string): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-pipe-"));
  const repo = join(root, "repo");
  const binDir = join(root, "bin");
  const artifactDir = join(root, "artifacts");
  const { mkdir, readdir, readFile } = await import("node:fs/promises");
  await mkdir(binDir, { recursive: true });
  await mkdir(artifactDir, { recursive: true });

  // Real git repository — worktree isolation is not mocked.
  await git(["init", "-q", "-b", "main", "repo"], root);
  await writeFile(join(repo, "README.md"), "# fixture\n", "utf8");
  await git(["add", "-A"], repo);
  await git(
    ["-c", "user.name=T", "-c", "user.email=t@localhost", "commit", "-q", "-m", "init"],
    repo,
  );

  // Fake CLIs, ahead of the real ones on PATH. Each speaks its own runtime's
  // wire format — see fakeAgentScript.
  for (const name of ["claude", "codex"] as const) {
    const p = join(binDir, name);
    await writeFile(p, fakeAgentScript(behaviour, name, artifactDir), "utf8");
    await chmod(p, 0o755);
  }
  const originalPath = process.env["PATH"] ?? "";
  process.env["PATH"] = `${binDir}${delimiter}${originalPath}`;

  const dbPath = join(root, "test.db");
  const store = new Store(dbPath);
  const author = store.createExpert({
    name: "Maker",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const reviewer = store.createExpert({
    name: "Reviewer",
    description: "",
    runtimeKind: "codex",
    model: null,
    systemPrompt: "",
    capabilities: ["correctness"],
  });
  const team = store.createTeam("fake-team");
  store.addTeamMember(team.id, author.id, "orchestrator");
  store.addTeamMember(team.id, author.id, "maker");
  store.addTeamMember(team.id, reviewer.id, "reviewer");
  store.addTeamMember(team.id, reviewer.id, "verifier");
  const project = store.createProject({ name: "p", repoPath: repo, teamId: team.id });
  const run = store.createRun({ projectId: project.id, goal: "add a note file" });

  return {
    repo,
    dbPath,
    binDir,
    artifactDir,
    originalPath,
    runId: run.id,
    store,
    async prompts() {
      const names = (await readdir(artifactDir)).filter((n) => n.startsWith("prompt-"));
      // Sorted by the timestamp component, not lexically: the filename leads with
      // the pid, and reviewers run concurrently, so a plain sort would interleave
      // turns from different processes in the wrong order.
      const stamped = names.map((n) => ({
        n,
        t: Number(n.replace(/^prompt-\d+-/, "").replace(/\.txt$/, "")) || 0,
      }));
      stamped.sort((a, b) => a.t - b.t);
      return Promise.all(stamped.map(({ n }) => readFile(join(artifactDir, n), "utf8")));
    },
    async dispose() {
      process.env["PATH"] = originalPath;
      store.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

const PIPELINE_OPTS = { autoApprovePlan: true, perAttemptTimeoutMs: 60_000 } as const;

test("pipeline: a clean review completes without discussion or rework", async () => {
  const h = await setup("clean");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    const subtasks = h.store.listSubTasks(h.runId);
    assert.equal(subtasks.length, 1, "the fake plan produced one subtask");
    assert.equal(subtasks[0]?.status, "done");
    assert.ok(subtasks[0]?.branch, "a branch was recorded — it is the deliverable");

    assert.equal(h.store.listReviews(h.runId).length, 0);
    assert.equal(h.store.listDiscussion(h.runId).length, 0, "no findings, so nothing to discuss");

    // The work must actually be reachable, not just reported.
    const files = await git(["ls-files"], h.repo);
    assert.ok(files.stdout.includes("note.txt"), "the maker's file merged into main");
  } finally {
    await h.dispose();
  }
});

test("pipeline: every reviewer failing is not approval", async () => {
  const h = await setup("review-outage");
  try {
    /*
     * The worst bug found in this codebase, and it was invisible.
     *
     * `collectReviews` returned findings only, so an empty array meant both
     * "reviewed and clean" and "nobody managed to review this". The second took
     * the accept branch — status `done`, logged as "no blocking findings" — and
     * `mergeStage` merges every `done` subtask. So UNREVIEWED code landed on the
     * user's branch and the run reported success.
     *
     * One API incident away from real: a live run hit `cursor-agent exited 1`
     * with `[unavailable] HTTP 503`, and the same outage reaching both reviewers
     * of one subtask is the ordinary case, not a contrived one. Cross-vendor
     * review is the entire premise of this system.
     */
    await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    const subtasks = h.store.listSubTasks(h.runId);
    assert.equal(subtasks.length, 1);
    const s = subtasks[0];

    // Not `done`: that is the status that gets merged.
    assert.equal(s?.status, "in_review", `expected in_review, got ${s?.status}`);

    // The security-critical property. Nothing else in this test matters as much.
    const files = await git(["ls-files"], h.repo);
    assert.ok(
      !files.stdout.includes("note.txt"),
      "unreviewed work must NOT be merged into the working branch",
    );

    // But the work is preserved rather than thrown away — the draft succeeded, and
    // a human can still look at the branch.
    assert.ok(s?.branch, "the draft's branch must survive for a human to inspect");
    const branchExists = await git(["rev-parse", "--verify", s?.branch ?? ""], h.repo);
    assert.equal(branchExists.code, 0, "the branch must still exist");

    // And it says so, rather than being silently skipped.
    const events = h.store.eventsAfter(h.runId, 0, 5000);
    const unreviewed = events.find((e) => e.type === "subtask:unreviewed");
    assert.ok(unreviewed, "the run must record that this was never reviewed");

    /*
     * The 503 was RETRIED before being given up on.
     *
     * Asserted rather than inferred from wall-clock: the earlier evidence was this
     * test slowing from 1.4s to 6.1s, which matches two reviewers each backing off
     * 1.5s then 3s — but timing is not proof, and a future change that quietly
     * bypasses `runOneWithRetry` would keep passing on duration alone.
     */
    const retries = events.filter((e) => e.type === "attempt:retrying");
    assert.ok(
      retries.length > 0,
      "a transient 503 must be retried, not accepted as a dead reviewer on first failure",
    );
    assert.ok(
      !events.some((e) => e.type === "subtask:accepted"),
      "nothing may be recorded as accepted when no review happened",
    );

    // No review rows, because no reviewer delivered one.
    assert.equal(h.store.listReviews(h.runId).length, 0);
  } finally {
    await h.dispose();
  }
});

test("pipeline: a partial failure is reported as partial, not as success", async () => {
  const h = await setup("partial-failure");
  try {
    /*
     * Reproduced against real CLIs before this test existed. A Cursor 503 killed
     * two of three subtasks and the run still reported:
     *
     *   status=completed  error=NULL
     *
     * which moves the board card to 待复核. The user is then asked to review work
     * missing most of what they asked for, with nothing anywhere saying so — and in
     * that run the surviving output actively contradicted the goal, since one
     * module got the new error convention and the other kept the old one.
     *
     * `finishRun` wrote `completed` without ever looking at the subtasks.
     */
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    const subtasks = h.store.listSubTasks(h.runId);
    const failed = subtasks.filter((s) => s.status === "failed");
    assert.equal(subtasks.length, 2, "the fixture plans one survivor and one casualty");
    assert.equal(failed.length, 1, "exactly one draft was killed");

    // Still `completed`: the survivor merged real work, so there is something to
    // review, and `failed` would send the card back to 待办 and bury it.
    assert.equal(outcome.status, "completed");

    // But the loss has to be stated. This is the whole fix.
    assert.ok(outcome.error !== null, "a partial result must not report error=null");
    assert.match(outcome.error ?? "", /1\/2/, "says how much was lost");
    const failedTitle = failed[0]?.title ?? "";
    assert.notEqual(failedTitle, "", "the fixture must produce one failed subtask with a title");
    assert.ok(
      (outcome.error ?? "").includes(failedTitle),
      `names the failed subtask; got: ${outcome.error}`,
    );

    // Persisted, not just returned — the UI reads the row.
    assert.equal(h.store.getRun(h.runId)?.error, outcome.error);

    // And the survivor's work genuinely landed.
    const files = await git(["ls-files"], h.repo);
    assert.ok(files.stdout.includes("note.txt"), "the surviving subtask still merged");
  } finally {
    await h.dispose();
  }
});

test("pipeline: a total failure is reported as failed, not completed", async () => {
  const h = await setup("total-failure");
  try {
    // "Completed with an error" only makes sense when something completed. With
    // nothing merged there is nothing to review, so sending the card back to 待办
    // is the accurate outcome rather than a hidden one.
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    const subtasks = h.store.listSubTasks(h.runId);
    assert.equal(subtasks.length, 1);
    assert.equal(subtasks[0]?.status, "failed");

    assert.equal(outcome.status, "failed", `expected failed, got ${outcome.status}`);
    assert.ok(outcome.error !== null);
    assert.equal(h.store.getRun(h.runId)?.status, "failed");

    // Nothing merged, so main is untouched.
    const files = await git(["ls-files"], h.repo);
    assert.ok(!files.stdout.includes("note.txt"), "a failed draft must not merge");
  } finally {
    await h.dispose();
  }
});

test("pipeline: a nit does not block, discuss, or trigger rework", async () => {
  const h = await setup("nit-only");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    assert.equal(h.store.listReviews(h.runId).length, 1, "the nit is recorded");
    assert.equal(h.store.listSubTasks(h.runId)[0]?.status, "done");
    // A local preference must not cost a rebuttal, a discussion, or a round.
    assert.equal(h.store.listDiscussion(h.runId).length, 0);
    assert.equal(h.store.listAdjudications(h.runId).length, 0);
  } finally {
    await h.dispose();
  }
});

test("pipeline: a verifiable claim is settled by reproduction, not debate", async () => {
  const h = await setup("refuted");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    const reviews = h.store.listReviews(h.runId);
    assert.equal(reviews.length, 1);
    assert.equal(reviews[0]?.verifiable, true);
    assert.equal(reviews[0]?.reproOutcome, "refuted", "the claim was tested and did not hold");

    /*
     * The payoff of the verifiable/unverifiable split: a disproven blocker stops
     * blocking, so it costs no discussion and no rework round. Before this was
     * enforced it consumed a rebuttal turn, an adjudication turn, and possibly a
     * full rework.
     */
    assert.equal(h.store.listDiscussion(h.runId).length, 0, "settled by test, not argued");
    assert.equal(h.store.listSubTasks(h.runId)[0]?.status, "done");

    const events = h.store.eventsAfter(h.runId, 0, 5000);
    assert.ok(events.some((e) => e.type === "repro:settled"));
    assert.ok(events.some((e) => e.type === "repro:dismissed"));
  } finally {
    await h.dispose();
  }
});

test("pipeline: an unverifiable major finding DOES reach discussion", async () => {
  const h = await setup("judgment");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    const reviews = h.store.listReviews(h.runId);
    assert.ok(reviews.length >= 1);
    assert.equal(reviews[0]?.verifiable, false);
    assert.equal(reviews[0]?.reproOutcome, null, "an unverifiable claim is never reproduced");

    /*
     * The mechanism the user asked for, finally observed. Three real multi-agent
     * runs never got here: reaching it needs a reviewer to rate a judgment call
     * `major` rather than `nit`, which no amount of retrying makes deterministic.
     */
    const discussion = h.store.listDiscussion(h.runId);
    assert.ok(discussion.length > 0, "specialists must actually discuss the judgment call");
    assert.ok(
      discussion.every((m) => m.round <= 2),
      "bounded by the round cap, with no 'until they agree' condition",
    );
    // More than one voice, otherwise it is a monologue.
    assert.ok(
      new Set(discussion.map((m) => m.authorExpertId)).size >= 2,
      "at least two experts contributed",
    );

    const events = h.store.eventsAfter(h.runId, 0, 5000);
    assert.ok(events.some((e) => e.type === "discussion:started"));
    assert.ok(events.some((e) => e.type === "discussion:message"));
    assert.ok(events.some((e) => e.type === "discussion:ended"));
  } finally {
    await h.dispose();
  }
});

test("pipeline: discussion converges early when nobody has more to say", async () => {
  const h = await setup("silent-discussion");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    // Every speaker replies "NOTHING TO ADD", so no turn is persisted and the
    // convergence check must stop after the first round rather than padding to
    // the cap. Restating agreement burns budget and adds nothing.
    assert.equal(h.store.listDiscussion(h.runId).length, 0);
    const events = h.store.eventsAfter(h.runId, 0, 5000);
    assert.ok(events.some((e) => e.type === "discussion:started"));
    assert.ok(events.some((e) => e.type === "discussion:pass"), "a pass is recorded");
    assert.ok(
      events.some((e) => e.type === "discussion:converged"),
      "an empty round ends the discussion",
    );
  } finally {
    await h.dispose();
  }
});

test("pipeline: the stage barrier and event log stay coherent", async () => {
  const h = await setup("clean");
  try {
    await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    const events = h.store.eventsAfter(h.runId, 0, 10_000);
    assert.ok(events.length > 0);
    // SSE replay depends on this being dense and strictly increasing.
    const seqs = events.map((e) => e.seq);
    assert.ok(seqs.every((s, i) => i === 0 || s > (seqs[i - 1] ?? -1)));

    assert.ok(events.some((e) => e.type === "stage:barrier_cleared"));
    assert.ok(events.some((e) => e.type === "merge:ok"));
    assert.ok(events.some((e) => e.type === "verify:done"));
    assert.ok(events.some((e) => e.type === "run:completed"));

    const run = h.store.getRun(h.runId);
    assert.equal(run?.status, "completed");
    assert.ok((run?.spentTokens ?? 0) > 0, "usage from the fake result event is recorded");
  } finally {
    await h.dispose();
  }
});

test("rework: the second attempt is told what was wrong", async () => {
  const h = await setup("rework");
  try {
    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");

    // The loop must actually have gone around: sent back once, then accepted.
    const drafts = h.store.listAttempts(h.runId).filter((a) => a.kind === "draft");
    assert.equal(drafts.length, 2, `expected two drafting turns, saw ${drafts.length}`);
    const verdicts = h.store.listAdjudications(h.runId);
    assert.equal(verdicts[0]?.verdict, "rework");
    assert.equal(verdicts.at(-1)?.verdict, "proceed");

    const prompts = await h.prompts();
    const draftPrompts = prompts.filter((p) =>
      p.includes("You are working as part of a team on one subtask"),
    );
    assert.equal(draftPrompts.length, 2);

    const [first, second] = draftPrompts;
    assert.ok(first !== undefined && second !== undefined);

    // The first turn has no history to carry.
    assert.ok(!first.includes("THIS IS A REWORK"), "the first attempt must not claim to be a rework");

    /*
     * The assertion this whole scenario exists for.
     *
     * A rework round used to re-send the ORIGINAL prompt verbatim to a fresh
     * session: same task, no idea what any reviewer had said, no memory of its own
     * rebuttal. A full agent turn bought for zero new information, while the round
     * counter and the `rework` verdict made the mechanism look like it worked.
     *
     * Asserting on the prompt text rather than on "the code path ran" is the
     * point — reaching the branch proves nothing if the payload is empty.
     */
    assert.ok(second.includes("THIS IS A REWORK"), "the second attempt must be labelled a rework");
    assert.ok(
      second.includes("this API shape will age badly"),
      "the reviewer's actual claim must reach the author",
    );
    assert.ok(
      second.includes("WHY THIS CAME BACK") && second.includes("the blocker stands"),
      "the adjudicator's reason must reach the author",
    );
    assert.ok(
      second.includes("YOUR previous response"),
      "the author's own earlier rebuttal must be echoed back — sessions do not persist",
    );
    // And it must not silently restart from nothing.
    assert.ok(
      second.includes("Do NOT start over"),
      "the previous attempt is already in the worktree and should be built on",
    );
  } finally {
    await h.dispose();
  }
});

test("escalation: the run parks for a human, then acts on the ruling", async () => {
  const h = await setup("escalate");
  try {
    const parked = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    /*
     * Parking must survive the end of the pipeline.
     *
     * The tail used to write `status: completed` unconditionally, clobbering the
     * `blocked_on_human` an escalation had just set — so the UI showed a finished
     * run while a decision was still pending, and nothing resumes a completed run.
     */
    assert.equal(parked.status, "blocked_on_human", parked.error ?? "");
    const atGate = h.store.getRun(h.runId);
    assert.equal(atGate?.status, "blocked_on_human");
    assert.equal(atGate?.gate, "adjudication");

    const subtask = h.store.listSubTasks(h.runId)[0];
    assert.ok(subtask);
    assert.equal(subtask.status, "blocked");
    assert.ok(subtask.branch, "the work so far is preserved on a branch");

    const pending = h.store
      .listAdjudications(h.runId)
      .find((a) => a.escalatedToHuman && a.humanDecision === null);
    assert.ok(pending, "an escalation is recorded and awaiting a decision");

    // Nothing merged while blocked — unreviewed work must not land.
    const beforeFiles = await git(["ls-files"], h.repo);
    assert.ok(!beforeFiles.stdout.includes("note.txt"));

    // ── The human rules ──
    const RULING = "Use the flat shape. Nested config has aged badly for us before.";
    const resumed = await resolveEscalationAndContinue({
      store: h.store,
      runId: h.runId,
      adjudicationId: pending.id,
      decision: RULING,
      perAttemptTimeoutMs: 60_000,
    });
    assert.equal(resumed.status, "completed", resumed.error ?? "");

    // The decision is persisted, not just consumed.
    const settled = h.store.listAdjudications(h.runId).find((a) => a.id === pending.id);
    assert.equal(settled?.humanDecision, RULING);

    /*
     * The assertion this scenario exists for.
     *
     * `/resolve` used to write the decision and return; nothing read it, so the
     * subtask stayed `blocked` forever. The system could ask a human to settle
     * what no test can, and then ignore the answer — asserting on the prompt text
     * is what proves the ruling actually reached the agent.
     */
    const prompts = await h.prompts();
    const drafts = prompts.filter((p) =>
      p.includes("You are working as part of a team on one subtask"),
    );
    assert.equal(drafts.length, 2, `expected a second attempt, saw ${drafts.length}`);
    const second = drafts[1];
    assert.ok(second !== undefined);
    assert.ok(second.includes("A HUMAN HAS RULED ON THIS"), "the ruling must be labelled");
    assert.ok(second.includes(RULING), "the ruling text itself must reach the author");
    assert.ok(
      second.includes("do not re-litigate"),
      "and the author must be told not to argue it again",
    );

    // ── And the resumed work actually lands ──
    assert.equal(h.store.listSubTasks(h.runId)[0]?.status, "done");
    const afterFiles = await git(["ls-files"], h.repo);
    /*
     * Guards a second bug found here: phaseStages skipped merging entirely for a
     * stage with no `todo` subtasks, so a subtask completed on a RESUMED run had
     * its work silently abandoned on its branch.
     */
    assert.ok(afterFiles.stdout.includes("note.txt"), "the resumed work merged into main");
  } finally {
    await h.dispose();
  }
});

test("escalation: an adjudication from another run is refused", async () => {
  const h = await setup("escalate");
  try {
    await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    const pending = h.store.listAdjudications(h.runId).find((a) => a.escalatedToHuman);
    assert.ok(pending);

    const project = h.store.listProjects()[0];
    assert.ok(project);
    const other = h.store.createRun({ projectId: project.id, goal: "unrelated" });

    // Guards against a client posting a valid id under the wrong run, which would
    // resume work the caller never looked at.
    await assert.rejects(
      () =>
        resolveEscalationAndContinue({
          store: h.store,
          runId: other.id,
          adjudicationId: pending.id,
          decision: "whatever",
        }),
      /different run/,
    );
    await assert.rejects(
      () =>
        resolveEscalationAndContinue({
          store: h.store,
          runId: h.runId,
          adjudicationId: "does-not-exist",
          decision: "whatever",
        }),
      /adjudication not found/,
    );
  } finally {
    await h.dispose();
  }
});

test("plan gate: the run parks before any work starts, then resumes on approval", async () => {
  const h = await setup("clean");
  try {
    // autoApprovePlan omitted, i.e. the default interactive behaviour.
    const parked = await runPipeline({
      store: h.store,
      runId: h.runId,
      perAttemptTimeoutMs: 60_000,
    });
    assert.equal(parked.status, "blocked_on_human");
    assert.equal(parked.error, null);

    const atGate = h.store.getRun(h.runId);
    assert.equal(atGate?.gate, "plan_approval");
    assert.equal(atGate?.status, "blocked_on_human");

    // The plan is visible so a person can actually review it.
    const subtasks = h.store.listSubTasks(h.runId);
    assert.equal(subtasks.length, 1);
    assert.equal(subtasks[0]?.status, "todo");

    /*
     * The assertion that gives the gate its value: NO drafting has happened.
     *
     * The gate exists because thirty seconds spent checking a decomposition
     * avoids several agents building the wrong thing and several reviews of that
     * wrong thing. A gate that let drafting start anyway would cost exactly what
     * it was meant to save, while still looking like it worked.
     */
    const before = h.store.listAttempts(h.runId);
    assert.ok(before.length > 0, "planning itself ran");
    assert.ok(
      before.every((a) => a.kind === "plan"),
      `only planning may have run, saw: ${before.map((a) => a.kind).join(", ")}`,
    );
    assert.equal(subtasks[0]?.worktreePath, null, "no worktree was created yet");

    // Approval resumes from the gate rather than restarting the run.
    const resumed = await approvePlanAndContinue({
      store: h.store,
      runId: h.runId,
      perAttemptTimeoutMs: 60_000,
    });
    assert.equal(resumed.status, "completed", resumed.error ?? "");

    const done = h.store.getRun(h.runId);
    assert.equal(done?.gate, null, "the gate is cleared once approved");
    assert.equal(h.store.listSubTasks(h.runId)[0]?.status, "done");
    assert.ok(
      h.store.listAttempts(h.runId).some((a) => a.kind === "draft"),
      "drafting only happened after approval",
    );

    const files = await git(["ls-files"], h.repo);
    assert.ok(files.stdout.includes("note.txt"), "the approved work landed");
  } finally {
    await h.dispose();
  }
});

test("cancellation: a stopped run neither merges nor reports success", async () => {
  const h = await setup("clean");
  try {
    // Park at the plan gate so the cancel lands at a deterministic point — no
    // timing race against a real subprocess.
    const parked = await runPipeline({
      store: h.store,
      runId: h.runId,
      perAttemptTimeoutMs: 60_000,
    });
    assert.equal(parked.status, "blocked_on_human");

    // The user presses Stop, exactly as the cancel endpoint does.
    h.store.updateRun(h.runId, { status: "cancelled", endedAt: new Date().toISOString() });

    /*
     * A cancelled run cannot be resumed.
     *
     * Both resume paths began by writing `status: "running"`, which RESURRECTED it:
     * cancelling does not clear the gate, so the UI still offered "approve plan" on
     * a stopped run, and pressing it carried on as though nothing had happened.
     */
    await assert.rejects(
      () =>
        approvePlanAndContinue({
          store: h.store,
          runId: h.runId,
          perAttemptTimeoutMs: 60_000,
        }),
      /cancelled/,
    );

    assert.equal(h.store.getRun(h.runId)?.status, "cancelled", "the status must not be rewritten");

    // Nothing may land on the user's branch.
    const files = await git(["ls-files"], h.repo);
    assert.ok(
      !files.stdout.includes("note.txt"),
      "no work may be merged into the working branch after a cancel",
    );
    assert.equal(
      h.store.listAttempts(h.runId).filter((a) => a.kind === "verify").length,
      0,
      "no verifier turn may be spent on a cancelled run",
    );
  } finally {
    await h.dispose();
  }
});

test("cancellation: an abort mid-flight stops before merging", async () => {
  const h = await setup("clean");
  try {
    const parked = await runPipeline({
      store: h.store,
      runId: h.runId,
      perAttemptTimeoutMs: 60_000,
    });
    assert.equal(parked.status, "blocked_on_human");

    /*
     * Resume with an ALREADY-aborted signal, i.e. a cancel that arrives while the
     * pipeline is running rather than before it starts.
     *
     * This is the dangerous case the guards exist for: aborting only killed the
     * agent SUBPROCESS, while the surrounding orchestration carried on and merged.
     * Half-finished, unreviewed work on the user's working branch is not undone by
     * pressing anything.
     */
    const controller = new AbortController();
    controller.abort();

    const after = await approvePlanAndContinue({
      store: h.store,
      runId: h.runId,
      signal: controller.signal,
      perAttemptTimeoutMs: 60_000,
    });

    assert.equal(after.status, "cancelled", "an aborted run must not report success");
    assert.equal(h.store.getRun(h.runId)?.status, "cancelled");

    const files = await git(["ls-files"], h.repo);
    assert.ok(!files.stdout.includes("note.txt"), "nothing may be merged after an abort");

    const events = h.store.eventsAfter(h.runId, 0, 5000);
    assert.ok(
      events.some((e) => e.type === "stage:skipped_cancelled"),
      "the skip must be recorded, not silent",
    );
    assert.ok(
      events.some((e) => e.type === "verify:skipped_cancelled"),
      "verification must be skipped when there is nothing to verify",
    );
    // A verifier turn is a full agent run; spending one on a cancelled pipeline is
    // pure waste.
    assert.equal(h.store.listAttempts(h.runId).filter((a) => a.kind === "verify").length, 0);
  } finally {
    await h.dispose();
  }
});

test("plan gate: approving a run that is not parked is refused", async () => {
  const h = await setup("clean");
  try {
    // Never parked, so there is nothing to approve.
    await assert.rejects(
      () => approvePlanAndContinue({ store: h.store, runId: h.runId }),
      /not waiting at the plan gate/,
    );
    // And an unknown run must not be silently ignored.
    await assert.rejects(
      () => approvePlanAndContinue({ store: h.store, runId: "no-such-run" }),
      /run not found/,
    );
  } finally {
    await h.dispose();
  }
});

test("plan gate: approving twice is refused rather than running the work again", async () => {
  const h = await setup("clean");
  try {
    await runPipeline({ store: h.store, runId: h.runId, perAttemptTimeoutMs: 60_000 });
    await approvePlanAndContinue({ store: h.store, runId: h.runId, perAttemptTimeoutMs: 60_000 });

    const attemptsAfterFirst = h.store.listAttempts(h.runId).length;
    // A double-click on Approve must not spend a second full run's worth of
    // tokens, nor merge the same branch twice.
    await assert.rejects(
      () => approvePlanAndContinue({ store: h.store, runId: h.runId }),
      /not waiting at the plan gate/,
    );
    assert.equal(h.store.listAttempts(h.runId).length, attemptsAfterFirst, "no extra agent turns");
  } finally {
    await h.dispose();
  }
});

test("pipeline: a dirty working tree is refused before any tokens are spent", async () => {
  const h = await setup("clean");
  try {
    // The user is mid-edit, as almost everyone almost always is.
    await writeFile(join(h.repo, "README.md"), "# fixture\n\nthe user's uncommitted work\n", "utf8");

    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });

    /*
     * Refused up front, and the timing is the whole point.
     *
     * Worktrees branch from HEAD, so an agent cannot see work that exists only in
     * the working tree — it reasons about a stale snapshot of the very files being
     * edited. Then git refuses the final merge ("your local changes would be
     * overwritten"), which was measured: the entire run is paid for before the
     * problem appears.
     */
    assert.equal(outcome.status, "failed");
    assert.match(outcome.error ?? "", /uncommitted changes/);
    // The message has to name the file and say what to do; the user is looking at
    // a repository that seems perfectly fine.
    assert.match(outcome.error ?? "", /README\.md/);
    assert.match(outcome.error ?? "", /git stash/);

    assert.equal(
      h.store.listAttempts(h.runId).length,
      0,
      "not one agent turn may be spent on a run that cannot merge",
    );
  } finally {
    await h.dispose();
  }
});

test("pipeline: untracked files do NOT block a run", async () => {
  const h = await setup("clean");
  try {
    /*
     * Scratch files, editor droppings and build output are everywhere. They are
     * invisible to a worktree anyway and only collide if the agent happens to
     * create the same path, so refusing over them would be obstruction rather than
     * protection.
     */
    await writeFile(join(h.repo, "scratch.md"), "notes to self\n", "utf8");
    await writeFile(join(h.repo, "debug.log"), "noise\n", "utf8");

    const outcome = await runPipeline({ store: h.store, runId: h.runId, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "completed", outcome.error ?? "");
    // And the user's untracked files are still theirs, untouched.
    const files = await git(["status", "--porcelain", "--untracked-files=all"], h.repo);
    assert.ok(files.stdout.includes("scratch.md"));
  } finally {
    await h.dispose();
  }
});

test("pipeline: single-expert mode is exempt from the clean-tree requirement", async () => {
  const h = await setup("clean");
  try {
    await writeFile(join(h.repo, "README.md"), "# fixture\n\nmid-edit\n", "utf8");
    const project = h.store.listProjects()[0];
    assert.ok(project);
    const solo = h.store.createRun({ projectId: project.id, goal: "small fix", soloMode: true });

    const outcome = await runPipeline({ store: h.store, runId: solo.id, ...PIPELINE_OPTS });

    /*
     * Solo mode works directly in the repository rather than a worktree, so it SEES
     * the uncommitted edits and never merges. Neither failure mode applies, and
     * blocking it would deny the user the one lane that handles a dirty tree.
     */
    assert.equal(outcome.status, "completed", outcome.error ?? "");
    assert.ok(h.store.listAttempts(solo.id).length > 0, "solo mode actually ran");
  } finally {
    await h.dispose();
  }
});

test("pipeline: a non-git repository is refused before any agent runs", async () => {
  const h = await setup("clean");
  try {
    const plain = await mkdtemp(join(tmpdir(), "todoagent-plain-"));
    try {
      const project = h.store.createProject({
        name: "plain",
        repoPath: plain,
        teamId: h.store.listTeams()[0]?.id ?? "",
      });
      const run = h.store.createRun({ projectId: project.id, goal: "x" });
      const outcome = await runPipeline({ store: h.store, runId: run.id, ...PIPELINE_OPTS });

      assert.equal(outcome.status, "failed");
      // Without worktree isolation parallel agents overwrite each other, so this
      // has to fail loudly up front rather than corrupting a directory.
      assert.match(outcome.error ?? "", /not a git repository/);
      assert.equal(h.store.listAttempts(run.id).length, 0, "no tokens spent on a doomed run");
    } finally {
      await rm(plain, { recursive: true, force: true });
    }
  } finally {
    await h.dispose();
  }
});

test("pipeline: the budget ceiling stops a run", async () => {
  const h = await setup("clean");
  try {
    const project = h.store.listProjects()[0];
    assert.ok(project);
    // One token: the pre-spawn check must refuse before the first agent turn.
    const run = h.store.createRun({ projectId: project.id, goal: "x", budgetTokens: 1 });
    h.store.addSpend(run.id, 5);

    const outcome = await runPipeline({ store: h.store, runId: run.id, ...PIPELINE_OPTS });
    assert.equal(outcome.status, "budget_exceeded");
    // Not "failed": partial work is surrendered, which is the point of a ceiling.
    assert.match(outcome.error ?? "", /budget/);
  } finally {
    await h.dispose();
  }
});
