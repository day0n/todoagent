# Contributing to TodoAgent

感谢你帮助改进 TodoAgent。本文适用于 `master` 上的原生 macOS App 与 Rust Engine；
旧 Web + Node.js 实现位于 `legacy/web`，不要把两个产品的依赖、命令或数据模型混用。

参与社区即表示你同意遵守 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。安全问题请按
[`SECURITY.md`](SECURITY.md) 私下报告，不要创建公开 Issue。

> **许可提醒：** 仓库尚未提交 TodoAgent 第一方代码的项目级 `LICENSE`。在维护者
> 明确许可和贡献条款前，请不要假定代码已经获得开源许可；维护者也应在接受外部
> 代码贡献前先完成这项决定。文档勘误和问题报告仍然非常欢迎。

## 提交问题前

- 搜索现有 Issue，避免重复报告。
- 确认问题发生在原生 `master`，而不是 `legacy/web`。
- Runtime 问题先在“设置 → 本机 CLI”重新检测和验证。
- 不要上传 API Key、认证 Token、私人终端内容、完整家庭目录路径或未脱敏日志。

Bug Report 应包含：

- macOS 版本与 Mac 架构；
- TodoAgent commit 或构建来源；
- 相关 CLI 名称和版本；
- 最小复现步骤、预期结果和实际结果；
- 失败发生在检测、启动、交互、状态、结束还是恢复阶段；
- 已脱敏日志和可安全分享的截图。

Feature Request 请说明使用场景、用户价值、权限/隐私边界和可验证的验收条件。长期
记忆、跨 Agent 协作和自动派发 CLI 的已有设计问题见 [`TODO.md`](TODO.md)。

## 开发环境

### 必需工具

- macOS 26+ on Apple Silicon arm64
- Xcode 26+（Swift 6.2）
- Rust 1.88.0；仓库通过 `rust-toolchain.toml` 固定并包含 `rustfmt`、`clippy`
- Zig 0.15.2
- Xcode Metal Toolchain
- `curl`、`lipo`、Xcode Command Line Tools
- 首次获取固定 Ghostty 源码和依赖所需的网络访问

安装 Metal Toolchain：

```bash
xcodebuild -downloadComponent MetalToolchain
```

如果 Zig 不在 PATH，可将 `TODOAGENT_ZIG` 指向 0.15.2 executable。

Node.js 与 pnpm 只用于 `legacy/web`，不是原生 `master` 的运行或测试依赖。

## 初始化依赖

干净检出不提交生成的 `GhosttyKit.xcframework`、Ghostty runtime resources 或 terminfo。
首次运行：

```bash
./scripts/setup-ghostty.sh
```

脚本会：

- 获取 `vendor/ghostty/pins.json` 固定的 Ghostty revision；
- 校验源码 archive、工具版本和 SHA-256；
- 禁用不需要的 themes、Sentry 与 i18n 功能；
- 生成 `apps/macos/Vendor/GhosttyKit.xcframework` 与运行资源；
- 校验并保留完整第三方许可和源码 provenance。

验证已有生成物而不重新构建：

```bash
./scripts/setup-ghostty.sh --check
```

不要提交生成的 XCFramework、Ghostty runtime 目录或本机 build stamp。第三方许可正文、
pin 和 provenance 文件应保持可追溯。

## 构建本地预览

```bash
./scripts/build-macos-preview.sh
open dist/TodoAgent.app
```

脚本会构建 Swift release App、Rust Engine 和 Terminal Runner，验证资源/许可，执行
strip 与 ad-hoc 签名，并生成本地预览 App 与 arm64 DMG。它不是正式发行流程；
Developer ID、公证和干净账户验收仍未完成。当前公开预览包见
[v0.1.0](https://github.com/day0n/todoagent/releases/tag/v0.1.0)。

日常开发直接重新构建并打开 `dist/TodoAgent.app`，无需复制到 `/Applications`。

## 必跑验证

准备提交原生改动前，在仓库根目录运行：

```bash
cargo fmt --manifest-path apps/engine-rs/Cargo.toml --all -- --check
cargo clippy --manifest-path apps/engine-rs/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path apps/engine-rs/Cargo.toml --locked
swift test --disable-sandbox --package-path apps/macos \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
git diff --check
```

在无法写入默认 Swift module cache 的沙箱中使用独立临时目录：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/todoagent-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/todoagent-swift-cache \
swift test --disable-sandbox --package-path apps/macos \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

涉及协议时同步更新并验证
[`protocol/fixtures/contract.ndjson`](protocol/fixtures/contract.ndjson)。涉及发布候选时还应：

- 运行 `./scripts/build-macos-preview.sh`；
- 使用 `TODOAGENT_NATIVE_DATA_DIR` 和 `TODOAGENT_NATIVE_LOG_DIR` 做隔离数据库 smoke；
- 验证 bundle 内 arm64 Engine 的 IPC 握手；
- 验证 App、Runner、Engine 签名与 DMG 挂载；
- 在实际安装且已登录的相关 CLI 上完成 fresh/resume 验收。

不要复制旧测试数量作为当前结果。记录本次实际执行的命令、通过项和未执行项。

## 代码与架构约定

- Engine stdout 只输出 NDJSON IPC；诊断使用 stderr 或应用日志。
- 不在代码、测试 fixture、日志、Issue 或 commit 中保存 Gemini Key 和 CLI 凭据。
- 保持 Swift 6 strict concurrency clean；优先结构化并发、明确取消和 `Sendable` 边界。
- SQLite 是持久状态的事实来源；mutation 需要明确事务、revision 和幂等语义。
- Terminal Runner 直接执行经过验证的 binary/arguments，不通过 shell 拼接命令。
- 不解析或持久化私人终端 scrollback，除非未来设计经过独立的产品和安全评审。
- UI 中“任务状态”“Terminal 运行状态”“Provider Agent 状态”是不同概念，不应混用。
- 用户授权的工作目录可能是 dirty worktree；不得静默 reset、覆盖或清理用户修改。
- 修改 Ghostty 或其他 vendored 组件时同步更新 pin、hash、license、NOTICE 和 provenance。

## 文档约定

不同文档各有唯一职责：

- `README.md`：用户入口与当前能力；
- `TODO.md`：尚未实现的方向和验收项；
- `docs/`：当前架构、Runtime 和数据事实；
- `CHANGELOG.md`：已经发生、尚未发布或随版本发布的变化；
- 子项目 README：模块细节，不重复整份产品文档。

新功能必须明确区分 `Shipped`、`In progress`、`Planned` 和 `Research`，不要把实现中的
工作写成已发布能力。更新命令、schema 或协议时同步检查所有入口文档。

## Pull Request

1. 从最新 `master` 开始，在你自己的 fork 中使用描述用途的分支。
2. 一个 PR 只解决一个清晰问题；避免夹带格式化或不相关重构。
3. 保留现有用户改动和数据迁移路径，不使用破坏性 Git 操作清理工作区。
4. 添加或更新覆盖成功、失败、取消、恢复和幂等边界的测试。
5. 更新对应文档与 `CHANGELOG.md` 的 `Unreleased` 部分。
6. 填写 PR 模板中的验证结果、安全/隐私影响和未验证项。

PR 标题建议使用简明的命令式描述，例如 `fix: preserve terminal session on window close`。
维护者可能要求拆分改动或补充实际 CLI 验收；上游 Provider 的模拟 fixture 不能完全
替代真实版本测试。
