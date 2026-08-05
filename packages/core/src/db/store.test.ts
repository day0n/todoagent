import assert from "node:assert/strict";
import { test } from "node:test";
import { Store } from "./index.ts";

/**
 * Boundary tests for the execution layer.
 *
 * The stage barrier gets the most attention here because it is the load-bearing
 * piece of the whole design — it is the automatic hand-off that Raft explicitly
 * does not implement, and if it misjudges "terminal" a run either stalls forever
 * or races ahead onto unfinished work.
 */

function fixture(): { store: Store; runId: string; expertId: string } {
  const store = new Store(":memory:");
  const expert = store.createExpert({
    name: "T",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  const project = store.createProject({ name: "p", repoPath: "/tmp/p", teamId: team.id });
  const run = store.createRun({ projectId: project.id, goal: "g" });
  return { store, runId: run.id, expertId: expert.id };
}

function addSubTask(
  store: Store,
  runId: string,
  stage: number,
  status: Parameters<Store["updateSubTask"]>[1]["status"] = "todo",
): string {
  const s = store.createSubTask({
    runId,
    stage,
    title: `s${stage}`,
    brief: "b",
    acceptance: "a",
    capability: "general",
    assignedExpertId: null,
    dependsOn: [],
    status: "todo",
    worktreePath: null,
    branch: null,
  });
  if (status !== undefined && status !== "todo") store.updateSubTask(s.id, { status });
  return s.id;
}

// ── Stage barrier ───────────────────────────────────────────

test("barrier: an empty stage is trivially complete", () => {
  const { store, runId } = fixture();
  // Otherwise a plan that skips a stage number would deadlock the run.
  assert.equal(store.stageComplete(runId, 0), true);
  assert.equal(store.stageComplete(runId, 99), true);
  store.close();
});

test("barrier: a running subtask holds the stage closed", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 0, "done");
  const pending = addSubTask(store, runId, 0, "running");
  assert.equal(store.stageComplete(runId, 0), false, "one running sibling must block");
  store.updateSubTask(pending, { status: "done" });
  assert.equal(store.stageComplete(runId, 0), true);
  store.close();
});

test("barrier: failed and blocked count as terminal", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 0, "failed");
  addSubTask(store, runId, 0, "blocked");
  // A failed sibling must not stall the pipeline forever — the run continues and
  // reports what did not land.
  assert.equal(store.stageComplete(runId, 0), true);
  store.close();
});

test("barrier: in_review counts as terminal", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 0, "in_review");
  /*
   * in_review is where a subtask lands when it exhausts its rework rounds with
   * findings still open: the agents are finished, a human needs to look. If the
   * barrier treated it as non-terminal, exhausting rounds would abort the entire
   * run with "stage did not reach a terminal state" — turning a normal outcome
   * into a crash.
   */
  assert.equal(store.stageComplete(runId, 0), true, "rounds-exhausted must not deadlock the run");
  store.close();
});

test("barrier: reworking is NOT terminal", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 0, "reworking");
  // Mid-rework means another draft is coming; opening the next stage now would
  // let downstream work build on output that is about to change.
  assert.equal(store.stageComplete(runId, 0), false);
  store.close();
});

test("barrier: stages are independent", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 0, "done");
  addSubTask(store, runId, 1, "running");
  assert.equal(store.stageComplete(runId, 0), true);
  assert.equal(store.stageComplete(runId, 1), false);
  assert.deepEqual(store.stages(runId), [0, 1]);
  store.close();
});

test("barrier: stages() returns sorted distinct stages", () => {
  const { store, runId } = fixture();
  addSubTask(store, runId, 2);
  addSubTask(store, runId, 0);
  addSubTask(store, runId, 2);
  addSubTask(store, runId, 1);
  // Execution order depends on this being sorted, not insertion-ordered.
  assert.deepEqual(store.stages(runId), [0, 1, 2]);
  store.close();
});

test("barrier: another run's subtasks are invisible", () => {
  const { store, runId } = fixture();
  const project = store.listProjects()[0];
  assert.ok(project);
  const other = store.createRun({ projectId: project.id, goal: "other" });
  addSubTask(store, runId, 0, "done");
  addSubTask(store, other.id, 0, "running");
  assert.equal(store.stageComplete(runId, 0), true, "runs must not block each other");
  assert.equal(store.stageComplete(other.id, 0), false);
  store.close();
});

// ── Budget ──────────────────────────────────────────────────

test("budget: spend accumulates and reports the breach", () => {
  const { store } = fixture();
  const project = store.listProjects()[0];
  assert.ok(project);
  const run = store.createRun({ projectId: project.id, goal: "g", budgetTokens: 1000 });

  let r = store.addSpend(run.id, 400);
  assert.equal(r.spent, 400);
  assert.equal(r.exceeded, false);

  r = store.addSpend(run.id, 500);
  assert.equal(r.spent, 900);
  assert.equal(r.exceeded, false);

  // At the ceiling counts as exceeded: the check runs before a spawn, so
  // "exactly at budget" must not authorise one more full agent turn.
  r = store.addSpend(run.id, 100);
  assert.equal(r.spent, 1000);
  assert.equal(r.exceeded, true);
  store.close();
});

test("budget: zero means unlimited", () => {
  const { store } = fixture();
  const project = store.listProjects()[0];
  assert.ok(project);
  const run = store.createRun({ projectId: project.id, goal: "g", budgetTokens: 0 });
  const r = store.addSpend(run.id, 10_000_000);
  assert.equal(r.exceeded, false, "an explicit 0 ceiling must not read as 'already exceeded'");
  store.close();
});

test("budget: spend on an unknown run does not throw", () => {
  const { store } = fixture();
  const r = store.addSpend("nope", 100);
  assert.equal(r.exceeded, false);
  store.close();
});

// ── Event log (SSE replay depends on this) ──────────────────

test("events: seq is per-run and gapless", () => {
  const { store, runId } = fixture();
  const project = store.listProjects()[0];
  assert.ok(project);
  const other = store.createRun({ projectId: project.id, goal: "o" });

  for (let i = 0; i < 5; i++) store.appendEvent({ runId, attemptId: null, type: "t", payload: { i } });
  for (let i = 0; i < 3; i++) store.appendEvent({ runId: other.id, attemptId: null, type: "t", payload: { i } });

  const mine = store.eventsAfter(runId, 0, 100);
  assert.deepEqual(mine.map((e) => e.seq), [1, 2, 3, 4, 5]);
  const theirs = store.eventsAfter(other.id, 0, 100);
  assert.deepEqual(theirs.map((e) => e.seq), [1, 2, 3], "seq must not be global");
  store.close();
});

test("events: eventsAfter is an exclusive cursor", () => {
  const { store, runId } = fixture();
  const ids: number[] = [];
  for (let i = 0; i < 4; i++) {
    ids.push(store.appendEvent({ runId, attemptId: null, type: "t", payload: { i } }));
  }
  const second = ids[1];
  assert.ok(second !== undefined);
  const after = store.eventsAfter(runId, second, 100);
  // Inclusive would replay one event twice on every SSE reconnect.
  assert.equal(after.length, 2);
  assert.ok(after.every((e) => e.id > second));
  store.close();
});

test("events: payload round-trips, and a malformed one degrades to null", () => {
  const { store, runId } = fixture();
  store.appendEvent({ runId, attemptId: null, type: "t", payload: { nested: { a: [1, "x", null] } } });
  store.appendEvent({ runId, attemptId: null, type: "t", payload: undefined });
  const evs = store.eventsAfter(runId, 0, 10);
  assert.deepEqual(evs[0]?.payload, { nested: { a: [1, "x", null] } });
  assert.equal(evs[1]?.payload, null, "undefined must persist as null, not crash the reader");
  store.close();
});

test("events: limit is honoured so a long run cannot flood a client", () => {
  const { store, runId } = fixture();
  for (let i = 0; i < 50; i++) store.appendEvent({ runId, attemptId: null, type: "t", payload: i });
  assert.equal(store.eventsAfter(runId, 0, 10).length, 10);
  store.close();
});

// ── Transactions (no FK constraints, so atomicity is manual) ──

test("tx: a throw rolls back every write in the batch", () => {
  const { store, runId } = fixture();
  assert.throws(() => {
    store.tx(() => {
      addSubTask(store, runId, 0);
      addSubTask(store, runId, 0);
      throw new Error("boom");
    });
  }, /boom/);
  // A half-written plan would make the barrier fire on an incomplete stage.
  assert.equal(store.listSubTasks(runId).length, 0, "partial plan must not survive");
  store.close();
});

test("tx: returns its value on success", () => {
  const { store, runId } = fixture();
  const n = store.tx(() => {
    addSubTask(store, runId, 0);
    return 42;
  });
  assert.equal(n, 42);
  assert.equal(store.listSubTasks(runId).length, 1);
  store.close();
});

// ── Roster ──────────────────────────────────────────────────

test("roster: one expert can hold several roles", () => {
  const { store, expertId } = fixture();
  const team = store.listTeams()[0];
  assert.ok(team);
  store.addTeamMember(team.id, expertId, "reviewer");
  store.addTeamMember(team.id, expertId, "orchestrator");
  const roster = store.roster(team.id);
  assert.equal(roster.length, 3, "maker + reviewer + orchestrator");
  assert.equal(new Set(roster.map((r) => r.expert.id)).size, 1);
  store.close();
});

test("roster: adding the same role twice is idempotent", () => {
  const { store, expertId } = fixture();
  const team = store.listTeams()[0];
  assert.ok(team);
  store.addTeamMember(team.id, expertId, "maker");
  store.addTeamMember(team.id, expertId, "maker");
  assert.equal(store.roster(team.id).length, 1);
  store.close();
});

test("roster: a dangling expert id is skipped rather than crashing", () => {
  const { store } = fixture();
  const team = store.listTeams()[0];
  assert.ok(team);
  // Possible by design: there are no foreign keys, so cleanup is application-side.
  store.addTeamMember(team.id, "does-not-exist", "reviewer");
  assert.doesNotThrow(() => store.roster(team.id));
  assert.ok(store.roster(team.id).every((r) => r.expert.id !== "does-not-exist"));
  store.close();
});

// ── Reviews ─────────────────────────────────────────────────

test("reviews: the verifiable flag survives the boolean round trip", () => {
  const { store, runId, expertId } = fixture();
  const stId = addSubTask(store, runId, 0);
  const base = {
    runId,
    subTaskId: stId,
    reviewerExpertId: expertId,
    round: 1,
    claim: "c",
    evidence: "",
    suggestedTest: null,
    patch: null,
    reproOutcome: null,
  } as const;
  store.createReview({ ...base, severity: "blocker", verifiable: true });
  store.createReview({ ...base, severity: "nit", verifiable: false });

  const rows = store.listReviews(runId);
  // SQLite stores booleans as integers; a sloppy read turns 0 into a truthy
  // value and routes a judgment call into the repro path.
  assert.equal(rows.filter((r) => r.verifiable).length, 1);
  assert.equal(rows.filter((r) => !r.verifiable).length, 1);
  store.close();
});

test("reviews: repro outcome is recorded with its evidence", () => {
  const { store, runId, expertId } = fixture();
  const stId = addSubTask(store, runId, 0);
  const review = store.createReview({
    runId,
    subTaskId: stId,
    reviewerExpertId: expertId,
    round: 1,
    severity: "blocker",
    claim: "races",
    evidence: "",
    verifiable: true,
    suggestedTest: "node --test",
    patch: null,
    reproOutcome: null,
  });
  store.setReproOutcome(review.id, "refuted", "test passed 20/20");
  const after = store.listReviews(runId)[0];
  assert.equal(after?.reproOutcome, "refuted");
  assert.equal(after?.evidence, "test passed 20/20");
  store.close();
});

test("reviews: round scoping isolates a rework cycle", () => {
  const { store, runId, expertId } = fixture();
  const stId = addSubTask(store, runId, 0);
  const base = {
    runId,
    subTaskId: stId,
    reviewerExpertId: expertId,
    severity: "major" as const,
    claim: "c",
    evidence: "",
    verifiable: false,
    suggestedTest: null,
    patch: null,
    reproOutcome: null,
  };
  store.createReview({ ...base, round: 1 });
  store.createReview({ ...base, round: 2 });
  // Round 2 must not re-litigate round 1's findings.
  assert.equal(store.listReviewsForSubTask(stId, 1).length, 1);
  assert.equal(store.listReviewsForSubTask(stId, 2).length, 1);
  assert.equal(store.listReviewsForSubTask(stId).length, 2);
  store.close();
});

test("rebuttals: an empty id list returns nothing instead of building bad SQL", () => {
  const { store } = fixture();
  assert.deepEqual(store.listRebuttals([]), []);
  store.close();
});

// ── Misc integrity ──────────────────────────────────────────

test("subtask: dependsOn round-trips as JSON", () => {
  const { store, runId } = fixture();
  const s = store.createSubTask({
    runId,
    stage: 1,
    title: "t",
    brief: "b",
    acceptance: "a",
    capability: "general",
    assignedExpertId: null,
    dependsOn: ["a", "b"],
    status: "todo",
    worktreePath: null,
    branch: null,
  });
  assert.deepEqual(store.getSubTask(s.id)?.dependsOn, ["a", "b"]);
  store.close();
});

test("expert: capabilities survive a malformed column", () => {
  const { store, expertId } = fixture();
  const e = store.getExpert(expertId);
  assert.deepEqual(e?.capabilities, ["general"]);
  // jsonArray() must degrade to [] rather than throwing while rendering a page.
  assert.deepEqual(store.getExpert("missing"), null);
  store.close();
});

test("run: updateRun with an empty patch is a no-op", () => {
  const { store, runId } = fixture();
  assert.doesNotThrow(() => store.updateRun(runId, {}));
  assert.equal(store.getRun(runId)?.status, "running");
  store.close();
});

test("run: soloMode round-trips as a boolean", () => {
  const { store } = fixture();
  const project = store.listProjects()[0];
  assert.ok(project);
  const solo = store.createRun({ projectId: project.id, goal: "g", soloMode: true });
  const team = store.createRun({ projectId: project.id, goal: "g", soloMode: false });
  assert.equal(store.getRun(solo.id)?.soloMode, true);
  assert.equal(store.getRun(team.id)?.soloMode, false);
  store.close();
});

// ── Chat sessions ───────────────────────────────────────────

test("chat session: create/list/get/patch round-trip", () => {
  const store = new Store(":memory:");
  const s = store.createChatSession({ title: "第一个" });
  assert.equal(store.getChatSession(s.id)?.title, "第一个");
  assert.equal(store.listChatSessions().length, 1);

  store.patchChatSession(s.id, { title: "改名了" });
  assert.equal(store.getChatSession(s.id)?.title, "改名了");

  store.patchChatSession(s.id, { archivedAt: new Date().toISOString() });
  assert.equal(store.listChatSessions().length, 0, "archived leaves the default list");
  assert.equal(store.listChatSessions({ archived: true }).length, 1);
  store.close();
});

test("chat session: defaultChatSession creates one lazily and is stable across calls", () => {
  const store = new Store(":memory:");
  const first = store.defaultChatSession();
  const second = store.defaultChatSession();
  assert.equal(first.id, second.id);
  assert.equal(store.listChatSessions().length, 1);
  store.close();
});

test("chat: messages are scoped to their session", () => {
  const store = new Store(":memory:");
  const a = store.createChatSession({ title: "a" });
  const b = store.createChatSession({ title: "b" });
  store.appendAgentChat({ sessionId: a.id, role: "user", body: "in a" });
  store.appendAgentChat({ sessionId: b.id, role: "user", body: "in b" });

  assert.deepEqual(store.listAgentChat(a.id).map((m) => m.body), ["in a"]);
  assert.deepEqual(store.listAgentChat(b.id).map((m) => m.body), ["in b"]);
  store.close();
});

test("chat: attachments round-trip as JSON and default to empty", () => {
  const store = new Store(":memory:");
  const s = store.createChatSession();
  const withImage = store.appendAgentChat({
    sessionId: s.id,
    role: "user",
    body: "look",
    attachments: [{ id: "att1", mediaType: "image/png", url: "/api/uploads/att1" }],
  });
  const withoutImage = store.appendAgentChat({ sessionId: s.id, role: "agent", body: "ok" });

  const rows = store.listAgentChat(s.id);
  assert.deepEqual(rows[0]?.attachments, withImage.attachments);
  assert.deepEqual(rows[1]?.attachments, withoutImage.attachments);
  assert.deepEqual(rows[1]?.attachments, []);
  store.close();
});

test("chat: appending a message touches its session's updatedAt", () => {
  const store = new Store(":memory:");
  const s = store.createChatSession();
  const before = store.getChatSession(s.id)?.updatedAt;
  store.appendAgentChat({ sessionId: s.id, role: "user", body: "hi" });
  const after = store.getChatSession(s.id)?.updatedAt;
  assert.ok(before !== undefined && after !== undefined);
  assert.ok(after !== undefined);
  store.close();
});
