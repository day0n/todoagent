# Data and Privacy

TodoAgent 是本地优先应用，但“本地”不等于“没有安全边界”。本文说明当前保存什么、
不保存什么，以及什么时候会访问网络或用户配置。

## 默认存储位置

| 数据 | 默认路径 | 内容 |
|---|---|---|
| SQLite | `~/Library/Application Support/TodoAgent/todoagent.sqlite3` | 任务、清单、Terminal 元数据、Gemini 会话和设置 |
| 任务附件 | `~/Library/Application Support/TodoAgent/Attachments` | 用户选择后由 Engine 托管的副本 |
| Gemini Key | `~/Library/Application Support/TodoAgent/credentials.json` | 当前 Gemini API Key |
| Engine 日志 | `~/Library/Logs/TodoAgent/engine-stderr.log` | 诊断信息，不应包含密钥 |
| 状态 Hook 管理文件 | `~/Library/Application Support/TodoAgent/StatusHooks` | Wrapper、备份和临时配置 |

Application Support 目录设置为 `0700`；SQLite、凭据、备份和临时设置使用 `0600`。
敏感文件写入使用同目录临时文件与原子替换，并拒绝符号链接、异常文件类型、错误
owner、多个硬链接或过宽权限。

## 保存的内容

- 任务、清单、日期、状态和任务备注；
- 任务附件的托管本地副本及其元数据；
- Runtime 路径、版本、验证状态和有限能力信息；
- Terminal Session 的 Runtime、工作目录、Provider Session ID、Run 和生命周期状态；
- Gemini 助手的用户消息、模型结果、工具 receipt、上下文摘要和用户显式附加的文本；
- schema migration 和幂等 mutation receipt。

## 不保存或不自动发送的内容

- Coding Agent PTY 字节和旧终端 scrollback 不写入 SQLite；
- TodoAgent 不解析或复制 CLI TUI 中的 Prompt、回复和工具结果；
- 任务标题、备注与任务附件不会自动发送给 Coding Agent；
- 任务附件不会自动进入 Gemini 助手上下文；
- Gemini API Key 不写入 SQLite、环境变量或日志；
- TodoAgent 不读取 Codex、Claude Code、Cursor Agent 或 Kiro CLI 的认证凭据。

Provider 自身仍可能按各自产品行为在本机或云端保存会话。TodoAgent 恢复 Provider
Session 并不改变对应供应商的隐私政策。

## Gemini 助手与网络

Gemini 助手使用 Gemini Interactions API，需要网络访问。请求设置 `store=false`，
TodoAgent 每轮从本地 SQLite 重建所需上下文。`store=false` 描述 API 请求行为，不代表
网络服务没有自身的运行日志或账户政策；请同时查阅所用 Gemini 服务的适用条款。

助手只能使用六个任务工具，没有 shell、任意文件读取、MCP、skills 或本地 CLI 控制。
用户可以显式给一条助手消息附加 UTF-8 `.txt` / `.md`：每轮最多 4 个、单个最多
128 KiB、总计最多 256 KiB。这些文本会进入该 Gemini 请求并随本机会话保存。

## 任务附件

任务附件是本地备忘，不等同于助手消息附件：

- 用户选择文件后，Engine 复制一个托管副本，不修改原文件；
- 单个任务附件最大 100 MiB；
- 符号链接和不安全文件类型会被拒绝；
- 删除附件只删除托管副本；
- 名称、路径和内容不进入 Gemini Prompt 或 Coding Agent Session。

## Gemini 凭据

当前 Gemini Key 保存在账户私有的普通文件中，不是 Keychain 加密项或独立保险箱。
同一 macOS 登录账户下的其他进程，以及系统备份，仍可能读取该文件。建议：

- 启用 FileVault；
- 保护 macOS 登录账户；
- 不共享 Application Support 或未加密备份；
- 怀疑泄露时从 Provider 控制台撤销 Key，并在设置中移除旧 Key。

迁移到 Keychain 是公开预览前的 TODO。

## 工作目录与 Coding Agent 权限

用户创建 Terminal Session 时明确选择工作目录。TodoAgent 不因为目录不是 Git 仓库或
存在未提交修改而阻止启动。所选 CLI 可以在该目录中按自身权限读取和修改文件、运行
命令或访问网络；TodoAgent 不替代各 CLI 的 sandbox 与 approval 设置。

在重要项目中使用前，建议确认 Git 状态、备份策略和 Agent 自身权限。

## 状态 Hook 对用户配置的影响

- Codex/Cursor：用户同意后，TodoAgent 备份并合并用户级 `hooks.json`；卸载只移除
  TodoAgent 管理的 handler。
- Claude Code：使用单次 Run 的临时 `--settings`，不修改全局配置。
- Kiro CLI：当前不安装状态 Hook。

Hook 仅发送经过认证的生命周期状态，不读取终端输出；Wrapper 在 TodoAgent Run 之外
没有认证 socket 时直接退出。

## 数据迁移与删除

v4 → v5 迁移前会生成 `0600` 备份。迁移保留任务、附件、设置和 Gemini 助手历史，
但会删除旧结构化 Coding Agent 聊天表，因为新实现不再保存终端对话。其他旧 schema
与未来 schema 会被保留并拒绝打开。

删除 App 不会自动删除 Application Support 数据。完整的数据导出、可视化清除和备份
管理仍是未来工作；需要手工删除或迁移数据时，请先退出 TodoAgent 并做好备份。

## 长期记忆不是当前能力

Gemini 单会话历史、上下文摘要和 Provider Session resume 都不等于跨任务长期语义
记忆。TodoAgent 当前不会自动提取个人偏好或项目知识。长期记忆的确认、来源、删除、
隔离、Prompt Injection 与加密要求见 [`../TODO.md`](../TODO.md)。
