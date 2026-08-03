"use client";

import { Fragment, useEffect, useRef, useState } from "react";
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
  onOpenResult,
  answer,
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
}: {
  task: Task;
  repoPath: string | null;
  executor: string | null;
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

      <RowAction
        task={task}
        canDispatch={repoPath !== null}
        onDispatch={onDispatch}
        onCancel={onCancel}
        onOpenResult={onOpenResult}
        onStartAnswer={answer.onStart}
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

  // Both remaining states point at a run. `runId` can be null on a needs_you task
  // that never ran, which is why this is a guard and not a cast — a 查看 button
  // there would link at `/runs/null`.
  if (task.runId === null) return null;

  if (task.status === "in_review") {
    return (
      <button type="button" className="act" onClick={() => onOpenResult(task)}>
        看结果
      </button>
    );
  }

  if (task.status === "needs_you") {
    /*
     * A question is answerable; an obstacle or a failure is not.
     *
     * `question` means the agent asked something and is waiting, so 回答 is the
     * primary action and the answer goes back to the run that asked. `blocked` and
     * `failed` share the other shape — nobody asked anything, so the only ways
     * forward are to run it again or to read what happened.
     */
    if (task.needsKind === "question") {
      return (
        <>
          <button type="button" className="act" onClick={() => onStartAnswer(task)}>
            回答
          </button>
          <button type="button" className="act" onClick={() => onOpenResult(task)}>
            查看
          </button>
        </>
      );
    }
    return (
      <>
        {canDispatch ? (
          <button type="button" className="act" onClick={() => onDispatch(task)}>
            重派
          </button>
        ) : null}
        <button type="button" className="act" onClick={() => onOpenResult(task)}>
          查看
        </button>
      </>
    );
  }
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
        placeholder="回答它，agent 会接着做"
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
