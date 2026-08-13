# TodoAgent 文档导航

`PLAN.md` 曾同时记录产品规范、架构、测试快照和后续路线。随着原生实现从结构化
CLI 适配器迁移为 Ghostty PTY/TUI，这种单文件结构产生了重复和事实漂移。

从 2026-08-13 起，请使用以下文档作为对应内容的事实来源：

| 内容 | 文档 |
|---|---|
| 项目定位、当前能力、快速开始 | [`README.md`](README.md) |
| 公开 TODO 与 Roadmap | [`TODO.md`](TODO.md) |
| App、Engine、IPC、SQLite 与迁移 | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Codex、Claude Code、Cursor Agent、Kiro CLI 集成 | [`docs/RUNTIMES.md`](docs/RUNTIMES.md) |
| 本地数据、凭据、状态 Hook 与隐私 | [`docs/DATA_AND_PRIVACY.md`](docs/DATA_AND_PRIVACY.md) |
| 开发环境、构建与测试 | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| 安全报告与支持边界 | [`SECURITY.md`](SECURITY.md) |
| 未发布变更与发布记录 | [`CHANGELOG.md`](CHANGELOG.md) |

## 当前产品基线

- `master` 是原生 macOS 产品主线；`legacy/web` 保留旧 Web + Node.js 实现。
- 当前工作树使用 SwiftUI/AppKit、Ghostty PTY、Rust Engine、IPC v4 和 SQLite
  schema v5。
- 四家 Coding Agent CLI 通过真实 TUI 由用户直接操作；TodoAgent 负责启动、恢复、
  状态与进程生命周期，不解析终端对话。
- 长期语义记忆、跨 Agent 接力和 TodoAgent 自动派发 CLI 尚未实现，详见
  [`TODO.md`](TODO.md)。

## 历史说明

旧 PLAN 中的 IPC v3、SQLite v4、`TaskSession → SessionTurn → SessionMessage`、
每条消息启动一次 CLI、结构化 JSON/ACP 输出和 CLI 聊天 Sheet 描述属于上一代实现，
不再代表 `master` 当前架构。

2026-08-10 记录的测试数量、内存数据和三家 Runtime smoke 也是历史快照，不应作为
当前未提交 PTY/TUI 改造的验收结果。发布或提交前需按
[`CONTRIBUTING.md`](CONTRIBUTING.md) 重新执行门禁并单独记录结果。
