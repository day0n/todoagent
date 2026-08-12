# TodoAgent

TodoAgent 是一款原生 macOS 待办与本地 Agent 工作台。任务、清单、对话和
Runtime 状态都保存在本机；SwiftUI/AppKit 前端通过 stdin/stdout 上的 IPC v3
与随 App 打包的 Rust Engine 通信，不启动 Web 服务或本地 TCP 端口。

## 分支定位

- `master`：当前主产品，原生 macOS App 与 Rust Engine 的发布基线。
- `legacy/web`：旧 Web/Node.js 前后端基线；维护旧产品时使用这个分支。

原生版本不会读取旧版 `~/.todoagent` 数据库，也不会自动导入 Web 数据。

## 当前能力

- 管理任务、清单、执行日期、截止日期、附件和未完成/已完成状态。
- 时间线、总任务和自定义清单统一将未完成任务直接排在上方；已完成任务只在存在时
  显示于下方“已完成”分组。未完成任务的截止日或执行日已经过去时，统一以红色
  显示需要处理的日期和星期。
- 任务卡支持原生右键菜单，可完成/重新打开、设置两个日期、移动清单、根据任务创建清单和安全删除；菜单打开期间任务卡保持选中阴影，清楚标示当前操作目标。
- 时间线固定显示所选日期起连续四天，只按执行日期排期；每列的快速添加栏固定在
  底部，任务较多时只滚动中间任务区。菜单栏显示今天全部任务。
- 任务详情与本地 Session 按当前主窗口尺寸展示为紧凑双栏，窄窗自动切换上下布局，不再用接近全屏的固定 Sheet 遮住主界面。
- 任务启动本地 Agent 后会先建立一个空的长期逻辑 Session，不会自动发送任务信息；
  用户主动发送消息后才启动一轮 CLI，历史和供应商 Session ID 持久化到 SQLite，
  较长的工具结果默认折叠并可点击展开。
- 支持四个本地 Runtime：Codex、Claude Code、Cursor Agent、Kiro CLI。
  Runtime 由用户在设置中主动检测和验证；某个 Runtime 未安装或未登录不会影响
  其他 Runtime。
- 内置 Gemini 任务助手：多会话、流式回复、取消、上下文压缩和崩溃恢复。
  助手只开放 `create_tasks`、`find_related`、`update_task`、`delete_task`、
  `list_state`、`list_lists` 六个任务工具。
- 助手工具调用按实际 Turn 穿插在对应问答之间，不再集中堆到对话末尾；运行状态
  使用静态文字与图标。右侧对话栏顶部只保留会话选择、“开始新对话”和“隐藏对话”，
  会话记录使用栏内的 TodoAgent 风格下拉卡片，不再弹出覆盖顶部的系统菜单。
- 主窗口首次以 1120×720 左右的居中中等尺寸出现；TodoAgent 始终按类似 Notion
  的比例停靠在任务板右侧，窄窗或左右分屏时也保留任务区、左侧日历与导航。
- 助手对话可读取 UTF-8 `.txt` 和 `.md` 附件；任务附件是独立的本地备忘，名称、
  路径和内容都不会进入助手或本地 CLI Session。

## 架构

```text
SwiftUI / AppKit
       │  IPC v3 · NDJSON · stdin/stdout
       ▼
Rust Engine
  ├─ SQLite v4：任务双日期、任务附件、Session、消息、事件和助手上下文
  ├─ CLI adapters：Codex / Claude Code / Cursor Agent / Kiro CLI
  └─ Gemini Interactions API：store=false，持久化上下文仅保存在本机
```

`DemoRepository` 仅用于 SwiftUI 预览和确定性的 UI 测试。普通启动始终使用共享的
`EngineRepository` 和随 App 打包的 Rust sidecar。

## 本地构建

要求：

- macOS 26+
- Apple Silicon
- Xcode 26+
- Rust 1.88
- Swift 6.2（由 Xcode 提供）

在仓库根目录运行：

```bash
./scripts/build-macos-preview.sh
open dist/TodoAgent.app
```

构建产物：

- `dist/TodoAgent.app`：可直接打开的日常调试版本，不需要反复复制到
  `/Applications`。
- `dist/TodoAgent-0.1.0-arm64.dmg`：Apple Silicon 本地预览 DMG。

脚本会构建并 strip arm64 Rust sidecar，将其嵌入 App Resources，再对 sidecar 和
App 做 ad-hoc 签名。

## 验证

```bash
cargo fmt --manifest-path apps/engine-rs/Cargo.toml --all -- --check
cargo clippy --manifest-path apps/engine-rs/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path apps/engine-rs/Cargo.toml --locked

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox --package-path apps/macos \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

Swift 和 Rust 共用的 IPC 契约 fixture 位于 `protocol/fixtures/contract.ndjson`。

## 本地数据与密钥

| 内容 | 路径 |
|---|---|
| SQLite | `~/Library/Application Support/TodoAgent/todoagent.sqlite3` |
| Gemini API Key | `~/Library/Application Support/TodoAgent/credentials.json` |
| Engine 附件目录 | `~/Library/Application Support/TodoAgent/Attachments` |
| Engine 日志 | `~/Library/Logs/TodoAgent/engine-stderr.log` |

TodoAgent 将 Application Support 数据目录设置为 `0700`，SQLite 与凭据文件设置为
`0600`。Gemini Key 不写入 SQLite、环境变量或日志；它是当前 macOS 账户下的普通
权限隔离文件，并非 Keychain 加密项。同一登录账户下的其他进程仍可能读取，建议
开启 FileVault。

## 分发边界

当前 App 只有 ad-hoc 签名，不含 Developer ID 签名和苹果公证，适合本机开发与
预览，不是面向公众的正式安装包。公开下载仍需单独完成 Developer ID 签名、
notarization、Gatekeeper 验收；Universal 构建和自动更新也不在当前版本范围内。

更详细的实现状态与后续事项见 [`PLAN.md`](PLAN.md)。
