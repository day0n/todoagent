import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";
import type { Task, TaskStatus } from "@todoagent/core/types";

/**
 * The day board: which column a task lands in, and why.
 *
 * Membership is decided in the engine on purpose — two places deciding it is how a
 * card renders twice or not at all. So these tests are the specification for the
 * whole view, and each one pins a judgement rather than an implementation detail.
 *
 * Several cases need a status a person cannot set (`needs_you` is refused by PATCH
 * by design) or a `created_at` in the past, so those rows are written through
 * `Store` directly. Everything reachable through HTTP goes through HTTP.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8818; // distinct from every other engine suite (8799–8817)
const BASE = `http://127.0.0.1:${PORT}`;

interface Fixture {
  dbPath: string;
  listId: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-board-"));
  const dbPath = join(root, "b.db");
  const store = new Store(dbPath);
  const list = store.createChannel({
    name: "工作",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
    color: null,
  });
  store.close();
  return { dbPath, listId: list.id, dispose: () => rm(root, { recursive: true, force: true }) };
}

async function withEngine<T>(dbPath: string, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: { ...process.env, TODOAGENT_DB: dbPath, TODOAGENT_PORT: String(PORT) },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const deadline = Date.now() + 30_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error("engine did not start within 30s");
      try {
        if ((await fetch(`${BASE}/api/health`)).ok) break;
      } catch {
        /* not listening yet */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    return await fn();
  } finally {
    child.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 200));
  }
}

function req(method: string, path: string, body?: unknown): Promise<Response> {
  return fetch(`${BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

interface BoardColumn {
  key: "today" | "tomorrow" | "dayAfter" | "later";
  date: string | null;
  weekday: number | null;
  tasks: Task[];
  done: number;
  total: number;
}
interface Board {
  today: string;
  columns: BoardColumn[];
}

/** `YYYY-MM-DD`, `n` days from now, computed the way the engine does. */
function day(n: number): string {
  const now = new Date();
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + n);
  const m = String(d.getMonth() + 1).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, "0")}`;
}

async function board(): Promise<Board> {
  return json<Board>(await req("GET", "/api/board"));
}

/** Which column holds this task, or null. Proves exactly-one-column too. */
function columnOf(b: Board, id: string): string | null {
  const hits = b.columns.filter((c) => c.tasks.some((t) => t.id === id));
  assert.ok(hits.length <= 1, `task ${id} appeared in ${hits.length} columns: ${hits.map((h) => h.key).join()}`);
  return hits[0]?.key ?? null;
}

/**
 * Moves a task's timestamps into the past.
 *
 * Raw SQL because no API can produce this: `createTask` stamps both timestamps with
 * `nowIso()` and `updateTask` always refreshes `updated_at`. Without it, "created
 * before today" and "finished last month" are untestable — and both are exactly the
 * cases where the bucketing rules earn their keep.
 */
function backdate(dbPath: string, id: string, iso: string): void {
  const store = new Store(dbPath);
  try {
    (store as unknown as { db: { prepare: (s: string) => { run: (...a: unknown[]) => void } } }).db
      .prepare("UPDATE task SET created_at=?, updated_at=? WHERE id=?")
      .run(iso, iso, id);
  } finally {
    store.close();
  }
}

/** Writes a row the HTTP API deliberately will not let a caller create. */
function seed(
  dbPath: string,
  listId: string,
  over: Partial<Task> & { title: string; status: TaskStatus },
): string {
  const store = new Store(dbPath);
  try {
    const t = store.createTask({
      channelId: listId,
      title: over.title,
      status: over.status,
      ...(over.dueDate !== undefined ? { dueDate: over.dueDate } : {}),
      ...(over.myDay !== undefined ? { myDay: over.myDay } : {}),
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: over.runId ?? null,
    });
    return t.id;
  } finally {
    store.close();
  }
}

// ── Shape ───────────────────────────────────────────────────

test("board: four columns, dated from today, with 以后 carrying no date", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const b = await board();
      assert.deepEqual(
        b.columns.map((c) => c.key),
        ["today", "tomorrow", "dayAfter", "later"],
        "display order is the response order",
      );
      assert.equal(b.today, day(0));
      assert.equal(b.columns[0]?.date, day(0));
      assert.equal(b.columns[1]?.date, day(1));
      assert.equal(b.columns[2]?.date, day(2));
      /*
       * `later` is a bucket, not a day. Sending it a date would invite the client to
       * render a column header for a day that means nothing.
       */
      assert.equal(b.columns[3]?.date, null);
      assert.equal(b.columns[3]?.weekday, null);

      // The weekday is sent so the client renders 周二 without parsing a string.
      const now = new Date();
      assert.equal(b.columns[0]?.weekday, now.getDay());
      assert.equal(
        b.columns[2]?.weekday,
        new Date(now.getFullYear(), now.getMonth(), now.getDate() + 2).getDay(),
      );
    });
  } finally {
    await f.dispose();
  }
});

// ── Bucketing by deadline ───────────────────────────────────

test("board: a deadline decides the column", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const make = async (title: string, dueDate: string | null) =>
        (await json<Task>(await req("POST", "/api/tasks", { title, listId: f.listId, dueDate }))).id;

      const dueToday = await make("今天到期", day(0));
      const tomorrow = await make("明天到期", day(1));
      const dayAfter = await make("后天到期", day(2));
      const nextWeek = await make("下周到期", day(7));
      const overdue = await make("早就该做了", day(-4));

      const b = await board();
      assert.equal(columnOf(b, dueToday), "today");
      assert.equal(columnOf(b, tomorrow), "tomorrow");
      assert.equal(columnOf(b, dayAfter), "dayAfter");
      assert.equal(columnOf(b, nextWeek), "later", "beyond the third column is 以后");
      /*
       * Overdue rolls INTO today rather than staying on a past column nobody can see.
       * A late task that vanished from the board would be the worst possible outcome
       * for a deadline feature.
       */
      assert.equal(columnOf(b, overdue), "today");
    });
  } finally {
    await f.dispose();
  }
});

test("board: created today but due next week is NOT today's business", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      /*
       * The behaviour this milestone changed, and the reason it had to change.
       *
       * `inToday` used to accept any todo created today, so a card typed now and
       * dated next week landed in 我的一天 — defensible for one aggregate view, and
       * plainly wrong on a day board, where it would crowd today while the column
       * the user actually chose sat empty. An explicit date is a stronger signal than
       * the accident of when the card was typed.
       */
      const later = (
        await json<Task>(
          await req("POST", "/api/tasks", { title: "下周的事", listId: f.listId, dueDate: day(6) }),
        )
      ).id;
      // Same card, no deadline: created-today still puts it in today.
      const undated = (
        await json<Task>(await req("POST", "/api/tasks", { title: "随手记的", listId: f.listId }))
      ).id;

      const b = await board();
      assert.equal(columnOf(b, later), "later");
      assert.equal(columnOf(b, undated), "today");

      // And the aggregate view agrees — the board and 我的一天 must not disagree.
      const today = await json<{ groups: Record<string, Task[]> }>(
        await req("GET", "/api/tasks?view=today"),
      );
      const ids = Object.values(today.groups).flat().map((t) => t.id);
      assert.ok(ids.includes(undated), "the undated card is in 我的一天");
      assert.ok(!ids.includes(later), "the dated one is not");
    });
  } finally {
    await f.dispose();
  }
});

test("board: an undated task from an earlier day sits in 以后", async () => {
  const f = await fixture();
  try {
    const id = seed(f.dbPath, f.listId, { title: "上周随手记的", status: "todo" });
    backdate(f.dbPath, id, "2026-01-01T09:00:00.000Z");

    await withEngine(f.dbPath, async () => {
      const b = await board();
      /*
       * No deadline and not created today: real work with no date attached, which is
       * exactly what 以后 is for. Dropping it would hide tasks; putting it in today
       * would refill today every morning with everything ever deferred.
       */
      assert.equal(columnOf(b, id), "later");
    });
  } finally {
    await f.dispose();
  }
});

// ── Live status wins ────────────────────────────────────────

test("board: a live or parked task is today's business whatever its deadline says", async () => {
  const f = await fixture();
  try {
    // Statuses a person cannot set: needs_you is a run outcome, and in_progress
    // without a real run would be a lie the API refuses to tell.
    const running = seed(f.dbPath, f.listId, {
      title: "在跑但明天到期",
      status: "in_progress",
      dueDate: day(1),
      runId: "run-1",
    });
    const parked = seed(f.dbPath, f.listId, {
      title: "卡住但下周到期",
      status: "needs_you",
      dueDate: day(9),
    });
    const review = seed(f.dbPath, f.listId, {
      title: "待确认但后天到期",
      status: "in_review",
      dueDate: day(2),
    });

    await withEngine(f.dbPath, async () => {
      const b = await board();
      /*
       * You are watching these right now. A task mid-run that hid itself on tomorrow's
       * column because of its deadline would be the board contradicting the thing the
       * user is looking at.
       */
      assert.equal(columnOf(b, running), "today");
      assert.equal(columnOf(b, parked), "today");
      assert.equal(columnOf(b, review), "today");
    });
  } finally {
    await f.dispose();
  }
});

// ── Done ────────────────────────────────────────────────────

test("board: finished today stays, finished earlier leaves the board", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const t = (
        await json<Task>(await req("POST", "/api/tasks", { title: "做完的", listId: f.listId }))
      ).id;
      await req("PATCH", `/api/tasks/${t}`, { status: "done" });

      const b = await board();
      assert.equal(columnOf(b, t), "today", "the day's wins stay visible");
      assert.equal(b.columns[0]?.done, 1, "and count toward the progress bar");
    });

    // Back-date the completion: it should disappear from the board entirely.
    const store = new Store(f.dbPath);
    const stale = store.createTask({
      channelId: f.listId,
      title: "上个月做完的",
      status: "done",
      dueDate: day(-40),
      assigneeKind: null,
      assigneeId: null,
      creatorKind: "human",
      creatorId: null,
      sourceMessageId: null,
      runId: null,
    });
    store.close();
    backdate(f.dbPath, stale.id, "2026-07-01T09:00:00.000Z");

    await withEngine(f.dbPath, async () => {
      const b = await board();
      /*
       * A month-old completion with a past deadline must not roll into today. Without
       * the done check it would satisfy the overdue rule forever, and every completed
       * task with a deadline would pile up in today's column permanently.
       */
      assert.equal(columnOf(b, stale.id), null, "old completions are off the board");
    });
  } finally {
    await f.dispose();
  }
});

// ── Ordering and counts ─────────────────────────────────────

test("board: within a column, what needs a person comes first", async () => {
  const f = await fixture();
  try {
    const plain = seed(f.dbPath, f.listId, { title: "普通待办", status: "todo" });
    const review = seed(f.dbPath, f.listId, { title: "待确认", status: "in_review" });
    const parked = seed(f.dbPath, f.listId, { title: "需要你", status: "needs_you" });
    const running = seed(f.dbPath, f.listId, { title: "进行中", status: "in_progress", runId: "r" });

    await withEngine(f.dbPath, async () => {
      const b = await board();
      const order = (b.columns[0]?.tasks ?? []).map((t) => t.id);
      /*
       * The same precedence the status groups use in the old pane, so the two views
       * cannot disagree about which card is most urgent.
       */
      assert.deepEqual(
        order,
        [parked, running, review, plain],
        "needs_you → in_progress → in_review → todo",
      );
    });
  } finally {
    await f.dispose();
  }
});

test("board: counts describe the column they arrive with", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const a = (await json<Task>(await req("POST", "/api/tasks", { title: "a", listId: f.listId }))).id;
      await req("POST", "/api/tasks", { title: "b", listId: f.listId });
      await req("POST", "/api/tasks", { title: "明天", listId: f.listId, dueDate: day(1) });
      await req("PATCH", `/api/tasks/${a}`, { status: "done" });

      const b = await board();
      const today = b.columns[0];
      const tomorrow = b.columns[1];
      assert.equal(today?.total, 2, "two cards in today");
      assert.equal(today?.done, 1, "one of them finished");
      assert.equal(today?.tasks.length, today?.total, "total matches what was sent");
      assert.equal(tomorrow?.total, 1);
      /*
       * A future column can never have a completed task: finishing one moves it to
       * today. So its bar is structurally always empty, which the client should read
       * as "not yet due" rather than rendering 0% as failure.
       */
      assert.equal(tomorrow?.done, 0);
    });
  } finally {
    await f.dispose();
  }
});

test("board: a manual 我的一天 pin still lands in today", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const t = (
        await json<Task>(await req("POST", "/api/tasks", { title: "手动置顶", listId: f.listId }))
      ).id;
      await req("PATCH", `/api/tasks/${t}`, { myDay: day(0) });
      assert.equal(columnOf(await board(), t), "today");

      /*
       * With BOTH a pin and a future deadline, the PIN wins.
       *
       * Worth pinning because the opposite is superficially plausible — "the user
       * named a specific day, that is more precise". But the two fields answer
       * different questions: a deadline is when it must be done BY, a pin is when I
       * am doing it. Starting something due Thursday on Tuesday is ordinary work, and
       * the pin is a click the user just made deliberately. Ignoring it would mean
       * the sun icon silently does nothing on any task with a future deadline.
       */
      await req("PATCH", `/api/tasks/${t}`, { dueDate: day(2) });
      assert.equal(columnOf(await board(), t), "today", "an explicit pin is not outranked");

      /*
       * And a STALE pin does not hold it: `sameLocalDay` only accepts today's, so
       * yesterday's pin falls through to the deadline.
       */
      await req("PATCH", `/api/tasks/${t}`, { myDay: day(-1) });
      assert.equal(columnOf(await board(), t), "dayAfter", "yesterday's pin has expired");
    });
  } finally {
    await f.dispose();
  }
});
