"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { TodoList, ViewCounts, ViewKey } from "../lib/types.ts";
import { IconCaret, IconGear, IconMore, IconPlus, IconToday } from "./icons.tsx";

/**
 * The six colours offered when creating a list.
 *
 * A fixed palette rather than a colour picker: the swatch is 8px of sidebar
 * furniture whose only job is to tell two lists apart at a glance, and an
 * arbitrary hex would let a person choose one that vanishes against the surface.
 * `null` is the seventh option — the default graphite.
 */
const PRESET_COLORS = ["#007aff", "#34c759", "#ff9500", "#ff3b30", "#af52de", "#8e8e93"] as const;

/** The default swatch, for a list created without a colour. */
const DEFAULT_SWATCH = "var(--ink-1)";

/** Column headers of the mini calendar, `Date.getDay()`-indexed. */
const DOW = ["日", "一", "二", "三", "四", "五", "六"] as const;

export function Sidebar({
  lists,
  archived,
  counts,
  view,
  onSelect,
  onCreate,
  onRename,
  onBindRepo,
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
  /** Same contract as onCreate's repoPath: rejects with the engine's sentence. Null unbinds. */
  onBindRepo: (id: string, repoPath: string | null) => Promise<void>;
  onArchive: (id: string) => void;
  onRestore: (id: string) => void;
}) {
  const [composing, setComposing] = useState(false);
  const [showArchived, setShowArchived] = useState(false);

  return (
    <nav className="side">
      <div className="side-head">
        <div className="brand">
          <span className="mark" aria-hidden="true" />
          {/* Wrapped so the narrow breakpoint can hide the word and keep the mark.
              A bare text node has no selector. */}
          <span className="t">TodoAgent</span>
        </div>
      </div>

      <div className="side-scroll">
        <MiniCalendar />

        <button
          type="button"
          className={`npill${view === "today" ? " on" : ""}`}
          aria-current={view === "today"}
          onClick={() => onSelect("today")}
        >
          <IconToday />
          <span className="label">我的一天</span>
          {counts.today > 0 ? <span className="count">{counts.today}</span> : null}
        </button>

        <div className="side-label">清单</div>

        {lists.map((list) => (
          <ListRow
            key={list.id}
            list={list}
            active={view === `list:${list.id}`}
            onSelect={() => onSelect(`list:${list.id}`)}
            onRename={(name) => onRename(list.id, name)}
            onBindRepo={(repoPath) => onBindRepo(list.id, repoPath)}
            onArchive={() => onArchive(list.id)}
          />
        ))}

        {composing ? (
          <NewListForm onCancel={() => setComposing(false)} onCreate={onCreate} />
        ) : (
          <button type="button" className="srow add" onClick={() => setComposing(true)}>
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
              className="srow arch-toggle"
              aria-expanded={showArchived}
              onClick={() => setShowArchived((v) => !v)}
            >
              <IconCaret className="caret" />
              <span className="label">已归档</span>
              <span className="count">{archived.length}</span>
            </button>

            {showArchived
              ? archived.map((list) => (
                  <div className="srow arch" key={list.id}>
                    <span className="swatch" style={{ background: list.color ?? DEFAULT_SWATCH }} />
                    <span className="label">{list.name}</span>
                    <button type="button" className="restore" onClick={() => onRestore(list.id)}>
                      恢复
                    </button>
                  </div>
                ))
              : null}
          </>
        ) : null}

        <div className="side-label">状态</div>

        {/*
          The status views.

          需要你 used to be here and is deliberately gone: a parked task is already
          visible wherever its list is, now marked by the dots on that list's row,
          and the conversation is where it gets dealt with. One aggregate entry
          listing the same cards a third time only made the count meaningless —
          「等你回答」and「凭据过期」are not the same errand.

          A cross-list inbox that can RANK parked work is deferred, not rejected.
        */}
        <button
          type="button"
          className={`srow${view === "running" ? " on" : ""}`}
          aria-current={view === "running"}
          onClick={() => onSelect("running")}
        >
          <span className="label">进行中</span>
          {counts.running > 0 ? <span className="count run">{counts.running}</span> : null}
        </button>

        <button
          type="button"
          className={`srow${view === "done" ? " on" : ""}`}
          aria-current={view === "done"}
          onClick={() => onSelect("done")}
        >
          <span className="label">已完成</span>
          {counts.done > 0 ? <span className="count">{counts.done}</span> : null}
        </button>
      </div>

      <div className="side-foot">
        <Link href="/team" className="foot-link" title="Agent 管理">
          <IconGear />
          设置
        </Link>
      </div>
    </nav>
  );
}

/**
 * The current month, with today marked.
 *
 * Display-only by design (V1 takes no date navigation), but not decoration: the
 * three tinted days ARE the board's three dated columns, so the calendar answers
 * "which days am I looking at" rather than merely showing that a month exists.
 *
 * Rendered only after mount, following `Subtitle`'s precedent: the date comes from
 * the browser's clock and time zone, and emitting it during SSR would produce a
 * different grid on a server elsewhere — a hydration mismatch React resolves by
 * blanking the node.
 */
function MiniCalendar() {
  const [now, setNow] = useState<Date | null>(null);
  /** Months away from the current one. Zero is this month. */
  const [offset, setOffset] = useState(0);

  useEffect(() => {
    setNow(new Date());
  }, []);

  if (now === null) {
    // A fixed-height placeholder, so the nav below it does not jump on hydration.
    return <div className="cal" aria-hidden="true" />;
  }

  const shown = new Date(now.getFullYear(), now.getMonth() + offset, 1);
  const year = shown.getFullYear();
  const month = shown.getMonth();

  // Sunday-first, matching the DOW header.
  const lead = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();

  /** Local `YYYY-MM-DD`, the same string the engine buckets against. */
  const iso = (d: Date): string =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const todayIso = iso(now);
  // The board's other two columns. Constructed from calendar parts so month
  // rollover is the platform's problem rather than millisecond arithmetic.
  const boardDays = new Set([
    iso(new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)),
    iso(new Date(now.getFullYear(), now.getMonth(), now.getDate() + 2)),
  ]);

  const cells: Array<{ key: string; day: number; iso: string | null }> = [];
  for (let i = 0; i < lead; i++) {
    const d = new Date(year, month, i - lead + 1);
    cells.push({ key: `lead-${i}`, day: d.getDate(), iso: null });
  }
  for (let d = 1; d <= daysInMonth; d++) {
    cells.push({ key: `d-${d}`, day: d, iso: iso(new Date(year, month, d)) });
  }
  // Fill to a whole week so the grid does not end ragged.
  while (cells.length % 7 !== 0) {
    const i = cells.length - lead - daysInMonth;
    cells.push({ key: `tail-${i}`, day: new Date(year, month + 1, i + 1).getDate(), iso: null });
  }

  return (
    <div className="cal">
      <div className="cal-head">
        <button
          type="button"
          className="arrow"
          aria-label="上一个月"
          onClick={() => setOffset((v) => v - 1)}
        >
          ‹
        </button>
        <span>
          {year}年{month + 1}月
        </span>
        <button
          type="button"
          className="arrow"
          aria-label="下一个月"
          onClick={() => setOffset((v) => v + 1)}
        >
          ›
        </button>
      </div>
      <div className="cal-grid">
        {DOW.map((d) => (
          <span className="dow" key={d}>
            {d}
          </span>
        ))}
        {cells.map((c) => {
          const isToday = c.iso === todayIso;
          const onBoard = c.iso !== null && boardDays.has(c.iso);
          return (
            <span
              key={c.key}
              className={`day${c.iso === null ? " muted" : ""}${isToday ? " today" : ""}${onBoard ? " range" : ""}`}
              aria-current={isToday ? "date" : undefined}
            >
              {c.day}
            </span>
          );
        })}
      </div>
    </div>
  );
}

function ListRow({
  list,
  active,
  onSelect,
  onRename,
  onBindRepo,
  onArchive,
}: {
  list: TodoList;
  active: boolean;
  onSelect: () => void;
  onRename: (name: string) => void;
  onBindRepo: (repoPath: string | null) => Promise<void>;
  onArchive: () => void;
}) {
  const [menu, setMenu] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(list.name);
  const [binding, setBinding] = useState(false);
  const [repoDraft, setRepoDraft] = useState(list.repoPath ?? "");
  const [repoError, setRepoError] = useState<string | null>(null);
  const [repoBusy, setRepoBusy] = useState(false);
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
      <div className="srow">
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

  if (binding) {
    /*
     * Same inline pattern as renaming, but async: the engine validates the path,
     * and a rejected path stays in the field where it gets corrected. Empty means
     * unbind — no separate menu item for an action this rare.
     */
    const commitRepo = (): void => {
      if (repoBusy) return;
      const path = repoDraft.trim() === "" ? null : repoDraft.trim();
      if (path === (list.repoPath ?? null)) {
        setBinding(false);
        return;
      }
      setRepoBusy(true);
      setRepoError(null);
      onBindRepo(path)
        .then(() => {
          setRepoBusy(false);
          setBinding(false);
        })
        .catch((err: unknown) => {
          setRepoBusy(false);
          setRepoError(err instanceof Error ? err.message : String(err));
        });
    };
    return (
      <div className="srow bind">
        <span className="swatch" style={{ background: list.color ?? DEFAULT_SWATCH }} />
        <div className="bindbox">
          <input
            className="rename"
            value={repoDraft}
            autoFocus
            placeholder="仓库路径（留空解绑）"
            aria-label={`「${list.name}」的仓库路径`}
            spellCheck={false}
            disabled={repoBusy}
            onChange={(e) => setRepoDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") commitRepo();
              if (e.key === "Escape") setBinding(false);
            }}
          />
          {repoError !== null ? (
            <p className="err" role="alert">
              {repoError}
            </p>
          ) : null}
        </div>
      </div>
    );
  }

  return (
    <div className={`srow${active ? " on" : ""}`} ref={rowRef}>
      <button
        type="button"
        className="pick"
        onClick={onSelect}
        aria-current={active}
        title={list.repoPath ?? undefined}
      >
        {/*
          The hash is the list marker, per the mockup, and the swatch rides on it —
          the colour is the thing that tells two lists apart at a glance, and it was
          the only marker before. `aria-hidden` because "#" read aloud is noise.
        */}
        <span className="hash" aria-hidden="true" style={{ color: list.color ?? DEFAULT_SWATCH }}>
          #
        </span>
        <span className="label">{list.name}</span>
      </button>

      {/*
        What is parked on this list, one dot per KIND — never a sum.

        This is what replaced the aggregate 需要你 view. That view was a second copy
        of cards already on screen (a parked task outranks its date in `boardColumn`,
        so it always sits in the board's 今天 column), and its single badge added
        「回一句话」to「凭据过期了」— a number you could not act on.

        Attention before volume: these sit left of `openCount`, which counts
        everything open and answers a different question.
      */}
      {list.askingCount > 0 || list.brokenCount > 0 ? (
        <span className="pdots">
          {/* Blue, not red. An agent that asks instead of guessing did the right
              thing; colouring it like a failure would say the opposite. */}
          {list.askingCount > 0 ? (
            <span
              className="dot-badge ask"
              role="img"
              aria-label={`${list.askingCount} 项等你回答`}
              title={`${list.askingCount} 项等你回答`}
            />
          ) : null}
          {/* Warm: the run is dead and something needs fixing. `blocked` and
              `failed` share it — both cost you a detour, not a sentence. */}
          {list.brokenCount > 0 ? (
            <span
              className="dot-badge"
              role="img"
              aria-label={`${list.brokenCount} 项需要修复`}
              title={`${list.brokenCount} 项需要修复`}
            />
          ) : null}
        </span>
      ) : null}

      {list.openCount > 0 ? <span className="count">{list.openCount}</span> : null}

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
              setRepoDraft(list.repoPath ?? "");
              setRepoError(null);
              setBinding(true);
            }}
          >
            {list.repoPath === null ? "绑定仓库…" : "改绑仓库…"}
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
      <p className="err hint">
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
