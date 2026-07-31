"use client";

import { useEffect, useRef, useState } from "react";
import type { LiveAttempt } from "../lib/useRun.ts";
import type { Attempt, Phase, Review, RuntimeKind, SubTask } from "../lib/types.ts";
import { PHASE_LABEL, PHASE_ORDER } from "../lib/types.ts";
import { Badge, Meta, RuntimeMark, SubTaskBadge } from "./atoms.tsx";

const KIND_LABEL: Record<string, string> = {
  plan: "拆解",
  draft: "执行",
  review: "评审",
  repro: "复现验证",
  rebuttal: "回应",
  discuss: "讨论",
  adjudicate: "裁决",
  verify: "验证",
};

/**
 * The phase rail.
 *
 * A real stepper rather than the row of identical pills this replaces: completed
 * phases collapse to a check, the current one is filled and carries an indeterminate
 * sweep, and connectors show which segments are behind you. A run emits hundreds of
 * events, so the one thing that must be legible at a glance is "where am I".
 */
export function PhaseRail({
  current,
  reached,
  soloMode,
}: {
  current: Phase;
  reached: Set<Phase>;
  soloMode: boolean;
}) {
  // Solo mode skips the collaboration phases entirely, so showing them greyed out
  // would imply "pending" rather than "not applicable".
  const phases = soloMode ? (["draft", "verify"] as Phase[]) : PHASE_ORDER;
  const currentIndex = phases.indexOf(current);

  return (
    <ol className="flex items-center gap-1 overflow-x-auto pb-1" aria-label="流程阶段">
      {phases.map((phase, i) => {
        const isCurrent = phase === current;
        const isPast = reached.has(phase) && i < currentIndex;
        return (
          <li key={phase} className="flex shrink-0 items-center gap-1">
            <div
              className="relative flex items-center gap-2 overflow-hidden rounded-[0.5rem] px-2.5 py-1.5 transition-colors duration-200"
              style={
                isCurrent
                  ? {
                      background: "var(--color-accent-soft)",
                      border: "1px solid color-mix(in oklch, var(--color-accent) 42%, transparent)",
                    }
                  : {
                      border: "1px solid transparent",
                    }
              }
              aria-current={isCurrent ? "step" : undefined}
            >
              <span
                aria-hidden
                className="grid h-4 w-4 shrink-0 place-items-center rounded-full text-[0.5625rem] font-bold"
                style={
                  isPast
                    ? { background: "var(--color-ok)", color: "var(--color-bg)" }
                    : isCurrent
                      ? { background: "var(--color-accent)", color: "var(--color-accent-fg)" }
                      : {
                          border: "1px solid var(--color-line-strong)",
                          color: "var(--color-subtle-fg)",
                        }
                }
              >
                {isPast ? "✓" : i + 1}
              </span>
              <span
                className="text-[0.8125rem] font-medium"
                style={{
                  color: isCurrent
                    ? "var(--color-fg)"
                    : isPast
                      ? "var(--color-muted-fg)"
                      : "var(--color-subtle-fg)",
                }}
              >
                {PHASE_LABEL[phase]}
              </span>
              {/* Indeterminate, because a phase's duration genuinely is not known. */}
              {isCurrent ? (
                <span
                  aria-hidden
                  className="indeterminate pointer-events-none absolute inset-x-0 bottom-0 h-[2px] overflow-hidden opacity-70"
                />
              ) : null}
            </div>
            {i < phases.length - 1 ? (
              <span
                aria-hidden
                className="h-px w-3 shrink-0 transition-colors duration-300"
                style={{
                  background: isPast ? "var(--color-ok)" : "var(--color-line-strong)",
                  opacity: isPast ? 0.5 : 1,
                }}
              />
            ) : null}
          </li>
        );
      })}
    </ol>
  );
}

/**
 * One agent's live output.
 *
 * Styled as an output panel — recessed body, distinct header — so a wall of parallel
 * transcripts reads as several tools working rather than one long undifferentiated
 * blob. Auto-scroll sticks to the bottom only while the user is already there;
 * yanking the viewport away from something they scrolled up to read is the fastest
 * way to make a live log useless.
 */
export function LiveCard({ live }: { live: LiveAttempt }) {
  const scroller = useRef<HTMLDivElement | null>(null);
  const pinned = useRef(true);
  const [showThinking, setShowThinking] = useState(false);

  useEffect(() => {
    const el = scroller.current;
    if (!el || !pinned.current) return;
    el.scrollTop = el.scrollHeight;
  }, [live.text, live.thinking, showThinking]);

  const onScroll = (): void => {
    const el = scroller.current;
    if (!el) return;
    pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
  };

  const running = live.status === "running";
  const tone = live.status === "failed" ? "bad" : running ? "info" : "ok";

  return (
    <div
      className="rise overflow-hidden rounded-[var(--radius-lg)] border"
      style={{
        borderColor: running
          ? "color-mix(in oklch, var(--color-info) 26%, transparent)"
          : "var(--color-line)",
        background: "var(--color-surface)",
        boxShadow: "var(--shadow-sm)",
      }}
    >
      <div
        className="flex flex-wrap items-center gap-x-2.5 gap-y-1 border-b px-3.5 py-2.5"
        style={{ borderColor: "var(--color-line)" }}
      >
        <RuntimeMark kind={live.runtimeKind as RuntimeKind} name={live.expertName} />
        <Meta>{KIND_LABEL[live.kind] ?? live.kind}</Meta>

        <div className="ml-auto flex items-center gap-2.5">
          {live.toolCount > 0 ? <Meta>{live.toolCount} 次工具调用</Meta> : null}
          {/*
            The STATUS is announced, not the streaming text. Marking the transcript
            itself as a live region would be a firehose — one turn emits dozens of
            text events and a screen reader would read every fragment. State
            transitions carry the meaning, so only they are announced, politely. The
            expert's name is included because an announcement arrives with no
            surrounding context.
          */}
          <span role="status" aria-live="polite" aria-atomic="true">
            {running ? (
              <Badge tone="info" dot>
                {live.currentTool !== null
                  ? `${live.expertName || "专家"} 正在执行 ${live.currentTool}`
                  : `${live.expertName || "专家"} 思考中`}
              </Badge>
            ) : (
              <Badge tone={tone}>
                {`${live.expertName || "专家"} ${live.status === "done" ? "完成" : "失败"}`}
              </Badge>
            )}
          </span>
        </div>
      </div>

      {live.thinking.length > 0 ? (
        <button
          type="button"
          className="flex w-full items-center gap-1.5 border-b px-3.5 py-1.5 text-left text-[0.75rem] transition-colors hover:bg-surface-2"
          style={{ borderColor: "var(--color-line)", color: "var(--color-grape)" }}
          onClick={() => setShowThinking((v) => !v)}
          aria-expanded={showThinking}
        >
          <span aria-hidden className="text-[0.625rem]">
            {showThinking ? "▾" : "▸"}
          </span>
          推理过程
          <span className="opacity-60">{live.thinking.length} 字</span>
        </button>
      ) : null}

      <div
        ref={scroller}
        onScroll={onScroll}
        // `fade-top`, not `fade-bottom`: this box is pinned to the BOTTOM while an
        // agent streams (see the scroll effect above), so the text being cut off is
        // at the top. `fade-bottom` was never defined, so it faded nothing at all.
        className={`max-h-[19rem] overflow-y-auto px-3.5 py-3 ${running ? "fade-top" : ""}`}
        style={{ background: "var(--color-surface)" }}
      >
        {showThinking && live.thinking.length > 0 ? (
          <pre
            className="mono mb-3 whitespace-pre-wrap break-words border-l-2 pl-3 opacity-70"
            style={{ borderColor: "var(--color-grape)", color: "var(--color-muted-fg)" }}
          >
            {live.thinking}
          </pre>
        ) : null}

        {live.text.length > 0 ? (
          <pre className="mono whitespace-pre-wrap break-words">{live.text}</pre>
        ) : running ? (
          <p className="t-meta">等待输出…</p>
        ) : (
          <p className="t-meta">（无文本输出）</p>
        )}

        {live.error !== null ? (
          <p className="mt-2.5 text-[0.8125rem]" style={{ color: "var(--color-bad)" }}>
            {live.error}
          </p>
        ) : null}
      </div>
    </div>
  );
}

/**
 * Subtasks grouped by stage.
 *
 * The stage grouping is load-bearing: everything in one stage runs at once in its own
 * worktree, and the next stage cannot open until every subtask here is terminal.
 * That barrier is what makes hand-off automatic instead of something a human holds
 * back, so the UI states it explicitly rather than just listing cards.
 */
export function StageBoard({
  subtasks,
  attempts,
  reviews,
  selectedId,
  onSelect,
}: {
  subtasks: SubTask[];
  attempts: Attempt[];
  /** Only needed to tell "unreviewed" from "reviewed, still open" — see below. */
  reviews: Review[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
}) {
  if (subtasks.length === 0) return null;

  const stages = [...new Set(subtasks.map((s) => s.stage))].sort((a, b) => a - b);
  const attemptsFor = (id: string): number => attempts.filter((a) => a.subTaskId === id).length;
  /** Subtasks a reviewer actually filed something against. */
  const reviewedIds = new Set(reviews.map((r) => r.subTaskId));

  return (
    <div className="space-y-5">
      {stages.map((stage) => {
        const inStage = subtasks.filter((s) => s.stage === stage);
        const terminal = inStage.filter(
          (s) => s.status === "done" || s.status === "failed" || s.status === "blocked",
        ).length;
        const cleared = terminal === inStage.length;

        return (
          <div key={stage}>
            <div className="mb-2.5 flex flex-wrap items-center gap-x-2.5 gap-y-1">
              <span className="t-label">第 {stage + 1} 批</span>
              <Meta>{inStage.length} 个子任务并行</Meta>
              {cleared ? (
                <Badge tone="ok">屏障已通过</Badge>
              ) : (
                <Badge tone="info" dot>
                  {terminal}/{inStage.length} 完成
                </Badge>
              )}
            </div>

            <div className="grid gap-2.5 sm:grid-cols-2 xl:grid-cols-3">
              {inStage.map((s) => {
                const selected = s.id === selectedId;
                const runs = attemptsFor(s.id);
                return (
                  <button
                    key={s.id}
                    type="button"
                    onClick={() => onSelect(selected ? null : s.id)}
                    className="card-hover p-3.5 text-left"
                    style={
                      selected
                        ? {
                            borderColor: "var(--color-accent)",
                            background:
                              "color-mix(in oklch, var(--color-accent) 7%, var(--color-bg))",
                          }
                        : undefined
                    }
                    aria-pressed={selected}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <p className="text-[0.875rem] font-medium leading-snug">{s.title}</p>
                      <span className="flex shrink-0 flex-wrap items-center justify-end gap-1">
                        <SubTaskBadge status={s.status} />
                        {/*
                          "Nobody reviewed this" and "reviewers found things and the
                          rounds ran out" are both `in_review`, and they were
                          rendering as the same 待复核 badge — so a review outage
                          looked like agents having done their job and left notes.

                          No extra data needed to tell them apart: a review row
                          exists only for a FINDING, and a subtask reaches
                          in_review normally BECAUSE it had blocking findings. So
                          in_review with zero reviews means the review never
                          happened.
                        */}
                        {s.status === "in_review" && !reviewedIds.has(s.id) ? (
                          <Badge tone="warn" title="所有评审员都失败了，这份产出没有被任何人检查过">
                            未经评审
                          </Badge>
                        ) : null}
                      </span>
                    </div>
                    <p className="mt-2 line-clamp-2 t-meta">{s.brief}</p>
                    <div className="mt-2.5 flex flex-wrap items-center gap-x-2 gap-y-1">
                      {s.assigneeName ? (
                        <span className="text-[0.75rem] font-medium text-[var(--color-muted-fg)]">
                          {s.assigneeName}
                        </span>
                      ) : null}
                      {s.capability ? <Meta>{s.capability}</Meta> : null}
                      {runs > 0 ? <Meta>{runs} 次运行</Meta> : null}
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
}
