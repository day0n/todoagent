import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import {
  createAgentSession,
  defineTool,
  DefaultResourceLoader,
  ModelRuntime,
  resolveCliModel,
  SessionManager,
  SettingsManager,
  type AgentSession,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import type { Store, Task } from "@todoagent/core";

/**
 * The main agent: a task secretary embedded via the pi SDK.
 *
 * It manages CARDS, not code. Its tool belt is the five task tools plus pi's
 * read-only file tools (`read`/`grep`/`find`/`ls`) — deliberately NOT
 * `write`/`edit`/`bash`. Those arrive with the supervisor milestone, if ever;
 * a secretary that can execute arbitrary shell from a chat message is an
 * attack surface, not a feature.
 *
 * Isolation: the secretary lives in its own agentDir (`~/.todoagent/pi` by
 * default) with in-memory settings and every discovery channel disabled, so a
 * user's personal `~/.pi` extensions, skills and AGENTS.md never leak into it.
 *
 * The pi session (JSONL, with compaction) is the truth for LLM context. The
 * `agent_chat` table is only the UI timeline projection — the engine writes it
 * for rendering, never feeds it back to the model.
 */

export interface SecretaryDeps {
  store: Store;
  /** The engine's one true dispatch path, guards included. */
  dispatch: (taskId: string) => Promise<{ ok: boolean; error?: string }>;
  /** Where a quick-add without a list lands (收件箱 semantics). */
  defaultListId: () => string;
  /** Announce board mutations made outside a request (tools write directly). */
  publishBoard: (taskId: string | null) => void;
}

export interface SecretaryTurn {
  reply: string;
  taskRefs: string[];
}

export interface Secretary {
  model: string;
  isBusy(): boolean;
  turn(userText: string): Promise<SecretaryTurn>;
  dispose(): void;
}

export type SecretaryInit =
  | { ready: true; secretary: Secretary }
  | { ready: false; reason: string };

/** Wall clock for one whole turn, tool loops included. */
const TURN_TIMEOUT_MS = 120_000;

const SYSTEM_PROMPT = `你是 TodoAgent 的任务秘书。你管理的是任务卡片，不写代码。

职责：把用户的话变成清晰的任务卡、维护看板、在合适的时候派发任务给本地编码 agent。

规则：
1. 建卡前先用 find_related 查一遍：发现相关的历史任务就在回复里提一句（如「和上周的 X 同清单」），并把新卡建到同一清单。
2. 一句话里有多件事就拆成多张卡；标题短，细节放 note。
3. 自动派发必须同时满足三个条件：目标清单绑定了仓库、dispatch_task 没有返回占用错误、用户没有表达「先别做 / 待会 / 只是记一下」这类意思。拿不准就只建卡不派发——建错卡删掉就好，派错了会烧钱。
4. 回复惜字如金：一两句确认即可，不要复述任务内容（卡片自己会展示），不要用列表和标题排版。
5. 永远不要编造任务状态，状态只来自工具返回值。
6. 用户问现状时用 list_state，照实转述。
7. 需要看文件内容时可以用 read/grep/find/ls（只读）。`;

/** Truncates tool feedback so a pathological title cannot flood the context. */
function clip(s: string, max = 400): string {
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function taskLine(store: Store, t: Task): string {
  const list = store.getChannel(t.channelId);
  return `[${t.id}] ${clip(t.title, 80)}（清单:${list?.name ?? "?"} 状态:${t.status}）`;
}

function buildTools(
  deps: SecretaryDeps,
  pendingRefs: string[],
): ToolDefinition[] {
  const { store } = deps;

  const createTasks = defineTool({
    name: "create_tasks",
    label: "创建任务",
    description:
      "批量创建任务卡。listId 省略时进入默认收件箱。返回创建的任务 id 列表。",
    parameters: Type.Object({
      tasks: Type.Array(
        Type.Object({
          title: Type.String({ description: "任务标题，一行" }),
          note: Type.Optional(Type.String({ description: "补充说明，可空" })),
          listId: Type.Optional(Type.String({ description: "目标清单 id" })),
        }),
        { minItems: 1, maxItems: 10 },
      ),
    }),
    execute: async (_id, params) => {
      const lines: string[] = [];
      for (const t of params.tasks) {
        const listId = t.listId ?? deps.defaultListId();
        if (t.listId !== undefined && store.getChannel(t.listId) === null) {
          lines.push(`跳过「${clip(t.title, 60)}」：清单 ${t.listId} 不存在`);
          continue;
        }
        const task = store.createTask({
          channelId: listId,
          title: t.title.trim(),
          note: t.note ?? "",
          status: "todo",
          assigneeKind: null,
          assigneeId: null,
          creatorKind: "expert",
          creatorId: null,
          sourceMessageId: null,
          runId: null,
        });
        pendingRefs.push(task.id);
        deps.publishBoard(task.id);
        lines.push(taskLine(store, task));
      }
      return { content: [{ type: "text", text: `已创建：\n${lines.join("\n")}` }], details: {} };
    },
  });

  const findRelated = defineTool({
    name: "find_related",
    label: "查找相关任务",
    description: "按关键词在所有任务（含已完成）的标题和说明里模糊检索，最多返回 10 条。",
    parameters: Type.Object({
      query: Type.String({ description: "关键词，可以是空格分隔的多个词" }),
    }),
    execute: async (_id, params) => {
      const words = params.query.toLowerCase().split(/\s+/).filter(Boolean);
      const hits = store
        .listAllTasks()
        .filter((t) => {
          const hay = `${t.title} ${t.note}`.toLowerCase();
          return words.some((w) => hay.includes(w));
        })
        .slice(-10);
      const text =
        hits.length === 0 ? "没有找到相关任务" : hits.map((t) => taskLine(store, t)).join("\n");
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  const dispatchTask = defineTool({
    name: "dispatch_task",
    label: "派发任务",
    description:
      "把一张任务卡派发给本地编码 agent 执行。目标清单必须绑定 git 仓库；同一仓库同时只能跑一个任务。失败时返回原因。",
    parameters: Type.Object({
      taskId: Type.String({ description: "要派发的任务 id" }),
    }),
    execute: async (_id, params) => {
      const res = await deps.dispatch(params.taskId);
      const text = res.ok ? `已派发 ${params.taskId}` : `派发失败：${res.error ?? "未知原因"}`;
      return { content: [{ type: "text", text }], details: {}, isError: !res.ok };
    },
  });

  const updateTask = defineTool({
    name: "update_task",
    label: "修改任务",
    description: "修改一张任务卡的标题、说明或所属清单。",
    parameters: Type.Object({
      taskId: Type.String(),
      title: Type.Optional(Type.String()),
      note: Type.Optional(Type.String()),
      listId: Type.Optional(Type.String({ description: "移动到的清单 id" })),
    }),
    execute: async (_id, params) => {
      const task = store.getTask(params.taskId);
      if (!task) {
        return { content: [{ type: "text", text: `任务 ${params.taskId} 不存在` }], details: {}, isError: true };
      }
      if (params.listId !== undefined && store.getChannel(params.listId) === null) {
        return { content: [{ type: "text", text: `清单 ${params.listId} 不存在` }], details: {}, isError: true };
      }
      store.updateTask(task.id, {
        ...(params.title !== undefined ? { title: params.title.trim() } : {}),
        ...(params.note !== undefined ? { note: params.note } : {}),
        ...(params.listId !== undefined ? { channelId: params.listId } : {}),
      });
      pendingRefs.push(task.id);
      deps.publishBoard(task.id);
      const after = store.getTask(task.id);
      return {
        content: [{ type: "text", text: after ? `已更新 ${taskLine(store, after)}` : "已更新" }],
        details: {},
      };
    },
  });

  const listState = defineTool({
    name: "list_state",
    label: "看板现状",
    description: "读取当前看板摘要：各状态的任务数与标题。回答「现在什么情况」用。",
    parameters: Type.Object({}),
    execute: async () => {
      const all = store.listAllTasks();
      const by = (s: Task["status"]) => all.filter((t) => t.status === s);
      const section = (label: string, tasks: Task[]) =>
        tasks.length === 0
          ? `${label}：无`
          : `${label}（${tasks.length}）：\n${tasks
              .slice(0, 15)
              .map((t) => taskLine(store, t))
              .join("\n")}`;
      const text = [
        section("需要你", by("needs_you")),
        section("进行中", by("in_progress")),
        section("待确认", by("in_review")),
        `待办：${by("todo").length} 条`,
        `已完成：${by("done").length} 条`,
      ].join("\n");
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  return [createTasks, findRelated, dispatchTask, updateTask, listState];
}

/**
 * Builds the secretary, or reports precisely why it cannot run.
 *
 * "Not configured" is a first-class state, not an error: the whole app works
 * without a model, chat is just dormant. Every failure reason here is written
 * for the banner the user will read.
 */
export async function createSecretary(deps: SecretaryDeps): Promise<SecretaryInit> {
  const modelSpec = process.env["TODOAGENT_MODEL"];
  if (modelSpec === undefined || modelSpec.trim() === "") {
    return {
      ready: false,
      reason:
        "未配置模型。设置 TODOAGENT_MODEL（如 anthropic/claude-haiku-4-5）和对应的 API key 后重启引擎。",
    };
  }

  const agentDir = process.env["TODOAGENT_AGENT_DIR"] ?? join(homedir(), ".todoagent", "pi");
  const cwd = process.env["TODOAGENT_AGENT_CWD"] ?? homedir();

  const modelRuntime = await ModelRuntime.create({
    authPath: join(agentDir, "auth.json"),
    modelsPath: join(agentDir, "models.json"),
  });

  const resolved = resolveCliModel({ cliModel: modelSpec, modelRuntime });
  if (resolved.error !== undefined || resolved.model === undefined) {
    return {
      ready: false,
      reason: `模型 ${modelSpec} 无法解析：${resolved.error ?? "未找到"}。检查 TODOAGENT_MODEL 的 provider/model 拼写。`,
    };
  }
  const model = resolved.model;

  const apiKey = process.env["TODOAGENT_API_KEY"];
  if (apiKey !== undefined && apiKey !== "") {
    modelRuntime.setRuntimeApiKey(model.provider, apiKey);
  }

  const available = await modelRuntime.getAvailable();
  if (!available.some((m) => m.provider === model.provider && m.id === model.id)) {
    return {
      ready: false,
      reason: `模型 ${modelSpec} 缺少凭据。设置 TODOAGENT_API_KEY 或对应厂商的环境变量（如 ANTHROPIC_API_KEY）。`,
    };
  }

  const pendingRefs: string[] = [];
  const customTools = buildTools(deps, pendingRefs);

  const settingsManager = SettingsManager.inMemory({
    retry: { enabled: true, maxRetries: 2 },
  });

  // Discovery is fully off: the user's personal pi setup must not leak in.
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
    systemPromptOverride: () => SYSTEM_PROMPT,
  });
  await loader.reload();

  let session: AgentSession;
  try {
    const created = await createAgentSession({
      cwd,
      agentDir,
      modelRuntime,
      model,
      thinkingLevel: "off",
      tools: ["read", "grep", "find", "ls", ...customTools.map((t) => t.name)],
      customTools,
      resourceLoader: loader,
      sessionManager: SessionManager.continueRecent(cwd, join(agentDir, "sessions")),
      settingsManager,
    });
    session = created.session;
  } catch (err) {
    return {
      ready: false,
      reason: `主 agent 初始化失败：${err instanceof Error ? err.message : String(err)}`,
    };
  }

  const secretary: Secretary = {
    model: `${model.provider}/${model.id}`,
    isBusy: () => session.isStreaming,

    async turn(userText: string): Promise<SecretaryTurn> {
      pendingRefs.length = 0;
      const replyParts: string[] = [];

      const unsubscribe = session.subscribe((event) => {
        if (event.type === "agent_end") {
          for (const message of event.messages) {
            if (message.role !== "assistant") continue;
            for (const block of message.content) {
              if (typeof block === "object" && block !== null && "type" in block && block.type === "text") {
                const text = (block as { text?: unknown }).text;
                if (typeof text === "string" && text.trim() !== "") replyParts.push(text.trim());
              }
            }
          }
        }
      });

      // The abort is the outer safety net; pi's own retry/backoff lives inside it.
      const timeout = setTimeout(() => {
        void session.abort();
      }, TURN_TIMEOUT_MS);

      try {
        await session.prompt(userText);
      } finally {
        clearTimeout(timeout);
        unsubscribe();
      }

      const reply = replyParts.join("\n\n").trim();
      return {
        reply: reply === "" ? "这轮没有得到模型回复（可能超时或被中断），稍后再试一次。" : reply,
        taskRefs: [...new Set(pendingRefs)],
      };
    },

    dispose: () => session.dispose(),
  };

  return { ready: true, secretary };
}
