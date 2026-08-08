PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (
  version     INTEGER NOT NULL,
  applied_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS list (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  color            TEXT NOT NULL DEFAULT 'blue',
  repository_path  TEXT,
  archived_at      TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task (
  id            TEXT PRIMARY KEY,
  list_id       TEXT REFERENCES list(id),
  title         TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  status        TEXT NOT NULL CHECK(status IN ('todo','running','needs_you','review','done')),
  due_date      TEXT,
  needs_kind    TEXT CHECK(needs_kind IS NULL OR needs_kind IN ('question','blocked','failed')),
  needs_text    TEXT,
  runtime_kind  TEXT CHECK(runtime_kind IS NULL OR runtime_kind IN ('codex','claude')),
  working_directory TEXT,
  active_run_id TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  FOREIGN KEY(active_run_id) REFERENCES run(id)
);

CREATE TABLE IF NOT EXISTS runtime (
  kind          TEXT PRIMARY KEY CHECK(kind IN ('codex','claude')),
  executable    TEXT,
  version       TEXT,
  status        TEXT NOT NULL CHECK(status IN ('missing','detected','verifying','ready','error')),
  detected_at   TEXT,
  verified_at   TEXT,
  verify_error  TEXT
);

CREATE TABLE IF NOT EXISTS run (
  id                 TEXT PRIMARY KEY,
  task_id            TEXT NOT NULL REFERENCES task(id),
  parent_run_id      TEXT REFERENCES run(id),
  runtime_kind       TEXT NOT NULL CHECK(runtime_kind IN ('codex','claude')),
  executable         TEXT NOT NULL,
  executable_version TEXT,
  session_id         TEXT,
  user_message       TEXT NOT NULL,
  working_directory  TEXT NOT NULL,
  status             TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled','timed_out')),
  dirty_before       INTEGER NOT NULL DEFAULT 0,
  dirty_summary      TEXT,
  final_output       TEXT,
  diff_snapshot      TEXT,
  error              TEXT,
  started_at         TEXT NOT NULL,
  ended_at           TEXT
);

CREATE TABLE IF NOT EXISTS attempt (
  id             TEXT PRIMARY KEY,
  run_id         TEXT NOT NULL REFERENCES run(id),
  session_id     TEXT,
  status         TEXT NOT NULL,
  output         TEXT,
  error          TEXT,
  started_at     TEXT NOT NULL,
  ended_at       TEXT
);

CREATE TABLE IF NOT EXISTS run_event (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id      TEXT NOT NULL REFERENCES run(id),
  sequence    INTEGER NOT NULL,
  type        TEXT NOT NULL,
  payload     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  UNIQUE(run_id, sequence)
);

CREATE TABLE IF NOT EXISTS task_message (
  id          TEXT PRIMARY KEY,
  task_id     TEXT NOT NULL REFERENCES task(id),
  role        TEXT NOT NULL CHECK(role IN ('user','agent','system')),
  body        TEXT NOT NULL,
  run_id      TEXT REFERENCES run(id),
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_session (
  id           TEXT PRIMARY KEY,
  title        TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  archived_at  TEXT
);

CREATE TABLE IF NOT EXISTS chat_message (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES chat_session(id),
  role        TEXT NOT NULL CHECK(role IN ('user','todoagent')),
  body        TEXT NOT NULL,
  task_refs   TEXT NOT NULL DEFAULT '[]',
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS attachment (
  id           TEXT PRIMARY KEY,
  message_id   TEXT NOT NULL REFERENCES chat_message(id),
  media_type   TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  width        INTEGER,
  height       INTEGER,
  created_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_setting (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_status ON task(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_task_list ON task(list_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_run_task ON run(task_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_run ON run_event(run_id, sequence);
CREATE INDEX IF NOT EXISTS idx_chat_message_session ON chat_message(session_id, created_at);
