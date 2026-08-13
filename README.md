# TodoAgent

![Status](https://img.shields.io/badge/status-developer_preview-orange)
![Platform](https://img.shields.io/badge/platform-macOS_26%2B-black)
![Architecture](https://img.shields.io/badge/architecture-Apple_Silicon_arm64-black)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-1.88.0-000000?logo=rust&logoColor=white)

TodoAgent 是一款本地优先的原生 macOS 待办与 Agent 工作台。它把任务、工作目录和
你已经安装的 Coding Agent CLI 放在同一个桌面界面中：每个任务都有独立工作台，
左侧管理任务，右侧直接操作 Agent 自己的真实终端界面。

> **项目状态：开发预览。** 当前只支持 macOS 26+ 与 Apple Silicon arm64；本地
> DMG 使用 ad-hoc 签名，尚未经过 Developer ID 签名和 Apple 公证，不是面向公众的
> 正式发行包。

[快速开始](#本地构建与运行) · [公开 TODO](TODO.md) ·
[架构](docs/ARCHITECTURE.md) · [Runtime 集成](docs/RUNTIMES.md) ·
[贡献指南](CONTRIBUTING.md) · [安全策略](SECURITY.md)

## 为什么是 TodoAgent

Coding Agent 已经能在终端里工作，但任务管理、工作目录、会话恢复和日常进度通常
散落在不同工具中。TodoAgent 的目标是提供一个可见、可恢复、由用户掌控的本地工作台，
同时保留 Codex、Claude Code、Cursor Agent 和 Kiro CLI 各自原生的交互体验。

## 当前能力

- 管理任务、清单、执行日期、截止日期、状态和本地附件；支持四日时间线、逾期提示、
  菜单栏今日任务和原生右键操作。
- 为每个任务打开独立工作台窗口，在嵌入式 Ghostty PTY 中直接运行 Coding Agent
  自己的 TUI。
- 检测并验证 Codex、Claude Code、Cursor Agent、Kiro CLI；单个 Runtime 未安装或
  未登录时不会阻塞其他功能。
- 将一个任务绑定到一个 Runtime 和一个工作目录，管理 Agent 的启动、精确恢复、
  Provider Session ID、状态和进程组生命周期。
- 使用 Gemini 任务助手创建、查找、更新和删除 TodoAgent 中的任务；支持多会话、
  流式回复、取消、崩溃恢复和会话内上下文压缩。
- 任务、会话元数据和助手上下文保存在本机 SQLite；Engine 通过 stdin/stdout 上的
  NDJSON IPC v4 与 App 通信，不启动 Web 服务或本地 TCP 端口。

### 能力边界

| 能力 | 当前状态 |
|---|---|
| 用户在 TodoAgent 内直接操作四家 CLI TUI | 已实现，发布验收仍在进行 |
| TodoAgent 助手管理任务与清单 | 已实现 |
| TodoAgent 自动向 Coding Agent 派发任务并收集结果 | 计划中 |
| 不同 Agent 之间接力或协作 | 计划中 |
| 跨任务、跨会话的长期语义记忆 | 调研中 |

当前的“直接操作 CLI”指用户在内嵌终端中操作原生 TUI。TodoAgent 不解析四家 CLI 的
对话输出，不会自动发送任务标题、备注或附件，也不保存旧终端滚屏。Gemini 任务助手
没有 shell、任意文件读写或 CLI 派发权限。自动派发、结果回收和跨 Agent 编排是独立的
[后续路线](TODO.md)，不能与现有终端能力混为一谈。

## 支持的本地 Runtime

| Runtime | 新会话 | 恢复 | 当前集成方式 |
|---|---|---|---|
| Codex | 支持 | 支持 | 原生 TUI + 工作目录绑定 |
| Claude Code | 支持 | 支持 | 原生 TUI + 预分配 Session ID |
| Cursor Agent | 支持 | 支持 | 原生 TUI + Workspace/Chat 绑定 |
| Kiro CLI | 支持 | 支持 | `chat --tui` + Session ID |

这些 CLI 不随 TodoAgent 分发，用户需要自行安装并完成登录。上游命令行参数、会话存储
和 Hook 能力可能变化；TodoAgent 会在启动前探测当前安装是否具备所需能力。具体的
fresh/resume 规则、状态 Hook 和兼容性边界见
[`docs/RUNTIMES.md`](docs/RUNTIMES.md)。

## 本地构建与运行

### 要求

- macOS 26+
- Apple Silicon arm64
- Xcode 26+，包含 Swift 6.2
- Rust 1.88.0（仓库由 `rust-toolchain.toml` 固定）
- 首次构建 Ghostty：Zig 0.15.2、Xcode Metal Toolchain、`curl`、Xcode Command
  Line Tools 和网络访问

如尚未安装 Metal Toolchain：

```bash
xcodebuild -downloadComponent MetalToolchain
```

在仓库根目录初始化固定版本的 GhosttyKit，然后构建：

```bash
./scripts/setup-ghostty.sh
./scripts/build-macos-preview.sh
open dist/TodoAgent.app
```

`build-macos-preview.sh` 会在缺少 GhosttyKit 时自动执行初始化；显式先运行 setup
更容易单独定位工具链或网络问题。脚本会校验固定源码、SHA-256 和第三方许可，构建
Swift App、Rust Engine 与 Terminal Runner，并生成：

- `dist/TodoAgent.app`：指向临时目录内日常预览 App 的便捷链接；
- `dist/TodoAgent-0.1.0-arm64.dmg`：仅用于本地测试的 ad-hoc 签名 DMG。

首次打开后，在“设置 → 本机 CLI”中检测并验证已安装的 Runtime；创建任务工作台时，
再由用户明确选择并授权工作目录。

完整依赖、开发流程和验证命令见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。目前没有可供
普通用户直接下载的已签名、公证版本。

## 架构概览

```text
SwiftUI / AppKit
  ├─ 任务、清单、时间线与菜单栏
  ├─ 每任务独立工作台
  │    └─ Ghostty PTY ── Codex / Claude Code / Cursor Agent / Kiro CLI
  └─ Gemini 任务助手
          │
          │ NDJSON · stdin/stdout · IPC v4
          ▼
Rust Engine
  ├─ SQLite schema v5
  ├─ Runtime 探测、launch plan 与 Terminal Session 元数据
  └─ Gemini Interactions API（store=false）
```

TodoAgent 的 App、Engine、Terminal Runner、状态 Hook 与数据迁移边界见
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 本地数据与隐私

| 内容 | 默认路径 |
|---|---|
| SQLite | `~/Library/Application Support/TodoAgent/todoagent.sqlite3` |
| 任务附件 | `~/Library/Application Support/TodoAgent/Attachments` |
| Gemini API Key | `~/Library/Application Support/TodoAgent/credentials.json` |
| Engine 日志 | `~/Library/Logs/TodoAgent/engine-stderr.log` |

TodoAgent 将 Application Support 数据目录设置为 `0700`，SQLite 与凭据文件设置为
`0600`。Gemini Key 不写入 SQLite、环境变量或日志，但当前凭据文件不是 Keychain
加密项；同一 macOS 登录账户下的其他进程和系统备份仍可能读取，建议启用 FileVault。

Codex/Cursor 的可选状态 Hook 会在用户确认后备份并合并用户配置；Claude 使用
run-scoped settings；Kiro 当前只有进程级状态监督。TodoAgent 不通过这些 Hook 读取
终端内容。完整说明见 [`docs/DATA_AND_PRIVACY.md`](docs/DATA_AND_PRIVACY.md) 和
[`SECURITY.md`](SECURITY.md)。

## 文档

- [`TODO.md`](TODO.md)：公开路线、状态和验收标准
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：当前原生架构与持久化模型
- [`docs/RUNTIMES.md`](docs/RUNTIMES.md)：四个本地 Runtime 的集成边界
- [`docs/DATA_AND_PRIVACY.md`](docs/DATA_AND_PRIVACY.md)：数据、凭据、Hook 与隐私
- [`CONTRIBUTING.md`](CONTRIBUTING.md)：环境准备、测试和 Pull Request 约定
- [`SECURITY.md`](SECURITY.md)：漏洞报告与安全边界
- [`CHANGELOG.md`](CHANGELOG.md)：未发布变更与后续发布记录
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)：社区行为准则
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)：第三方组件和许可

## 分支

- `master`：原生 macOS App 与 Rust Engine 的主产品基线。
- `legacy/web`：保留旧 Web + Node.js 实现；原生版本不会读取或导入旧 Web 数据。

## 参与贡献

欢迎通过 Issue 反馈可复现问题、产品建议和文档改进。准备代码改动前，请先阅读
[`CONTRIBUTING.md`](CONTRIBUTING.md) 和 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)；
安全问题请不要公开披露，按 [`SECURITY.md`](SECURITY.md) 报告。

## 许可证状态

仓库当前尚未包含 TodoAgent 第一方代码的项目级 `LICENSE`。在维护者明确并提交许可
之前，不应把本仓库视为已经完成开源许可授予；这也是公开发布前的阻塞项。
`Cargo.toml` 中单个 Rust package 的 metadata 不能替代仓库根许可证。

第三方组件继续受各自许可证约束，详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
