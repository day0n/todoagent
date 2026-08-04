-- TodoAgent schema.
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
  error         TEXT,
  -- Snapshot of the working tree taken the instant a direct run completed.
  --
  -- Captured then, not on demand, because a direct run's agent edits the user's
  -- real working tree: by the time anyone opens the result the diff would also
  -- contain their own later edits, with no way to separate the two.
  --
  -- Deliberately NOT part of the `Run` interface — see `getRunDiff`. It is capped
  -- at 2M characters and `GET /api/runs` spreads whole Run objects for up to 100
  -- rows, so putting it on the type would put 200MB in a list response.
  diff          TEXT,
  -- What the worker's final output amounted to: 'done' | 'question' | 'blocked'.
  --
  -- A single-turn CLI has no way to ask for help other than saying so in its last
  -- words, so a run can complete successfully and still not be finished.
  --
  -- Persisted rather than kept in the classifier's return value because
  -- `syncTaskFromRun` maps (run, task) to a card state from eleven call sites and
  -- has to reach the same answer every time. With the verdict living only in a
  -- local variable, the first call parked a question in needs_you and the next one
  -- — a cancel, a reconcile, a resumed gate — saw `completed`, mapped it to
  -- 待确认 and discarded the question.
  --
  -- Deliberately NOT on the `Run` interface, for the same reason as `diff` above:
  -- read it through `getRunOutcome` at the one point a card's fate is decided.
  outcome_kind  TEXT,
  outcome_text  TEXT
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

-- ── Channel layer ───────────────────────────────────────────
--
-- Chat is the workspace: channels, DMs and threads, with agents as persistent
-- members rather than one-shot invocations. This sits ABOVE the execution layer.
-- A channel message is durable conversation; `discussion_message` above is a
-- transcript of one review round inside a single subtask. They are not the same
-- thing and deliberately do not share a table.

CREATE TABLE IF NOT EXISTS channel (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  purpose    TEXT NOT NULL DEFAULT '',
  -- 'channel' | 'dm'
  kind       TEXT NOT NULL DEFAULT 'channel',
  -- The repository this channel's work lands in. NULL is legitimate: a DM with
  -- an agent, or a channel used purely for discussion, has no repo — and a task
  -- there cannot start a pipeline run, which is honest rather than broken.
  project_id TEXT,
  -- For kind='dm', the agent on the other side of a 1:1 conversation.
  dm_expert_id TEXT,
  -- Sidebar swatch. NULL renders the default gray dot.
  color       TEXT,
  -- Archived lists keep their tasks but leave the sidebar.
  archived_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_channel_project ON channel (project_id);

CREATE TABLE IF NOT EXISTS message (
  -- Ordering key. A message stream needs a total order, and deriving one from
  -- `created_at` is unsound: ISO strings collide at millisecond resolution, so
  -- two agents replying at once would sort arbitrarily and could swap places
  -- between reads. AUTOINCREMENT also gives cheap keyset pagination.
  --
  -- A per-channel counter would reintroduce the MAX() scan that made `event`
  -- appends quadratic; a global sequence has no such lookup.
  seq         INTEGER PRIMARY KEY AUTOINCREMENT,
  -- Stable reference key, since `parent_id` and `task.source_message_id` point
  -- at messages and must not depend on insertion order.
  id          TEXT NOT NULL UNIQUE,
  channel_id  TEXT NOT NULL,
  -- Polymorphic author, following the same shape as a polymorphic assignee:
  -- 'human' | 'expert'. `author_id` is an expert.id only when kind='expert';
  -- there is a single local human, who needs no row.
  author_kind TEXT NOT NULL,
  author_id   TEXT,
  -- Thread root. NULL means this message is itself a root. Replies are one level
  -- deep, matching what the reference product exposes.
  parent_id   TEXT,
  body        TEXT NOT NULL,
  created_at  TEXT NOT NULL
);

-- Serves the channel stream (roots, newest last) and thread expansion.
CREATE INDEX IF NOT EXISTS idx_message_channel ON message (channel_id, seq);
CREATE INDEX IF NOT EXISTS idx_message_parent ON message (parent_id, seq);

CREATE TABLE IF NOT EXISTS task (
  id            TEXT PRIMARY KEY,
  channel_id    TEXT NOT NULL,
  title         TEXT NOT NULL,
  -- Board column: 'todo' | 'in_progress' | 'needs_you' | 'in_review' | 'done'.
  --
  -- `needs_you` is the product's heart: the task is parked until a person
  -- answers a question, unblocks it, or decides what to do about a failure.
  --
  -- Distinct from `subtask.status`, which tracks one agent's work inside a run
  -- and carries states a board has no column for (reworking, blocked, failed).
  -- Collapsing them would force the board to invent columns nobody asked for.
  status        TEXT NOT NULL DEFAULT 'todo',
  -- Free-form second line under the title.
  note          TEXT NOT NULL DEFAULT '',
  -- ISO date (YYYY-MM-DD) for a manual "my day" pin; automatic membership
  -- (needs_you / in_progress / in_review / created today) is derived, not stored.
  my_day        TEXT,
  -- ISO date (YYYY-MM-DD) the task is due. NULL means no deadline, which is the
  -- normal case — most todos never get one and a default would be a lie.
  --
  -- A DATE, not a timestamp. "Friday" is what people mean by a deadline; storing
  -- 23:59:59 would invent a precision nobody asked for and make every comparison
  -- timezone-dependent. Compared against the local calendar day, same as my_day.
  due_date      TEXT,
  -- Why the task sits in needs_you: 'question' | 'blocked' | 'failed'.
  needs_kind    TEXT,
  -- The agent's question or blocking reason, shown on the card.
  needs_text    TEXT,
  -- Polymorphic assignee: 'human' | 'expert', or NULL for unclaimed. An agent
  -- claims a task itself, so this is written by the agent as often as by a person.
  assignee_kind TEXT,
  assignee_id   TEXT,
  creator_kind  TEXT NOT NULL DEFAULT 'human',
  creator_id    TEXT,
  -- The message this task was created from, when it came from chat rather than
  -- the board's own New Task dialog.
  source_message_id TEXT,
  -- The pipeline run doing the work, once started. NULL until then.
  run_id        TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_channel ON task (channel_id, status);

-- ── Main-agent conversation ─────────────────────────────────
--
-- A single timeline, not per-channel: the main agent is one assistant for the
-- whole workspace. Same AUTOINCREMENT reasoning as `message`.

CREATE TABLE IF NOT EXISTS agent_chat (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  id         TEXT NOT NULL UNIQUE,
  -- 'user' | 'agent'
  role       TEXT NOT NULL,
  body       TEXT NOT NULL,
  -- JSON array of task ids this message created or referenced, for inline cards.
  task_refs  TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);
