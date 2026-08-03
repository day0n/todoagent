"use client";

import { useEffect, useRef, useState } from "react";
import type { ChatHistory, ChatStatus, ChatTaskCard } from "../lib/types.ts";
import { TASK_STATUS_LABEL } from "../lib/types.ts";
import { IconSend } from "./icons.tsx";

/**
 * The right pane: the main agent's conversation.
 *
 * Live as of M4. The composer stays visible even when the agent is not
 * configured — this pane IS the product's promise, "say a thing, it becomes a
 * task" — but submitting then only surfaces the setup banner. Task cards the
 * agent creates render inline under its reply, resolved through
 * `history.tasks` because the current board view may not contain them.
 *
 * Hidden entirely below 1050px by the stylesheet: at that width the task list
 * is the working surface and this is the first thing that can go.
 */
export function ChatPane({
  history,
  status,
  thinking,
  runtimeNames,
  onSend,
  onOpenTask,
}: {
  history: ChatHistory | null;
  /** Null while the probe is in flight; the banner waits for a real answer. */
  status: ChatStatus | null;
  thinking: boolean;
  /** Detected local CLIs, e.g. ["codex", "claude"]. */
  runtimeNames: string[];
  /** Resolves when the turn is over; rejections carry the engine's message. */
  onSend: (body: string) => Promise<void>;
  onOpenTask: (task: ChatTaskCard) => void;
}) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);

  const messages = history?.messages ?? [];
  const ready = status?.ready === true;

  // Pinned to the newest message, like any messaging client. Thinking state is
  // in the dependency list so the indicator's appearance also scrolls into view.
  useEffect(() => {
    const el = bodyRef.current;
    if (el !== null) el.scrollTop = el.scrollHeight;
  }, [messages.length, thinking]);

  const submit = (): void => {
    const text = draft.trim();
    if (text === "" || sending) return;
    setDraft("");
    setSending(true);
    onSend(text).finally(() => setSending(false));
  };

  return (
    <aside className="chat">
      <div className="chead">
        <div className="face" aria-hidden="true" />
        <div className="t">
          <i className={ready ? "on" : ""} />
          Agent
        </div>
        {/* Configured model when live; otherwise the installed CLIs, honest about zero. */}
        <div className="s">
          {status?.ready === true
            ? status.model
            : runtimeNames.length > 0
              ? runtimeNames.join(" · ")
              : "未检测到 CLI"}
        </div>
      </div>

      {status !== null && !status.ready && (
        <div className="cbanner" role="note">
          {status.reason}
        </div>
      )}

      <div className="cbody" ref={bodyRef}>
        {messages.length === 0 && !thinking ? (
          <p className="cempty">和 agent 说件事，它会变成任务</p>
        ) : (
          messages.map((m) => (
            <div key={m.id} className={`mrow ${m.role === "user" ? "u" : "a"}`}>
              <div className={`m ${m.role === "user" ? "u" : "a"}`}>{m.body}</div>
              {m.taskRefs.length > 0 && (
                <div className="trefs">
                  {m.taskRefs.map((id) => {
                    const t = history?.tasks[id];
                    if (t === undefined) return null;
                    return (
                      <button
                        key={id}
                        type="button"
                        className="tref"
                        onClick={() => onOpenTask(t)}
                        title="在清单中查看"
                      >
                        <span className="o" aria-hidden="true" />
                        <span className="tt">{t.title}</span>
                        <span className={`st st-${t.status}`}>{TASK_STATUS_LABEL[t.status]}</span>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          ))
        )}
        {thinking && (
          <div className="m a thinking" aria-label="agent 正在处理">
            <i />
            <i />
            <i />
          </div>
        )}
      </div>

      <div className="cinput-wrap">
        <div className={`cinput ${sending ? "busy" : ""}`}>
          <input
            placeholder={ready ? "说件事，自动变成任务…" : "先配置模型（见上方提示）"}
            aria-label="给 Agent 发送消息"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.nativeEvent.isComposing) submit();
            }}
            disabled={sending}
          />
          <button
            type="button"
            className="send"
            onClick={submit}
            disabled={sending || draft.trim() === ""}
            aria-label="发送"
          >
            <IconSend />
          </button>
        </div>
      </div>
    </aside>
  );
}
