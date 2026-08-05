# TodoAgent

一个会自己完成任务的待办清单。

别的 to-do list 只记录任务。TodoAgent 把任务派给你本机**已登录**的编码 CLI（Claude Code、Codex、Cursor、Gemini、Kiro、Grok）去干掉：添加一条任务，或者直接和秘书说一句话，任务就会被派发、执行、带着 diff 回来等你确认。卡住的任务会**带着 agent 提的问题**主动来找你，你回一句，它接着做。

「完成」永远由人点。跑完的任务进待确认，不会自己变成已完成 —— 没人审过的工作不该声称已通过。

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

`--probe` 这一步不能省：`detect` 只证明二进制在 PATH 上，凭据过期的 CLI 看起来完全一样，直到派发时才失败。

命令是 `pnpm runtimes`，**不是** `pnpm doctor` —— pnpm 有个同名内置命令会把它截走，`pnpm doctor --probe` 会报 `Unknown option: 'probe'`。

`pnpm seed` 不带仓库路径也能用：那样只建 agent 和收件箱，可以当纯待办清单用，但任务不能派发（没有工作目录）。也可以在界面上「新建清单」时填仓库路径，效果一样。绑定的路径**必须是 git 仓库**：diff 快照靠它，没有 git 就没有「看结果」。

## 配置秘书

秘书需要一个模型。**不配也能用**，只是那一栏休眠 —— 清单、任务、派发、diff、确认全都照常，少的是「说一句话自动建卡」，以及产出分类会从模型判断退回启发式（最后一段是短问句就算提问）。

在仓库根目录建 `.env`（已在 `.gitignore` 里）：

```bash
TODOAGENT_MODEL=google/gemini-3.6-flash
TODOAGENT_API_KEY=你的-key
```

`pnpm dev` 会加载它，测试套件不会 —— 真 key 不会漏进测试变成计费请求。

模型走 pi 的 provider 体系，`provider/model` 形式。任何 OpenAI 兼容端点都能接：在 `~/.todoagent/pi/models.json` 里注册一个 provider（`baseUrl` + `api: "openai-completions"`），本地 vLLM / Ollama 同理。机器上有 `https_proxy` 时引擎会自动用它。

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
| `TODOAGENT_MODEL` | 无 | 秘书的模型，`provider/model` |
| `TODOAGENT_API_KEY` | 无 | 上面那个 provider 的 key |
| `TODOAGENT_AGENT_DIR` | `~/.todoagent/pi` | 秘书的会话/凭据目录 |
| `TODOAGENT_AGENT_CWD` | `$HOME` | 秘书的工作目录（它的只读文件工具在这里） |
| `TODOAGENT_MAX_CONCURRENT_AGENTS` | `max(2, min(6, 核数/2))` | 同时活着的 CLI 进程上限 |
| `TODOAGENT_WEB_ORIGIN` | 无 | 额外允许的 CORS 源，逗号分隔。所有 `localhost:*` / `127.0.0.1:*` 默认已放行 |
| `TODOAGENT_E2E_PORT` | `8850` | e2e 用的端口 |

## 安全

**仅 localhost，且故意不做认证。** 所有适配器都以绕过工具确认的方式运行 CLI（`--permission-mode bypassPermissions`、`--force`、`--yolo`）。单人本机工具可以接受；**一旦暴露端口，任何能访问的人都能在你机器上以你的凭据执行任意代码**。对外提供服务前必须先加认证和沙箱。

agent 直接在你绑定的仓库里工作，**不做 worktree 隔离**。它改的就是你的工作区，改完留在那儿等你看 diff —— 不自动提交。派发和回答走的是同一条执行路径，所以两者都会在真仓库里动手。同一个仓库同时只跑一个任务：第二次派发会被拒并告诉你哪个 run 占着。

---

代码注释里出现的 `mockups/xxx.html` 是本地设计原型，未纳入版本库（含第三方产品截图素材），不是仓库里的路径。`PLAN.md` 是总纲和决策记录。
