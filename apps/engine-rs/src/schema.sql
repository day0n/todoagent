CREATE TABLE IF NOT EXISTS schema_migration (
  version     INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  checksum    TEXT NOT NULL,
  applied_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_revision (
  singleton   INTEGER PRIMARY KEY CHECK(singleton = 1),
  revision    INTEGER NOT NULL
);
INSERT OR IGNORE INTO app_revision(singleton, revision) VALUES(1, 0);

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
  status        TEXT NOT NULL CHECK(status IN ('open','completed')),
  due_date      TEXT,
  completed_at  TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime (
  kind             TEXT PRIMARY KEY CHECK(kind IN ('codex','claude','cursor','kiro')),
  launch_path      TEXT,
  resolved_path    TEXT,
  version          TEXT,
  status           TEXT NOT NULL CHECK(status IN ('missing','detected','verifying','ready','auth_required','error')),
  auth_status      TEXT NOT NULL DEFAULT 'unknown' CHECK(auth_status IN ('unknown','authenticated','required','error')),
  capabilities     TEXT NOT NULL DEFAULT '{}',
  provider_engine  TEXT,
  detected_at      TEXT,
  verified_at      TEXT,
  verify_error     TEXT
);

CREATE TABLE IF NOT EXISTS task_session (
  id                    TEXT PRIMARY KEY,
  task_id               TEXT NOT NULL UNIQUE REFERENCES task(id) ON DELETE CASCADE,
  runtime_kind          TEXT NOT NULL CHECK(runtime_kind IN ('codex','claude','cursor','kiro')),
  working_directory     TEXT NOT NULL,
  provider_session_id   TEXT,
  provider_engine       TEXT,
  state                 TEXT NOT NULL CHECK(state IN ('idle','queued','running','failed','closed')),
  last_agent_sequence   INTEGER NOT NULL DEFAULT 0,
  last_read_sequence    INTEGER NOT NULL DEFAULT 0,
  last_error_code       TEXT,
  last_error_message    TEXT,
  dirty_before          INTEGER NOT NULL DEFAULT 0,
  dirty_summary         TEXT,
  created_at            TEXT NOT NULL,
  updated_at            TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_turn (
  id                          TEXT PRIMARY KEY,
  session_id                  TEXT NOT NULL REFERENCES task_session(id) ON DELETE CASCADE,
  ordinal                     INTEGER NOT NULL,
  user_message_id             TEXT NOT NULL,
  provider_session_id_before  TEXT,
  provider_session_id_after   TEXT,
  status                      TEXT NOT NULL CHECK(status IN ('queued','running','completed','failed','cancelled','interrupted')),
  exit_code                   INTEGER,
  final_output                TEXT,
  error_code                  TEXT,
  error_message               TEXT,
  provider_usage_json         TEXT,
  started_at                  TEXT,
  ended_at                    TEXT,
  created_at                  TEXT NOT NULL,
  UNIQUE(session_id, ordinal)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_session_one_active_turn
ON session_turn(session_id)
WHERE status IN ('queued','running');

CREATE TABLE IF NOT EXISTS session_message (
  id                 TEXT PRIMARY KEY,
  session_id         TEXT NOT NULL REFERENCES task_session(id) ON DELETE CASCADE,
  turn_id            TEXT REFERENCES session_turn(id) ON DELETE SET NULL,
  sequence           INTEGER NOT NULL,
  client_message_id  TEXT,
  role               TEXT NOT NULL CHECK(role IN ('user','agent','system','tool')),
  kind               TEXT NOT NULL CHECK(kind IN ('text','tool_call','tool_result','status','error')),
  body               TEXT NOT NULL,
  payload_json       TEXT,
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL,
  UNIQUE(session_id, sequence),
  UNIQUE(session_id, client_message_id)
);

CREATE TABLE IF NOT EXISTS turn_event (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_id     TEXT NOT NULL REFERENCES session_turn(id) ON DELETE CASCADE,
  sequence    INTEGER NOT NULL,
  type        TEXT NOT NULL,
  payload     TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  UNIQUE(turn_id, sequence)
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
  session_id  TEXT NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  sequence    INTEGER NOT NULL,
  role        TEXT NOT NULL CHECK(role IN ('user','todoagent','system','tool')),
  body        TEXT NOT NULL,
  payload_json TEXT,
  created_at  TEXT NOT NULL,
  UNIQUE(session_id, sequence)
);

CREATE TABLE IF NOT EXISTS attachment (
  id             TEXT PRIMARY KEY,
  message_id     TEXT NOT NULL REFERENCES chat_message(id) ON DELETE CASCADE,
  media_type     TEXT NOT NULL,
  relative_path  TEXT NOT NULL,
  width          INTEGER,
  height         INTEGER,
  created_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_setting (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_status ON task(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_task_list ON task(list_id, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_session_task ON task_session(task_id);
CREATE INDEX IF NOT EXISTS idx_turn_session ON session_turn(session_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_message_session ON session_message(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_event_turn ON turn_event(turn_id, sequence);
CREATE INDEX IF NOT EXISTS idx_chat_message_session ON chat_message(session_id, sequence);
