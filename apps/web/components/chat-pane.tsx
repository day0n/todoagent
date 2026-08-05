"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ENGINE } from "../lib/api.ts";
import type { ChatAttachment, ChatHistory, ChatSession, ChatStatus, ChatTaskCard, Task } from "../lib/types.ts";
import { TASK_STATUS_LABEL } from "../lib/types.ts";
import { resizeImageFile, type ResizedImage } from "../lib/image.ts";
import { ChatSessionMenu } from "./chat-session-menu.tsx";
import type { AnswerControls } from "./task-pane.tsx";
import { IconArrowDown, IconCheck, IconCopy, IconImage, IconSend, IconX } from "./icons.tsx";
import { MarkdownLite } from "./markdown-lite.tsx";

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

/** How many pictures one turn can carry, matching the engine's own `images.max(4)`. */
const MAX_IMAGES = 4;

/** One picture attached to the draft, resized and ready to send. */
interface PendingImage extends ResizedImage {
  localId: string;
}

export function ChatPane({
  history,
  status,
  thinking,
  live,
  needsTasks,
  sessions,
  activeSessionId,
  busySessionIds,
  onSend,
  onOpenTask,
  answer,
  onSelectSession,
  onCreateSession,
  onRenameSession,
  onArchiveSession,
}: {
  history: ChatHistory | null;
  /** Null while the probe is in flight; the banner waits for a real answer. */
  status: ChatStatus | null;
  thinking: boolean;
  /**
   * The active session's answer, growing token by token, while it streams.
   *
   * Null both before the first `chat:delta` arrives (the three-dot indicator
   * shows instead, driven by `thinking`) and again once `chat:message` has
   * been folded into `history` — never rendered alongside the real bubble it
   * is a preview of.
   */
  live: string | null;
  /**
   * Tasks parked in 需要你, newest last.
   *
   * Passed in rather than derived from the board: a task waiting on you is waiting
   * regardless of which view is open, and the board is only loaded for 我的一天.
   */
  needsTasks: Task[];
  /** Every open (unarchived) conversation, for the header's switcher. */
  sessions: ChatSession[];
  activeSessionId: string | null;
  /** Threads with a turn in flight right now, this one included. */
  busySessionIds: ReadonlySet<string>;
  /** Resolves when the turn is over; rejections carry the engine's message. */
  onSend: (body: string, images: ResizedImage[]) => Promise<void>;
  onOpenTask: (task: ChatTaskCard) => void;
  /**
   * Answering, shared with the task cards.
   *
   * When `activeId` names a parked question, the composer below is BOUND to it: the
   * text goes to that task's answer endpoint instead of to the secretary. The same
   * `activeId` is what the cards use to open their own bar below 1050px, where this
   * whole panel is hidden — one piece of state, so the two can never both be open.
   */
  answer: AnswerControls;
  onSelectSession: (id: string) => void;
  onCreateSession: () => void;
  onRenameSession: (id: string, title: string) => void;
  onArchiveSession: (id: string) => void;
}) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [images, setImages] = useState<PendingImage[]>([]);
  /** How many files are still being decoded/resized, to hold off sending mid-drop. */
  const [attaching, setAttaching] = useState(0);
  const [attachError, setAttachError] = useState<string | null>(null);

  /**
   * Whether the stream is pinned to the newest message.
   *
   * True by default — a fresh reply follows the reader down, exactly like any
   * messaging client. Scrolling up to reread history un-pins it, so a reply
   * arriving mid-scroll cannot yank the view away from what was being read; it
   * banks in `unseen` instead, surfaced by the jump pill below.
   */
  const [stuck, setStuck] = useState(true);
  const [unseen, setUnseen] = useState(0);
  /** Counts messages already accounted for, so only NEW arrivals move the view. */
  const prevLenRef = useRef(0);
  /** First paint jumps instantly; every arrival after that eases in. */
  const mountedRef = useRef(false);

  const messages = history?.messages ?? [];
  const ready = status?.ready === true;

  const scrollToBottom = useCallback((smooth: boolean) => {
    const el = bodyRef.current;
    if (el === null) return;
    el.scrollTo({ top: el.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }, []);

  const onBodyScroll = useCallback(() => {
    const el = bodyRef.current;
    if (el === null) return;
    // 64px of slack: a reader parked exactly at the bottom pixel is rare, and a
    // stray sub-pixel gap from the browser's own rounding must not read as
    // "scrolled away" and start banking replies the reader is still watching.
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 64;
    setStuck(atBottom);
    if (atBottom) setUnseen(0);
  }, []);

  useEffect(() => {
    const delta = messages.length - prevLenRef.current;
    prevLenRef.current = messages.length;
    if (delta <= 0) {
      mountedRef.current = true;
      return;
    }
    if (stuck) scrollToBottom(mountedRef.current);
    else setUnseen((n) => n + delta);
    mountedRef.current = true;
  }, [messages.length, stuck, scrollToBottom]);

  // Switching sessions is a new stream, scrolled to its own bottom instantly —
  // not eased in as if it were a reply arriving in the thread just left.
  useEffect(() => {
    mountedRef.current = false;
    setStuck(true);
    setUnseen(0);
  }, [activeSessionId]);

  // The typing indicator and the growing streamed text are not messages —
  // they never bank into `unseen` — but should still pull the view down while
  // the reader is already following.
  useEffect(() => {
    if ((thinking || live !== null) && stuck) scrollToBottom(true);
  }, [thinking, live, stuck, scrollToBottom]);


  const addFiles = useCallback((files: FileList | File[]) => {
    const picks = Array.from(files).filter((f) => f.type.startsWith("image/"));
    if (picks.length === 0) return;
    setAttachError(null);
    setImages((current) => {
      const room = MAX_IMAGES - current.length;
      if (room <= 0) {
        setAttachError(`最多 ${MAX_IMAGES} 张图`);
        return current;
      }
      const accepted = picks.slice(0, room);
      if (picks.length > accepted.length) setAttachError(`最多 ${MAX_IMAGES} 张图`);
      setAttaching((n) => n + accepted.length);
      for (const file of accepted) {
        resizeImageFile(file)
          .then((resized) => {
            setImages((prev) => [...prev, { ...resized, localId: `${Date.now()}-${Math.random()}` }]);
          })
          .catch(() => setAttachError("这张图片读取失败"))
          .finally(() => setAttaching((n) => n - 1));
      }
      return current;
    });
  }, []);

  const removeImage = (localId: string): void => {
    setImages((current) => current.filter((img) => img.localId !== localId));
  };

  /*
   * Is the composer bound to a parked question, and to which task?
   *
   * `pending` and `bound` are deliberately separate. The answer goes to a task
   * endpoint, not to the secretary, so a bound composer that cannot resolve its
   * task must NOT quietly fall back to sending a chat message — the person would
   * watch their answer become small talk while the agent kept waiting. When the
   * task is gone (answered in another window, or the poll moved it) the pill says
   * so and the send is refused until it is cleared.
   */
  const pending = answer.activeId !== null;
  const bound = pending ? (needsTasks.find((t) => t.id === answer.activeId) ?? null) : null;

  /* Binding moves the cursor here: this composer is now the answer field. */
  useEffect(() => {
    if (bound !== null) inputRef.current?.focus();
  }, [bound]);

  const submit = (text: string = draft): void => {
    const body = text.trim();
    if (sending || attaching > 0) return;

    if (pending) {
      // Bound: the text is an answer to a specific run, and images have nowhere
      // to go — `POST /answer` takes a sentence.
      if (bound === null || body === "") return;
      setDraft("");
      answer.onSubmit(bound, body);
      return;
    }

    if (body === "" && images.length === 0) return;
    const toSend = images;
    setDraft("");
    setImages([]);
    setSending(true);
    onSend(body, toSend).finally(() => setSending(false));
  };

  const activeTitle =
    sessions.find((s) => s.id === activeSessionId)?.title.trim() || "秘书";

  return (
    <aside className="chat">
      <div className="chead">
        <span className="chat-mark" aria-hidden="true" />
        <ChatSessionMenu
          sessions={sessions}
          activeSessionId={activeSessionId}
          activeTitle={activeTitle}
          busySessionIds={busySessionIds}
          onSelect={onSelectSession}
          onCreate={onCreateSession}
          onRename={onRenameSession}
          onArchive={onArchiveSession}
        />
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

      <div className="cbody" ref={bodyRef} onScroll={onBodyScroll}>
        {/*
          Everything parked, above the conversation.

          A LIST, not the one-at-a-time card this replaced. That card showed a single
          task behind a 还有 N 件 button that cycled the rest — so the panel could
          never answer "what is waiting on me", which is the only question it exists
          to answer. With the aggregate 需要你 view gone, this IS the queue.

          Pinned to the top of the stream rather than inline with the messages: it is
          the state of the board, not part of the conversation, and it stays put while
          you scroll back through history.
        */}
        {needsTasks.map((t) => {
          const asking = t.needsKind === "question";
          return (
            <div key={t.id} className={`ctx${asking ? " ask" : ""}`}>
              <div className="k">
                {asking
                  ? "等你回答"
                  : t.needsKind === "blocked"
                    ? "需要修复 · 受阻"
                    : "需要修复 · 失败"}
              </div>
              <div className="t">{t.title}</div>
              {t.needsText !== null && t.needsText !== "" ? <p className="q">{t.needsText}</p> : null}
              <div className="acts">
                {/*
                  Only a question can be answered — the engine 409s anything else,
                  since nobody asked and there is no session to send a reply to.
                  Those take 重派 on the card instead.

                  This binds the composer below rather than opening a second textarea
                  here: one input, already under the cursor.
                */}
                {asking ? (
                  <button type="button" className="yes" onClick={() => answer.onStart(t)}>
                    回答
                  </button>
                ) : null}
                <button
                  type="button"
                  className="no"
                  onClick={() =>
                    onOpenTask({
                      id: t.id,
                      title: t.title,
                      status: t.status,
                      channelId: t.channelId,
                    })
                  }
                >
                  去看看
                </button>
              </div>
            </div>
          );
        })}

        {messages.length === 0 && !thinking && live === null ? (
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
              /* Only the newest row eases in — the rest already played that
                 transition on their own arrival and must not replay it on every
                 unrelated re-render (typing in the composer, e.g.). */
              isLatest={i === messages.length - 1}
            />
          ))
        )}

        {/*
          The in-flight reply. `thinking` alone (no delta yet) is the three dots;
          once `live` has text, it takes over as a growing bubble — the SAME
          markdown renderer real replies use, so the switch to the persisted
          bubble on `chat:message` cannot visibly reflow.
        */}
        {thinking && live === null ? (
          <div className="m a thinking" aria-label="agent 正在处理">
            <i />
            <i />
            <i />
          </div>
        ) : null}
        {live !== null ? (
          <div className="mrow a">
            <div className="m a live" aria-live="polite" aria-label="agent 正在回复">
              <MarkdownLite text={live} />
              <span className="live-caret" aria-hidden="true" />
            </div>
          </div>
        ) : null}

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

        {/*
          Sticky rather than fixed: as the last child of the scrolling column it
          pins to the bottom of the VIEWPORT, not the document, with no width or
          offset math against the composer below it — the trick `position: sticky`
          is for. Only rendered once there is something to report, so it never sits
          over the empty state or a thread nobody has scrolled away from.
        */}
        {!stuck && unseen > 0 ? (
          <button
            type="button"
            className="jump"
            onClick={() => {
              scrollToBottom(true);
              setUnseen(0);
            }}
          >
            <IconArrowDown />
            {unseen > 1 ? `${unseen} 条新消息` : "新消息"}
          </button>
        ) : null}
      </div>

      <div
        className="composer"
        onDragOver={(e) => {
          e.preventDefault();
        }}
        onDrop={(e) => {
          e.preventDefault();
          if (e.dataTransfer.files.length > 0) addFiles(e.dataTransfer.files);
        }}
        onPaste={(e) => {
          const files = Array.from(e.clipboardData.files);
          if (files.length > 0) addFiles(files);
        }}
      >
        {/*
          What this composer is currently answering.

          Visible because the field's behaviour changes underneath it: the next Enter
          goes to a run that is waiting, not to the secretary. A placeholder alone
          would not survive the person typing.
        */}
        {pending ? (
          <div className={`abind${bound === null ? " stale" : ""}`}>
            <span className="k">回答</span>
            <span className="t">{bound?.title ?? "这个任务已经不在等回答了"}</span>
            <button type="button" className="x" aria-label="取消回答" onClick={answer.onCancel}>
              <IconX />
            </button>
          </div>
        ) : null}

        {images.length > 0 || attaching > 0 ? (
          <div className="composer-attachments">
            {images.map((img) => (
              <div key={img.localId} className="composer-thumb">
                <img src={`data:${img.mediaType};base64,${img.data}`} alt="" />
                <button
                  type="button"
                  className="composer-thumb-remove"
                  aria-label="移除这张图片"
                  onClick={() => removeImage(img.localId)}
                >
                  <IconX />
                </button>
              </div>
            ))}
            {/* A placeholder per file still resizing, so a slow decode doesn't read
                as the drop having silently failed. */}
            {Array.from({ length: attaching }).map((_, i) => (
              <div key={`pending-${i}`} className="composer-thumb loading" aria-hidden="true" />
            ))}
          </div>
        ) : null}
        {attachError !== null ? (
          <p className="composer-attach-error" role="alert">
            {attachError}
          </p>
        ) : null}
        <div className={`composer-box${sending ? " busy" : ""}`}>
          <input
            ref={fileInputRef}
            type="file"
            accept="image/png,image/jpeg,image/webp,image/gif"
            multiple
            className="composer-file-input"
            aria-hidden="true"
            tabIndex={-1}
            onChange={(e) => {
              if (e.target.files) addFiles(e.target.files);
              e.target.value = "";
            }}
          />
          <button
            type="button"
            className="composer-attach"
            aria-label="添加图片"
            // No pictures on an answer: `POST /answer` carries a sentence, so an
            // attached image would be silently dropped.
            disabled={sending || pending || images.length >= MAX_IMAGES}
            onClick={() => fileInputRef.current?.click()}
          >
            <IconImage />
          </button>
          <textarea
            ref={inputRef}
            rows={1}
            placeholder={
              bound !== null
                ? "回答它，agent 会接着做"
                : pending
                  ? "这个任务已经不在等回答了"
                  : ready
                    ? "跟秘书说点什么…"
                    : "先配置模型（见上方提示）"
            }
            aria-label={bound !== null ? `回答「${bound.title}」` : "给秘书发送消息"}
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
              // Esc unbinds, matching the card bar this replaced. Only while bound:
              // otherwise it would swallow Esc from anything above it.
              if (e.key === "Escape" && pending) {
                e.preventDefault();
                answer.onCancel();
              }
            }}
            disabled={sending}
          />
          <button
            type="button"
            className="send"
            onClick={() => submit()}
            disabled={
              sending ||
              attaching > 0 ||
              // Bound: a resolvable task and some text. Never falls back to sending
              // the answer to the secretary as chat.
              (pending
                ? bound === null || draft.trim() === ""
                : draft.trim() === "" && images.length === 0)
            }
            aria-label={bound !== null ? "发送回答" : "发送"}
          >
            <IconSend />
          </button>
        </div>
        <div className="composer-hint">
          {pending ? "↩ 发送回答 · ⇧↩ 换行 · esc 取消" : "↩ 发送 · ⇧↩ 换行 · 可拖拽/粘贴图片"}
        </div>
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
  isLatest,
}: {
  message: ChatHistory["messages"][number];
  history: ChatHistory | null;
  onOpenTask: (task: ChatTaskCard) => void;
  daySep: string | null;
  isLatest: boolean;
}) {
  const mine = message.role === "user";
  return (
    <>
      {daySep !== null ? <div className="day-sep">{daySep}</div> : null}
      <div className={`mrow ${mine ? "u" : "a"}${isLatest ? " rise" : ""}`}>
        {message.attachments.length > 0 ? (
          <AttachmentStrip attachments={message.attachments} align={mine ? "u" : "a"} />
        ) : null}
        {/*
          A picture-only message (no text) renders no empty bubble under its
          thumbnails — an empty pill with nothing in it would just be visual
          noise under a picture that already says everything.
        */}
        {message.body !== "" ? (
          <div className={`m ${mine ? "u" : "a"}`}>
            {/*
              Markdown only for the secretary. A person's own text is never
              reinterpreted — their literal `*` or `_id_` should not turn into
              emphasis under them without asking.
            */}
            {mine ? message.body : <MarkdownLite text={message.body} />}
            <CopyButton text={message.body} />
          </div>
        ) : null}
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
 * Thumbnails for a message's attachments, above its text bubble.
 *
 * Full images, not cropped squares: a picture sent to ask "what does this mean"
 * loses exactly the detail the question is about if a thumbnail crops it.
 * Opens the original in a new tab rather than an in-app lightbox — one browser
 * viewer already does pan/zoom/save, and duplicating it here would be a second,
 * worse copy of that same feature.
 */
function AttachmentStrip({ attachments, align }: { attachments: ChatAttachment[]; align: "u" | "a" }) {
  return (
    <div className={`attach-strip ${align}`}>
      {attachments.map((a) => (
        <a key={a.id} href={`${ENGINE}${a.url}`} target="_blank" rel="noreferrer" className="attach-thumb">
          <img src={`${ENGINE}${a.url}`} alt="" loading="lazy" />
        </a>
      ))}
    </div>
  );
}

/**
 * The corner copy action, shown on hover — vercel/chatbot's message toolbar,
 * shrunk to the one action that fits this app's bubble instead of a full row.
 *
 * `copied` is state rather than a CSS `:active` trick because the confirmation
 * has to survive the pointer leaving the bubble — the whole point of switching
 * the glyph to a check is to be visible after the click, not during it.
 */
function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => () => {
    if (timerRef.current !== null) clearTimeout(timerRef.current);
  }, []);

  return (
    <button
      type="button"
      className={`mcopy${copied ? " show" : ""}`}
      aria-label={copied ? "已复制" : "复制这条消息"}
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard
          .writeText(text)
          .then(() => {
            setCopied(true);
            if (timerRef.current !== null) clearTimeout(timerRef.current);
            timerRef.current = setTimeout(() => setCopied(false), 1400);
          })
          .catch(() => undefined);
      }}
    >
      {copied ? <IconCheck /> : <IconCopy />}
    </button>
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
