# TodoAgent 实施计划

> **工作方式**：本文档是总纲和唯一事实来源。每个里程碑有一份独立的执行 prompt 放在 `plans/` 目录下，
> 直接复制给编码 agent 执行。每完成一个里程碑：更新 §6 的状态列、把决策沉淀进 §7、再写下一份 prompt。

设计基准：`mockups/opt-h2-sunsama-refined.html`（2026-08-04 用户定稿，M7 落地中；旧基准 v1d-apple 已废弃）。产品承诺：**一个会自己完成任务的待办清单**——添加任务或和 agent 说一句话，任务被派给本地 CLI agent 执行，卡住的任务带着问题回来找你，完成的任务等你确认。

## 0. 目标闭环（V1 全景）

```
你在 chat 说一句话（或点「添加任务」）
    ↓
主 agent（pi runtime）解析 → 建任务卡 → 自动关联清单/仓库/历史任务
    ↓
任务派发给本地 CLI（claude/codex/cursor/kiro/grok，直跑，已实现）
    ↓
执行中 → 看板实时更新（SSE）
    ↓
结束分三路：
  完成       → 「待确认」，你点「看结果」看 diff/transcript 后勾掉
  提问/受阻  → 「需要你」，你点「回答」，答案送回 agent 继续
  失败/超时  → 「需要你」，你看日志决定重派或关闭
```

主 agent 只做四件事：**解析对话、建卡关联、识别产出类型（完成/提问）、转发你的回答**。不做拆解、不做验收（人是验收者）、不做 workflow。

## 1. 架构

```
apps/web        Next.js 三栏 UI（照 v1d 原型重做）
   ↕ HTTP + SSE（仅 localhost）
apps/engine     Hono
   ├─ chat 路由 → 主 agent（pi-agent-core + pi-ai，进程内）
   ├─ 任务/清单 API
   ├─ 直派执行 runDirect（已完成，d45cb62）
   └─ SQLite（packages/core/db）
packages/core   适配器、看门狗、runDirect、Store（全部复用）
```

主 agent 依赖：`@earendil-works/pi-ai` + `@earendil-works/pi-agent-core`（0.83.x，badlogic 的 pi 已迁移到该组织；旧 `@mariozechner/*` 停更在 0.73.1）。

## 2. 数据模型改动（packages/core）

### 2.1 复用 `channel` 表作为「清单」
- 加列：`color TEXT`（侧栏色点）
- 语义：一个清单可绑仓库（`project_id` 非空 → 任务可派发）或不绑（纯待办，如「灵光一现」）
- 频道消息/DM 功能不再暴露 UI，表保留

### 2.2 `task` 表扩展
```
note            TEXT      -- 副标题行（"codex · 4 分钟 · 3 个文件"由前端实时渲染，note 存用户/主agent写的说明）
my_day          TEXT      -- ISO 日期；等于今天 → 出现在「我的一天」
needs_kind      TEXT      -- null | question | blocked | failed | timeout
needs_text      TEXT      -- 提问原文 / 受阻原因摘要
```
状态机（在现有 todo|in_progress|in_review|done 上加一个值）：
```
todo → in_progress → in_review → done
              ↘ needs_you ↗（回答后回 in_progress）
```
不变量：`needs_you` 必有 `needs_kind`；`in_progress` 必有活着的 run。

### 2.3 新表 `agent_chat`
```
id, role (user|agent), body, task_refs (JSON: 本条消息创建/引用的任务id),
created_at
```
V1 单条时间线（不分会话），主 agent 上下文取最近 N 条。

### 2.4 迁移
Store 已有 migrate 机制（`db/index.ts`），按既有模式加列/建表 + 测试。

## 3. 主 agent（pi runtime）

### 3.1 职责与工具
系统提示词固定人设：任务秘书，惜字如金。注册工具（TypeBox schema）：

| 工具 | 作用 |
|---|---|
| `create_tasks` | 批量建卡：title/note/listId/是否派发 |
| `find_related` | 按关键词+仓库查历史任务（关联提示「与上周 X 同仓库」）|
| `dispatch_task` | 调 engine 内部派发（复用 /tasks/:id/run 的逻辑）|
| `update_task` | 改清单/标题/note |
| `list_state` | 读当前看板摘要（回答"现在什么情况"）|

### 3.2 两个非对话职责
- **产出分类**：runDirect 结束时，把 worker 最后输出交给主 agent 单轮调用分类：`done | question | blocked`，question/blocked 时抽出一句摘要写进 `needs_text`。分类失败兜底为 done（宁可让人看一眼，不可吞掉产出）。
- **回答转发**：你在「需要你」点「回答」→ 主 agent 把你的答案 + 原问题拼成续跑 prompt：claude/cursor 用 `resumeSessionId` 续会话（attempt 表已存 sessionId，适配器已支持，只是从没被调用过）；codex/acp 无 resume，带上一轮输出全文重跑。

### 3.3 运行位置与凭据
- 跑在 engine 进程内（无独立服务）
- 模型走 pi-ai，需要一个 API key（环境变量 `TODOAGENT_MODEL` + `TODOAGENT_API_KEY`，pi-ai 支持任意 OpenAI 兼容端点）
- **待讨论**：用哪家模型（见 §7-1）

## 4. Engine API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/lists` | 清单+计数（我的一天/需要你/已完成 计数一并返回）|
| POST | `/api/lists` | 建清单（可选绑仓库）|
| GET | `/api/tasks?view=today\|needs\|done\|list:<id>` | 分组好的任务 |
| POST | `/api/tasks` | 快速添加（不经过主 agent）|
| PATCH | `/api/tasks/:id` | 勾选/改清单/myDay |
| POST | `/api/tasks/:id/run` | 派发（已有，直跑）|
| POST | `/api/tasks/:id/answer` | 回答提问 → 续跑 |
| POST | `/api/chat` | 用户消息 → 主 agent，SSE 流式返回（文本 + 建卡事件）|
| GET | `/api/chat/history` | 对话时间线 |
| GET | `/api/stream` | 看板增量事件（复用 bus，扩展 task:* 事件）|
| GET | `/api/runs/:id/diff` | 「看结果」：工作区 git diff + transcript（已有 transcript 端点）|

删除/隐藏：频道消息路由、六阶段闸门路由从 web 不再调用（引擎里保留，深度模式）。

## 5. 前端重做（apps/web）

- **设计 token**：把原型 `:root` 变量提为 `globals.css`，苹果灰底/毛玻璃/系统蓝/0.5px 分隔线/圆角 18px 组卡
- **结构**：单页三栏
  - `Sidebar`：我的一天/需要你(蓝色角标)/已完成 + 清单（色点+计数）+ 新建清单
  - `TaskPane`：大标题 + 添加任务输入行 + 分组卡（需要你 priority 描边置顶 → 进行中 → 待办 → 已完成折叠）
  - `ChatPane`：iMessage 风、任务创建卡片内嵌、关联提示行、输入胶囊；≤1050px 隐藏（原型断点照搬）
- **交互**：
  - 添加任务行内输入回车即建（默认当前清单）
  - 勾选圈点击 → done（agent 任务在 in_review 时勾选＝确认通过）
  - 「回答」弹底部输入条（textarea）→ POST answer
  - 「看结果」抽屉：diff + transcript
  - SSE 驱动状态点/计数实时变化
- **删除页面**：频道页、首页委托表单；`/runs/[id]` 简化为执行详情（供「看结果」跳转）；team 页改「Agent 管理」（列 CLI 探测状态）
- 旧组件保留可复用：`atoms`、`transcripts`、SSE hooks

## 6. 里程碑（每个都可独立验收）

| # | 内容 | 验收标准 | 状态 |
|---|---|---|---|
| M0 | 直派执行（任务→单 agent 直跑，无流水线）| 测试过 | ✅ `d45cb62` |
| M1 | 数据模型迁移 + lists/tasks API | curl 全链路建单/建卡/查视图，测试过 | ✅ `8eb60bc` |
| M2 | 前端三栏重做（照 v1d 原型，接 M1 API）| UI 与原型一致，增删勾选/派发/取消可用 | ✅ `3e46360`…`dfd4bed`，452 测试全绿 |
| M3 | 执行反馈打磨 + M2 遗留缺口 | SSE、看结果抽屉（diff+transcript）、失败重派、CORS/归档修复、任务改标题 | ✅ `4b5066d`…`286a4e8`，490 测试全绿 |
| M4 | 主 agent chat（完全嵌入 pi SDK）| 说一句话 → 建卡出现在清单 + 关联提示；无 key 时优雅降级 | ✅ 代码与测试完成；真实模型路径待 key 验证（脚本化假模型已穿透生产路径）|
| M5 | 需要你闭环 | 产出分类（模型+启发式双层）进 needs_you；回答 → resume 真续/假续 → 再分类 | ✅ `e7c82cd`…`2a7a960`，527 测试全绿 |
| M6 | 打磨与收尾 | e2e 重写、seed 收简、移动清单/我的一天入口、快捷键、README 重写 | ✅ `ee306a1`…`d772567`（含 .env/代理支持），542 测试全绿 |
| M7 | UI 重制：Sunsama 风日看板 + 常驻秘书 | 视觉对齐 `mockups/opt-h2-sunsama-refined.html`；四列日看板（due_date 分列）；秘书面板常驻含 needs_you 上下文卡；全链路与测试不回归 | 📋 prompt 就绪（`plans/M7-ui-dayboard.md`），前置：先提交工作区 due_date 改动 |

### 待 key 验证清单（key = google/gemini-3.6-flash，2026-08-04 执行）

1. ✅ M4 真模型：真实 Gemini 一轮 6s，两卡创建、taskRefs 正确、遵守「先别派发」
2. ✅ M5 真续跑：`pnpm e2e --ask` 19/19——真 claude 提问→回答→`resumed=true` 真续→按回答建文件→待确认
3. ◐ M5 模型分类：e2e 引擎是隔离环境走的启发式（正确）；真 Gemini 分类质量待 dogfood 中首次真实派发观察
4. ⏳ 降级路径（删 session 文件→假续）：边缘用例，dogfood 期间顺手验

顺序说明:M2 在 M1 后立即做，让每个后续里程碑都能在真 UI 里看到；M4/M5 依赖 pi 凭据到位。

## 7. 已定决策（2026-08-02）

1. **主 agent 凭据**：key 暂缓，M1–M3 先行；M4/M5 等 key 到位再动。不做 CLI 兜底。
2. **「我的一天」**：方案 B，自动聚合 = 需要你 + 进行中 + 待确认 + 今天新建的待办。
3. **续跑策略**：claude/cursor 用真 resume（attempt.sessionId 已存）；codex 带上一轮输出全文重跑（假续），接受 token 重复消耗。
4. **旧频道聊天 UI**：直接删，engine 代码保留。
> M3 验收补记（2026-08-02）：diff 快照不进 `Run` 接口（列表载荷会爆），读取走独立查询；SSE 发布走中间件
> 跳过 GET/4xx/5xx；`needsKind=question` 的任务在 M5 落地前没有可用动作（已知死路，M5 解）。

> M5 验收补记（2026-08-03）：产出判定持久化在 `run.outcome_kind/text`（syncTaskFromRun 有 11 个
> 调用点，必须保持 (run,task) 纯映射，判定放局部变量会被后续同步冲掉——实现者的方案优于计划原稿）；
> session 失效只能靠文本匹配（两家 CLI 都无结构化错误码），匹配刻意收窄；启发式不产 blocked，
> 该 kind 仅模型路径可达。

6. **M4 架构决策（2026-08-03，用户拍板）**：主 agent **完全嵌入 pi SDK**（`@earendil-works` 系），
   不走「pi-ai + 自写循环」。理由：总管的演进路线（读 diff 验收、读仓库补上下文、review 文件、
   多 agent 沟通）会用上 pi 的内置工具集与会话体系，现在自写将来再迁是两遍工。配套约束：
   - 工具按里程碑分级启用：M4 只开任务五工具 + 只读文件工具；write/edit/bash 留给总管里程碑
   - 会话真相单轨：pi 会话是 LLM 上下文的真相，`agent_chat` 表降级为 UI 时间线投影（消息文本 + taskRefs）
   - 版本锁死精确号，升级是主动动作
   - 测试注入点在第 0 步调研中确定（假 provider / 假模型端点）

5. **V1 操作清单**（破坏性操作全部二次确认一次）：
   - 任务：添加、改标题、勾选完成、删除、派发、**取消执行中**（abort run，防烧 token）、回答（需要你）、重派（失败后）
   - 清单：新建、重命名、归档（不碰仓库本身）
   - 不做：批量操作、清空已完成、任务移动排序
