"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { RuntimeMark } from "../../components/atoms.tsx";
import { PromptDialog } from "../../components/overlays.tsx";
import { api, ApiError } from "../../lib/api.ts";
import { RUNTIME_STATUS_LABEL, runtimeLabel } from "../../lib/runtime.ts";
import type { AssistantWorkspace, RuntimeInfo, RuntimeKind } from "../../lib/types.ts";

export default function SettingsPage() {
  const [runtimes, setRuntimes] = useState<RuntimeInfo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [verifying, setVerifying] = useState<Set<RuntimeKind>>(new Set());
  const refreshingRef = useRef(false);
  const verifyingRef = useRef<Set<RuntimeKind>>(new Set());
  const [assistant, setAssistant] = useState<AssistantWorkspace | null>(null);
  const [memoryDraft, setMemoryDraft] = useState("");
  const [selectedRef, setSelectedRef] = useState<string | null>(null);
  const [refDraft, setRefDraft] = useState("");
  const [savingMemory, setSavingMemory] = useState(false);
  const [assistantNotice, setAssistantNotice] = useState<string | null>(null);
  const [creatingRef, setCreatingRef] = useState(false);

  const load = useCallback(async (): Promise<void> => {
    setError(null);
    try {
      const envelope = await api.runtimes();
      setRuntimes(envelope.runtimes);
    } catch (err) {
      setError(messageOf(err));
    }
  }, []);

  useEffect(() => {
    // Reading persisted state is cheap. Real verification is intentionally never
    // triggered on mount because it sends a provider request.
    void load();
    void api.assistantWorkspace().then((workspace) => {
      setAssistant(workspace);
      setMemoryDraft(workspace.memory);
    }).catch((err: unknown) => setAssistantNotice(messageOf(err)));
  }, [load]);

  const openRef = async (name: string): Promise<void> => {
    setAssistantNotice(null);
    try {
      const file = await api.assistantRef(name);
      setSelectedRef(file.name);
      setRefDraft(file.content);
    } catch (err) {
      setAssistantNotice(messageOf(err));
    }
  };

  const createRef = (entered: string): void => {
    if (!entered) return;
    const name = entered.endsWith(".md") ? entered : `${entered}.md`;
    setSelectedRef(name);
    setRefDraft("");
    setCreatingRef(false);
    setAssistantNotice("写好内容后点击保存，小抄文件才会创建。");
  };

  const saveMemory = async (): Promise<void> => {
    setSavingMemory(true);
    setAssistantNotice(null);
    try {
      await api.saveAssistantMemory(memoryDraft);
      setAssistantNotice("MEMORY.md 已保存；新的助手对话会读取它。");
    } catch (err) {
      setAssistantNotice(messageOf(err));
    } finally {
      setSavingMemory(false);
    }
  };

  const saveRef = async (): Promise<void> => {
    if (selectedRef === null) return;
    setSavingMemory(true);
    setAssistantNotice(null);
    try {
      await api.saveAssistantRef(selectedRef, refDraft);
      const workspace = await api.assistantWorkspace();
      setAssistant(workspace);
      setAssistantNotice(`${selectedRef} 已保存。`);
    } catch (err) {
      setAssistantNotice(messageOf(err));
    } finally {
      setSavingMemory(false);
    }
  };

  const refresh = async (): Promise<void> => {
    if (refreshingRef.current) return;
    refreshingRef.current = true;
    setRefreshing(true);
    setError(null);
    try {
      const envelope = await api.refreshRuntimes();
      setRuntimes(envelope.runtimes);
    } catch (err) {
      setError(messageOf(err));
    } finally {
      refreshingRef.current = false;
      setRefreshing(false);
    }
  };

  const verify = async (kind: RuntimeKind): Promise<void> => {
    if (verifyingRef.current.has(kind)) return;
    verifyingRef.current.add(kind);
    setError(null);
    setVerifying((current) => new Set(current).add(kind));
    setRuntimes((current) =>
      current?.map((runtime) =>
        runtime.kind === kind ? { ...runtime, status: "verifying", verifyError: null } : runtime,
      ) ?? null,
    );
    try {
      const runtime = await api.verifyRuntime(kind);
      setRuntimes((current) =>
        current?.map((item) => (item.kind === kind ? runtime : item)) ?? [runtime],
      );
    } catch (err) {
      setError(messageOf(err));
      // A dropped response should not strand the optimistic "verifying" state.
      await load().catch(() => undefined);
    } finally {
      verifyingRef.current.delete(kind);
      setVerifying((current) => {
        const next = new Set(current);
        next.delete(kind);
        return next;
      });
    }
  };

  const ready = runtimes?.filter((runtime) => runtime.status === "ready").length ?? 0;

  return (
    <main className="settings-main">
      <header className="settings-hero">
        <div>
          <p className="settings-kicker">执行设置</p>
          <h1>本机 CLI</h1>
          <p>
            TodoAgent 直接调用你已经安装并登录的编码 CLI。没有专家身份、角色或编队；每次派发都由你选择谁来执行。
          </p>
        </div>
        <button type="button" className="btn" disabled={refreshing} onClick={() => void refresh()}>
          {refreshing ? "正在检测…" : "重新检测"}
        </button>
      </header>

      <div className={`settings-summary${ready > 0 ? " ready" : ""}`} aria-live="polite">
        <span className="ready-dot" aria-hidden="true" />
        {runtimes === null ? "正在读取本机 CLI" : `${ready} 个 CLI 已验证可用`}
      </div>

      {error !== null ? (
        <div className="settings-error" role="alert">
          <span>{error}</span>
          <button type="button" onClick={() => void load()}>
            重试
          </button>
        </div>
      ) : null}

      {runtimes === null ? (
        <div className="settings-loading" role="status">
          正在读取 Runtime Manager…
        </div>
      ) : (
        <section className="runtime-settings-grid" aria-label="本机 CLI 状态">
          {runtimes.map((runtime) => (
            <RuntimeCard
              key={runtime.kind}
              runtime={runtime}
              verifying={verifying.has(runtime.kind)}
              onVerify={() => void verify(runtime.kind)}
            />
          ))}
        </section>
      )}

      <aside className="settings-note">
        <strong>为什么“已安装”还不能直接执行？</strong>
        <p>
          找到可执行文件只能证明命令存在。点击“验证连接”会在临时 Git 仓库发送一次最小请求，用来确认登录和协议都可用；这可能产生少量额度消耗，因此页面不会自动验证。
        </p>
      </aside>

      <section className="assistant-memory-settings" aria-labelledby="assistant-memory-title">
        <header>
          <div>
            <p className="settings-kicker">TodoAgent 助手</p>
            <h2 id="assistant-memory-title">记忆与小抄</h2>
            <p>助手只负责整理清单和任务，不执行代码。它的长期资料只有一个 MEMORY.md 和 ref/ 目录，内容完全由你看见和控制。</p>
          </div>
          <code title={assistant?.path}>{assistant?.path ?? "正在读取…"}</code>
        </header>
        {assistantNotice ? <div className="settings-memory-notice" role="status">{assistantNotice}</div> : null}
        <div className="assistant-memory-grid">
          <article>
            <div className="assistant-memory-title">
              <div><strong>MEMORY.md</strong><span>每次新对话都会先读</span></div>
              <button type="button" className="btn btn-sm" disabled={savingMemory || assistant === null} onClick={() => void saveMemory()}>{savingMemory ? "保存中…" : "保存"}</button>
            </div>
            <textarea value={memoryDraft} rows={12} placeholder="可以留空。写下助手需要长期记住的清单习惯、称呼或规则。" onChange={(event) => setMemoryDraft(event.target.value)} />
          </article>
          <article>
            <div className="assistant-memory-title">
              <div><strong>ref/ 小抄</strong><span>按需查阅的 Markdown 文件</span></div>
              <button type="button" className="btn btn-sm" onClick={() => setCreatingRef(true)}>新建</button>
            </div>
            <div className="assistant-ref-tabs">
              {assistant?.refs.length === 0 ? <span>还没有小抄</span> : null}
              {assistant?.refs.map((name) => <button key={name} type="button" className={selectedRef === name ? "active" : ""} onClick={() => void openRef(name)}>{name}</button>)}
            </div>
            {selectedRef === null ? (
              <div className="assistant-ref-empty">选择一个文件查看，或新建第一张小抄。</div>
            ) : (
              <>
                <textarea value={refDraft} rows={9} aria-label={`${selectedRef} 内容`} onChange={(event) => setRefDraft(event.target.value)} />
                <div className="assistant-ref-save"><span>{selectedRef}</span><button type="button" className="btn btn-sm" disabled={savingMemory} onClick={() => void saveRef()}>保存小抄</button></div>
              </>
            )}
          </article>
        </div>
      </section>
      <PromptDialog
        open={creatingRef}
        heading="新建一张小抄"
        description="保存为 ref/ 目录里的 Markdown 文件，助手需要时可以查阅。"
        placeholder="例如 project-rules.md"
        confirmLabel="开始编辑"
        onCancel={() => setCreatingRef(false)}
        onConfirm={createRef}
      />
    </main>
  );
}

function RuntimeCard({
  runtime,
  verifying,
  onVerify,
}: {
  runtime: RuntimeInfo;
  verifying: boolean;
  onVerify: () => void;
}) {
  const status = verifying ? "verifying" : runtime.status;
  const cannotVerify = status === "missing" || status === "verifying";

  return (
    <article className={`runtime-settings-card ${status}`}>
      <div className="runtime-settings-head">
        <RuntimeMark kind={runtime.kind} name={runtimeLabel(runtime.kind, runtime.label)} />
        <span className={`runtime-state ${status}`}>
          <i aria-hidden="true" />
          {RUNTIME_STATUS_LABEL[status]}
        </span>
      </div>

      <dl className="runtime-settings-meta">
        <div>
          <dt>版本</dt>
          <dd>{runtime.version || "—"}</dd>
        </div>
        <div>
          <dt>路径</dt>
          <dd title={runtime.execPath ?? undefined}>{runtime.execPath || "未检测到"}</dd>
        </div>
        <div>
          <dt>上次验证</dt>
          <dd>{formatTime(runtime.verifiedAt)}</dd>
        </div>
        {runtime.activeRuns > 0 ? (
          <div>
            <dt>正在执行</dt>
            <dd>{runtime.activeRuns} 个任务</dd>
          </div>
        ) : null}
      </dl>

      {runtime.verifyError ? <p className="runtime-settings-error">{runtime.verifyError}</p> : null}

      <div className="runtime-settings-actions">
        <button type="button" className="btn btn-sm" disabled={cannotVerify} onClick={onVerify}>
          {status === "verifying"
            ? "正在验证…"
            : status === "ready"
              ? "重新验证"
              : "验证连接"}
        </button>
        {status === "missing" ? <span>请先安装该 CLI，再重新检测。</span> : null}
        {status === "auth_required" ? <span>请先在终端完成登录，再重新验证。</span> : null}
      </div>
    </article>
  );
}

function formatTime(value: string | null): string {
  if (value === null) return "尚未验证";
  const time = new Date(value);
  if (Number.isNaN(time.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(time);
}

function messageOf(error: unknown): string {
  return error instanceof ApiError || error instanceof Error ? error.message : String(error);
}
