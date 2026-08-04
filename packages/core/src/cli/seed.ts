#!/usr/bin/env node
/**
 * Prepares a fresh install: one agent per installed CLI, and a list to work in.
 *
 * `pnpm seed <repo>` creates a list bound to that repository, so its tasks can be
 * dispatched. Without an argument it creates the agents and the inbox only — a
 * perfectly usable state for a plain todo list, and honest about the fact that
 * nothing can execute until a list carries a repository.
 *
 * What this deliberately no longer does: assemble a four-role team, or create a DM
 * channel per agent. Both were pipeline-era furniture. Roles are not consulted when
 * a task is dispatched (the card's assignee is, or the first agent on file), and
 * `GET /api/lists` returns only `kind: "channel"` rows, so every DM this used to
 * create was invisible in the product it was seeding.
 */
import { resolve } from "node:path";
import { detectAll } from "../adapters/index.ts";
import { Store, defaultDbPath } from "../db/index.ts";
import { isGitRepo } from "../util/git.ts";
import type { ExpertRole, RuntimeKind } from "../types.ts";

/**
 * The list quick-added tasks land in.
 *
 * Must match `DEFAULT_LIST_NAME` in apps/engine/src/server.ts EXACTLY. The engine
 * finds its inbox by name and creates one on demand if it cannot; a different
 * spelling here would leave the user looking at two inboxes with tasks split
 * between them.
 */
const INBOX = "收件箱";

interface Profile {
  name: string;
  description: string;
  capabilities: string[];
  systemPrompt: string;
}

/**
 * A starting profile per runtime.
 *
 * Every claim here is a hypothesis, not a measurement — which is why `attempt` rows
 * record what actually happened. It lives here as DATA, a first guess a person can
 * edit on the 团队 page, and never as branching logic anywhere else in the system.
 */
const PROFILES: Readonly<Record<RuntimeKind, Profile>> = {
  claude: {
    name: "Atlas",
    description: "实现主力。读懂周围代码再动手。",
    capabilities: ["backend", "refactor", "general", "typescript", "api"],
    systemPrompt:
      "You are a senior implementation engineer. Read surrounding code before writing any, and match its existing conventions rather than importing your own. Prefer the smallest change that fully solves the problem. State plainly what you verified and what you did not.",
  },
  codex: {
    name: "Probe",
    description: "深挖缺陷。宁可跑一遍也不猜。",
    capabilities: ["debugging", "correctness", "concurrency", "performance", "security"],
    systemPrompt:
      "You are a defect-hunting specialist. Prioritise correctness, race conditions, error propagation, and unchecked edge cases. When you make a claim, prefer a reproduction over an assertion — a failing test is worth more than a paragraph of suspicion. Never invent findings to appear thorough.",
  },
  gemini: {
    name: "Iris",
    description: "界面与视觉。把可访问性当正确性的一部分。",
    capabilities: ["frontend", "frontend-aesthetics", "visual-design", "ux", "css", "accessibility"],
    systemPrompt:
      "You are an interface designer who writes code. Care about hierarchy, spacing, contrast, and motion, and treat accessibility as part of correctness rather than an afterthought. Say plainly when a tradeoff is a matter of preference rather than fact.",
  },
  cursor: {
    name: "Vector",
    description: "跨文件快速改动。",
    capabilities: ["frontend", "refactor", "general", "migration"],
    systemPrompt:
      "You are a pragmatic engineer working at speed without being careless. Follow the existing patterns in the repository, keep changes tightly scoped to the task, and verify before declaring completion.",
  },
  kiro: {
    name: "Warden",
    description: "结构与规格审查。",
    capabilities: ["architecture", "planning", "spec", "documentation"],
    systemPrompt:
      "You review work for structural soundness: are the boundaries right, will this shape hold as the system grows, does the implementation actually match its stated intent? Flag architectural drift and unstated assumptions.",
  },
  grok: {
    name: "Quill",
    description: "独立第二意见。",
    capabilities: ["correctness", "general", "review"],
    systemPrompt:
      "You are the independent voice. Disagree when disagreement is warranted — converging on whatever the previous reviewer said destroys the reason several vendors are being paid. Reason from the code in front of you, not from what others concluded.",
  },
};

/** Every role, for the stub team below. */
const ALL_ROLES: ExpertRole[] = ["orchestrator", "maker", "reviewer", "verifier"];

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const repoArg = args.find((a) => !a.startsWith("--")) ?? null;

  const detected = await detectAll();
  if (detected.length === 0) {
    console.error(
      "PATH 上没有找到任何编码 CLI。先装一个（claude / codex / cursor-agent / gemini / kiro-cli / grok）并登录。",
    );
    process.exitCode = 1;
    return;
  }

  /*
   * The repository is validated BEFORE anything is written.
   *
   * `POST /api/lists` refuses a path that is not a git repository, so creating one
   * here would produce a list the HTTP API would never have allowed — and every task
   * on it would fail at dispatch with no explanation on the card.
   */
  let repoPath: string | null = null;
  if (repoArg !== null) {
    repoPath = resolve(repoArg);
    if (!(await isGitRepo(repoPath))) {
      console.error(`${repoPath} 不是 git 仓库。先在那里运行 git init，或者不带参数运行 seed。`);
      process.exitCode = 1;
      return;
    }
  }

  const store = new Store(defaultDbPath());
  try {
    console.log(`数据库：${defaultDbPath()}\n`);
    console.log("agent：");

    const experts = detected.map((runtime) => {
      const profile = PROFILES[runtime.kind];
      // Reused by name, so re-seeding is idempotent rather than cumulative.
      const expert =
        store.getExpertByName(profile.name) ??
        store.createExpert({
          name: profile.name,
          description: profile.description,
          runtimeKind: runtime.kind,
          model: null,
          systemPrompt: profile.systemPrompt,
          capabilities: profile.capabilities,
        });
      console.log(`  ${expert.name.padEnd(8)} ${runtime.kind.padEnd(8)} ${runtime.version}`);
      return expert;
    });

    /*
     * The inbox, matching the engine's own name for it.
     *
     * Created here so a fresh install opens onto something rather than an empty
     * sidebar. The engine would create it on the first quick-add anyway; doing it now
     * means the first thing a person sees is a place to type.
     */
    const lists = store.listChannels();
    const inbox =
      lists.find((ch) => ch.kind === "channel" && ch.archivedAt === null && ch.name === INBOX) ??
      store.createChannel({
        name: INBOX,
        purpose: "",
        kind: "channel",
        projectId: null,
        dmExpertId: null,
        color: null,
      });

    let bound: { name: string; repoPath: string } | null = null;
    if (repoPath !== null) {
      /*
       * `project.team_id` is NOT NULL — pipeline-era schema this product does not
       * otherwise use. A stub team satisfies it, which is exactly what
       * `POST /api/lists` does; keeping the two identical means a list created by
       * seed and one created in the UI are indistinguishable afterwards.
       *
       * Every agent joins it in every role. Not because direct dispatch reads roles
       * — it does not — but because the retained six-phase pipeline needs a roster,
       * and a seeded project that 500s on `POST /api/runs` would be a worse
       * surprise than a team nobody looks at.
       */
      const team = store.listTeams()[0] ?? store.createTeam("todoagent");
      for (const expert of experts) {
        for (const role of ALL_ROLES) store.addTeamMember(team.id, expert.id, role);
      }

      const name = repoPath.split("/").filter(Boolean).at(-1) ?? "project";
      const project =
        store.listProjects().find((p) => resolve(p.repoPath) === repoPath) ??
        store.createProject({ name, repoPath, teamId: team.id });

      // One list per repository. Re-seeding the same repo finds it instead of
      // stacking a second list with the same name.
      const existing = lists.find(
        (ch) => ch.kind === "channel" && ch.archivedAt === null && ch.projectId === project.id,
      );
      const list =
        existing ??
        store.createChannel({
          name: project.name,
          purpose: "",
          kind: "channel",
          projectId: project.id,
          dmExpertId: null,
          color: "#007aff",
        });
      bound = { name: list.name, repoPath: project.repoPath };
    }

    // Re-read: the inbox may already carry a projectId from a prior UI bind /
    // `pnpm seed <repo>`, and printing "不能派发" against that state is a lie.
    const inboxNow = store.getChannel(inbox.id) ?? inbox;
    const inboxRepo =
      inboxNow.projectId === null
        ? null
        : (store.getProject(inboxNow.projectId)?.repoPath ?? null);

    console.log(`\n清单：`);
    if (inboxRepo !== null) {
      console.log(`  ${inboxNow.name.padEnd(16)} → ${inboxRepo}`);
    } else {
      console.log(`  ${inboxNow.name.padEnd(16)} 纯待办，不能派发`);
    }
    if (bound !== null && (inboxRepo === null || resolve(inboxRepo) !== resolve(bound.repoPath))) {
      console.log(`  ${bound.name.padEnd(16)} → ${bound.repoPath}`);
    }

    const anyDispatchable =
      inboxRepo !== null || bound !== null ||
      store.listChannels().some(
        (ch) => ch.kind === "channel" && ch.archivedAt === null && ch.projectId !== null,
      );
    if (anyDispatchable) {
      console.log(`\n清单已就绪。启动 pnpm dev 和 pnpm dev:web，去界面添加任务。`);
    } else {
      console.log(`\nagent 已就绪，但还没有能派发的清单。`);
      console.log(`要执行任务，重跑一次带仓库路径：pnpm seed <仓库路径>`);
      console.log(`（也可以在界面上「新建清单」时填仓库路径，或侧栏清单菜单 → 绑定仓库。）`);
    }
  } finally {
    store.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
