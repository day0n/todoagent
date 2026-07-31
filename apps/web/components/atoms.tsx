import type { Phase, RunStatus, RuntimeKind, SubTaskStatus } from "../lib/types.ts";
import { PHASE_LABEL, STATUS_LABEL } from "../lib/types.ts";

/**
 * Semantic tones, expressed as brutalist fills.
 *
 * In this style a tag is a black-outlined box with a solid fill, so a tone is a
 * BACKGROUND rather than a text colour. Ink stays constant for contrast — the fills
 * are all light enough to carry 700-weight near-black text, which is what keeps the
 * palette legible without a second thought.
 */
export type Tone = "ok" | "warn" | "bad" | "info" | "grape" | "mute" | "accent" | "signal";

const FILL: Record<Tone, string> = {
  ok: "var(--color-ok-soft)",
  warn: "var(--color-warn-soft)",
  bad: "var(--color-bad-soft)",
  info: "var(--color-aqua-soft)",
  grape: "var(--color-grape-soft)",
  mute: "var(--color-faint)",
  accent: "var(--color-accent-soft)",
  signal: "var(--color-signal-soft)",
};

/** The saturated version, for a tag that must interrupt. */
const SOLID: Record<Tone, string> = {
  ok: "var(--color-ok)",
  warn: "var(--color-warn)",
  bad: "var(--color-bad)",
  info: "var(--color-aqua)",
  grape: "var(--color-grape)",
  mute: "var(--color-faint-2)",
  accent: "var(--color-accent)",
  signal: "var(--color-signal)",
};

/** Solid dark fills need light text; the light ones do not. */
const NEEDS_LIGHT_TEXT = new Set<Tone>(["ok", "warn", "bad"]);

export function Badge({
  children,
  tone = "mute",
  solid = false,
  title,
  dot = false,
}: {
  children: React.ReactNode;
  tone?: Tone;
  solid?: boolean;
  title?: string;
  /** Adds a blinking square — for a live state where fill alone is too static. */
  dot?: boolean;
}) {
  return (
    <span
      className="tag"
      title={title}
      style={
        solid
          ? {
              background: SOLID[tone],
              color: NEEDS_LIGHT_TEXT.has(tone) ? "var(--color-paper)" : "var(--color-ink)",
            }
          : { background: FILL[tone] }
      }
    >
      {dot ? (
        <span
          aria-hidden
          className="blink inline-block h-1.5 w-1.5 shrink-0"
          style={{ background: "currentColor" }}
        />
      ) : null}
      {children}
    </span>
  );
}

/** Plain metadata. Used instead of a tag for anything that is not a state. */
export function Meta({ children, title }: { children: React.ReactNode; title?: string }) {
  return (
    <span className="t-meta" title={title}>
      {children}
    </span>
  );
}

export function Dot() {
  return (
    <span aria-hidden className="text-mute opacity-50">
      /
    </span>
  );
}

const STATUS_TONE: Record<RunStatus, Tone> = {
  running: "info",
  blocked_on_human: "signal",
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
  in_review: { tone: "signal", label: "待复核" },
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
 * A member's mark: a filled square plus their name.
 *
 * A square, not a circle — there is not a single rounded corner in this system. Each
 * vendor keeps a stable hue so a wall of parallel output is scannable by author
 * without reading names.
 */
const RUNTIME_FILL: Record<RuntimeKind, Tone> = {
  claude: "accent",
  codex: "ok",
  cursor: "info",
  gemini: "grape",
  kiro: "signal",
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
  return (
    <span className="inline-flex items-center gap-1.5" title={`runtime: ${kind}`}>
      <span
        aria-hidden
        className="inline-block h-3.5 w-3.5 shrink-0 border-2 border-ink"
        style={{ background: SOLID[RUNTIME_FILL[kind] ?? "mute"] }}
      />
      <span className="text-[0.8125rem] font-bold">{name ?? kind}</span>
      {showKind && name ? <span className="t-meta">{kind}</span> : null}
    </span>
  );
}

/**
 * A finding's severity and how it was settled.
 *
 * The verdict tag is `solid` deliberately: "reproduced" versus "refuted" is the
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

export function PhaseBadge({ phase }: { phase: Phase }) {
  return <Badge tone="signal">{PHASE_LABEL[phase] ?? phase}</Badge>;
}

export function Spinner({ label }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-2.5 font-semibold">
      {/* A square that blinks rather than a spinning ring — a smooth circle would be
          the only curved, continuously-animated thing on the page. */}
      <span aria-hidden className="blink inline-block h-3 w-3 border-2 border-ink bg-signal" />
      {label ?? "加载中"}
    </span>
  );
}

export function ErrorBox({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div role="alert" className="brut pop p-3.5" style={{ background: "var(--color-bad-soft)" }}>
      <div className="t-md flex items-center gap-2">
        <span aria-hidden>!</span>
        出错了
      </div>
      <p className="mt-1.5 whitespace-pre-wrap">{message}</p>
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
    <div className="brut-inset grid place-items-center px-6 py-12 text-center">
      {icon ? (
        <div
          aria-hidden
          className="mb-3 grid h-9 w-9 place-items-center border-2 border-ink bg-paper text-base font-bold"
        >
          {icon}
        </div>
      ) : null}
      <p className="font-bold">{title}</p>
      {hint ? <p className="t-meta mt-1.5 max-w-md text-balance">{hint}</p> : null}
    </div>
  );
}

/**
 * Budget meter.
 *
 * A segmented bar rather than a smooth gradient: this style has no soft fills, and
 * discrete blocks also make "roughly how much is left" readable at a glance. Amber
 * past 70%, red past 90% — the ceiling is a hard stop, so it should look like one
 * before it arrives.
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
  const SEGMENTS = 10;
  const lit = Math.max(1, Math.round((pct / 100) * SEGMENTS));

  return (
    <div
      className={`flex gap-0.5 ${className}`}
      title={`${spent.toLocaleString()} / ${budget.toLocaleString()} tokens (${pct}%)`}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label="预算用量"
    >
      {Array.from({ length: SEGMENTS }, (_, i) => (
        <span
          key={i}
          aria-hidden
          className="h-2 flex-1 border-2 border-ink"
          style={{ background: i < lit ? SOLID[tone] : "var(--color-paper)" }}
        />
      ))}
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
    <div className="mb-3 flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
      <h2 className="t-md">{title}</h2>
      {count !== undefined && count > 0 ? (
        <span className="tag" style={{ background: "var(--color-faint)" }}>
          {count}
        </span>
      ) : null}
      {hint ? <span className="t-meta">{hint}</span> : null}
      {right ? <div className="ml-auto">{right}</div> : null}
    </div>
  );
}
