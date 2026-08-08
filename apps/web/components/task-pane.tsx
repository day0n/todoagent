"use client";

import Link from "next/link";
import { Fragment, useEffect, useRef, useState } from "react";
import type { Task, TaskGroups, TaskStatus, TodoList, ViewKey } from "../lib/types.ts";
import { TASK_STATUS_LABEL } from "../lib/types.ts";
import { visibleGroups } from "../lib/todo-state.ts";
import { dueLabel, isOverdue, isPinnedToday } from "../lib/api.ts";
import { IconCaret, IconCheck, IconPlus, IconToday, IconX } from "./icons.tsx";
import { ConfirmButton, SelectMenu } from "./overlays.tsx";

/**
 * The middle pane: one view's tasks, grouped.
 *
 * Every mutation is routed out through a callback rather than performed here, so
 * the page owns the optimistic state and this file stays a rendering of it. The
 * one exception is the quick-add draft, which is local by nature.
 */

/** Weekday names, indexed by `Date.getDay()`. */
const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"] as const;

/**
 * Everything the answer bar needs, as one prop.
 *
 * Bundled rather than threaded as four separate props through three component
 * levels — and, more importantly, `activeId` lives in the page rather than in each
 * row: the drawer's 回答 button opens the same bar, so exactly one place gets to
 * decide which row is currently asking.
 */
export interface AnswerControls {
  /** Which task's answer bar is open, if any. */
  activeId: string | null;
  onStart: (task: Task) => void;
  onSubmit: (task: Task, answer: string) => void;
  onCancel: () => void;
}

/**
 * Per-row operations that are not status changes.
 *
 * Bundled for the same reason as `AnswerControls`: threading two more callbacks
 * through three component levels adds noise at every one of them.
 */
export interface RowOps {
  /** Moves the task to another list. The engine refuses unknown or archived ones. */
  onMove: (task: Task, listId: string) => void;
  /** Pins to 我的一天, or unpins. */
  onToggleMyDay: (task: Task) => void;
  /** Sets the deadline, or clears it with null. `YYYY-MM-DD`. */
  onSetDue: (task: Task, dueDate: string | null) => void;
}

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
  onOpenResult,
  answer,
  rowOps,
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
  /** Opens the result drawer for a finished or failed task. */
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
  rowOps: RowOps;
}) {
  const shown = visibleGroups(groups);
  const repoByList = new Map(lists.map((l) => [l.id, l.repoPath]));

  /*
   * Quick-add's open state lives HERE, not inside `QuickAdd`.
   *
   * The `/` and `n` shortcuts have to be able to open it, and a keydown listener
   * cannot reach into a child's private state. The input ref is lifted for the same
   * reason: `autoFocus` only fires on mount, so pressing `/` while the field is
   * already open but unfocused would otherwise do nothing.
   */
  const [addOpen, setAddOpen] = useState(false);
  const addInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key !== "/" && e.key !== "n") return;
      // Never steal a keystroke from a field. `isContentEditable` covers the case
      // no tag check does, and the answer bar is a textarea.
      const el = document.activeElement;
      if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) return;
      if (el instanceof HTMLElement && el.isContentEditable) return;
      // A modifier means the user is reaching for a browser or OS command.
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      // A dialog owns the keyboard while it is open.
      if (document.querySelector('[role="dialog"]') !== null) return;

      // Prevented so `/` does not open Firefox's quick-find and `n` does not type
      // itself into the field we are about to focus.
      e.preventDefault();
      setAddOpen(true);
      addInputRef.current?.focus();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  return (
    <main className="main">
      <div className="main-in">
        <h1>{title}</h1>
        <Subtitle runtimeCount={runtimeCount} />

        <QuickAdd onAdd={onAdd} open={addOpen} setOpen={setAddOpen} inputRef={addInputRef} />

        {shown.map(({ status, tasks }) => (
          <Group
            key={status}
            status={status}
            tasks={tasks}
            lists={lists}
            rowOps={rowOps}
            repoByList={repoByList}
            executorFor={executorFor}
            onToggleDone={onToggleDone}
            onRenameTask={onRenameTask}
            onDispatch={onDispatch}
            onCancel={onCancel}
            onDelete={onDelete}
            onOpenResult={onOpenResult}
            answer={answer}
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
              {
                EMPTY_LINE[
                  // Every status view names itself; `other` covers 我的一天 and the
                  // list views, whose emptiness is about today rather than a status.
                  // A view missing from this guard silently renders the wrong line.
                  view === "tasks" || view === "needs" || view === "running" || view === "done" ? view : "other"
                ]
              }
            </p>
          )
        ) : null}
      </div>
    </main>
  );
}

const EMPTY_LINE = {
  tasks: "还没有任务。",
  needs: "没有等你的事。",
  running: "现在没有本机 CLI 在执行。",
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
      {today !== null && runtimeCount !== null ? ` · ${runtimeCount} 个 CLI 可用` : null}
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
function QuickAdd({
  onAdd,
  open,
  setOpen,
  inputRef,
}: {
  onAdd: (title: string) => Promise<void>;
  /** Owned by the pane so the `/` and `n` shortcuts can open it. */
  open: boolean;
  setOpen: (open: boolean) => void;
  inputRef: React.RefObject<HTMLInputElement | null>;
}) {
  const [draft, setDraft] = useState("");

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
  onOpenResult,
  answer,
  rowOps,
  lists,
}: {
  status: TaskStatus;
  tasks: Task[];
  lists: TodoList[];
  rowOps: RowOps;
  repoByList: Map<string, string | null>;
  executorFor: (task: Task) => string | null;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
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
            /*
             * The answer bar is a SIBLING of the row, not a child.
             *
             * `.row` is a flex container with centred items, so a bar rendered inside
             * it would sit in the same line as the tick and the action pills rather
             * than below them. Rendered here rather than inside `Row` for the same
             * reason the active id lives in the page: one place decides.
             */
            <Fragment key={task.id}>
            <Row
              task={task}
              repoPath={repoByList.get(task.channelId) ?? null}
              executor={executorFor(task)}
              onToggleDone={onToggleDone}
              onRenameTask={onRenameTask}
              onDispatch={onDispatch}
              onCancel={onCancel}
              onDelete={onDelete}
              onOpenResult={onOpenResult}
              answer={answer}
              rowOps={rowOps}
              lists={lists}
            />
            {answer.activeId === task.id ? (
              <AnswerBar task={task} onSubmit={answer.onSubmit} onCancel={answer.onCancel} />
            ) : null}
            </Fragment>
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
  onOpenResult,
  answer,
  rowOps,
  lists,
}: {
  task: Task;
  repoPath: string | null;
  executor: string | null;
  lists: TodoList[];
  rowOps: RowOps;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
}) {
  const done = task.status === "done";
  const running = task.status === "in_progress";
  const needs = task.status === "needs_you";
  /*
   * Computed per render rather than stored.
   *
   * `myDay` is a date, not a flag, so "pinned" is a question about today — and a pin
   * from yesterday is stale. The engine already stops counting it toward 我的一天 at
   * midnight, and the sun has to agree or the row claims a membership it no longer has.
   */
  const pinned = isPinnedToday(task.myDay);
  /*
   * Both derived per render, like `pinned`, because both are questions about TODAY.
   *
   * A deadline is a stored date; whether it is late changes at midnight with nothing
   * writing to the row. Computing it here means the answer cannot go stale in state.
   */
  const overdue = isOverdue(task.dueDate, task.status);
  const dueText = task.dueDate === null ? "" : dueLabel(task.dueDate);

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
          /*
           * A real `<button>`, not a div carrying a double-click handler.
           *
           * Double-click has no keyboard equivalent, so renaming was pointer-only,
           * and a plain div announces neither a role nor that it does anything. A
           * button gets Enter and Space from the platform and needs no ARIA at all.
           *
           * Single click now opens the field, which is what Reminders and Things do
           * and is more discoverable than a double-click nothing advertises.
           */
          <button
            type="button"
            className="tt"
            title="改标题"
            onClick={() => {
              // Seeded HERE rather than from initial state: a poll may have
              // changed the title since this row mounted, and editing a stale
              // draft would silently revert someone else's rename.
              setDraft(task.title);
              setEditing(true);
            }}
          >
            {task.title}
          </button>
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

      {/*
        Deadline.

        A native `<input type="date">`: no dependency, a real calendar picker on
        every platform, keyboard-operable, and it enforces the `YYYY-MM-DD` shape
        the engine's regex demands rather than trusting typed text.

        Hover-revealed while empty, permanently visible once set — a deadline is
        information, not an action, so a row carrying one has to say so at a glance.
        Red when overdue; `isOverdue` returns false for a done task, so a finished
        row does not stay alarming forever.
      */}
      <input
        type="date"
        className={`due${task.dueDate !== null ? " set" : ""}${overdue ? " late" : ""}`}
        value={task.dueDate ?? ""}
        aria-label={
          task.dueDate === null ? `给「${task.title}」设置截止日期` : `截止日期：${dueText}`
        }
        title={task.dueDate === null ? "设置截止日期" : dueText}
        onChange={(e) => {
          // An empty value is the picker's own clear button, which is the only way
          // to remove a deadline — so it maps to null rather than being ignored.
          rowOps.onSetDue(task, e.target.value === "" ? null : e.target.value);
        }}
      />

      {/*
        Pin to 我的一天.

        A toggle rather than a menu item because it is the one row operation people
        use repeatedly. Stays lit once pinned — see `.act.sun.on` — so the row says
        what it is without being hovered; `isPinnedToday` treats yesterday's pin as
        unpinned, matching the engine, which stops counting it at midnight.
      */}
      <button
        type="button"
        className={`act ghost sun${pinned ? " on" : ""}`}
        aria-pressed={pinned}
        aria-label={pinned ? `从今天移出「${task.title}」` : `加入今天：「${task.title}」`}
        title={pinned ? "从今天移出" : "加入今天"}
        onClick={() => rowOps.onToggleMyDay(task)}
      >
        <IconToday />
      </button>

      {lists.length > 0 && (!lists.some((list) => list.id === task.channelId) || lists.length > 1) ? (
        <SelectMenu
          className="move"
          value={task.channelId}
          ariaLabel={`移动「${task.title}」到别的清单`}
          options={[
            ...(!lists.some((list) => list.id === task.channelId) ? [{ value: task.channelId, label: "任务（未加入清单）" }] : []),
            ...lists.map((list) => ({ value: list.id, label: list.name })),
          ]}
          onChange={(next) => { if (next !== task.channelId) rowOps.onMove(task, next); }}
        />
      ) : null}

      <RowAction
        task={task}
        canDispatch={repoPath !== null}
        onDispatch={onDispatch}
        onCancel={onCancel}
        onOpenResult={onOpenResult}
        onStartAnswer={answer.onStart}
      />

      <ConfirmButton
        className="act ghost"
        ariaLabel={`删除「${task.title}」`}
        title="删除"
        heading={`删除「${task.title}」？`}
        description="任务及其对话记录会被永久删除，这个操作无法撤销。"
        confirmLabel="删除任务"
        onConfirm={() => onDelete(task)}
      >
        <IconX />
      </ConfirmButton>
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
  question: "本机 CLI 有个问题等你回答。",
  reply: "本轮回复完成，等你继续对话。",
  blocked: "受阻，等你决定。",
  failed: "执行失败，看看日志再决定。",
};

/**
 * The actions a row offers, by status.
 *
 * One pill for most statuses, two for every 需要你 row — the thing you almost always
 * want, plus the thing you need first if you don't. Which pair depends on why it is
 * parked, and the distinction is the point:
 *
 *   question  回答 + 查看   the agent asked something; replying is the way forward
 *   blocked   重派 + 查看   nothing was asked, so there is nothing to reply to
 *   failed    重派 + 查看   same shape: run it again, or read what happened
 *
 * Offering 重派 on a question would discard the question, and offering 回答 on a
 * failure would open a box for a question nobody asked — which is why the engine
 * refuses that call with a 409 rather than trusting the UI to get it right.
 */
function RowAction({
  task,
  canDispatch,
  onDispatch,
  onCancel,
  onOpenResult,
  onStartAnswer,
}: {
  task: Task;
  canDispatch: boolean;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  onStartAnswer: (task: Task) => void;
}) {
  if (task.status === "todo") {
    return <Link href={`/tasks/${task.id}`} className="act">开始对话</Link>;
  }

  if (task.status === "in_progress") {
    return (
      <>
        <Link href={`/tasks/${task.id}`} className="act">查看对话</Link>
        <ConfirmButton
          className="act ghost"
          heading={`取消执行「${task.title}」？`}
          description="CLI 会停止，但已经写入工作目录的文件改动会保留。"
          confirmLabel="停止执行"
          onConfirm={() => onCancel(task)}
        >取消</ConfirmButton>
      </>
    );
  }
  if (task.status === "needs_you" || task.status === "in_review") {
    return <Link href={`/tasks/${task.id}`} className="act">继续对话</Link>;
  }
  void canDispatch;
  void onDispatch;
  void onOpenResult;
  void onStartAnswer;
  return null;
}

/**
 * The inline answer bar, below the row that is asking.
 *
 * In the flow rather than in a dialog: the question is one line of text and the
 * answer is usually one sentence, so a modal would be more furniture than the
 * exchange deserves — and the row above stays readable while typing, which is where
 * the question is.
 */
function AnswerBar({
  task,
  onSubmit,
  onCancel,
}: {
  task: Task;
  onSubmit: (task: Task, answer: string) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState("");
  const ref = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    ref.current?.focus();
  }, []);

  const commit = (): void => {
    const answer = draft.trim();
    // An empty answer would be refused by the engine anyway, and sending it would
    // replace the question with a toast for no reason.
    if (answer === "") return;
    onSubmit(task, answer);
  };

  return (
    <div className="abar">
      {task.needsText !== null && task.needsText !== "" ? (
        <p className="aq">{task.needsText}</p>
      ) : null}
      <textarea
        ref={ref}
        className="ain"
        value={draft}
        rows={2}
        placeholder="回答后，CLI 会接着做"
        aria-label={`回答「${task.title}」`}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          // Enter sends, Shift+Enter breaks a line: the messaging convention, and
          // the answer is usually one sentence.
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            commit();
          }
          if (e.key === "Escape") onCancel();
        }}
      />
      <div className="aacts">
        <button
          type="button"
          className="btn btn-primary btn-sm"
          disabled={draft.trim() === ""}
          onClick={commit}
        >
          发送
        </button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>
          取消
        </button>
      </div>
    </div>
  );
}

/** Last path segment, for the row's repo tag. Trailing slashes tolerated. */
function basename(path: string): string {
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] ?? path;
}
