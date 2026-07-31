"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { api } from "../lib/api.ts";
import type { DetectedRuntime, Expert, Project, RuntimeKind } from "../lib/types.ts";

/**
 * The workspace shell: a fixed rail plus a scrolling panel.
 *
 * This is the structural half of matching Raft. Their primary surface is a chat
 * workspace, not a list of jobs — "Chat is the workspace. Channels, DMs, threads —
 * every interaction happens in messages." So the app is a persistent rail of
 * channels and members with one panel on the right, like a chat client, rather than
 * a document that scrolls as a whole.
 *
 * Projects ARE the channels. That is not a shortcut: Raft's own guidance is "One
 * channel per project or workstream", and a Council project is exactly one
 * repository's stream of work. Mapping them keeps a single source of truth instead
 * of inventing a parallel container.
 */
export function WorkspaceShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [projects, setProjects] = useState<Project[]>([]);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [runtimes, setRuntimes] = useState<DetectedRuntime[]>([]);
  const [offline, setOffline] = useState(false);
  const [railOpen, setRailOpen] = useState(false);

  const load = useCallback(async () => {
    try {
      const [ps, ex, rt] = await Promise.all([api.projects(), api.experts(), api.runtimes()]);
      setProjects(ps);
      setExperts(ex);
      setRuntimes(rt.detected);
      setOffline(false);
    } catch {
      // The engine is a separate local process, so "not running" is the most common
      // state on a cold start. The rail says so rather than rendering as empty.
      setOffline(true);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="flex h-full">
      {/* ── Rail ── */}
      <aside
        className={`absolute inset-y-0 left-0 z-30 flex w-[var(--w-rail)] shrink-0 flex-col border-r-2 border-ink bg-paper transition-transform duration-150 md:static md:translate-x-0 ${
          railOpen ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <div className="panel-header">
          <span
            aria-hidden
            className="grid h-7 w-7 shrink-0 place-items-center border-2 border-ink bg-paper text-[13px] font-bold"
          >
            C
          </span>
          <span className="t-md truncate">Council</span>
        </div>

        <nav className="flex-1 overflow-y-auto px-3 py-4">
          <RailSection title="频道">
            {offline ? (
              <p className="t-meta px-1">引擎未启动</p>
            ) : projects.length === 0 ? (
              <p className="t-meta px-1">还没有项目</p>
            ) : (
              projects.map((p) => (
                <RailLink
                  key={p.id}
                  href={`/?project=${p.id}`}
                  active={pathname === "/"}
                  label={p.name}
                  prefix="#"
                  title={p.repoPath}
                  onNavigate={() => setRailOpen(false)}
                />
              ))
            )}
          </RailSection>

          <RailSection title="视图">
            <RailLink
              href="/"
              active={pathname === "/"}
              label="委托"
              prefix="◆"
              onNavigate={() => setRailOpen(false)}
            />
            <RailLink
              href="/team"
              active={pathname === "/team"}
              label="团队"
              prefix="◇"
              onNavigate={() => setRailOpen(false)}
            />
          </RailSection>

          {/*
            Agents listed as members, the way Raft treats them — "persistent
            teammates with their own identities". Showing the roster in the rail is
            what makes them feel like people you address rather than settings you
            configure.
          */}
          <RailSection title={`成员 ${experts.length > 0 ? experts.length : ""}`}>
            {experts.length === 0 ? (
              <p className="t-meta px-1">运行 pnpm seed</p>
            ) : (
              experts.map((e) => (
                <MemberRow
                  key={e.id}
                  name={e.name}
                  kind={e.runtimeKind as RuntimeKind}
                  // A runtime absent from PATH can never run, so it is shown as
                  // offline instead of silently failing when work is routed to it.
                  online={runtimes.some((r) => r.kind === e.runtimeKind)}
                />
              ))
            )}
          </RailSection>
        </nav>

        <div className="rule mt-auto" />
        <div className="flex items-center gap-2 px-3 py-2.5">
          <span
            aria-hidden
            className={`h-2 w-2 shrink-0 border-2 border-ink ${offline ? "bg-paper" : "bg-ok"}`}
          />
          <span className="t-meta truncate">{offline ? "引擎离线" : "本机运行"}</span>
        </div>
      </aside>

      {/* Scrim for the mobile rail. */}
      {railOpen ? (
        <button
          type="button"
          aria-label="关闭侧栏"
          className="absolute inset-0 z-20 bg-ink/30 md:hidden"
          onClick={() => setRailOpen(false)}
        />
      ) : null}

      {/* ── Panel ── */}
      <div className="flex min-w-0 flex-1 flex-col">
        <button
          type="button"
          className="btn btn-sm absolute left-3 top-3 z-10 md:hidden"
          onClick={() => setRailOpen(true)}
          aria-label="打开侧栏"
        >
          ☰
        </button>
        <div className="min-h-0 flex-1 overflow-y-auto">{children}</div>
      </div>
    </div>
  );
}

function RailSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mb-5">
      <h2 className="t-label mb-1.5 px-1">{title}</h2>
      <div className="space-y-0.5">{children}</div>
    </section>
  );
}

function RailLink({
  href,
  active,
  label,
  prefix,
  title,
  onNavigate,
}: {
  href: string;
  active: boolean;
  label: string;
  prefix: string;
  title?: string;
  onNavigate: () => void;
}) {
  return (
    <Link
      href={href}
      title={title}
      onClick={onNavigate}
      // Active state is a solid yellow fill with a black box — legible without
      // relying on a subtle tint the way the previous design did.
      className={`flex items-center gap-2 px-2 py-1.5 text-[0.8125rem] font-semibold transition-colors ${
        active ? "border-2 border-ink bg-signal" : "border-2 border-transparent hover:bg-faint"
      }`}
    >
      <span aria-hidden className="shrink-0 text-mute">
        {prefix}
      </span>
      <span className="truncate">{label}</span>
    </Link>
  );
}

/** Each vendor keeps a stable hue so the roster is scannable without reading. */
const RUNTIME_FILL: Record<RuntimeKind, string> = {
  claude: "var(--color-accent)",
  codex: "var(--color-ok)",
  cursor: "var(--color-aqua)",
  gemini: "var(--color-grape)",
  kiro: "var(--color-signal)",
  grok: "var(--color-bad)",
};

function MemberRow({
  name,
  kind,
  online,
}: {
  name: string;
  kind: RuntimeKind;
  online: boolean;
}) {
  return (
    <div
      className="flex items-center gap-2 px-2 py-1"
      title={online ? `${kind}` : `${kind} — 未安装，派活会失败`}
    >
      <span
        aria-hidden
        className="h-4 w-4 shrink-0 border-2 border-ink"
        style={{ background: online ? RUNTIME_FILL[kind] : "var(--color-faint-2)" }}
      />
      <span className={`truncate text-[0.8125rem] font-semibold ${online ? "" : "text-mute"}`}>
        {name}
      </span>
      {!online ? <span className="t-meta ml-auto shrink-0">离线</span> : null}
    </div>
  );
}
