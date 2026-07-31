"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { api } from "../lib/api.ts";
import type { DetectedRuntime, Expert, Project, RuntimeKind } from "../lib/types.ts";

/**
 * The workspace shell: an icon rail, a channel sidebar, and one panel.
 *
 * This is the structural half of matching Raft. Their primary surface is a chat
 * workspace, not a list of jobs — the app is a persistent sidebar of channels and
 * members with a single panel beside it, like a chat client, rather than a
 * document that scrolls as a whole.
 *
 * Projects ARE the channels. Raft's own guidance is "one channel per project or
 * workstream", and a Council project is exactly one repository's stream of work,
 * so mapping them keeps a single source of truth instead of inventing a parallel
 * container.
 *
 * Only destinations that exist are linked. Raft's rail also carries search,
 * activity, files and settings; wiring icons to routes this app does not have
 * would look complete and behave broken.
 */

/** Runtime tile hues, matching `RuntimeMark` in atoms.tsx. */
const RUNTIME_TONE: Record<RuntimeKind, { bg: string; fg: string }> = {
  claude: { bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  codex: { bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  cursor: { bg: "var(--color-info-soft)", fg: "var(--color-info)" },
  gemini: { bg: "var(--color-grape-soft)", fg: "var(--color-grape)" },
  kiro: { bg: "var(--color-accent-soft)", fg: "var(--color-accent)" },
  grok: { bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};

export function WorkspaceShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [projects, setProjects] = useState<Project[]>([]);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [runtimes, setRuntimes] = useState<DetectedRuntime[]>([]);
  const [offline, setOffline] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const load = useCallback(async () => {
    try {
      const [ps, ex, rt] = await Promise.all([api.projects(), api.experts(), api.runtimes()]);
      setProjects(ps);
      setExperts(ex);
      setRuntimes(rt.detected);
      setOffline(false);
    } catch {
      // The engine is a separate local process, so "not running" is the most
      // common state on a cold start. The sidebar says so rather than rendering
      // as an empty workspace, which would look like data loss.
      setOffline(true);
    } finally {
      setLoaded(true);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const online = new Set(runtimes.map((r) => r.kind));

  return (
    <div className="flex h-full">
      {/* ── Icon rail ──
          Always visible, even on a narrow screen: it is the only way back to the
          two top-level views. */}
      <nav
        aria-label="主导航"
        className="flex w-[var(--w-rail)] shrink-0 flex-col items-center gap-1 border-r border-line bg-surface py-2.5"
      >
        <Link
          href="/"
          aria-label="Council 首页"
          className="mb-1.5 grid h-8 w-8 place-items-center rounded-[var(--radius-sm)] bg-fg text-[13px] font-semibold text-bg"
        >
          C
        </Link>
        <RailIcon href="/" active={pathname === "/"} label="委托" glyph="◧" />
        <RailIcon href="/team" active={pathname === "/team"} label="团队" glyph="◍" />

        <button
          type="button"
          className="btn btn-icon btn-sm btn-ghost mt-auto md:hidden"
          onClick={() => setSidebarOpen((v) => !v)}
          aria-label="切换频道栏"
          aria-expanded={sidebarOpen}
        >
          ☰
        </button>
      </nav>

      {/* ── Channel sidebar ── */}
      <aside
        className={`absolute inset-y-0 left-[var(--w-rail)] z-30 flex w-[var(--w-sidebar)] shrink-0 flex-col border-r border-line bg-bg transition-transform duration-150 md:static md:left-auto md:translate-x-0 ${
          sidebarOpen ? "translate-x-0" : "-translate-x-[120%]"
        }`}
      >
        <div className="app-header">
          <span className="t-md truncate">工作区</span>
          <span
            aria-hidden
            className={`ml-auto h-1.5 w-1.5 shrink-0 rounded-full ${offline ? "bg-bad" : "bg-ok"}`}
            title={offline ? "引擎未连接" : "引擎在线"}
          />
        </div>

        <div className="flex-1 overflow-y-auto px-2 py-3">
          <Section title="频道" count={projects.length}>
            {offline ? (
              <Hint>引擎未启动</Hint>
            ) : !loaded ? (
              <Hint>载入中…</Hint>
            ) : projects.length === 0 ? (
              <Hint>还没有项目</Hint>
            ) : (
              projects.map((p) => (
                <Link
                  key={p.id}
                  href={`/?project=${encodeURIComponent(p.id)}`}
                  className="nav-row"
                  title={p.repoPath}
                  onClick={() => setSidebarOpen(false)}
                >
                  <span aria-hidden className="shrink-0 text-subtle-fg">
                    #
                  </span>
                  <span className="truncate">{p.name}</span>
                </Link>
              ))
            )}
          </Section>

          {/*
            Agents grouped under the machine they run on, the way Raft's members
            page does it — a machine row, then its agents with a presence dot.
            The grouping is the point: these are local CLIs, so which computer
            they live on is what determines whether they can run at all.

            The machine is labelled "本机" rather than a hostname because the
            engine does not report one; inventing a name would be worse than
            naming the thing accurately.
          */}
          <Section title="Agent" count={experts.length}>
            {experts.length === 0 ? (
              <Hint>{offline ? "—" : "运行 pnpm seed 建立团队"}</Hint>
            ) : (
              <>
                <div className="flex items-center gap-1.5 px-2 pb-1 pt-0.5">
                  <span aria-hidden className="text-[10px] text-subtle-fg">
                    ▣
                  </span>
                  <span className="mono truncate text-[0.6875rem] text-muted-fg">本机</span>
                </div>
                {experts.map((e) => (
                  <MemberRow
                    key={e.id}
                    name={e.name}
                    kind={e.runtimeKind}
                    // A runtime absent from PATH can never run, so it reads as
                    // offline here instead of silently failing when work routes
                    // to it.
                    online={online.has(e.runtimeKind)}
                  />
                ))}
              </>
            )}
          </Section>

          <Section title="成员">
            <div className="nav-row cursor-default">
              <span
                aria-hidden
                className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] text-[9px] font-semibold"
                style={{ background: "var(--color-muted)", color: "var(--color-muted-fg)" }}
              >
                你
              </span>
              <span className="truncate">你</span>
            </div>
          </Section>
        </div>

        <div className="rule" />
        <div className="px-3 py-2">
          <p className="t-meta truncate" title={offline ? undefined : `${runtimes.length} 个运行时`}>
            {offline ? "引擎离线" : `本机 · ${runtimes.length} 个运行时在线`}
          </p>
        </div>
      </aside>

      {/* Scrim for the mobile sidebar. */}
      {sidebarOpen ? (
        <button
          type="button"
          aria-label="关闭频道栏"
          className="absolute inset-0 z-20 bg-fg/20 md:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      ) : null}

      {/* ── Panel ──
          Owns its own scroll region so the rail and sidebar stay put. */}
      <main className="flex min-w-0 flex-1 flex-col overflow-y-auto">{children}</main>
    </div>
  );
}

function RailIcon({
  href,
  active,
  label,
  glyph,
}: {
  href: string;
  active: boolean;
  label: string;
  glyph: string;
}) {
  return (
    <Link
      href={href}
      title={label}
      aria-label={label}
      aria-current={active ? "page" : undefined}
      className={`grid h-8 w-8 place-items-center rounded-[var(--radius-sm)] text-[15px] transition-colors ${
        active
          ? "bg-surface-2 text-fg"
          : "text-muted-fg hover:bg-surface-2 hover:text-fg"
      }`}
    >
      <span aria-hidden>{glyph}</span>
    </Link>
  );
}

function Section({
  title,
  count,
  children,
}: {
  title: string;
  count?: number;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-4">
      <h2 className="t-label mb-1 flex items-center gap-1.5 px-2">
        {title}
        {count !== undefined && count > 0 ? (
          <span className="font-normal text-subtle-fg">{count}</span>
        ) : null}
      </h2>
      <div className="space-y-px">{children}</div>
    </section>
  );
}

function Hint({ children }: { children: React.ReactNode }) {
  return <p className="t-meta px-2 py-0.5">{children}</p>;
}

function MemberRow({
  name,
  kind,
  online,
}: {
  name: string;
  kind: RuntimeKind;
  online: boolean;
}) {
  const tone = RUNTIME_TONE[kind] ?? {
    bg: "var(--color-muted)",
    fg: "var(--color-muted-fg)",
  };
  return (
    <div
      className="nav-row cursor-default"
      title={online ? kind : `${kind} — 未安装，派活会失败`}
    >
      <span
        aria-hidden
        className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] text-[9px] font-semibold uppercase"
        style={
          online
            ? { background: tone.bg, color: tone.fg }
            : { background: "var(--color-muted)", color: "var(--color-subtle-fg)" }
        }
      >
        {name.slice(0, 1)}
      </span>
      <span className={`truncate ${online ? "" : "text-muted-fg"}`}>{name}</span>
      <span
        aria-hidden
        className={`ml-auto h-1.5 w-1.5 shrink-0 rounded-full ${
          online ? "bg-ok" : "border border-line-strong"
        }`}
        title={online ? "在线" : "离线"}
      />
    </div>
  );
}
