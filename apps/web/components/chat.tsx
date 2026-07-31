"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { findMentions, segmentBody } from "@council/core/mentions";
import { api, ApiError, fmtRelative } from "../lib/api.ts";
import type { Channel, Expert, Message, MessageWithThread } from "../lib/types.ts";
import { Empty, ErrorBox, RuntimeMark, Spinner } from "./atoms.tsx";

/**
 * A channel's message stream.
 *
 * Chat is the workspace: this is where work is requested, discussed and handed
 * off, rather than in a form that submits a job. Two things carry that:
 *
 *   - The stream shows thread ROOTS only. An agent working a task posts many
 *     turns, and letting those into the main stream would bury everything else —
 *     so a thread collapses to a reply count you open on purpose.
 *   - The composer's "作为任务" toggle creates a board card from the message in
 *     the same action, so a request never has to be restated as a task by hand.
 *
 * New messages arrive by polling. The engine's SSE stream is per-RUN, keyed to
 * a pipeline's event log, and reusing it here would mean inventing a second
 * meaning for a channel that has no run yet. Polling is honest about what this
 * is: a local tool talking to a process on the same machine.
 */

/** How often to re-read the stream while the tab is visible. */
const POLL_MS = 4000;

/** A message the user has sent that the engine has not acknowledged yet. */
interface Pending {
  key: string;
  body: string;
  asTask: boolean;
  failed: boolean;
}

export function Chat({
  channel,
  experts,
  onTaskCreated,
}: {
  channel: Channel;
  experts: Expert[];
  /** Lets the tab strip update its task count without refetching the board. */
  onTaskCreated?: () => void;
}) {
  const [messages, setMessages] = useState<MessageWithThread[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending[]>([]);
  const [openThread, setOpenThread] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const res = await api.messages(channel.id);
      setMessages(res.messages);
      setError(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    }
  }, [channel.id]);

  useEffect(() => {
    setMessages(null);
    setPending([]);
    setOpenThread(null);
    void load();
  }, [load]);

  /*
   * Polling pauses when the tab is hidden.
   *
   * A background tab hammering the engine every four seconds for a stream nobody
   * is looking at is pure waste, and the visibility listener also forces an
   * immediate refresh on return — which is exactly when the stream is most
   * likely to be stale.
   */
  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;

    const start = (): void => {
      if (timer !== null) return;
      timer = setInterval(() => void load(), POLL_MS);
    };
    const stop = (): void => {
      if (timer === null) return;
      clearInterval(timer);
      timer = null;
    };
    const onVisibility = (): void => {
      if (document.hidden) stop();
      else {
        void load();
        start();
      }
    };

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [load]);

  const send = useCallback(
    async (body: string, asTask: boolean) => {
      const key = `${body} ${String(performance.now())}`;
      // Rendered immediately with a visible pending state rather than optimistically
      // merged into the stream: a failed send has to stay on screen so it can be
      // retried, and silently dropping what someone typed is the worst outcome here.
      setPending((p) => [...p, { key, body, asTask, failed: false }]);
      try {
        const res = await api.postMessage(channel.id, { body, asTask });
        setPending((p) => p.filter((x) => x.key !== key));
        await load();
        if (res.task !== null) onTaskCreated?.();
      } catch (err) {
        setPending((p) => p.map((x) => (x.key === key ? { ...x, failed: true } : x)));
        setError(err instanceof ApiError ? err.message : String(err));
      }
    },
    [channel.id, load, onTaskCreated],
  );

  const retry = useCallback(
    (key: string) => {
      const item = pending.find((x) => x.key === key);
      if (!item) return;
      setPending((p) => p.filter((x) => x.key !== key));
      void send(item.body, item.asTask);
    },
    [pending, send],
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <Stream
        channel={channel}
        experts={experts}
        messages={messages}
        pending={pending}
        error={error}
        openThread={openThread}
        onOpenThread={setOpenThread}
        onRetry={retry}
        onReload={() => void load()}
      />
      <Composer channel={channel} experts={experts} onSend={send} />
    </div>
  );
}

function Stream({
  channel,
  experts,
  messages,
  pending,
  error,
  openThread,
  onOpenThread,
  onRetry,
  onReload,
}: {
  channel: Channel;
  experts: Expert[];
  messages: MessageWithThread[] | null;
  pending: Pending[];
  error: string | null;
  openThread: string | null;
  onOpenThread: (id: string | null) => void;
  onRetry: (key: string) => void;
  onReload: () => void;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);

  /*
   * Auto-scroll only when already at the bottom.
   *
   * Yanking the viewport down while someone is reading back through history is
   * the classic chat-client bug, and it is worse here than usual: an agent can
   * post a burst of turns while the user is looking at something earlier.
   */
  useEffect(() => {
    const el = scroller.current;
    if (!el || !atBottom.current) return;
    el.scrollTop = el.scrollHeight;
  }, [messages, pending]);

  const onScroll = (): void => {
    const el = scroller.current;
    if (!el) return;
    atBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  return (
    <div ref={scroller} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto w-full max-w-3xl px-4 py-6">
        {error !== null ? (
          <div className="mb-4">
            <ErrorBox message={error} onRetry={onReload} />
          </div>
        ) : null}

        {messages === null ? (
          <div className="py-10 text-center">
            <Spinner label="读取消息" />
          </div>
        ) : messages.length === 0 && pending.length === 0 ? (
          <Empty
            title={channel.kind === "dm" ? "还没有对话" : `#${channel.name} 还没有消息`}
            hint={
              channel.kind === "dm"
                ? "像对同事那样直接说，半成形的想法也可以。"
                : "说你想做什么。勾上「作为任务」就同时建一张卡。"
            }
          />
        ) : (
          <ol className="space-y-5">
            {messages.map((m) => (
              <li key={m.id}>
                <Row
                  message={m}
                  experts={experts}
                  threadOpen={openThread === m.id}
                  onToggleThread={() => onOpenThread(openThread === m.id ? null : m.id)}
                />
              </li>
            ))}
            {pending.map((p) => (
              <li key={p.key}>
                <PendingRow item={p} experts={experts} onRetry={() => onRetry(p.key)} />
              </li>
            ))}
          </ol>
        )}
      </div>
    </div>
  );
}

/** Resolves an author to a display name, or null for the local human. */
function authorOf(message: Message, experts: Expert[]): Expert | null {
  if (message.authorKind !== "expert" || message.authorId === null) return null;
  return experts.find((e) => e.id === message.authorId) ?? null;
}

/**
 * A message body with its mentions marked.
 *
 * Uses the engine's own parser rather than a regex of its own. That is the whole
 * point of `mentions.ts` being dependency-free: a second implementation here
 * would drift, and the failure would be a name shown as a mention that the router
 * does not actually route to — which is invisible until nobody answers.
 *
 * Only mentions of a KNOWN expert are marked, so `@nobody` renders as the plain
 * text it behaves as.
 */
function Body({ text, experts, className }: { text: string; experts: Expert[]; className: string }) {
  const segments = useMemo(() => segmentBody(text, experts), [text, experts]);

  return (
    <p className={className}>
      {segments.map((seg, i) =>
        seg.kind === "mention" ? (
          <span
            // eslint-disable-next-line react/no-array-index-key -- segments are positional
            key={i}
            className="rounded-[3px] px-0.5 font-medium"
            style={{ background: "var(--color-accent-soft)", color: "var(--color-accent)" }}
          >
            {seg.text}
          </span>
        ) : (
          // eslint-disable-next-line react/no-array-index-key -- segments are positional
          <span key={i}>{seg.text}</span>
        ),
      )}
    </p>
  );
}

function Row({
  message,
  experts,
  threadOpen,
  onToggleThread,
}: {
  message: MessageWithThread;
  experts: Expert[];
  threadOpen: boolean;
  onToggleThread: () => void;
}) {
  const expert = authorOf(message, experts);

  return (
    <div className="group">
      <div className="flex items-baseline gap-2">
        {expert ? (
          <RuntimeMark kind={expert.runtimeKind} name={expert.name} />
        ) : (
          <span className="inline-flex items-center gap-1.5">
            <span
              aria-hidden
              className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] bg-muted text-[9px] font-semibold text-muted-fg"
            >
              你
            </span>
            <span className="text-[0.8125rem] font-medium">你</span>
          </span>
        )}
        <time className="t-meta" dateTime={message.createdAt} title={message.createdAt}>
          {fmtRelative(message.createdAt)}
        </time>
        {/*
          An agent author is labelled with the runtime it actually ran on. These
          are local CLIs from different vendors, and which one said something is
          load-bearing information — not a decorative badge.
        */}
        {expert ? <span className="t-meta">{expert.runtimeKind}</span> : null}
      </div>

      <Body
        text={message.body}
        experts={experts}
        className="mt-1 break-anywhere whitespace-pre-wrap"
      />

      {message.replyCount > 0 ? (
        <button
          type="button"
          onClick={onToggleThread}
          className="mt-1.5 inline-flex items-center gap-1.5 text-[0.8125rem] font-medium text-accent hover:underline"
          aria-expanded={threadOpen}
        >
          {message.replyCount} 条回复
          {message.lastReplyAt !== null ? (
            <span className="t-meta font-normal">· {fmtRelative(message.lastReplyAt)}</span>
          ) : null}
          <span aria-hidden>{threadOpen ? "▾" : "›"}</span>
        </button>
      ) : null}

      {threadOpen ? <Thread rootId={message.id} experts={experts} /> : null}
    </div>
  );
}

function PendingRow({
  item,
  experts,
  onRetry,
}: {
  item: Pending;
  experts: Expert[];
  onRetry: () => void;
}) {
  return (
    <div className={item.failed ? "" : "opacity-60"}>
      <div className="flex items-baseline gap-2">
        <span className="inline-flex items-center gap-1.5">
          <span
            aria-hidden
            className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] bg-muted text-[9px] font-semibold text-muted-fg"
          >
            你
          </span>
          <span className="text-[0.8125rem] font-medium">你</span>
        </span>
        <span className="t-meta">{item.failed ? "发送失败" : "发送中…"}</span>
        {item.asTask ? <span className="tag">任务</span> : null}
      </div>
      {/* Same rendering as an acknowledged message, so nothing shifts or
          re-highlights when the engine confirms it. */}
      <Body
        text={item.body}
        experts={experts}
        className="mt-1 break-anywhere whitespace-pre-wrap"
      />
      {item.failed ? (
        <button type="button" className="btn btn-sm mt-1.5" onClick={onRetry}>
          重试
        </button>
      ) : null}
    </div>
  );
}

/**
 * One thread's replies, fetched when opened.
 *
 * Loaded on demand rather than with the stream: a channel's threads together can
 * hold far more text than the channel itself, and almost all of it is never read.
 */
function Thread({ rootId, experts }: { rootId: string; experts: Expert[] }) {
  const [replies, setReplies] = useState<Message[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setReplies(null);
    setError(null);
    api
      .replies(rootId)
      .then((res) => {
        if (live) setReplies(res.replies);
      })
      .catch((err: unknown) => {
        if (live) setError(err instanceof ApiError ? err.message : String(err));
      });
    return () => {
      live = false;
    };
  }, [rootId]);

  return (
    <div className="mt-2.5 border-l-2 border-line pl-3.5">
      {error !== null ? (
        <ErrorBox message={error} />
      ) : replies === null ? (
        <Spinner label="读取回复" />
      ) : (
        <ol className="space-y-3.5">
          {replies.map((r) => {
            const expert = authorOf(r, experts);
            return (
              <li key={r.id}>
                <div className="flex items-baseline gap-2">
                  {expert ? (
                    <RuntimeMark kind={expert.runtimeKind} name={expert.name} />
                  ) : (
                    <span className="text-[0.8125rem] font-medium">你</span>
                  )}
                  <time className="t-meta" dateTime={r.createdAt}>
                    {fmtRelative(r.createdAt)}
                  </time>
                </div>
                <Body
                  text={r.body}
                  experts={experts}
                  className="mt-0.5 break-anywhere whitespace-pre-wrap"
                />
              </li>
            );
          })}
        </ol>
      )}
    </div>
  );
}

function Composer({
  channel,
  experts,
  onSend,
}: {
  channel: Channel;
  experts: Expert[];
  onSend: (body: string, asTask: boolean) => void;
}) {
  const [text, setText] = useState("");
  const [asTask, setAsTask] = useState(false);
  const box = useRef<HTMLTextAreaElement>(null);

  /*
   * Who this message will actually reach.
   *
   * Computed with the ENGINE's parser, so what is shown here is what the router
   * will do — not a second opinion from a regex that happens to live in the
   * browser.
   *
   * This exists because the routing rule fails silently in the one direction that
   * matters: a channel message with no recognised mention is answered by NOBODY,
   * so a typo'd name produces no reply, no error, and nothing to look at. A DM
   * always reaches its agent, so it needs no such warning.
   */
  const mentioned = useMemo(
    () => findMentions(text, experts).map((m) => m.name),
    [text, experts],
  );
  const unaddressed = channel.kind === "channel" && text.trim().length > 0 && mentioned.length === 0;

  const submit = (): void => {
    const body = text.trim();
    if (body.length === 0) return;
    onSend(body, asTask);
    setText("");
    // The toggle resets: "as task" is a property of one message, and leaving it
    // on would silently turn every subsequent line into a card.
    setAsTask(false);
    box.current?.focus();
  };

  return (
    <div className="shrink-0 border-t border-line bg-bg px-4 py-3">
      <div className="mx-auto w-full max-w-3xl">
        <div className="card overflow-hidden focus-within:border-accent">
          <textarea
            ref={box}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              // Enter sends, Shift+Enter breaks the line — the chat convention.
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                submit();
              }
            }}
            rows={2}
            placeholder={
              channel.kind === "dm" ? `发消息给 ${channel.name}` : `发送消息至 #${channel.name}`
            }
            className="block max-h-48 min-h-[3.25rem] w-full resize-y bg-transparent px-3 py-2.5 outline-none placeholder:text-subtle-fg"
            aria-label="消息内容"
          />

          <div className="flex items-center gap-2 border-t border-line px-2.5 py-1.5">
            <label className="inline-flex cursor-pointer select-none items-center gap-1.5 text-[0.8125rem]">
              <input
                type="checkbox"
                checked={asTask}
                onChange={(e) => setAsTask(e.target.checked)}
                className="h-3.5 w-3.5 accent-accent"
              />
              作为任务
            </label>

            {/*
              Said plainly rather than left to fail: a channel with no repository
              can hold a card, but nothing can execute it.
            */}
            {asTask && channel.projectId === null ? (
              <span className="t-meta">此频道未关联仓库，任务无法执行</span>
            ) : null}

            {/*
              Both directions are shown, because the positive case is what makes a
              typo visible: naming @Atals produces no "将回复" line, which is the
              only signal available before sending. Silence afterwards looks
              identical to an agent still thinking.
            */}
            {unaddressed ? (
              <span className="t-meta">没有 @ 任何人，不会有 agent 回复</span>
            ) : mentioned.length > 0 ? (
              <span className="t-meta">将回复：{mentioned.join("、")}</span>
            ) : null}

            <div className="ml-auto flex items-center gap-2">
              <kbd className="t-meta hidden sm:block">↵ 发送</kbd>
              <button
                type="button"
                className="btn btn-primary btn-sm"
                onClick={submit}
                disabled={text.trim().length === 0}
              >
                发送
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
