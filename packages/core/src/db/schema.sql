-- Council schema.
--
-- Two deliberate choices carried over from Multica's conventions:
--   * No foreign keys. Relationships, validation, and dependent cleanup are
--     resolved in application code inside a transaction, so a cascade can never
--     silently delete a run's history.
--   * The event table is append-only. It backs SSE replay (Last-Event-ID) and
--     post-hoc inspection of what an agent actually did.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = OFF;

-- ── Organization layer ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS expert (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  description   TEXT NOT NULL DEFAULT '',
  runtime_kind  TEXT NOT NULL,
  model         TEXT,
  system_prompt TEXT NOT NULL DEFAULT '',
  capabilities  TEXT NOT NULL DEFAULT '[]',  -- JSON array
  created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS team (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS team_member (
  team_id   TEXT NOT NULL,
  expert_id TEXT NOT NULL,
  role      TEXT NOT NULL,
  PRIMARY KEY (team_id, expert_id, role)
);

CREATE TABLE IF NOT EXISTS project (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  repo_path  TEXT NOT NULL,
  team_id    TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- ── Execution layer ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS run (
  id            TEXT PRIMARY KEY,
  project_id    TEXT NOT NULL,
  goal          TEXT NOT NULL,
  acceptance    TEXT,
  status        TEXT NOT NULL,
  phase         TEXT NOT NULL,
  gate          TEXT,
  budget_tokens INTEGER NOT NULL DEFAULT 0,
  spent_tokens  INTEGER NOT NULL DEFAULT 0,
  solo_mode     INTEGER NOT NULL DEFAULT 0,
  round         INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  ended_at      TEXT,
  error         TEXT
);

CREATE INDEX IF NOT EXISTS idx_run_created ON run (created_at DESC);

CREATE TABLE IF NOT EXISTS subtask (
  id                 TEXT PRIMARY KEY,
  run_id             TEXT NOT NULL,
  -- Barrier group. Stage N+1 opens only once every stage-N subtask is terminal.
  stage              INTEGER NOT NULL DEFAULT 0,
  title              TEXT NOT NULL,
  brief              TEXT NOT NULL,
  acceptance         TEXT NOT NULL DEFAULT '',
  capability         TEXT NOT NULL DEFAULT '',
  assigned_expert_id TEXT,
  depends_on         TEXT NOT NULL DEFAULT '[]',  -- JSON array of subtask ids
  status             TEXT NOT NULL,
  worktree_path      TEXT,
  -- The git branch holding this subtask's work. This is the DELIVERABLE: the
  -- worktree directory is disposed as soon as the subtask finishes, and the
  -- merge phase runs afterwards, so the branch name has to be durable state.
  -- Recovering it from the event log instead is unsound — a real run emits tens
  -- of thousands of events and any read cap silently drops the older ones,
  -- which loses the branch and therefore the work.
  branch             TEXT,
  created_at         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_subtask_run ON subtask (run_id, stage);

CREATE TABLE IF NOT EXISTS attempt (
  id            TEXT PRIMARY KEY,
  run_id        TEXT NOT NULL,
  subtask_id    TEXT,
  expert_id     TEXT NOT NULL,
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

CREATE INDEX IF NOT EXISTS idx_attempt_run ON attempt (run_id, started_at);

CREATE TABLE IF NOT EXISTS event (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id     TEXT NOT NULL,
  attempt_id TEXT,
  seq        INTEGER NOT NULL,
  type       TEXT NOT NULL,
  payload    TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Ordered replay for SSE (Last-Event-ID walks `id`).
CREATE INDEX IF NOT EXISTS idx_event_run ON event (run_id, id);

-- Serves the per-run MAX(seq) lookup that every insert performs.
--
-- Without it, appending was O(n) per event because finding the highest seq for a
-- run had to scan all of that run's rows: measured cost grew from 34us/event at
-- 1k events to 169us/event at 8k, i.e. quadratic in total events. A single
-- subtask already emits a few hundred and four parallel ones emit thousands, so
-- the write path degraded exactly when a run got interesting.
CREATE INDEX IF NOT EXISTS idx_event_run_seq ON event (run_id, seq DESC);

-- ── Discussion layer ────────────────────────────────────────

CREATE TABLE IF NOT EXISTS review (
  id                 TEXT PRIMARY KEY,
  run_id             TEXT NOT NULL,
  subtask_id         TEXT NOT NULL,
  reviewer_expert_id TEXT NOT NULL,
  round              INTEGER NOT NULL DEFAULT 1,
  severity           TEXT NOT NULL,
  claim              TEXT NOT NULL,
  evidence           TEXT NOT NULL DEFAULT '',
  -- Splits every dispute in two: a checkable claim is settled by a repro test,
  -- an uncheckable one is the only kind worth a human's attention.
  verifiable         INTEGER NOT NULL DEFAULT 0,
  suggested_test     TEXT,
  patch              TEXT,
  repro_outcome      TEXT,
  created_at         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_review_subtask ON review (subtask_id, round);

CREATE TABLE IF NOT EXISTS rebuttal (
  id               TEXT PRIMARY KEY,
  review_id        TEXT NOT NULL,
  author_expert_id TEXT NOT NULL,
  decision         TEXT NOT NULL,
  reason           TEXT NOT NULL,
  created_at       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS adjudication (
  id                 TEXT PRIMARY KEY,
  run_id             TEXT NOT NULL,
  subtask_id         TEXT NOT NULL,
  round              INTEGER NOT NULL DEFAULT 1,
  verdict            TEXT NOT NULL,
  rationale          TEXT NOT NULL,
  escalated_to_human INTEGER NOT NULL DEFAULT 0,
  human_decision     TEXT,
  created_at         TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS discussion_message (
  id               TEXT PRIMARY KEY,
  run_id           TEXT NOT NULL,
  subtask_id       TEXT NOT NULL,
  round            INTEGER NOT NULL DEFAULT 1,
  author_expert_id TEXT NOT NULL,
  reply_to_id      TEXT,
  body             TEXT NOT NULL,
  created_at       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_discussion_subtask ON discussion_message (subtask_id, round);
