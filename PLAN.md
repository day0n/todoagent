# TodoAgent 实施计划

设计基准：`mockups/v1d-apple.html`（用户修订版）。产品承诺：**一个会自己完成任务的待办清单**——添加任务或和 agent 说一句话，任务被派给本地 CLI agent 执行，卡住的任务带着问题回来找你，完成的任务等你确认。

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

| # | 内容 | 验收标准 |
|---|---|---|
| M1 | 数据模型迁移 + lists/tasks API | curl 全链路建单/建卡/查视图，测试过 |
| M2 | 前端三栏（静态先行，接 M1 API）| UI 与原型一致，增删勾选可用 |
| M3 | 派发闭环接前端 | 点「派发」→ 状态点变化 → 待确认 → 看结果 → 勾掉 |
| M4 | 主 agent chat（pi 接入）| 说一句话 → 建卡出现在清单 + 关联提示 |
| M5 | 需要你闭环 | 产出分类进 needs_you；回答 → resume 续跑 → 完成 |
| M6 | 打磨 | 空状态/快捷键/响应式/已完成折叠；e2e 更新 |

顺序说明:M2 在 M1 后立即做，让每个后续里程碑都能在真 UI 里看到；M4/M5 依赖 pi 凭据到位。

## 7. 待讨论决策

1. **主 agent 用什么模型/凭据**（阻塞 M4/M5）：pi-ai 支持 Anthropic/OpenAI/Google/OpenRouter/任意兼容端点。推荐便宜快的小模型（解析任务和分类产出不需要旗舰）。需要你提供一个 key，或者决定用 OpenRouter 统一。兜底方案：没有 key 时主 agent 降级为本地 CLI 单轮调用（慢、但零成本）——要不要做这个兜底？
2. **「我的一天」的定义**：A. 手动加入（微软原味，纯 my_day 字段）；B. 自动聚合（needs_you+进行中+待确认+今天建的）。建议 V1 用 B（省一步手动操作，打开就是全局现状），后续再加手动。
3. **提问式续跑的降级策略**：codex 没有 resume，带全文重跑会重复消耗 token。可接受吗？（claude/cursor 无此问题）
4. **旧频道聊天功能**：UI 直接删，还是留个隐藏入口？建议直接删（代码保留在 engine）。
5. **清单删除/归档**、任务删除这类破坏性操作 V1 要不要做？建议只做「归档清单」「删任务」两个最小项。
