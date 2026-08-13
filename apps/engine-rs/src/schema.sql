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

CREATE TABLE IF NOT EXISTS task_data_revision (
  singleton   INTEGER PRIMARY KEY CHECK(singleton = 1),
  revision    INTEGER NOT NULL CHECK(revision >= 0)
);
INSERT OR IGNORE INTO task_data_revision(singleton, revision) VALUES(1, 0);

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
  execution_date TEXT CHECK(
    execution_date IS NULL OR
    (length(execution_date) = 10 AND
     execution_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND
     substr(execution_date, 1, 4) BETWEEN '0001' AND '9999')
  ),
  due_date      TEXT CHECK(
    due_date IS NULL OR
    (length(due_date) = 10 AND
     due_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND
     substr(due_date, 1, 4) BETWEEN '0001' AND '9999')
  ),
  completed_at  TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_attachment (
  id             TEXT PRIMARY KEY,
  task_id        TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  original_name  TEXT NOT NULL CHECK(original_name NOT IN ('', '.', '..') AND instr(original_name, '/') = 0),
  size_bytes     INTEGER NOT NULL CHECK(size_bytes BETWEEN 0 AND 104857600),
  mime_type      TEXT NOT NULL CHECK(mime_type <> ''),
  relative_path  TEXT NOT NULL UNIQUE CHECK(
    relative_path GLOB 'Attachments/*' AND
    instr(substr(relative_path, 13), '/') = 0
  ),
  created_at     TEXT NOT NULL
);

-- Durable receipts make attachment mutations safe to retry after the caller
-- loses the response. The canonical request fingerprint prevents a UUID from
-- being reused for a different operation or target.
CREATE TABLE IF NOT EXISTS task_attachment_mutation (
  client_mutation_id          TEXT PRIMARY KEY,
  operation                   TEXT NOT NULL CHECK(operation IN ('add','remove')),
  task_id                     TEXT NOT NULL,
  request_fingerprint         TEXT NOT NULL,
  result_attachment_ids_json  TEXT NOT NULL,
  created_at                  TEXT NOT NULL
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

CREATE TABLE IF NOT EXISTS terminal_session (
  id                       TEXT PRIMARY KEY,
  task_id                  TEXT NOT NULL UNIQUE REFERENCES task(id) ON DELETE CASCADE,
  runtime_kind             TEXT NOT NULL CHECK(runtime_kind IN ('codex','claude','cursor','kiro')),
  working_directory        TEXT NOT NULL,
  provider_session_id      TEXT CHECK(provider_session_id IS NULL OR length(provider_session_id) BETWEEN 1 AND 512),
  provider_binding_state   TEXT NOT NULL DEFAULT 'unbound'
    CHECK(provider_binding_state IN ('unbound','bound','capture_failed')),
  provider_binding_source  TEXT,
  agent_status             TEXT NOT NULL DEFAULT 'unknown'
    CHECK(agent_status IN ('unknown','idle','active','blocked','completed')),
  status_sequence          INTEGER NOT NULL DEFAULT 0 CHECK(status_sequence >= 0),
  seen_status_sequence     INTEGER NOT NULL DEFAULT 0
    CHECK(seen_status_sequence BETWEEN 0 AND status_sequence),
  last_error_code          TEXT,
  last_error_message       TEXT,
  last_started_at          TEXT,
  last_exited_at           TEXT,
  created_at               TEXT NOT NULL,
  updated_at               TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS terminal_run (
  id                             TEXT PRIMARY KEY,
  session_id                     TEXT NOT NULL REFERENCES terminal_session(id) ON DELETE CASCADE,
  ordinal                        INTEGER NOT NULL CHECK(ordinal > 0),
  launch_mode                    TEXT NOT NULL CHECK(launch_mode IN ('fresh','resume')),
  state                          TEXT NOT NULL
    CHECK(state IN ('starting','running','stopping','exited','failed','interrupted')),
  provider_session_id_at_launch  TEXT,
  exit_code                      INTEGER,
  exit_reason                    TEXT,
  error_code                     TEXT,
  error_message                  TEXT,
  started_at                     TEXT,
  exited_at                      TEXT,
  created_at                     TEXT NOT NULL,
  UNIQUE(session_id, ordinal)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_terminal_one_active_run
ON terminal_run(session_id)
WHERE state IN ('starting','running','stopping');

CREATE TABLE IF NOT EXISTS terminal_status_receipt (
  event_id    TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES terminal_session(id) ON DELETE CASCADE,
  run_id      TEXT NOT NULL REFERENCES terminal_run(id) ON DELETE CASCADE,
  status      TEXT NOT NULL CHECK(status IN ('unknown','idle','active','blocked','completed')),
  created_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_terminal_status_receipt_run
ON terminal_status_receipt(run_id);

CREATE TABLE IF NOT EXISTS chat_session (
  id           TEXT PRIMARY KEY,
  title        TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  archived_at  TEXT
);

CREATE TABLE IF NOT EXISTS chat_message (
  id                TEXT PRIMARY KEY,
  session_id        TEXT NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  turn_id           TEXT REFERENCES assistant_turn(id) ON DELETE SET NULL,
  sequence          INTEGER NOT NULL,
  client_message_id TEXT,
  role              TEXT NOT NULL CHECK(role IN ('user','todoagent','system','tool')),
  kind              TEXT NOT NULL DEFAULT 'text' CHECK(kind IN ('text','tool_call','tool_result','status','error')),
  body              TEXT NOT NULL,
  payload_json      TEXT,
  task_refs_json    TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  UNIQUE(session_id, sequence),
  UNIQUE(session_id, client_message_id)
);

CREATE TABLE IF NOT EXISTS assistant_turn (
  id                TEXT PRIMARY KEY,
  session_id        TEXT NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  ordinal           INTEGER NOT NULL,
  user_message_id   TEXT NOT NULL REFERENCES chat_message(id) ON DELETE RESTRICT,
  model_id          TEXT,
  attempt_count     INTEGER NOT NULL DEFAULT 0,
  status            TEXT NOT NULL CHECK(status IN ('queued','running','completed','failed','cancelled','interrupted')),
  final_output      TEXT,
  usage_json        TEXT,
  error_code        TEXT,
  error_message     TEXT,
  started_at        TEXT,
  ended_at          TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  UNIQUE(session_id, ordinal)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_assistant_one_active_turn
ON assistant_turn(session_id)
WHERE status IN ('queued','running');

CREATE TABLE IF NOT EXISTS assistant_step (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  turn_id       TEXT NOT NULL REFERENCES assistant_turn(id) ON DELETE CASCADE,
  sequence      INTEGER NOT NULL,
  interaction_ordinal INTEGER NOT NULL DEFAULT 1,
  provider_step_index INTEGER,
  kind          TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'completed' CHECK(status IN ('queued','running','completed','failed','cancelled')),
  title         TEXT,
  payload_json  TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  UNIQUE(session_id, sequence)
);

CREATE TABLE IF NOT EXISTS assistant_tool_execution (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  turn_id        TEXT REFERENCES assistant_turn(id) ON DELETE SET NULL,
  step_id        TEXT REFERENCES assistant_step(id) ON DELETE SET NULL,
  call_id        TEXT NOT NULL,
  tool_name      TEXT NOT NULL,
  request_json   TEXT NOT NULL,
  response_json  TEXT,
  task_refs_json TEXT,
  is_error       INTEGER NOT NULL DEFAULT 0 CHECK(is_error IN (0,1)),
  status         TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
  error_code     TEXT,
  error_message  TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  UNIQUE(session_id, call_id)
);

CREATE TABLE IF NOT EXISTS assistant_compaction (
  session_id       TEXT PRIMARY KEY REFERENCES chat_session(id) ON DELETE CASCADE,
  through_sequence INTEGER NOT NULL,
  summary          TEXT NOT NULL,
  payload_json     TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
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
CREATE INDEX IF NOT EXISTS idx_task_execution_date ON task(execution_date, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_task_due_date ON task(due_date, status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_task_attachment_task ON task_attachment(task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_terminal_session_task ON terminal_session(task_id);
CREATE INDEX IF NOT EXISTS idx_terminal_run_session ON terminal_run(session_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_chat_message_session ON chat_message(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_assistant_turn_session ON assistant_turn(session_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_assistant_step_session ON assistant_step(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_assistant_tool_execution_turn ON assistant_tool_execution(turn_id);
