import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ActorKind,
  Adjudication,
  AgentChatAttachment,
  AgentChatMessage,
  Attempt,
  Channel,
  ChatSession,
  DiscussionMessage,
  Expert,
  ExpertRole,
  HumanGate,
  LocalRuntime,
  Message,
  MessageWithThread,
  Phase,
  Project,
  Rebuttal,
  Review,
  Run,
  RunOutcomeKind,
  RunStatus,
  RuntimeKind,
  SubTask,
  SubTaskStatus,
  Task,
  TaskStatus,
  Team,
  TeamMember,
} from "../types.ts";
import { TASK_STATUSES, TERMINAL_SUBTASK_STATUS } from "../types.ts";
import { RUNTIME_KINDS } from "../types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));

export function defaultDbPath(): string {
  const home = process.env["HOME"] ?? ".";
  return process.env["TODOAGENT_DB"] ?? join(home, ".todoagent", "todoagent.db");
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function newId(): string {
  return randomUUID();
}

/** Raw sqlite row values. */
type Row = Record<string, unknown>;

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function strOrNull(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}
function num(v: unknown): number {
  return typeof v === "number" ? v : typeof v === "bigint" ? Number(v) : 0;
}
function bool(v: unknown): boolean {
  return num(v) !== 0;
}
/**
 * Coerces a stored actor kind.
 *
 * Anything unrecognised becomes `human`, which is the safe direction: the only
 * privilege attached to `expert` is being resolved against the expert table, so
 * a corrupt value degrades to "the local person said this" rather than to a
 * dangling agent reference the UI would render as a blank author.
 */
function actorKind(v: unknown): ActorKind {
  return v === "expert" ? "expert" : "human";
}

function runtimeKindOrNull(v: unknown): RuntimeKind | null {
  return typeof v === "string" && (RUNTIME_KINDS as readonly string[]).includes(v)
    ? (v as RuntimeKind)
    : null;
}

function jsonArray(v: unknown): string[] {
  if (typeof v !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(v);
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function jsonAttachments(v: unknown): AgentChatAttachment[] {
  if (typeof v !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(v);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (x): x is AgentChatAttachment =>
        typeof x === "object" &&
        x !== null &&
        typeof (x as Record<string, unknown>)["id"] === "string" &&
        typeof (x as Record<string, unknown>)["mediaType"] === "string" &&
        typeof (x as Record<string, unknown>)["url"] === "string",
    );
  } catch {
    return [];
  }
}

export class Store {
  private readonly db: DatabaseSync;

  constructor(path: string = defaultDbPath()) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    const schema = readFileSync(join(HERE, "schema.sql"), "utf8");
    this.db.exec(schema);
    this.migrate();
    this.backfillDefaultChatSession();
  }

  /**
   * Adds columns that schema.sql declares but an existing database lacks.
   *
   * `CREATE TABLE IF NOT EXISTS` is a no-op on a table that already exists, so
   * every additive change silently skipped databases created before it. The
   * resulting failure was worse than a crash: reads degraded quietly (a missing
   * `subtask.branch` read back as null) so a run would execute normally, produce
   * real work, and then lose it at merge time — while the write path failed with
   * `no such column: branch`.
   *
   * Only additive, nullable-or-defaulted columns belong here. SQLite's ADD COLUMN
   * cannot introduce PRIMARY KEY, UNIQUE, or NOT NULL-without-default, and it is
   * a metadata-only operation, so this costs one PRAGMA read per table at open.
   * Indexes over newly migrated columns must be created after the ADD COLUMN
   * pass. Putting one in schema.sql makes opening an old database fail before
   * migration gets a chance to add that column.
   */
  private migrate(): void {
    const expected: Array<{ table: string; column: string; definition: string }> = [
      { table: "subtask", column: "branch", definition: "TEXT" },
      { table: "attempt", column: "cost_usd", definition: "REAL NOT NULL DEFAULT 0" },
      { table: "channel", column: "color", definition: "TEXT" },
      { table: "channel", column: "archived_at", definition: "TEXT" },
      { table: "task", column: "note", definition: "TEXT NOT NULL DEFAULT ''" },
      { table: "task", column: "my_day", definition: "TEXT" },
      { table: "task", column: "due_date", definition: "TEXT" },
      { table: "task", column: "needs_kind", definition: "TEXT" },
      { table: "task", column: "needs_text", definition: "TEXT" },
      { table: "task", column: "runtime_kind", definition: "TEXT" },
      { table: "task", column: "working_directory", definition: "TEXT" },
      { table: "run", column: "diff", definition: "TEXT" },
      { table: "run", column: "outcome_kind", definition: "TEXT" },
      { table: "run", column: "outcome_text", definition: "TEXT" },
      { table: "run", column: "runtime_kind", definition: "TEXT" },
      { table: "run", column: "runtime_exec_path", definition: "TEXT" },
      { table: "run", column: "runtime_version", definition: "TEXT" },
      { table: "run", column: "task_id", definition: "TEXT" },
      { table: "run", column: "parent_run_id", definition: "TEXT" },
      { table: "run", column: "trigger", definition: "TEXT" },
      { table: "run", column: "user_message", definition: "TEXT" },
      { table: "run", column: "repository_root", definition: "TEXT" },
      { table: "run", column: "working_directory", definition: "TEXT" },
      { table: "agent_chat", column: "session_id", definition: "TEXT" },
      { table: "agent_chat", column: "attachments", definition: "TEXT NOT NULL DEFAULT '[]'" },
    ];

    for (const { table, column, definition } of expected) {
      const info = this.db.prepare(`PRAGMA table_info(${table})`).all() as Row[];
      // An unknown table means schema.sql just created it with every column.
      if (info.length === 0) continue;
      if (info.some((c) => str(c["name"]) === column)) continue;
      this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
    }

    this.migrateAttemptExpertNullable();

    // Preserve the most reliable historical signal before falling back to the
    // old assignee. These statements are intentionally idempotent: only NULL
    // targets are touched, so reopening cannot overwrite a later explicit CLI.
    this.db.exec(`
      UPDATE run
         SET runtime_kind = (
           SELECT a.runtime_kind
             FROM attempt a
            WHERE a.run_id = run.id
            ORDER BY CASE WHEN a.subtask_id IS NULL THEN 0 ELSE 1 END,
                     a.started_at DESC
            LIMIT 1
         )
       WHERE runtime_kind IS NULL
         AND EXISTS (SELECT 1 FROM attempt a WHERE a.run_id = run.id);

      UPDATE task
         SET runtime_kind = COALESCE(
           (SELECT r.runtime_kind FROM run r WHERE r.id = task.run_id),
           (SELECT e.runtime_kind
              FROM expert e
             WHERE task.assignee_kind = 'expert' AND e.id = task.assignee_id)
         )
       WHERE runtime_kind IS NULL;

      UPDATE run
         SET task_id = (
           SELECT t.id FROM task t WHERE t.run_id = run.id LIMIT 1
         )
       WHERE task_id IS NULL
         AND EXISTS (SELECT 1 FROM task t WHERE t.run_id = run.id);
    `);

    // Deferred from schema.sql: it indexes a column that may have just been
    // added above, so creating it earlier would fail on a pre-existing table.
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_agent_chat_session ON agent_chat (session_id, seq)`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_run_task ON run (task_id, created_at)`);
  }

  /**
   * SQLite cannot drop a NOT NULL constraint in place, so old `attempt` tables
   * are rebuilt once. The full row is copied, including transcripts and usage;
   * the index is recreated only after the legacy table (and its old index) is
   * gone. A transaction makes an interrupted upgrade all-or-nothing.
   */
  private migrateAttemptExpertNullable(): void {
    const info = this.db.prepare(`PRAGMA table_info(attempt)`).all() as Row[];
    const expert = info.find((column) => str(column["name"]) === "expert_id");
    if (!expert || num(expert["notnull"]) === 0) return;

    this.db.exec(`
      BEGIN;
      ALTER TABLE attempt RENAME TO attempt_legacy_expert_required;
      CREATE TABLE attempt (
        id            TEXT PRIMARY KEY,
        run_id        TEXT NOT NULL,
        subtask_id    TEXT,
        expert_id     TEXT,
        runtime_kind  TEXT NOT NULL,
        kind          TEXT NOT NULL,
        session_id    TEXT,
        status        TEXT NOT NULL,
        output        TEXT,
        error         TEXT,
        input_tokens  INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd      REAL NOT NULL DEFAULT 0,
        started_at    TEXT NOT NULL,
        ended_at      TEXT
      );
      INSERT INTO attempt
        (id,run_id,subtask_id,expert_id,runtime_kind,kind,session_id,status,
         output,error,input_tokens,output_tokens,cost_usd,started_at,ended_at)
      SELECT
        id,run_id,subtask_id,expert_id,runtime_kind,kind,session_id,status,
        output,error,input_tokens,output_tokens,cost_usd,started_at,ended_at
        FROM attempt_legacy_expert_required;
      DROP TABLE attempt_legacy_expert_required;
      CREATE INDEX IF NOT EXISTS idx_attempt_run ON attempt (run_id, started_at);
      COMMIT;
    `);
  }

  /**
   * Ensures a default chat session exists and every pre-multi-session
   * `agent_chat` row points at it.
   *
   * Runs on every open, not just once, because it is cheap (two small queries
   * when there is nothing to do) and idempotent — the alternative, a one-time
   * migration flag, adds a place for the backfill to silently not happen on a
   * database that predates this flag's own introduction.
   */
  private backfillDefaultChatSession(): void {
    const orphans = this.db
      .prepare(`SELECT COUNT(*) AS n FROM agent_chat WHERE session_id IS NULL`)
      .get() as Row;
    if (num(orphans["n"]) === 0) return;
    const existing = this.db
      .prepare(`SELECT id FROM chat_session ORDER BY created_at LIMIT 1`)
      .get() as Row | undefined;
    const sessionId = existing ? str(existing["id"]) : this.createChatSession({ title: "默认会话" }).id;
    this.db
      .prepare(`UPDATE agent_chat SET session_id=? WHERE session_id IS NULL`)
      .run(sessionId);
  }

  close(): void {
    this.db.close();
  }

  /**
   * Runs `fn` inside a transaction.
   *
   * Because the schema carries no foreign keys, multi-table invariants (a run
   * and its subtasks, a review and its rebuttal) are only atomic if the caller
   * wraps them here.
   */
  tx<T>(fn: () => T): T {
    this.db.exec("BEGIN");
    try {
      const out = fn();
      this.db.exec("COMMIT");
      return out;
    } catch (err) {
      this.db.exec("ROLLBACK");
      throw err;
    }
  }

  // ── Experts ───────────────────────────────────────────────

  createExpert(e: Omit<Expert, "id" | "createdAt"> & { id?: string }): Expert {
    const row: Expert = {
      id: e.id ?? newId(),
      name: e.name,
      description: e.description,
      runtimeKind: e.runtimeKind,
      model: e.model,
      systemPrompt: e.systemPrompt,
      capabilities: e.capabilities,
      createdAt: nowIso(),
    };
    this.db
      .prepare(
        `INSERT INTO expert (id,name,description,runtime_kind,model,system_prompt,capabilities,created_at)
         VALUES (?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.name,
        row.description,
        row.runtimeKind,
        row.model,
        row.systemPrompt,
        JSON.stringify(row.capabilities),
        row.createdAt,
      );
    return row;
  }

  private toExpert(r: Row): Expert {
    return {
      id: str(r["id"]),
      name: str(r["name"]),
      description: str(r["description"]),
      runtimeKind: str(r["runtime_kind"]) as Expert["runtimeKind"],
      model: strOrNull(r["model"]),
      systemPrompt: str(r["system_prompt"]),
      capabilities: jsonArray(r["capabilities"]),
      createdAt: str(r["created_at"]),
    };
  }

  listExperts(): Expert[] {
    return this.db
      .prepare(`SELECT * FROM expert ORDER BY name`)
      .all()
      .map((r) => this.toExpert(r as Row));
  }

  getExpert(id: string): Expert | null {
    const r = this.db.prepare(`SELECT * FROM expert WHERE id=?`).get(id);
    return r ? this.toExpert(r as Row) : null;
  }

  getExpertByName(name: string): Expert | null {
    const r = this.db.prepare(`SELECT * FROM expert WHERE name=?`).get(name);
    return r ? this.toExpert(r as Row) : null;
  }

  // ── Teams ─────────────────────────────────────────────────

  createTeam(name: string, id?: string): Team {
    const row: Team = { id: id ?? newId(), name, createdAt: nowIso() };
    this.db.prepare(`INSERT INTO team (id,name,created_at) VALUES (?,?,?)`).run(row.id, row.name, row.createdAt);
    return row;
  }

  getTeamByName(name: string): Team | null {
    const r = this.db.prepare(`SELECT * FROM team WHERE name=?`).get(name) as Row | undefined;
    return r ? { id: str(r["id"]), name: str(r["name"]), createdAt: str(r["created_at"]) } : null;
  }

  listTeams(): Team[] {
    return this.db
      .prepare(`SELECT * FROM team ORDER BY name`)
      .all()
      .map((raw) => {
        const r = raw as Row;
        return { id: str(r["id"]), name: str(r["name"]), createdAt: str(r["created_at"]) };
      });
  }

  addTeamMember(teamId: string, expertId: string, role: ExpertRole): void {
    this.db
      .prepare(`INSERT OR REPLACE INTO team_member (team_id,expert_id,role) VALUES (?,?,?)`)
      .run(teamId, expertId, role);
  }

  listTeamMembers(teamId: string): TeamMember[] {
    return this.db
      .prepare(`SELECT * FROM team_member WHERE team_id=?`)
      .all(teamId)
      .map((raw) => {
        const r = raw as Row;
        return {
          teamId: str(r["team_id"]),
          expertId: str(r["expert_id"]),
          role: str(r["role"]) as ExpertRole,
        };
      });
  }

  /** Roster with expert records resolved, for prompt building and routing. */
  roster(teamId: string): Array<{ member: TeamMember; expert: Expert }> {
    const out: Array<{ member: TeamMember; expert: Expert }> = [];
    for (const member of this.listTeamMembers(teamId)) {
      const expert = this.getExpert(member.expertId);
      if (expert) out.push({ member, expert });
    }
    return out;
  }

  // ── Projects ──────────────────────────────────────────────

  createProject(p: Omit<Project, "id" | "createdAt"> & { id?: string }): Project {
    const row: Project = { id: p.id ?? newId(), name: p.name, repoPath: p.repoPath, teamId: p.teamId, createdAt: nowIso() };
    this.db
      .prepare(`INSERT INTO project (id,name,repo_path,team_id,created_at) VALUES (?,?,?,?,?)`)
      .run(row.id, row.name, row.repoPath, row.teamId, row.createdAt);
    return row;
  }

  private toProject(r: Row): Project {
    return {
      id: str(r["id"]),
      name: str(r["name"]),
      repoPath: str(r["repo_path"]),
      teamId: str(r["team_id"]),
      createdAt: str(r["created_at"]),
    };
  }

  getProject(id: string): Project | null {
    const r = this.db.prepare(`SELECT * FROM project WHERE id=?`).get(id);
    return r ? this.toProject(r as Row) : null;
  }

  listProjects(): Project[] {
    return this.db
      .prepare(`SELECT * FROM project ORDER BY created_at DESC`)
      .all()
      .map((r) => this.toProject(r as Row));
  }

  // ── Local runtimes ────────────────────────────────────────

  private toLocalRuntime(r: Row): LocalRuntime {
    const kind = runtimeKindOrNull(r["kind"]);
    if (kind === null) throw new Error(`invalid local runtime kind: ${str(r["kind"])}`);
    const rawStatus = str(r["status"]);
    const status: LocalRuntime["status"] =
      rawStatus === "missing" ||
      rawStatus === "unverified" ||
      rawStatus === "verifying" ||
      rawStatus === "ready" ||
      rawStatus === "auth_required" ||
      rawStatus === "error"
        ? rawStatus
        : "error";
    return {
      kind,
      execPath: strOrNull(r["exec_path"]),
      version: strOrNull(r["version"]),
      status,
      detectedAt: strOrNull(r["detected_at"]),
      verifiedAt: strOrNull(r["verified_at"]),
      verifyError: strOrNull(r["verify_error"]),
    };
  }

  upsertLocalRuntime(runtime: LocalRuntime): LocalRuntime {
    this.db
      .prepare(
        `INSERT INTO local_runtime
           (kind,exec_path,version,status,detected_at,verified_at,verify_error)
         VALUES (?,?,?,?,?,?,?)
         ON CONFLICT(kind) DO UPDATE SET
           exec_path=excluded.exec_path,
           version=excluded.version,
           status=excluded.status,
           detected_at=excluded.detected_at,
           verified_at=excluded.verified_at,
           verify_error=excluded.verify_error`,
      )
      .run(
        runtime.kind,
        runtime.execPath,
        runtime.version,
        runtime.status,
        runtime.detectedAt,
        runtime.verifiedAt,
        runtime.verifyError,
      );
    return runtime;
  }

  getLocalRuntime(kind: RuntimeKind): LocalRuntime | null {
    const row = this.db.prepare(`SELECT * FROM local_runtime WHERE kind=?`).get(kind);
    return row ? this.toLocalRuntime(row as Row) : null;
  }

  listLocalRuntimes(): LocalRuntime[] {
    const rows = this.db.prepare(`SELECT * FROM local_runtime`).all() as Row[];
    const byKind = new Map(rows.map((row) => [str(row["kind"]), row]));
    // Product order is stable and includes missing rows once the manager has
    // initialized them; unknown/corrupt kinds are deliberately ignored.
    return RUNTIME_KINDS.flatMap((kind) => {
      const row = byKind.get(kind);
      return row ? [this.toLocalRuntime(row)] : [];
    });
  }

  // ── Runs ──────────────────────────────────────────────────

  createRun(r: {
    projectId: string;
    taskId?: string | null;
    parentRunId?: string | null;
    trigger?: Run["trigger"];
    userMessage?: string | null;
    repositoryRoot?: string | null;
    workingDirectory?: string | null;
    goal: string;
    acceptance?: string | null;
    budgetTokens?: number;
    soloMode?: boolean;
    runtimeKind?: RuntimeKind | null;
    runtimeExecPath?: string | null;
    runtimeVersion?: string | null;
    id?: string;
  }): Run {
    const row: Run = {
      id: r.id ?? newId(),
      projectId: r.projectId,
      taskId: r.taskId ?? null,
      parentRunId: r.parentRunId ?? null,
      trigger: r.trigger ?? null,
      userMessage: r.userMessage ?? null,
      repositoryRoot: r.repositoryRoot ?? null,
      workingDirectory: r.workingDirectory ?? null,
      goal: r.goal,
      acceptance: r.acceptance ?? null,
      status: "running",
      phase: "plan",
      gate: null,
      budgetTokens: r.budgetTokens ?? 2_000_000,
      spentTokens: 0,
      soloMode: r.soloMode ?? false,
      round: 0,
      createdAt: nowIso(),
      endedAt: null,
      error: null,
      runtimeKind: r.runtimeKind ?? null,
      runtimeExecPath: r.runtimeExecPath ?? null,
      runtimeVersion: r.runtimeVersion ?? null,
    };
    this.db
      .prepare(
        `INSERT INTO run (id,project_id,task_id,parent_run_id,trigger,user_message,repository_root,working_directory,goal,acceptance,status,phase,gate,budget_tokens,spent_tokens,solo_mode,round,created_at,ended_at,error,runtime_kind,runtime_exec_path,runtime_version)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.projectId,
        row.taskId,
        row.parentRunId,
        row.trigger,
        row.userMessage,
        row.repositoryRoot,
        row.workingDirectory,
        row.goal,
        row.acceptance,
        row.status,
        row.phase,
        row.gate,
        row.budgetTokens,
        row.spentTokens,
        row.soloMode ? 1 : 0,
        row.round,
        row.createdAt,
        row.endedAt,
        row.error,
        row.runtimeKind,
        row.runtimeExecPath,
        row.runtimeVersion,
      );
    return row;
  }

  private toRun(r: Row): Run {
    return {
      id: str(r["id"]),
      projectId: str(r["project_id"]),
      taskId: strOrNull(r["task_id"]),
      parentRunId: strOrNull(r["parent_run_id"]),
      trigger:
        r["trigger"] === "dispatch" || r["trigger"] === "task_chat"
          ? (r["trigger"] as Run["trigger"])
          : null,
      userMessage: strOrNull(r["user_message"]),
      repositoryRoot: strOrNull(r["repository_root"]),
      workingDirectory: strOrNull(r["working_directory"]),
      goal: str(r["goal"]),
      acceptance: strOrNull(r["acceptance"]),
      status: str(r["status"]) as RunStatus,
      phase: str(r["phase"]) as Phase,
      gate: strOrNull(r["gate"]) as HumanGate | null,
      budgetTokens: num(r["budget_tokens"]),
      spentTokens: num(r["spent_tokens"]),
      soloMode: bool(r["solo_mode"]),
      round: num(r["round"]),
      createdAt: str(r["created_at"]),
      endedAt: strOrNull(r["ended_at"]),
      error: strOrNull(r["error"]),
      runtimeKind: runtimeKindOrNull(r["runtime_kind"]),
      runtimeExecPath: strOrNull(r["runtime_exec_path"]),
      runtimeVersion: strOrNull(r["runtime_version"]),
    };
  }

  getRun(id: string): Run | null {
    const r = this.db.prepare(`SELECT * FROM run WHERE id=?`).get(id);
    return r ? this.toRun(r as Row) : null;
  }

  /**
   * The run's working-tree snapshot, read on its own.
   *
   * Separate from `getRun` because it is up to 2M characters and is wanted in
   * exactly one place — the result drawer, when a person asks to see what changed.
   * `getRun` is called on nearly every request, `GET /api/runs` calls it for up to
   * 100 rows, and the SSE path re-reads it constantly; none of them want this.
   *
   * Null means "nothing was captured" (the run failed, was cancelled, or predates
   * the column). An empty string means "captured, and the tree was clean" — a
   * distinction the caller has to keep, since the second is a real answer about a
   * run that legitimately changed no files.
   */
  getRunDiff(id: string): string | null {
    const r = this.db.prepare(`SELECT diff FROM run WHERE id=?`).get(id) as Row | undefined;
    if (r === undefined) return null;
    return strOrNull(r["diff"]);
  }

  /**
   * What a completed run's output amounted to, if anything classified it.
   *
   * `kind: null` means "never classified" — an older run, a failed one, or a
   * classifier that has not answered yet — and callers must read that as the M0
   * behaviour (a completed run becomes 待确认). An unrecognised stored value is
   * coerced to null for the same reason: degrading to "a person looks at it" is
   * safe, whereas passing an unknown string through would put a card into a state
   * no part of the UI can render.
   */
  getRunOutcome(id: string): { kind: RunOutcomeKind | null; text: string | null } {
    const r = this.db
      .prepare(`SELECT outcome_kind, outcome_text FROM run WHERE id=?`)
      .get(id) as Row | undefined;
    if (r === undefined) return { kind: null, text: null };
    const raw = strOrNull(r["outcome_kind"]);
    const kind =
      raw === "done" || raw === "question" || raw === "blocked" ? raw : null;
    return { kind, text: strOrNull(r["outcome_text"]) };
  }

  listRuns(limit = 50): Run[] {
    return this.db
      .prepare(`SELECT * FROM run ORDER BY created_at DESC LIMIT ?`)
      .all(limit)
      .map((r) => this.toRun(r as Row));
  }

  /** Immutable turns in one task conversation, oldest first. */
  listRunsForTask(taskId: string): Run[] {
    return this.db
      .prepare(`SELECT * FROM run WHERE task_id=? ORDER BY created_at, id`)
      .all(taskId)
      .map((r) => this.toRun(r as Row));
  }

  /**
   * Runs the database still believes are executing.
   *
   * Used for startup reconciliation. A `running` row is only true while some
   * process is actually driving it, and that fact lives in memory — so after a
   * crash or restart these rows are stale and must be resolved, or the UI shows
   * "in progress" forever on work nothing is doing.
   *
   * Deliberately NOT limited: every stale row has to be found, not just the most
   * recent page of them.
   */
  listRunningRuns(): Run[] {
    return this.db
      .prepare(`SELECT * FROM run WHERE status='running' ORDER BY created_at`)
      .all()
      .map((r) => this.toRun(r as Row));
  }

  updateRun(
    id: string,
    patch: Partial<
      Pick<
        Run,
        "status" | "phase" | "gate" | "round" | "endedAt" | "error" | "spentTokens" | "goal"
      >
    > & {
      /**
       * Working-tree snapshot, written once when a direct run completes.
       *
       * An intersection rather than a member of `Run`, which is the point. `toRun`
       * maps every field of that interface, and `GET /api/runs` spreads whole Run
       * objects for up to 100 rows — so a 2M-character diff on the type would put
       * up to 200MB in one list response. This codebase already learned that with
       * `attempt.output`: measured at 211 KB of a 292 KB payload, for text the
       * overview never rendered, refetched on every event. Read it deliberately
       * through `getRunDiff` instead.
       */
      diff?: string;
      /**
       * What the worker's final output amounted to, and the text explaining it.
       *
       * Off the `Run` interface for the same reason as `diff`, though not for size:
       * a card's fate is decided in exactly one place, and a field on the type would
       * invite every reader of a run to form its own opinion about whether the work
       * is really finished. Read it through `getRunOutcome`.
       */
      outcomeKind?: string;
      outcomeText?: string;
    },
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      status: "status",
      phase: "phase",
      gate: "gate",
      round: "round",
      endedAt: "ended_at",
      error: "error",
      spentTokens: "spent_tokens",
      // Rewritten in exactly one situation: a resumed run whose CLI rejected the
      // session id, retried cold with a prompt that carries the context the session
      // would have supplied. The row must describe the prompt actually sent.
      goal: "goal",
      diff: "diff",
      outcomeKind: "outcome_kind",
      outcomeText: "outcome_text",
    };
    const sets: string[] = [];
    const vals: Array<string | number | null> = [];
    for (const [k, col] of Object.entries(cols) as Array<[keyof typeof patch, string]>) {
      const v = patch[k];
      if (v === undefined) continue;
      sets.push(`${col}=?`);
      vals.push(v as string | number | null);
    }
    if (sets.length === 0) return;
    vals.push(id);
    this.db.prepare(`UPDATE run SET ${sets.join(",")} WHERE id=?`).run(...vals);
  }

  /** Adds to the spend counter and reports whether the ceiling is now breached. */
  addSpend(runId: string, tokens: number): { spent: number; exceeded: boolean } {
    this.db.prepare(`UPDATE run SET spent_tokens = spent_tokens + ? WHERE id=?`).run(tokens, runId);
    const run = this.getRun(runId);
    if (!run) return { spent: 0, exceeded: false };
    return { spent: run.spentTokens, exceeded: run.budgetTokens > 0 && run.spentTokens >= run.budgetTokens };
  }

  // ── Subtasks ──────────────────────────────────────────────

  createSubTask(s: Omit<SubTask, "id" | "createdAt"> & { id?: string }): SubTask {
    const row: SubTask = { ...s, id: s.id ?? newId(), createdAt: nowIso() };
    this.db
      .prepare(
        `INSERT INTO subtask (id,run_id,stage,title,brief,acceptance,capability,assigned_expert_id,depends_on,status,worktree_path,branch,created_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.runId,
        row.stage,
        row.title,
        row.brief,
        row.acceptance,
        row.capability,
        row.assignedExpertId,
        JSON.stringify(row.dependsOn),
        row.status,
        row.worktreePath,
        row.branch,
        row.createdAt,
      );
    return row;
  }

  private toSubTask(r: Row): SubTask {
    return {
      id: str(r["id"]),
      runId: str(r["run_id"]),
      stage: num(r["stage"]),
      title: str(r["title"]),
      brief: str(r["brief"]),
      acceptance: str(r["acceptance"]),
      capability: str(r["capability"]),
      assignedExpertId: strOrNull(r["assigned_expert_id"]),
      dependsOn: jsonArray(r["depends_on"]),
      status: str(r["status"]) as SubTaskStatus,
      worktreePath: strOrNull(r["worktree_path"]),
      branch: strOrNull(r["branch"]),
      createdAt: str(r["created_at"]),
    };
  }

  listSubTasks(runId: string): SubTask[] {
    return this.db
      .prepare(`SELECT * FROM subtask WHERE run_id=? ORDER BY stage, created_at`)
      .all(runId)
      .map((r) => this.toSubTask(r as Row));
  }

  getSubTask(id: string): SubTask | null {
    const r = this.db.prepare(`SELECT * FROM subtask WHERE id=?`).get(id);
    return r ? this.toSubTask(r as Row) : null;
  }

  updateSubTask(
    id: string,
    patch: Partial<Pick<SubTask, "status" | "worktreePath" | "assignedExpertId" | "branch">>,
  ): void {
    const sets: string[] = [];
    const vals: Array<string | null> = [];
    if (patch.status !== undefined) {
      sets.push("status=?");
      vals.push(patch.status);
    }
    if (patch.worktreePath !== undefined) {
      sets.push("worktree_path=?");
      vals.push(patch.worktreePath);
    }
    if (patch.assignedExpertId !== undefined) {
      sets.push("assigned_expert_id=?");
      vals.push(patch.assignedExpertId);
    }
    if (patch.branch !== undefined) {
      sets.push("branch=?");
      vals.push(patch.branch);
    }
    if (sets.length === 0) return;
    vals.push(id);
    this.db.prepare(`UPDATE subtask SET ${sets.join(",")} WHERE id=?`).run(...vals);
  }

  /**
   * The stage barrier: is every subtask in this stage terminal?
   *
   * This is the join Multica implements as a staged child-done wake, and the one
   * Raft documents that it does NOT do — leaving its human to hold downstream
   * work back by hand.
   */
  stageComplete(runId: string, stage: number): boolean {
    const rows = this.db
      .prepare(`SELECT status FROM subtask WHERE run_id=? AND stage=?`)
      .all(runId, stage) as Row[];
    if (rows.length === 0) return true;
    return rows.every((r) => TERMINAL_SUBTASK_STATUS.has(str(r["status"])));
  }

  stages(runId: string): number[] {
    const rows = this.db
      .prepare(`SELECT DISTINCT stage FROM subtask WHERE run_id=? ORDER BY stage`)
      .all(runId) as Row[];
    return rows.map((r) => num(r["stage"]));
  }

  // ── Attempts ──────────────────────────────────────────────

  startAttempt(a: {
    runId: string;
    subTaskId: string | null;
    expertId?: string | null;
    runtimeKind: Attempt["runtimeKind"];
    kind: Attempt["kind"];
    id?: string;
  }): Attempt {
    const row: Attempt = {
      id: a.id ?? newId(),
      runId: a.runId,
      subTaskId: a.subTaskId,
      expertId: a.expertId ?? null,
      runtimeKind: a.runtimeKind,
      kind: a.kind,
      sessionId: null,
      status: "running",
      output: null,
      error: null,
      inputTokens: 0,
      outputTokens: 0,
      costUsd: 0,
      startedAt: nowIso(),
      endedAt: null,
    };
    this.db
      .prepare(
        `INSERT INTO attempt (id,run_id,subtask_id,expert_id,runtime_kind,kind,session_id,status,output,error,input_tokens,output_tokens,cost_usd,started_at,ended_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.runId,
        row.subTaskId,
        row.expertId,
        row.runtimeKind,
        row.kind,
        row.sessionId,
        row.status,
        row.output,
        row.error,
        0,
        0,
        0,
        row.startedAt,
        row.endedAt,
      );
    return row;
  }

  finishAttempt(
    id: string,
    patch: {
      status: Attempt["status"];
      output?: string | null;
      error?: string | null;
      sessionId?: string | null;
      inputTokens?: number;
      outputTokens?: number;
      costUsd?: number;
    },
  ): void {
    this.db
      .prepare(
        `UPDATE attempt SET status=?, output=?, error=?, session_id=?, input_tokens=?, output_tokens=?, cost_usd=?, ended_at=? WHERE id=?`,
      )
      .run(
        patch.status,
        patch.output ?? null,
        patch.error ?? null,
        patch.sessionId ?? null,
        patch.inputTokens ?? 0,
        patch.outputTokens ?? 0,
        patch.costUsd ?? 0,
        nowIso(),
        id,
      );
  }

  /**
   * One attempt WITH its full output.
   *
   * Separate from `listAttempts` because the run endpoint deliberately strips
   * output — 72% of a measured 292 KB payload, refetched on every structural
   * event, for text the overview never renders. Fetching a transcript is an
   * explicit, one-at-a-time action instead.
   */
  getAttempt(id: string): Attempt | null {
    const r = this.db.prepare(`SELECT * FROM attempt WHERE id=?`).get(id) as Row | undefined;
    if (!r) return null;
    return {
      id: str(r["id"]),
      runId: str(r["run_id"]),
      subTaskId: strOrNull(r["subtask_id"]),
      expertId: strOrNull(r["expert_id"]),
      runtimeKind: str(r["runtime_kind"]) as Attempt["runtimeKind"],
      kind: str(r["kind"]) as Attempt["kind"],
      sessionId: strOrNull(r["session_id"]),
      status: str(r["status"]) as Attempt["status"],
      output: strOrNull(r["output"]),
      error: strOrNull(r["error"]),
      inputTokens: num(r["input_tokens"]),
      outputTokens: num(r["output_tokens"]),
      costUsd: num(r["cost_usd"]),
      startedAt: str(r["started_at"]),
      endedAt: strOrNull(r["ended_at"]),
    };
  }

  listAttempts(runId: string): Attempt[] {
    return this.db
      .prepare(`SELECT * FROM attempt WHERE run_id=? ORDER BY started_at`)
      .all(runId)
      .map((raw) => {
        const r = raw as Row;
        return {
          id: str(r["id"]),
          runId: str(r["run_id"]),
          subTaskId: strOrNull(r["subtask_id"]),
          expertId: strOrNull(r["expert_id"]),
          runtimeKind: str(r["runtime_kind"]) as Attempt["runtimeKind"],
          kind: str(r["kind"]) as Attempt["kind"],
          sessionId: strOrNull(r["session_id"]),
          status: str(r["status"]) as Attempt["status"],
          output: strOrNull(r["output"]),
          error: strOrNull(r["error"]),
          inputTokens: num(r["input_tokens"]),
          outputTokens: num(r["output_tokens"]),
          // Persisted by finishAttempt but previously never read back, so a
          // runtime's own price statement was recorded and then invisible.
          costUsd: num(r["cost_usd"]),
          startedAt: str(r["started_at"]),
          endedAt: strOrNull(r["ended_at"]),
        };
      });
  }

  // ── Events (append-only) ──────────────────────────────────

  appendEvent(e: { runId: string; attemptId: string | null; type: string; payload: unknown }): number {
    const seqRow = this.db
      .prepare(`SELECT COALESCE(MAX(seq),0) AS s FROM event WHERE run_id=?`)
      .get(e.runId) as Row | undefined;
    const seq = num(seqRow?.["s"]) + 1;
    this.db
      .prepare(`INSERT INTO event (run_id,attempt_id,seq,type,payload,created_at) VALUES (?,?,?,?,?,?)`)
      .run(e.runId, e.attemptId, seq, e.type, JSON.stringify(e.payload ?? null), nowIso());
    const idRow = this.db.prepare(`SELECT last_insert_rowid() AS id`).get() as Row | undefined;
    return num(idRow?.["id"]);
  }

  /** Events after `afterId`, for SSE replay on reconnect. */
  eventsAfter(runId: string, afterId: number, limit = 500): Array<{
    id: number;
    attemptId: string | null;
    seq: number;
    type: string;
    payload: unknown;
    createdAt: string;
  }> {
    return this.db
      .prepare(`SELECT * FROM event WHERE run_id=? AND id>? ORDER BY id LIMIT ?`)
      .all(runId, afterId, limit)
      .map((raw) => {
        const r = raw as Row;
        let payload: unknown = null;
        try {
          payload = JSON.parse(str(r["payload"]));
        } catch {
          payload = null;
        }
        return {
          id: num(r["id"]),
          attemptId: strOrNull(r["attempt_id"]),
          seq: num(r["seq"]),
          type: str(r["type"]),
          payload,
          createdAt: str(r["created_at"]),
        };
      });
  }

  // ── Reviews / rebuttals / adjudications / discussion ──────

  createReview(r: Omit<Review, "id" | "createdAt"> & { id?: string }): Review {
    const row: Review = { ...r, id: r.id ?? newId(), createdAt: nowIso() };
    this.db
      .prepare(
        `INSERT INTO review (id,run_id,subtask_id,reviewer_expert_id,round,severity,claim,evidence,verifiable,suggested_test,patch,repro_outcome,created_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.runId,
        row.subTaskId,
        row.reviewerExpertId,
        row.round,
        row.severity,
        row.claim,
        row.evidence,
        row.verifiable ? 1 : 0,
        row.suggestedTest,
        row.patch,
        row.reproOutcome,
        row.createdAt,
      );
    return row;
  }

  private toReview(r: Row): Review {
    return {
      id: str(r["id"]),
      runId: str(r["run_id"]),
      subTaskId: str(r["subtask_id"]),
      reviewerExpertId: str(r["reviewer_expert_id"]),
      round: num(r["round"]),
      severity: str(r["severity"]) as Review["severity"],
      claim: str(r["claim"]),
      evidence: str(r["evidence"]),
      verifiable: bool(r["verifiable"]),
      suggestedTest: strOrNull(r["suggested_test"]),
      patch: strOrNull(r["patch"]),
      reproOutcome: strOrNull(r["repro_outcome"]) as Review["reproOutcome"],
      createdAt: str(r["created_at"]),
    };
  }

  listReviews(runId: string): Review[] {
    return this.db
      .prepare(`SELECT * FROM review WHERE run_id=? ORDER BY created_at`)
      .all(runId)
      .map((r) => this.toReview(r as Row));
  }

  listReviewsForSubTask(subTaskId: string, round?: number): Review[] {
    const sql =
      round === undefined
        ? `SELECT * FROM review WHERE subtask_id=? ORDER BY created_at`
        : `SELECT * FROM review WHERE subtask_id=? AND round=? ORDER BY created_at`;
    const args = round === undefined ? [subTaskId] : [subTaskId, round];
    return this.db
      .prepare(sql)
      .all(...args)
      .map((r) => this.toReview(r as Row));
  }

  setReproOutcome(reviewId: string, outcome: NonNullable<Review["reproOutcome"]>, evidence: string): void {
    this.db
      .prepare(`UPDATE review SET repro_outcome=?, evidence=? WHERE id=?`)
      .run(outcome, evidence, reviewId);
  }

  createRebuttal(r: Omit<Rebuttal, "id" | "createdAt"> & { id?: string }): void {
    this.db
      .prepare(`INSERT INTO rebuttal (id,review_id,author_expert_id,decision,reason,created_at) VALUES (?,?,?,?,?,?)`)
      .run(r.id ?? newId(), r.reviewId, r.authorExpertId, r.decision, r.reason, nowIso());
  }

  listRebuttals(reviewIds: string[]): Rebuttal[] {
    if (reviewIds.length === 0) return [];
    const placeholders = reviewIds.map(() => "?").join(",");
    return this.db
      .prepare(`SELECT * FROM rebuttal WHERE review_id IN (${placeholders}) ORDER BY created_at`)
      .all(...reviewIds)
      .map((raw) => {
        const r = raw as Row;
        return {
          id: str(r["id"]),
          reviewId: str(r["review_id"]),
          authorExpertId: str(r["author_expert_id"]),
          decision: str(r["decision"]) as Rebuttal["decision"],
          reason: str(r["reason"]),
          createdAt: str(r["created_at"]),
        };
      });
  }

  createAdjudication(a: Omit<Adjudication, "id" | "createdAt"> & { id?: string }): Adjudication {
    const row: Adjudication = { ...a, id: a.id ?? newId(), createdAt: nowIso() };
    this.db
      .prepare(
        `INSERT INTO adjudication (id,run_id,subtask_id,round,verdict,rationale,escalated_to_human,human_decision,created_at)
         VALUES (?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.runId,
        row.subTaskId,
        row.round,
        row.verdict,
        row.rationale,
        row.escalatedToHuman ? 1 : 0,
        row.humanDecision,
        row.createdAt,
      );
    return row;
  }

  listAdjudications(runId: string): Adjudication[] {
    return this.db
      .prepare(`SELECT * FROM adjudication WHERE run_id=? ORDER BY created_at`)
      .all(runId)
      .map((raw) => this.toAdjudication(raw as Row));
  }

  getAdjudication(id: string): Adjudication | null {
    const r = this.db.prepare(`SELECT * FROM adjudication WHERE id=?`).get(id) as Row | undefined;
    return r ? this.toAdjudication(r) : null;
  }

  /**
   * Records a human decision and returns the adjudication it belongs to.
   *
   * The row is returned because the caller needs its `subTaskId` to resume the
   * blocked work. Writing the decision and stopping there was a dead end: nothing
   * read it, so the subtask stayed `blocked` forever and the run's central
   * promise — a human settles what no test can — never completed.
   */
  resolveEscalation(adjudicationId: string, decision: string): Adjudication | null {
    this.db
      .prepare(`UPDATE adjudication SET human_decision=? WHERE id=?`)
      .run(decision, adjudicationId);
    return this.getAdjudication(adjudicationId);
  }

  private toAdjudication(r: Row): Adjudication {
    return {
      id: str(r["id"]),
      runId: str(r["run_id"]),
      subTaskId: str(r["subtask_id"]),
      round: num(r["round"]),
      verdict: str(r["verdict"]) as Adjudication["verdict"],
      rationale: str(r["rationale"]),
      escalatedToHuman: bool(r["escalated_to_human"]),
      humanDecision: strOrNull(r["human_decision"]),
      createdAt: str(r["created_at"]),
    };
  }

  addDiscussion(m: Omit<DiscussionMessage, "id" | "createdAt"> & { id?: string }): DiscussionMessage {
    const row: DiscussionMessage = { ...m, id: m.id ?? newId(), createdAt: nowIso() };
    this.db
      .prepare(
        `INSERT INTO discussion_message (id,run_id,subtask_id,round,author_expert_id,reply_to_id,body,created_at)
         VALUES (?,?,?,?,?,?,?,?)`,
      )
      .run(row.id, row.runId, row.subTaskId, row.round, row.authorExpertId, row.replyToId, row.body, row.createdAt);
    return row;
  }

  listDiscussion(runId: string): DiscussionMessage[] {
    return this.db
      .prepare(`SELECT * FROM discussion_message WHERE run_id=? ORDER BY created_at`)
      .all(runId)
      .map((raw) => {
        const r = raw as Row;
        return {
          id: str(r["id"]),
          runId: str(r["run_id"]),
          subTaskId: str(r["subtask_id"]),
          round: num(r["round"]),
          authorExpertId: str(r["author_expert_id"]),
          replyToId: strOrNull(r["reply_to_id"]),
          body: str(r["body"]),
          createdAt: str(r["created_at"]),
        };
      });
  }

  // ── Channels ──────────────────────────────────────────────

  createChannel(
    c: Omit<Channel, "id" | "createdAt" | "color" | "archivedAt"> & {
      id?: string;
      color?: string | null;
    },
  ): Channel {
    const row: Channel = {
      ...c,
      id: c.id ?? newId(),
      color: c.color ?? null,
      archivedAt: null,
      createdAt: nowIso(),
    };
    this.db
      .prepare(
        `INSERT INTO channel (id,name,purpose,kind,project_id,dm_expert_id,color,archived_at,created_at)
         VALUES (?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.name,
        row.purpose,
        row.kind,
        row.projectId,
        row.dmExpertId,
        row.color,
        row.archivedAt,
        row.createdAt,
      );
    return row;
  }

  listChannels(): Channel[] {
    return this.db
      .prepare(`SELECT * FROM channel ORDER BY kind, created_at`)
      .all()
      .map((raw) => this.toChannel(raw as Row));
  }

  getChannel(id: string): Channel | null {
    const raw = this.db.prepare(`SELECT * FROM channel WHERE id=?`).get(id);
    return raw ? this.toChannel(raw as Row) : null;
  }

  updateChannel(
    id: string,
    patch: Partial<Pick<Channel, "name" | "color" | "archivedAt" | "projectId">>,
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      name: "name",
      color: "color",
      archivedAt: "archived_at",
      projectId: "project_id",
    };
    const sets: string[] = [];
    const vals: Array<string | null> = [];
    for (const [k, col] of Object.entries(cols) as Array<[keyof typeof patch, string]>) {
      const v = patch[k];
      if (v === undefined) continue;
      sets.push(`${col}=?`);
      vals.push(v);
    }
    if (sets.length === 0) return;
    vals.push(id);
    this.db.prepare(`UPDATE channel SET ${sets.join(",")} WHERE id=?`).run(...vals);
  }

  private toChannel(r: Row): Channel {
    return {
      id: str(r["id"]),
      name: str(r["name"]),
      purpose: str(r["purpose"]),
      kind: str(r["kind"]) === "dm" ? "dm" : "channel",
      projectId: strOrNull(r["project_id"]),
      dmExpertId: strOrNull(r["dm_expert_id"]),
      color: strOrNull(r["color"]),
      archivedAt: strOrNull(r["archived_at"]),
      createdAt: str(r["created_at"]),
    };
  }

  // ── Messages ──────────────────────────────────────────────

  /**
   * Appends a message and returns it with its assigned `seq`.
   *
   * `seq` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so it is the rowid and comes
   * back from the insert directly — no follow-up SELECT, and no per-channel
   * MAX() scan of the kind that made event appends quadratic.
   */
  createMessage(m: Omit<Message, "id" | "seq" | "createdAt"> & { id?: string }): Message {
    const id = m.id ?? newId();
    const createdAt = nowIso();
    const result = this.db
      .prepare(
        `INSERT INTO message (id,channel_id,author_kind,author_id,parent_id,body,created_at)
         VALUES (?,?,?,?,?,?,?)`,
      )
      .run(id, m.channelId, m.authorKind, m.authorId, m.parentId, m.body, createdAt);
    return { ...m, id, seq: num(result.lastInsertRowid), createdAt };
  }

  /**
   * A channel's root messages, oldest first, with each one's thread summary.
   *
   * Roots only: an agent working a task can post many turns into its thread, and
   * letting those into the main stream would bury everything else. The reply
   * counts come from one grouped self-join rather than a query per row.
   *
   * `limit` takes the NEWEST n roots and still returns them ascending, which is
   * what a chat client wants — a channel grows without bound, and the interesting
   * end is the recent one.
   */
  listChannelMessages(channelId: string, opts: { limit?: number } = {}): MessageWithThread[] {
    const limit = opts.limit ?? 200;
    const rows = this.db
      .prepare(
        `SELECT m.*,
                COUNT(r.seq)      AS reply_count,
                MAX(r.created_at) AS last_reply_at
           FROM message m
           LEFT JOIN message r ON r.parent_id = m.id
          WHERE m.channel_id = ? AND m.parent_id IS NULL
          GROUP BY m.seq
          ORDER BY m.seq DESC
          LIMIT ?`,
      )
      .all(channelId, limit) as Row[];

    return rows.reverse().map((r) => ({
      ...this.toMessage(r),
      replyCount: num(r["reply_count"]),
      lastReplyAt: strOrNull(r["last_reply_at"]),
    }));
  }

  /** One thread's replies, oldest first. Threads are one level deep. */
  listThreadReplies(parentId: string): Message[] {
    return this.db
      .prepare(`SELECT * FROM message WHERE parent_id=? ORDER BY seq`)
      .all(parentId)
      .map((raw) => this.toMessage(raw as Row));
  }

  getMessage(id: string): Message | null {
    const raw = this.db.prepare(`SELECT * FROM message WHERE id=?`).get(id);
    return raw ? this.toMessage(raw as Row) : null;
  }

  private toMessage(r: Row): Message {
    return {
      seq: num(r["seq"]),
      id: str(r["id"]),
      channelId: str(r["channel_id"]),
      authorKind: actorKind(r["author_kind"]),
      authorId: strOrNull(r["author_id"]),
      parentId: strOrNull(r["parent_id"]),
      body: str(r["body"]),
      createdAt: str(r["created_at"]),
    };
  }

  // ── Tasks ─────────────────────────────────────────────────

  createTask(
    t: Omit<
      Task,
      | "id"
      | "createdAt"
      | "updatedAt"
      | "note"
      | "myDay"
      | "dueDate"
      | "needsKind"
      | "needsText"
      | "runtimeKind"
      | "workingDirectory"
    > & {
      id?: string;
      note?: string;
      myDay?: string | null;
      dueDate?: string | null;
      needsKind?: Task["needsKind"];
      needsText?: string | null;
      runtimeKind?: RuntimeKind | null;
      workingDirectory?: string | null;
    },
  ): Task {
    const at = nowIso();
    const row: Task = {
      ...t,
      id: t.id ?? newId(),
      note: t.note ?? "",
      myDay: t.myDay ?? null,
      dueDate: t.dueDate ?? null,
      needsKind: t.needsKind ?? null,
      needsText: t.needsText ?? null,
      runtimeKind: t.runtimeKind ?? null,
      workingDirectory: t.workingDirectory ?? null,
      createdAt: at,
      updatedAt: at,
    };
    this.db
      .prepare(
        `INSERT INTO task
           (id,channel_id,title,status,note,my_day,due_date,needs_kind,needs_text,
            assignee_kind,assignee_id,creator_kind,creator_id,
            source_message_id,run_id,runtime_kind,working_directory,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.channelId,
        row.title,
        row.status,
        row.note,
        row.myDay,
        row.dueDate,
        row.needsKind,
        row.needsText,
        row.assigneeKind,
        row.assigneeId,
        row.creatorKind,
        row.creatorId,
        row.sourceMessageId,
        row.runId,
        row.runtimeKind,
        row.workingDirectory,
        row.createdAt,
        row.updatedAt,
      );
    return row;
  }

  /** Every task across every list, for the aggregated views (today / needs / done). */
  listAllTasks(): Task[] {
    return this.db
      .prepare(`SELECT * FROM task ORDER BY created_at`)
      .all()
      .map((raw) => this.toTask(raw as Row));
  }

  listTasks(channelId: string): Task[] {
    return this.db
      .prepare(`SELECT * FROM task WHERE channel_id=? ORDER BY created_at`)
      .all(channelId)
      .map((raw) => this.toTask(raw as Row));
  }

  /**
   * A channel's tasks grouped into board columns.
   *
   * Every column is present even when empty, because a Kanban board with a
   * missing column is a layout bug rather than a state worth rendering. Building
   * the shape here also keeps `TaskStatus` as the single source of truth for
   * which columns exist.
   */
  board(channelId: string): Record<TaskStatus, Task[]> {
    const columns = Object.fromEntries(TASK_STATUSES.map((s) => [s, [] as Task[]])) as Record<
      TaskStatus,
      Task[]
    >;
    for (const task of this.listTasks(channelId)) {
      // An unrecognised status would otherwise vanish from the board silently.
      (columns[task.status] ?? columns.todo).push(task);
    }
    return columns;
  }

  getTask(id: string): Task | null {
    const raw = this.db.prepare(`SELECT * FROM task WHERE id=?`).get(id);
    return raw ? this.toTask(raw as Row) : null;
  }

  /**
   * The card driving a run, if one started it.
   *
   * Reverse lookup rather than a taskId threaded through the pipeline: a run can
   * also be started directly, so the link has to be optional in that direction.
   * This is what lets the board reflect what the pipeline did.
   */
  getTaskByRunId(runId: string): Task | null {
    const raw = this.db.prepare(`SELECT * FROM task WHERE run_id=? LIMIT 1`).get(runId);
    return raw ? this.toTask(raw as Row) : null;
  }

  updateTask(
    id: string,
    patch: Partial<
      Pick<
        Task,
        | "title"
        | "status"
        | "note"
        | "myDay"
        | "dueDate"
        | "needsKind"
        | "needsText"
        | "assigneeKind"
        | "assigneeId"
        | "runId"
        | "runtimeKind"
        | "workingDirectory"
        | "channelId"
      >
    >,
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      title: "title",
      status: "status",
      note: "note",
      myDay: "my_day",
      dueDate: "due_date",
      needsKind: "needs_kind",
      needsText: "needs_text",
      assigneeKind: "assignee_kind",
      assigneeId: "assignee_id",
      runId: "run_id",
      runtimeKind: "runtime_kind",
      workingDirectory: "working_directory",
      channelId: "channel_id",
    };
    const sets: string[] = [];
    const vals: Array<string | null> = [];
    for (const [k, col] of Object.entries(cols) as Array<[keyof typeof patch, string]>) {
      const v = patch[k];
      if (v === undefined) continue;
      sets.push(`${col}=?`);
      vals.push(v);
    }
    if (sets.length === 0) return;
    // Always stamped, so "when did this last move" is answerable from the row
    // rather than inferred from the board's render order.
    sets.push("updated_at=?");
    vals.push(nowIso());
    vals.push(id);
    this.db.prepare(`UPDATE task SET ${sets.join(",")} WHERE id=?`).run(...vals);
  }

  private toTask(r: Row): Task {
    const assigneeKind = strOrNull(r["assignee_kind"]);
    const status = str(r["status"]);
    const needsKind = strOrNull(r["needs_kind"]);
    return {
      id: str(r["id"]),
      channelId: str(r["channel_id"]),
      title: str(r["title"]),
      status: (TASK_STATUSES as readonly string[]).includes(status)
        ? (status as TaskStatus)
        : "todo",
      note: str(r["note"] ?? ""),
      myDay: strOrNull(r["my_day"]),
      dueDate: strOrNull(r["due_date"]),
      needsKind:
        needsKind === "question" || needsKind === "reply" || needsKind === "blocked" || needsKind === "failed"
          ? needsKind
          : null,
      needsText: strOrNull(r["needs_text"]),
      assigneeKind: assigneeKind === null ? null : actorKind(assigneeKind),
      assigneeId: strOrNull(r["assignee_id"]),
      creatorKind: actorKind(r["creator_kind"]),
      creatorId: strOrNull(r["creator_id"]),
      sourceMessageId: strOrNull(r["source_message_id"]),
      runId: strOrNull(r["run_id"]),
      runtimeKind: runtimeKindOrNull(r["runtime_kind"]),
      workingDirectory: strOrNull(r["working_directory"]),
      createdAt: str(r["created_at"]),
      updatedAt: str(r["updated_at"]),
    };
  }

  deleteTask(id: string): boolean {
    const res = this.db.prepare(`DELETE FROM task WHERE id=?`).run(id);
    return res.changes > 0;
  }

  // ── Chat sessions ─────────────────────────────────────────

  createChatSession(s: { title?: string; id?: string } = {}): ChatSession {
    const at = nowIso();
    const row: ChatSession = {
      id: s.id ?? newId(),
      title: s.title ?? "",
      piSessionPath: null,
      createdAt: at,
      updatedAt: at,
      archivedAt: null,
    };
    this.db
      .prepare(
        `INSERT INTO chat_session (id,title,pi_session_path,created_at,updated_at,archived_at)
         VALUES (?,?,?,?,?,?)`,
      )
      .run(row.id, row.title, row.piSessionPath, row.createdAt, row.updatedAt, row.archivedAt);
    return row;
  }

  private toChatSession(r: Row): ChatSession {
    return {
      id: str(r["id"]),
      title: str(r["title"]),
      piSessionPath: strOrNull(r["pi_session_path"]),
      createdAt: str(r["created_at"]),
      updatedAt: str(r["updated_at"]),
      archivedAt: strOrNull(r["archived_at"]),
    };
  }

  listChatSessions(opts: { archived?: boolean } = {}): ChatSession[] {
    const archived = opts.archived ?? false;
    const sql = archived
      ? `SELECT * FROM chat_session WHERE archived_at IS NOT NULL ORDER BY updated_at DESC`
      : `SELECT * FROM chat_session WHERE archived_at IS NULL ORDER BY updated_at DESC`;
    return this.db
      .prepare(sql)
      .all()
      .map((r) => this.toChatSession(r as Row));
  }

  getChatSession(id: string): ChatSession | null {
    const r = this.db.prepare(`SELECT * FROM chat_session WHERE id=?`).get(id);
    return r ? this.toChatSession(r as Row) : null;
  }

  /**
   * The oldest non-archived session, creating one if none exists yet.
   *
   * The fallback target for requests that omit a session id — a single global
   * chat is the degenerate case of "many sessions", not a separate code path.
   */
  defaultChatSession(): ChatSession {
    const existing = this.listChatSessions()[0];
    if (existing) return existing;
    return this.createChatSession({ title: "默认会话" });
  }

  patchChatSession(
    id: string,
    patch: Partial<Pick<ChatSession, "title" | "piSessionPath" | "archivedAt">>,
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      title: "title",
      piSessionPath: "pi_session_path",
      archivedAt: "archived_at",
    };
    const sets: string[] = [];
    const vals: Array<string | null> = [];
    for (const [k, col] of Object.entries(cols) as Array<[keyof typeof patch, string]>) {
      const v = patch[k];
      if (v === undefined) continue;
      sets.push(`${col}=?`);
      vals.push(v);
    }
    if (sets.length === 0) return;
    sets.push("updated_at=?");
    vals.push(nowIso());
    vals.push(id);
    this.db.prepare(`UPDATE chat_session SET ${sets.join(",")} WHERE id=?`).run(...vals);
  }

  /** Bumps `updated_at` so the switcher can sort by recent activity. */
  touchChatSession(id: string): void {
    this.db.prepare(`UPDATE chat_session SET updated_at=? WHERE id=?`).run(nowIso(), id);
  }

  // ── Main-agent chat ───────────────────────────────────────

  appendAgentChat(m: {
    sessionId: string;
    role: AgentChatMessage["role"];
    body: string;
    taskRefs?: string[];
    attachments?: AgentChatAttachment[];
  }): AgentChatMessage {
    const id = newId();
    const createdAt = nowIso();
    const taskRefs = m.taskRefs ?? [];
    const attachments = m.attachments ?? [];
    this.db
      .prepare(
        `INSERT INTO agent_chat (id,session_id,role,body,task_refs,attachments,created_at)
         VALUES (?,?,?,?,?,?,?)`,
      )
      .run(id, m.sessionId, m.role, m.body, JSON.stringify(taskRefs), JSON.stringify(attachments), createdAt);
    const seq = this.db.prepare(`SELECT seq FROM agent_chat WHERE id=?`).get(id) as Row;
    this.touchChatSession(m.sessionId);
    return {
      seq: Number(seq["seq"]),
      id,
      sessionId: m.sessionId,
      role: m.role,
      body: m.body,
      taskRefs,
      attachments,
      createdAt,
    };
  }

  /** One session's newest `limit` entries, returned oldest-first for straight rendering. */
  listAgentChat(sessionId: string, limit = 200): AgentChatMessage[] {
    const rows = this.db
      .prepare(`SELECT * FROM agent_chat WHERE session_id=? ORDER BY seq DESC LIMIT ?`)
      .all(sessionId, limit) as Row[];
    return rows.reverse().map((r) => ({
      seq: Number(r["seq"]),
      id: str(r["id"]),
      sessionId: strOrNull(r["session_id"]) ?? sessionId,
      role: str(r["role"]) === "agent" ? "agent" : "user",
      body: str(r["body"]),
      taskRefs: jsonArray(r["task_refs"]),
      attachments: jsonAttachments(r["attachments"]),
      createdAt: str(r["created_at"]),
    }));
  }
}
