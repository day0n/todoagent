# Security Policy

TodoAgent 可以启动拥有用户权限的 Coding Agent、访问用户授权的工作目录并保存
Gemini 凭据，因此安全问题应在公开前得到私下处理。

## 报告漏洞

请优先使用 GitHub 的私有安全报告入口：

<https://github.com/day0n/todoagent/security/advisories/new>

如果该入口不可用，请先通过仓库维护者的 GitHub 主页请求一个私下联系渠道，不要在
公开 Issue、Discussion、PR、commit 或日志附件中披露漏洞细节。

报告请尽量包含：

- 受影响 commit、组件和 macOS 版本；
- 相关 Runtime/CLI 及其版本；
- 可重复的最小步骤或 proof of concept；
- 实际影响、攻击前提和可观察结果；
- 已知缓解措施；
- 是否包含第三方组件问题。

请勿附带真实 API Key、认证 Token、完整私人终端内容或无关用户数据。维护者确认收到
后会评估影响、协调修复与披露时间；请在双方同意前保持私密。

## 当前支持范围

TodoAgent 尚处于 developer preview。已有 [`v0.1.0`](https://github.com/day0n/todoagent/releases/tag/v0.1.0)
预览 tag，但安全修复只面向最新 `master`；预览 DMG 不构成长期支持版本。
`legacy/web` 仅用于历史兼容参考，不承诺持续安全维护。

| 版本/分支 | 安全修复 |
|---|---|
| 最新 `master` | 支持 |
| `v0.1.0` 预览 DMG | 跟随最新 `master`，不单独维护 |
| `legacy/web` | 不主动维护 |
| 未知 fork、旧 commit、第三方重打包 | 不支持 |

## 信任边界

### 本地 Coding Agent

Codex、Claude Code、Cursor Agent 和 Kiro CLI 使用用户自己的安装、身份和权限。
TodoAgent 不替代它们的 sandbox、approval、网络策略或供应商安全模型。用户选择工作
目录后，CLI 可能按自身能力读取/修改文件和运行命令。

TodoAgent 负责验证 executable、构造参数、启动独立进程组、恢复 Provider Session
和结束进程；不解析或持久化终端 scrollback。binary 或上游 CLI 被替换、升级或入侵
属于重要安全边界，应重新执行 Runtime 验证。

### Engine IPC

Engine stdout 专用于本地 stdin/stdout NDJSON IPC，不监听 TCP 端口。Terminal status
事件需要 Run-scoped token 认证；用户输入、Provider 输出和诊断不得混入 IPC stdout。

### Provider 状态 Hook

- Codex/Cursor 的用户级 Hook 只在用户确认后合并，写入前备份现有配置；卸载只移除
  TodoAgent 管理的 handler。
- Claude Code 的受管 Run 使用 run-scoped 临时 settings；用户在任务终端自行启动的
  `claude` 在用户确认后合并用户级 `settings.json` 的 hooks 段。
- Kiro CLI 当前不安装 Hook。
- Hook 仅报告有限生命周期状态，不读取终端内容；TodoAgent Run 之外缺少认证环境时
  Wrapper 直接退出。

Hook 配置处理应拒绝符号链接、错误 owner、异常文件类型、多个硬链接、过宽权限和
超大/未知 JSON 结构。

### Gemini Key 与远程模型

Gemini Key 保存在 mode `0600` 的 Application Support 文件中，通过 IPC 注入 Engine
内存，以敏感 Header 发送。它不进入 SQLite、环境变量或日志。当前文件不是 Keychain
加密项；同一账户进程和系统备份可能读取，建议启用 FileVault。

Gemini 助手会向远程 API 发送当前对话及用户显式附加的 `.txt` / `.md` 内容。助手没有
shell、任意文件读取或 CLI 派发权限。`store=false` 不替代 Provider 自身条款和日志
政策。

### 数据与迁移

Application Support 目录使用 `0700`，数据库和敏感文件使用 `0600`。文件访问和原子
替换应保持 no-follow、owner、file-type、hard-link 和权限检查。

v4 → v5 会先生成受限权限备份；无法识别的旧/未来 schema 应原样保留并拒绝打开，
不能为了恢复启动而静默擦除用户数据。

## 不属于安全漏洞的情况

以下通常属于产品限制或上游问题，但仍欢迎普通 Bug Report：

- ad-hoc 签名预览 DMG 触发 Gatekeeper；
- 未安装或未登录的 Runtime 返回 `missing` / `auth_required`；
- 上游 CLI 改变未承诺的 flags、Hook schema 或 Session store；
- 用户明确授权 Agent 修改工作目录后产生的预期文件变更；
- 删除 App 后 Application Support 数据仍然保留。

如果某项限制能被绕过授权、导致跨目录访问、凭据泄露、命令注入、配置破坏、权限
提升或无法恢复的数据损坏，则应按漏洞私下报告。

## 第三方组件

GhosttyKit、shell integration、Rust crates 和其他第三方组件保留各自安全与许可责任。
来源和版本信息见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 与
`vendor/ghostty/`。发现上游漏洞时，请同时说明受影响 revision 和 TodoAgent 是否实际
启用了相关代码路径。
