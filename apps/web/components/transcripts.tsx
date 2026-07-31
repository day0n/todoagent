"use client";

import { useCallback, useState } from "react";
import { api, ApiError, fmtDuration, fmtTokens, fmtUsd } from "../lib/api.ts";
import type { Attempt, AttemptTranscript, RuntimeKind, SubTask } from "../lib/types.ts";
import { Badge, Meta, RuntimeMark, SectionHeader, Spinner } from "./atoms.tsx";

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
 * Historical agent turns, with transcripts fetched on demand.
 *
 * Closes a real gap: the live cards only exist inside the SSE session that produced
 * them, so reloading a finished run showed no agent output at all — the transcripts
 * were in the database with no way to read them.
 *
 * Output is deliberately NOT part of the run payload (211 KB of a measured 292 KB,
 * refetched on every structural event, for text nothing rendered). So this component
 * pays that cost once per transcript, only when a user asks.
 */
export function AttemptHistory({
  runId,
  attempts,
  subtasks,
  filterSubTaskId,
}: {
  runId: string;
  attempts: Attempt[];
  subtasks: SubTask[];
  filterSubTaskId: string | null;
}) {
  const scoped =
    filterSubTaskId === null ? attempts : attempts.filter((a) => a.subTaskId === filterSubTaskId);

  if (scoped.length === 0) return null;

  const titleOf = (id: string | null): string =>
    id === null ? "整体" : (subtasks.find((s) => s.id === id)?.title ?? "已删除的子任务");

  const totalTokens = scoped.reduce((n, a) => n + a.inputTokens + a.outputTokens, 0);

  return (
    <section>
      <SectionHeader
        title="运行记录"
        count={scoped.length}
        right={<Meta>{fmtTokens(totalTokens)} tokens</Meta>}
      />
      <p className="mb-3 max-w-[62ch] text-balance t-meta">
        每次 agent 运行的完整输出都保留着。点开才会加载 —— 一次委托的成绩单加起来有几百 KB，默认全传会让页面变慢。
      </p>

      <div className="card divide-line overflow-hidden">
        {scoped.map((a) => (
          <AttemptRow key={a.id} runId={runId} attempt={a} scopeLabel={titleOf(a.subTaskId)} />
        ))}
      </div>
    </section>
  );
}

function AttemptRow({
  runId,
  attempt,
  scopeLabel,
}: {
  runId: string;
  attempt: Attempt;
  scopeLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const [transcript, setTranscript] = useState<AttemptTranscript | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const toggle = useCallback(() => {
    const next = !open;
    setOpen(next);
    // Cached after the first fetch: expanding and collapsing repeatedly must not
    // re-download a transcript that cannot change once the attempt has ended.
    if (!next || transcript !== null || loading) return;
    setLoading(true);
    setError(null);
    api
      .attempt(runId, attempt.id)
      .then(setTranscript)
      .catch((err: unknown) => setError(err instanceof ApiError ? err.message : String(err)))
      .finally(() => setLoading(false));
  }, [open, transcript, loading, runId, attempt.id]);

  const cost = fmtUsd(attempt.costUsd);
  const failed = attempt.status !== "completed";

  return (
    <div>
      <button
        type="button"
        onClick={toggle}
        aria-expanded={open}
        className="flex w-full flex-wrap items-center gap-x-2.5 gap-y-1 px-3.5 py-2.5 text-left transition-colors duration-150 hover:bg-surface-2"
      >
        <span aria-hidden className="w-3 shrink-0 text-[0.625rem] text-[var(--color-subtle-fg)]">
          {open ? "▾" : "▸"}
        </span>
        <RuntimeMark kind={attempt.runtimeKind as RuntimeKind} name={attempt.expertName} />
        <Meta>{KIND_LABEL[attempt.kind] ?? attempt.kind}</Meta>
        <span className="truncate t-meta">{scopeLabel}</span>

        <span className="ml-auto flex shrink-0 items-center gap-2.5">
          {attempt.outputChars > 0 ? <Meta>{fmtTokens(attempt.outputChars)} 字</Meta> : null}
          <Meta title={`${(attempt.inputTokens + attempt.outputTokens).toLocaleString()} tokens`}>
            {fmtTokens(attempt.inputTokens + attempt.outputTokens)}
          </Meta>
          {cost !== null ? <Meta>{cost}</Meta> : null}
          <Meta>{fmtDuration(attempt.startedAt, attempt.endedAt)}</Meta>
          {failed ? <Badge tone="bad">{attempt.status}</Badge> : null}
        </span>
      </button>

      {open ? (
        <div
          className="rise border-t px-3.5 py-3"
          style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
        >
          {loading ? (
            <Spinner label="加载成绩单" />
          ) : error !== null ? (
            <p className="text-[0.8125rem]" style={{ color: "var(--color-bad)" }}>
              {error}
            </p>
          ) : transcript === null ? (
            <p className="t-meta">（无内容）</p>
          ) : (
            <>
              {transcript.error !== null ? (
                <p className="mb-2.5 text-[0.8125rem]" style={{ color: "var(--color-bad)" }}>
                  {transcript.error}
                </p>
              ) : null}
              {transcript.output !== null && transcript.output.length > 0 ? (
                <pre className="mono max-h-[24rem] overflow-auto whitespace-pre-wrap break-words text-[var(--color-muted-fg)]">
                  {transcript.output}
                </pre>
              ) : (
                <p className="t-meta">这次运行没有产生文本输出。</p>
              )}
            </>
          )}
        </div>
      ) : null}
    </div>
  );
}
