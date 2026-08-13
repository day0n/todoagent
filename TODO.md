# TodoAgent TODO & Roadmap

> 本文描述 TodoAgent 当前的产品方向，不构成发布日期承诺。优先级会随产品验证、
> 安全评审以及上游 CLI 的变化而调整。

## 状态说明

| 状态 | 含义 |
|---|---|
| `Research` | 正在明确产品、安全或技术边界，尚未承诺实现方案 |
| `Planned` | 方向已经确定，尚未进入完整实现 |
| `In progress` | 已有实际开发工作，尚未达到验收条件 |
| `Blocked` | 依赖外部条件或尚未完成的决策 |
| `Shipped` | 已实现并通过对应验收 |

## Now — 开发预览稳定化

### [In progress] 四个 Coding Agent CLI 的直接操控

TodoAgent 已经能够在每个任务的嵌入式 PTY 中启动和恢复 Codex、Claude Code、
Cursor Agent 与 Kiro CLI。当前阶段的重点是把这项能力从开发工作区推进到可重复验证
的预览版本，而不是重新实现终端。

- [ ] 在当前兼容版本上完成四家 CLI 的安装、登录、新会话、交互、结束和至少三轮
  恢复验收。
- [ ] 固化基于真实 `--help` 能力探测的兼容性矩阵，并记录上游版本回归。
- [ ] 验证 Provider Session ID 捕获、工作目录重绑定和歧义候选的人工选择流程。
- [ ] 覆盖 App/Engine/Runner 崩溃、强制退出、休眠唤醒和残留进程清理。
- [ ] 完成 Codex/Cursor Hook 安装与卸载、Claude run-scoped settings、配置备份和
  用户可见说明的验收。
- [ ] 验证不解析终端输出、不持久化 scrollback、不自动注入任务内容的隐私边界。
- [ ] 在干净 macOS 账户完成首次运行和四家 Runtime 的恢复指导。

### [In progress] 面向公开预览的发布工程

- [ ] 为 TodoAgent 第一方代码选择并提交项目级 `LICENSE`。
- [ ] 建立可重复运行的原生 CI，覆盖 Rust、Swift strict concurrency、IPC fixture
  和 Markdown 链接。
- [ ] 完成 Developer ID Application 签名、Apple notarization 和 Gatekeeper 验收。
- [ ] 设计从当前凭据文件迁移到稳定 Keychain identity 的方案。
- [ ] 验证全新安装、覆盖升级、版本回滚和退出无残留进程。
- [ ] 评估 Universal 构建、自动更新和隐私友好的崩溃诊断。

### [Planned] 核心任务体验

- [ ] 增强任务排序、搜索和批量操作。
- [ ] 系统完成键盘导航、VoiceOver、对比度和 Reduce Motion 验收。
- [ ] 根据真实使用数据决定是否支持更多附件类型；实现前先定义大小、持久化和
  隐私边界。
- [ ] 持续压测长会话、多个并行终端和 Provider 事件洪峰。

## Next — Agent 平台能力

### [Planned] TodoAgent 自动派发 Coding Agent

让 TodoAgent 在用户明确授权后，把有边界的工作直接派发给 Claude Code、Codex、
Cursor Agent 或 Kiro CLI，并回收可验证的结果。这与当前“用户直接操作 TUI”是两个
不同能力。

- [ ] 设计 Runtime-neutral 的 dispatch、execution 和 result 生命周期。
- [ ] 支持启动、观察、停止、恢复、超时和失败恢复。
- [ ] 保留各 CLI 自己的身份认证、工作目录授权和 Provider Session 语义。
- [ ] 向用户展示实际命令、文件变更、diff、产物、最终结果和来源 Agent。
- [ ] 为写文件、运行命令、网络访问和破坏性操作设计分级审批策略。
- [ ] 定义重试幂等性，避免重复执行已经产生副作用的操作。
- [ ] 为四家 CLI 建立相同任务集上的兼容性与结果回收测试。

### [Planned] 不同 Agent 的交互、接力与协作

允许多个 Agent 围绕同一任务协作，同时保留清晰的所有权、上下文来源和用户控制。

- [ ] 明确交互模型：切换 Runtime、顺序接力、并行协作或任务分支树。
- [ ] 定义 Runtime-neutral handoff package，包含目标、工作目录、约束、上下文、
  已做决策、产物和来源 Agent。
- [ ] 保留每个 Provider 的原生 Session，不伪造或合并供应商历史。
- [ ] 定义并发所有权，以及多个 Agent 修改同一工作目录时的冲突策略。
- [ ] 在可见时间线中记录每次派发、交接、审批、结果、取消和失败。
- [ ] 接收方执行有副作用操作前要求明确授权。
- [ ] 定义失败回滚、部分完成、超时、重复交接和用户中止语义。
- [ ] 验证 Claude Code、Codex、Cursor Agent、Kiro CLI 之间的双向交接。

## Later — 长期记忆

### [Research] 可控、可解释的长期记忆

设计跨会话、跨任务但仍由用户控制的本地语义记忆。现有的 Gemini 单会话历史压缩
和 Provider Session resume 都不是长期记忆。

- [ ] 决定记忆作用域：用户、清单、任务、工作目录、Agent 或 Session。
- [ ] 定义允许提取的内容，以及密钥、凭据和敏感文件等永不自动记录的内容。
- [ ] 设计显式确认、查看、编辑、导出、忘记和永久删除流程。
- [ ] 保存来源和时间；注入上下文时说明用了哪条记忆以及原因。
- [ ] 处理过期、冲突、误提取、低置信度和重复记忆。
- [ ] 防止 Prompt Injection 导致错误持久化或跨项目数据泄露。
- [ ] 完成本机加密、Keychain、备份、数据保留、彻底删除和 Token 预算评审。
- [ ] 定义不同 Agent 对记忆的读取、写入和隔离权限。
- [ ] 只有产品与安全评审通过后，才增加正式 schema、IPC、UI 和回归测试。

本阶段不会通过空 `MEMORY.md`、占位数据库表或不可见的自动提取来假装已经实现长期
记忆。

## 当前不做

- 不把单个 Provider 的 resume 能力宣传为 TodoAgent 长期记忆。
- 不把多个独立终端同时运行宣传为跨 Agent 协作。
- 不让 Gemini 任务助手在没有新的权限与审批模型时获得 shell 或 CLI 派发能力。
- 不把 ad-hoc 签名 DMG 宣传为可公开分发的正式版本。

## 如何参与

如果你希望参与其中一项，请先创建 Feature Request，说明使用场景、预期结果、安全
边界和可验证的验收方式。实现前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)；涉及
隐私或安全设计时同时阅读 [`SECURITY.md`](SECURITY.md)。
