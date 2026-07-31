"use client";

import Link from "next/link";
import { use, useMemo, useRef, useState } from "react";
import { isBlocking } from "@council/core/review-rules";
import { api, ApiError, fmtDuration, fmtTokens, fmtUsd } from "../../../lib/api.ts";
import type { SubTask } from "../../../lib/types.ts";
import { useRun, type LogRow, type VerifyReport as VerifyReportData } from "../../../lib/useRun.ts";
import {
  Badge,
  BudgetMeter,
  Dot,
  Empty,
  ErrorBox,
  Meta,
  SectionHeader,
  Spinner,
  StatusBadge,
} from "../../../components/atoms.tsx";
import { LiveCard, PhaseRail, StageBoard } from "../../../components/timeline.tsx";
import { DiscussionThread, EscalationGate, ReviewPanel } from "../../../components/review.tsx";
import { AttemptHistory } from "../../../components/transcripts.tsx";

type Tab = "work" | "review" | "log";

/**
 * Tab order, shared by rendering and keyboard navigation.
 *
 * One source of truth so the arrow keys cannot walk a different order than the eye
 * sees — a drift that is invisible to anyone testing with a mouse.
 */
const TAB_ORDER: readonly Tab[] = ["work", "review", "log"];

const TAB_LABEL: Record<Tab, string> = {
  work: "工作",
  review: "评审与讨论",
  log: "事件流",
};

export default function RunPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const {
    detail,
    log,
    live,
    reachedPhases,
    verifyReport,
    mergeConflicts,
    unmergeable,
    connected,
    error,
    reload,
  } = useRun(id);

  const [tab, setTab] = useState<Tab>("work");
  /**
   * The tab buttons, so arrow keys can move focus along with selection. Without
   * moving focus, the next arrow press is handled from the old position and the strip
   * feels stuck after one keypress.
   */
  const tabRefs = useRef<Partial<Record<Tab, HTMLButtonElement | null>>>({});
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  /**
   * Sum of the costs runtimes reported for themselves.
   *
   * A LOWER BOUND, not a total: most runtimes report nothing (their spend is covered
   * by a subscription), so this only adds up the ones that do. The label says so —
   * presenting a partial sum as the full cost would be a false claim.
   */
  const reportedCost = useMemo(() => {
    const total = (detail?.attempts ?? []).reduce((sum, a) => sum + (a.costUsd ?? 0), 0);
    return fmtUsd(total);
  }, [detail?.attempts]);

  // Cheap: `live` holds one entry per agent turn, not per event.
  const running = useMemo(() => [...live.values()].filter((l) => l.status === "running"), [live]);
  const recentlyDone = useMemo(
    () => [...live.values()].filter((l) => l.status !== "running").slice(-2),
    [live],
  );

  const act = async (fn: () => Promise<unknown>): Promise<void> => {
    setBusy(true);
    setActionError(null);
    try {
      await fn();
      reload();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  if (error !== null && detail === null) {
    return (
      <div className="pt-12">
        <ErrorBox message={error} onRetry={reload} />
        <Link href="/" className="btn mt-4">
          返回
        </Link>
      </div>
    );
  }

  if (detail === null) {
    return (
      <div className="card mt-12 p-6">
        <Spinner label="加载委托" />
      </div>
    );
  }

  const { run, subtasks, attempts, reviews, adjudications, discussion } = detail;
  const selectedSubtask: SubTask | null =
    selected === null ? null : (subtasks.find((s) => s.id === selected) ?? null);
  const blockers = reviews.filter(isBlocking).length;

  return (
    <div className="pt-8">
      {/* ── Header ── */}
      <div className="flex items-start gap-3">
        <Link
          href="/"
          className="btn btn-ghost btn-sm mt-0.5 shrink-0"
          aria-label="返回委托列表"
          title="返回"
        >
          ←
        </Link>

        <div className="min-w-0 flex-1">
          <h1 className="t-lg text-balance">{run.goal}</h1>

          <div className="mt-2.5 flex flex-wrap items-center gap-x-2 gap-y-1.5">
            <StatusBadge status={run.status} />
            {run.soloMode ? <Meta>单专家直通</Meta> : null}
            {detail.project ? (
              <>
                <Dot />
                <Meta title={detail.project.repoPath}>{detail.project.name}</Meta>
              </>
            ) : null}
            <Dot />
            <Meta>{fmtDuration(run.createdAt, run.endedAt)}</Meta>
            <Dot />
            <Meta title={`${run.spentTokens.toLocaleString()} tokens`}>
              {fmtTokens(run.spentTokens)} / {fmtTokens(run.budgetTokens)} tokens
            </Meta>
            {reportedCost !== null ? (
              <>
                <Dot />
                {/*
                  Only runtimes that state their own price contribute, so this is a
                  floor on real spend rather than a total. Labelled as such:
                  presenting a partial figure as the full cost would be worse than
                  showing nothing.
                */}
                <Meta title="仅统计会自报花费的运行时（Grok / Kiro），因此是下限而非总额">
                  ≥{reportedCost}
                </Meta>
              </>
            ) : null}
            {!connected && run.status === "running" ? (
              <>
                <Dot />
                <Badge tone="warn" title="实时连接中断，正在自动重连">
                  连接中断
                </Badge>
              </>
            ) : null}
          </div>

          {run.budgetTokens > 0 ? (
            <div className="mt-3 max-w-[22rem]">
              <BudgetMeter spent={run.spentTokens} budget={run.budgetTokens} />
            </div>
          ) : null}
        </div>

        {run.status === "running" ? (
          <button
            type="button"
            className="btn btn-sm shrink-0"
            disabled={busy}
            onClick={() => void act(() => api.cancel(run.id))}
          >
            中止
          </button>
        ) : null}
      </div>

      {run.acceptance !== null && run.acceptance.length > 0 ? (
        <div className="inset mt-4 px-3.5 py-2.5">
          <span className="t-label">验收标准</span>
          <p className="mt-1 body-muted">{run.acceptance}</p>
        </div>
      ) : null}

      <div className="mt-5">
        <PhaseRail current={run.phase} reached={reachedPhases} soloMode={run.soloMode} />
      </div>

      {actionError !== null ? (
        <div className="mt-4">
          <ErrorBox message={actionError} />
        </div>
      ) : null}

      {run.error !== null && run.status !== "running" ? (
        <div className="mt-4">
          <ErrorBox message={run.error} />
        </div>
      ) : null}

      {/* ── Gates: the only two places a human is needed ── */}
      {run.gate === "plan_approval" ? (
        <PlanGate
          subtasks={subtasks}
          busy={busy}
          onApprove={() => void act(() => api.approvePlan(run.id))}
        />
      ) : null}

      <div className="mt-4">
        <EscalationGate
          adjudications={adjudications}
          busy={busy}
          onResolve={(aid, decision) => void act(() => api.resolve(run.id, aid, decision))}
        />
      </div>

      {/*
        ── Tabs ──

        A full tabs implementation, because a partial one is worse than none:
        `role="tab"` PROMISES arrow-key navigation and a linked panel to assistive
        technology. An earlier version declared the role and delivered neither.
      */}
      <nav
        className="mt-7 flex gap-0.5 border-b"
        style={{ borderColor: "var(--color-line)" }}
        role="tablist"
        aria-label="委托详情视图"
        onKeyDown={(e) => {
          const delta =
            e.key === "ArrowRight"
              ? 1
              : e.key === "ArrowLeft"
                ? -1
                : e.key === "Home"
                  ? -999
                  : e.key === "End"
                    ? 999
                    : 0;
          if (delta === 0) return;
          e.preventDefault();
          const i = TAB_ORDER.indexOf(tab);
          // Wraps, as the pattern specifies; clamping makes the ends feel broken.
          const next =
            delta === -999
              ? 0
              : delta === 999
                ? TAB_ORDER.length - 1
                : (i + delta + TAB_ORDER.length) % TAB_ORDER.length;
          const target = TAB_ORDER[next];
          if (target === undefined) return;
          setTab(target);
          tabRefs.current[target]?.focus();
        }}
      >
        {TAB_ORDER.map((key) => {
          const count =
            key === "work"
              ? subtasks.length
              : key === "review"
                ? reviews.length + discussion.length
                : log.length;
          const isSelected = tab === key;
          return (
            <button
              key={key}
              ref={(el) => {
                tabRefs.current[key] = el;
              }}
              type="button"
              role="tab"
              id={`tab-${key}`}
              aria-selected={isSelected}
              aria-controls={`panel-${key}`}
              // Roving tabindex: one stop for the group, then arrows move within it.
              tabIndex={isSelected ? 0 : -1}
              onClick={() => setTab(key)}
              className="-mb-px flex items-center gap-2 border-b-2 px-3 py-2.5 text-[0.875rem] font-medium transition-colors duration-150"
              style={
                isSelected
                  ? { borderColor: "var(--color-accent)", color: "var(--color-fg)" }
                  : { borderColor: "transparent", color: "var(--color-subtle-fg)" }
              }
            >
              {TAB_LABEL[key]}
              {count > 0 ? (
                <span
                  className="rounded-[0.3125rem] px-1.5 text-[0.6875rem] font-semibold tabular-nums"
                  style={{
                    background: isSelected ? "var(--color-accent-soft)" : "var(--color-bg)",
                    color: isSelected ? "var(--color-accent)" : "var(--color-subtle-fg)",
                  }}
                >
                  {count}
                </span>
              ) : null}
              {key === "review" && blockers > 0 ? (
                <span
                  aria-label={`${blockers} 个未解决的阻塞项`}
                  className="h-1.5 w-1.5 rounded-full"
                  style={{ background: "var(--color-bad)" }}
                />
              ) : null}
            </button>
          );
        })}
      </nav>

      <div
        className="mt-6"
        role="tabpanel"
        id={`panel-${tab}`}
        aria-labelledby={`tab-${tab}`}
        // Focusable so a keyboard user can Tab from the strip into the content.
        tabIndex={0}
      >
        {tab === "work" ? (
          <div className="space-y-10">
            {running.length > 0 ? (
              <section>
                <SectionHeader title="正在工作" count={running.length} hint="并行" />
                <div className="grid gap-3 xl:grid-cols-2">
                  {running.map((l) => (
                    <LiveCard key={l.attemptId} live={l} />
                  ))}
                </div>
              </section>
            ) : null}

            {running.length === 0 && recentlyDone.length > 0 && run.status === "running" ? (
              <section>
                <SectionHeader title="刚刚完成" />
                <div className="grid gap-3 xl:grid-cols-2">
                  {recentlyDone.map((l) => (
                    <LiveCard key={l.attemptId} live={l} />
                  ))}
                </div>
              </section>
            ) : null}

            {subtasks.length > 0 ? (
              <section>
                <SectionHeader
                  title="拆解结果"
                  count={subtasks.length}
                  hint="点一个子任务可只看它的评审"
                  right={
                    selected !== null ? (
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setSelected(null)}>
                        清除筛选
                      </button>
                    ) : null
                  }
                />
                <StageBoard
                  subtasks={subtasks}
                  attempts={attempts}
                  selectedId={selected}
                  onSelect={setSelected}
                />
              </section>
            ) : run.status === "running" && !run.soloMode ? (
              <Empty
                icon="◐"
                title="编排者正在读代码、拆解任务"
                hint="拆完会停下来等你确认，这是最便宜的介入点。"
              />
            ) : null}

            <MergeAndVerify
              report={verifyReport}
              conflicts={mergeConflicts}
              unmergeable={unmergeable}
            />

            {/*
              The durable record. Live cards only exist inside the SSE session that
              produced them, so without this a reloaded run showed no agent output at
              all — the transcripts were in the database and unreachable.
            */}
            <AttemptHistory
              runId={run.id}
              attempts={attempts}
              subtasks={subtasks}
              filterSubTaskId={selected}
            />
          </div>
        ) : null}

        {tab === "review" ? (
          <div className="space-y-10">
            {selectedSubtask !== null ? (
              <div className="flex flex-wrap items-center gap-2.5">
                <Meta>只看</Meta>
                <Badge tone="accent">{selectedSubtask.title}</Badge>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setSelected(null)}>
                  显示全部
                </button>
              </div>
            ) : null}
            <ReviewPanel reviews={reviews} adjudications={adjudications} subtask={selectedSubtask} />
            <DiscussionThread messages={discussion} subtask={selectedSubtask} />
          </div>
        ) : null}

        {tab === "log" ? <EventLog rows={log} /> : null}
      </div>
    </div>
  );
}

/**
 * The plan gate.
 *
 * The cheapest intervention point in the whole pipeline: thirty seconds spent checking
 * the decomposition here avoids several agents building the wrong thing and several
 * reviews of that wrong thing. So it is styled as the primary thing on screen, not as
 * a notice bar.
 */
function PlanGate({
  subtasks,
  busy,
  onApprove,
}: {
  subtasks: SubTask[];
  busy: boolean;
  onApprove: () => void;
}) {
  const stages = [...new Set(subtasks.map((s) => s.stage))].sort((a, b) => a - b);
  return (
    <div
      className="rise mt-5 rounded-[var(--radius-lg)] border p-4"
      style={{
        borderColor: "color-mix(in oklch, var(--color-accent) 45%, transparent)",
        background: "color-mix(in oklch, var(--color-accent) 6%, var(--color-surface))",
        boxShadow: "var(--shadow-md), var(--highlight)",
      }}
    >
      <h2 className="flex items-center gap-2 t-md">
        <span aria-hidden style={{ color: "var(--color-accent)" }}>
          ◆
        </span>
        确认拆解方案
      </h2>
      <p className="mt-1.5 max-w-[62ch] text-balance t-meta">
        同一批里的子任务会在各自独立的 worktree 中并行执行，互相看不到对方的产出。后一批开始前，前一批的产出会先合并进来。
      </p>

      <div className="mt-4 space-y-4">
        {stages.map((stage) => (
          <div key={stage}>
            <div className="mb-2 flex items-center gap-2.5">
              <span className="t-label">第 {stage + 1} 批</span>
              <Meta>{subtasks.filter((s) => s.stage === stage).length} 个并行</Meta>
            </div>
            <ol className="space-y-2">
              {subtasks
                .filter((s) => s.stage === stage)
                .map((s) => (
                  <li key={s.id} className="inset p-3">
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <p className="font-medium leading-snug">{s.title}</p>
                      <div className="flex shrink-0 flex-wrap gap-1.5">
                        {s.assigneeName ? <Badge tone="accent">{s.assigneeName}</Badge> : null}
                        {s.capability ? <Meta>{s.capability}</Meta> : null}
                      </div>
                    </div>
                    <p className="mt-1.5 body-muted">{s.brief}</p>
                    {s.acceptance ? <p className="mt-1.5 t-meta">验收：{s.acceptance}</p> : null}
                  </li>
                ))}
            </ol>
          </div>
        ))}
      </div>

      <button type="button" className="btn btn-primary mt-4" disabled={busy} onClick={onApprove}>
        {busy ? "启动中…" : "通过，开始执行"}
      </button>
    </div>
  );
}

/** The last honest measurement in the pipeline — surfaced, never summarised away. */
function MergeAndVerify({
  report,
  conflicts,
  unmergeable,
}: {
  report: VerifyReportData | null;
  conflicts: string[];
  unmergeable: string[];
}) {
  if (report === null && conflicts.length === 0 && unmergeable.length === 0) return null;

  return (
    <section className="space-y-3">
      {conflicts.length > 0 || unmergeable.length > 0 ? (
        <div
          className="rounded-[var(--radius-lg)] border p-4"
          style={{
            borderColor: "color-mix(in oklch, var(--color-warn) 34%, transparent)",
            background: "color-mix(in oklch, var(--color-warn) 5%, var(--color-surface))",
          }}
        >
          <h3 className="t-md" style={{ color: "var(--color-warn)" }}>
            有产出留给你处理
          </h3>
          <p className="mt-1.5 max-w-[62ch] text-balance t-meta">
            没有自动解决 —— 机器随手挑一边正是这套系统要避免的那类静默损坏。
          </p>

          {conflicts.length > 0 ? (
            <div className="mt-3">
              <span className="t-label">合并冲突</span>
              <ul className="mono mt-1.5 space-y-1 text-[var(--color-muted-fg)]">
                {conflicts.map((c) => (
                  <li key={c}>{c}</li>
                ))}
              </ul>
            </div>
          ) : null}

          {unmergeable.length > 0 ? (
            <div className="mt-3">
              <span className="t-label">未合并（评审未通过或没有分支）</span>
              <ul className="mono mt-1.5 space-y-1 text-[var(--color-muted-fg)]">
                {unmergeable.map((u) => (
                  <li key={u}>{u}</li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      ) : null}

      {report !== null ? (
        <div className="card p-4">
          <div className="flex items-center gap-2.5">
            <h3 className="t-md">验证报告</h3>
            <Badge tone={report.ok ? "ok" : "bad"}>{report.ok ? "已执行" : "执行失败"}</Badge>
          </div>
          <pre className="inset mono mt-3 max-h-[22rem] overflow-y-auto whitespace-pre-wrap break-words p-3 text-[var(--color-muted-fg)]">
            {report.text}
          </pre>
        </div>
      ) : null}
    </section>
  );
}

/**
 * Raw event feed, newest first.
 *
 * Filtering matches a search string precomputed when the row arrived —
 * re-stringifying every payload on each keystroke made the input lag once a run had a
 * few hundred events.
 */
function EventLog({ rows }: { rows: LogRow[] }) {
  const [filter, setFilter] = useState("");

  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase();
    const list = q.length === 0 ? rows : rows.filter((r) => r.search.includes(q));
    return list.slice().reverse();
  }, [rows, filter]);

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-2.5">
        <input
          className="input btn-sm w-auto flex-1"
          style={{ minWidth: "12rem" }}
          placeholder="过滤事件…"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          aria-label="过滤事件"
        />
        <Meta>{visible.length} 条</Meta>
      </div>
      <p className="mb-3 t-meta">逐字输出不在这里 —— 它属于上方每位专家的实时卡片。</p>

      {visible.length === 0 ? (
        <Empty icon="○" title="没有匹配的事件" />
      ) : (
        <div className="card divide-line overflow-hidden">
          {visible.map((ev) => (
            <details key={ev.id} className="group">
              <summary className="flex cursor-pointer items-center gap-2.5 px-3.5 py-2 transition-colors duration-150 hover:bg-[oklch(1_0_0/4%)]">
                <span className="mono shrink-0 text-[var(--color-subtle-fg)]">
                  {new Date(ev.createdAt).toLocaleTimeString("zh-CN", { hour12: false })}
                </span>
                <span className="mono font-medium">{ev.type}</span>
              </summary>
              <pre
                className="mono max-h-72 overflow-auto px-3.5 py-2.5 text-[var(--color-muted-fg)]"
                style={{ background: "var(--color-surface)" }}
              >
                {JSON.stringify(ev.payload, null, 2)}
              </pre>
            </details>
          ))}
        </div>
      )}
    </div>
  );
}
