# Changelog

TodoAgent 的重要变化将记录在这里。项目目前处于 developer preview，尚未创建正式
release tag；在首个版本发布前，变更统一记录在 `Unreleased`。

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本发布后将使用
[Semantic Versioning](https://semver.org/) 记录兼容性，但预览阶段的 schema、IPC 和
CLI 集成仍可能发生破坏性变化。

## [Unreleased]

### Added

- 每个任务一个独立原生工作台，嵌入 Ghostty PTY 并运行 Codex、Claude Code、
  Cursor Agent 或 Kiro CLI 的真实 TUI。
- Rust Terminal Runner、Terminal Session/Run 元数据、Provider Session ID 绑定和
  fresh/resume 生命周期。
- Codex/Cursor 可选用户级状态 Hook、Claude run-scoped Hook，以及安全备份/合并和
  卸载流程。
- 固定 Ghostty 源码、构建脚本、第三方许可、hash 与 provenance 校验。
- 公开 TODO、架构、Runtime、数据隐私、贡献、安全和社区行为文档。

### Changed

- App ↔ Engine 协议升级到 IPC v4。
- SQLite 升级到 schema v5；用 `terminal_session` / `terminal_run` 取代旧结构化 CLI
  Chat/Turn/Event 模型。
- Coding Agent 交互从解析供应商消息格式改为用户直接操作原生 TUI；终端 scrollback
  不再持久化。
- 任务标题与备注采用 800ms trailing autosave，并在失焦和生命周期边界 flush。
- 根文档按当前能力、未来路线和社区治理重新拆分。

### Migration

- v4 数据库在迁移前创建 mode `0600` 备份。
- 任务、清单、附件、Runtime、设置和 Gemini 助手历史保留。
- 旧结构化 Coding Agent Session/Turn/Message/Event 历史不迁移到 v5。
- 更旧、未知或未来 schema 原样保留并拒绝打开，不会静默清空。

### Security

- Terminal Runner 不经 shell 启动经过验证的 CLI，并使用独立进程组与 Run-scoped
  authenticated status events。
- Provider Hook 合并增加 owner、symlink、hard-link、file type、permission、size
  和未知 schema 检查。
- 发布包验证 Ghostty 及其依赖的许可证正文和固定来源。

## 历史开发快照

2026-08-10 以前的 IPC v3/schema v4 结构化 CLI 实现没有正式发布 tag。相关 Git 历史
仍可用于考察设计演进，但旧测试数量、性能采样和 Runtime smoke 不能代表当前版本。
