import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "./index.ts";
import { TASK_STATUSES } from "../types.ts";

/**
 * Boundary tests for the channel layer.
 *
 * The message stream gets the most attention because its query does three things
 * that are individually easy and jointly easy to get wrong: it filters to thread
 * roots, it aggregates each root's replies in the same pass, and it takes the
 * NEWEST n rows while returning them oldest-first. Any one of those inverted
 * produces a channel that looks plausible and shows the wrong messages.
 */

function fixture(): { store: Store; channelId: string; expertId: string } {
  const store = new Store(":memory:");
  const expert = store.createExpert({
    name: "T",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const channel = store.createChannel({
    name: "general",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
  return { store, channelId: channel.id, expertId: expert.id };
}

function say(
  store: Store,
  channelId: string,
  body: string,
  parentId: string | null = null,
): string {
  return store.createMessage({
    channelId,
    authorKind: "human",
    authorId: null,
    parentId,
    body,
  }).id;
}

// ── Channels ────────────────────────────────────────────────

test("channel: a project channel and a DM round-trip with their own fields", () => {
  const store = new Store(":memory:");
  const expert = store.createExpert({
    name: "Iris",
    description: "",
    runtimeKind: "gemini",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });

  const chan = store.createChannel({
    name: "web",
    purpose: "the web app",
    kind: "channel",
    projectId: "proj-1",
    dmExpertId: null,
  });
  const dm = store.createChannel({
    name: "Iris",
    purpose: "",
    kind: "dm",
    projectId: null,
    dmExpertId: expert.id,
  });

  assert.deepEqual(store.getChannel(chan.id), chan);
  assert.equal(store.getChannel(dm.id)?.kind, "dm");
  assert.equal(store.getChannel(dm.id)?.dmExpertId, expert.id);
  // A channel with no repository is a legitimate state, not a missing field.
  assert.equal(store.getChannel(dm.id)?.projectId, null);
  assert.equal(store.listChannels().length, 2);
  assert.equal(store.getChannel("nope"), null);
});

// ── Messages ────────────────────────────────────────────────

test("messages: seq comes back from the insert and strictly increases", () => {
  const { store, channelId } = fixture();
  const a = store.createMessage({
    channelId,
    authorKind: "human",
    authorId: null,
    parentId: null,
    body: "one",
  });
  const b = store.createMessage({
    channelId,
    authorKind: "human",
    authorId: null,
    parentId: null,
    body: "two",
  });

  // Zero would mean lastInsertRowid was not read — the value the whole ordering
  // depends on, and a plausible-looking default.
  assert.ok(a.seq > 0, `expected a positive seq, got ${a.seq}`);
  assert.ok(b.seq > a.seq, `expected ${b.seq} > ${a.seq}`);
  assert.equal(store.getMessage(a.id)?.seq, a.seq);
});

test("messages: the stream carries roots only, each with its reply count", () => {
  const { store, channelId, expertId } = fixture();
  const root = say(store, channelId, "how should we split this?");
  say(store, channelId, "unrelated");
  store.createMessage({
    channelId,
    authorKind: "expert",
    authorId: expertId,
    parentId: root,
    body: "I'll take the parser",
  });
  say(store, channelId, "sounds right", root);

  const stream = store.listChannelMessages(channelId);

  assert.equal(stream.length, 2, "two roots, and neither reply promoted into the stream");
  assert.deepEqual(
    stream.map((m) => m.body),
    ["how should we split this?", "unrelated"],
  );
  assert.equal(stream[0]?.replyCount, 2);
  assert.ok(stream[0]?.lastReplyAt, "a thread with replies reports when the newest arrived");
  // A root with no replies must report zero rather than the LEFT JOIN's one null row.
  assert.equal(stream[1]?.replyCount, 0);
  assert.equal(stream[1]?.lastReplyAt, null);
});

test("messages: limit takes the NEWEST roots and still returns them oldest-first", () => {
  const { store, channelId } = fixture();
  for (let i = 1; i <= 6; i++) say(store, channelId, `m${i}`);

  const tail = store.listChannelMessages(channelId, { limit: 3 });

  // The interesting end of a channel is the recent one, but it must still read
  // top-to-bottom in time. Getting either half wrong yields a stream that looks
  // fine and shows the wrong three messages.
  assert.deepEqual(
    tail.map((m) => m.body),
    ["m4", "m5", "m6"],
  );
});

test("messages: another channel's traffic is invisible", () => {
  const { store, channelId } = fixture();
  const other = store.createChannel({
    name: "other",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
  say(store, channelId, "mine");
  say(store, other.id, "theirs");

  assert.deepEqual(
    store.listChannelMessages(channelId).map((m) => m.body),
    ["mine"],
  );
});

test("threads: replies come back oldest-first, and only that thread's", () => {
  const { store, channelId } = fixture();
  const a = say(store, channelId, "thread A");
  const b = say(store, channelId, "thread B");
  say(store, channelId, "a1", a);
  say(store, channelId, "b1", b);
  say(store, channelId, "a2", a);

  assert.deepEqual(
    store.listThreadReplies(a).map((m) => m.body),
    ["a1", "a2"],
  );
  assert.deepEqual(store.listThreadReplies(b).map((m) => m.body), ["b1"]);
  assert.deepEqual(store.listThreadReplies("nope"), []);
});

// ── Board ───────────────────────────────────────────────────

test("board: every column exists even when the channel has no tasks", () => {
  const { store, channelId } = fixture();
  const board = store.board(channelId);

  // A Kanban board with a missing column is a layout bug, not a state worth
  // rendering — so the shape is guaranteed rather than derived from the data.
  assert.deepEqual(Object.keys(board).sort(), [...TASK_STATUSES].sort());
  for (const status of TASK_STATUSES) assert.deepEqual(board[status], []);
});

test("board: tasks land in their own column", () => {
  const { store, channelId, expertId } = fixture();
  const mk = (title: string, status: (typeof TASK_STATUSES)[number]) =>
    store.createTask({
      channelId,
      title,
      status,
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: null,
    });

  mk("a", "todo");
  mk("b", "in_review");
  mk("c", "in_review");
  const claimed = mk("d", "in_progress");
  store.updateTask(claimed.id, { assigneeKind: "expert", assigneeId: expertId });

  const board = store.board(channelId);
  assert.deepEqual(board.todo.map((t) => t.title), ["a"]);
  assert.deepEqual(board.in_review.map((t) => t.title), ["b", "c"]);
  assert.deepEqual(board.done, []);
  assert.equal(board.in_progress[0]?.assigneeId, expertId);
  assert.equal(board.in_progress[0]?.assigneeKind, "expert");
});

test("task: an unclaimed task has a null assignee rather than a placeholder", () => {
  const { store, channelId } = fixture();
  const t = store.createTask({
    channelId,
    title: "unclaimed",
    status: "todo",
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: null,
    runId: null,
  });

  assert.equal(store.getTask(t.id)?.assigneeKind, null);
  assert.equal(store.getTask(t.id)?.assigneeId, null);
});

test("task: a task created from a message keeps the link back to it", () => {
  const { store, channelId } = fixture();
  const msg = say(store, channelId, "we should cache the roster");
  const t = store.createTask({
    channelId,
    title: "cache the roster",
    status: "todo",
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: msg,
    runId: null,
  });

  assert.equal(store.getTask(t.id)?.sourceMessageId, msg);
});

test("task: updateTask stamps updated_at and an empty patch is a no-op", async () => {
  const { store, channelId } = fixture();
  const t = store.createTask({
    channelId,
    title: "move me",
    status: "todo",
    assigneeKind: null,
    assigneeId: null,
    creatorKind: "human",
    creatorId: null,
    sourceMessageId: null,
    runId: null,
  });
  assert.equal(t.updatedAt, t.createdAt);

  // ISO timestamps carry millisecond resolution, so without a real gap the
  // stamped value could equal the original and the assertion would pass by
  // accident on a fast machine.
  await new Promise((r) => setTimeout(r, 3));
  store.updateTask(t.id, { status: "in_progress" });

  const moved = store.getTask(t.id);
  assert.equal(moved?.status, "in_progress");
  assert.ok(
    (moved?.updatedAt ?? "") > t.createdAt,
    `expected updated_at to advance past ${t.createdAt}, got ${moved?.updatedAt}`,
  );

  // An empty patch must not fall through to `SET updated_at=?` alone, which
  // would report a change that never happened.
  store.updateTask(t.id, {});
  assert.equal(store.getTask(t.id)?.updatedAt, moved?.updatedAt);
});

test("task: another channel's tasks are invisible", () => {
  const { store, channelId } = fixture();
  const other = store.createChannel({
    name: "other",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
  const mk = (channel: string, title: string) =>
    store.createTask({
      channelId: channel,
      title,
      status: "todo",
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: null,
    });
  mk(channelId, "mine");
  mk(other.id, "theirs");

  assert.deepEqual(store.listTasks(channelId).map((t) => t.title), ["mine"]);
});

// ── Corrupt rows ────────────────────────────────────────────

/**
 * These go through a file-backed database and a second connection, because the
 * point is to write values the Store's own API cannot produce. A `:memory:`
 * database cannot be shared between connections.
 */
async function withRawDb(
  fn: (store: Store, raw: DatabaseSync) => void | Promise<void>,
): Promise<void> {
  const dir = await mkdtemp(join(tmpdir(), "council-channel-"));
  const path = join(dir, "t.db");
  const store = new Store(path);
  const raw = new DatabaseSync(path);
  try {
    await fn(store, raw);
  } finally {
    raw.close();
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
}

test("corrupt: an unknown author kind degrades to human rather than a blank author", async () => {
  await withRawDb((store, raw) => {
    const channel = store.createChannel({
      name: "c",
      purpose: "",
      kind: "channel",
      projectId: null,
      dmExpertId: null,
    });
    raw
      .prepare(
        `INSERT INTO message (id,channel_id,author_kind,author_id,parent_id,body,created_at)
         VALUES (?,?,?,?,?,?,?)`,
      )
      .run("m1", channel.id, "robot", null, null, "who said this?", "2026-01-01T00:00:00.000Z");

    // Degrading toward `human` is the safe direction: the only thing `expert`
    // buys is being resolved against the expert table, so an unknown kind would
    // otherwise render as an agent that does not exist.
    assert.equal(store.getMessage("m1")?.authorKind, "human");
  });
});

test("corrupt: an unrecognised task status lands in todo rather than vanishing", async () => {
  await withRawDb((store, raw) => {
    const channel = store.createChannel({
      name: "c",
      purpose: "",
      kind: "channel",
      projectId: null,
      dmExpertId: null,
    });
    raw
      .prepare(
        `INSERT INTO task (id,channel_id,title,status,creator_kind,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?)`,
      )
      .run("t1", channel.id, "orphan", "archived", "human", "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");

    assert.equal(store.getTask("t1")?.status, "todo");
    // The board must still show it. Silently dropping a task is worse than
    // showing it in the wrong column, because nothing tells the user it is gone.
    const board = store.board(channel.id);
    assert.deepEqual(board.todo.map((t) => t.title), ["orphan"]);
  });
});
