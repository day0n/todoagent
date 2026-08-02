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
