# Changelog

TodoAgent 的重要变化将记录在这里。项目目前处于 developer preview，尚未创建正式
release tag；在首个版本发布前，变更统一记录在 `Unreleased`。

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本发布后将使用
[Semantic Versioning](https://semver.org/) 记录兼容性，但预览阶段的 schema、IPC 和
CLI 集成仍可能发生破坏性变化。

## [Unreleased]

### Added

- 主窗口内的任务工作台使用左侧任务 rail 和右侧 retained Ghostty PTY，运行 Codex、
  Claude Code、Cursor Agent 或 Kiro CLI 的真实 TUI。
- Rust Terminal Runner、Terminal Session/Run 元数据、Provider Session ID 绑定和
  fresh/resume 生命周期。
- Codex/Cursor 可选用户级状态 Hook、Claude run-scoped Hook，以及安全备份/合并和
  卸载流程。
- 固定 Ghostty 源码、构建脚本、第三方许可、hash 与 provenance 校验。
- 公开 TODO、架构、Runtime、数据隐私、贡献、安全和社区行为文档。
- “今天”动态视图、菜单栏入口和直接加入/移出快捷操作。

### Changed

- App ↔ Engine 协议升级到 IPC v4。
- SQLite 先升级到 schema v5，用 `terminal_session` / `terminal_run` 取代旧结构化 CLI
  Chat/Turn/Event 模型；随后升级到 schema v6，加入受约束的自动恢复元数据。
- Coding Agent 交互从解析供应商消息格式改为用户直接操作原生 TUI；终端 scrollback
  不再持久化。
- 任务标题与备注采用 800ms trailing autosave，并在失焦和生命周期边界 flush。
- 旧多日任务时间线收敛为“今天”和任务总库存；打开任务后在同一主窗口使用左侧
  来源任务 rail 与右侧 retained terminal，左箭头只收起终端 surface。
- `dueDate` 独立承担逾期语义；旧数据库中的未来 `executionDate` 无损保留，但新 UI 和
  Gemini 助手不再创建未来执行日。助手 mutation 在 Store 前只接受本地当天或清空。
- 根文档按当前能力、未来路线和社区治理重新拆分。

### Migration

- v4 数据库在迁移前创建 mode `0600` 备份。
- 任务、清单、附件、Runtime、设置和 Gemini 助手历史保留。
- 旧结构化 Coding Agent Session/Turn/Message/Event 历史不迁移到 v5。
- v5 → v6 再次备份数据库，并加入 `last_exit_reason` / `auto_resume`；只有可精确确认的
  中断 Run 会回填自动恢复标记。
- 低于 v4、未知或高于 v6 的 schema 原样保留并拒绝打开，不会静默清空。

### Security

- Terminal Runner 不经 shell 启动经过验证的 CLI，并使用独立进程组与 Run-scoped
  authenticated status events。
- Provider Hook 合并增加 owner、symlink、hard-link、file type、permission、size
  和未知 schema 检查。
- 发布包验证 Ghostty 及其依赖的许可证正文和固定来源。

## 历史开发快照

2026-08-10 以前的 IPC v3/schema v4 结构化 CLI 实现没有正式发布 tag。相关 Git 历史
仍可用于考察设计演进，但旧测试数量、性能采样和 Runtime smoke 不能代表当前版本。
