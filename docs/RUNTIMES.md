# Local Runtime Integrations

TodoAgent 支持用户已经安装并登录的 Codex、Claude Code、Cursor Agent 和 Kiro CLI。
四者都运行自己的原生 TUI。每个任务固定对应一个本机终端；已登记的受管 Run 仍通过
Terminal Runner 持久化 Runtime、工作目录和 Provider Session ID。TodoAgent 不将终端
输出转换成统一聊天协议。

## 集成矩阵

| Runtime | Fresh launch | Resume | Provider ID | 状态来源 |
|---|---|---|---|---|
| Codex | `codex -C <workspace>` | `codex resume -C <workspace> <id>` | Hook/运行期唯一捕获；否则退出后确认候选 | 可选用户级 Hook + 进程状态 |
| Claude Code | 每次 fresh 生成新 UUID，走 `--session-id`，可附加 `--name` | `--resume <id>` | 该次 fresh 启动时绑定 | run-scoped `--settings` Hook + 进程状态 |
| Cursor Agent | 先创建 chat，再以 `--workspace ... --resume <id>` 启动 | 相同 resume 入口 | 创建 chat 时绑定 | 可选用户级 Hook + 进程状态 |
| Kiro CLI | `chat --tui` | `chat --tui --resume-id <id>` | 运行期唯一元数据捕获；否则退出后确认候选 | 当前仅进程状态 |

表中命令用于解释集成语义，并不是建议用户手工复制的稳定公共 API。TodoAgent 启动前
会探测当前 CLI 的实际 `--help` grammar；上游 CLI 的参数和存储格式可能变化。

## 检测与验证

“设置 → 本机 CLI”中的检测与验证会：

1. 在可信 PATH 与用户常见安装位置查找可执行文件；
2. 规范化并记录实际 executable path；
3. 读取版本并探测 fresh/resume 所需的 help grammar；
4. 进行不修改用户项目的登录/可用性检查；
5. 返回 `ready`、`missing`、`auth_required` 或明确错误。

单个 Runtime 不可用不会阻止任务管理、该任务的普通终端、Gemini 助手、其他 Runtime
或 App 构建。只有真正启动对应 Agent 时才要求 Runtime 已安装并通过验证。
CLI 被升级、替换或移动后必须重新验证，TodoAgent 不会静默执行一个已变化的 binary。

## Session 规则

- 首次点击任务会自动创建它唯一的 `TerminalSession` 和普通 shell；同一任务只会有
  一个终端和最多一个活动受管 Run。
- Fresh Run 在启动 CLI 前持久化 Run identity 与 launch mode。Claude 会预分配 UUID
  并使用 `--session-id <id>`；恢复严格使用 `--resume <同一 id>`。Codex/Kiro 的
  Provider ID 只能在运行中验证捕获或退出后由用户确认候选。
- 收起终端或切换任务只会 detach surface，PTY 和 Agent 继续运行。Cmd+Q 会结束进程组，
  并把正在运行、有稳定 Provider ID 的活动受管 Run 标为 `app_shutdown` /
  `auto_resume=1`。
- 新 App 进程再次打开同一任务时会自动恢复 `auto_resume` Session。普通 process exit
  或用户显式结束不会自动启动；界面直接保留普通 shell，不显示恢复或新建 Provider
  Session 页面。
- TodoAgent 恢复的是 Provider 对话语义，不保存旧 PTY、scrollback 或正在运行的进程。
  Claude transcript 缺失或不可恢复时不会降级成 fresh 对话；可用的 shell 仍会显示。
- 直接在普通 shell 中手打 CLI 不会经过 Runner，也就没有可跨 App 重启恢复的
  Run/Provider 绑定；但在 App 仍运行时，收起和任务切换会保留原 PTY 状态。
- TodoAgent 不把任务标题、备注和附件作为 Prompt。Claude fresh Run 会把任务标题作为
  `--name` Session 名称传给 Claude CLI；备注与附件不会自动发送。

为精确绑定和恢复，Engine 会有界读取 Provider 本地会话元数据，以及 Claude transcript
的记录类型；只判断 ID、工作目录、时间和是否存在可恢复对话，不提取、保存或发送正文。

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

受管 Run 会生成临时、权限受控的 settings 文件，并通过 `--settings` 仅注入当前
Session 所需的 Hook。

在任务终端里由用户自己启动的 `claude` 不经 TodoAgent 启动，命令行参数无法注入，
因此还需要用户级 Hook：在用户明确确认后，TodoAgent 会像 Codex/Cursor 那样备份并
结构化合并 `settings.json` 的 `hooks` 段，只添加自己管理的处理器；卸载时仅移除
TodoAgent 条目，其他 Hook 与不相关的设置项都会保留。

settings.json 与受管 Run 都使用 Engine 启动时继承的 `CLAUDE_CONFIG_DIR`；未设置或
取值不是绝对路径时使用 `~/.claude`。因此只在交互式 shell 配置中临时改写该变量不会
让 fresh 与下一次恢复扫描落到两个不同目录。

两条路径可能对同一次回复各触发一次 Hook。事件 ID 由 Run、状态和 Hook 载荷派生，
重复事件会被去重，只通知一次。

### Kiro CLI

当前没有启用稳定的 Provider 状态 Hook；TodoAgent 只根据 Runner/进程生命周期判断
启动和退出，并在需要时扫描明确的 Session ID 候选。

## 安全与兼容性

- CLI 使用用户自己已经登录的身份和权限；TodoAgent 不分发、复制或接管它们的凭据。
- Agent 可以在用户授权的工作目录中按自身能力读取、修改文件和运行命令。请先检查
  该目录及各 CLI 自己的 approval/sandbox 设置。
- App 只向 login shell 注入严格引用的 Runner 与 descriptor 路径；Agent executable 和
  参数不进入 shell，由 Terminal Runner 从验证后的 descriptor 直接执行。
- Provider Session ID 候选必须与工作目录和运行时间窗口匹配；歧义时要求人工选择。
- Hook 配置写入使用所有者、文件类型、符号链接、硬链接、权限和大小检查，并在变更前
  创建备份。

若上游版本变更导致启动或恢复失败，请提交 Bug Report，并附 Runtime 名称、CLI 版本、
macOS 版本、失败阶段和已脱敏日志；不要附带 API Key、认证 Token 或完整私人终端内容。
