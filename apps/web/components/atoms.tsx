import type { RunStatus, RuntimeKind, SubTaskStatus } from "../lib/types.ts";
import { STATUS_LABEL } from "../lib/types.ts";
import { runtimeLabel } from "../lib/runtime.ts";

/**
 * Semantic tones.
 *
 * A tone is a PAIR: a low-chroma wash plus the saturated ink that sits on it.
 * That is what lets a badge stay legible without a border, and it keeps colour
 * cheap enough that a dense page is not a fruit salad.
 *
 * Colour discipline matters here more than in most UIs: this app shows several
 * agents' parallel output at once, so hue is reserved for state a person acts on
 * — a blocker, a gate, a failure. Structure is carried by greys.
 */
export type Tone = "ok" | "warn" | "bad" | "info" | "grape" | "accent" | "mute";

const TONE: Record<Tone, { bg: string; fg: string }> = {
  ok: { bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  warn: { bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  bad: { bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  info: { bg: "var(--color-info-soft)", fg: "var(--color-info)" },
  grape: { bg: "var(--color-grape-soft)", fg: "var(--color-grape)" },
  accent: { bg: "var(--color-accent-soft)", fg: "var(--color-accent)" },
  mute: { bg: "var(--color-muted)", fg: "var(--color-muted-fg)" },
};

export function Badge({
  children,
  tone = "mute",
  solid = false,
  title,
  dot = false,
}: {
  children: React.ReactNode;
  tone?: Tone;
  /** Inverts to a filled chip. For the one verdict in a row that must interrupt. */
  solid?: boolean;
  title?: string;
  /** Adds a breathing dot — for a live state where a static fill reads as stale. */
  dot?: boolean;
}) {
  const t = TONE[tone] ?? TONE.mute;
  return (
    <span
      className="tag"
      title={title}
      style={
        solid ? { background: t.fg, color: "var(--color-bg)" } : { background: t.bg, color: t.fg }
      }
    >
      {dot ? (
        <span
          aria-hidden
          className="pulse inline-block h-1.5 w-1.5 shrink-0 rounded-full"
          style={{ background: "currentColor" }}
        />
      ) : null}
      {children}
    </span>
  );
}

/** Plain metadata. Used instead of a badge for anything that is not a state. */
export function Meta({ children, title }: { children: React.ReactNode; title?: string }) {
  return (
    <span className="t-meta" title={title}>
      {children}
    </span>
  );
}

export function Dot() {
  return (
    <span aria-hidden className="select-none text-subtle-fg">
      ·
    </span>
  );
}

const STATUS_TONE: Record<RunStatus, Tone> = {
  running: "info",
  // Amber, because this is the one state whose entire meaning is "a person must
  // act before anything else happens".
  blocked_on_human: "warn",
  completed: "ok",
  failed: "bad",
  cancelled: "mute",
  budget_exceeded: "warn",
};

export function StatusBadge({ status }: { status: RunStatus }) {
  return (
    <Badge tone={STATUS_TONE[status] ?? "mute"} dot={status === "running"}>
      {STATUS_LABEL[status] ?? status}
    </Badge>
  );
}

const SUBTASK: Record<SubTaskStatus, { tone: Tone; label: string }> = {
  todo: { tone: "mute", label: "待开始" },
  running: { tone: "info", label: "进行中" },
  // Purple keeps "waiting on review" distinct from both "running" and "needs
  // you" — three different kinds of not-done that are easy to conflate.
  in_review: { tone: "grape", label: "待复核" },
  reworking: { tone: "warn", label: "返工中" },
  done: { tone: "ok", label: "已完成" },
  blocked: { tone: "warn", label: "已阻塞" },
  failed: { tone: "bad", label: "失败" },
};

export function SubTaskBadge({ status }: { status: SubTaskStatus }) {
  const spec = SUBTASK[status] ?? { tone: "mute" as Tone, label: status };
  return (
    <Badge tone={spec.tone} dot={status === "running"}>
      {spec.label}
    </Badge>
  );
}

/**
 * A member's mark: a small tinted tile plus their name.
 *
 * Each vendor keeps a stable hue so a wall of parallel output is scannable by
 * author without reading names. The tile is an avatar shape rather than a status
 * pill on purpose — it sits beside status badges constantly, and identity must
 * not be mistaken for state.
 *
 * No cast on this map: an exhaustive Record is what catches a missing or
 * misspelled runtime at compile time, which is the only reason it is typed
 * rather than a plain object.
 */
const RUNTIME_TONE: Record<RuntimeKind, Tone> = {
  claude: "warn",
  codex: "ok",
  cursor: "info",
  gemini: "grape",
  kiro: "accent",
  grok: "bad",
};

export function RuntimeMark({
  kind,
  name,
  showKind = false,
}: {
  kind: RuntimeKind;
  name?: string;
  showKind?: boolean;
}) {
  const t = TONE[RUNTIME_TONE[kind] ?? "mute"] ?? TONE.mute;
  const label = runtimeLabel(kind, name);
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5" title={`runtime: ${kind}`}>
      <span
        aria-hidden
        className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] text-[9px] font-semibold uppercase"
        style={{ background: t.bg, color: t.fg }}
      >
        {label.slice(0, 1)}
      </span>
      <span className="truncate text-[0.8125rem] font-medium">{label}</span>
      {showKind && name ? <span className="t-meta shrink-0">{kind}</span> : null}
    </span>
  );
}

/**
 * A finding's severity and how it was settled.
 *
 * The verdict chip is `solid` deliberately: "reproduced" versus "refuted" is the
 * difference between a real defect and a reviewer being wrong, and it is the one
 * place in this UI where colour carries the meaning rather than decorating it.
 */
export function SeverityBadge({
  severity,
  verifiable,
  reproOutcome,
}: {
  severity: "blocker" | "major" | "nit";
  verifiable: boolean;
  reproOutcome: "confirmed" | "refuted" | "inconclusive" | null;
}) {
  const spec =
    severity === "blocker"
      ? { tone: "bad" as Tone, label: "阻塞" }
      : severity === "major"
        ? { tone: "warn" as Tone, label: "重要" }
        : { tone: "mute" as Tone, label: "小问题" };

  return (
    <span className="inline-flex flex-wrap items-center gap-1.5">
      <Badge tone={spec.tone}>{spec.label}</Badge>
      {verifiable ? (
        reproOutcome === "confirmed" ? (
          <Badge tone="bad" solid title="跑了测试，问题真实存在">
            已复现
          </Badge>
        ) : reproOutcome === "refuted" ? (
          <Badge tone="ok" solid title="跑了测试，这个判断不成立">
            已否证
          </Badge>
        ) : reproOutcome === "inconclusive" ? (
          <Badge tone="mute" title="无法搭出可信的验证">
            无法判定
          </Badge>
        ) : (
          <Badge tone="info" title="声称可以用测试判定">
            待验证
          </Badge>
        )
      ) : (
        <Badge tone="grape" title="没有客观判据，需要人来定">
          主观判断
        </Badge>
      )}
    </span>
  );
}

export function Spinner({ label }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-muted-fg">
      <span
        aria-hidden
        className="inline-block h-3.5 w-3.5 shrink-0 animate-spin rounded-full border-2 border-line"
        style={{ borderTopColor: "var(--color-accent)" }}
      />
      {label ?? "加载中"}
    </span>
  );
}

export function ErrorBox({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div
      role="alert"
      className="rise rounded-[var(--radius)] border p-3"
      style={{
        background: "var(--color-bad-soft)",
        borderColor: "color-mix(in oklab, var(--color-bad) 26%, transparent)",
      }}
    >
      <div className="font-medium" style={{ color: "var(--color-bad)" }}>
        出错了
      </div>
      <p className="mt-1 break-anywhere whitespace-pre-wrap">{message}</p>
      {onRetry ? (
        <button type="button" className="btn btn-sm mt-2.5" onClick={onRetry}>
          重试
        </button>
      ) : null}
    </div>
  );
}

export function Empty({
  title,
  hint,
  icon,
}: {
  title: string;
  hint?: string;
  icon?: React.ReactNode;
}) {
  return (
    <div className="grid place-items-center px-6 py-14 text-center">
      {icon ? (
        <div
          aria-hidden
          className="mb-3 grid h-9 w-9 place-items-center rounded-[var(--radius-sm)] border border-line bg-surface text-muted-fg"
        >
          {icon}
        </div>
      ) : null}
      <p className="font-medium">{title}</p>
      {hint ? <p className="t-meta mt-1 max-w-md text-balance">{hint}</p> : null}
    </div>
  );
}

/**
 * Budget meter.
 *
 * A single thin bar rather than segments: the exact figure lives in the title and
 * the adjacent text, so the bar's only job is "roughly how close to the wall".
 * Amber past 70%, red past 90% — the ceiling is a hard stop that kills a run, so
 * it should look like one before it arrives rather than after.
 */
export function BudgetMeter({
  spent,
  budget,
  className = "",
}: {
  spent: number;
  budget: number;
  className?: string;
}) {
  if (budget <= 0) return null;
  const pct = Math.min(100, Math.round((spent / budget) * 100));
  const tone: Tone = pct >= 90 ? "bad" : pct >= 70 ? "warn" : "ok";

  return (
    <div
      className={`h-1 w-full overflow-hidden rounded-full bg-muted ${className}`}
      title={`${spent.toLocaleString()} / ${budget.toLocaleString()} tokens (${pct}%)`}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label="预算用量"
    >
      <div
        className="h-full rounded-full transition-[width] duration-500 ease-out"
        style={{ width: `${Math.max(pct, 1.5)}%`, background: TONE[tone].fg }}
      />
    </div>
  );
}

export function SectionHeader({
  title,
  count,
  hint,
  right,
}: {
  title: string;
  count?: number;
  hint?: string;
  right?: React.ReactNode;
}) {
  return (
    <div className="mb-3 flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <h2 className="t-md">{title}</h2>
      {count !== undefined && count > 0 ? <span className="tag">{count}</span> : null}
      {hint ? <span className="t-meta">{hint}</span> : null}
      {right ? <div className="ml-auto">{right}</div> : null}
    </div>
  );
}
