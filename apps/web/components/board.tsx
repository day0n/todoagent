"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api, ApiError, fmtRelative } from "../lib/api.ts";
import { TASK_STATUS_LABEL, TASK_STATUSES } from "../lib/types.ts";
import type { ActorKind, Channel, Expert, Task, TaskStatus } from "../lib/types.ts";
import { Empty, ErrorBox, RuntimeMark, Spinner } from "./atoms.tsx";

/**
 * A channel's task board.
 *
 * Cards come from two places — the composer's "作为任务" toggle and this view's
 * own dialog — and an agent claims one itself as readily as a person assigns it.
 * That is why assignment is polymorphic here rather than a user picker with
 * agents bolted on.
 *
 * Moving a card is optimistic. The four states are local to the board, the user
 * stays on this screen, failure is rare, and rollback is a single field — so the
 * column updates immediately and reverts if the engine refuses.
 */

/** Board or flat list. A long backlog is easier to scan as rows than columns. */
type View = "board" | "list";

export function Board({ channel, experts }: { channel: Channel; experts: Expert[] }) {
  const [tasks, setTasks] = useState<Task[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<View>("board");
  const [creating, setCreating] = useState(false);
  const [creator, setCreator] = useState<string>("all");
  const [assignee, setAssignee] = useState<string>("all");

  const load = useCallback(async () => {
    try {
      const res = await api.tasks(channel.id);
      setTasks(res.tasks);
      setError(null);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    }
  }, [channel.id]);

  useEffect(() => {
    setTasks(null);
    void load();
  }, [load]);

  /**
   * Applies a patch locally first, then persists it.
   *
   * The revert restores the whole previous array rather than the single field:
   * concurrent moves would otherwise resurrect a stale sibling.
   */
  const patch = useCallback(
    async (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => {
      const before = tasks;
      setTasks((cur) => cur?.map((t) => (t.id === id ? { ...t, ...next } : t)) ?? cur);
      try {
        await api.patchTask(id, {
          ...(next.status !== undefined ? { status: next.status } : {}),
          ...(next.assigneeKind !== undefined
            ? {
                assignee:
                  next.assigneeKind === null
                    ? null
                    : { kind: next.assigneeKind, id: next.assigneeId ?? null },
              }
            : {}),
        });
      } catch (err) {
        setTasks(before);
        setError(err instanceof ApiError ? err.message : String(err));
      }
    },
    [tasks],
  );

  const filtered = useMemo(() => {
    if (tasks === null) return null;
    return tasks.filter((t) => {
      if (creator !== "all" && actorKey(t.creatorKind, t.creatorId) !== creator) return false;
      if (assignee !== "all" && actorKey(t.assigneeKind, t.assigneeId) !== assignee) return false;
      return true;
    });
  }, [tasks, creator, assignee]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* ── Toolbar ── */}
      <div className="flex flex-wrap items-center gap-2 border-b border-line px-4 py-2.5">
        <ActorFilter
          label="创建者"
          value={creator}
          onChange={setCreator}
          experts={experts}
          tasks={tasks}
          pick={(t) => actorKey(t.creatorKind, t.creatorId)}
        />
        <ActorFilter
          label="负责人"
          value={assignee}
          onChange={setAssignee}
          experts={experts}
          tasks={tasks}
          pick={(t) => actorKey(t.assigneeKind, t.assigneeId)}
          includeUnassigned
        />
        <button type="button" className="btn btn-primary btn-sm" onClick={() => setCreating(true)}>
          + 新建任务
        </button>

        <div className="ml-auto flex items-center gap-1">
          {(["board", "list"] as const).map((v) => (
            <button
              key={v}
              type="button"
              className={`btn btn-sm ${view === v ? "" : "btn-ghost"}`}
              onClick={() => setView(v)}
              aria-pressed={view === v}
            >
              {v === "board" ? "看板" : "列表"}
            </button>
          ))}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-auto p-4">
        {error !== null ? (
          <div className="mb-4">
            <ErrorBox message={error} onRetry={() => void load()} />
          </div>
        ) : null}

        {filtered === null ? (
          <div className="py-10 text-center">
            <Spinner label="读取任务" />
          </div>
        ) : tasks !== null && tasks.length === 0 ? (
          <Empty
            title="暂无任务"
            hint="用「新建任务」建一张卡，或在聊天里勾选「作为任务」。"
          />
        ) : view === "board" ? (
          <BoardView tasks={filtered} experts={experts} onPatch={patch} />
        ) : (
          <ListView tasks={filtered} experts={experts} onPatch={patch} />
        )}
      </div>

      {creating ? (
        <CreateDialog
          channelId={channel.id}
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            void load();
          }}
        />
      ) : null}
    </div>
  );
}

/** Stable identity for an actor, used as a filter key. */
function actorKey(kind: ActorKind | null, id: string | null): string {
  if (kind === null) return "none";
  return kind === "expert" && id !== null ? `expert:${id}` : "human";
}

function actorLabel(kind: ActorKind | null, id: string | null, experts: Expert[]): string {
  if (kind === null) return "未分配";
  if (kind === "human") return "你";
  return experts.find((e) => e.id === id)?.name ?? "未知 agent";
}

function ActorFilter({
  label,
  value,
  onChange,
  experts,
  tasks,
  pick,
  includeUnassigned = false,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  experts: Expert[];
  tasks: Task[] | null;
  /** Which side of the task this filter reads, so counts match reality. */
  pick: (t: Task) => string;
  includeUnassigned?: boolean;
}) {
  /*
   * Only actors that actually appear are offered.
   *
   * Listing all six agents when one has touched anything makes the filter look
   * broken — every extra option selects nothing.
   */
  const present = useMemo(() => new Set((tasks ?? []).map(pick)), [tasks, pick]);

  return (
    <label className="inline-flex items-center gap-1.5">
      <span className="t-meta">{label}</span>
      <select
        className="field btn-sm w-auto py-0"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        <option value="all">全部</option>
        {includeUnassigned && present.has("none") ? <option value="none">未分配</option> : null}
        {present.has("human") ? <option value="human">你</option> : null}
        {experts
          .filter((e) => present.has(`expert:${e.id}`))
          .map((e) => (
            <option key={e.id} value={`expert:${e.id}`}>
              {e.name}
            </option>
          ))}
      </select>
    </label>
  );
}

function BoardView({
  tasks,
  experts,
  onPatch,
}: {
  tasks: Task[];
  experts: Expert[];
  onPatch: (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => void;
}) {
  const [dragOver, setDragOver] = useState<TaskStatus | null>(null);

  return (
    <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      {TASK_STATUSES.map((status) => {
        const column = tasks.filter((t) => t.status === status);
        return (
          <section
            key={status}
            // Native HTML5 drag-and-drop rather than a library: dragging cards
            // between four fixed columns needs no collision detection or virtual
            // list, and every card also carries a status menu, so the pointer
            // gesture is an accelerator rather than the only way to move work.
            onDragOver={(e) => {
              e.preventDefault();
              setDragOver(status);
            }}
            onDragLeave={() => setDragOver((s) => (s === status ? null : s))}
            onDrop={(e) => {
              e.preventDefault();
              setDragOver(null);
              const id = e.dataTransfer.getData("text/council-task");
              if (id !== "") onPatch(id, { status });
            }}
            className={`flex min-h-32 flex-col rounded-[var(--radius)] border p-2 transition-colors ${
              dragOver === status ? "border-accent bg-accent-soft" : "border-line bg-surface"
            }`}
            aria-label={TASK_STATUS_LABEL[status]}
          >
            <h3 className="t-label mb-2 flex items-center gap-1.5 px-1">
              {TASK_STATUS_LABEL[status]}
              {column.length > 0 ? (
                <span className="font-normal text-subtle-fg">{column.length}</span>
              ) : null}
            </h3>
            <ol className="space-y-2">
              {column.map((t) => (
                <li key={t.id}>
                  <Card task={t} experts={experts} onPatch={onPatch} />
                </li>
              ))}
            </ol>
          </section>
        );
      })}
    </div>
  );
}

function Card({
  task,
  experts,
  onPatch,
}: {
  task: Task;
  experts: Expert[];
  onPatch: (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => void;
}) {
  return (
    <article
      draggable
      onDragStart={(e) => {
        // A private type, so dropping a card onto an unrelated target elsewhere
        // cannot be mistaken for plain text.
        e.dataTransfer.setData("text/council-task", task.id);
        e.dataTransfer.effectAllowed = "move";
      }}
      className="card cursor-grab p-2.5 active:cursor-grabbing"
    >
      <p className="break-anywhere font-medium leading-snug">{task.title}</p>

      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        {task.sourceMessageId !== null ? (
          <span className="tag" title="由聊天消息创建">
            来自聊天
          </span>
        ) : null}
        {task.runId !== null ? (
          <a className="tag text-accent hover:underline" href={`/runs/${task.runId}`}>
            查看执行
          </a>
        ) : null}
        <span className="t-meta ml-auto">{fmtRelative(task.updatedAt)}</span>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        <AssigneeMenu task={task} experts={experts} onPatch={onPatch} />
        <StatusMenu task={task} onPatch={onPatch} />
      </div>
    </article>
  );
}

/**
 * Assignment, as one control.
 *
 * Kind and id move together because `expert` with no id is unresolvable — the
 * engine refuses that pair, and offering them as separate fields would let the
 * UI construct exactly the state it rejects.
 */
function AssigneeMenu({
  task,
  experts,
  onPatch,
}: {
  task: Task;
  experts: Expert[];
  onPatch: (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => void;
}) {
  return (
    <label className="inline-flex items-center gap-1">
      <span className="sr-only">负责人</span>
      <select
        className="field btn-sm w-auto py-0 text-[0.75rem]"
        value={actorKey(task.assigneeKind, task.assigneeId)}
        onChange={(e) => {
          const v = e.target.value;
          if (v === "none") onPatch(task.id, { assigneeKind: null, assigneeId: null });
          else if (v === "human") onPatch(task.id, { assigneeKind: "human", assigneeId: null });
          else onPatch(task.id, { assigneeKind: "expert", assigneeId: v.slice("expert:".length) });
        }}
      >
        <option value="none">未分配</option>
        <option value="human">你</option>
        {experts.map((e) => (
          <option key={e.id} value={`expert:${e.id}`}>
            {e.name}
          </option>
        ))}
      </select>
    </label>
  );
}

/** Keyboard-reachable status change, so dragging is never the only route. */
function StatusMenu({
  task,
  onPatch,
}: {
  task: Task;
  onPatch: (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => void;
}) {
  return (
    <label className="inline-flex items-center gap-1">
      <span className="sr-only">状态</span>
      <select
        className="field btn-sm w-auto py-0 text-[0.75rem]"
        value={task.status}
        onChange={(e) => onPatch(task.id, { status: e.target.value as TaskStatus })}
      >
        {TASK_STATUSES.map((s) => (
          <option key={s} value={s}>
            {TASK_STATUS_LABEL[s]}
          </option>
        ))}
      </select>
    </label>
  );
}

function ListView({
  tasks,
  experts,
  onPatch,
}: {
  tasks: Task[];
  experts: Expert[];
  onPatch: (id: string, next: Partial<Pick<Task, "status" | "assigneeKind" | "assigneeId">>) => void;
}) {
  return (
    <div className="panel divide-soft overflow-hidden">
      {tasks.map((t) => (
        <div key={t.id} className="flex flex-wrap items-center gap-2 px-3 py-2.5">
          <span className="min-w-0 flex-1 break-anywhere font-medium">{t.title}</span>
          {t.assigneeKind === "expert" && t.assigneeId !== null ? (
            <ExpertChip id={t.assigneeId} experts={experts} />
          ) : (
            <span className="t-meta">{actorLabel(t.assigneeKind, t.assigneeId, experts)}</span>
          )}
          <StatusMenu task={t} onPatch={onPatch} />
        </div>
      ))}
    </div>
  );
}

function ExpertChip({ id, experts }: { id: string; experts: Expert[] }) {
  const expert = experts.find((e) => e.id === id);
  if (!expert) return <span className="t-meta">未知 agent</span>;
  return <RuntimeMark kind={expert.runtimeKind} name={expert.name} />;
}

/**
 * Create dialog: titles only.
 *
 * Everything else about a task — who owns it, which column it sits in — is set
 * on the board afterwards, so asking for it up front would be four fields nobody
 * has decided yet. "再加一个" makes entering a handful the normal case rather
 * than a bulk-import feature.
 */
function CreateDialog({
  channelId,
  onClose,
  onCreated,
}: {
  channelId: string;
  onClose: () => void;
  onCreated: () => void;
}) {
  const [titles, setTitles] = useState<string[]>([""]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    const cleaned = titles.map((t) => t.trim()).filter((t) => t.length > 0);
    if (cleaned.length === 0) return;
    setBusy(true);
    try {
      await api.createTasks(channelId, cleaned);
      onCreated();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      className="absolute inset-0 z-40 grid place-items-center bg-fg/20 p-4"
      role="dialog"
      aria-modal="true"
      aria-label="新建任务"
      onKeyDown={(e) => {
        if (e.key === "Escape") onClose();
      }}
    >
      <div className="card w-full max-w-lg p-4">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="t-md">新建任务</h2>
          <button type="button" className="btn btn-icon btn-sm btn-ghost" onClick={onClose} aria-label="关闭">
            ✕
          </button>
        </div>

        {error !== null ? (
          <div className="mb-3">
            <ErrorBox message={error} />
          </div>
        ) : null}

        <div className="space-y-2">
          {titles.map((title, i) => (
            <input
              // eslint-disable-next-line react/no-array-index-key -- rows are positional
              key={i}
              className="field"
              value={title}
              autoFocus={i === titles.length - 1}
              placeholder={`任务 ${i + 1}`}
              onChange={(e) =>
                setTitles((cur) => cur.map((t, j) => (j === i ? e.target.value : t)))
              }
              onKeyDown={(e) => {
                if (e.key !== "Enter") return;
                e.preventDefault();
                // Enter on the last row adds another, matching how a list of
                // things is actually typed; on an earlier row it submits.
                if (i === titles.length - 1 && e.currentTarget.value.trim().length > 0) {
                  setTitles((cur) => [...cur, ""]);
                } else {
                  void submit();
                }
              }}
            />
          ))}
        </div>

        <div className="mt-3 flex items-center gap-2">
          <button
            type="button"
            className="btn btn-sm"
            onClick={() => setTitles((cur) => [...cur, ""])}
          >
            + 再加一个
          </button>
          <div className="ml-auto flex items-center gap-2">
            <button type="button" className="btn btn-sm" onClick={onClose}>
              取消
            </button>
            <button
              type="button"
              className="btn btn-primary btn-sm"
              onClick={() => void submit()}
              disabled={busy || titles.every((t) => t.trim().length === 0)}
            >
              {busy ? "创建中…" : "创建任务"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
