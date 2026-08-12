# TodoAgent Rust Engine

`apps/engine-rs` 是原生 macOS TodoAgent 随 App 打包的 Rust sidecar。它负责 SQLite
持久化、四个本地 CLI Runtime、Gemini 助手内核和进程生命周期。Engine 只通过
stdin/stdout 上的版本化 NDJSON 通信，不监听 TCP 端口。

## 模块

- `main.rs` / `protocol.rs`：IPC v3 握手、请求分发、事件输出和 Engine 生命周期。
- `store.rs` / `store_worker.rs` / `schema.sql`：SQLite v4 schema、事务和串行
  数据访问。
- `runtime.rs` / `adapters.rs`：Codex、Claude Code、Cursor Agent、Kiro CLI 的
  检测、验证、首轮启动、续聊、取消和进程组回收。
- `assistant/` / `assistant_service.rs`：极简 ReAct Runner、Gemini Interactions SSE、
  本地上下文、压缩、工具 receipt 和流式事件。

Swift 和 Rust 共用的 NDJSON 契约 fixture 位于仓库根目录
`protocol/fixtures/contract.ndjson`。

## 数据模型与并发

SQLite 是唯一事实来源，schema version 为 4。Engine 保存任务、清单、任务附件、
`TaskSession`、每轮 CLI 执行、稳定消息投影、原始事件，以及助手 Session、Turn、
模型步骤、工具执行和上下文摘要。

- 同一个 CLI Session 同时只允许一个活动 Turn；不同 Session 最多并行 2 个 Turn。
- 同一个 Assistant Session 同时只允许一个活动 Turn；不同 Assistant Session 最多
  并行 2 个 Turn。
- `clientMessageId` 和持久化工具 receipt 用于防止超时重试产生重复消息或重复任务。
- `task.attachment.add/remove` 要求稳定的 `clientMutationId`；SQLite receipt 使响应丢失
  后的同参数重放直接成功且不会重复复制或删除，复用同一 UUID 发送不同参数会返回冲突。
- `session.create` 只持久化空的 `idle` Task Session；同任务、Runtime 和规范化工作目录
  的空 Session 可安全重放。首条可见用户消息和 CLI Turn 只由后续 `session.send` 创建。
- Engine 重启时，遗留的运行中 Turn 会被标记为 `interrupted`，不会自动重放有副作用
  的工具。

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
