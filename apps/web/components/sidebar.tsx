"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { TodoList, ViewCounts, ViewKey } from "../lib/types.ts";
import {
  IconCaret,
  IconDone,
  IconGear,
  IconMore,
  IconNeeds,
  IconPlus,
  IconToday,
} from "./icons.tsx";

/**
 * The six colours offered when creating a list.
 *
 * A fixed palette rather than a colour picker: the swatch is 8px of sidebar
 * furniture whose only job is to tell two lists apart at a glance, and an
 * arbitrary hex would let a person choose one that vanishes against the glass.
 * `null` is the seventh option — the default graphite, which is what the
 * prototype shows.
 */
const PRESET_COLORS = ["#007aff", "#34c759", "#ff9500", "#ff3b30", "#af52de", "#8e8e93"] as const;

/**
 * The prototype's default swatch, for a list created without a colour.
 *
 * The token rather than the hex it holds, so the graphite exists in exactly one
 * place. Custom properties resolve in inline styles like anywhere else.
 */
const DEFAULT_SWATCH = "var(--ink-1)";

export function Sidebar({
  lists,
  archived,
  counts,
  view,
  onSelect,
  onCreate,
  onRename,
  onArchive,
  onRestore,
}: {
  lists: TodoList[];
  /** Archived lists, for the restore section. Empty hides that section entirely. */
  archived: TodoList[];
  counts: ViewCounts;
  view: ViewKey;
  onSelect: (view: ViewKey) => void;
  /** Rejects with the engine's message when the repo path is not a git repo. */
  onCreate: (input: { name: string; color: string | null; repoPath: string | null }) => Promise<void>;
  onRename: (id: string, name: string) => void;
  onArchive: (id: string) => void;
  onRestore: (id: string) => void;
}) {
  const [composing, setComposing] = useState(false);
  const [showArchived, setShowArchived] = useState(false);

  return (
    <nav className="side">
      <div className="brand">
        <div className="mark" aria-hidden="true" />
        <div className="t">TodoAgent</div>
      </div>

      <button
        type="button"
        className={`item${view === "today" ? " on" : ""}`}
        onClick={() => onSelect("today")}
        aria-current={view === "today"}
      >
        <IconToday />
        <span className="label">我的一天</span>
        <Count n={counts.today} />
      </button>

      <button
        type="button"
        className={`item${view === "needs" ? " on" : ""}`}
        onClick={() => onSelect("needs")}
        aria-current={view === "needs"}
      >
        <IconNeeds />
        <span className="label">需要你</span>
        {/* Hot only when there is something: a blue "0" would demand attention
            for the one state that has none. */}
        {counts.needs > 0 ? (
          <span className="n hot" aria-label={`${counts.needs} 项需要你`}>
            {counts.needs}
          </span>
        ) : null}
      </button>

      <button
        type="button"
        className={`item${view === "done" ? " on" : ""}`}
        onClick={() => onSelect("done")}
        aria-current={view === "done"}
      >
        <IconDone />
        <span className="label">已完成</span>
        <Count n={counts.done} />
      </button>

      <div className="side-scroll">
        <div className="side-label">清单</div>

        {lists.map((list) => (
          <ListRow
            key={list.id}
            list={list}
            active={view === `list:${list.id}`}
            onSelect={() => onSelect(`list:${list.id}`)}
            onRename={(name) => onRename(list.id, name)}
            onArchive={() => onArchive(list.id)}
          />
        ))}

        {composing ? (
          <NewListForm onCancel={() => setComposing(false)} onCreate={onCreate} />
        ) : (
          <button type="button" className="item" onClick={() => setComposing(true)}>
            <IconPlus />
            <span className="label">新建清单</span>
          </button>
        )}

        {/*
          Archived lists, collapsed, and absent entirely when there are none.
          Without this, archiving was one-way in the UI: the engine accepts
          `{archived:false}` but nothing could name a list you can no longer see.
        */}
        {archived.length > 0 ? (
          <>
            <button
              type="button"
              className="item arch-toggle"
              aria-expanded={showArchived}
              onClick={() => setShowArchived((v) => !v)}
            >
              <IconCaret className="caret" />
              <span className="label">已归档</span>
              <span className="n">{archived.length}</span>
            </button>

            {showArchived
              ? archived.map((list) => (
                  <div className="item arch" key={list.id}>
                    <span
                      className="swatch"
                      style={{ background: list.color ?? DEFAULT_SWATCH }}
                    />
                    <span className="label">{list.name}</span>
                    <button
                      type="button"
                      className="restore"
                      onClick={() => onRestore(list.id)}
                    >
                      恢复
                    </button>
                  </div>
                ))
              : null}
          </>
        ) : null}
      </div>

      <div className="side-foot">
        <div className="avatar" aria-hidden="true">
          N
        </div>
        <div className="name">Niko</div>
        <Link href="/team" className="gear" title="Agent 管理" aria-label="Agent 管理">
          <IconGear />
        </Link>
      </div>
    </nav>
  );
}

/** A plain count. Zero renders nothing rather than a "0" that reads as broken. */
function Count({ n }: { n: number }) {
  if (n <= 0) return null;
  return <span className="n">{n}</span>;
}

function ListRow({
  list,
  active,
  onSelect,
  onRename,
  onArchive,
}: {
  list: TodoList;
  active: boolean;
  onSelect: () => void;
  onRename: (name: string) => void;
  onArchive: () => void;
}) {
  const [menu, setMenu] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(list.name);
  const rowRef = useRef<HTMLDivElement>(null);

  // Dismiss the menu on an outside click or Escape. Without this it survives
  // until the next click on the trigger itself, which reads as stuck.
  useEffect(() => {
    if (!menu) return;
    const onDown = (e: MouseEvent): void => {
      if (!rowRef.current?.contains(e.target as Node)) setMenu(false);
    };
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setMenu(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [menu]);

  const commit = (): void => {
    const name = draft.trim();
    setRenaming(false);
    if (name !== "" && name !== list.name) onRename(name);
    else setDraft(list.name);
  };

  if (renaming) {
    return (
      <div className="item">
        <span className="swatch" style={{ background: list.color ?? DEFAULT_SWATCH }} />
        <input
          className="rename"
          value={draft}
          autoFocus
          aria-label="清单名"
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit();
            if (e.key === "Escape") {
              setDraft(list.name);
              setRenaming(false);
            }
          }}
        />
      </div>
    );
  }

  return (
    <div className={`item${active ? " on" : ""}`} ref={rowRef}>
      <button
        type="button"
        className="pick"
        onClick={onSelect}
        aria-current={active}
        title={list.repoPath ?? undefined}
      >
        <span className="swatch" style={{ background: list.color ?? DEFAULT_SWATCH }} />
        <span className="label">{list.name}</span>
      </button>

      <Count n={list.openCount} />

      <button
        type="button"
        className="more"
        data-open={menu}
        aria-label={`${list.name} 的操作`}
        aria-expanded={menu}
        onClick={() => setMenu((v) => !v)}
      >
        <IconMore />
      </button>

      {menu ? (
        <div className="lmenu" role="menu">
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setMenu(false);
              setDraft(list.name);
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
              // Confirmed once: archiving hides a list and every task on it. The
              // tasks survive, but nothing in this UI can bring the list back.
              if (window.confirm(`归档「${list.name}」？任务会保留，清单从侧栏移除。`)) {
                onArchive();
              }
            }}
          >
            归档
          </button>
        </div>
      ) : null}
    </div>
  );
}

function NewListForm({
  onCancel,
  onCreate,
}: {
  onCancel: () => void;
  onCreate: (input: { name: string; color: string | null; repoPath: string | null }) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [repoPath, setRepoPath] = useState("");
  const [color, setColor] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (): Promise<void> => {
    if (name.trim() === "" || busy) return;
    setBusy(true);
    setError(null);
    try {
      await onCreate({
        name: name.trim(),
        color,
        repoPath: repoPath.trim() === "" ? null : repoPath.trim(),
      });
      onCancel();
    } catch (err) {
      // Shown in place rather than as a toast: the path that was rejected is
      // still in the field above, which is where it gets corrected.
      setError(err instanceof Error ? err.message : String(err));
      setBusy(false);
    }
  };

  return (
    <div className="nlform">
      <input
        value={name}
        autoFocus
        placeholder="清单名"
        aria-label="清单名"
        onChange={(e) => setName(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") void submit();
          if (e.key === "Escape") onCancel();
        }}
      />
      <input
        value={repoPath}
        placeholder="仓库路径（可选）"
        aria-label="仓库路径（可选）"
        spellCheck={false}
        onChange={(e) => setRepoPath(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") void submit();
          if (e.key === "Escape") onCancel();
        }}
      />

      <div className="dots" role="group" aria-label="色点">
        {PRESET_COLORS.map((c) => (
          <button
            key={c}
            type="button"
            className="dot"
            style={{ color: c }}
            aria-label={c}
            aria-pressed={color === c}
            onClick={() => setColor((cur) => (cur === c ? null : c))}
          >
            <i />
          </button>
        ))}
      </div>

      {/* A path is what makes the list's tasks dispatchable, so the consequence of
          leaving it empty is stated rather than implied. */}
      <p className="err" style={{ color: "var(--ink-3)" }}>
        {repoPath.trim() === "" ? "不绑仓库：纯待办，不能派发。" : "任务可以派发到这个仓库。"}
      </p>

      {error !== null ? (
        <p className="err" role="alert">
          {error}
        </p>
      ) : null}

      <div className="acts">
        <button
          type="button"
          className="btn btn-primary btn-sm"
          disabled={busy || name.trim() === ""}
          onClick={() => void submit()}
        >
          {busy ? "创建中" : "创建"}
        </button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>
          取消
        </button>
      </div>
    </div>
  );
}

export { DEFAULT_SWATCH };
