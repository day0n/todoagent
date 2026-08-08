import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "./index.ts";

/**
 * Schema-upgrade regression tests.
 *
 * `CREATE TABLE IF NOT EXISTS` is a no-op on a table that already exists, so
 * every additive column silently skipped databases created before it. The
 * resulting failure was worse than a plain crash and is what these tests pin
 * down: reads degraded QUIETLY (a missing `subtask.branch` read back as null),
 * so a run would execute normally, produce real work, and then lose all of it at
 * merge time — while the write path failed with `no such column: branch`.
 */

/** Builds a database with the pre-`branch`, pre-`cost_usd` table definitions. */
async function legacyDb(): Promise<{ path: string; dispose: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-migrate-"));
  const path = join(dir, "legacy.db");
  const db = new DatabaseSync(path);

  db.exec(`CREATE TABLE subtask (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    stage INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL,
    brief TEXT NOT NULL,
    acceptance TEXT NOT NULL DEFAULT '',
    capability TEXT NOT NULL DEFAULT '',
    assigned_expert_id TEXT,
    depends_on TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL,
    worktree_path TEXT,
    created_at TEXT NOT NULL
  )`);
  db.exec(`CREATE TABLE attempt (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    subtask_id TEXT,
    expert_id TEXT NOT NULL,
    runtime_kind TEXT NOT NULL,
    kind TEXT NOT NULL,
    session_id TEXT,
    status TEXT NOT NULL,
    output TEXT,
    error TEXT,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    started_at TEXT NOT NULL,
    ended_at TEXT
  )`);

  /*
   * A `run` table WITHOUT the `diff` column.
   *
   * It has to exist here for the migration to be tested at all. `Store` runs
   * schema.sql before `migrate()`, and `CREATE TABLE IF NOT EXISTS` on a missing
   * table creates it with every current column — so a fixture lacking the table
   * entirely would exercise the create path and never the ALTER, while reporting
   * success either way.
   */
  db.exec(`CREATE TABLE run (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    goal TEXT NOT NULL,
    acceptance TEXT,
    status TEXT NOT NULL,
    phase TEXT NOT NULL,
    gate TEXT,
    budget_tokens INTEGER NOT NULL DEFAULT 0,
    spent_tokens INTEGER NOT NULL DEFAULT 0,
    solo_mode INTEGER NOT NULL DEFAULT 0,
    round INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    ended_at TEXT,
    error TEXT
  )`);

  /*
   * A `task` table as M1 first shipped it: no `note`, `my_day`, `due_date`,
   * `needs_kind` or `needs_text`.
   *
   * All five are in `migrate()`'s expected list and none of them was covered until
   * now — this fixture simply had no task table, so every one of those ALTERs took
   * the create path described above and reported success without running.
   */
  db.exec(`CREATE TABLE task (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'todo',
    assignee_kind TEXT,
    assignee_id TEXT,
    creator_kind TEXT NOT NULL DEFAULT 'human',
    creator_id TEXT,
    source_message_id TEXT,
    run_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )`);

  db.prepare(
    `INSERT INTO subtask (id,run_id,stage,title,brief,status,created_at) VALUES (?,?,?,?,?,?,?)`,
  ).run("s1", "r1", 0, "legacy subtask", "brief", "done", "2026-01-01T00:00:00.000Z");
  db.prepare(
    `INSERT INTO task (id,channel_id,title,status,creator_kind,run_id,created_at,updated_at)
     VALUES (?,?,?,?,?,?,?,?)`,
  ).run(
    "t1",
    "ch1",
    "legacy task",
    "todo",
    "human",
    "r1",
    "2026-01-01T00:00:00.000Z",
    "2026-01-01T00:00:00.000Z",
  );
  db.prepare(
    `INSERT INTO run (id,project_id,goal,status,phase,created_at) VALUES (?,?,?,?,?,?)`,
  ).run("r1", "p1", "legacy goal", "completed", "draft", "2026-01-01T00:00:00.000Z");
  db.prepare(
    `INSERT INTO attempt (id,run_id,subtask_id,expert_id,runtime_kind,kind,status,input_tokens,output_tokens,started_at)
     VALUES (?,?,?,?,?,?,?,?,?,?)`,
  ).run("a1", "r1", "s1", "e1", "claude", "draft", "completed", 100, 50, "2026-01-01T00:00:00.000Z");

  /*
   * `agent_chat` as it shipped before multi-session support: no `session_id`,
   * no `attachments`. This is what the default-session backfill exists for.
   */
  db.exec(`CREATE TABLE agent_chat (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL,
    body TEXT NOT NULL,
    task_refs TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL
  )`);
  db.prepare(
    `INSERT INTO agent_chat (id,role,body,created_at) VALUES (?,?,?,?)`,
  ).run("m1", "user", "老消息", "2026-01-01T00:00:00.000Z");
  db.close();

  return { path, dispose: () => rm(dir, { recursive: true, force: true }) };
}

test("migrate: an old database gains the branch column instead of crashing", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      // Reading used to work but silently return null, which is why the bug
      // survived: the pipeline ran to completion and only lost the work at merge.
      const rows = store.listSubTasks("r1");
      assert.equal(rows.length, 1, "the legacy row must survive the upgrade");
      assert.equal(rows[0]?.title, "legacy subtask");
      assert.equal(rows[0]?.branch, null, "a pre-existing row has no branch yet");

      // Writing is what used to throw `no such column: branch`.
      assert.doesNotThrow(() => store.updateSubTask("s1", { branch: "todoagent/recovered" }));
      assert.equal(store.getSubTask("s1")?.branch, "todoagent/recovered");
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: an old database gains cost_usd on attempt", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      const attempts = store.listAttempts("r1");
      assert.equal(attempts.length, 1);
      // Zero means "not reported", and a legacy row genuinely has no figure.
      assert.equal(attempts[0]?.costUsd, 0);
      assert.equal(attempts[0]?.inputTokens, 100, "existing token counts are untouched");

      assert.doesNotThrow(() =>
        store.finishAttempt("a1", { status: "completed", costUsd: 0.42, inputTokens: 100, outputTokens: 50 }),
      );
      assert.equal(store.listAttempts("r1")[0]?.costUsd, 0.42);
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: direct attempts allow a null expert without losing legacy attempts", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      const old = store.getAttempt("a1");
      assert.equal(old?.expertId, "e1", "the legacy expert reference survives the table rebuild");
      assert.equal(old?.runtimeKind, "claude");

      const direct = store.startAttempt({
        id: "a-direct",
        runId: "r1",
        subTaskId: null,
        expertId: null,
        runtimeKind: "claude",
        kind: "draft",
      });
      assert.equal(direct.expertId, null);
      assert.equal(store.getAttempt(direct.id)?.expertId, null, "NULL round-trips from SQLite");
    } finally {
      store.close();
    }

    // The second open must see the nullable schema and skip the destructive
    // rebuild while preserving both kinds of row.
    const reopened = new Store(legacy.path);
    try {
      assert.deepEqual(
        reopened.listAttempts("r1").map((attempt) => [attempt.id, attempt.expertId]),
        [
          ["a1", "e1"],
          ["a-direct", null],
        ],
      );
    } finally {
      reopened.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: runtime choice backfills run then task without inventing a path or version", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      const run = store.getRun("r1");
      assert.equal(run?.runtimeKind, "claude", "attempt runtime is the historical source of truth");
      assert.equal(run?.runtimeExecPath, null, "an old executable path cannot be reconstructed safely");
      assert.equal(run?.runtimeVersion, null, "an old CLI version cannot be reconstructed safely");
      assert.equal(store.getTask("t1")?.runtimeKind, "claude", "the linked run backfills its task");
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: an old database gains run.diff, and null stays distinct from empty", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      // The row survives the upgrade, and the write path is what used to throw
      // `no such column: diff`.
      assert.equal(store.getRun("r1")?.goal, "legacy goal", "the legacy run survives");
      assert.equal(store.getRunDiff("r1"), null, "a pre-existing run has no snapshot");

      assert.doesNotThrow(() => store.updateRun("r1", { diff: "diff --git a/x b/x\n+one" }));
      assert.match(store.getRunDiff("r1") ?? "", /diff --git/);

      /*
       * The distinction the result endpoint depends on.
       *
       * NULL means no snapshot was taken (the run failed, was cancelled, or predates
       * the column). An empty string means one WAS taken and the tree was clean.
       * Collapsing them would make the UI assert "this run changed no files" about a
       * failed run that had in fact edited several.
       */
      store.updateRun("r1", { diff: "" });
      assert.equal(store.getRunDiff("r1"), "", "an empty snapshot is not null");

      assert.equal(store.getRunDiff("no-such-run"), null, "an unknown id is null, not a throw");
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: an old task table gains every column added since M1", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      /*
       * The legacy row survives, and reads back with defaults rather than crashing.
       *
       * `note` is NOT NULL DEFAULT '' so SQLite backfills it; the four date and
       * needs columns are nullable and read as null. All five are what `toTask`
       * expects to find, and a missing one used to surface as
       * `no such column: due_date` on the WRITE path while reads degraded quietly.
       */
      const task = store.getTask("t1");
      assert.ok(task, "the legacy task survives the upgrade");
      assert.equal(task.title, "legacy task");
      assert.equal(task.note, "", "NOT NULL DEFAULT '' is backfilled");
      assert.equal(task.myDay, null);
      assert.equal(task.dueDate, null, "no deadline is the honest default for old rows");
      assert.equal(task.needsKind, null);
      assert.equal(task.needsText, null);
      assert.equal(task.workingDirectory, null);

      // The write path is the half that used to throw.
      assert.doesNotThrow(() =>
        store.updateTask("t1", { dueDate: "2026-08-10", myDay: "2026-08-04", note: "补的说明" }),
      );
      const after = store.getTask("t1");
      assert.equal(after?.dueDate, "2026-08-10");
      assert.equal(after?.myDay, "2026-08-04");
      assert.equal(after?.note, "补的说明");

      /*
       * Clearing is distinct from never having set one, and both are null here —
       * which is correct: "no deadline" has exactly one representation, unlike
       * `run.diff` where empty and null mean different things.
       */
      store.updateTask("t1", { dueDate: null });
      assert.equal(store.getTask("t1")?.dueDate, null, "a deadline can be removed");

      // A brand-new task on the upgraded database carries the column too.
      const fresh = store.createTask({
        channelId: "ch1",
        title: "新任务",
        status: "todo",
        dueDate: "2026-12-31",
        assigneeKind: null,
        assigneeId: null,
        creatorKind: "human",
        creatorId: null,
        sourceMessageId: null,
        runId: null,
      });
      assert.equal(store.getTask(fresh.id)?.dueDate, "2026-12-31");
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: an old database gains run.outcome_*, and unclassified stays distinct", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      /*
       * `kind: null` is a real answer, not a missing one.
       *
       * It means "nothing classified this run" — an old row, a failed run, or a
       * classifier that has not answered yet — and `syncTaskFromRun` reads it as the
       * M0 behaviour: a completed run becomes 待确认. If this returned a default of
       * `done` instead, the distinction would still hold today, but a future reader
       * could not tell "judged finished" from "never judged".
       */
      assert.deepEqual(store.getRunOutcome("r1"), { kind: null, text: null });

      // The write path is what used to throw `no such column: outcome_kind`.
      assert.doesNotThrow(() =>
        store.updateRun("r1", { outcomeKind: "question", outcomeText: "用哪个数据库？" }),
      );
      assert.deepEqual(store.getRunOutcome("r1"), {
        kind: "question",
        text: "用哪个数据库？",
      });

      /*
       * An unrecognised stored value degrades to null rather than passing through.
       *
       * The column is plain TEXT, so a future version writing a fourth kind — or a
       * hand-edited database — would otherwise put a card into a status no part of
       * the UI can render. Falling back to "a person looks at it" is the safe
       * direction.
       */
      store.updateRun("r1", { outcomeKind: "something_new" });
      assert.equal(store.getRunOutcome("r1").kind, null, "an unknown kind reads as unclassified");

      assert.deepEqual(store.getRunOutcome("no-such-run"), { kind: null, text: null });
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: an old agent_chat table gains session_id/attachments and backfills a default session", async () => {
  const legacy = await legacyDb();
  try {
    const store = new Store(legacy.path);
    try {
      // The pre-existing row must survive under some session rather than
      // vanishing from every session-scoped query.
      const sessions = store.listChatSessions();
      assert.equal(sessions.length, 1, "exactly one default session is created");
      const rows = store.listAgentChat(sessions[0]?.id ?? "");
      assert.equal(rows.length, 1);
      assert.equal(rows[0]?.body, "老消息");
      assert.deepEqual(rows[0]?.attachments, [], "a legacy row has no attachments");

      // The write path is what used to throw `no such column: session_id`.
      assert.doesNotThrow(() =>
        store.appendAgentChat({ sessionId: sessions[0]?.id ?? "", role: "agent", body: "新消息" }),
      );
    } finally {
      store.close();
    }
  } finally {
    await legacy.dispose();
  }
});

test("migrate: reopening is idempotent", async () => {
  const legacy = await legacyDb();
  try {
    const first = new Store(legacy.path);
    first.updateSubTask("s1", { branch: "todoagent/x" });
    first.close();

    // A second ALTER TABLE would fail with "duplicate column name".
    const second = new Store(legacy.path);
    try {
      assert.equal(second.getSubTask("s1")?.branch, "todoagent/x", "data persists across opens");
    } finally {
      second.close();
    }

    const third = new Store(legacy.path);
    third.close();
  } finally {
    await legacy.dispose();
  }
});

test("migrate: a fresh database needs no migration and works fully", async () => {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-fresh-"));
  try {
    const store = new Store(join(dir, "fresh.db"));
    try {
      const expert = store.createExpert({
        name: "T",
        description: "",
        runtimeKind: "claude",
        model: null,
        systemPrompt: "",
        capabilities: [],
      });
      const team = store.createTeam("t");
      store.addTeamMember(team.id, expert.id, "maker");
      const project = store.createProject({ name: "p", repoPath: dir, teamId: team.id });
      const run = store.createRun({ projectId: project.id, goal: "g" });
      const sub = store.createSubTask({
        runId: run.id,
        stage: 0,
        title: "t",
        brief: "b",
        acceptance: "a",
        capability: "general",
        assignedExpertId: expert.id,
        dependsOn: [],
        status: "todo",
        worktreePath: null,
        branch: "todoagent/fresh",
      });
      assert.equal(store.getSubTask(sub.id)?.branch, "todoagent/fresh");
    } finally {
      store.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("migrate: an in-memory database is fully formed", () => {
  // Every other test in the suite relies on this, so a regression here would
  // present as unrelated failures everywhere.
  const store = new Store(":memory:");
  try {
    const expert = store.createExpert({
      name: "T",
      description: "",
      runtimeKind: "codex",
      model: null,
      systemPrompt: "",
      capabilities: [],
    });
    const team = store.createTeam("t");
    store.addTeamMember(team.id, expert.id, "maker");
    const project = store.createProject({ name: "p", repoPath: "/tmp", teamId: team.id });
    const run = store.createRun({ projectId: project.id, goal: "g" });
    const attempt = store.startAttempt({
      runId: run.id,
      subTaskId: null,
      expertId: expert.id,
      runtimeKind: "codex",
      kind: "plan",
    });
    store.finishAttempt(attempt.id, { status: "completed", costUsd: 1.5 });
    assert.equal(store.listAttempts(run.id)[0]?.costUsd, 1.5);
  } finally {
    store.close();
  }
});

test("migrate: the seq index exists so appends stay flat", () => {
  const store = new Store(":memory:");
  try {
    /*
     * Guards the fix for a measured O(n^2) write path: appendEvent looks up
     * MAX(seq) per run, and without an index covering (run_id, seq) that scanned
     * every row of the run. Cost grew 34us -> 169us per event between 1k and 8k
     * events; with the index it stays flat at ~14us.
     */
    const expert = store.createExpert({
      name: "T",
      description: "",
      runtimeKind: "claude",
      model: null,
      systemPrompt: "",
      capabilities: [],
    });
    const team = store.createTeam("t");
    store.addTeamMember(team.id, expert.id, "maker");
    const project = store.createProject({ name: "p", repoPath: "/tmp", teamId: team.id });
    const run = store.createRun({ projectId: project.id, goal: "g" });

    for (let i = 0; i < 200; i++) {
      store.appendEvent({ runId: run.id, attemptId: null, type: "agent:text", payload: { i } });
    }
    const events = store.eventsAfter(run.id, 0, 500);
    assert.equal(events.length, 200);
    // seq must remain dense and ordered for replay to be coherent.
    assert.deepEqual(
      events.map((e) => e.seq).slice(0, 5),
      [1, 2, 3, 4, 5],
    );
    assert.equal(events.at(-1)?.seq, 200);
  } finally {
    store.close();
  }
});
