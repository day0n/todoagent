import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@council/core";

/**
 * Channel layer endpoints.
 *
 * The schema carries no foreign keys by design, so every reference these
 * endpoints accept has to be checked in application code. An unchecked id does
 * not fail loudly — it inserts happily and surfaces later as a channel whose
 * project cannot be loaded, or a message whose author renders blank. Most of
 * what follows pins down those refusals.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8811; // distinct from the other engine suites

const BASE = `http://127.0.0.1:${PORT}`;

interface Fixture {
  dbPath: string;
  expertId: string;
  projectId: string;
  channelId: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "council-channels-"));
  const dbPath = join(root, "c.db");
  const store = new Store(dbPath);

  const expert = store.createExpert({
    name: "Ada",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  // No git validation runs on this path, so the repo need not be real here —
  // channels only hold the id.
  const project = store.createProject({ name: "p", repoPath: root, teamId: team.id });
  const channel = store.createChannel({
    name: "general",
    purpose: "",
    kind: "channel",
    projectId: project.id,
    dmExpertId: null,
  });
  store.close();

  return {
    dbPath,
    expertId: expert.id,
    projectId: project.id,
    channelId: channel.id,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

async function withEngine<T>(dbPath: string, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: { ...process.env, COUNCIL_DB: dbPath, COUNCIL_PORT: String(PORT) },
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

function post(path: string, body: unknown): Promise<Response> {
  return fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function patch(path: string, body: unknown): Promise<Response> {
  return fetch(`${BASE}${path}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

// ── Channels ────────────────────────────────────────────────

test("channels: an unknown project or expert is refused, since there are no FKs", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const badProject = await post("/api/channels", { name: "x", projectId: "nope" });
      assert.equal(badProject.status, 400);
      assert.match((await json<{ error: string }>(badProject)).error, /unknown project/);

      const badExpert = await post("/api/channels", {
        name: "x",
        kind: "dm",
        dmExpertId: "nope",
      });
      assert.equal(badExpert.status, 400);
      assert.match((await json<{ error: string }>(badExpert)).error, /unknown expert/);

      // A dm with nobody on the other side is an empty room wearing a name.
      const namelessDm = await post("/api/channels", { name: "x", kind: "dm" });
      assert.equal(namelessDm.status, 400);
      assert.match((await json<{ error: string }>(namelessDm)).error, /needs dmExpertId/);

      // And none of the refusals stored anything.
      const list = await json<unknown[]>(await fetch(`${BASE}/api/channels`));
      assert.equal(list.length, 1, "only the fixture channel exists");
    });
  } finally {
    await f.dispose();
  }
});

test("channels: a project channel and a DM are both creatable", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const chan = await post("/api/channels", {
        name: "web",
        purpose: "the web app",
        projectId: f.projectId,
      });
      assert.equal(chan.status, 201);
      assert.equal((await json<{ projectId: string }>(chan)).projectId, f.projectId);

      const dm = await post("/api/channels", {
        name: "Ada",
        kind: "dm",
        dmExpertId: f.expertId,
      });
      assert.equal(dm.status, 201);
      const body = await json<{ kind: string; dmExpertId: string; projectId: string | null }>(dm);
      assert.equal(body.kind, "dm");
      assert.equal(body.dmExpertId, f.expertId);
      // A DM has no repository, and that is a legitimate state.
      assert.equal(body.projectId, null);
    });
  } finally {
    await f.dispose();
  }
});

// ── Messages ────────────────────────────────────────────────

test("messages: an unknown channel is 404, not a 500 or a silent success", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      assert.equal((await fetch(`${BASE}/api/channels/nope/messages`)).status, 404);
      assert.equal((await post("/api/channels/nope/messages", { body: "hi" })).status, 404);
      assert.equal((await fetch(`${BASE}/api/channels/nope/tasks`)).status, 404);
      assert.equal((await fetch(`${BASE}/api/messages/nope/replies`)).status, 404);
      assert.equal((await patch("/api/tasks/nope", { status: "done" })).status, 404);
    });
  } finally {
    await f.dispose();
  }
});

test("messages: posting appears in the channel stream", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await post(`/api/channels/${f.channelId}/messages`, { body: "first" });
      assert.equal(res.status, 201);
      const created = await json<{ message: { id: string; seq: number }; task: null }>(res);
      assert.ok(created.message.seq > 0, "seq must come back from the insert");
      assert.equal(created.task, null, "no task unless asTask was set");

      const stream = await json<{ messages: Array<{ body: string; replyCount: number }> }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/messages`),
      );
      assert.deepEqual(stream.messages.map((m) => m.body), ["first"]);
      assert.equal(stream.messages[0]?.replyCount, 0);
    });
  } finally {
    await f.dispose();
  }
});

test("messages: an expert author must exist and be identified", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const noId = await post(`/api/channels/${f.channelId}/messages`, {
        body: "hi",
        authorKind: "expert",
      });
      assert.equal(noId.status, 400);
      assert.match((await json<{ error: string }>(noId)).error, /needs authorId/);

      const unknown = await post(`/api/channels/${f.channelId}/messages`, {
        body: "hi",
        authorKind: "expert",
        authorId: "nope",
      });
      assert.equal(unknown.status, 400);

      const ok = await post(`/api/channels/${f.channelId}/messages`, {
        body: "on it",
        authorKind: "expert",
        authorId: f.expertId,
      });
      assert.equal(ok.status, 201);
      assert.equal((await json<{ message: { authorId: string } }>(ok)).message.authorId, f.expertId);
    });
  } finally {
    await f.dispose();
  }
});

test("threads: one level deep, and never across channels", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const root = (
        await json<{ message: { id: string } }>(
          await post(`/api/channels/${f.channelId}/messages`, { body: "root" }),
        )
      ).message.id;

      const reply = await post(`/api/channels/${f.channelId}/messages`, {
        body: "reply",
        parentId: root,
      });
      assert.equal(reply.status, 201);
      const replyId = (await json<{ message: { id: string } }>(reply)).message.id;

      /*
       * A reply-to-a-reply is refused rather than flattened onto the root.
       * Flattening would silently move the message somewhere the author did not
       * point at, which is worse than saying no.
       */
      const nested = await post(`/api/channels/${f.channelId}/messages`, {
        body: "nested",
        parentId: replyId,
      });
      assert.equal(nested.status, 400);
      assert.match((await json<{ error: string }>(nested)).error, /one level deep/);

      // Cross-channel threading would put a message in a channel whose own
      // stream query cannot see it.
      const other = (
        await json<{ id: string }>(await post("/api/channels", { name: "other" }))
      ).id;
      const crossed = await post(`/api/channels/${other}/messages`, {
        body: "wrong room",
        parentId: root,
      });
      assert.equal(crossed.status, 400);
      assert.match((await json<{ error: string }>(crossed)).error, /another channel/);

      // The stream still shows one root carrying one reply.
      const stream = await json<{ messages: Array<{ body: string; replyCount: number }> }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/messages`),
      );
      assert.equal(stream.messages.length, 1);
      assert.equal(stream.messages[0]?.replyCount, 1);

      const thread = await json<{ replies: Array<{ body: string }> }>(
        await fetch(`${BASE}/api/messages/${root}/replies`),
      );
      assert.deepEqual(thread.replies.map((r) => r.body), ["reply"]);
    });
  } finally {
    await f.dispose();
  }
});

test("messages: limit is clamped, so no client can ask for the whole table", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      for (let i = 1; i <= 4; i++) {
        await post(`/api/channels/${f.channelId}/messages`, { body: `m${i}` });
      }

      const two = await json<{ messages: Array<{ body: string }> }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/messages?limit=2`),
      );
      // Newest two, still oldest-first.
      assert.deepEqual(two.messages.map((m) => m.body), ["m3", "m4"]);

      // Absurd, negative and non-numeric limits all resolve to something sane
      // rather than erroring or serialising everything.
      for (const q of ["1e9", "-5", "abc", "0"]) {
        const res = await fetch(`${BASE}/api/channels/${f.channelId}/messages?limit=${q}`);
        assert.equal(res.status, 200, `limit=${q} should not fail`);
        const body = await json<{ messages: unknown[] }>(res);
        assert.ok(body.messages.length >= 1 && body.messages.length <= 4, `limit=${q}`);
      }
    });
  } finally {
    await f.dispose();
  }
});

// ── Chat → board ────────────────────────────────────────────

test("asTask: one action both says the thing and creates the card", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await post(`/api/channels/${f.channelId}/messages`, {
        body: "缓存一下 roster 查询\n第二行不该进标题",
        asTask: true,
      });
      assert.equal(res.status, 201);
      const created = await json<{
        message: { id: string };
        task: { title: string; status: string; sourceMessageId: string; assigneeKind: null };
      }>(res);

      assert.ok(created.task, "asTask must return the card it made");
      // A board card wants a line, not an essay — the full text stays on the
      // message this points back at.
      assert.equal(created.task.title, "缓存一下 roster 查询");
      assert.equal(created.task.status, "todo");
      assert.equal(created.task.sourceMessageId, created.message.id);
      // Nobody has claimed it yet, and that is a null rather than a placeholder.
      assert.equal(created.task.assigneeKind, null);

      const board = await json<{ board: Record<string, Array<{ title: string }>> }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/tasks`),
      );
      assert.deepEqual(board.board.todo.map((t) => t.title), ["缓存一下 roster 查询"]);
    });
  } finally {
    await f.dispose();
  }
});

// ── Board ───────────────────────────────────────────────────

test("board: every column is present even with no tasks", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const res = await json<{ board: Record<string, unknown[]> }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/tasks`),
      );
      assert.deepEqual(Object.keys(res.board).sort(), [
        "done",
        "in_progress",
        "in_review",
        "todo",
      ]);
    });
  } finally {
    await f.dispose();
  }
});

test("tasks: several titles at once, all or none", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const ok = await post(`/api/channels/${f.channelId}/tasks`, {
        titles: ["one", "  two  ", "three"],
      });
      assert.equal(ok.status, 201);
      const tasks = await json<Array<{ title: string; status: string }>>(ok);
      assert.deepEqual(tasks.map((t) => t.title), ["one", "two", "three"]);
      assert.ok(tasks.every((t) => t.status === "todo"));

      // An invalid entry rejects the batch instead of storing part of it, so the
      // user never has to compare what they typed against what appeared.
      const partial = await post(`/api/channels/${f.channelId}/tasks`, {
        titles: ["good", ""],
      });
      assert.equal(partial.status, 400);
      const after = await json<{ tasks: unknown[] }>(
        await fetch(`${BASE}/api/channels/${f.channelId}/tasks`),
      );
      assert.equal(after.tasks.length, 3, "the rejected batch stored nothing");

      assert.equal((await post(`/api/channels/${f.channelId}/tasks`, { titles: [] })).status, 400);
    });
  } finally {
    await f.dispose();
  }
});

test("tasks: assignment is a pair, and unclaiming clears both halves", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const id = (
        await json<Array<{ id: string }>>(
          await post(`/api/channels/${f.channelId}/tasks`, { titles: ["claim me"] }),
        )
      )[0]!.id;

      // `expert` with no id is unresolvable; accepting it would render as an
      // assignee nobody can look up.
      const noId = await patch(`/api/tasks/${id}`, { assignee: { kind: "expert", id: null } });
      assert.equal(noId.status, 400);
      assert.match((await json<{ error: string }>(noId)).error, /needs an id/);

      assert.equal(
        (await patch(`/api/tasks/${id}`, { assignee: { kind: "expert", id: "nope" } })).status,
        400,
      );

      const claimed = await patch(`/api/tasks/${id}`, {
        assignee: { kind: "expert", id: f.expertId },
        status: "in_progress",
      });
      assert.equal(claimed.status, 200);
      const body = await json<{ assigneeKind: string; assigneeId: string; status: string }>(claimed);
      assert.equal(body.assigneeKind, "expert");
      assert.equal(body.assigneeId, f.expertId);
      assert.equal(body.status, "in_progress");

      const cleared = await json<{ assigneeKind: null; assigneeId: null }>(
        await patch(`/api/tasks/${id}`, { assignee: null }),
      );
      assert.equal(cleared.assigneeKind, null);
      assert.equal(cleared.assigneeId, null);
    });
  } finally {
    await f.dispose();
  }
});

test("tasks: an unknown status is refused rather than stored", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      const id = (
        await json<Array<{ id: string }>>(
          await post(`/api/channels/${f.channelId}/tasks`, { titles: ["t"] }),
        )
      )[0]!.id;

      // The board renders a fixed set of columns; a status outside them has
      // nowhere to go.
      assert.equal((await patch(`/api/tasks/${id}`, { status: "archived" })).status, 400);
      assert.equal((await patch(`/api/tasks/${id}`, { status: "reworking" })).status, 400);

      // An empty patch is valid and changes nothing.
      const untouched = await patch(`/api/tasks/${id}`, {});
      assert.equal(untouched.status, 200);
      assert.equal((await json<{ status: string }>(untouched)).status, "todo");
    });
  } finally {
    await f.dispose();
  }
});

test("malformed bodies are 400, not 500", async () => {
  const f = await fixture();
  try {
    await withEngine(f.dbPath, async () => {
      for (const [path, method] of [
        [`/api/channels`, "POST"],
        [`/api/channels/${f.channelId}/messages`, "POST"],
        [`/api/channels/${f.channelId}/tasks`, "POST"],
      ] as const) {
        const res = await fetch(`${BASE}${path}`, {
          method,
          headers: { "Content-Type": "application/json" },
          body: "{ not json",
        });
        assert.equal(res.status, 400, `${method} ${path} on malformed JSON`);
      }
    });
  } finally {
    await f.dispose();
  }
});
