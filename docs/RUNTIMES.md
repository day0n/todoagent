# Local Runtime Integrations

TodoAgent 支持用户已经安装并登录的 Codex、Claude Code、Cursor Agent 和 Kiro CLI。
四者都运行自己的原生 TUI；TodoAgent 管理工作目录、启动参数、Provider Session ID、
进程生命周期和可用状态，不将终端输出转换成统一聊天协议。

## 集成矩阵

| Runtime | Fresh launch | Resume | Provider ID | 状态来源 |
|---|---|---|---|---|
| Codex | `codex -C <workspace>` | `codex resume -C <workspace> <id>` | 完成后精确扫描候选并绑定 | 可选用户级 Hook + 进程状态 |
| Claude Code | 预分配 `--session-id`，可附加 `--name` | `--resume <id>` | 首次启动前生成并绑定 | run-scoped `--settings` Hook + 进程状态 |
| Cursor Agent | 先创建 chat，再以 `--workspace ... --resume <id>` 启动 | 相同 resume 入口 | 创建 chat 时绑定 | 可选用户级 Hook + 进程状态 |
| Kiro CLI | `chat --tui` | `chat --tui --resume-id <id>` | 完成后精确扫描候选并绑定 | 当前仅进程状态 |

表中命令用于解释集成语义，并不是建议用户手工复制的稳定公共 API。TodoAgent 启动前
会探测当前 CLI 的实际 `--help` grammar；上游 CLI 的参数和存储格式可能变化。

## 检测与验证

“设置 → 本机 CLI”中的检测与验证会：

1. 在可信 PATH 与用户常见安装位置查找可执行文件；
2. 规范化并记录实际 executable path；
3. 读取版本并探测 fresh/resume 所需的 help grammar；
4. 进行不修改用户项目的登录/可用性检查；
5. 返回 `ready`、`missing`、`auth_required` 或明确错误。

单个 Runtime 不可用不会阻止任务管理、Gemini 助手、其他 Runtime 或 App 构建。
CLI 被升级、替换或移动后必须重新验证，TodoAgent 不会静默执行一个已变化的 binary。

## Session 规则

- 创建 Session 时由用户选择 Runtime 和工作目录。
- 工作目录必须是绝对路径，并由用户通过系统界面授权；它不要求是 Git 仓库，也不因
  dirty worktree 阻止启动。
- 一个任务永久绑定一个 Runtime；当前不能在同一任务中切换 Agent。
- TodoAgent 不自动发送任务标题、备注和附件。终端打开后，由用户在 TUI 内决定输入。
- 关闭工作台窗口不终止 Agent；显式结束 Session、删除任务或退出 App 才停止它。
- App 重启后使用已绑定的 Provider Session ID 恢复对话语义，但不恢复旧 scrollback。

## 状态 Hook

Hook 只传递活动、阻塞、空闲或完成等生命周期状态，不读取 Prompt、模型输出或终端
scrollback。

### Codex

在用户明确确认后，TodoAgent 会备份并结构化合并 `~/.codex/hooks.json`。当前 Codex
Hook 配置仍需要用户结合所装版本确认信任边界；可随时从设置中卸载 TodoAgent 管理的
条目，其他 Hook 会被保留。

### Cursor Agent

在用户明确确认后，TodoAgent 会备份并结构化合并 `~/.cursor/hooks.json`，只添加自己
管理的处理器。卸载时仅移除 TodoAgent 条目。

### Claude Code

TodoAgent 不修改 Claude 的全局用户设置。每次 Run 生成临时、权限受控的 settings
文件，并通过 `--settings` 仅注入当前 Session 所需的 Hook。

### Kiro CLI

当前没有启用稳定的 Provider 状态 Hook；TodoAgent 只根据 Runner/进程生命周期判断
启动和退出，并在需要时扫描明确的 Session ID 候选。

## 安全与兼容性

- CLI 使用用户自己已经登录的身份和权限；TodoAgent 不分发、复制或接管它们的凭据。
- Agent 可以在用户授权的工作目录中按自身能力读取、修改文件和运行命令。请先检查
  该目录及各 CLI 自己的 approval/sandbox 设置。
- TodoAgent 不通过 shell 插值拼接启动参数；Terminal Runner 直接执行已验证 binary。
- Provider Session ID 候选必须与工作目录和运行时间窗口匹配；歧义时要求人工选择。
- Hook 配置写入使用所有者、文件类型、符号链接、硬链接、权限和大小检查，并在变更前
  创建备份。

若上游版本变更导致启动或恢复失败，请提交 Bug Report，并附 Runtime 名称、CLI 版本、
macOS 版本、失败阶段和已脱敏日志；不要附带 API Key、认证 Token 或完整私人终端内容。
