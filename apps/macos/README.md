# TodoAgent macOS App

`apps/macos` 是 `master` 分支的主界面工程，也是 TodoAgent 当前正式开发入口。
它面向 macOS 26+、Apple Silicon，使用 Swift 6.2、SwiftUI 和少量 AppKit，与
`apps/engine-rs` 中随 App 打包的 Rust sidecar 配合运行。旧 Web/Node.js 产品基线
保存在 `legacy/web` 分支。

项目级介绍、环境初始化和安全边界分别见 [`../../README.md`](../../README.md)、
[`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) 与
[`../../SECURITY.md`](../../SECURITY.md)。本文只记录 macOS 子工程职责。

## 运行结构

- 普通启动使用一个共享 `EngineRepository`。任务、四个本地 CLI Runtime 和
  TodoAgent Gemini 助手都通过 IPC v4 访问同一份原生 SQLite 数据。
- `EngineClient` 是 sidecar 进程及其 stdin/stdout/stderr 的唯一所有者，负责握手、
  请求超时、事件流、重连和异步退出。
- `AppState` 管理任务与导航状态；`AssistantViewState` 独立管理助手会话、历史、
  流式草稿和工具状态，避免聊天事件触发整页重算。
- `DemoRepository` 只用于 SwiftUI Preview 和确定性测试，不会替代普通启动中的
  `EngineRepository`。
- `MenuBarExtra` 提供“TodoAgent 今天”入口，展示今天执行的全部任务，未完成项
  排在已完成项之前。
- 主窗口任务卡提供原生右键菜单，统一调用同一任务 Store：支持状态、日期、移动清单、
  根据任务创建清单和安全删除；执行日期快捷操作只保留加入或移出“今天”，菜单
  跟踪期间任务卡保持选中阴影。
- 总任务、日期投影和每个清单共用同一状态分组：未完成任务不显示重复状态标签，
  已完成任务移到条件显示的“已完成”分组；只有未完成任务的截止日已过时才显示红色
  逾期提示，执行日期不承担逾期语义。
- 各任务视图都将快速添加栏固定在底部；任务较多时只滚动中间任务区，输入位置不会
  随任务数量跳动。
- 打开任务后，主窗口使用左侧紧凑任务 rail、右侧可缩放 Ghostty PTY/TUI 的工作台。
  收起或切换只 detach 终端 surface，不结束 Agent；显式“结束 Session”、删除任务或
  退出 App 才终止对应进程组。

本地 CLI 支持 Codex、Claude Code、Cursor Agent、Kiro CLI。安装与登录状态由用户
在“本机 CLI”设置中主动检测和验证，单个 Runtime 不可用不会阻塞其他功能。
创建任务 Session 后直接在真实 PTY 中运行 Agent 自己的 TUI；TodoAgent 不解析四家
消息格式，也不自动发送任务标题、备注或附件。App 重启后通过各 CLI 的精确 resume
参数恢复 Provider 对话语义，不保存旧终端滚屏。

## 今天

当前 App 的导航、菜单和数据行为如下：

- “今天”以本地 `currentDay` 动态计算，只投影 `executionDate` 等于当天的任务；任务
  总库存与该投影独立。
- 从“今天”打开任务时，左侧 rail 保留当天任务；从总任务或清单打开时，左侧使用
  对应来源的紧凑任务列表，右侧始终是所选任务的终端。
- 左箭头是唯一的终端收起 affordance。它只 detach surface，保留 Controller、Agent、
  PTY 和同一 App 进程内的 scrollback；右侧不再显示重复的 `Esc` 入口。
- 右键执行日期快捷菜单收敛为“加入今天 / 移出今天”。操作只设置或清除
  `executionDate`，不复制或删除任务，也不终止 TerminalSession/Run。
- `dueDate` 保持独立；旧数据中的未来 `executionDate` 原样保留且不丢失，但不再投影为
  未来时间线列。
- Gemini 助手 mutation 在进入 Store 前只接受本地当天或清空 `executionDate`；
  `list_state` 仍可查询旧数据中的任意执行日。

## TodoAgent 助手

助手使用 Gemini Interactions API，并提供多会话、流式回复、停止本轮、历史恢复和
任务工具状态。工具调用按对应 Turn 穿插在消息时间线中，运行中只显示静态状态，
不会使用持续旋转动画；右侧对话栏顶部只保留会话选择、开始新对话和隐藏对话，
会话记录在栏内展开为与产品配色一致的下拉卡片，不使用覆盖顶部的系统菜单。它只
管理 TodoAgent 内的任务，不执行 shell，也不会派发本地 CLI。

主窗口默认以中等尺寸居中出现。TodoAgent 对话不再使用会覆盖或挤压根视图的原生
Inspector，而是始终以约三分之一的比例停靠在任务板右侧；窄窗/左右分屏时仍保留
任务区、左侧日历与导航，也不会出现 Inspector 的右上 resize affordance。

附件当前只支持 UTF-8 `.txt` 和 `.md`：一次最多 4 个，单文件最大 128 KB，合计
最大 256 KB。图片、音频和其他多模态输入不在第一版范围内。

## 开发与测试

从仓库根目录构建可直接运行的 App 与 DMG：

```bash
./scripts/build-macos-preview.sh
open dist/TodoAgent.app
```

日常调试直接重新构建并打开 `dist/TodoAgent.app`，不需要每次安装到
`/Applications`。

单独运行 Swift 6.2 严格并发测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox --package-path apps/macos \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

完整构建需要 Xcode 26+、macOS 26+、Apple Silicon 和 Rust 1.88。
干净检出还需先按 [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) 准备 Zig 0.15.2、
Metal Toolchain 与固定版本 GhosttyKit。

## 数据与凭据

原生数据默认位于：

- `~/Library/Application Support/TodoAgent/todoagent.sqlite3`
- `~/Library/Application Support/TodoAgent/Attachments`
- `~/Library/Logs/TodoAgent/engine-stderr.log`

Gemini Key 保存在
`~/Library/Application Support/TodoAgent/credentials.json`。TodoAgent 将目录权限设为
`0700`、凭据文件权限设为 `0600`，拒绝符号链接并使用原子替换；Key 不写入 SQLite、
UserDefaults、环境变量或日志。

这个文件依靠 macOS 账户与 POSIX 权限隔离，不是 Keychain 加密项。同一登录账户下
的其他进程仍可能读取，建议启用 FileVault；系统备份也可能包含该文件。

## 本地预览分发

`scripts/build-macos-preview.sh` 使用 `/Applications/Xcode.app`，不会修改全局
`xcode-select`。脚本构建并 strip arm64 sidecar，将其嵌入 App Resources，然后对
sidecar 和 App 进行 ad-hoc 签名。

产物为 `dist/TodoAgent.app` 和 `dist/TodoAgent-0.1.0-arm64.dmg`。它们不含
Developer ID 签名或苹果公证，只用于本机开发与预览；公开分发会触发 Gatekeeper
限制，需要另行完成 Developer ID 签名、notarization 和发布验收。

当前公开预览包见
[GitHub Releases 的 v0.1.0](https://github.com/day0n/todoagent/releases/tag/v0.1.0)。
