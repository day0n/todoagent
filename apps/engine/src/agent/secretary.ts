import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
 *
 * Multiple `chat_session` rows can be live at once — this is the whole point
 * of letting a person hold several independent conversations. Each gets its
 * OWN `AgentSession` (own pi JSONL file, own in-flight turn), tracked in a
 * small LRU so the process does not accumulate one live agent per conversation
 * ever created. Model/tool wiring (`modelRuntime`, `resourceLoader`,
 * `settingsManager`) is resolved once and shared; only the per-conversation
 * `AgentSession` and its tool closures (`pendingRefs`) are per-session.
 */

export interface SecretaryDeps {
  store: Store;
  /** Internal owner behind the aggregate “任务” smart view. */
  defaultListId: () => string;
  /** Announce board mutations made outside a request (tools write directly). */
  publishBoard: (taskId: string | null) => void;
}

export interface SecretaryTurn {
  reply: string;
  taskRefs: string[];
}

/** An image attachment ready to hand to the model. Matches pi's `ImageContent` shape. */
export interface SecretaryImage {
  mediaType: string;
  /** Base64-encoded bytes, no `data:` prefix. */
  data: string;
}

export interface SecretaryTurnOptions {
  images?: SecretaryImage[];
  /** Called once per streamed text chunk, in order, before the turn resolves. */
  onDelta?: (text: string) => void;
}

export interface Secretary {
  model: string;
  isBusy(chatSessionId: string): boolean;
  turn(chatSessionId: string, userText: string, options?: SecretaryTurnOptions): Promise<SecretaryTurn>;
  /** Drops one conversation's live agent (e.g. after it is archived). Safe to call on an unopened session. */
  closeSession(chatSessionId: string): void;
  dispose(): void;
}

export type SecretaryInit =
  | { ready: true; secretary: Secretary }
  | { ready: false; reason: string };

/** Wall clock for one whole turn, tool loops included. */
const TURN_TIMEOUT_MS = 120_000;

/**
 * How many conversations may hold a live `AgentSession` at once.
 *
 * Each one is a real in-memory agent loop plus its loaded context, so this is
 * a memory/fan-out cap, not a UI limit — a person can have far more chat
 * sessions than this; the rest just reload from their pi JSONL file (a few
 * hundred ms) the next time they're opened. Never counts against a session
 * that is mid-turn: eviction skips those, so a slow reply is never cut off by
 * someone opening a sixth conversation.
 */
const MAX_LIVE_SESSIONS = 6;

const SYSTEM_PROMPT = `你是 TodoAgent 的任务秘书。你管理的是任务卡片，不写代码。

职责：把用户的话变成清晰的任务卡、维护看板和提醒。你不执行代码，也不启动本机 CLI。

规则：
1. 建卡前先用 find_related 查一遍：发现相关的历史任务就在回复里提一句。用户明确指定自定义清单时用 list_lists 找到它；没有指定时放入系统“任务”总览，不要擅自塞进某个自定义清单。
2. 一句话里有多件事就拆成多张卡；标题短，细节放 note。
3. 禁止派发、启动或猜测 CLI。用户要求执行时，只创建或更新任务，并告诉他打开任务后亲自选择工作目录、Runtime 和第一条消息。
4. 回复惜字如金：一两句确认即可，不要复述任务内容（卡片自己会展示），不要用列表和标题排版。
5. 永远不要编造任务状态，状态只来自工具返回值。
6. 用户问现状时用 list_state，照实转述。
7. 需要看文件内容时可以用 read/grep/find/ls（只读）。
8. MEMORY.md 是长期记忆；ref/ 是按需查阅的小抄。不要把 ref/ 全部复述或塞进回复，只在当前问题需要时读取。
9. 截止日期：用户明确说了时间才填 dueDate，格式必须是 YYYY-MM-DD。每条用户消息开头会给你今天的日期，
   相对时间（明天、下周五、月底）都从那个日期算。用户没提时间就不要自己编一个截止日期——
   大多数待办本来就没有截止日期。`;

/** Truncates tool feedback so a pathological title cannot flood the context. */
function clip(s: string, max = 400): string {
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function taskLine(store: Store, t: Task): string {
  const list = store.getChannel(t.channelId);
  // The due date is included so the model can see existing deadlines in
  // `find_related` and `list_state` output — otherwise it would have to ask, or
  // worse, overwrite one it did not know about.
  const due = t.dueDate === null ? "" : ` 截止:${t.dueDate}`;
  return `[${t.id}] ${clip(t.title, 80)}（清单:${list?.name ?? "?"} 状态:${t.status}${due}）`;
}

/** Today as `YYYY-MM-DD`, local time — the format every date field here uses. */
function todayIso(): string {
  const now = new Date();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${now.getFullYear()}-${m}-${d}`;
}

/** Weekday name for the prompt, so "下周五" has an anchor to count from. */
const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"] as const;

/**
 * Validates a date the MODEL produced.
 *
 * It is generating a string, so it can generate `2026-13-45`, `明天`, or a
 * plausible-looking date with the wrong year. A bad value would be stored verbatim
 * and then compared as a string against today, so it would silently never match —
 * a deadline that exists in the database and does nothing. Rejected loudly instead,
 * with the reason fed back so the model can correct itself.
 */
function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [y, m, d] = value.split("-").map(Number) as [number, number, number];
  const probe = new Date(y, m - 1, d);
  // Round-trip check: `new Date(2026, 12, 45)` silently rolls over into the next
  // month rather than failing, so the only reliable test is whether the parts
  // survive construction unchanged.
  return probe.getFullYear() === y && probe.getMonth() === m - 1 && probe.getDate() === d;
}

function buildTools(
  deps: SecretaryDeps,
  pendingRefs: string[],
): ToolDefinition[] {
  const { store } = deps;

  const createTasks = defineTool({
    name: "create_tasks",
    label: "创建任务",
    description: "批量创建任务卡。listId 省略时进入系统“任务”总览；明确指定自定义清单时必须使用现有 listId。",
    parameters: Type.Object({
      tasks: Type.Array(
        Type.Object({
          title: Type.String({ description: "任务标题，一行" }),
          note: Type.Optional(Type.String({ description: "补充说明，可空" })),
          listId: Type.Optional(Type.String({ description: "可选的自定义清单 id，必须来自 list_lists 或 find_related" })),
          dueDate: Type.Optional(
            Type.String({
              description: "截止日期，必须是 YYYY-MM-DD。用户没提到时间就不要填。",
            }),
          ),
        }),
        { minItems: 1, maxItems: 10 },
      ),
    }),
    execute: async (_id, params) => {
      const lines: string[] = [];
      for (const t of params.tasks) {
        const listId = t.listId ?? deps.defaultListId();
        const list = store.getChannel(listId);
        if (list === null || list.kind !== "channel" || list.archivedAt !== null) {
          lines.push(`跳过「${clip(t.title, 60)}」：清单 ${listId} 不存在或已归档`);
          continue;
        }
        /*
         * A bad date is refused rather than stored.
         *
         * The model is generating a string, so it can produce `2026-13-45` or the
         * word 明天. Either would be written verbatim and then compared as a string
         * against today — silently never matching, which is a deadline that exists
         * in the database and does nothing. Skipping the whole card is deliberate:
         * creating it without the date the user asked for is a quiet half-success.
         */
        if (t.dueDate !== undefined && !validDate(t.dueDate)) {
          lines.push(`跳过「${clip(t.title, 60)}」：截止日期 ${t.dueDate} 不是合法的 YYYY-MM-DD`);
          continue;
        }
        const task = store.createTask({
          channelId: listId,
          title: t.title.trim(),
          note: t.note ?? "",
          status: "todo",
          ...(t.dueDate !== undefined ? { dueDate: t.dueDate } : {}),
          assigneeKind: null,
          assigneeId: null,
          // The secretary writes on the user's behalf. It is not a configured
          // coding Expert, and the direct-CLI product path must not create an
          // Expert identity merely to attribute a card.
          creatorKind: "human",
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

  const updateTask = defineTool({
    name: "update_task",
    label: "修改任务",
    description: "修改一张任务卡的标题、说明、所属清单或截止日期。",
    parameters: Type.Object({
      taskId: Type.String(),
      title: Type.Optional(Type.String()),
      note: Type.Optional(Type.String()),
      listId: Type.Optional(Type.String({ description: "移动到的清单 id" })),
      dueDate: Type.Optional(
        Type.String({
          description: "截止日期 YYYY-MM-DD。传空字符串清除截止日期。不改就不要传这个字段。",
        }),
      ),
    }),
    execute: async (_id, params) => {
      const task = store.getTask(params.taskId);
      if (!task) {
        return { content: [{ type: "text", text: `任务 ${params.taskId} 不存在` }], details: {}, isError: true };
      }
      if (params.listId !== undefined && store.getChannel(params.listId) === null) {
        return { content: [{ type: "text", text: `清单 ${params.listId} 不存在` }], details: {}, isError: true };
      }
      /*
       * The empty string clears the deadline; anything else must be a real date.
       *
       * An empty string rather than `null` because TypeBox's nullable union becomes
       * `type: ["string", "null"]` in JSON Schema, and support for that across
       * function-calling providers is uneven — a schema one provider rejects would
       * take the whole tool down. No real date is ever empty, so the encoding is
       * unambiguous.
       */
      if (params.dueDate !== undefined && params.dueDate !== "" && !validDate(params.dueDate)) {
        return {
          content: [
            { type: "text", text: `截止日期 ${params.dueDate} 不是合法的 YYYY-MM-DD，没有改动` },
          ],
          details: {},
          isError: true,
        };
      }
      store.updateTask(task.id, {
        ...(params.title !== undefined ? { title: params.title.trim() } : {}),
        ...(params.note !== undefined ? { note: params.note } : {}),
        ...(params.listId !== undefined ? { channelId: params.listId } : {}),
        ...(params.dueDate !== undefined
          ? { dueDate: params.dueDate === "" ? null : params.dueDate }
          : {}),
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

  const listLists = defineTool({
    name: "list_lists",
    label: "查看清单",
    description: "读取用户创建的清单名称和 id。仅在用户明确提到自定义清单时用它确定 listId。",
    parameters: Type.Object({}),
    execute: async () => {
      const lists = store.listChannels().filter((list) =>
        list.kind === "channel" &&
        list.archivedAt === null &&
        !list.name.startsWith("__todoagent_") &&
        list.name !== "收件箱"
      );
      const text = lists.length === 0
        ? "当前没有清单。请用户先创建清单。"
        : lists.map((list) => `[${list.id}] ${list.name}`).join("\n");
      return { content: [{ type: "text", text }], details: {} };
    },
  });

  return [createTasks, findRelated, updateTask, listState, listLists];
}

/** Transparent, user-editable long-term memory for the one TodoAgent assistant. */
export function assistantWorkspaceDir(): string {
  return process.env["TODOAGENT_ASSISTANT_WORKSPACE"] ?? join(homedir(), ".todoagent", "assistant");
}

export function ensureAssistantWorkspace(): string {
  const dir = assistantWorkspaceDir();
  mkdirSync(join(dir, "ref"), { recursive: true });
  const memory = join(dir, "MEMORY.md");
  if (!existsSync(memory)) writeFileSync(memory, "", "utf8");
  return dir;
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
  // The secretary gets a small, persistent home of its own. It can read its
  // MEMORY.md and ref/ cheat sheets, but it is not launched from the user's home
  // or from a code repository and has no shell/write tools.
  const cwd = ensureAssistantWorkspace();

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

  const settingsManager = SettingsManager.inMemory({
    retry: { enabled: true, maxRetries: 2 },
  });

  // Discovery is fully off: the user's personal pi setup must not leak in.
  // Shared across every conversation's AgentSession — it carries no
  // per-conversation state, only the (fixed) system prompt and disabled
  // discovery channels.
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
    systemPromptOverride: () => {
      const memoryPath = join(cwd, "MEMORY.md");
      const memory = existsSync(memoryPath) ? readFileSync(memoryPath, "utf8").slice(0, 20_000) : "";
      return memory.trim() === ""
        ? SYSTEM_PROMPT
        : `${SYSTEM_PROMPT}\n\n以下是用户可见、可编辑的长期记忆 MEMORY.md：\n\n${memory}`;
    },
  });
  await loader.reload();

  const sessionsDir = join(agentDir, "sessions");

  interface LiveSession {
    session: AgentSession;
    /** Task ids the CURRENT turn's tool calls touched. Reset at the start of every turn. */
    pendingRefs: string[];
  }

  /**
   * Live agents, oldest-touched first.
   *
   * A `Map` rather than a dedicated LRU structure because "move to the end on
   * access" is exactly `delete` + `set` on a `Map` — insertion order IS
   * recency order, and iterating from the front finds the eviction candidate
   * for free.
   */
  const live = new Map<string, LiveSession>();

  function touch(chatSessionId: string, entry: LiveSession): void {
    live.delete(chatSessionId);
    live.set(chatSessionId, entry);
  }

  /** Drops the oldest non-streaming session once the cap is exceeded. */
  function evictIfNeeded(): void {
    while (live.size > MAX_LIVE_SESSIONS) {
      let victimId: string | undefined;
      for (const [id, entry] of live) {
        if (!entry.session.isStreaming) {
          victimId = id;
          break;
        }
      }
      // Everyone left is mid-turn: over the cap, but nothing safe to drop.
      // The map shrinks back down as those turns finish and later evictions run.
      if (victimId === undefined) return;
      const victim = live.get(victimId);
      live.delete(victimId);
      victim?.session.dispose();
    }
  }

  async function getOrCreate(chatSessionId: string): Promise<LiveSession> {
    const existing = live.get(chatSessionId);
    if (existing) {
      touch(chatSessionId, existing);
      return existing;
    }

    const chatSession = deps.store.getChatSession(chatSessionId);
    const pendingRefs: string[] = [];
    const customTools = buildTools(deps, pendingRefs);
    const sessionManager =
      chatSession?.piSessionPath !== null && chatSession?.piSessionPath !== undefined
        ? SessionManager.open(chatSession.piSessionPath, sessionsDir, cwd)
        : SessionManager.create(cwd, sessionsDir);

    const created = await createAgentSession({
      cwd,
      agentDir,
      modelRuntime,
      model,
      thinkingLevel: "off",
      tools: ["read", "grep", "find", "ls", ...customTools.map((t) => t.name)],
      customTools,
      resourceLoader: loader,
      sessionManager,
      settingsManager,
    });

    const entry: LiveSession = { session: created.session, pendingRefs };
    touch(chatSessionId, entry);

    // pi assigns the file path synchronously on creation, so this is safe to
    // read back immediately rather than waiting for the first turn to finish.
    const path = created.session.sessionFile;
    if (path !== undefined && path !== chatSession?.piSessionPath) {
      deps.store.patchChatSession(chatSessionId, { piSessionPath: path });
    }

    evictIfNeeded();
    return entry;
  }

  const secretary: Secretary = {
    model: `${model.provider}/${model.id}`,
    isBusy: (chatSessionId: string) => live.get(chatSessionId)?.session.isStreaming ?? false,

    async turn(
      chatSessionId: string,
      userText: string,
      options: SecretaryTurnOptions = {},
    ): Promise<SecretaryTurn> {
      const { session, pendingRefs } = await getOrCreate(chatSessionId);
      pendingRefs.length = 0;
      const replyParts: string[] = [];

      const unsubscribe = session.subscribe((event) => {
        if (
          event.type === "message_update" &&
          event.assistantMessageEvent.type === "text_delta" &&
          event.assistantMessageEvent.delta !== ""
        ) {
          options.onDelta?.(event.assistantMessageEvent.delta);
        }
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
        /*
         * Today's date is stamped on every turn, not baked into the system prompt.
         *
         * A conversation's AgentSession can live for days — this is a local tool
         * people leave running — so a date in the system prompt would be correct
         * until midnight and then quietly wrong, and "明天" resolving to yesterday
         * is the kind of error nobody notices until a deadline is already missed.
         *
         * Stamped on the text sent to the MODEL only. The `agent_chat` row the UI
         * renders is written by the caller from the original message, so the user
         * never sees this line.
         */
        const now = new Date();
        const stamp = `[今天是 ${todayIso()} 星期${WEEKDAYS[now.getDay()]}]`;
        const images = options.images?.map((img) => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mediaType,
        }));
        await session.prompt(`${stamp}\n\n${userText}`, images && images.length > 0 ? { images } : undefined);
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

    closeSession(chatSessionId: string): void {
      const entry = live.get(chatSessionId);
      if (!entry) return;
      live.delete(chatSessionId);
      entry.session.dispose();
    },

    dispose: () => {
      for (const entry of live.values()) entry.session.dispose();
      live.clear();
    },
  };

  return { ready: true, secretary };
}
