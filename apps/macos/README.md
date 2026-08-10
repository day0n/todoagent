# TodoAgent macOS App

`apps/macos` 是 `master` 分支的主界面工程，也是 TodoAgent 当前正式开发入口。
它面向 macOS 26+、Apple Silicon，使用 Swift 6.2、SwiftUI 和少量 AppKit，与
`apps/engine-rs` 中随 App 打包的 Rust sidecar 配合运行。旧 Web/Node.js 产品基线
保存在 `legacy/web` 分支。

## 运行结构

- 普通启动使用一个共享 `EngineRepository`。任务、四个本地 CLI Runtime 和
  TodoAgent Gemini 助手都通过 IPC v3 访问同一份原生 SQLite 数据。
- `EngineClient` 是 sidecar 进程及其 stdin/stdout/stderr 的唯一所有者，负责握手、
  请求超时、事件流、重连和异步退出。
- `AppState` 管理任务与导航状态；`AssistantViewState` 独立管理助手会话、历史、
  流式草稿和工具状态，避免聊天事件触发整页重算。
- `DemoRepository` 只用于 SwiftUI Preview 和确定性测试，不会替代普通启动中的
  `EngineRepository`。
- `MenuBarExtra` 提供“TodoAgent 今日任务”入口，展示今天执行的全部任务，未完成项
  排在已完成项之前。
- 主窗口任务卡提供原生右键菜单，统一调用同一任务 Store：支持状态、执行/截止
  日期、移动清单、根据任务创建清单和安全删除；菜单跟踪期间任务卡保持选中阴影。
- 时间线、总任务和每个清单共用同一状态分组：未完成任务不显示重复状态标签，
  已完成任务移到条件显示的“已完成”分组；未完成任务的截止日或执行日已过时，
  以红色显示对应日期和星期。
- 时间线每列与任务/清单视图都将快速添加栏固定在底部；时间线任务较多时只滚动
  中间任务区，输入位置不会随任务数量跳动。
- 任务详情与本地 Session Sheet 会读取当前主窗口尺寸：标准窗口使用有上限的紧凑
  双栏，窄窗切换上下布局，表单内容可滚动且启动按钮保持可用。

本地 CLI 支持 Codex、Claude Code、Cursor Agent、Kiro CLI。安装与登录状态由用户
在“本机 CLI”设置中主动检测和验证，单个 Runtime 不可用不会阻塞其他功能。
创建任务 Session 只进入空的 `idle` 会话；用户主动发送第一条消息后才启动 CLI。
聊天中的 `tool_result` 默认折叠，点击摘要卡片后展开完整内容。

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
