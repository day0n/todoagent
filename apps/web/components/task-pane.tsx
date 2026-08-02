"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { Task, TaskGroups, TaskStatus, TodoList, ViewKey } from "../lib/types.ts";
import { TASK_STATUS_LABEL } from "../lib/types.ts";
import { visibleGroups } from "../lib/todo-state.ts";
import { IconCaret, IconCheck, IconPlus, IconX } from "./icons.tsx";

/**
 * The middle pane: one view's tasks, grouped.
 *
 * Every mutation is routed out through a callback rather than performed here, so
 * the page owns the optimistic state and this file stays a rendering of it. The
 * one exception is the quick-add draft, which is local by nature.
 */

/** Weekday names, indexed by `Date.getDay()`. */
const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"] as const;

export function TaskPane({
  view,
  title,
  groups,
  lists,
  runtimeCount,
  executorFor,
  loading,
  error,
  onRetry,
  onAdd,
  onToggleDone,
  onRenameTask,
  onDispatch,
  onCancel,
  onDelete,
}: {
  view: ViewKey;
  title: string;
  groups: TaskGroups | null;
  lists: TodoList[];
  runtimeCount: number | null;
  /** Display name for a task's assigned runtime, or null when unresolvable. */
  executorFor: (task: Task) => string | null;
  loading: boolean;
  /**
   * Why the view is empty, when the reason is a failure rather than an absence.
   * Null means the data loaded and the emptiness is real.
   */
  error: string | null;
  onRetry?: () => void;
  onAdd: (title: string) => Promise<void>;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
}) {
  const shown = visibleGroups(groups);
  const repoByList = new Map(lists.map((l) => [l.id, l.repoPath]));

  return (
    <main className="main">
      <div className="main-in">
        <h1>{title}</h1>
        <Subtitle runtimeCount={runtimeCount} />

        <QuickAdd onAdd={onAdd} />

        {shown.map(({ status, tasks }) => (
          <Group
            key={status}
            status={status}
            tasks={tasks}
            repoByList={repoByList}
            executorFor={executorFor}
            onToggleDone={onToggleDone}
            onRenameTask={onRenameTask}
            onDispatch={onDispatch}
            onCancel={onCancel}
            onDelete={onDelete}
          />
        ))}

        {/*
          Nothing on screen has three distinct causes, and saying the wrong one is
          worse than saying nothing:

            still loading  — say nothing, or the empty line flashes on every switch
            failed to load — say THAT; "今天很干净" would assert there is no work
            genuinely empty — the quiet line the design asks for
        */}
        {shown.length === 0 && !loading ? (
          error !== null ? (
            <p className="gempty" role="alert">
              读不到任务：{error}
              {onRetry !== undefined ? (
                <>
                  {" "}
                  <button type="button" className="btn btn-sm" onClick={onRetry}>
                    重试
                  </button>
                </>
              ) : null}
            </p>
          ) : (
            <p className="gempty">
              {EMPTY_LINE[view === "needs" || view === "done" ? view : "other"]}
            </p>
          )
        ) : null}
      </div>
    </main>
  );
}

const EMPTY_LINE = {
  needs: "没有等你的事。",
  done: "还没有完成的任务。",
  other: "今天很干净。",
} as const;

/**
 * Date and standby count.
 *
 * Rendered only after mount: the date is computed from the browser's clock and
 * time zone, and emitting it during SSR would produce a different string on a
 * server in another zone — a hydration mismatch that React resolves by blanking
 * the node.
 */
function Subtitle({ runtimeCount }: { runtimeCount: number | null }) {
  const [today, setToday] = useState<string | null>(null);

  useEffect(() => {
    const d = new Date();
    setToday(`${d.getMonth() + 1}月${d.getDate()}日 星期${WEEKDAYS[d.getDay()]}`);
  }, []);

  return (
    <div className="sub">
      {today ?? " "}
      {today !== null && runtimeCount !== null ? ` · ${runtimeCount} 个 agent 待命` : null}
    </div>
  );
}

/**
 * The add-task row.
 *
 * Collapsed it is a button, which is what makes the whole 54px surface clickable
 * and keyboard-reachable. Open it is an input that stays open after each Enter,
 * so a person can type several tasks without reaching for the mouse again.
 */
function QuickAdd({ onAdd }: { onAdd: (title: string) => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  if (!open) {
    return (
      <button type="button" className="qadd" onClick={() => setOpen(true)}>
        <span className="pl" aria-hidden="true">
          <IconPlus />
        </span>
        添加任务
      </button>
    );
  }

  const commit = (): void => {
    const title = draft.trim();
    if (title === "") return;
    // Cleared immediately rather than after the request settles: the optimistic
    // row is already on screen, and a field that stays full for 200ms invites a
    // second Enter and a duplicate task.
    setDraft("");
    void onAdd(title);
  };

  return (
    <div className="qadd open">
      <span className="pl" aria-hidden="true">
        <IconPlus />
      </span>
      <input
        ref={inputRef}
        value={draft}
        autoFocus
        placeholder="添加任务"
        aria-label="添加任务"
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commit();
          if (e.key === "Escape") {
            setDraft("");
            setOpen(false);
          }
        }}
        onBlur={() => {
          // An empty field that lost focus is just furniture; a half-typed one
          // stays open so a stray click does not discard the text.
          if (draft.trim() === "") setOpen(false);
        }}
      />
    </div>
  );
}

function Group({
  status,
  tasks,
  repoByList,
  executorFor,
  onToggleDone,
  onRenameTask,
  onDispatch,
  onCancel,
  onDelete,
}: {
  status: TaskStatus;
  tasks: Task[];
  repoByList: Map<string, string | null>;
  executorFor: (task: Task) => string | null;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
}) {
  // 已完成 starts collapsed: it grows without bound and is the one group nobody
  // opens the app to read.
  const [open, setOpen] = useState(status !== "done");
  const attention = status === "needs_you";

  const label = (
    <>
      {TASK_STATUS_LABEL[status]} <span className="gn">{tasks.length}</span>
    </>
  );

  return (
    <>
      {status === "done" ? (
        <button
          type="button"
          className="glabel toggle"
          aria-expanded={open}
          onClick={() => setOpen((v) => !v)}
        >
          <IconCaret className="caret" />
          {label}
        </button>
      ) : (
        <div className={`glabel${attention ? " attention" : ""}`}>{label}</div>
      )}

      {open ? (
        <div className={`tgroup${attention ? " priority" : ""}`}>
          {tasks.map((task) => (
            <Row
              key={task.id}
              task={task}
              repoPath={repoByList.get(task.channelId) ?? null}
              executor={executorFor(task)}
              onToggleDone={onToggleDone}
              onRenameTask={onRenameTask}
              onDispatch={onDispatch}
              onCancel={onCancel}
              onDelete={onDelete}
            />
          ))}
        </div>
      ) : null}
    </>
  );
}

function Row({
  task,
  repoPath,
  executor,
  onToggleDone,
  onRenameTask,
  onDispatch,
  onCancel,
  onDelete,
}: {
  task: Task;
  repoPath: string | null;
  executor: string | null;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
}) {
  const done = task.status === "done";
  const running = task.status === "in_progress";
  const needs = task.status === "needs_you";

  /*
   * Inline title editing, opened by double-click.
   *
   * Allowed in every status, including in_progress: the title is a label, and the
   * prompt the agent is working from was sent at dispatch time, so renaming
   * mid-run changes nothing about the execution. That is the opposite of the tick
   * control next to it, which is disabled while running because it WOULD conflict
   * with a live process.
   */
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.title);

  const commitTitle = (): void => {
    setEditing(false);
    onRenameTask(task, draft);
  };

  return (
    <div className={`row${done ? " done" : ""}${needs ? " needs" : ""}`}>
      <button
        type="button"
        className="ring"
        // A live run owns the task; ticking it off would leave a CLI process
        // writing into a task the user believes is finished. Cancel first.
        disabled={running}
        aria-label={done ? `取消完成「${task.title}」` : `完成「${task.title}」`}
        title={running ? "执行中，先取消再改状态" : undefined}
        onClick={() => onToggleDone(task)}
      >
        {done ? <IconCheck /> : null}
      </button>

      <div className="grow">
        {editing ? (
          <input
            className="tt-edit"
            value={draft}
            autoFocus
            aria-label="任务标题"
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commitTitle}
            onKeyDown={(e) => {
              if (e.key === "Enter") commitTitle();
              if (e.key === "Escape") {
                // Discard, and put the draft back so reopening starts clean.
                setDraft(task.title);
                setEditing(false);
              }
            }}
          />
        ) : (
          <div
            className="tt"
            title="双击改标题"
            onDoubleClick={() => {
              // Seeded HERE rather than from initial state: a poll may have
              // changed the title since this row mounted, and editing a stale
              // draft would silently revert someone else's rename.
              setDraft(task.title);
              setEditing(true);
            }}
          >
            {task.title}
          </div>
        )}
        <Subline task={task} executor={executor} />
      </div>

      {repoPath !== null ? <span className="repo">{basename(repoPath)}</span> : null}

      {running ? (
        <span className="st run">
          <i />
          进行中
        </span>
      ) : task.status === "in_review" ? (
        <span className="st">
          <i />
          待确认
        </span>
      ) : null}

      <RowAction
        task={task}
        canDispatch={repoPath !== null}
        onDispatch={onDispatch}
        onCancel={onCancel}
      />

      <button
        type="button"
        className="act ghost"
        aria-label={`删除「${task.title}」`}
        title="删除"
        onClick={() => {
          if (window.confirm(`删除「${task.title}」？`)) onDelete(task);
        }}
      >
        <IconX />
      </button>
    </div>
  );
}

/**
 * The second line under a title.
 *
 * At most one thing, chosen by status: what a person needs to know about this
 * task right now. `note` is the fallback because it is the only one the user
 * wrote themselves.
 */
function Subline({ task, executor }: { task: Task; executor: string | null }) {
  if (task.status === "needs_you") {
    const text = task.needsText ?? NEEDS_FALLBACK[task.needsKind ?? "blocked"];
    return <div className="mm attention">{text}</div>;
  }
  if (task.status === "in_progress") {
    return <div className="mm">{executor ?? "执行中"}</div>;
  }
  if (task.status === "in_review") {
    return <div className="mm">等你确认</div>;
  }
  if (task.note.trim() !== "") return <div className="mm">{task.note}</div>;
  return null;
}

const NEEDS_FALLBACK: Record<string, string> = {
  question: "agent 有个问题等你回答。",
  blocked: "受阻，等你决定。",
  failed: "执行失败，看看日志再决定。",
};

/**
 * The one primary action a row gets, by status.
 *
 * Deliberately at most one: the prototype's row has room for a single pill, and
 * a row offering three competing verbs is a row nobody reads.
 */
function RowAction({
  task,
  canDispatch,
  onDispatch,
  onCancel,
}: {
  task: Task;
  canDispatch: boolean;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
}) {
  if (task.status === "todo") {
    // No repository on the list means no working directory, so there is nothing
    // to dispatch to. Omitted rather than shown disabled: the reason lives on the
    // list, not the task, and a dead button here could not explain itself.
    if (!canDispatch) return null;
    return (
      <button type="button" className="act" onClick={() => onDispatch(task)}>
        派发
      </button>
    );
  }

  if (task.status === "in_progress") {
    return (
      <button
        type="button"
        className="act"
        onClick={() => {
          // Confirmed once: this kills a live CLI process, and whatever it had
          // done so far in the working tree stays there.
          if (window.confirm(`取消执行「${task.title}」？已经改动的文件会留在工作区。`)) {
            onCancel(task);
          }
        }}
      >
        取消
      </button>
    );
  }

  // in_review and needs_you both point at the run. `runId` can be null on a
  // needs_you task that never ran, which is why this is a guard and not a cast.
  if (task.runId === null) return null;

  if (task.status === "in_review") {
    return (
      <Link href={`/runs/${task.runId}`} className="act">
        看结果
      </Link>
    );
  }
  if (task.status === "needs_you") {
    return (
      <Link href={`/runs/${task.runId}`} className="act">
        查看
      </Link>
    );
  }
  return null;
}

/** Last path segment, for the row's repo tag. Trailing slashes tolerated. */
function basename(path: string): string {
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] ?? path;
}
