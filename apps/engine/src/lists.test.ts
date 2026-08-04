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
 * The todoagent surface: lists, the derived views (today / needs / done), quick
 * add, delete, cancel.
 *
 * These are the routes the new UI lives on, so their contracts are pinned here:
 * membership of 我的一天 is DERIVED (decision B, 2026-08-02), quick-added tasks
 * land in 收件箱 when no list is chosen, and needs_you is only ever entered by
 * run outcomes — never by hand.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8814; // distinct from the other engine suites
const BASE = `http://127.0.0.1:${PORT}`;

interface Fixture {
  dbPath: string;
  listId: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-lists-"));
  const dbPath = join(root, "l.db");
  const store = new Store(dbPath);
  const list = store.createChannel({
    name: "工作",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
    color: "#3a3a3c",
  });
  store.close();
  return {
    dbPath,
    listId: list.id,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
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

type Groups = Record<TaskStatus, Task[]>;

// ── Lists ───────────────────────────────────────────────────

test("lists: created, patched, archived out of the sidebar", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const created = await req("POST", "/api/lists", { name: "灵光一现", color: "#8e8e93" });
      assert.equal(created.status, 201);
      const list = await json<{ id: string; color: string | null }>(created);
      assert.equal(list.color, "#8e8e93");

      // Rename + recolor round-trips.
      const patched = await json<{ name: string; color: string | null }>(
        await req("PATCH", `/api/lists/${list.id}`, { name: "灵感", color: null }),
      );
      assert.equal(patched.name, "灵感");
      assert.equal(patched.color, null);

      // Archiving removes it from the sidebar without deleting anything.
      await req("PATCH", `/api/lists/${list.id}`, { archived: true });
      const after = await json<{ lists: Array<{ id: string }> }>(await req("GET", "/api/lists"));
      assert.ok(!after.lists.some((l) => l.id === list.id), "archived lists leave the sidebar");

      /*
       * ...and are still reachable, which is what makes archiving reversible.
       *
       * Without this view the operation was one-way in practice: the engine
       * accepted `{archived:false}` but nothing could name a list the user can no
       * longer see, so there was no path back.
       */
      const arch = await json<{ lists: Array<{ id: string; name: string }> }>(
        await req("GET", "/api/lists?archived=1"),
      );
      assert.deepEqual(
        arch.lists.map((l) => l.id),
        [list.id],
        "?archived=1 returns the archived list instead of the live ones",
      );
      assert.equal(arch.lists[0]?.name, "灵感", "it keeps the name it was renamed to");

      // Restoring puts it back where it was.
      await req("PATCH", `/api/lists/${list.id}`, { archived: false });
      const restored = await json<{ lists: Array<{ id: string }> }>(await req("GET", "/api/lists"));
      assert.ok(restored.lists.some((l) => l.id === list.id), "restored lists return to the sidebar");
      const emptyArch = await json<{ lists: unknown[] }>(
        await req("GET", "/api/lists?archived=1"),
      );
      assert.equal(emptyArch.lists.length, 0, "and leave the archived view");
    });
  } finally {
    await f.dispose();
  }
});

test("views: an archived list's view is 404, and its tasks survive the round trip", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const task = await json<Task>(
        await req("POST", "/api/tasks", { title: "归档前的任务", listId: f.listId }),
      );

      // Live, the view works.
      assert.equal((await req("GET", `/api/tasks?view=list:${f.listId}`)).status, 200);

      await req("PATCH", `/api/lists/${f.listId}`, { archived: true });

      /*
       * 404 rather than an empty 200.
       *
       * The list has left the sidebar, so a client asking for it is working from a
       * stale id — another window archived it, or this one held it across the
       * change. The web app falls back to 我的一天 on a 404; answering 200 left it
       * showing a pane titled after a list the user could neither see nor reach.
       */
      const gone = await req("GET", `/api/tasks?view=list:${f.listId}`);
      assert.equal(gone.status, 404, "an archived list's view is not reachable");

      // The task is only hidden, never deleted — that is the promise archiving makes.
      await req("PATCH", `/api/lists/${f.listId}`, { archived: false });
      const back = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${f.listId}`),
      );
      assert.deepEqual(
        back.groups.todo.map((t) => t.id),
        [task.id],
        "restoring the list brings its tasks back with it",
      );
    });
  } finally {
    await f.dispose();
  }
});

test("cors: any loopback port is accepted, a lookalike host is not", async () => {
  /*
   * The HTTP-level counterpart to origin.test.ts, which tests the predicate but
   * not that Hono is actually asking it. Both halves are needed: the M2 symptom
   * was a browser silently dropping responses while curl saw 200, so a wiring
   * mistake here is invisible to every other test in this suite.
   */
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const allowed = await fetch(`${BASE}/api/lists`, {
        headers: { Origin: "http://localhost:3111" },
      });
      assert.equal(
        allowed.headers.get("access-control-allow-origin"),
        "http://localhost:3111",
        "a non-3000 loopback port is echoed back",
      );

      const refused = await fetch(`${BASE}/api/lists`, {
        headers: { Origin: "http://localhost.evil.com" },
      });
      // A domain an attacker can register, which merely STARTS with "localhost".
      // Reaching this API means arbitrary code execution, so this must not pass.
      assert.notEqual(
        refused.headers.get("access-control-allow-origin"),
        "http://localhost.evil.com",
        "a lookalike host must never be echoed back",
      );
    });
  } finally {
    await f.dispose();
  }
});

test("lists: a repo-bound list refuses a non-repo path", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await req("POST", "/api/lists", { name: "x", repoPath: "/tmp" });
      assert.equal(res.status, 400);
      assert.match((await json<{ error: string }>(res)).error, /git/);
    });
  } finally {
    await f.dispose();
  }
});

// ── Quick add & the default list ────────────────────────────

test("tasks: quick add without a list lands in 收件箱, created on demand", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const task = await json<Task>(await req("POST", "/api/tasks", { title: "买猫粮" }));
      const lists = await json<{ lists: Array<{ id: string; name: string; openCount: number }> }>(
        await req("GET", "/api/lists"),
      );
      const inbox = lists.lists.find((l) => l.name === "收件箱");
      assert.ok(inbox, "收件箱 exists after first quick add");
      assert.equal(task.channelId, inbox?.id);
      assert.equal(inbox?.openCount, 1);

      // A second quick add reuses it rather than multiplying inboxes.
      await req("POST", "/api/tasks", { title: "回消息" });
      const again = await json<{ lists: Array<{ name: string }> }>(await req("GET", "/api/lists"));
      assert.equal(again.lists.filter((l) => l.name === "收件箱").length, 1);
    });
  } finally {
    await f.dispose();
  }
});

// ── The derived views ───────────────────────────────────────

test("views: today is derived — created today shows up, needs_you cannot be set by hand", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const t = await json<Task>(
        await req("POST", "/api/tasks", { title: "今天的事", listId: f.listId }),
      );

      const today = await json<{ groups: Groups }>(await req("GET", "/api/tasks?view=today"));
      assert.ok(today.groups.todo.some((x) => x.id === t.id), "a todo created today is in 我的一天");

      // needs_you is a run outcome, not a column a person can drag into.
      const forced = await req("PATCH", `/api/tasks/${t.id}`, { status: "needs_you" });
      assert.equal(forced.status, 400);

      // Completing it moves it out of the open groups and into done, still today.
      await req("PATCH", `/api/tasks/${t.id}`, { status: "done" });
      const after = await json<{ groups: Groups }>(await req("GET", "/api/tasks?view=today"));
      assert.ok(after.groups.done.some((x) => x.id === t.id), "finished today stays visible today");

      const done = await json<{ groups: Groups }>(await req("GET", "/api/tasks?view=done"));
      assert.ok(done.groups.done.some((x) => x.id === t.id));
    });
  } finally {
    await f.dispose();
  }
});

test("views: list view returns every group, unknown views are refused", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      await req("POST", "/api/tasks", { title: "a", listId: f.listId });
      const view = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${f.listId}`),
      );
      assert.deepEqual(Object.keys(view.groups), [
        "todo",
        "in_progress",
        "needs_you",
        "in_review",
        "done",
      ]);
      assert.equal(view.groups.todo.length, 1);

      assert.equal((await req("GET", "/api/tasks?view=list:nope")).status, 404);
      assert.equal((await req("GET", "/api/tasks?view=everything")).status, 400);
    });
  } finally {
    await f.dispose();
  }
});

// ── Destructive operations ──────────────────────────────────

test("tasks: delete removes the row; cancel without a live run is a 409", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const t = await json<Task>(await req("POST", "/api/tasks", { title: "误加的", listId: f.listId }));

      // Cancel refuses when nothing is running — not a silent success.
      assert.equal((await req("POST", `/api/tasks/${t.id}/cancel`)).status, 409);

      assert.equal((await req("DELETE", `/api/tasks/${t.id}`)).status, 200);
      const view = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${f.listId}`),
      );
      assert.equal(view.groups.todo.length, 0);
      // Deleting twice reports the truth.
      assert.equal((await req("DELETE", `/api/tasks/${t.id}`)).status, 404);
    });
  } finally {
    await f.dispose();
  }
});

// ── Moving a task between lists ──────────────────────────────

test("tasks: a task moves to another list, and refuses unusable targets", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const other = await json<{ id: string }>(
        await req("POST", "/api/lists", { name: "以后再说", color: null }),
      );
      const task = await json<Task>(
        await req("POST", "/api/tasks", { title: "放错清单了", listId: f.listId }),
      );

      /*
       * `store.updateTask` has accepted `channelId` since M1 — the HTTP surface
       * simply never exposed it, so a task added to the wrong list could only be
       * fixed by deleting and retyping it.
       */
      const moved = await json<Task>(
        await req("PATCH", `/api/tasks/${task.id}`, { listId: other.id }),
      );
      assert.equal(moved.channelId, other.id, "the response reports the new list");

      // And it is reachable there, which is the part a user cares about.
      const target = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${other.id}`),
      );
      assert.deepEqual(
        target.groups.todo.map((t) => t.id),
        [task.id],
        "the task shows up in the destination list's view",
      );
      const source = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${f.listId}`),
      );
      assert.equal(source.groups.todo.length, 0, "and is gone from the one it left");

      // A list that does not exist. 400, not 404: the task URL is correct, it is
      // the body that names something unusable — matching the assignee check.
      const unknown = await req("PATCH", `/api/tasks/${task.id}`, { listId: "no-such-list" });
      assert.equal(unknown.status, 400);
      assert.match((await json<{ error: string }>(unknown)).error, /unknown list/);

      /*
       * An archived list is refused, and this one matters more than it looks.
       *
       * `GET /api/tasks?view=list:<id>` 404s an archived list, so a task moved into
       * one would be unreachable from every view — it would look deleted while
       * still counting toward the sidebar totals.
       */
      await req("PATCH", `/api/lists/${other.id}`, { archived: true });
      const archived = await req("PATCH", `/api/tasks/${task.id}`, { listId: other.id });
      assert.equal(archived.status, 400);
      assert.match((await json<{ error: string }>(archived)).error, /归档/);

      // The failures changed nothing: the task is still where the move put it.
      const still = await json<{ groups: Groups }>(
        await req("GET", `/api/tasks?view=list:${f.listId}`),
      );
      assert.equal(still.groups.todo.length, 0, "a rejected move must not move anything");
    });
  } finally {
    await f.dispose();
  }
});
