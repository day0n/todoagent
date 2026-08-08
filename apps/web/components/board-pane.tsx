"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { AnimatePresence, LayoutGroup, motion } from "motion/react";
import type { BoardColumn, BoardResponse, Task, TodoList } from "../lib/types.ts";
import { fmtDuration, isOverdue, isPinnedToday, localDayIso } from "../lib/api.ts";
import { IconCheck, IconPlus, IconToday, IconX } from "./icons.tsx";
import { ConfirmButton } from "./overlays.tsx";
import { AnimatedText } from "./animated-text.tsx";
import { GlowingEffect } from "./glowing-effect.tsx";
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
  const boardTasks = board?.columns.flatMap((column) => column.tasks) ?? [];
  const boardStats = {
    needs: boardTasks.filter((task) => task.status === "needs_you").length,
    running: boardTasks.filter((task) => task.status === "in_progress").length,
    review: boardTasks.filter((task) => task.status === "in_review").length,
    done: boardTasks.filter((task) => task.status === "done").length,
    total: boardTasks.length,
  };
  const isTodayBoard = board !== null && board.today === localDayIso();

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
      if (document.querySelector('[role="dialog"]') !== null) return;

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
        <div className="board-head-copy">
          <div className="crumb">时间线</div>
          <Subtitle date={board?.today ?? null} runtimeCount={runtimeCount} />
        </div>
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

      <BoardOverview stats={boardStats} runtimeCount={runtimeCount} />

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
        <LayoutGroup id={`timeline-${board?.today ?? "loading"}`}>
          <div className="cols">
            {(board?.columns ?? []).map((col) => (
              <Column
                key={col.key}
                col={col}
                isTodayBoard={isTodayBoard}
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
        </LayoutGroup>
      )}
    </main>
  );
}

function BoardOverview({
  stats,
  runtimeCount,
}: {
  stats: { needs: number; running: number; review: number; done: number; total: number };
  runtimeCount: number | null;
}) {
  const headline =
    stats.needs > 0
      ? `${stats.needs} 件任务正在等你决定`
      : stats.review > 0
        ? `${stats.review} 项成果等待你的确认`
        : stats.running > 0
          ? `${stats.running} 个本机 CLI 正在推进任务`
          : stats.total > 0
            ? "选一件事，选择本机 CLI 开始推进"
            : "今天从一件值得完成的事开始";

  return (
    <section className="board-overview" aria-label="今日工作概览">
      <div className="overview-lead">
        <div className="overview-kicker">
          <span className="pulse-dot" aria-hidden="true" />
          本机 CLI 工作台
        </div>
        <h1>
          <AnimatedText>{headline}</AnimatedText>
        </h1>
        <p>
          {stats.running > 0
            ? "任务会持续推进，只有需要判断时才会回来找你。"
            : "派发后可以离开这里，TodoAgent 会在关键节点通知你。"}
        </p>
      </div>

      <div className="overview-stats" aria-label="任务状态">
        <OverviewStat tone="warn" label="需要你" value={stats.needs} />
        <OverviewStat tone="live" label="执行中" value={stats.running} />
        <OverviewStat tone="ok" label="待确认" value={stats.review} />
      </div>

      <div className="runtime-ready">
        <span className="ready-dot" aria-hidden="true" />
        {runtimeCount === null ? "正在检查本机 CLI" : `${runtimeCount} 个 CLI 已验证可用`}
      </div>
    </section>
  );
}

function OverviewStat({
  tone,
  label,
  value,
}: {
  tone: "warn" | "live" | "ok";
  label: string;
  value: number;
}) {
  return (
    <div className={`overview-stat ${tone}`}>
      <span>{label}</span>
      <strong>
        <AnimatedText variant="number" animation="snappy">
          {value}
        </AnimatedText>
      </strong>
    </div>
  );
}

/**
 * Date and standby count, in the top bar.
 *
 * Rendered only after mount: the date comes from the browser's clock and time zone,
 * and emitting it during SSR would produce a different string on a server elsewhere —
 * a hydration mismatch React resolves by blanking the node.
 */
function Subtitle({ date, runtimeCount }: { date: string | null; runtimeCount: number | null }) {
  const selected = date === null ? null : new Date(`${date}T12:00:00`);
  const label =
    selected === null
      ? " "
      : `${selected.getMonth() + 1}月${selected.getDate()}日 星期${WEEKDAYS[selected.getDay()]}`;

  return (
    <div className="crumb-sub">
      {label}
      {selected !== null && runtimeCount !== null ? ` · ${runtimeCount} 个 CLI 可用` : null}
    </div>
  );
}

function Column({
  col,
  isTodayBoard,
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
  isTodayBoard: boolean;
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
        {col.key === "today" ? (
          <span className="links">{isTodayBoard ? COLUMN_LABEL.today : "所选"}</span>
        ) : null}
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
          aria-label={`${isTodayBoard ? "今天" : "所选日期"}完成 ${col.done} / ${col.total}`}
        >
          <i style={{ width: `${pct}%` }} />
        </div>
      ) : (
        // A spacer, so the four column headers stay on one baseline whether or not
        // a bar is drawn. Without it the cards in three columns sit 18px higher.
        <div className="col-bar-spacer" aria-hidden="true" />
      )}

      <AnimatePresence initial={false} mode="popLayout">
        {col.tasks.map((task) => (
          <motion.div
            key={task.id}
            layout="position"
            layoutId={`timeline-task-${task.id}`}
            className="tcard-motion"
            initial={{ opacity: 0, y: 6, scale: 0.985 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -4, scale: 0.985 }}
            transition={{ duration: 0.22, ease: [0.2, 0.8, 0.2, 1] }}
          >
            <TaskCard
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
          </motion.div>
        ))}
      </AnimatePresence>

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
      className={`tcard${needs ? " needs" : ""}${running ? " run" : ""}${review ? " review" : ""}${done ? " done" : ""}`}
    >
      <GlowingEffect active={running || needs || review} />
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

      <TaskStatusLine task={task} executor={executor} />

      {/*
        The badge row: what this card IS, in one glance.

        One status badge at most, then the context. `需要你` and `运行中` get their
        own colours because they are the two states that change on their own while
        you watch, and one shared accent would make them indistinguishable.
      */}
      <div className="badges">
        {/* Which list, so a board mixing several stays legible. */}
        {listName !== null ? <span className="badge">{listName}</span> : null}

        {task.dueDate !== null && overdue ? <span className="badge late">逾期</span> : null}
      </div>

      {!needs && task.note.trim() !== "" ? <p className="tcard-note">{task.note}</p> : null}

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
          aria-label={pinned ? `从今天移出「${task.title}」` : `加入今天：「${task.title}」`}
          title={pinned ? "从今天移出" : "加入今天"}
          onClick={() => rowOps.onToggleMyDay(task)}
        >
          <IconToday />
        </button>

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

      {answer.activeId === task.id ? (
        <AnswerBar task={task} onSubmit={answer.onSubmit} onCancel={answer.onCancel} />
      ) : null}
    </article>
  );
}

function TaskStatusLine({ task, executor }: { task: Task; executor: string | null }) {
  const status =
    task.status === "needs_you"
      ? { tone: "warn", label: "等待你的回答" }
      : task.status === "in_progress"
        ? { tone: "live", label: executor === null ? "本机 CLI 正在执行" : `${executor} 正在执行` }
        : task.status === "in_review"
          ? { tone: "ok", label: "执行完成，等待确认" }
          : task.status === "done"
            ? { tone: "done", label: "已完成" }
            : { tone: "idle", label: "等待派发" };

  return (
    <div className={`tcard-status ${status.tone}`}>
      <span className="status-dot" aria-hidden="true" />
      <span>{status.label}</span>
      {task.status === "in_progress" ? (
        <time>{fmtDuration(task.updatedAt, null)}</time>
      ) : null}
    </div>
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
