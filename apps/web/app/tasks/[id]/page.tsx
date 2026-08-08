"use client";

import Link from "next/link";
import { AnimatePresence, motion } from "motion/react";
import { use, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { RuntimeMark, StatusBadge } from "../../../components/atoms.tsx";
import { EdgeGlow } from "../../../components/edge-glow.tsx";
import { SelectMenu } from "../../../components/overlays.tsx";
import { api, ApiError } from "../../../lib/api.ts";
import { runtimeLabel } from "../../../lib/runtime.ts";
import type { RuntimeEnvelope, RuntimeKind, StreamEvent, TaskThread } from "../../../lib/types.ts";
import { useRun } from "../../../lib/useRun.ts";

export default function TaskThreadPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [thread, setThread] = useState<TaskThread | null>(null);
  const [runtimes, setRuntimes] = useState<RuntimeEnvelope | null>(null);
  const [draft, setDraft] = useState("");
  const [runtimeKind, setRuntimeKind] = useState<RuntimeKind | "">("");
  const [workingDirectory, setWorkingDirectory] = useState("");
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [pickingDirectory, setPickingDirectory] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement | null>(null);

  const load = useCallback(async () => {
    try {
      const [nextThread, nextRuntimes] = await Promise.all([api.taskThread(id), api.runtimes()]);
      setThread(nextThread);
      setRuntimes(nextRuntimes);
      setRuntimeKind((current) =>
        nextThread.task.runtimeKind ?? (current !== "" ? current : nextRuntimes.runtimes.find((r) => r.status === "ready")?.kind ?? ""),
      );
      setWorkingDirectory((current) =>
        nextThread.task.workingDirectory ?? (current !== "" ? current : nextThread.defaultWorkingDirectory ?? ""),
      );
      setError(null);
    } catch (reason) {
      setError(messageOf(reason));
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (thread?.activeRunId === null || thread?.activeRunId === undefined) return;
    const timer = window.setInterval(() => void load(), 2_000);
    return () => window.clearInterval(timer);
  }, [load, thread?.activeRunId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [thread?.replyCount, thread?.activeRunId]);

  const locked =
    thread?.task.runtimeKind !== null &&
    thread?.task.runtimeKind !== undefined &&
    thread?.task.workingDirectory !== null &&
    thread?.task.workingDirectory !== undefined;
  const active = thread?.activeRunId !== null && thread?.activeRunId !== undefined;
  const selectedRuntime = runtimes?.runtimes.find((runtime) => runtime.kind === runtimeKind) ?? null;

  const send = async (): Promise<void> => {
    const message = draft.trim();
    if (message === "" || sending || active) return;
    if (!locked && (runtimeKind === "" || workingDirectory.trim() === "")) {
      setError("第一次对话前，请选择本机 CLI 和工作目录。");
      return;
    }
    setSending(true);
    setError(null);
    try {
      await api.sendTaskMessage(id, {
        message,
        ...(!locked && runtimeKind !== "" ? { runtimeKind } : {}),
        ...(!locked ? { workingDirectory: workingDirectory.trim() } : {}),
      });
      setDraft("");
      await load();
    } catch (reason) {
      setError(messageOf(reason));
    } finally {
      setSending(false);
    }
  };

  const markDone = async (): Promise<void> => {
    if (active || !thread) return;
    setSending(true);
    setError(null);
    try {
      await api.patchTask(id, { status: "done" });
      await load();
    } catch (reason) {
      setError(messageOf(reason));
    } finally {
      setSending(false);
    }
  };

  const pickDirectory = async (): Promise<void> => {
    if (pickingDirectory) return;
    setPickingDirectory(true);
    setError(null);
    try {
      const selected = await api.pickDirectory();
      if (selected.path !== null) setWorkingDirectory(selected.path);
    } catch (reason) {
      setError(messageOf(reason));
    } finally {
      setPickingDirectory(false);
    }
  };

  const reopen = async (): Promise<void> => {
    setSending(true);
    setError(null);
    try {
      await api.patchTask(id, { status: "todo" });
      await load();
    } catch (reason) {
      setError(messageOf(reason));
    } finally {
      setSending(false);
    }
  };

  if (loading && thread === null) {
    return <main className="task-thread-loading">正在打开任务对话…</main>;
  }
  if (thread === null) {
    return (
      <main className="task-thread-loading">
        <p>{error ?? "无法打开任务"}</p>
        <Link href="/" className="btn">返回时间线</Link>
      </main>
    );
  }

  return (
    <main className="task-thread-shell">
      <header className="task-thread-header">
        <Link href="/" className="task-thread-back" aria-label="返回时间线">←</Link>
        <div className="task-thread-heading">
          <div className="task-thread-eyebrow">
            <span>{thread.list?.name ?? "任务"}</span>
            <span>·</span>
            <span>{thread.replyCount} 条消息</span>
          </div>
          <h1>{thread.task.title}</h1>
          {thread.task.note.trim() !== "" ? <p>{thread.task.note}</p> : null}
          {locked ? (
            <div className="task-thread-context" aria-label="当前会话环境">
              {thread.task.runtimeKind ? <RuntimeMark kind={thread.task.runtimeKind} name={runtimeLabel(thread.task.runtimeKind)} /> : null}
              <span className="task-context-separator" aria-hidden="true">/</span>
              <span className="task-context-path" title={thread.task.workingDirectory ?? undefined}>{thread.task.workingDirectory}</span>
            </div>
          ) : null}
        </div>
        <div className="task-thread-header-actions">
          {thread.task.status === "done" ? (
            <button type="button" className="btn btn-sm" disabled={sending} onClick={() => void reopen()}>重新打开</button>
          ) : (
            <button type="button" className="btn btn-sm" disabled={sending || active} onClick={() => void markDone()}>标记完成</button>
          )}
        </div>
      </header>

      <section className="task-thread-transcript" aria-label="任务对话">
        <div className="task-thread-feed">
        {!locked ? (
          <EdgeGlow className="task-session-glow">
          <section className="task-session-setup" aria-label="首次会话设置">
            <div className="task-session-setup-copy">
              <span className="task-setup-kicker">开始本机任务</span>
              <h2>选择 CLI 和它要工作的目录</h2>
              <p>第一条消息发出后，这两个选项会锁定。CLI 会直接读写该目录里的真实文件。</p>
            </div>
            <div className="task-setup-fields">
              <label>
                <span>本机 CLI</span>
                <SelectMenu
                  value={runtimeKind}
                  ariaLabel="选择本机 CLI"
                  menuClassName="agent-product-menu"
                  options={(runtimes?.runtimes ?? []).map((runtime) => ({
                    value: runtime.kind,
                    label: runtimeLabel(runtime.kind, runtime.label),
                    description: runtime.status === "ready" ? "已验证，可以启动" : `当前状态：${runtime.status}`,
                    disabled: runtime.status !== "ready",
                  }))}
                  onChange={setRuntimeKind}
                />
              </label>
              <label>
                <span>工作目录</span>
                <div className="task-directory-field">
                  <input
                    value={workingDirectory}
                    placeholder="选择文件夹或粘贴路径"
                    onChange={(event) => setWorkingDirectory(event.target.value)}
                  />
                  <button type="button" className="btn" disabled={pickingDirectory} onClick={() => void pickDirectory()}>
                    {pickingDirectory ? "正在打开…" : "选择文件夹"}
                  </button>
                </div>
                {thread.knownWorkspaces.length > 0 ? (
                  <div className="task-known-workspaces" aria-label="最近使用的工作目录">
                    {thread.knownWorkspaces.slice(0, 4).map((workspace) => (
                      <button key={workspace.path} type="button" title={workspace.path} onClick={() => setWorkingDirectory(workspace.path)}>{workspace.name}</button>
                    ))}
                  </div>
                ) : null}
              </label>
            </div>
          </section>
          </EdgeGlow>
        ) : null}
        {thread.turns.length === 0 ? (
          <div className="task-thread-empty">
            <span aria-hidden="true">›_</span>
            <h2>告诉 {selectedRuntime ? runtimeLabel(selectedRuntime.kind) : "编码 CLI"} 从哪里开始</h2>
            <p>写清目标、约束和验收方式。之后读取文件、修改代码、运行命令都会按发生顺序显示在这里。</p>
          </div>
        ) : null}

        <AnimatePresence initial={false}>
        {thread.turns.map((turn) => (
          <motion.article
            layout
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.22, ease: [0.32, 0.72, 0, 1] }}
            className="task-turn"
            key={turn.run.id}
          >
            <motion.div layout className="task-message human">
              <div className="task-message-meta"><strong>你</strong><time>{formatTime(turn.run.createdAt)}</time></div>
              <div className="task-message-body">{turn.message}</div>
            </motion.div>
            {turn.run.id === thread.activeRunId ? (
              <ActiveTurn runId={turn.run.id} />
            ) : (
              <div className="task-message agent">
                <div className="task-agent-heading">
                  {turn.run.runtimeKind ? <RuntimeMark kind={turn.run.runtimeKind} name={runtimeLabel(turn.run.runtimeKind)} /> : <strong>本机 CLI</strong>}
                  <StatusBadge status={turn.run.status} />
                  <time>{formatTime(turn.run.endedAt ?? turn.run.createdAt)}</time>
                </div>
                <ExecutionRecord events={turn.events} />
                <div className="task-agent-response">
                  <span>回复</span>
                  <div className="task-message-body">{turn.output ?? turn.run.error ?? "这一轮没有返回文本。"}</div>
                </div>
                <Link href={`/runs/${turn.run.id}`} className="task-run-link">查看原始运行记录</Link>
              </div>
            )}
          </motion.article>
        ))}
        </AnimatePresence>
        <div ref={bottomRef} />
        </div>
      </section>

      <footer className="task-composer-wrap">
        {error !== null ? <div className="task-thread-error" role="alert">{error}</div> : null}
        {active ? (
          <EdgeGlow active className="task-composer-glow">
            <div className="task-active-actions">
              <span><StatusRing />本机 CLI 正在工作，输出会实时出现在上方。</span>
              <button type="button" className="task-stop-button" aria-label="停止执行" title="停止执行" onClick={() => void api.cancelTask(id).then(load).catch((reason) => setError(messageOf(reason)))}><i /></button>
            </div>
          </EdgeGlow>
        ) : thread.task.status === "done" ? (
          <div className="task-composer-closed">任务已完成。需要继续时先重新打开。</div>
        ) : (
          <EdgeGlow active={sending} className="task-composer-glow">
          <div className="task-composer">
            <textarea
              value={draft}
              placeholder={locked ? "继续和本机 CLI 对话…" : "写下这次任务的第一条指令…"}
              rows={3}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  void send();
                }
              }}
            />
            <div>
              <span>Enter 发送 · Shift + Enter 换行</span>
              <button type="button" className="task-send-button" aria-label={locked ? "发送" : "启动会话"} title={locked ? "发送" : "启动会话"} disabled={sending || draft.trim() === "" || (!locked && (runtimeKind === "" || workingDirectory.trim() === ""))} onClick={() => void send()}>
                {sending ? <span className="task-send-spinner" /> : <span aria-hidden="true">↑</span>}
              </button>
            </div>
          </div>
          </EdgeGlow>
        )}
      </footer>
    </main>
  );
}

function ActiveTurn({ runId }: { runId: string }) {
  const { detail, live, log, connected, connection, error } = useRun(runId);
  const attempts = useMemo(() => [...live.values()], [live]);
  const current = attempts.at(-1) ?? null;
  return (
    <div className="task-message agent live">
      <div className="task-agent-heading">
        {detail?.run.runtimeKind ? <RuntimeMark kind={detail.run.runtimeKind} name={runtimeLabel(detail.run.runtimeKind)} /> : <strong>本机 CLI</strong>}
        <span className="task-live-label"><StatusRing compact />正在执行</span>
        {!connected ? <span className="task-reconnecting">{connection.state === "reconnecting" ? `连接中断，正在第 ${connection.attempt} 次重连…` : connection.state === "failed" ? "实时连接失败，页面仍会同步最终结果" : "正在建立实时连接…"}</span> : null}
      </div>
      <div className="task-live-stage">
        <span className="task-live-spinner" aria-hidden="true" />
        <span>{current?.currentTool ? toolActionLabel(current.currentTool) : "正在思考并检查工作区"}</span>
        {current && current.toolCount > 0 ? <small>{current.toolCount} 个操作</small> : null}
      </div>
      <ExecutionRecord events={log.map((row) => ({ id: row.id, type: row.type, attemptId: null, payload: row.payload, createdAt: row.createdAt }))} live />
      {current?.text ? (
        <div className="task-agent-response live-response">
          <span>实时回复</span>
          <div className="task-message-body">{current.text}</div>
        </div>
      ) : null}
      {error ? <div className="task-thread-error">{error}</div> : null}
      <Link href={`/runs/${runId}`} className="task-run-link">打开原始运行记录</Link>
    </div>
  );
}

interface ToolStep {
  id: number;
  tool: string;
  input: unknown;
  output: unknown;
  startedAt: string;
  finished: boolean;
  failed: boolean;
}

function ExecutionRecord({ events, live = false }: { events: StreamEvent[]; live?: boolean }) {
  const steps = buildToolSteps(events);
  if (steps.length === 0) return null;
  return (
    <section className="task-execution-record agent-tool-timeline" aria-label="CLI 执行过程">
      <header><span>工作记录</span><small>{steps.length} 个操作</small>{live ? <span className="agent-tool-live"><i />实时</span> : null}</header>
      <ol>
        {steps.map((step, index) => <li key={`${step.id}-${index}`}><ToolStepRow step={step} live={live && index === steps.length - 1} /></li>)}
      </ol>
    </section>
  );
}

function ToolStepRow({ step, live }: { step: ToolStep; live: boolean }) {
  const summary = toolInputSummary(step.tool, step.input);
  return (
    <details open={live || step.failed} className={`task-tool-step agent-tool-run${step.failed ? " failed" : ""}`}>
      <summary>
        <span className={`agent-tool-dot${step.failed ? " failed" : !step.finished && live ? " live" : ""}`} aria-hidden="true" />
        <span className="task-tool-copy">
          <strong>{toolActionLabel(step.tool)}</strong>
          {summary !== "" ? <small title={summary}>{summary}</small> : null}
        </span>
        <time>{shortTime(step.startedAt)}</time>
        <span className={`task-tool-state${!step.finished && live ? " live" : ""}`}>
          {step.failed ? "失败" : step.finished ? "完成" : live ? "运行中" : "未完成"}
        </span>
        <span className="task-tool-chevron" aria-hidden="true">⌄</span>
      </summary>
      <div className="task-tool-detail">
        {step.input !== null && step.input !== undefined ? <ToolPayload label="输入" value={step.input} /> : null}
        {step.output !== null && step.output !== undefined ? <ToolPayload label={step.failed ? "错误" : "输出"} value={step.output} /> : null}
      </div>
    </details>
  );
}

function StatusRing({ compact = false }: { compact?: boolean }) {
  return (
    <span className={`agent-status-ring${compact ? " compact" : ""}`} aria-hidden="true">
      <i /><i /><i />
    </span>
  );
}

function ToolPayload({ label, value }: { label: string; value: unknown }) {
  return <div><span>{label}</span><pre>{formatPayload(value)}</pre></div>;
}

function buildToolSteps(events: StreamEvent[]): ToolStep[] {
  const steps: ToolStep[] = [];
  const byCallId = new Map<string, ToolStep>();
  for (const event of events) {
    const payload = asRecord(event.payload);
    const callId = stringValue(payload["callId"] ?? payload["call_id"]);
    const tool = stringValue(payload["tool"] ?? payload["name"]) || "tool";
    if (event.type === "agent:tool_use") {
      const step: ToolStep = {
        id: event.id,
        tool,
        input: payload["input"] ?? payload["args"] ?? null,
        output: null,
        startedAt: event.createdAt,
        finished: false,
        failed: false,
      };
      steps.push(step);
      if (callId !== "") byCallId.set(callId, step);
      continue;
    }
    if (event.type === "agent:tool_result") {
      const step = (callId !== "" ? byCallId.get(callId) : undefined) ?? [...steps].reverse().find((candidate) => !candidate.finished);
      if (step) {
        step.output = payload["output"] ?? payload["content"] ?? payload["message"] ?? null;
        step.finished = true;
        step.failed = payload["isError"] === true || payload["is_error"] === true;
      }
      continue;
    }
    if (event.type === "agent:error") {
      steps.push({ id: event.id, tool: "error", input: null, output: payload["message"] ?? event.payload, startedAt: event.createdAt, finished: true, failed: true });
    }
  }
  return steps;
}

function toolActionLabel(tool: string): string {
  const name = tool.toLowerCase();
  if (name === "error") return "执行出错";
  if (/bash|shell|command|terminal/.test(name)) return "运行命令";
  if (/read|cat|view/.test(name)) return "读取文件";
  if (/edit|write|patch|replace/.test(name)) return "修改文件";
  if (/search|grep|glob|find/.test(name)) return "搜索代码";
  if (/web|browser|fetch|url/.test(name)) return "访问网页";
  return `使用 ${tool}`;
}

function toolInputSummary(tool: string, input: unknown): string {
  if (typeof input === "string") return oneLine(input);
  const row = asRecord(input);
  const candidate = row["command"] ?? row["file_path"] ?? row["path"] ?? row["query"] ?? row["pattern"] ?? row["url"];
  if (typeof candidate === "string") return oneLine(candidate);
  const formatted = formatPayload(input);
  return formatted === "" || formatted === "null" ? tool : oneLine(formatted);
}

function oneLine(value: string): string {
  const clean = value.replace(/\s+/g, " ").trim();
  return clean.length > 110 ? `${clean.slice(0, 107)}…` : clean;
}

function formatPayload(value: unknown): string {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  if (text === undefined) return "";
  return text.length > 6_000 ? `${text.slice(0, 6_000)}\n…` : text;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
function stringValue(value: unknown): string { return typeof value === "string" ? value : ""; }
function formatTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(date);
}
function shortTime(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "" : new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(date);
}
function messageOf(reason: unknown): string { return reason instanceof ApiError || reason instanceof Error ? reason.message : String(reason); }
