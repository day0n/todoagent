"use client";

import { useEffect, useRef, useState } from "react";
import type { BoardColumn, BoardResponse, Task, TodoList } from "../lib/types.ts";
import { fmtDuration, isOverdue, isPinnedToday } from "../lib/api.ts";
import { IconCheck, IconPlus, IconToday, IconX } from "./icons.tsx";
import type { AnswerControls, RowOps } from "./task-pane.tsx";

/**
 * The day board: four columns, one card per task.
 *
 * Layout from mockups/opt-h2-sunsama-refined.html. Every mutation is routed out
 * through a callback, so the page owns the optimistic state and this file stays a
 * rendering of it.
 *
 * Class named `tcard`, not `card`: `.card` is a retained atom (`/team`, `/runs`)
 * with its own radius and border, and board rules written for that name would
 * restyle both pages as a side effect. Same collision that renamed `.group` to
 * `.tgroup` in M2.
 *
 * The card is a genuine redesign rather than the old row restyled, and it has to be:
 * that row carried ten controls side by side (tick, title, subline, repo tag, status
 * pill, date field, sun, list picker, action pills, delete) across 724px. At 258px
 * they do not fit, and shrinking them all would produce a column of illegible
 * furniture. So the card shows what a person reads — title, then badges — and the
 * controls appear on hover in their own row beneath. Nothing was dropped; the
 * arrangement changed.
 */

/** Weekday names, indexed by `Date.getDay()`. */
const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"] as const;

/** Column headings. `later` has no date, so it names itself. */
const COLUMN_LABEL: Record<BoardColumn["key"], string> = {
  today: "今天",
  tomorrow: "明天",
  dayAfter: "后天",
  later: "以后",
};

export function BoardPane({
  board,
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
  board: BoardResponse | null;
  lists: TodoList[];
  runtimeCount: number | null;
  executorFor: (task: Task) => string | null;
  loading: boolean;
  /** Why the board is empty, when the reason is a failure rather than an absence. */
  error: string | null;
  onRetry?: () => void;
  /** Creates a task with the column's own date, so it lands where it was typed. */
  onAdd: (title: string, dueDate: string | null, key: BoardColumn["key"]) => Promise<void>;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
  rowOps: RowOps;
}) {
  const repoByList = new Map(lists.map((l) => [l.id, l.repoPath]));
  const nameByList = new Map(lists.map((l) => [l.id, l.name]));

  /** Which column's inline add is open. Only one at a time. */
  const [adding, setAdding] = useState<BoardColumn["key"] | null>(null);
  const addRef = useRef<HTMLInputElement>(null);

  /*
   * `/` and `n` open today's add field.
   *
   * The board has four add fields where the old pane had one, so the shortcut has to
   * choose. Today is the only defensible default: it is the column the view is named
   * after and the one already in front of the user.
   */
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key !== "/" && e.key !== "n") return;
      const el = document.activeElement;
      if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) return;
      if (el instanceof HTMLElement && el.isContentEditable) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      // A dialog owns the keyboard while it is open.
      if (document.querySelector(".drawer") !== null) return;

      // Prevented so `/` does not open Firefox's quick-find and `n` does not type
      // itself into the field about to be focused.
      e.preventDefault();
      setAdding("today");
      // After the state lands, so the input exists to receive focus.
      requestAnimationFrame(() => addRef.current?.focus());
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  return (
    <main className="board">
      <div className="board-top">
        <div className="crumb">今天</div>
        <Subtitle runtimeCount={runtimeCount} />
        <button
          type="button"
          className="add-btn"
          onClick={() => {
            setAdding("today");
            requestAnimationFrame(() => addRef.current?.focus());
          }}
        >
          <IconPlus />
          新建任务
        </button>
      </div>

      {/*
        Three states with three different truths, and saying the wrong one is worse
        than saying nothing:

          still loading  — say nothing, or the message flashes on every switch
          failed to load — say THAT; empty columns would assert there is no work
          genuinely empty — the columns themselves are the answer
      */}
      {board === null && !loading && error !== null ? (
        <p className="gempty" role="alert">
          读不到看板：{error}
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
        <div className="cols">
          {(board?.columns ?? []).map((col) => (
            <Column
              key={col.key}
              col={col}
              repoByList={repoByList}
              nameByList={nameByList}
              executorFor={executorFor}
              adding={adding === col.key}
              addRef={adding === col.key ? addRef : undefined}
              onOpenAdd={() => setAdding(col.key)}
              onCloseAdd={() => setAdding(null)}
              onAdd={onAdd}
              onToggleDone={onToggleDone}
              onRenameTask={onRenameTask}
              onDispatch={onDispatch}
              onCancel={onCancel}
              onDelete={onDelete}
              onOpenResult={onOpenResult}
              answer={answer}
              rowOps={rowOps}
            />
          ))}
        </div>
      )}
    </main>
  );
}

/**
 * Date and standby count, in the top bar.
 *
 * Rendered only after mount: the date comes from the browser's clock and time zone,
 * and emitting it during SSR would produce a different string on a server elsewhere —
 * a hydration mismatch React resolves by blanking the node.
 */
function Subtitle({ runtimeCount }: { runtimeCount: number | null }) {
  const [today, setToday] = useState<string | null>(null);

  useEffect(() => {
    const d = new Date();
    setToday(`${d.getMonth() + 1}月${d.getDate()}日 星期${WEEKDAYS[d.getDay()]}`);
  }, []);

  return (
    <div className="crumb-sub">
      {today ?? " "}
      {today !== null && runtimeCount !== null ? ` · ${runtimeCount} 个 agent 待命` : null}
    </div>
  );
}

function Column({
  col,
  repoByList,
  nameByList,
  executorFor,
  adding,
  addRef,
  onOpenAdd,
  onCloseAdd,
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
  col: BoardColumn;
  repoByList: Map<string, string | null>;
  nameByList: Map<string, string>;
  executorFor: (task: Task) => string | null;
  adding: boolean;
  addRef?: React.RefObject<HTMLInputElement | null>;
  onOpenAdd: () => void;
  onCloseAdd: () => void;
  onAdd: (title: string, dueDate: string | null, key: BoardColumn["key"]) => Promise<void>;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
  rowOps: RowOps;
}) {
  /*
   * Narrowed through a const rather than a boolean flag.
   *
   * `col.weekday !== null` stored in a `dated` variable does not narrow the property
   * for TypeScript — it only knows the boolean. Capturing the value is what makes
   * the index legal, and it is also what makes the two branches obviously exhaustive.
   */
  const weekday = col.weekday;
  const heading = weekday === null ? COLUMN_LABEL[col.key] : `周${WEEKDAYS[weekday]}`;
  const dated = col.date !== null && weekday !== null;
  /*
   * The progress bar is rendered only where it means something.
   *
   * Finishing a task moves it into today, so a future column's `done` is
   * structurally always zero. Three bars sitting at 0% would read as failure rather
   * than "not yet due" — the engine's own comment on this field says the same.
   */
  const showBar = col.key === "today" && col.total > 0;
  const pct = col.total === 0 ? 0 : Math.round((col.done / col.total) * 100);

  return (
    <section className={`col${col.key === "later" ? " faded" : ""}`}>
      <div className="col-head">
        <span className="day">
          {heading}
        </span>
        {col.key === "today" ? <span className="links">{COLUMN_LABEL.today}</span> : null}
      </div>
      <div className="col-date">
        {dated ? formatColDate(col.date) : "没有截止日期，或更远"}
      </div>

      {showBar ? (
        <div
          className="col-bar"
          role="progressbar"
          aria-valuenow={col.done}
          aria-valuemin={0}
          aria-valuemax={col.total}
          aria-label={`今天完成 ${col.done} / ${col.total}`}
        >
          <i style={{ width: `${pct}%` }} />
        </div>
      ) : (
        // A spacer, so the four column headers stay on one baseline whether or not
        // a bar is drawn. Without it the cards in three columns sit 18px higher.
        <div className="col-bar-spacer" aria-hidden="true" />
      )}

      {col.tasks.map((task) => (
        <TaskCard
          key={task.id}
          task={task}
          repoPath={repoByList.get(task.channelId) ?? null}
          listName={nameByList.get(task.channelId) ?? null}
          executor={executorFor(task)}
          onToggleDone={onToggleDone}
          onRenameTask={onRenameTask}
          onDispatch={onDispatch}
          onCancel={onCancel}
          onDelete={onDelete}
          onOpenResult={onOpenResult}
          answer={answer}
          rowOps={rowOps}
        />
      ))}

      {adding ? (
        <InlineAdd
          inputRef={addRef}
          onCancel={onCloseAdd}
          onSubmit={(title) => onAdd(title, col.date, col.key)}
        />
      ) : (
        <button type="button" className="add-task" onClick={onOpenAdd}>
          <span className="p" aria-hidden="true">
            <IconPlus />
          </span>
          添加任务
        </button>
      )}
    </section>
  );
}

/** `8月4日`, from a `YYYY-MM-DD` string. */
function formatColDate(date: string | null): string {
  if (date === null) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (m === null) return date;
  return `${Number(m[2])}月${Number(m[3])}日`;
}

function TaskCard({
  task,
  repoPath,
  listName,
  executor,
  onToggleDone,
  onRenameTask,
  onDispatch,
  onCancel,
  onDelete,
  onOpenResult,
  answer,
  rowOps,
}: {
  task: Task;
  repoPath: string | null;
  listName: string | null;
  executor: string | null;
  onToggleDone: (task: Task) => void;
  onRenameTask: (task: Task, title: string) => void;
  onDispatch: (task: Task) => void;
  onCancel: (task: Task) => void;
  onDelete: (task: Task) => void;
  onOpenResult: (task: Task) => void;
  answer: AnswerControls;
  rowOps: RowOps;
}) {
  const done = task.status === "done";
  const running = task.status === "in_progress";
  const needs = task.status === "needs_you";
  const review = task.status === "in_review";
  const overdue = isOverdue(task.dueDate, task.status);
  const pinned = isPinnedToday(task.myDay);

  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(task.title);

  const commitTitle = (): void => {
    setEditing(false);
    onRenameTask(task, draft);
  };

  return (
    <article
      className={`tcard${needs ? " needs" : ""}${running ? " run" : ""}${done ? " done" : ""}`}
    >
      <div className="tcard-top">
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
                setDraft(task.title);
                setEditing(false);
              }
            }}
          />
        ) : (
          <button
            type="button"
            className="title"
            title="改标题"
            onClick={() => {
              // Seeded HERE rather than from initial state: a poll may have changed
              // the title since this card mounted, and editing a stale draft would
              // silently revert someone else's rename.
              setDraft(task.title);
              setEditing(true);
            }}
          >
            {task.title}
          </button>
        )}
      </div>

      {/*
        The badge row: what this card IS, in one glance.

        One status badge at most, then the context. `需要你` and `运行中` get their
        own colours because they are the two states that change on their own while
        you watch, and one shared accent would make them indistinguishable.
      */}
      <div className="badges">
        {needs ? <span className="badge needs">需要你</span> : null}
        {running ? <span className="badge run">运行中</span> : null}
        {review ? <span className="badge review">待确认</span> : null}

        {/* The agent, when one is involved — the mockup pairs it with 需要你. */}
        {(needs || running) && executor !== null ? (
          <span className="badge agent">{executor}</span>
        ) : null}

        {/* Which list, so a board mixing several stays legible. */}
        {listName !== null && !needs && !running ? (
          <span className="badge">{listName}</span>
        ) : null}

        {task.dueDate !== null && overdue ? <span className="badge late">逾期</span> : null}

        {/*
          Elapsed time on a running card.

          Measured from `updatedAt`, which is stamped when the status became
          in_progress — the task carries no run start of its own. It updates without
          a timer here because a live run polls every four seconds anyway, so the
          re-render arrives for free.
        */}
        {running ? <span className="time">{fmtDuration(task.updatedAt, null)}</span> : null}
      </div>

      {/* The parked question, in full. The card is the only place it fits. */}
      {needs && task.needsText !== null && task.needsText !== "" ? (
        <p className="tcard-q">{task.needsText}</p>
      ) : null}

      {/*
        Controls, revealed on hover or keyboard focus.

        `:focus-within` is not optional: an action that appears only on pointer hover
        is unreachable by keyboard.
      */}
      <div className="tcard-acts">
        <CardAction
          task={task}
          canDispatch={repoPath !== null}
          onDispatch={onDispatch}
          onCancel={onCancel}
          onOpenResult={onOpenResult}
          onStartAnswer={answer.onStart}
        />

        <input
          type="date"
          className={`due${task.dueDate !== null ? " set" : ""}${overdue ? " late" : ""}`}
          value={task.dueDate ?? ""}
          aria-label={task.dueDate === null ? `给「${task.title}」设置截止日期` : "截止日期"}
          title={task.dueDate === null ? "设置截止日期" : "改截止日期"}
          onChange={(e) => rowOps.onSetDue(task, e.target.value === "" ? null : e.target.value)}
        />

        <button
          type="button"
          className={`act ghost sun${pinned ? " on" : ""}`}
          aria-pressed={pinned}
          aria-label={pinned ? `从我的一天移出「${task.title}」` : `加入我的一天：「${task.title}」`}
          title={pinned ? "从我的一天移出" : "加入我的一天"}
          onClick={() => rowOps.onToggleMyDay(task)}
        >
          <IconToday />
        </button>

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

      {answer.activeId === task.id ? (
        <AnswerBar task={task} onSubmit={answer.onSubmit} onCancel={answer.onCancel} />
      ) : null}
    </article>
  );
}

/**
 * The actions a card offers, by status.
 *
 * Same rules the old pane's rows used, and the distinctions matter: offering 重派 on
 * a question would discard the question, and offering 回答 on a failure would open a
 * box for a question nobody asked — which the engine refuses with a 409 rather than
 * trusting the UI to get it right.
 */
function CardAction({
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
    // No repository on the list means no working directory. Omitted rather than
    // shown disabled: the reason lives on the list, and a dead button here could
    // not explain itself.
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
          // Confirmed once: this kills a live CLI process, and whatever it had done
          // so far in the working tree stays there.
          if (window.confirm(`取消执行「${task.title}」？已经改动的文件会留在工作区。`)) {
            onCancel(task);
          }
        }}
      >
        取消
      </button>
    );
  }

  /*
   * A parked card with no run behind it.
   *
   * 查看 cannot be the answer because there is no result to show, and 重派 would be
   * the wrong word for work that never started. Dispatching is what unsticks it.
   */
  if (task.runId === null) {
    if (task.status !== "needs_you" || !canDispatch) return null;
    return (
      <button type="button" className="act" onClick={() => onDispatch(task)}>
        派发
      </button>
    );
  }

  if (task.status === "in_review") {
    return (
      <button type="button" className="act" onClick={() => onOpenResult(task)}>
        看结果
      </button>
    );
  }

  if (task.status === "needs_you") {
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

/** The inline answer field, inside the card that is asking. */
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

/**
 * Per-column add.
 *
 * Stays open after each Enter so several tasks can be typed without reaching for the
 * mouse, matching the old quick-add's behaviour.
 */
function InlineAdd({
  inputRef,
  onSubmit,
  onCancel,
}: {
  inputRef?: React.RefObject<HTMLInputElement | null>;
  onSubmit: (title: string) => Promise<void>;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState("");
  const own = useRef<HTMLInputElement>(null);
  const ref = inputRef ?? own;

  useEffect(() => {
    ref.current?.focus();
  }, [ref]);

  const commit = (): void => {
    const title = draft.trim();
    if (title === "") return;
    // Cleared immediately rather than after the request settles: the optimistic card
    // is already on screen, and a field that stays full invites a duplicate.
    setDraft("");
    void onSubmit(title);
  };

  return (
    <div className="add-task open">
      <span className="p" aria-hidden="true">
        <IconPlus />
      </span>
      <input
        ref={ref}
        value={draft}
        placeholder="任务标题"
        aria-label="添加任务"
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commit();
          if (e.key === "Escape") {
            setDraft("");
            onCancel();
          }
        }}
        onBlur={() => {
          // An empty field that lost focus is furniture; a half-typed one stays open
          // so a stray click does not discard the text.
          if (draft.trim() === "") onCancel();
        }}
      />
    </div>
  );
}
