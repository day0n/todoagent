"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { api, ApiError, fmtRelative, fmtTokens } from "../lib/api.ts";
import type { Project, Run } from "../lib/types.ts";
import {
  BudgetMeter,
  Dot,
  Empty,
  ErrorBox,
  Meta,
  PhaseBadge,
  SectionHeader,
  Spinner,
  StatusBadge,
} from "../components/atoms.tsx";

/**
 * Home is a composer plus history — deliberately NOT a board.
 *
 * A kanban front page tells the user "you have a backlog to manage", which is right
 * for Multica and Raft: they are team workspaces where work accumulates. This is a
 * one-shot commission — you state a goal, a team works it, it ends. So the page has
 * exactly one obvious action, and everything else is a record of past ones.
 */
export default function HomePage() {
  const [projects, setProjects] = useState<Project[] | null>(null);
  const [runs, setRuns] = useState<Run[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [goal, setGoal] = useState("");
  const [projectId, setProjectId] = useState("");
  const [acceptance, setAcceptance] = useState("");
  const [budgetM, setBudgetM] = useState(2);
  const [soloMode, setSoloMode] = useState(false);
  const [autoApprove, setAutoApprove] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const load = useCallback(async () => {
    setError(null);
    try {
      const [ps, rs] = await Promise.all([api.projects(), api.runs()]);
      setProjects(ps);
      setRuns(rs);
      setProjectId((cur) => cur || (ps[0]?.id ?? ""));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      setProjects([]);
      setRuns([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  // Coarse polling for the history list. The run page itself uses SSE; this only
  // needs to notice that something finished elsewhere.
  useEffect(() => {
    const t = setInterval(() => {
      api
        .runs()
        .then(setRuns)
        .catch(() => undefined);
    }, 8000);
    return () => clearInterval(t);
  }, []);

  const submit = async (): Promise<void> => {
    if (goal.trim().length === 0 || projectId.length === 0) return;
    setSubmitting(true);
    setError(null);
    try {
      const run = await api.createRun({
        projectId,
        goal: goal.trim(),
        acceptance: acceptance.trim().length > 0 ? acceptance.trim() : null,
        budgetTokens: Math.round(budgetM * 1_000_000),
        soloMode,
        autoApprovePlan: autoApprove,
      });
      window.location.href = `/runs/${run.id}`;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      setSubmitting(false);
    }
  };

  const loading = projects === null || runs === null;
  const canSubmit = !submitting && goal.trim().length > 0 && projectId.length > 0;
  const activeProject = projects?.find((p) => p.id === projectId);

  return (
    <div className="mx-auto w-full max-w-[760px]">
      {/* ── Composer ── */}
      <section className="pt-14">
        <h1 className="title-xl text-balance">你想完成什么？</h1>
        <p className="mt-2.5 max-w-[52ch] text-balance body-muted">
          交代一件事，一支本地专家团队会拆解它、并行执行、互相评审，最后交回被审查过的结果。
        </p>

        <div className="card mt-7 p-1.5">
          <textarea
            className="min-h-[7.5rem] w-full resize-y bg-transparent px-3.5 pt-3 text-[0.9375rem] leading-relaxed outline-none placeholder:text-[var(--color-subtle-fg)]"
            placeholder="例如：给设置页加深色模式，跟系统偏好同步，切换时不要闪白屏"
            value={goal}
            onChange={(e) => setGoal(e.target.value)}
            onKeyDown={(e) => {
              // Cmd/Ctrl+Enter submits. This box is the whole point of the page.
              if ((e.metaKey || e.ctrlKey) && e.key === "Enter") void submit();
            }}
            autoFocus
          />

          <div className="flex flex-wrap items-center gap-2 px-2 pb-1.5 pt-1">
            {projects !== null && projects.length > 0 ? (
              <select
                className="input btn-sm w-auto"
                style={{ background: "var(--color-surface)" }}
                value={projectId}
                onChange={(e) => setProjectId(e.target.value)}
                aria-label="目标仓库"
              >
                {projects.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            ) : null}

            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={() => setAdvanced((v) => !v)}
              aria-expanded={advanced}
            >
              <span aria-hidden className="text-[0.6875rem]">
                {advanced ? "▾" : "▸"}
              </span>
              选项
            </button>

            {soloMode ? <Meta>单专家</Meta> : null}
            {autoApprove ? <Meta>自动通过拆解</Meta> : null}

            <div className="ml-auto flex items-center gap-2.5">
              <kbd className="hidden t-meta sm:block">⌘↵</kbd>
              <button
                type="button"
                className="btn btn-primary"
                disabled={!canSubmit}
                onClick={() => void submit()}
              >
                {submitting ? "启动中…" : "开始"}
              </button>
            </div>
          </div>

          {advanced ? (
            <div
              className="rise mt-1.5 space-y-4 border-t px-3.5 pb-3 pt-3.5"
              style={{ borderColor: "var(--color-line)" }}
            >
              <label className="block">
                <span className="t-label">验收标准（可选）</span>
                <textarea
                  className="input mt-2 min-h-[4.5rem] resize-y"
                  placeholder="怎样算做完了？写具体一点，评审者会照这个检查。"
                  value={acceptance}
                  onChange={(e) => setAcceptance(e.target.value)}
                />
              </label>

              <div className="grid gap-5 sm:grid-cols-2">
                <div>
                  <div className="flex items-baseline justify-between">
                    <span className="t-label">预算上限</span>
                    <span className="text-[0.8125rem] font-medium tabular-nums">{budgetM}M</span>
                  </div>
                  <input
                    type="range"
                    min={0.25}
                    max={20}
                    step={0.25}
                    value={budgetM}
                    onChange={(e) => setBudgetM(Number(e.target.value))}
                    className="mt-2.5 w-full accent-[var(--color-accent)]"
                    aria-label="预算上限（百万 token）"
                  />
                  <p className="mt-1.5 t-meta">硬上限。超出即停，并把中间产物交给你。</p>
                </div>

                <div className="space-y-3">
                  <Toggle
                    checked={soloMode}
                    onChange={setSoloMode}
                    title="单专家直通"
                    hint="小改动派一队人纯属浪费。跳过拆解与评审，但仍然跑验证。"
                  />
                  <Toggle
                    checked={autoApprove}
                    onChange={setAutoApprove}
                    title="自动通过拆解"
                    hint="不停下来等你确认。拆错了会连带浪费后面的并行执行。"
                  />
                </div>
              </div>
            </div>
          ) : null}
        </div>

        {activeProject ? (
          <p className="mono mt-2.5 truncate px-1 text-[var(--color-subtle-fg)]">
            {activeProject.repoPath}
          </p>
        ) : null}

        {error !== null ? (
          <div className="mt-5">
            <ErrorBox message={error} onRetry={() => void load()} />
          </div>
        ) : null}

        {projects !== null && projects.length === 0 && error === null ? (
          <div className="mt-5">
            <Empty
              icon="◇"
              title="还没有配置项目"
              hint="在 council 目录运行 pnpm seed <你的仓库路径>，它会按本机已安装的 CLI 自动组一支团队。"
            />
          </div>
        ) : null}
      </section>

      {/* ── History ── */}
      <section className="mt-14">
        <SectionHeader title="历史委托" count={runs?.length ?? 0} />

        <div className="space-y-2.5">
          {loading ? (
            <div className="card p-5">
              <Spinner />
            </div>
          ) : runs !== null && runs.length === 0 ? (
            <Empty icon="◷" title="还没有委托记录" hint="上面写一句目标就能开始。" />
          ) : (
            runs?.map((run) => <RunRow key={run.id} run={run} />)
          )}
        </div>
      </section>
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  title,
  hint,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  title: string;
  hint: string;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2.5">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-[0.1875rem] h-3.5 w-3.5 shrink-0 accent-[var(--color-accent)]"
      />
      <span>
        <span className="block text-[0.8125rem] font-medium">{title}</span>
        <span className="mt-0.5 block t-meta">{hint}</span>
      </span>
    </label>
  );
}

function RunRow({ run }: { run: Run }) {
  const needsYou = run.status === "blocked_on_human";
  return (
    <Link
      href={`/runs/${run.id}`}
      className="card-hover p-4"
      style={
        needsYou
          ? {
              borderColor: "color-mix(in oklch, var(--color-warn) 34%, transparent)",
              background: "color-mix(in oklch, var(--color-warn) 5%, var(--color-surface))",
            }
          : undefined
      }
    >
      <div className="flex items-start gap-4">
        <div className="min-w-0 flex-1">
          {/* The goal is the point of the row, so it gets real size — the old design
              rendered it at the same 14px as its own metadata. */}
          <p className="line-clamp-2 font-medium leading-snug">{run.goal}</p>

          <div className="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1.5">
            <StatusBadge status={run.status} />
            {run.status === "running" ? <PhaseBadge phase={run.phase} /> : null}
            {run.soloMode ? <Meta>单专家</Meta> : null}
            {run.projectName ? (
              <>
                <Dot />
                <Meta>{run.projectName}</Meta>
              </>
            ) : null}
            <Dot />
            <Meta>{fmtRelative(run.createdAt)}</Meta>
            {run.spentTokens > 0 ? (
              <>
                <Dot />
                <Meta title={`${run.spentTokens.toLocaleString()} tokens`}>
                  {fmtTokens(run.spentTokens)} tokens
                </Meta>
              </>
            ) : null}
          </div>
        </div>

        {run.budgetTokens > 0 ? (
          <div className="w-24 shrink-0 pt-2">
            <BudgetMeter spent={run.spentTokens} budget={run.budgetTokens} />
          </div>
        ) : null}
      </div>

      {needsYou ? (
        <p
          className="mt-2.5 flex items-center gap-1.5 text-[0.8125rem] font-medium"
          style={{ color: "var(--color-warn)" }}
        >
          <span aria-hidden>→</span>
          {run.gate === "plan_approval" ? "等你确认拆解方案" : "有一处分歧需要你裁决"}
        </p>
      ) : null}

      {run.error !== null && run.status === "failed" ? (
        <p
          className="mt-2.5 line-clamp-2 text-[0.8125rem]"
          style={{ color: "var(--color-bad)" }}
        >
          {run.error}
        </p>
      ) : null}
    </Link>
  );
}
