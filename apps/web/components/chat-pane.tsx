"use client";

import { useEffect, useRef, useState } from "react";
import type { ChatHistory, ChatStatus, ChatTaskCard, Task } from "../lib/types.ts";
import { TASK_STATUS_LABEL } from "../lib/types.ts";
import { IconSend } from "./icons.tsx";

/**
 * The right column: the secretary, always present.
 *
 * Structure from mockups/opt-h2-sunsama-refined.html — header, needs-you context
 * card, message stream, quick-command chips, composer. Colour and type stay on this
 * app's palette rather than the mockup's green.
 *
 * Live as of M4. The composer stays visible even when no model is configured — this
 * panel IS the product's promise, "say a thing, it becomes a task" — but submitting
 * then only surfaces the setup banner.
 *
 * Hidden below 1050px by the stylesheet, along with its grid track: at that width
 * the board is the working surface and this is the first thing that can go.
 */

/**
 * The three suggestions under the stream.
 *
 * Static, and each one is a sentence the secretary's existing tools can already act
 * on — 派发 goes through `dispatch_task`, moving dates through `update_task`, the
 * summary through `list_state`. They are shortcuts for typing, not a second command
 * surface with its own semantics.
 */
const QUICK_CHIPS = ["派发剩余任务", "把明天的挪到今天", "总结今天的进展"] as const;

export function ChatPane({
  history,
  status,
  thinking,
  runtimeNames,
  needsTasks,
  onSend,
  onOpenTask,
  onAnswer,
}: {
  history: ChatHistory | null;
  /** Null while the probe is in flight; the banner waits for a real answer. */
  status: ChatStatus | null;
  thinking: boolean;
  /** Detected local CLIs, e.g. ["codex", "claude"]. */
  runtimeNames: string[];
  /**
   * Tasks parked in 需要你, newest last.
   *
   * Passed in rather than derived from the board: a task waiting on you is waiting
   * regardless of which view is open, and the board is only loaded for 我的一天.
   */
  needsTasks: Task[];
  /** Resolves when the turn is over; rejections carry the engine's message. */
  onSend: (body: string) => Promise<void>;
  onOpenTask: (task: ChatTaskCard) => void;
  /** Hands off to the task card's own answer bar. */
  onAnswer: (task: Task) => void;
}) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  /** Which parked task the context card is showing, when there are several. */
  const [ctxIndex, setCtxIndex] = useState(0);

  const messages = history?.messages ?? [];
  const ready = status?.ready === true;

  // Pinned to the newest message, like any messaging client. Thinking state is in
  // the dependency list so the indicator's appearance also scrolls into view.
  useEffect(() => {
    const el = bodyRef.current;
    if (el !== null) el.scrollTop = el.scrollHeight;
  }, [messages.length, thinking]);

  /*
   * Clamped when the list shrinks.
   *
   * Answering the third of three parked tasks leaves the index past the end, and the
   * card would render blank rather than falling back to what is still waiting.
   */
  useEffect(() => {
    if (ctxIndex >= needsTasks.length) setCtxIndex(0);
  }, [needsTasks.length, ctxIndex]);

  const submit = (text: string = draft): void => {
    const body = text.trim();
    if (body === "" || sending) return;
    setDraft("");
    setSending(true);
    onSend(body).finally(() => setSending(false));
  };

  const ctx = needsTasks[ctxIndex];

  return (
    <aside className="chat">
      <div className="chead">
        <span className="chat-mark" aria-hidden="true" />
        <div className="chead-id">
          <div className="name">秘书</div>
          {/* The configured model when live; otherwise the installed CLIs, honest
              about zero. */}
          <div className="sub">
            {status?.ready === true
              ? status.model
              : runtimeNames.length > 0
                ? runtimeNames.join(" · ")
                : "未检测到 CLI"}
          </div>
        </div>
        {/*
          Green when the model answers, grey when it does not.

          `title` rather than text: the reason is already spelled out in the banner
          below, and repeating it in the header would push the model name out.
        */}
        <span
          className={`dot-live${ready ? " on" : ""}`}
          title={ready ? "在线" : (status?.reason ?? "未配置模型")}
          aria-label={ready ? "秘书在线" : "秘书未配置"}
        />
      </div>

      {status !== null && !status.ready && (
        <div className="cbanner" role="note">
          {status.reason}
        </div>
      )}

      <div className="cbody" ref={bodyRef}>
        {/*
          The context card: what is waiting on you, above everything else.

          Pinned to the top of the stream rather than inline with the messages,
          because it is not part of the conversation — it is the state of the board,
          and it has to stay visible while you scroll back through history.
        */}
        {ctx !== undefined ? (
          <div className="ctx">
            <div className="k">
              需要你
              {ctx.needsKind === "question" ? " · 提问" : ctx.needsKind === "blocked" ? " · 受阻" : " · 失败"}
            </div>
            <div className="t">{ctx.title}</div>
            {ctx.needsText !== null && ctx.needsText !== "" ? (
              <p className="q">{ctx.needsText}</p>
            ) : null}
            <div className="acts">
              {/*
                Only a question can be answered. `blocked` and `failed` are refused by
                the engine with a 409 — nobody asked anything, so there is no question
                for a reply to answer — and those cards take 重派 on the board instead.
              */}
              {ctx.needsKind === "question" ? (
                <button type="button" className="yes" onClick={() => onAnswer(ctx)}>
                  回答
                </button>
              ) : null}
              <button
                type="button"
                className="no"
                onClick={() =>
                  onOpenTask({
                    id: ctx.id,
                    title: ctx.title,
                    status: ctx.status,
                    channelId: ctx.channelId,
                  })
                }
              >
                去看看
              </button>
              {needsTasks.length > 1 ? (
                <button
                  type="button"
                  className="more"
                  onClick={() => setCtxIndex((i) => (i + 1) % needsTasks.length)}
                >
                  还有 {needsTasks.length - 1} 件
                </button>
              ) : null}
            </div>
          </div>
        ) : null}

        {messages.length === 0 && !thinking ? (
          <p className="cempty">和 agent 说件事，它会变成任务</p>
        ) : (
          messages.map((m, i) => (
            <MessageRow
              key={m.id}
              message={m}
              history={history}
              onOpenTask={onOpenTask}
              /* A separator whenever the calendar day changes, and before the first
                 message — so a stream opened days later says when it started. */
              daySep={daySeparator(messages[i - 1]?.createdAt ?? null, m.createdAt)}
            />
          ))
        )}
        {thinking && (
          <div className="m a thinking" aria-label="agent 正在处理">
            <i />
            <i />
            <i />
          </div>
        )}

        {/*
          Suggestions, under the stream rather than above the composer.

          Hidden while the model is unconfigured: they would send a message that only
          produces the setup banner, which is a dead end dressed as an affordance.
          Hidden once a conversation exists, too — they are for the empty state, and a
          long thread does not need three buttons repeating themselves at the bottom.
        */}
        {ready && messages.length === 0 && !thinking ? (
          <div className="quick-chip">
            {QUICK_CHIPS.map((chip) => (
              <button key={chip} type="button" onClick={() => submit(chip)}>
                {chip}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      <div className="composer">
        <div className={`composer-box${sending ? " busy" : ""}`}>
          <textarea
            ref={inputRef}
            rows={1}
            placeholder={ready ? "跟秘书说点什么…" : "先配置模型（见上方提示）"}
            aria-label="给秘书发送消息"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              // Enter sends, Shift+Enter breaks a line. `isComposing` is checked
              // because an IME's Enter commits a candidate — sending there would
              // truncate a half-typed Chinese word mid-conversion.
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                submit();
              }
            }}
            disabled={sending}
          />
          <button
            type="button"
            className="send"
            onClick={() => submit()}
            disabled={sending || draft.trim() === ""}
            aria-label="发送"
          >
            <IconSend />
          </button>
        </div>
        <div className="composer-hint">↩ 发送 · ⇧↩ 换行</div>
      </div>
    </aside>
  );
}

/**
 * One message, with its task cards and an optional day separator.
 *
 * Split out so the separator logic stays out of the map body — it needs the previous
 * message's timestamp, which is exactly the kind of index arithmetic that goes wrong
 * silently when it is inline.
 */
function MessageRow({
  message,
  history,
  onOpenTask,
  daySep,
}: {
  message: ChatHistory["messages"][number];
  history: ChatHistory | null;
  onOpenTask: (task: ChatTaskCard) => void;
  daySep: string | null;
}) {
  const mine = message.role === "user";
  return (
    <>
      {daySep !== null ? <div className="day-sep">{daySep}</div> : null}
      <div className={`mrow ${mine ? "u" : "a"}`}>
        <div className={`m ${mine ? "u" : "a"}`}>{message.body}</div>
        {message.taskRefs.length > 0 && (
          <div className="trefs">
            {message.taskRefs.map((id) => {
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
    </>
  );
}

/**
 * The label for a day separator, or null when the day has not changed.
 *
 * Compared on the LOCAL calendar day rather than on the raw timestamps: two messages
 * fourteen hours apart may or may not span midnight, and only the local date answers
 * that. Today and yesterday are named rather than dated, because "今天 10:12" is what
 * a person reads a timestamp as.
 */
function daySeparator(previousIso: string | null, currentIso: string): string | null {
  const current = new Date(currentIso);
  if (Number.isNaN(current.getTime())) return null;

  if (previousIso !== null) {
    const previous = new Date(previousIso);
    if (
      previous.getFullYear() === current.getFullYear() &&
      previous.getMonth() === current.getMonth() &&
      previous.getDate() === current.getDate()
    ) {
      return null;
    }
  }

  const now = new Date();
  const sameDay = (a: Date, b: Date): boolean =>
    a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);

  const time = `${current.getHours()}:${String(current.getMinutes()).padStart(2, "0")}`;
  if (sameDay(current, now)) return `今天 ${time}`;
  if (sameDay(current, yesterday)) return `昨天 ${time}`;
  return `${current.getMonth() + 1}月${current.getDate()}日 ${time}`;
}
