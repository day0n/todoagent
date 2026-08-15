# TodoAgent Rust Engine

`apps/engine-rs` 是原生 macOS TodoAgent 随 App 打包的 Rust sidecar。它负责 SQLite
持久化、四个本地 CLI Runtime 的启动描述、Gemini 助手内核和终端生命周期元数据。
Engine 只通过 stdin/stdout 上的版本化 NDJSON 通信，不监听 TCP 端口。

完整系统图与本地 Runtime 规则分别见
[`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) 和
[`../../docs/RUNTIMES.md`](../../docs/RUNTIMES.md)。本文只记录 Engine 子工程细节。

## 模块

- `main.rs` / `protocol.rs`：IPC v4 握手、请求分发、事件输出和 Engine 生命周期。
- `store.rs` / `store_worker.rs` / `schema.sql`：SQLite v6 schema、事务和串行
  数据访问。
- `runtime.rs` / `terminal.rs`：Codex、Claude Code、Cursor Agent、Kiro CLI 的
  检测、验证、fresh/resume launch plan、Provider ID 候选扫描和安全 descriptor。
- `bin/todoagent-terminal-runner.rs`：不经 shell 启动 Agent，管理独立进程组、宿主
  存活监控和经过 token 验证的生命周期/Hook 事件。
- `assistant/` / `assistant_service.rs`：极简 ReAct Runner、Gemini Interactions SSE、
  本地上下文、压缩、工具 receipt 和流式事件。

Swift 和 Rust 共用的 NDJSON 契约 fixture 位于仓库根目录
`protocol/fixtures/contract.ndjson`。

## 数据模型与并发

SQLite 是 Session 元数据的唯一事实来源，schema version 为 6。Engine 保存任务、
清单、任务附件、`terminal_session`（含 `last_exit_reason` / `auto_resume`）、每次
官方 Agent 启动对应的 `terminal_run`，以及助手 Session、Turn、模型步骤、工具执行
和上下文摘要。终端 PTY 字节和滚屏不写入 SQLite。

- 每个 Terminal Session 同时只允许一个活动 Run；不同任务的 Run 不设 Engine
  semaphore 上限，App 在启动第 4 个活跃终端前提示资源消耗。
- 同一个 Assistant Session 同时只允许一个活动 Turn；不同 Assistant Session 最多
  并行 2 个 Turn。
- `clientMessageId` 和持久化工具 receipt 用于防止超时重试产生重复消息或重复任务。
- `task.attachment.add/remove` 要求稳定的 `clientMutationId`；SQLite receipt 使响应丢失
  后的同参数重放直接成功且不会重复复制或删除，复用同一 UUID 发送不同参数会返回冲突。
- `terminal.session.create` 只建终端行，不再预绑 Claude Provider ID。同一任务已有
  终端则复用；Runtime 和对话可在后续 fresh 启动时更换。
- `terminal.session.prepare_launch` 接受 `intent=fresh|resume|auto`。自动 resume
  仅当 `auto_resume=1`（上次以 `app_shutdown` / `engine_interrupted` 结束且仍有
  Provider ID）。Claude 每次 fresh 使用新 UUID。
- 无活动 Run 时允许替换 Provider Session ID；`auto_resume=1` 或正在 Resume 的
  Run 遇到不同 ID 仍返回 `provider_session_conflict`。
- Engine 重启时，遗留的活动 Terminal Run 会标记为 `interrupted` 并置 `auto_resume`；
  App 终止旧 host/Agent，再打开任务时自动续上那段对话。

从 v4 打开时会先建立权限为 `0600` 的数据库备份，再迁移到 v5，然后备份 v5 并迁到
v6。更旧、未知或高于 v6 的 schema 会原样保留并拒绝打开。

## Gemini 助手边界

Provider 使用 Gemini Interactions API 的 SSE 模式，并固定 `store=false`；每次请求
从本地 SQLite 重建所需上下文。API Key 通过 IPC 注入内存，以敏感 Header 发送，
不会写入 Engine 数据库、环境变量或日志，Provider 错误也会脱敏。

助手只注册六个任务工具：

- `create_tasks`
- `find_related`
- `update_task`
- `delete_task`
- `list_state`
- `list_lists`

`delete_task` 只接受来自查询结果的准确任务 ID。删除全部任务时，助手会先读取
open 和 completed 首屏的精确总数并确认同一 `taskRevision`。单次请求最多删除
20 个任务；超过时不会继续分页或删除，而会要求分批。未超过时才收集完整 ID
并逐个删除；运行中或排队中的本地 Session 会阻止对应任务被删除。

Engine 不向助手开放 shell、任意文件读写、MCP 或本地 CLI 派发。

`list_state` 在传入 `executionDate`、`status` 或 `listId` 时使用最多 50 条的
快照分页。返回值和 `pagination.nextCursor` 都带独立的 `taskRevision`；工具 receipt、
聊天消息和 Session 变化不会推进它。若分页期间任务被创建、修改日期/状态/标题或
移动清单，续页返回 `list_state_cursor_stale`，调用方必须丢弃旧页面并从第一页重查。

## 本地路径

默认路径：

- 数据库：`~/Library/Application Support/TodoAgent/todoagent.sqlite3`
- 附件目录：`~/Library/Application Support/TodoAgent/Attachments`
- 日志目录：`~/Library/Logs/TodoAgent`

Engine 不读取或修改旧版 `~/.todoagent`。测试和隔离 smoke run 可使用：

- `TODOAGENT_NATIVE_DATA_DIR`
- `TODOAGENT_NATIVE_LOG_DIR`

数据与日志目录会被设置为 `0700`，SQLite 文件会被设置为 `0600`。

## 构建与验证

从仓库根目录运行：

```bash
cargo fmt --manifest-path apps/engine-rs/Cargo.toml --all -- --check
cargo clippy --manifest-path apps/engine-rs/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path apps/engine-rs/Cargo.toml --locked
cargo build --release --locked --manifest-path apps/engine-rs/Cargo.toml
```

完整 App 打包使用：

```bash
./scripts/build-macos-preview.sh
```

脚本会把 release binary strip 后嵌入 `TodoAgent.app/Contents/Resources`，并做 ad-hoc
签名。该签名不是 Developer ID 签名，也没有苹果公证，只适用于本机开发和预览。
