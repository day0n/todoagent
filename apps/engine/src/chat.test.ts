import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";
import type { AgentChatMessage, Task } from "@todoagent/core/types";

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
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
        });
        res.end(scriptedCompletion(body));
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

      const res = await post("/api/chat", { body: "在吗" });
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

      const res = await post("/api/chat", { body: "帮我加两个任务：买猫粮，还有回消息" });
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
      }>(await fetch(`${BASE}/api/chat/history`));
      assert.equal(history.messages.length, 2);
      for (const id of turn.agent.taskRefs) {
        assert.ok(history.tasks[id], `ref ${id} resolves`);
      }
    });
  } finally {
    await f.dispose();
  }
});
