"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { api, ApiError } from "../lib/api.ts";
import type { RunResult, Task } from "../lib/types.ts";
import { IconCaret, IconCheck, IconX } from "./icons.tsx";

/**
 * What a finished run left behind, without leaving the task list.
 *
 * A drawer rather than a route, because reviewing a result is a glance in the
 * middle of working through a list — navigating away loses the scroll position,
 * the open groups, and the sense of where you were. `/runs/:id` still exists for
 * the full picture and the footer links to it, so deep links keep working.
 */

/**
 * How many diff lines to render.
 *
 * A snapshot is capped at 2M characters, which is roughly 50,000 lines — every one
 * of them a DOM node with a class. Rendering that blocks the main thread for
 * seconds on open. Anyone who needs to read a diff that size will read it in their
 * editor, so this caps and SAYS it capped; a silently shortened diff looks like a
 * complete one that happened to end there.
 */
const MAX_DIFF_LINES = 1_500;

/** Output shown before expanding. Matches the M3 spec. */
const OUTPUT_PREVIEW = 2_000;

type LineKind = "add" | "del" | "hunk" | "meta" | "ctx";

/**
 * Classifies one diff line.
 *
 * Order is load-bearing. `+++` and `---` are FILE HEADERS that happen to start
 * with the same characters as added and removed lines, so they have to be tested
 * first — otherwise every diff opens with a green line and a red line that are not
 * changes at all.
 */
function classify(line: string): LineKind {
  if (line.startsWith("+++") || line.startsWith("---")) return "meta";
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "del";
  if (
    line.startsWith("diff --git") ||
    line.startsWith("index ") ||
    line.startsWith("new file mode") ||
    line.startsWith("deleted file mode") ||
    line.startsWith("old mode") ||
    line.startsWith("new mode") ||
    line.startsWith("rename from") ||
    line.startsWith("rename to") ||
    line.startsWith("similarity index") ||
    line.startsWith("Binary files") ||
    line.startsWith("\\ No newline") ||
    // The status section this snapshot prepends, and its "[diff truncated: …]" tail.
    line.startsWith("# git status") ||
    line.startsWith("[diff truncated")
  ) {
    return "meta";
  }
  return "ctx";
}

export function ResultDrawer({
  task,
  onClose,
  onComplete,
  onRedispatch,
}: {
  task: Task;
  onClose: () => void;
  /** Accepts the work: PATCH done, then close. */
  onComplete: (task: Task) => void;
  /** Runs it again: POST run, then close. */
  onRedispatch: (task: Task) => void;
}) {
  const [result, setResult] = useState<RunResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showOutput, setShowOutput] = useState(false);

  const runId = task.runId;

  useEffect(() => {
    if (runId === null) return;
    let alive = true;
    setResult(null);
    setError(null);
    api
      .runResult(runId)
      .then((r) => {
        if (alive) setResult(r);
      })
      .catch((err: unknown) => {
        if (alive) setError(err instanceof ApiError ? err.message : String(err));
      });
    return () => {
      alive = false;
    };
  }, [runId]);

  // Escape closes. Registered on the document rather than the panel so it works
  // before anything inside has been focused.
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  const lines = useMemo(() => {
    const diff = result?.diff;
    if (diff === undefined || diff === null || diff === "") return null;
    const all = diff.split("\n");
    const shown = all.slice(0, MAX_DIFF_LINES);
    return { shown, hidden: all.length - shown.length };
  }, [result]);

  const inReview = task.status === "in_review";
  const failed = task.status === "needs_you";

  return (
    <>
      {/* Clicking away closes, which is the fastest exit for a glance. */}
      <div className="scrim" onClick={onClose} aria-hidden="true" />

      <aside className="drawer" role="dialog" aria-modal="true" aria-label="执行结果">
        <header className="dhead">
          <div className="grow">
            <div className="dtitle">{task.title}</div>
            <div className="dsub">
              {inReview ? "等你确认" : failed ? "需要你" : "已结束"}
              {result?.executor !== null && result?.executor !== undefined
                ? ` · ${result.executor}`
                : null}
            </div>
          </div>
          <button type="button" className="act ghost" aria-label="关闭" onClick={onClose}>
            <IconX />
          </button>
        </header>

        <div className="dbody">
          {/* The parked question or failure reason, in full — the row only had space
              for one line of it. */}
          {task.needsText !== null && task.needsText !== "" ? (
            <p className="dnote">{task.needsText}</p>
          ) : null}

          {error !== null ? (
            <p className="dempty" role="alert">
              读不到结果：{error}
            </p>
          ) : result === null ? (
            <p className="dempty">加载中…</p>
          ) : lines !== null ? (
            <>
              <pre className="diff">
                {lines.shown.map((line, i) => (
                  // Index keys are correct here: this list is derived from an
                  // immutable string and is never reordered or spliced.
                  <span key={i} className={`dl ${classify(line)}`}>
                    {line === "" ? " " : line}
                  </span>
                ))}
              </pre>
              {lines.hidden > 0 ? (
                <p className="dnote">
                  还有 {lines.hidden.toLocaleString()} 行没有显示。完整改动在仓库工作区里。
                </p>
              ) : null}
            </>
          ) : result.diff === "" ? (
            /*
             * Empty and null are different statements, and this is the one place the
             * difference is user-visible. A captured-but-empty snapshot means the
             * agent really changed nothing; a missing one means we never looked, and
             * saying "no changes" there would be false about a run that died
             * mid-edit.
             */
            <p className="dempty">没有文件改动</p>
          ) : (
            <p className="dempty">没有抓到改动快照（执行失败或被取消的任务不抓）。</p>
          )}

          {/* The agent's own words. Collapsed by default: it is usually a summary of
              what the diff above already shows. */}
          {result?.output !== null && result?.output !== undefined && result.output !== "" ? (
            <section className="dout">
              <button
                type="button"
                className="glabel toggle"
                aria-expanded={showOutput}
                onClick={() => setShowOutput((v) => !v)}
              >
                <IconCaret className="caret" />
                agent 输出
              </button>
              <pre className="outbody">
                {showOutput || result.output.length <= OUTPUT_PREVIEW
                  ? result.output
                  : `${result.output.slice(0, OUTPUT_PREVIEW)}…`}
              </pre>
            </section>
          ) : null}
        </div>

        <footer className="dfoot">
          {inReview ? (
            <button type="button" className="btn btn-primary" onClick={() => onComplete(task)}>
              <IconCheck />
              完成
            </button>
          ) : null}

          {/* Available in both states: accepting work you then want changed, and
              retrying a failure, are the same action. */}
          <button type="button" className="btn" onClick={() => onRedispatch(task)}>
            重派
          </button>

          {runId !== null ? (
            <Link href={`/runs/${runId}`} className="btn btn-ghost dmore">
              打开完整详情
            </Link>
          ) : null}
        </footer>
      </aside>
    </>
  );
}
