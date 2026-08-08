"use client";

import { useEffect, useRef, useState } from "react";
import type { ChatSession } from "../lib/types.ts";
import { fmtRelative } from "../lib/api.ts";
import { IconCaret, IconMore, IconPlus } from "./icons.tsx";
import { AnimatedText } from "./animated-text.tsx";

/**
 * The header's session switcher: click "秘书" to see every open conversation.
 *
 * A dropdown rather than a permanent list — the mockups this app is built from
 * give the whole right column to the message stream, and a person holds far
 * fewer live conversations than tasks, so a rail costing space on every screen
 * would be furniture for something checked once in a while. Same reasoning as
 * the sidebar's list switcher, minus the always-visible rail.
 */
export function ChatSessionMenu({
  sessions,
  activeSessionId,
  activeTitle,
  /** Threads whose turn is currently streaming, for the small live dot. */
  busySessionIds,
  onSelect,
  onCreate,
  onRename,
  onArchive,
}: {
  sessions: ChatSession[];
  activeSessionId: string | null;
  /** What the trigger shows for the active thread — a resolved fallback, not raw `title`. */
  activeTitle: string;
  busySessionIds: ReadonlySet<string>;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onRename: (id: string, title: string) => void;
  onArchive: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  // Same dismissal contract as the sidebar's list menu: an outside click or
  // Escape closes it, or it sits open until the trigger is clicked again.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent): void => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // Newest activity first — the thread someone just left mid-conversation is
  // the one they are most likely to come back to.
  const sorted = [...sessions].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));

  return (
    <div className="chat-switcher" ref={rootRef}>
      <button
        type="button"
        className="chead-id chat-switcher-trigger"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <div className="chead-id-text">
          <div className="name">
            <AnimatedText>{activeTitle}</AnimatedText>
            <IconCaret className="chat-switcher-caret" />
          </div>
          <div className="sub">{sessions.length > 1 ? `${sessions.length} 个会话` : "秘书"}</div>
        </div>
      </button>

      {open ? (
        <div className="chat-switcher-panel" role="menu">
          <button
            type="button"
            className="chat-switcher-new"
            role="menuitem"
            onClick={() => {
              setOpen(false);
              onCreate();
            }}
          >
            <IconPlus />
            新对话
          </button>
          <div className="chat-switcher-list">
            {sorted.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                active={s.id === activeSessionId}
                busy={busySessionIds.has(s.id)}
                onSelect={() => {
                  setOpen(false);
                  onSelect(s.id);
                }}
                onRename={(title) => onRename(s.id, title)}
                onArchive={() => onArchive(s.id)}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  );
}

function SessionRow({
  session,
  active,
  busy,
  onSelect,
  onRename,
  onArchive,
}: {
  session: ChatSession;
  active: boolean;
  /** This thread's turn is streaming right now, in a background tab or not. */
  busy: boolean;
  onSelect: () => void;
  onRename: (title: string) => void;
  onArchive: () => void;
}) {
  const [menu, setMenu] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(session.title);
  const rowRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menu) return;
    const onDown = (e: MouseEvent): void => {
      if (!rowRef.current?.contains(e.target as Node)) setMenu(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [menu]);

  const commit = (): void => {
    const title = draft.trim();
    setRenaming(false);
    if (title !== "" && title !== session.title) onRename(title);
    else setDraft(session.title);
  };

  const label = session.title.trim() !== "" ? session.title : `会话 · ${fmtRelative(session.createdAt)}`;

  if (renaming) {
    return (
      <div className="chat-switcher-row">
        <input
          className="chat-switcher-rename"
          value={draft}
          autoFocus
          aria-label="会话标题"
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit();
            if (e.key === "Escape") {
              setDraft(session.title);
              setRenaming(false);
            }
          }}
        />
      </div>
    );
  }

  return (
    <div className={`chat-switcher-row${active ? " on" : ""}`} ref={rowRef}>
      <button type="button" className="pick" role="menuitem" onClick={onSelect}>
        {busy ? <span className="busy-dot" aria-label="正在回复" /> : null}
        <span className="label">{label}</span>
        <span className="when">{fmtRelative(session.updatedAt)}</span>
      </button>
      <button
        type="button"
        className="more"
        data-open={menu}
        aria-label={`「${label}」的操作`}
        aria-expanded={menu}
        onClick={() => setMenu((v) => !v)}
      >
        <IconMore />
      </button>
      {menu ? (
        <div className="chat-switcher-rowmenu" role="menu">
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setMenu(false);
              setDraft(session.title);
              setRenaming(true);
            }}
          >
            重命名
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setMenu(false);
              onArchive();
            }}
          >
            归档
          </button>
        </div>
      ) : null}
    </div>
  );
}
