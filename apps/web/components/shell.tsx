"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { api, ApiError } from "../lib/api.ts";
import type { Channel, DetectedRuntime, Expert, Project, RuntimeKind } from "../lib/types.ts";
import { ErrorBox } from "./atoms.tsx";

/**
 * The workspace shell: an icon rail, a channel sidebar, and one panel.
 *
 * This is the structural half of matching Raft. Their primary surface is a chat
 * workspace, not a list of jobs — the app is a persistent sidebar of channels and
 * members with a single panel beside it, like a chat client, rather than a
 * document that scrolls as a whole.
 *
 * Projects ARE the channels. Raft's own guidance is "one channel per project or
 * workstream", and a TodoAgent project is exactly one repository's stream of work,
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
  // Used only after creating a channel, to open the thing that was just made.
  const router = useRouter();
  const [channels, setChannels] = useState<Channel[]>([]);
  const [experts, setExperts] = useState<Expert[]>([]);
  const [runtimes, setRuntimes] = useState<DetectedRuntime[]>([]);
  /** Only needed by the new-channel dialog: a channel's repo decides whether its
   *  tasks can execute at all. */
  const [projects, setProjects] = useState<Project[]>([]);
  const [offline, setOffline] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [creating, setCreating] = useState<null | "channel" | "dm">(null);

  const load = useCallback(async () => {
    try {
      const [ch, ex, rt, ps] = await Promise.all([
        api.channels(),
        api.experts(),
        api.runtimes(),
        api.projects(),
      ]);
      setChannels(ch);
      setExperts(ex);
      setRuntimes(rt.detected);
      setProjects(ps);
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
  // Split once here rather than filtering twice in the markup, so the counts in
  // the section headers cannot disagree with the rows underneath them.
  const rooms = channels.filter((c) => c.kind === "channel");
  const dms = channels.filter((c) => c.kind === "dm");
  /*
   * Agents with no DM yet.
   *
   * The `+` on the DM section appears only when this is non-empty. `seed` already
   * creates one DM per detected runtime, and the engine does NOT enforce
   * uniqueness on `dmExpertId` — so offering the action unconditionally would
   * happily produce two conversations with the same agent, indistinguishable in
   * the sidebar.
   */
  const dmlessExperts = experts.filter((e) => !dms.some((c) => c.dmExpertId === e.id));

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
          aria-label="TodoAgent 首页"
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
          <Section
            title="频道"
            count={rooms.length}
            // Hidden while the engine is unreachable: the dialog's first act would
            // be a request that cannot succeed.
            {...(offline ? {} : { onAdd: () => setCreating("channel"), addLabel: "新建频道" })}
          >
            {offline ? (
              <Hint>引擎未启动</Hint>
            ) : !loaded ? (
              <Hint>载入中…</Hint>
            ) : rooms.length === 0 ? (
              <Hint>运行 pnpm seed 建立频道</Hint>
            ) : (
              rooms.map((c) => (
                <Link
                  key={c.id}
                  href={`/channels/${c.id}`}
                  className="nav-row"
                  data-active={pathname === `/channels/${c.id}`}
                  title={c.purpose === "" ? undefined : c.purpose}
                  onClick={() => setSidebarOpen(false)}
                >
                  <span aria-hidden className="shrink-0 text-subtle-fg">
                    #
                  </span>
                  <span className="truncate">{c.name}</span>
                </Link>
              ))
            )}
          </Section>

          {/*
            DMs grouped under the machine the agents run on, the way Raft's
            members page does it — a machine row, then each agent with a presence
            dot. The grouping is the point: these are local CLIs, so which
            computer they live on determines whether they can run at all.

            One list, not two. A DM row IS the agent: click to talk to them, and
            the dot says whether their CLI is installed. A separate roster section
            would repeat the same six names directly below itself.

            The machine reads "本机" rather than a hostname because the engine
            does not report one, and inventing a name would be worse than naming
            the thing accurately.
          */}
          <Section
            title="私信"
            count={dms.length}
            // Only when there is somebody left to open one with — see dmlessExperts.
            {...(offline || dmlessExperts.length === 0
              ? {}
              : { onAdd: () => setCreating("dm"), addLabel: "新建私信" })}
          >
            {dms.length === 0 ? (
              <Hint>{offline ? "—" : "运行 pnpm seed 建立团队"}</Hint>
            ) : (
              <>
                <div className="flex items-center gap-1.5 px-2 pb-1 pt-0.5">
                  <span aria-hidden className="text-[10px] text-subtle-fg">
                    ▣
                  </span>
                  <span className="mono truncate text-[0.6875rem] text-muted-fg">本机</span>
                </div>
                {dms.map((c) => {
                  const expert =
                    c.dmExpertId === null
                      ? null
                      : (experts.find((e) => e.id === c.dmExpertId) ?? null);
                  return (
                    <DmRow
                      key={c.id}
                      href={`/channels/${c.id}`}
                      name={expert?.name ?? c.name}
                      kind={expert?.runtimeKind ?? null}
                      // A runtime absent from PATH can never run, so it reads as
                      // offline here instead of silently failing when work routes
                      // to it.
                      online={expert !== null && online.has(expert.runtimeKind)}
                      active={pathname === `/channels/${c.id}`}
                      onNavigate={() => setSidebarOpen(false)}
                    />
                  );
                })}
              </>
            )}
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

      {/* Mounted at the shell root, not inside the aside — the sidebar is 15rem
          wide and a dialog inside it would be clipped to that. */}
      {creating !== null ? (
        <NewChannelDialog
          mode={creating}
          projects={projects}
          experts={dmlessExperts}
          onClose={() => setCreating(null)}
          onCreated={(id) => {
            setCreating(null);
            // Reload before navigating, so the sidebar already lists the new
            // channel when its page appears.
            void load().then(() => router.push(`/channels/${id}`));
          }}
        />
      ) : null}
    </div>
  );
}

/**
 * Creates a channel or a DM.
 *
 * Both endpoints existed and had engine tests from the start, and nothing in the
 * UI ever called them — channels could only be created by `pnpm seed`. The
 * reference product has a `+` on each sidebar section, and without one this app
 * cannot add a second project's channel at all.
 *
 * One dialog for both because the shapes barely differ: a channel is a name plus an
 * optional repo, a DM is a choice of agent. Two components would duplicate the
 * submit, error and busy handling for one differing field.
 */
function NewChannelDialog({
  mode,
  projects,
  experts,
  onClose,
  onCreated,
}: {
  mode: "channel" | "dm";
  projects: Project[];
  /** Only agents without a DM yet — see `dmlessExperts`. */
  experts: Expert[];
  onClose: () => void;
  onCreated: (channelId: string) => void;
}) {
  const [name, setName] = useState("");
  const [purpose, setPurpose] = useState("");
  const [projectId, setProjectId] = useState("");
  const [expertId, setExpertId] = useState(experts[0]?.id ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isDm = mode === "dm";
  const canSubmit = isDm ? expertId !== "" : name.trim() !== "";

  const submit = async (): Promise<void> => {
    if (!canSubmit || busy) return;
    setBusy(true);
    setError(null);
    try {
      const created = isDm
        ? await api.createChannel({
            // A DM is named after its agent, so the sidebar row reads as a person
            // rather than as a room.
            name: experts.find((e) => e.id === expertId)?.name ?? "DM",
            kind: "dm",
            dmExpertId: expertId,
          })
        : await api.createChannel({
            name: name.trim(),
            purpose: purpose.trim(),
            // Empty means no repository. A legitimate state: the channel can hold
            // cards but nothing can execute them, which the composer already says.
            projectId: projectId === "" ? null : projectId,
          });
      onCreated(created.id);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      className="absolute inset-0 z-40 grid place-items-center bg-fg/20 p-4"
      role="dialog"
      aria-modal="true"
      aria-label={isDm ? "新建私信" : "新建频道"}
      onKeyDown={(e) => {
        if (e.key === "Escape") onClose();
      }}
    >
      <div className="card w-full max-w-md p-4">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="t-md">{isDm ? "新建私信" : "新建频道"}</h2>
          <button
            type="button"
            className="btn btn-icon btn-sm btn-ghost"
            onClick={onClose}
            aria-label="关闭"
          >
            ✕
          </button>
        </div>

        {error !== null ? (
          <div className="mb-3">
            <ErrorBox message={error} />
          </div>
        ) : null}

        {isDm ? (
          <label className="block">
            <span className="t-label">和谁对话</span>
            <select
              className="field mt-1"
              value={expertId}
              onChange={(e) => setExpertId(e.target.value)}
              autoFocus
            >
              {experts.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.name} — {e.runtimeKind}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <div className="space-y-3">
            <label className="block">
              <span className="t-label">频道名</span>
              <input
                className="field mt-1"
                value={name}
                onChange={(e) => setName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && !e.nativeEvent.isComposing) {
                    e.preventDefault();
                    void submit();
                  }
                }}
                placeholder="例如：web"
                autoFocus
              />
            </label>

            <label className="block">
              <span className="t-label">仓库（可选）</span>
              <select
                className="field mt-1"
                value={projectId}
                onChange={(e) => setProjectId(e.target.value)}
              >
                <option value="">不关联仓库 — 任务无法执行</option>
                {projects.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} — {p.repoPath}
                  </option>
                ))}
              </select>
              <span className="t-meta mt-1 block">
                没有仓库的频道可以聊天和记任务，但流水线跑不起来。
              </span>
            </label>

            <label className="block">
              <span className="t-label">用途（可选）</span>
              <input
                className="field mt-1"
                value={purpose}
                onChange={(e) => setPurpose(e.target.value)}
                placeholder="这个频道用来做什么"
              />
            </label>
          </div>
        )}

        <div className="mt-4 flex items-center gap-2">
          <button type="button" className="btn btn-sm ml-auto" onClick={onClose}>
            取消
          </button>
          <button
            type="button"
            className="btn btn-primary btn-sm"
            onClick={() => void submit()}
            disabled={!canSubmit || busy}
          >
            {busy ? "创建中…" : "创建"}
          </button>
        </div>
      </div>
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
  onAdd,
  addLabel,
  children,
}: {
  title: string;
  count?: number;
  /** Renders a `+` in the header. Omitted where there is nothing to create. */
  onAdd?: () => void;
  addLabel?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-4">
      <h2 className="t-label mb-1 flex items-center gap-1.5 px-2">
        {title}
        {count !== undefined && count > 0 ? (
          <span className="font-normal text-subtle-fg">{count}</span>
        ) : null}
        {onAdd ? (
          <button
            type="button"
            onClick={onAdd}
            className="ml-auto grid h-4 w-4 place-items-center rounded text-[13px] leading-none text-subtle-fg transition-colors hover:bg-surface-2 hover:text-fg"
            title={addLabel}
            aria-label={addLabel}
          >
            +
          </button>
        ) : null}
      </h2>
      <div className="space-y-px">{children}</div>
    </section>
  );
}

function Hint({ children }: { children: React.ReactNode }) {
  return <p className="t-meta px-2 py-0.5">{children}</p>;
}

/**
 * One agent, as a DM you can open.
 *
 * A link rather than a static row: an agent here is a persistent teammate you
 * address, not a setting you inspect. The presence dot is about their CLI, not
 * about the conversation — an offline agent's DM still opens and still holds its
 * history, so the row stays clickable and says why work would fail instead.
 */
function DmRow({
  href,
  name,
  kind,
  online,
  active,
  onNavigate,
}: {
  href: string;
  name: string;
  /** Null when the DM points at an expert that no longer exists. */
  kind: RuntimeKind | null;
  online: boolean;
  active: boolean;
  onNavigate: () => void;
}) {
  const tone =
    kind === null
      ? null
      : (RUNTIME_TONE[kind] ?? { bg: "var(--color-muted)", fg: "var(--color-muted-fg)" });

  return (
    <Link
      href={href}
      className="nav-row"
      data-active={active}
      onClick={onNavigate}
      title={
        kind === null
          ? "这个 agent 已不存在"
          : online
            ? kind
            : `${kind} — 未安装，派活会失败`
      }
    >
      <span
        aria-hidden
        className="grid h-4 w-4 shrink-0 place-items-center rounded-[4px] text-[9px] font-semibold uppercase"
        style={
          tone !== null && online
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
    </Link>
  );
}
