# TodoAgent

一个会自己完成任务的待办清单。

别的 to-do list 只记录任务。TodoAgent 把任务派给你本机已登录的编码 CLI（Claude Code、Codex、Cursor、Gemini、Kiro、Grok）去干掉：添加一条任务，或者直接和主 agent 说一句话，任务就会被派发、执行、带着 diff 回来等你确认。卡住的任务会**带着 agent 提的问题**主动来找你，你回一句，它接着做。

```
┌─────────────┬──────────────────────────────┬───────────────┐
│ 我的一天  3 │  我的一天                    │      ◇        │
│ 需要你   ①  │  8月4日 星期二 · 6 个 agent  │    Agent      │
│ 已完成      │  ┌────────────────────────┐  │  codex·claude │
│             │  │ ＋ 添加任务            │  │               │
│ 清单        │  └────────────────────────┘  │  和 agent 说件 │
│ ● 收件箱  2 │  需要你 1                    │  事，它会变成  │
│ ● todoagent │  ┌────────────────────────┐  │  任务          │
│ ● 买东西  1 │  │ ○ 接数据库             │  │               │
│             │  │   用 postgres 还是     │  │               │
│ ＋ 新建清单 │  │   sqlite？  [回答][查看]│  │               │
│             │  └────────────────────────┘  │ ╭───────────╮ │
│ Ⓝ Niko   ⚙ │  进行中 1 · 待办 2 · 已完成  │ ╰───────────╯ │
└─────────────┴──────────────────────────────┴───────────────┘
   侧栏 244px          任务栏 724px             chat 360px
```

## 前提

至少装一个编码 CLI 并**确认它已登录**。

## 快速开始

```bash
pnpm install
pnpm runtimes --probe         # 实测每个 CLI 能不能完成一轮对话
pnpm seed ~/你的仓库           # 建 agent + 一个绑这个仓库的清单
pnpm dev                      # 引擎 :8787
pnpm dev:web                  # 界面 :3000 —— 另开一个终端
```

打开 <http://localhost:3000>。

`--probe` 这一步不能省：`detect` 只证明二进制在 PATH 上，凭据过期的 CLI 看起来完全一样，直到派发时才失败。

命令是 `pnpm runtimes`，**不是** `pnpm doctor` —— pnpm 有个同名内置命令会把它截走，`pnpm doctor --probe` 会报 `Unknown option: 'probe'`。

`pnpm seed` 不带仓库路径也能用：那样只建 agent 和收件箱，可以当纯待办清单用，但任务不能派发（没有工作目录）。也可以在界面上「新建清单」时填仓库路径，效果一样。绑定的路径**必须是 git 仓库**：diff 快照靠它，没有 git 就没有「看结果」。

## 主 agent（chat 栏）

chat 栏那个 agent 需要一个模型。**不配也能用**，只是那一栏休眠：

| | 不配模型 | 配了模型 |
|---|---|---|
| 清单、任务、派发、diff、确认 | ✅ | ✅ |
| 说一句话自动建卡/派发 | ❌ 提示未配置 | ✅ |
| 产出分类（提问/受阻/完成） | 启发式：最后一段是短问句就算提问 | 模型判断，能识别「受阻」 |

在仓库根目录建 `.env`（已在 `.gitignore` 里）：

```bash
TODOAGENT_MODEL=google/gemini-3.6-flash
TODOAGENT_API_KEY=你的-key
```

`pnpm dev` 会加载它。**测试套件不会** —— 它们直接跑 `server.ts`，绕开这个加载，所以真 key 不会漏进测试变成计费请求。

模型走 pi 的 provider 体系，`provider/model` 形式。任何 OpenAI 兼容端点都能接：在 `~/.todoagent/pi/models.json` 里注册一个 provider（`baseUrl` + `api: "openai-completions"`），本地 vLLM / Ollama 同理。

如果你机器上有代理（`https_proxy`），引擎会自动用它。这一步不是自动的时候曾经很难查：模型能解析、状态显示就绪、curl 也通，但每次调用都超时 —— 因为 Node 默认不读代理环境变量。

## 状态机

```
      添加任务
         ↓
       待办 ──派发──→ 进行中 ──┬─→ 待确认 ──勾选──→ 已完成
         ↑                     │      （人看 diff 后确认）
         │                     │
      取消执行                 └─→ 需要你 ──┬─ 提问 ─→ 回答 ─→ 进行中 ↺
                                            ├─ 受阻 ─→ 重派
                                            └─ 失败 ─→ 重派
```

三种进「需要你」的方式，动作不同：

| 来源 | 卡上显示 | 能做什么 |
|---|---|---|
| `question` — agent 在输出末尾提了问题 | 问题原文 | **回答**（行内输入，答案送回同一个会话）、查看 |
| `blocked` — agent 说自己卡住了 | 受阻原因 | 重派、查看 |
| `failed` — 执行失败或超时 | 错误信息 | 重派、查看 |

「完成」永远由人点。跑完的任务进**待确认**，不会自己变成已完成 —— 没人审过的工作不该声称已通过。

回答之后是**新建一个 run**，不是接着写旧的。claude 和 cursor 用 `--resume` 真续会话；codex 这类不支持的，把原任务、上一轮输出和你的回答拼进新 prompt（token 会重复消耗，这是明确接受的取舍）。

## 命令

```bash
pnpm dev                # 引擎 :8787（会加载 .env）
pnpm dev:web            # 界面 :3000
pnpm runtimes --probe   # 实测每个 CLI 能否完成一轮
pnpm seed [仓库路径]     # 建 agent + 收件箱（给了路径就再建一个绑定清单）
pnpm typecheck          # 三个 workspace
pnpm test               # 全量测试，不烧 token
pnpm check              # 静态检查：控制字符、CSS 类、断点、死导出
pnpm e2e                # 真跑一遍闭环（烧真 token）
pnpm e2e --ask          # 真跑提问 → 回答 → 续跑
```

`pnpm e2e` 不在 `pnpm test` 里：它派发给真 CLI，花真钱。可选参数 `--runtime=codex` 指定 CLI、`--keep` 保留 fixture、`--budget=5` 调 token 上限。

## 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `TODOAGENT_DB` | `~/.todoagent/todoagent.db` | SQLite 路径 |
| `TODOAGENT_PORT` | `8787` | 引擎端口 |
| `TODOAGENT_MODEL` | 无 | 主 agent 模型，`provider/model` |
| `TODOAGENT_API_KEY` | 无 | 上面那个 provider 的 key |
| `TODOAGENT_AGENT_DIR` | `~/.todoagent/pi` | 主 agent 的会话/凭据目录 |
| `TODOAGENT_AGENT_CWD` | `$HOME` | 主 agent 的工作目录（它的只读文件工具在这里） |
| `TODOAGENT_MAX_CONCURRENT_AGENTS` | `max(2, min(6, 核数/2))` | 同时活着的 CLI 进程上限 |
| `TODOAGENT_WEB_ORIGIN` | 无 | 额外允许的 CORS 源，逗号分隔。所有 `localhost:*` / `127.0.0.1:*` 默认已放行 |
| `TODOAGENT_E2E_PORT` | `8850` | e2e 用的端口 |

## 架构

```
apps/web        Next.js 三栏界面（侧栏清单 + 任务栏 + chat）
   ↕ HTTP + SSE（仅 localhost）
apps/engine     Hono：任务/清单 API、SSE 失效广播、主 agent
packages/core   适配器、runDirect、Store（SQLite）
```

主 agent 完全嵌在 pi SDK 里（`@earendil-works/pi-coding-agent`），跑在引擎进程内，没有独立服务。它的工具只有任务五件套加 pi 的只读文件工具 —— 没有 write/edit/bash：一个能从聊天消息执行任意 shell 的秘书是攻击面，不是功能。

三种传输格式被适配器统一成同一个事件流：stream-json（claude/cursor/gemini）、JSONL（codex）、ACP over JSON-RPC（kiro/grok）。UI 和引擎保持两个进程、只走 localhost HTTP/SSE —— 这条纪律是为将来包成 Mac 应用留的。

看板变化走 SSE，但只发「变了，重读」不带数据：一条信号丢了只损失延迟，永远不会损失正确性。

从 Council 继承的六阶段交叉评审流水线（拆解→执行→互审→反驳→裁决→验证）仍在代码里，走 `POST /api/runs`，界面不用它 —— 保留作为将来重要任务的深度模式。

## 安全

**仅 localhost，且故意不做认证。** 所有适配器都以绕过工具确认的方式运行 CLI（`--permission-mode bypassPermissions`、`--force`、`--yolo`）。单人本机工具可以接受；**一旦暴露端口，任何能访问的人都能在你机器上以你的凭据执行任意代码**。对外提供服务前必须先加认证和沙箱。

直派模式下 agent 直接在你的仓库里工作，**不做 worktree 隔离**（那是六阶段流水线的机制）。它改的就是你的工作区，改完留在那儿等你看 diff —— 不自动提交。

## 已知限制

- **一个仓库同时只跑一个任务。** 两个 agent 同时写一个工作区会互相覆盖，且不可撤销。第二次派发会被拒并告诉你哪个 run 占着。
- **`blocked` 分类只有配了模型才会出现。** 启发式不产它 —— 「我没找到配置所以用了默认值」描述的是一个**完成**的任务，没有可靠的文本信号区分「我放弃了」，宁缺毋滥。
- **session 失效只能靠文本匹配。** claude 和 cursor 都没有结构化字段表示「会话不存在」，所以真续失败的判断是匹配错误信息里的 `session|resume|conversation`。匹配刻意收窄：误判的代价是多跑一次冷启动。
- **gemini 适配器未经真实运行验证。** 本机 `pnpm runtimes --probe` 的结果：claude、codex、cursor、kiro、grok 五个都真实完成了一轮（各自返回预期文本），gemini 报 `no credentials`。所以 gemini 的事件名仍来自协议文档而非抓包。完整任务（带工具调用、diff 快照）只在 claude 上跑过 `pnpm e2e`。
- **`question` 类任务如果没有关联的 run**（例如手工改库造出来的），只能派发或删除，没有回答入口 —— 答案得有个会话可以送回去。
- 合并冲突只上报，绝不自动解决（六阶段模式）。

## 设计基准

界面布局照 `opt-h2-sunsama-refined` 原型实现（2026-08-04 定稿），配色与字体留在实现里。`PLAN.md` 是总纲和决策记录。

设计原型（HTML）和里程碑 prompt 未纳入版本库 —— 原型里带有第三方产品的截图素材，不适合公开分发。代码注释中出现的
`mockups/xxx.html` 指的是这批本地文件，记录设计出处，不是仓库里的路径。
