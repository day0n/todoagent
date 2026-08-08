"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { IconX } from "./icons.tsx";
import { RuntimeMark } from "./atoms.tsx";
import { StatefulButton } from "./stateful-button.tsx";
import {
  isRuntimeKind,
  preferredRuntimeKind,
  RUNTIME_STATUS_LABEL,
  runtimeLabel,
} from "../lib/runtime.ts";
import type { RuntimeInfo, RuntimeKind, Task } from "../lib/types.ts";

export const LAST_RUNTIME_STORAGE_KEY = "todoagent.runtime.lastExplicit";

function storedRuntime(): RuntimeKind | null {
  if (typeof window === "undefined") return null;
  const value = window.localStorage.getItem(LAST_RUNTIME_STORAGE_KEY);
  return isRuntimeKind(value) ? value : null;
}

/**
 * The single dispatch surface shared by the board, list rows, and result drawer.
 * Nothing runs until the person picks a ready CLI and presses the final button.
 */
export function RuntimePicker({
  task,
  runtimes,
  submitting,
  onClose,
  onConfirm,
}: {
  task: Task;
  runtimes: RuntimeInfo[] | null;
  submitting: boolean;
  onClose: () => void;
  onConfirm: (kind: RuntimeKind) => void;
}) {
  const [selected, setSelected] = useState<RuntimeKind | null>(() =>
    preferredRuntimeKind(runtimes ?? [], task.runtimeKind, storedRuntime()),
  );
  const panelRef = useRef<HTMLElement>(null);
  const onCloseRef = useRef(onClose);
  const submittingRef = useRef(submitting);

  useEffect(() => {
    onCloseRef.current = onClose;
    submittingRef.current = submitting;
  }, [onClose, submitting]);

  /* A late runtime fetch may make the sole usable choice available after open. */
  useEffect(() => {
    if (runtimes === null) return;
    setSelected((current) => {
      if (current !== null && runtimes.some((r) => r.kind === current && r.status === "ready")) {
        return current;
      }
      return preferredRuntimeKind(runtimes, task.runtimeKind, storedRuntime());
    });
  }, [runtimes, task.runtimeKind]);

  /* Modal semantics: enter it, keep Tab inside, Esc out, then restore the trigger. */
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    panelRef.current?.focus();

    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape" && !submittingRef.current) {
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      const panel = panelRef.current;
      if (panel === null) return;
      const focusable = panel.querySelectorAll<HTMLElement>(
        'button:not(:disabled), a[href], input:not(:disabled), [tabindex]:not([tabindex="-1"])',
      );
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (first === undefined || last === undefined) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      if (previous !== null && document.contains(previous)) previous.focus();
    };
  }, []);

  const readyCount = runtimes?.filter((runtime) => runtime.status === "ready").length ?? 0;
  const selectedInfo = runtimes?.find((runtime) => runtime.kind === selected);
  const canSubmit = selectedInfo?.status === "ready" && !submitting;

  const submit = (): void => {
    if (!canSubmit || selected === null) return;
    // This is the explicit confirmation point — failed launches still count as the
    // person's latest choice and should be offered when they try again.
    window.localStorage.setItem(LAST_RUNTIME_STORAGE_KEY, selected);
    onConfirm(selected);
  };

  return (
    <>
      <div
        className="runtime-picker-scrim"
        aria-hidden="true"
        onClick={submitting ? undefined : onClose}
      />
      <aside
        ref={panelRef}
        className="runtime-picker"
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-labelledby="runtime-picker-title"
      >
        <header className="runtime-picker-head">
          <div>
            <p className="runtime-picker-eyebrow">本机执行</p>
            <h2 id="runtime-picker-title">
              {task.runId === null ? "选择本机 CLI" : "重新选择本机 CLI"}
            </h2>
            <p title={task.title}>{task.title}</p>
          </div>
          <button
            type="button"
            className="runtime-picker-close"
            aria-label="关闭 CLI 选择"
            disabled={submitting}
            onClick={onClose}
          >
            <IconX />
          </button>
        </header>

        <div className="runtime-picker-body">
          <p className="runtime-picker-warning">
            CLI 会直接修改清单绑定的真实仓库。取消执行只会停止进程，已经产生的文件改动会保留。
          </p>

          {runtimes === null ? (
            <div className="runtime-picker-loading" role="status">
              正在读取本机 CLI…
            </div>
          ) : (
            <fieldset className="runtime-options">
              <legend className="sr-only">选择执行任务的本机 CLI</legend>
              {runtimes.map((runtime) => {
                const disabled = runtime.status !== "ready";
                const checked = selected === runtime.kind;
                return (
                  <label
                    key={runtime.kind}
                    className={`runtime-option${checked ? " selected" : ""}${disabled ? " disabled" : ""}`}
                  >
                    <input
                      type="radio"
                      name="runtime"
                      value={runtime.kind}
                      checked={checked}
                      disabled={disabled || submitting}
                      onChange={() => setSelected(runtime.kind)}
                    />
                    <span className="runtime-option-main">
                      <RuntimeMark
                        kind={runtime.kind}
                        name={runtimeLabel(runtime.kind, runtime.label)}
                      />
                      <span className={`runtime-state ${runtime.status}`}>
                        <i aria-hidden="true" />
                        {RUNTIME_STATUS_LABEL[runtime.status]}
                      </span>
                    </span>
                    <span className="runtime-option-detail">
                      {runtime.status === "ready"
                        ? [runtime.version, runtime.activeRuns > 0 ? `${runtime.activeRuns} 个任务运行中` : null]
                            .filter(Boolean)
                            .join(" · ") || "已经过真实连接验证"
                        : runtime.verifyError || unavailableHint(runtime.status)}
                    </span>
                  </label>
                );
              })}
            </fieldset>
          )}

          {runtimes !== null && readyCount === 0 ? (
            <div className="runtime-picker-empty">
              <strong>还没有可用的本机 CLI</strong>
              <span>先去设置页完成安装检测和真实连接验证。</span>
              <Link href="/settings" onClick={onClose}>
                前往本机 CLI 设置
              </Link>
            </div>
          ) : null}
        </div>

        <footer className="runtime-picker-foot">
          <button type="button" className="btn btn-ghost" disabled={submitting} onClick={onClose}>
            取消
          </button>
          <StatefulButton
            type="button"
            className="btn btn-primary"
            pending={submitting}
            pendingLabel="正在连接本机 CLI…"
            disabled={!canSubmit}
            onClick={submit}
          >
            {selected === null ? "请选择 CLI" : `使用 ${runtimeLabel(selected)} 开始执行`}
          </StatefulButton>
        </footer>
      </aside>
    </>
  );
}

function unavailableHint(status: RuntimeInfo["status"]): string {
  switch (status) {
    case "missing":
      return "未在本机找到可执行文件";
    case "unverified":
      return "验证连接后才能执行";
    case "verifying":
      return "正在执行真实连接验证";
    case "auth_required":
      return "请先在终端完成该 CLI 的登录";
    case "error":
      return "连接验证失败，请到设置页查看";
    case "ready":
      return "可用";
  }
}
