"use client";

import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../../lib/api.ts";
import type { DetectedRuntime, Expert, Project, RuntimeKind, Team } from "../../lib/types.ts";
import {
  Badge,
  Empty,
  ErrorBox,
  Meta,
  RuntimeMark,
  SectionHeader,
  Spinner,
} from "../../components/atoms.tsx";

/*
 * Only roles the orchestrator actually selects.
 *
 * A `researcher` entry used to be listed here with a description of what it does —
 * while nothing in the pipeline ever picked it. Describing a role in the UI that
 * silently never runs is worse than omitting it: the user configures an expert, sees
 * it on the roster, and never learns why it produced nothing.
 */
const ROLE_LABEL: Record<string, string> = {
  orchestrator: "编排者",
  maker: "执行者",
  reviewer: "评审者",
  verifier: "验证者",
};

const ROLE_HINT: Record<string, string> = {
  orchestrator: "拆解目标、路由任务、做裁决",
  maker: "在独立 worktree 里干活",
  reviewer: "独立评审别人的产出",
  verifier: "跑复现测试、跑构建和测试",
};

const ROLE_ORDER = ["orchestrator", "maker", "reviewer", "verifier"] as const;

export default function TeamPage() {
  const [runtimes, setRuntimes] = useState<{
    detected: DetectedRuntime[];
    missing: string[];
  } | null>(null);
  const [experts, setExperts] = useState<Expert[] | null>(null);
  const [teams, setTeams] = useState<Team[] | null>(null);
  const [projects, setProjects] = useState<Project[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      const [rt, ex, tm, pr] = await Promise.all([
        api.runtimes(),
        api.experts(),
        api.teams(),
        api.projects(),
      ]);
      setRuntimes({ detected: rt.detected, missing: rt.missing });
      setExperts(ex);
      setTeams(tm);
      setProjects(pr);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  if (error !== null) {
    return (
      <div className="pt-12">
        <ErrorBox message={error} onRetry={() => void load()} />
      </div>
    );
  }

  if (runtimes === null || experts === null || teams === null || projects === null) {
    return (
      <div className="surface mt-12 p-6">
        <Spinner label="读取本机运行时" />
      </div>
    );
  }

  return (
    <div className="mx-auto w-full max-w-[880px] space-y-12 pt-12">
      <header>
        <h1 className="title-xl">团队</h1>
        <p className="mt-2 max-w-[58ch] text-balance body-muted">
          专家 = 一个身份 + 一个本机 CLI。角色决定它在流水线上的位置，能力标签决定它接哪类活。
        </p>
      </header>

      {/* ── Runtimes ── */}
      <section>
        <SectionHeader title="本机运行时" count={runtimes.detected.length} />
        <p className="mb-3 max-w-[62ch] text-balance meta">
          这里只证明二进制文件存在。凭据是否有效要跑一轮真实对话才知道 ——
          <code className="mono mx-1 rounded px-1" style={{ background: "var(--color-surface-sunken)" }}>
            pnpm doctor --probe
          </code>
          会逐个实测。
        </p>

        {runtimes.detected.length === 0 ? (
          <Empty
            icon="○"
            title="没有找到任何编码 CLI"
            hint="装一个就能用：claude / codex / cursor-agent / gemini / kiro-cli / grok。"
          />
        ) : (
          <div className="surface divide-line overflow-hidden">
            {runtimes.detected.map((rt) => (
              <div key={rt.kind} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3.5 py-2.5">
                <RuntimeMark kind={rt.kind} name={rt.kind} />
                <Meta>{rt.version}</Meta>
                <span className="mono ml-auto truncate text-[var(--color-fg-subtle)]">
                  {rt.execPath}
                </span>
              </div>
            ))}
          </div>
        )}

        {runtimes.missing.length > 0 ? (
          <p className="mt-2.5 meta">未安装：{runtimes.missing.join("、")}</p>
        ) : null}
      </section>

      {/* ── Experts ── */}
      <section>
        <SectionHeader title="专家" count={experts.length} />
        <p className="mb-3 max-w-[62ch] text-balance meta">
          「谁擅长什么」目前是社区经验，每次模型更新都会漂移，所以它是数据而不是写死的逻辑。
          每次委托都会记录谁做的、评审结论、最终是否被采纳，跑够二十次就能用真实数据校准。
        </p>

        <div className="grid gap-2.5 sm:grid-cols-2">
          {experts.length === 0 ? (
            <div className="sm:col-span-2">
              <Empty
                icon="◇"
                title="还没有专家"
                hint="运行 pnpm seed <仓库路径>，它会按已装的 CLI 自动组一队。"
              />
            </div>
          ) : (
            experts.map((e) => <ExpertCard key={e.id} expert={e} />)
          )}
        </div>
      </section>

      {/* ── Teams ── */}
      <section>
        <SectionHeader title="编队" count={teams.length} />
        <p className="mb-3 max-w-[62ch] text-balance meta">
          角色和能力是两个正交的维度：一队可以有两个执行者，一个擅长视觉、一个擅长后端。
        </p>
        <div className="space-y-2.5">
          {teams.length === 0 ? (
            <Empty icon="◇" title="还没有编队" />
          ) : (
            teams.map((t) => <TeamCard key={t.id} team={t} />)
          )}
        </div>
      </section>

      {/* ── Projects ── */}
      <section>
        <SectionHeader title="项目" count={projects.length} />
        <p className="mb-3 max-w-[62ch] text-balance meta">
          必须是 git 仓库 —— 并行执行靠 worktree 隔离，没有它多个 agent 会互相覆盖。
        </p>
        <div className="space-y-2.5">
          {projects.length === 0 ? (
            <Empty icon="◇" title="还没有项目" />
          ) : (
            projects.map((p) => {
              const team = teams.find((t) => t.id === p.teamId);
              return (
                <div key={p.id} className="surface px-3.5 py-3">
                  <div className="flex flex-wrap items-center gap-2.5">
                    <span className="font-medium">{p.name}</span>
                    {team ? (
                      <Badge tone="accent">{team.name}</Badge>
                    ) : (
                      <Badge tone="warn">编队缺失</Badge>
                    )}
                  </div>
                  <p className="mono mt-1.5 truncate text-[var(--color-fg-subtle)]">{p.repoPath}</p>
                </div>
              );
            })
          )}
        </div>
      </section>
    </div>
  );
}

function ExpertCard({ expert }: { expert: Expert }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="surface p-3.5">
      <div className="flex items-start justify-between gap-2.5">
        <div className="min-w-0">
          <RuntimeMark kind={expert.runtimeKind as RuntimeKind} name={expert.name} showKind />
          <p className="mt-1.5 meta">{expert.description}</p>
        </div>
      </div>

      {expert.capabilities.length > 0 ? (
        <div className="mt-2.5 flex flex-wrap gap-1.5">
          {expert.capabilities.map((c) => (
            <span
              key={c}
              className="rounded-[0.375rem] px-1.5 py-0.5 text-[0.6875rem] text-[var(--color-fg-muted)]"
              style={{ background: "var(--color-surface-sunken)" }}
            >
              {c}
            </span>
          ))}
        </div>
      ) : null}

      {expert.systemPrompt.length > 0 ? (
        <>
          <button
            type="button"
            className="btn btn-ghost btn-sm mt-2.5 -ml-2"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
          >
            <span aria-hidden className="text-[0.625rem]">
              {open ? "▾" : "▸"}
            </span>
            {open ? "收起提示词" : "查看提示词"}
          </button>
          {open ? (
            <pre className="surface-inset mono rise mt-2 max-h-56 overflow-y-auto whitespace-pre-wrap break-words p-2.5 text-[var(--color-fg-muted)]">
              {expert.systemPrompt}
            </pre>
          ) : null}
        </>
      ) : null}
    </div>
  );
}

function TeamCard({ team }: { team: Team }) {
  // One expert may hold several roles, so group by role rather than by person.
  const byRole = new Map<string, string[]>();
  for (const m of team.members) {
    byRole.set(m.role, [...(byRole.get(m.role) ?? []), m.name]);
  }
  const missing = ROLE_ORDER.filter((r) => (byRole.get(r) ?? []).length === 0);
  const singleVendor = new Set(team.members.map((m) => m.runtimeKind)).size <= 1;

  return (
    <div className="surface p-3.5">
      <div className="flex flex-wrap items-center gap-2.5">
        <span className="font-medium">{team.name}</span>
        <Meta>{team.members.length} 个成员位</Meta>
      </div>

      <div className="mt-3 space-y-2">
        {ROLE_ORDER.map((role) => {
          const names = byRole.get(role) ?? [];
          if (names.length === 0) return null;
          return (
            <div key={role} className="flex flex-wrap items-baseline gap-x-2.5 gap-y-0.5">
              <span className="w-[3.75rem] shrink-0 text-[0.75rem] font-semibold text-[var(--color-fg-muted)]">
                {ROLE_LABEL[role] ?? role}
              </span>
              <span className="text-[0.8125rem]">{names.join("、")}</span>
              <span className="meta">{ROLE_HINT[role]}</span>
            </div>
          );
        })}
      </div>

      {missing.length > 0 ? (
        <p className="mt-3 text-[0.8125rem]" style={{ color: "var(--color-warn)" }}>
          缺少角色：{missing.map((r) => ROLE_LABEL[r] ?? r).join("、")}
        </p>
      ) : null}

      {singleVendor ? (
        <p className="mt-2 text-[0.8125rem]" style={{ color: "var(--color-warn)" }}>
          只有一个厂商的运行时 —— 评审等于自审，多厂商交叉评审的独立视角优势不存在。
        </p>
      ) : null}
    </div>
  );
}
