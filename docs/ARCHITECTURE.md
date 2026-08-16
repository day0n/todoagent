# Architecture

本文描述 TodoAgent `master` 上的当前原生架构。未来工作与尚未实现能力见
[`../TODO.md`](../TODO.md)。

## 系统结构

```text
TodoAgent macOS App
  ├─ SwiftUI：任务、清单、日期投影、设置、Gemini 助手
  ├─ AppKit：窗口、菜单、文件授权与原生交互
  ├─ Main Window Task Workspace
  │    ├─ compact task rail
  │    └─ retained GhosttyKit Surface / PTY
  │         └─ todoagent-terminal-runner
  │              └─ Codex / Claude Code / Cursor Agent / Kiro CLI
  └─ EngineClient
           │ stdin/stdout NDJSON · IPC v4
           ▼
Rust Engine sidecar
  ├─ SQLite schema v6 / serialized Store worker
  ├─ Runtime discovery, verification and launch plans
  ├─ Terminal Session, Run and status receipts
  └─ Gemini assistant kernel
           └─ Gemini Interactions API · stream=true · store=false
```

原生运行路径不依赖 Node.js、Web server、Python、LiteLLM、`pie` 或 `yoagent`。
`legacy/web` 分支保留旧 Web + Node.js 产品；两者不共享启动方式或数据目录。

## 进程与通信

### App 与 Engine

App 启动一个随包分发的 `todoagent-engine` sidecar，并通过 stdin/stdout 上的 NDJSON
通信。Engine stdout 只用于 IPC，诊断输出进入 stderr 或应用日志。

- 协议版本：IPC v4。
- 请求使用 ID 匹配响应；异步事件可以穿插。
- Swift `EngineClient` 是 Engine 进程、stdin/stdout/stderr、握手和退出流程的唯一
  所有者。
- App 退出时先停止活动终端，再请求 Engine shutdown；异常遗留 Run 会在下次启动时
  标记为 `interrupted`。

Swift 与 Rust 共用的契约 fixture 位于
[`../protocol/fixtures/contract.ndjson`](../protocol/fixtures/contract.ndjson)。

### Terminal Runner 与 PTY

每个任务工作台都可以拥有一个独立 Ghostty PTY surface。Engine 生成经过验证的
launch descriptor；App 把只包含随包 Runner 与 descriptor 路径的严格引用命令注入
保留的 login shell。Agent executable 与参数不进入 shell，由
`todoagent-terminal-runner` 从 descriptor 验证后直接执行。Runner 负责：

- 独立进程组和退出清理；
- Host 存活监控；
- 经过 token 验证的 started/status/exited 事件；
- 将终端字节留在 PTY，而不是写入 Engine stdout。

TodoAgent 不解析或持久化 CLI 的终端内容。收起终端或切换任务只 detach surface，不结束
Agent；删除任务或退出 App 会停止对应进程组。退出 App 时，正在
运行且已有稳定 Provider Session ID 的受管 Run 会先持久化 `app_shutdown` /
`auto_resume=1`；下次打开同一任务后重建 PTY，并恢复同一个 Provider Session。

## 任务工作台模型

```text
Task 1 ── TerminalSession 0..1（task_id UNIQUE）
         └─ TerminalRun 0..n（fresh / resume）
```

- 首次点击任务会直接创建该任务唯一的 TerminalSession 和普通 shell；收起或切换任务
  继续复用同一个 Controller、surface 和 PTY。
- Agent 必须通过工作台的受管入口启动。Engine 在开始前持久化 Run identity 与 launch
  mode；Claude 预分配、Cursor 预创建得到的 Provider ID 同步保存，Codex/Kiro 的 ID
  则在运行期经 Hook/元数据验证，或退出后由用户确认精确候选后绑定。
- Cmd+Q 会结束本地进程组；只有已有稳定 Provider ID 的活动受管 Run 才保留
  `auto_resume=1`。新 App 进程打开任务时只对这个持久标记自动 launch，并使用同一个
  Provider Session ID。
- 普通进程退出或用户显式结束不会自动重启；终端回到 shell，不显示恢复或新建
  Provider Session 页面。如果 Provider transcript 缺失，自动恢复不会静默创建另一段
  对话，可用 shell 仍保持可见。
- PTY scrollback 与任意手打 shell 进程不属于跨 App 重启的恢复状态。普通 shell 中手打
  的 `claude` 不会被误认为已登记的可恢复 Run；同一 App 进程内收起和切换仍保留 PTY。
- 多个任务可以并行运行独立终端；启动第 4 个活跃终端前 App 会提示资源开销，Engine
  当前不设置跨任务的硬并发上限。

不做多 Agent 并排、Session 树或跨 Runtime 接力。这些是
[`../TODO.md`](../TODO.md) 中的未来能力。

## SQLite v6

SQLite 是任务和持久元数据的事实来源。主要数据包括：

- 任务、清单、执行日期、截止日期和任务附件；
- Runtime 检测与验证状态；
- `terminal_session`（含 `last_exit_reason` / `auto_resume`）、`terminal_run` 和去重的状态 receipt；
- Gemini 助手 Session、Message、Turn、Step、Tool execution 和 Compaction；
- 设置、schema migration 与单调 revision。

PTY 字节和旧终端滚屏不写入 SQLite。

### v4 → v5 迁移

打开 v4 数据库时，Engine 会先创建权限为 `0600` 的时间戳备份，然后在事务中迁移：

- 保留任务、清单、托管附件、Runtime、设置和 Gemini 助手数据；
- 删除上一代结构化 CLI 的 `task_session`、Turn、Message 和 Event 表；
- 创建 `terminal_session`、`terminal_run` 和 terminal status receipt；
- 验证 foreign keys 和 schema checksum 后提交。

### v5 → v6 迁移

Engine 会先为 v5 数据库创建另一份 `0600` 备份，再在事务中为
`terminal_session` 增加 `last_exit_reason` 与 `auto_resume`。迁移只会把最新 Run
确认为 `app_shutdown` 或 `engine_interrupted` 且已有 Provider ID 的 Session 标记为
可自动恢复；普通退出保持停止状态。

低于 v4、无法识别或高于当前版本的数据库会被原样保留并拒绝打开，不会静默删除。
原生 App 也不会读取或导入旧 Web 数据。

## 任务与编辑一致性

- `Task.status` 只有 `open | completed`。
- `executionDate` 与 `dueDate` 是彼此独立的本地日历日；当前“今天”投影只由
  `executionDate == 本地 currentDay` 决定。
- 标题与备注使用 800ms trailing autosave。文本控件聚焦或存在 IME composition 时，
  本地 draft 保持权威；失焦、关闭、启动 Session 和退出 App 时强制 flush。
- 日期、状态和附件立即保存。
- 任务附件被复制为 Engine 管理的本地副本；原文件不会被修改。

## “今天”视图架构

当前 UI、Assistant 和 Store 遵循以下契约：

- “今天”不新增任务表或复制任务记录，而是把
  `executionDate == 本地 currentDay` 作为动态查询条件；任务总库存独立存在。
- 加入或移出“今天”只分别设置当天 `executionDate` 或清除该字段。该 mutation 不改
  `dueDate`、任务 ID、TerminalSession、TerminalRun 或 Controller 生命周期。
- 旧数据库中的未来 `executionDate` 继续按原值读取和写回，不做批量清除或迁移；新 UI
  不再把这些值投影为明天、后天等未来时间线列。
- 主窗口仍由左侧任务 rail 和右侧 retained terminal 组成。rail 根据打开来源使用
  “今天”或任务/清单的紧凑范围，切换 rail 项只重新挂载对应 surface。
- 左箭头收起终端时只 detach surface；活动 Agent、PTY 和同一 App 生命周期内的
  scrollback 保持不变。右侧不提供重复的 `Esc` 收起 affordance。
- Gemini 助手的任务 mutation 在 Store 前拒绝非本地当天的非空 `executionDate`；
  `dueDate` 仍可独立表达将来的截止日期，日期查询保持向后兼容。

## Gemini 任务助手

Gemini 助手和 Coding Agent Terminal 是两套独立能力。助手通过 Gemini Interactions
API 流式运行，设置 `store=false`，每次从本地 SQLite 重建上下文。

它只注册六个任务工具：

- `create_tasks`
- `find_related`
- `update_task`
- `delete_task`
- `list_state`
- `list_lists`

工具 receipt 与 `clientMessageId` 保证重试不会重复修改任务。助手支持多会话、取消、
恢复和在完整 Turn 边界上的上下文压缩，但这只是会话历史管理，不是跨任务长期记忆。

助手没有 shell、任意文件读写、MCP、skills 或 Terminal/CLI 派发权限。它只能读取用户
在该消息中明确附加的 UTF-8 `.txt` / `.md` 文件；任务附件不会自动进入 Prompt。

## Demo 与测试路径

`DemoRepository` 只用于 SwiftUI Preview 和确定性测试。普通启动始终使用共享的
`EngineRepository` 与随 App 打包的 Rust sidecar。测试和 smoke run 可通过
`TODOAGENT_NATIVE_DATA_DIR` 与 `TODOAGENT_NATIVE_LOG_DIR` 使用隔离目录。
