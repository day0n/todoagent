"use client";

import { useEffect, useRef } from "react";
import type { ChatMessage } from "../lib/types.ts";
import { IconSend } from "./icons.tsx";

/**
 * The right pane: the main agent's conversation.
 *
 * Read-only in M2. The composer is rendered and disabled rather than omitted,
 * because this pane IS the product's promise — "say a thing, it becomes a task" —
 * and an empty column would not say so. Posting arrives with M4, once the main
 * agent has credentials; the endpoint that would receive it does not exist yet.
 *
 * Hidden entirely below 1050px by the stylesheet: at that width the task list is
 * the working surface and this is the first thing that can go.
 */
export function ChatPane({
  messages,
  runtimeNames,
}: {
  messages: ChatMessage[] | null;
  /** Detected local CLIs, e.g. ["codex", "claude"]. */
  runtimeNames: string[];
}) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const count = messages?.length ?? 0;

  // Pinned to the newest message, like any messaging client. Harmless while the
  // history is empty, and correct the moment M4 starts appending to it.
  useEffect(() => {
    const el = bodyRef.current;
    if (el !== null) el.scrollTop = el.scrollHeight;
  }, [count]);

  return (
    <aside className="chat">
      <div className="chead">
        <div className="face" aria-hidden="true" />
        <div className="t">
          <i />
          Agent
        </div>
        {/* The runtimes actually installed on this machine. Honest about zero:
            without a CLI there is nothing to dispatch to. */}
        <div className="s">
          {runtimeNames.length > 0 ? runtimeNames.join(" · ") : "未检测到 CLI"}
        </div>
      </div>

      <div className="cbody" ref={bodyRef}>
        {count === 0 ? (
          <p className="cempty">和 agent 说件事，它会变成任务</p>
        ) : (
          (messages ?? []).map((m) => (
            <div key={m.id} className={`m ${m.role === "user" ? "u" : "a"}`}>
              {m.body}
            </div>
          ))
        )}
      </div>

      <div className="cinput-wrap">
        <div className="cinput off">
          <input
            placeholder="主 agent 即将上线"
            aria-label="给 Agent 发送消息"
            disabled
          />
          <button type="button" className="send" disabled aria-label="发送">
            <IconSend />
          </button>
        </div>
      </div>
    </aside>
  );
}
