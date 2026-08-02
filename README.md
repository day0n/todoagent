# TodoAgent

一个会自己完成任务的待办清单。

别的 to-do list 只记录任务，TodoAgent 把任务派给你本机已登录的编码 CLI（Claude Code、Codex、Cursor、Kiro、Grok）去干掉：你添加一条任务，主 agent 解析它、写出验收标准、派发给合适的本地 agent 执行，完成后对照验收标准审核，再更新看板状态。卡住的、需要你拍板的任务会带着具体问题主动来找你，而不是静默挂着。

> 本项目由 Council（多 agent 交叉评审系统）转型而来。适配器、进程看门狗、git worktree 隔离、编排基础全部继承；原六阶段交叉评审流水线保留在代码中，未来作为重要任务的「深度模式」。

## 和竞品的区别

Vibe Kanban、Kangentic、KanVibe、agent-kanban 这批开源项目做的都是**给开发者的 agent 看板**：核心对象是 agent 的工作会话，界面围绕仓库和 diff。TodoAgent 的核心对象是**你的待办**：

- 清单是主界面，看板只是任务的观察视图
- 任务分两类：@了仓库的由 agent 执行并自动推进；普通待办安静躺着，不假装能代劳
- 验收标准在**派发前**生成，审核对照标准逐条核对，而不是「看起来不错」
- 「需要你」是一等状态：agent 提的问题、审核不过的任务都汇聚到这里等你处理

## V1 闭环（进行中）

```
你添加任务（或和主 agent 聊一句）
    ↓
主 agent 解析成任务卡 + 3 条验收标准
    ↓
派发给本地 CLI agent（worktree 隔离）
    ↓
执行，看板状态实时变化
    ↓
完成后主 agent 审核（构建/测试 + 对照验收标准）
    ↓
通过 → 完成；不通过 → 打回一次或标记「需要你」
```

看板状态：`待办 → 进行中 → 审核中 → 完成`，外加 `需要你`。

## 前提

至少装一个编码 CLI，并确认它已登录：

```bash
pnpm doctor --probe
```

`--probe` 会对每个 CLI 真跑一轮对话。这一步不能省：`detect` 只证明二进制存在，凭据过期的 CLI 看起来完全一样。

## 启动

```bash
pnpm install
pnpm seed ~/你的仓库          # 按已装 CLI 自动组队
pnpm dev                      # 引擎 :8787
pnpm dev:web                  # 界面 :3000
```

被 @ 的目标仓库**必须是 git 仓库**。并行执行靠 worktree 隔离，没有它多个 agent 会互相覆盖文件。

## 命令

```bash
pnpm doctor --probe     # 实测每个 CLI 能否完成一轮
pnpm test               # 全量测试（core + engine + web）
pnpm typecheck
pnpm e2e                # 真实 agent 跑完整流水线
```

环境变量：

- `TODOAGENT_DB` — SQLite 路径，默认 `~/.todoagent/todoagent.db`
- `TODOAGENT_PORT` — 引擎端口，默认 8787
- `TODOAGENT_MAX_CONCURRENT_AGENTS` — 并发 agent 进程全局上限，默认 `min(核数/2, 6)`

## 架构

```
apps/web      Next.js 界面（清单 + 看板）
apps/engine   Hono + SSE，仅监听 127.0.0.1
packages/core 适配器、编排器、SQLite
```

三种传输格式被适配器统一成同一个事件流：stream-json（claude/cursor/gemini）、JSONL（codex）、ACP over JSON-RPC（kiro/grok）。UI 和引擎保持两个进程、只走 localhost HTTP/SSE——这条纪律是为将来 Tauri 包壳成 Mac 应用留的。

### 继承自 Council 的模块

| 模块 | 作用 | 状态 |
|---|---|---|
| `core/adapters` | 6 个 CLI 适配、进程看门狗（静默/工具/墙钟三层超时、进程组终止） | 直接复用 |
| `core/orchestrator/runner` | 单次 agent 调用：预算、瞬时失败重试、结构化输出、事件流 | 直接复用 |
| `core/util/git` | worktree 创建/合并/清理，`todoagent/*` 分支即产出的唯一副本 | 直接复用 |
| `core/util/concurrency` | 全局信号量守住唯一的进程创建点 | 直接复用 |
| `core/db` + `web/board` | SQLite 存储、看板 UI | 改造中（任务合同、验收字段）|
| `core/orchestrator/pipeline` | 六阶段交叉评审（拆解→执行→互审→反驳→裁决→验证） | 保留，未来的深度模式 |
| `core/chat` + 频道/DM | Raft 式聊天 | 待改造为主 agent 对话入口 |

## 安全

**仅 localhost，且故意不做认证。** 所有适配器都以绕过工具确认的方式运行 CLI（`--permission-bypassPermissions`、`--yolo`、`--always-approve`）。单人本机工具可以接受；**一旦暴露端口，任何能访问的人都能在你机器上以你的凭据执行任意代码**。对外提供服务前必须先加认证和沙箱。

## 已知限制

- gemini 适配器未经真实运行（本机缺 API key），事件名属推测
- 合并冲突只上报，绝不自动解决
- 一个仓库同时只跑一个委托：两个委托并发 merge 会把结果搅坏且不可撤销
- 工作区有未提交改动时会拒绝启动（单专家模式除外）
