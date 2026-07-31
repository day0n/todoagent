"use client";

import { useState } from "react";
import type { Adjudication, DiscussionMessage, Review, SubTask } from "../lib/types.ts";
import { Badge, Meta, SectionHeader, SeverityBadge } from "./atoms.tsx";

/**
 * Review panel.
 *
 * The two-column layout IS the design's central rule made visible: a dispute a test
 * can settle is settled by a test, and only what a test cannot settle is worth a
 * person's attention. Listing findings as one undifferentiated pile would hide the
 * distinction that makes the whole pipeline worth its cost.
 */
export function ReviewPanel({
  reviews,
  adjudications,
  subtask,
}: {
  reviews: Review[];
  adjudications: Adjudication[];
  subtask: SubTask | null;
}) {
  const scoped = subtask === null ? reviews : reviews.filter((r) => r.subTaskId === subtask.id);

  if (scoped.length === 0) {
    return (
      <p className="t-meta">
        还没有评审意见。
        {subtask === null ? "" : " 这个子任务的产出会被另外两位专家独立评审。"}
      </p>
    );
  }

  const checkable = scoped.filter((r) => r.verifiable);
  const judgment = scoped.filter((r) => !r.verifiable);
  const verdicts =
    subtask === null ? adjudications : adjudications.filter((a) => a.subTaskId === subtask.id);

  return (
    <div className="space-y-8">
      <div className="grid gap-6 lg:grid-cols-2">
        <Column
          title="可验证的争议"
          count={checkable.length}
          tone="info"
          hint="交给测试判定。红灯说明问题真实存在，绿灯说明提出者判断有误 —— 一个能复现的用例胜过三轮争论。"
        >
          {checkable.length === 0 ? (
            <p className="t-meta">（无）</p>
          ) : (
            checkable.map((r) => <FindingCard key={r.id} review={r} />)
          )}
        </Column>

        <Column
          title="需要人判断的分歧"
          count={judgment.length}
          tone="grape"
          hint="审美、取舍、命名这类问题没有客观判据，只有这类才值得占用你的注意力。"
        >
          {judgment.length === 0 ? (
            <p className="t-meta">（无）</p>
          ) : (
            judgment.map((r) => <FindingCard key={r.id} review={r} />)
          )}
        </Column>
      </div>

      {verdicts.length > 0 ? (
        <section>
          <SectionHeader title="裁决" count={verdicts.length} />
          <div className="space-y-2.5">
            {verdicts.map((a) => (
              <VerdictCard key={a.id} adjudication={a} />
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}

function Column({
  title,
  count,
  tone,
  hint,
  children,
}: {
  title: string;
  count: number;
  tone: "info" | "grape";
  hint: string;
  children: React.ReactNode;
}) {
  const color = tone === "info" ? "var(--color-info)" : "var(--color-grape)";
  return (
    <section>
      <div className="mb-2 flex items-center gap-2.5">
        {/* A coloured rule instead of a badge: it groups the column without adding
            another pill to a screen that already has plenty. */}
        <span aria-hidden className="h-3.5 w-[3px] shrink-0 rounded-full" style={{ background: color }} />
        <h3 className="t-md">{title}</h3>
        <span className="t-meta font-medium">{count}</span>
      </div>
      <p className="mb-3 max-w-[46ch] text-balance t-meta">{hint}</p>
      <div className="space-y-2.5">{children}</div>
    </section>
  );
}

function FindingCard({ review }: { review: Review }) {
  const [open, setOpen] = useState(false);
  const hasDetail =
    review.evidence.length > 0 || review.suggestedTest !== null || review.patch !== null;

  // A refuted claim is settled — dimmed so the eye goes to what still stands.
  const settled = review.reproOutcome === "refuted";

  return (
    <div className="card p-3.5" style={settled ? { opacity: 0.5 } : undefined}>
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1.5">
        <SeverityBadge
          severity={review.severity}
          verifiable={review.verifiable}
          reproOutcome={review.reproOutcome}
        />
        {review.reviewerName ? <Meta>{review.reviewerName}</Meta> : null}
        {review.round > 1 ? <Meta>第 {review.round} 轮</Meta> : null}
      </div>

      <p className="mt-2.5 leading-snug">{review.claim}</p>

      {hasDetail ? (
        <button
          type="button"
          className="btn btn-ghost btn-sm mt-2 -ml-2"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
        >
          <span aria-hidden className="text-[0.625rem]">
            {open ? "▾" : "▸"}
          </span>
          {open ? "收起细节" : "查看证据"}
        </button>
      ) : null}

      {open ? (
        <div
          className="rise mt-2.5 space-y-3 border-t pt-3"
          style={{ borderColor: "var(--color-line)" }}
        >
          {review.evidence.length > 0 ? (
            <Detail label={review.reproOutcome === null ? "证据" : "复现结果"}>
              {review.evidence}
            </Detail>
          ) : null}
          {review.suggestedTest !== null ? (
            <Detail label="建议的验证方式">{review.suggestedTest}</Detail>
          ) : null}
          {review.patch !== null ? <Detail label="建议改法">{review.patch}</Detail> : null}
        </div>
      ) : null}
    </div>
  );
}

function Detail({ label, children }: { label: string; children: string }) {
  return (
    <div>
      <span className="t-label">{label}</span>
      <pre className="inset mono mt-1.5 max-h-56 overflow-y-auto whitespace-pre-wrap break-words p-2.5 text-[var(--color-muted-fg)]">
        {children}
      </pre>
    </div>
  );
}

function VerdictCard({ adjudication }: { adjudication: Adjudication }) {
  const spec =
    adjudication.verdict === "proceed"
      ? { tone: "ok" as const, label: "通过" }
      : adjudication.verdict === "rework"
        ? { tone: "warn" as const, label: "返工" }
        : { tone: "grape" as const, label: "上抛给人" };

  return (
    <div className="card p-3.5">
      <div className="flex items-center gap-2.5">
        <Badge tone={spec.tone} solid>
          {spec.label}
        </Badge>
        <Meta>第 {adjudication.round} 轮</Meta>
      </div>
      <p className="mt-2.5 body-muted">{adjudication.rationale}</p>

      {adjudication.humanDecision !== null ? (
        <div
          className="mt-3 rounded-[var(--radius-md)] border p-3"
          style={{
            borderColor: "color-mix(in oklch, var(--color-accent) 30%, transparent)",
            background: "var(--color-accent-soft)",
          }}
        >
          <span className="t-label">你的决定</span>
          <p className="mt-1">{adjudication.humanDecision}</p>
        </div>
      ) : null}
    </div>
  );
}

/**
 * Discussion thread.
 *
 * Bounded by construction — two rounds, and a participant with nothing to add passes
 * rather than padding. Unbounded agent chat converges on whoever spoke first, which
 * destroys the independent judgment that paying several vendors was supposed to buy.
 */
export function DiscussionThread({
  messages,
  subtask,
}: {
  messages: DiscussionMessage[];
  subtask: SubTask | null;
}) {
  const scoped = subtask === null ? messages : messages.filter((m) => m.subTaskId === subtask.id);
  if (scoped.length === 0) return null;

  const rounds = [...new Set(scoped.map((m) => m.round))].sort((a, b) => a - b);

  return (
    <section>
      <SectionHeader title="专家讨论" count={scoped.length} />
      <p className="mb-4 max-w-[62ch] text-balance t-meta">
        只对测试无法判定的点展开，最多两轮。没有「直到达成一致」这种终止条件 —— 那不是可判定的。
      </p>

      <div className="space-y-5">
        {rounds.map((round) => (
          <div key={round}>
            <div className="mb-2 flex items-center gap-2.5">
              <span className="t-label">第 {round} 轮</span>
              <span aria-hidden className="h-px flex-1" style={{ background: "var(--color-line)" }} />
            </div>
            <div className="space-y-2.5">
              {scoped
                .filter((m) => m.round === round)
                .map((m) => (
                  <div key={m.id} className="card p-3.5">
                    <span className="text-[0.8125rem] font-semibold">{m.authorName ?? "专家"}</span>
                    <p className="mt-1.5 whitespace-pre-wrap body-muted">{m.body}</p>
                  </div>
                ))}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

/** The human gate for a judgment call no test could decide. */
export function EscalationGate({
  adjudications,
  onResolve,
  busy,
}: {
  adjudications: Adjudication[];
  onResolve: (adjudicationId: string, decision: string) => void;
  busy: boolean;
}) {
  const open = adjudications.filter((a) => a.escalatedToHuman && a.humanDecision === null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  if (open.length === 0) return null;

  return (
    <div
      className="rise rounded-[var(--radius-lg)] border p-4"
      style={{
        borderColor: "color-mix(in oklch, var(--color-warn) 38%, transparent)",
        background: "color-mix(in oklch, var(--color-warn) 6%, var(--color-surface))",
        boxShadow: "var(--shadow-md), var(--highlight)",
      }}
    >
      <h3
        className="flex items-center gap-2 t-md"
        style={{ color: "var(--color-warn)" }}
      >
        <span aria-hidden>◆</span>
        需要你裁决
      </h3>
      <p className="mt-1.5 t-meta">以下分歧没有客观判据，只能由你来定。</p>

      <div className="mt-4 space-y-3.5">
        {open.map((a) => (
          <div key={a.id} className="inset p-3.5">
            <p className="body-muted">{a.rationale}</p>
            <textarea
              className="input mt-2.5 min-h-[4.5rem] resize-y"
              placeholder="你的决定，以及理由。会写进这次委托的记录，并直接交给 agent 执行。"
              value={drafts[a.id] ?? ""}
              onChange={(e) => setDrafts((d) => ({ ...d, [a.id]: e.target.value }))}
            />
            <button
              type="button"
              className="btn btn-primary btn-sm mt-2.5"
              disabled={busy || (drafts[a.id] ?? "").trim().length === 0}
              onClick={() => onResolve(a.id, (drafts[a.id] ?? "").trim())}
            >
              提交决定并继续
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
