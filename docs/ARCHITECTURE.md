# Architecture

本文描述 TodoAgent `master` 上的当前原生架构。未来工作与尚未实现能力见
[`../TODO.md`](../TODO.md)。

## 系统结构

```text
TodoAgent macOS App
  ├─ SwiftUI：任务、清单、时间线、设置、Gemini 助手
  ├─ AppKit：窗口、菜单、文件授权与原生交互
  ├─ Task Workbench Window
  │    └─ GhosttyKit Surface / PTY
  │         └─ todoagent-terminal-runner
  │              └─ Codex / Claude Code / Cursor Agent / Kiro CLI
  └─ EngineClient
           │ stdin/stdout NDJSON · IPC v4
           ▼
Rust Engine sidecar
  ├─ SQLite schema v5 / serialized Store worker
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
launch descriptor；App 使用随包 `todoagent-terminal-runner` 启动实际 CLI。Runner
不经过 shell 拼接命令，负责：

- 独立进程组和退出清理；
- Host 存活监控；
- 经过 token 验证的 started/status/exited 事件；
- 将终端字节留在 PTY，而不是写入 Engine stdout。

TodoAgent 不解析或持久化 CLI 的终端内容。关闭任务工作台窗口只隐藏 surface，不结束
Agent；显式结束 Session、删除任务或退出 App 才会停止对应进程组。

## 任务工作台模型

```text
Task 1 ── TerminalSession 1 ── TerminalRun 1..n
```

- 一个任务最多绑定一个 `TerminalSession`。
- Session 固定绑定一个 Runtime 和一个规范化工作目录。
- 工作目录移动后，用户可以显式重新授权并 rebind；Runtime 和 Provider Session ID
  不变。
- 每个 Session 同时只允许一个活动 Run；Run 分为 `fresh` 或 `resume`。
- Provider Session ID 只能从未绑定状态绑定一次；无法唯一判断 Codex/Kiro 候选时，
  必须由用户选择，TodoAgent 不猜“最近会话”。
- 多个任务可以并行运行独立终端；启动第 4 个活跃终端前 App 会提示资源开销，Engine
  当前不设置跨任务的硬并发上限。

一个任务不能切换 Runtime，也没有跨 Agent 接力或 Session 分支树。这些是
[`../TODO.md`](../TODO.md) 中的未来能力。

## SQLite v5

SQLite 是任务和持久元数据的事实来源。主要数据包括：

- 任务、清单、执行日期、截止日期和任务附件；
- Runtime 检测与验证状态；
- `terminal_session`、`terminal_run` 和去重的状态 receipt；
- Gemini 助手 Session、Message、Turn、Step、Tool execution 和 Compaction；
- 设置、schema migration 与单调 revision。

PTY 字节和旧终端滚屏不写入 SQLite。

### v4 → v5 迁移

打开 v4 数据库时，Engine 会先创建权限为 `0600` 的时间戳备份，然后在事务中迁移：

- 保留任务、清单、托管附件、Runtime、设置和 Gemini 助手数据；
- 删除上一代结构化 CLI 的 `task_session`、Turn、Message 和 Event 表；
- 创建 `terminal_session`、`terminal_run` 和 terminal status receipt；
- 验证 foreign keys 和 schema checksum 后提交。

低于 v4、无法识别或高于当前版本的数据库会被原样保留并拒绝打开，不会静默删除。
原生 App 也不会读取或导入旧 Web 数据。

## 任务与编辑一致性

- `Task.status` 只有 `open | completed`。
- `executionDate` 与 `dueDate` 是彼此独立的本地日历日；只有执行日期决定时间线和
  “今日任务”投影。
- 标题与备注使用 800ms trailing autosave。文本控件聚焦或存在 IME composition 时，
  本地 draft 保持权威；失焦、关闭、启动 Session 和退出 App 时强制 flush。
- 日期、状态和附件立即保存。
- 任务附件被复制为 Engine 管理的本地副本；原文件不会被修改。

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
