import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";
import type { AgentChatMessage, ChatSession, Task } from "@todoagent/core/types";

/**
 * The main agent, end to end through the PRODUCTION code path.
 *
 * No fake-LLM branch exists in the engine. Instead, the pi SDK is pointed at a
 * scripted OpenAI-compatible server via `models.json` in a temporary agentDir —
 * exactly the mechanism a user would use for a local vLLM/Ollama endpoint. The
 * secretary resolves the model, streams the response, executes the scripted
 * tool call, and writes real rows; the only fake thing is the text the "model"
 * decided to say.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8815; // distinct from the other engine suites
const BASE = `http://127.0.0.1:${PORT}`;

/** SSE frames for one OpenAI chat.completions streaming response. */
function sse(chunks: unknown[]): string {
  return `${chunks.map((c) => `data: ${JSON.stringify(c)}`).join("\n\n")}\n\ndata: [DONE]\n\n`;
}

/**
 * The scripted "model": first call answers with a create_tasks tool call,
 * the follow-up call (which carries the tool result) answers with text.
 */
function scriptedCompletion(requestBody: string): string {
  const parsed = JSON.parse(requestBody) as { messages: Array<{ role: string }> };
  const sawToolResult = parsed.messages.some((m) => m.role === "tool");

  if (!sawToolResult) {
    const args = JSON.stringify({ tasks: [{ title: "买猫粮" }, { title: "回消息", note: "微信里的三条" }] });
    return sse([
      { id: "c1", object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant" } }] },
      {
        id: "c1",
        object: "chat.completion.chunk",
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [
                { index: 0, id: "call_1", type: "function", function: { name: "create_tasks", arguments: "" } },
              ],
            },
          },
        ],
      },
      {
        id: "c1",
        object: "chat.completion.chunk",
        choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: args } }] } }],
      },
      {
        id: "c1",
        object: "chat.completion.chunk",
        choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
        usage: { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 },
      },
    ]);
  }

  return sse([
    { id: "c2", object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant" } }] },
    {
      id: "c2",
      object: "chat.completion.chunk",
      choices: [{ index: 0, delta: { content: "两张卡建好了，都在收件箱。" } }],
    },
    {
      id: "c2",
      object: "chat.completion.chunk",
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: 40, completion_tokens: 12, total_tokens: 52 },
    },
  ]);
}

function startFakeLlm(): Promise<{ server: Server; port: number }> {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      let body = "";
      req.on("data", (d: Buffer) => {
        body += d.toString();
      });
      req.on("end", () => {
        const respond = (): void => {
          res.writeHead(200, {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
          });
          res.end(scriptedCompletion(body));
        };
        // A marker the user text carries through both calls of a turn (it's
        // part of conversation history by the follow-up call), used by the
        // concurrency test to hold one session's turn open long enough to
        // prove a second session is not blocked by it.
        if (body.includes("SLOW_MARKER")) setTimeout(respond, 400);
        else respond();
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({ server, port: typeof address === "object" && address !== null ? address.port : 0 });
    });
  });
}

interface Fixture {
  root: string;
  dbPath: string;
  agentDir: string;
  llm: Server;
  llmPort: number;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-chat-"));
  const dbPath = join(root, "c.db");
  const agentDir = join(root, "pi");
  await mkdir(agentDir, { recursive: true });

  const { server, port } = await startFakeLlm();
  await writeFile(
    join(agentDir, "models.json"),
    JSON.stringify({
      providers: {
        fake: {
          baseUrl: `http://127.0.0.1:${port}/v1`,
          api: "openai-completions",
          apiKey: "test-key",
          models: [{ id: "scripted" }],
        },
      },
    }),
    "utf8",
  );

  // The db just needs to exist with the schema; the default 收件箱 is created on
  // demand by the quick-add path the tool shares.
  new Store(dbPath).close();

  return {
    root,
    dbPath,
    agentDir,
    llm: server,
    llmPort: port,
    dispose: async () => {
      server.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

async function withEngine<T>(
  f: Fixture,
  env: Record<string, string>,
  fn: () => Promise<T>,
): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: f.dbPath,
      TODOAGENT_PORT: String(PORT),
      TODOAGENT_AGENT_DIR: f.agentDir,
      TODOAGENT_AGENT_CWD: f.root,
      // Isolated from a developer's real `~/.todoagent/uploads` — a test image
      // must never land next to (or overwrite an id colliding with) real data.
      TODOAGENT_UPLOADS_DIR: join(f.root, "uploads"),
      // Cleared so a developer's real config cannot leak into the test, then
      // selectively re-added per test via `env`.
      TODOAGENT_MODEL: "",
      TODOAGENT_API_KEY: "",
      ...env,
    },
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

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

async function newSession(title = ""): Promise<string> {
  const session = await json<ChatSession>(await post("/api/chat/sessions", { title }));
  return session.id;
}

/**
 * A 1x1 transparent PNG, base64-encoded — the smallest valid input the
 * `/api/chat` image path (and its `mediaType` validation) will accept.
 */
const TINY_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUAAdafFs0AAAAASUVORK5CYII=";

/**
 * An open SSE connection on `/api/stream` whose frames can be awaited one at
 * a time, filtered to the chat channel — same shape as `board-stream.test.ts`'s
 * `listen`, since the wire format (bare `data:` frames, no `event:` field) is
 * identical for both channels on this one endpoint.
 */
interface ChatListener {
  next(ms: number): Promise<Record<string, unknown> | null>;
  close(): void;
}

async function listenChat(): Promise<ChatListener> {
  const controller = new AbortController();
  const res = await fetch(`${BASE}/api/stream`, { signal: controller.signal });
  assert.equal(res.status, 200);

  const reader = res.body?.getReader();
  assert.ok(reader, "the response must expose a readable body");

  const decoder = new TextDecoder();
  let raw = "";
  let cursor = 0;
  const queue: Array<Record<string, unknown>> = [];

  const drain = (): void => {
    for (;;) {
      const at = raw.indexOf("\n\n", cursor);
      if (at === -1) return;
      const chunk = raw.slice(cursor, at);
      cursor = at + 2;
      const dataLine = chunk.split("\n").find((l) => l.startsWith("data: "));
      if (dataLine === undefined) continue;
      try {
        queue.push(JSON.parse(dataLine.slice(6)) as Record<string, unknown>);
      } catch {
        /* comment/keepalive frame or otherwise not JSON */
      }
    }
  };

  let done = false;
  const pump = (async () => {
    try {
      for (;;) {
        const r = await reader.read();
        if (r.done) break;
        raw += decoder.decode(r.value, { stream: true });
        drain();
      }
    } catch {
      /* aborted, which is how this ends */
    } finally {
      done = true;
    }
  })();

  return {
    async next(ms: number) {
      const deadline = Date.now() + ms;
      for (;;) {
        const head = queue.shift();
        if (head !== undefined) return head;
        if (done) return null;
        if (Date.now() > deadline) return null;
        await new Promise((r) => setTimeout(r, 20));
      }
    },
    close() {
      controller.abort();
      void pump;
    },
  };
}

// ── Unconfigured: a first-class state, not an error ─────────

test("chat: without a model the status says why and posting is a 503", async () => {
  const f = await fixture();
  try {
    await withEngine(f, {}, async () => {
      const status = await json<{ ready: boolean; reason?: string }>(
        await fetch(`${BASE}/api/chat/status`),
      );
      assert.equal(status.ready, false);
      assert.match(status.reason ?? "", /TODOAGENT_MODEL/);

      const sessionId = await newSession();
      const res = await post("/api/chat", { sessionId, body: "在吗" });
      assert.equal(res.status, 503);
      assert.match((await json<{ error: string }>(res)).error, /TODOAGENT_MODEL/);
    });
  } finally {
    await f.dispose();
  }
});

// ── The full loop against the scripted model ────────────────

test("chat: one sentence becomes two real cards, refs and history included", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const status = await json<{ ready: boolean; model?: string }>(
        await fetch(`${BASE}/api/chat/status`),
      );
      assert.equal(status.ready, true, "the scripted provider must resolve");
      assert.equal(status.model, "fake/scripted");

      const sessionId = await newSession();
      const res = await post("/api/chat", { sessionId, body: "帮我加两个任务：买猫粮，还有回消息" });
      assert.equal(res.status, 201, JSON.stringify(await res.clone().json()));
      const turn = await json<{ user: AgentChatMessage; agent: AgentChatMessage }>(res);

      assert.equal(turn.user.role, "user");
      assert.equal(turn.agent.role, "agent");
      assert.match(turn.agent.body, /建好了/);
      assert.equal(turn.agent.taskRefs.length, 2, "both created cards travel as refs");

      // The cards are real rows in the default inbox, not just chat text.
      const view = await json<{ groups: { todo: Task[] } }>(
        await fetch(`${BASE}/api/tasks?view=today`),
      );
      const titles = view.groups.todo.map((t) => t.title).sort();
      assert.deepEqual(titles, ["回消息", "买猫粮"].sort());
      const noted = view.groups.todo.find((t) => t.title === "回消息");
      assert.equal(noted?.note, "微信里的三条", "the note survives the tool call");

      // History resolves refs to titles for the inline cards.
      const history = await json<{
        messages: AgentChatMessage[];
        tasks: Record<string, { title: string }>;
      }>(await fetch(`${BASE}/api/chat/history?sessionId=${sessionId}`));
      assert.equal(history.messages.length, 2);
      for (const id of turn.agent.taskRefs) {
        assert.ok(history.tasks[id], `ref ${id} resolves`);
      }
    });
  } finally {
    await f.dispose();
  }
});

// ── Multi-session isolation ──────────────────────────────────

test("chat: two sessions have independent histories and don't 409 each other", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const sessionA = await newSession("会话 A");
      const sessionB = await newSession("会话 B");
      assert.notEqual(sessionA, sessionB);

      const resA = await post("/api/chat", { sessionId: sessionA, body: "帮我加两个任务：买猫粮，还有回消息" });
      assert.equal(resA.status, 201, JSON.stringify(await resA.clone().json()));
      const resB = await post("/api/chat", { sessionId: sessionB, body: "帮我加两个任务：买猫粮，还有回消息" });
      assert.equal(
        resB.status,
        201,
        `B is not blocked by A's finished turn: ${JSON.stringify(await resB.clone().json())}`,
      );

      const historyA = await json<{ messages: AgentChatMessage[] }>(
        await fetch(`${BASE}/api/chat/history?sessionId=${sessionA}`),
      );
      const historyB = await json<{ messages: AgentChatMessage[] }>(
        await fetch(`${BASE}/api/chat/history?sessionId=${sessionB}`),
      );
      assert.equal(historyA.messages.length, 2, "only A's own turn shows up in A's history");
      assert.equal(historyB.messages.length, 2, "only B's own turn shows up in B's history");
      assert.ok(
        historyA.messages.every((m) => m.sessionId === sessionA),
        "no message in A's history belongs to another session",
      );
      assert.ok(
        historyB.messages.every((m) => m.sessionId === sessionB),
        "no message in B's history belongs to another session",
      );

      // 4 cards total in the shared inbox — 2 per session, none deduped or lost.
      const view = await json<{ groups: { todo: Task[] } }>(await fetch(`${BASE}/api/tasks?view=today`));
      assert.equal(view.groups.todo.length, 4);
    });
  } finally {
    await f.dispose();
  }
});

test("chat: sessions CRUD — create, list, rename, archive closes its live agent", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const created = await json<ChatSession>(await post("/api/chat/sessions", { title: "买菜清单" }));
      assert.equal(created.title, "买菜清单");
      assert.equal(created.archivedAt, null);

      const listed = await json<ChatSession[]>(await fetch(`${BASE}/api/chat/sessions`));
      assert.ok(listed.some((s) => s.id === created.id), "the new session shows up in the default (unarchived) list");

      // Give it a live AgentSession so archiving has something real to close.
      const chatRes = await post("/api/chat", { sessionId: created.id, body: "在吗" });
      assert.equal(chatRes.status, 201);

      const renamed = await json<ChatSession>(
        await fetch(`${BASE}/api/chat/sessions/${created.id}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ title: "购物清单" }),
        }),
      );
      assert.equal(renamed.title, "购物清单");

      const archived = await json<ChatSession>(
        await fetch(`${BASE}/api/chat/sessions/${created.id}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ archived: true }),
        }),
      );
      assert.ok(archived.archivedAt, "archiving stamps archivedAt");

      const listedAfter = await json<ChatSession[]>(await fetch(`${BASE}/api/chat/sessions`));
      assert.ok(!listedAfter.some((s) => s.id === created.id), "an archived session leaves the default list");

      const archivedList = await json<ChatSession[]>(await fetch(`${BASE}/api/chat/sessions?archived=1`));
      assert.ok(archivedList.some((s) => s.id === created.id), "…but still shows up under ?archived=1");

      // A second turn against the now-archived (and closed) session still works:
      // closeSession only drops the warm AgentSession, not the conversation itself.
      const afterArchive = await post("/api/chat", { sessionId: created.id, body: "还在吗" });
      assert.equal(afterArchive.status, 201, "an archived session can still be reopened by a new turn");

      const patchUnknown = await fetch(`${BASE}/api/chat/sessions/does-not-exist`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: "x" }),
      });
      assert.equal(patchUnknown.status, 404);
    });
  } finally {
    await f.dispose();
  }
});

test("chat: an unknown sessionId in POST /api/chat is a 404, not a silently-created row", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const res = await post("/api/chat", { sessionId: "ghost-session", body: "在吗" });
      assert.equal(res.status, 404);
    });
  } finally {
    await f.dispose();
  }
});

// ── Concurrency: sessions run independently, one session serializes ──

test("chat: a slow turn in one session never blocks a turn in another", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const slow = await newSession();
      const fast = await newSession();

      // `SLOW_MARKER` makes the fake LLM hold its response for 400ms — long
      // enough to prove a concurrent request to a DIFFERENT session isn't
      // waiting behind it, without making the suite slow.
      const slowPromise = post("/api/chat", { sessionId: slow, body: "SLOW_MARKER 帮我加个任务：慢慢来" });

      // Give the slow request a moment to actually start streaming before
      // racing the fast one, so this exercises real overlap rather than luck.
      await new Promise((r) => setTimeout(r, 50));

      const fastStart = Date.now();
      const fastRes = await post("/api/chat", { sessionId: fast, body: "帮我加个任务：快速的" });
      const fastElapsed = Date.now() - fastStart;
      assert.equal(fastRes.status, 201);
      assert.ok(
        fastElapsed < 350,
        `session B resolved in ${fastElapsed}ms while A was still streaming — it must not queue behind A`,
      );

      const slowRes = await slowPromise;
      assert.equal(slowRes.status, 201, JSON.stringify(await slowRes.clone().json()));
    });
  } finally {
    await f.dispose();
  }
});

test("chat: a second turn against the SAME still-streaming session is a 409", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const sessionId = await newSession();

      const first = post("/api/chat", { sessionId, body: "SLOW_MARKER 帮我加个任务：排队测试" });
      // Let the first request claim the session's busy flag before the second fires.
      await new Promise((r) => setTimeout(r, 50));

      const second = await post("/api/chat", { sessionId, body: "还有一件事" });
      assert.equal(second.status, 409);
      assert.match((await json<{ error: string }>(second)).error, /上一轮/);

      const firstRes = await first;
      assert.equal(firstRes.status, 201, JSON.stringify(await firstRes.clone().json()));

      // Once the first turn is done, the session is free again.
      const third = await post("/api/chat", { sessionId, body: "再加一个" });
      assert.equal(third.status, 201);
    });
  } finally {
    await f.dispose();
  }
});

// ── Image attachments ────────────────────────────────────────

test("chat: an image attachment is saved, served back, and travels through history", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const sessionId = await newSession();
      const res = await post("/api/chat", {
        sessionId,
        body: "这张图是什么",
        images: [{ mediaType: "image/png", data: TINY_PNG_BASE64, width: 1, height: 1 }],
      });
      assert.equal(res.status, 201, JSON.stringify(await res.clone().json()));
      const turn = await json<{ user: AgentChatMessage }>(res);

      assert.equal(turn.user.attachments.length, 1);
      const attachment = turn.user.attachments[0];
      assert.equal(attachment?.mediaType, "image/png");
      assert.equal(attachment?.width, 1);
      assert.ok(attachment?.url.startsWith("/api/uploads/"));

      const served = await fetch(`${BASE}${attachment?.url}`);
      assert.equal(served.status, 200);
      assert.equal(served.headers.get("content-type"), "image/png");
      const bytes = Buffer.from(await served.arrayBuffer());
      assert.deepEqual(bytes, Buffer.from(TINY_PNG_BASE64, "base64"), "the served bytes round-trip exactly");

      const history = await json<{ messages: AgentChatMessage[] }>(
        await fetch(`${BASE}/api/chat/history?sessionId=${sessionId}`),
      );
      const userRow = history.messages.find((m) => m.role === "user");
      assert.equal(userRow?.attachments.length, 1, "the attachment survives the round trip through the db");
      assert.equal(userRow?.attachments[0]?.url, attachment?.url);
    });
  } finally {
    await f.dispose();
  }
});

test("chat: a message with no text but an image is accepted; an entirely empty body is rejected", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const sessionId = await newSession();

      const imageOnly = await post("/api/chat", {
        sessionId,
        images: [{ mediaType: "image/png", data: TINY_PNG_BASE64 }],
      });
      assert.equal(imageOnly.status, 201, "an image alone is content enough to send");

      const empty = await post("/api/chat", { sessionId, body: "" });
      assert.equal(empty.status, 400, "neither text nor an image was provided");

      const badId = await fetch(`${BASE}/api/uploads/secret.pdf`);
      assert.equal(badId.status, 400, "an id whose extension isn't an allowed image type is refused structurally");

      const missing = await fetch(`${BASE}/api/uploads/does-not-exist.png`);
      assert.equal(missing.status, 404);
    });
  } finally {
    await f.dispose();
  }
});

// ── Streaming: chat:delta over /api/stream ───────────────────

test("chat: the SSE stream carries chat:thinking + chat:delta + chat:message, scoped to the right session", async () => {
  const f = await fixture();
  try {
    await withEngine(f, { TODOAGENT_MODEL: "fake/scripted" }, async () => {
      const sessionId = await newSession();
      const otherSessionId = await newSession();
      const stream = await listenChat();
      try {
        const chatPromise = post("/api/chat", { sessionId, body: "帮我加两个任务：买猫粮，还有回消息" });

        const seen: Record<string, unknown>[] = [];
        let sawDelta = false;
        let deltaText = "";
        const deadline = Date.now() + 10_000;
        while (Date.now() < deadline) {
          const ev = await stream.next(1_000);
          if (ev === null) continue;
          seen.push(ev);
          if (ev["type"] === "chat:delta") {
            sawDelta = true;
            deltaText += String(ev["text"] ?? "");
          }
          // `chat:thinking off` is the last frame this turn publishes (in the
          // route's `finally`, after the agent's `chat:message`), so waiting
          // for it — rather than the 2nd `chat:message` — avoids racing ahead
          // of it and missing it entirely.
          if (ev["type"] === "chat:thinking" && ev["on"] === false) break;
        }

        const res = await chatPromise;
        assert.equal(res.status, 201, JSON.stringify(await res.clone().json()));

        const thinkingOn = seen.find((e) => e["type"] === "chat:thinking" && e["on"] === true);
        const thinkingOff = seen.find((e) => e["type"] === "chat:thinking" && e["on"] === false);
        assert.ok(thinkingOn, "a thinking-on frame is published before the turn resolves");
        assert.ok(thinkingOff, "a thinking-off frame is published once the turn resolves");
        assert.equal(thinkingOn?.["sessionId"], sessionId);
        assert.equal(thinkingOff?.["sessionId"], sessionId);

        assert.ok(sawDelta, "at least one chat:delta frame arrives while the model streams its final answer");
        assert.ok(deltaText.length > 0, "the accumulated delta text is non-empty");
        // The scripted model's final-answer chunk is "两张卡建好了，都在收件箱。" —
        // the deltas concatenate back into (a prefix of) that same text.
        assert.ok(
          "两张卡建好了，都在收件箱。".startsWith(deltaText) || deltaText.includes("建好了"),
          `delta text should reassemble the model's answer, got ${JSON.stringify(deltaText)}`,
        );

        for (const ev of seen) {
          if (ev["type"] === "chat:delta" || ev["type"] === "chat:thinking" || ev["type"] === "chat:message") {
            assert.equal(
              ev["sessionId"],
              sessionId,
              `no frame may be tagged with a foreign sessionId: ${JSON.stringify(ev)}`,
            );
          }
        }
        assert.ok(
          !seen.some((e) => e["sessionId"] === otherSessionId),
          "nothing about the untouched session is announced on the stream",
        );
      } finally {
        stream.close();
      }
    });
  } finally {
    await f.dispose();
  }
});
