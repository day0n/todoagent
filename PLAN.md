# TodoAgent 原生 macOS 产品计划与状态

> 状态日期：2026-08-09
> 本文是 `master` 上原生 macOS 产品的实现边界、验收状态和后续路线。已经实现的能力与尚未实现的路线分开记录。

## 0. 仓库与分支基线

| 分支 | 定位 |
|---|---|
| `master` | TodoAgent 原生 macOS 产品的主分支与发布基线 |
| `legacy/web` | 旧 Web + Node Engine 产品及其完整历史 |

- 原生 App 不读取或导入旧 Web 数据库；两套产品的数据目录与启动方式保持隔离。
- `master` 的发布门禁只以 SwiftUI/AppKit 前端、Rust Engine sidecar、共享 IPC fixture 和 macOS 构建脚本为准。
- 旧 Web 的详细 M0–M7 计划不再复制到本文；需要维护旧产品时以 `legacy/web` 上的文档和代码为准。
- 分支调整不等于删除用户数据，也不要求对现有 Git 历史做重写。

## 1. 产品定义与首版边界

TodoAgent 是一个本地优先的 macOS 待办应用，提供两类彼此独立的 Agent 能力：

1. **任务 Session**：把一张任务卡绑定到 Codex、Claude Code、Cursor Agent 或 Kiro CLI，在用户选择的工作目录中持续对话和执行。
2. **TodoAgent 助手**：使用 Gemini 管理 TodoAgent 内的任务与清单，不启动本地 CLI，也不直接操作用户文件。

首版产品规则：

- 任务生命周期只有 `open | completed`；运行状态、失败状态和未读状态不冒充任务生命周期。
- 一个任务最多绑定一个长期逻辑 `TaskSession`、一个 Runtime 和一个工作目录；不支持同任务切换 Runtime 或跨 Agent 接力。
- 每条用户消息启动一次 CLI 进程；进程在本轮结束后退出，供应商 Session ID、聊天历史和未读位置保存在本地。
- 工作目录是否为 Git 仓库、是否存在未提交修改都不作为启动门槛。用户授权目录后，CLI 可以按自身能力读取或修改其中的文件。
- 本地 CLI 首版只接收文本消息。TodoAgent 助手额外支持 UTF-8 的 `.txt`、`.md` 文本附件，不支持图片、音频或其他多模态输入。
- 菜单栏入口首版只展示截止日期为今天且尚未完成的任务。

## 2. 原生架构

```text
SwiftUI / AppKit App
  ├─ 主窗口：日历、时间线、任务、清单、状态
  ├─ 右侧 Inspector：TodoAgent 助手
  ├─ 设置：Runtime 检测与 Gemini 配置
  └─ MenuBarExtra：今日任务
          │
          │ stdin/stdout NDJSON · TodoAgent IPC v2
          ▼
Rust Engine sidecar
  ├─ SQLite v3 migration / repository
  ├─ Codex / Claude / Cursor 流式适配器
  ├─ Kiro ACP v1 适配器
  ├─ 极简 Pi 风格 Assistant Kernel
  └─ Runtime、Turn、取消、恢复与事件调度
          ├──────── 本地 CLI 子进程
          └──────── Gemini Interactions API
```

- App 启动并管理随包分发的 Rust sidecar；原生运行路径不依赖 Node.js、Python、LiteLLM、`pie` 或 `yoagent`。
- Engine 使用 Tokio current-thread runtime；SQLite 写入经独立 Store worker 串行化，避免阻塞 IPC 与流式事件。
- IPC 使用请求 ID 对应响应，并允许异步事件穿插；握手必须确认协议版本 `2`。
- Swift 的 `AppRepository` 隔离 IPC 细节；助手流式状态放在独立 `AssistantViewState`，不写入全局任务 Snapshot。
- App 退出时先请求 Engine shutdown；Engine 取消活动 Turn、回收子进程后退出。

## 3. 数据模型与一致性

### 3.1 任务与本地 CLI Session

```text
Task → TaskSession → SessionTurn → SessionMessage / TurnEvent
```

- `Task.status`：`open | completed`。
- `TaskSession.state`：`idle | queued | running | failed | closed`。
- `SessionTurn.status`：`queued | running | completed | failed | cancelled | interrupted`。
- `SessionMessage.sequence` 在 Session 内递增；`lastAgentSequence > lastReadSequence` 表示有未读 Agent 消息。
- 同一 TaskSession 只允许一个活动 Turn；不同 TaskSession 最多同时运行两个 Turn。
- `session.send` 使用 UUID `clientMessageId` 幂等，超时重试不会重复启动同一条消息。
- Engine 重启时，遗留的活动 Turn 标记为 `interrupted` 并留下可见错误；不会自动重跑可能有副作用的 CLI 操作。

### 3.2 TodoAgent 助手

助手持久化使用独立模型：

- `chat_session` / `chat_message`：会话和稳定 UI 时间线；
- `assistant_turn`：模型、状态、用量、错误和时间；
- `assistant_step`：完整 Gemini step 投影；
- `assistant_tool_execution`：唯一 `callId` 工具回执，防止重试时重复创建或修改任务；
- `assistant_compaction`：结构化摘要及其安全覆盖位置。

同一助手会话只允许一个活动 Turn，不同助手会话最多同时运行两个 Turn。用户消息同样使用 `clientMessageId` 幂等。SQLite 是会话、模型步骤、工具回执和压缩摘要的唯一事实来源。

### 3.3 Migration

- 正式 schema 版本为 v3，支持全新数据库和原生 v2 → v3。
- migration 在事务内执行并记录版本与 checksum；启用外键和 WAL。
- 旧 `~/.todoagent` 和旧 Web 数据库永不读取。

## 4. 四个本地 Runtime

| Runtime | 首轮与续聊 | 结构化输入/输出 |
|---|---|---|
| Codex | `exec`，后续使用供应商 Session ID resume | JSON 事件流 |
| Claude Code | `--print`，后续 `--resume` | `stream-json` |
| Cursor Agent | 首轮 prompt，后续 `--resume` | `stream-json` |
| Kiro CLI | 首轮 `session/new`，后续 `session/load` | ACP v1 JSON-RPC |

共同约束：

- 设置页通过 `runtime.list / detect / verify` 展示 `missing`、`ready`、`auth_required`、`error` 等真实状态，并提供用户主动检测和恢复入口。
- 某个 Runtime 未安装或未登录，只影响该 Runtime，不阻塞其他 Runtime、App 构建或 DMG 生成。
- 每轮捕获文本、工具事件、原始受限事件、terminal 状态、退出码、usage 和供应商 Session ID。
- 取消和超时针对进程组执行终止与兜底清理，避免残留子进程。
- Runtime 输出只有在满足对应供应商的合法终态时才标记成功；缺失 terminal、解析失败或认证失败均为显式失败。

## 5. TodoAgent 极简 Agent Kernel

### 5.1 执行循环

助手直接调用 Gemini Interactions API：

- `stream=true`、`store=false`；
- `thinking_level=minimal`；
- 每次重新发送 system instruction、工具声明和本机 SQLite 重建的上下文；
- 严格聚合 `interaction.created → step.start/delta/stop → interaction.completed`，完整保留 `thought_signature`、function call 和 function result；
- SSE 中途断开时不提交未完成 step，也不执行参数不完整的工具；
- 模型无工具调用且产生有效文本时，才持久化最终回复并结束本轮。

固定限制：

| 项目 | 限制 |
|---|---:|
| 整轮时长 | 120 秒 |
| 单次模型请求 | 45 秒 |
| 单轮模型交互 | 最多 8 次 |
| 单轮工具调用 | 最多 32 次 |
| 网络瞬态错误 | 最多重试 2 次 |
| 用户文本 | 最多 16,000 字符 |
| 模型输出 | 最多 8,192 Token |

未知工具、无效参数和普通工具错误会作为 `isError` function result 回灌模型；认证错误和参数错误不做网络重试。用户取消或 Engine 重启后，不自动重放已经产生副作用的工具。

### 5.2 工具

首版只注册五个任务工具：

| 工具 | 能力 |
|---|---|
| `create_tasks` | 校验后原子创建 1–10 张任务卡 |
| `find_related` | 按标题和备注查找最多 10 条相关任务 |
| `update_task` | 修改标题、备注、清单和截止日期 |
| `list_state` | 读取 open/completed、运行中 Session 和未读摘要 |
| `list_lists` | 读取未归档清单 |

助手不提供 shell、任意文件读写、MCP、skills、CLI 派发或隐藏扩展工具。任务发生变化后发送 `task.changed`，Swift 再同步权威 Snapshot。

### 5.3 上下文与附件

- 有效上下文上限为 `min(模型 inputTokenLimit, 128,000)`；取不到模型元数据时使用 128,000。
- 接近上限前，在完整 Turn 边界生成增量摘要，保留最近约 20,000 Token；function call/result 不拆对。
- 压缩失败不删除历史；若上下文已经无法安全发送，则返回明确错误。
- `.txt` / `.md` 附件必须是 UTF-8：每轮最多 4 个，单个最多 128 KiB，总计最多 256 KiB。
- 附件内容随用户消息持久化到本机 SQLite，重启后可继续进入该会话的短期上下文。

## 6. 原生 UI 状态

已实现的首版界面：

- 主窗口：日历日期导航、时间线、任务、清单、进行中/已完成视图；任务与清单视图底部可行内添加任务。
- 任务卡：完成/重新打开、截止日期、清单归属、CLI Session 入口、运行和未读状态。
- Session：选择 Runtime 和工作目录后进入完整聊天记录，支持继续发送、取消本轮和重启恢复。
- 右侧 TodoAgent：折叠/展开、会话新建/切换/重命名/归档、流式草稿、处理中指示、工具状态、任务引用、停止按钮和文本附件。
- 设置：四个 Runtime 的检测/验证；Gemini 模型、API Key 保存/移除/显示和只读模型连接测试。
- 菜单栏：查看今天到期且未完成的任务，并打开主窗口。

## 7. 本地存储与安全边界

默认路径：

- 数据库：`~/Library/Application Support/TodoAgent/todoagent.sqlite3`
- Gemini 凭据：`~/Library/Application Support/TodoAgent/credentials.json`
- 日志：`~/Library/Logs/TodoAgent/`

约束：

- Application Support 数据目录权限为 `0700`；SQLite 和凭据文件权限为 `0600`。
- 凭据文件使用同目录临时文件、同步和原子替换；读写拒绝符号链接、异常文件类型、非当前账户所有者、硬链接和权限过宽文件。
- API Key 不进入 SQLite、UserDefaults、环境变量或日志，只在 App 启动后通过 stdin IPC 注入 Engine 的 `Zeroizing<String>` 内存。
- 当前凭据文件依赖 macOS 登录账户和文件权限隔离，不是独立加密保险箱；同一登录账户下的其他进程仍可能读取，建议启用 FileVault。
- 工作目录必须由用户选择并授权。启动 CLI 前不因 Git dirty 状态弹出阻断提示；该目录中的修改属于用户与所选 CLI 的共同工作区。

## 8. 测试与发布门禁

每次准备交付依次执行：

1. `cargo fmt --check`；
2. `cargo clippy --locked --all-targets -- -D warnings`；
3. `cargo test --locked`；
4. Swift 6.2 strict-concurrency 测试并将 warning 视为错误；
5. arm64 Release 构建；
6. sidecar 架构、IPC v2 握手、SQLite v3 隔离数据库 smoke test；
7. ad-hoc 签名校验、DMG 挂载与启动检查；
8. 空闲 App + Engine footprint 和 CPU 复测。

覆盖范围：

- 数据库 fresh/v2→v3、事务回滚、WAL、外键、权限、未读和 interrupted 恢复；
- IPC 半行、坏 JSON、超长行、乱序响应、版本不匹配、事件缺口与幂等发送；
- 四个 Runtime 的真实 fixture、成功终态、resume、认证失败、取消、超时和进程组清理；
- Assistant SSE、分片工具参数、错误回灌、tool receipt 幂等、取消、并发、压缩和附件重启恢复；
- Swift Repository/Reducer 的 delta 聚合、去重、补历史、重连、异步退出、菜单栏和凭据文件安全。

## 9. 2026-08-09 验收快照

以下是当前工作区最近一次记录的验收结果，不替代提交前重跑门禁：

- Rust：format、Clippy 和 77 个测试通过。
- Swift：Swift 6.2 strict-concurrency 下 64 个测试通过。
- 构建产物：`dist/TodoAgent.app` 与 `dist/TodoAgent-0.1.0-arm64.dmg`；内嵌 Engine 为 arm64，IPC v2 / schema v3 smoke 通过。
- 真实本地续聊：本机已安装且已登录的 Codex、Claude Code、Kiro CLI 完成至少两轮续聊 smoke；Cursor Agent 在本机返回 `auth_required`，已验证可操作的恢复状态，但尚未计入真实续聊通过项。
- Gemini 助手：真实文本回复、任务工具执行、多轮上下文、取消和 `.txt` / `.md` 附件路径已打通。
- 空闲性能记录：App 约 102.7 MiB、Engine 约 2.7 MiB，合计约 105.3 MiB；CPU 0.0%，低于当前 120 MiB 总预算。

## 10. 当前限制

- 只支持 macOS 26、Apple Silicon arm64。
- 当前 App 仅 ad-hoc 签名，未使用 Developer ID、未公证，不是面向陌生用户的正式公开发行包。
- 不提供 Intel/Universal 构建、自动更新或崩溃上报服务。
- 不导入旧 Web 数据；不支持同任务多 Runtime、跨 Agent 接力或任务 Session 分支树。
- TodoAgent 助手不读取任意文件，不处理图片，不调用本地 CLI；文本附件由用户显式选择并完整写入本机会话历史。
- API Key 的账户私有文件不是 Keychain，也没有独立静态加密。
- Cursor 的真实登录态续聊仍需在已认证环境完成验收。

## 11. 后续路线

### 11.1 公开发布阶段

- 加入 Developer ID Application 签名和 Apple 公证，并设计从当前凭据文件迁移到稳定 Keychain 身份的路径。
- 评估 Apple Silicon + Intel 的 Universal 构建、Sparkle 或等价自动更新、版本回滚和崩溃诊断。
- 在全新用户账户完成首次安装、覆盖升级、退出无残留进程、删除 App 不删除 Application Support 数据的验收。
- 在已认证环境补齐四个 Runtime 各至少三轮真实续聊，并把供应商版本矩阵固定进发布记录。

### 11.2 用户长期记忆调研

本轮不创建 `MEMORY.md`、数据库占位表、IPC 占位方法或半成品 UI。开始实现前必须单独确定：

- 哪些内容允许提取，哪些敏感信息永不自动记录；
- 是否逐条向用户确认，以及查看、修改、删除、导出和批量遗忘流程；
- 记忆按用户、清单、工作目录还是 Assistant Session 生效；
- 冲突、过期、误提取和提示注入的处理规则；
- 本机加密、备份、彻底删除和 Token 预算边界；
- 注入上下文时如何展示来源和提供可解释性。

只有产品、安全和删除语义通过独立评审后，才设计正式 schema、IPC 和界面。

### 11.3 产品增量

- 在不改变 `open | completed` 生命周期的前提下继续打磨任务排序、搜索、批量操作和可访问性。
- 根据真实使用数据决定是否增加更多文本格式或图片能力；任何新附件类型都必须先定义大小、持久化和隐私边界。
- 持续压测长会话、事件洪峰和四个 Runtime 的版本变化，保持空闲总 footprint 低于 120 MiB。
