import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ActorKind,
  Adjudication,
  Attempt,
  Channel,
  DiscussionMessage,
  Expert,
  ExpertRole,
  HumanGate,
  Message,
  MessageWithThread,
  Phase,
  Project,
  Rebuttal,
  Review,
  Run,
  RunStatus,
  SubTask,
  SubTaskStatus,
  Task,
  TaskStatus,
  Team,
  TeamMember,
} from "../types.ts";
import { TASK_STATUSES, TERMINAL_SUBTASK_STATUS } from "../types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));

export function defaultDbPath(): string {
  const home = process.env["HOME"] ?? ".";
  return process.env["COUNCIL_DB"] ?? join(home, ".council", "council.db");
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

function jsonArray(v: unknown): string[] {
  if (typeof v !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(v);
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
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
   * Indexes are exempt: `CREATE INDEX IF NOT EXISTS` does create a missing index
   * on an existing table, so schema.sql handles those on its own.
   */
  private migrate(): void {
    const expected: Array<{ table: string; column: string; definition: string }> = [
      { table: "subtask", column: "branch", definition: "TEXT" },
      { table: "attempt", column: "cost_usd", definition: "REAL NOT NULL DEFAULT 0" },
    ];

    for (const { table, column, definition } of expected) {
      const info = this.db.prepare(`PRAGMA table_info(${table})`).all() as Row[];
      // An unknown table means schema.sql just created it with every column.
      if (info.length === 0) continue;
      if (info.some((c) => str(c["name"]) === column)) continue;
      this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
    }
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

  // ── Runs ──────────────────────────────────────────────────

  createRun(r: {
    projectId: string;
    goal: string;
    acceptance?: string | null;
    budgetTokens?: number;
    soloMode?: boolean;
    id?: string;
  }): Run {
    const row: Run = {
      id: r.id ?? newId(),
      projectId: r.projectId,
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
    };
    this.db
      .prepare(
        `INSERT INTO run (id,project_id,goal,acceptance,status,phase,gate,budget_tokens,spent_tokens,solo_mode,round,created_at,ended_at,error)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.projectId,
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
      );
    return row;
  }

  private toRun(r: Row): Run {
    return {
      id: str(r["id"]),
      projectId: str(r["project_id"]),
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
    };
  }

  getRun(id: string): Run | null {
    const r = this.db.prepare(`SELECT * FROM run WHERE id=?`).get(id);
    return r ? this.toRun(r as Row) : null;
  }

  listRuns(limit = 50): Run[] {
    return this.db
      .prepare(`SELECT * FROM run ORDER BY created_at DESC LIMIT ?`)
      .all(limit)
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
    patch: Partial<Pick<Run, "status" | "phase" | "gate" | "round" | "endedAt" | "error" | "spentTokens">>,
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      status: "status",
      phase: "phase",
      gate: "gate",
      round: "round",
      endedAt: "ended_at",
      error: "error",
      spentTokens: "spent_tokens",
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
    expertId: string;
    runtimeKind: Attempt["runtimeKind"];
    kind: Attempt["kind"];
    id?: string;
  }): Attempt {
    const row: Attempt = {
      id: a.id ?? newId(),
      runId: a.runId,
      subTaskId: a.subTaskId,
      expertId: a.expertId,
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
      expertId: str(r["expert_id"]),
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
          expertId: str(r["expert_id"]),
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
      .map((raw) => {
        const r = raw as Row;
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
      });
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
    const r = this.db
      .prepare(`SELECT * FROM adjudication WHERE id=?`)
      .get(adjudicationId) as Row | undefined;
    if (!r) return null;
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
    c: Omit<Channel, "id" | "createdAt"> & { id?: string },
  ): Channel {
    const row: Channel = { ...c, id: c.id ?? newId(), createdAt: nowIso() };
    this.db
      .prepare(
        `INSERT INTO channel (id,name,purpose,kind,project_id,dm_expert_id,created_at)
         VALUES (?,?,?,?,?,?,?)`,
      )
      .run(row.id, row.name, row.purpose, row.kind, row.projectId, row.dmExpertId, row.createdAt);
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

  private toChannel(r: Row): Channel {
    return {
      id: str(r["id"]),
      name: str(r["name"]),
      purpose: str(r["purpose"]),
      kind: str(r["kind"]) === "dm" ? "dm" : "channel",
      projectId: strOrNull(r["project_id"]),
      dmExpertId: strOrNull(r["dm_expert_id"]),
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
    t: Omit<Task, "id" | "createdAt" | "updatedAt"> & { id?: string },
  ): Task {
    const at = nowIso();
    const row: Task = { ...t, id: t.id ?? newId(), createdAt: at, updatedAt: at };
    this.db
      .prepare(
        `INSERT INTO task
           (id,channel_id,title,status,assignee_kind,assignee_id,creator_kind,creator_id,
            source_message_id,run_id,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
      )
      .run(
        row.id,
        row.channelId,
        row.title,
        row.status,
        row.assigneeKind,
        row.assigneeId,
        row.creatorKind,
        row.creatorId,
        row.sourceMessageId,
        row.runId,
        row.createdAt,
        row.updatedAt,
      );
    return row;
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

  updateTask(
    id: string,
    patch: Partial<Pick<Task, "title" | "status" | "assigneeKind" | "assigneeId" | "runId">>,
  ): void {
    const cols: Record<keyof typeof patch, string> = {
      title: "title",
      status: "status",
      assigneeKind: "assignee_kind",
      assigneeId: "assignee_id",
      runId: "run_id",
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
    return {
      id: str(r["id"]),
      channelId: str(r["channel_id"]),
      title: str(r["title"]),
      status: (TASK_STATUSES as readonly string[]).includes(status)
        ? (status as TaskStatus)
        : "todo",
      assigneeKind: assigneeKind === null ? null : actorKind(assigneeKind),
      assigneeId: strOrNull(r["assignee_id"]),
      creatorKind: actorKind(r["creator_kind"]),
      creatorId: strOrNull(r["creator_id"]),
      sourceMessageId: strOrNull(r["source_message_id"]),
      runId: strOrNull(r["run_id"]),
      createdAt: str(r["created_at"]),
      updatedAt: str(r["updated_at"]),
    };
  }
}
