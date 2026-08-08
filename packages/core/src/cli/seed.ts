#!/usr/bin/env node
/**
 * Prepares a fresh install: reports installed local CLIs and, when a repository
 * is supplied, creates one repository-bound list.
 *
 * `pnpm seed <repo>` creates a list bound to that repository, so its tasks can be
 * dispatched. Without an argument it only reports Runtime state; the product has
 * no system-created inbox, so the user creates the lists they actually want.
 *
 * CLI detection is observation, not identity creation. Claude Code remains Claude
 * Code: seed creates no Expert, persona, role, TeamMember or DM. The sole retained
 * Team row is an empty internal compatibility record required by the historical
 * NOT NULL `project.team_id` column.
 */
import { resolve } from "node:path";
import { detectAll } from "../adapters/index.ts";
import { Store, defaultDbPath } from "../db/index.ts";
import { isGitRepo } from "../util/git.ts";

const INTERNAL_TEAM_NAME = "todoagent-internal";

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
    console.log("本机 CLI：");
    for (const runtime of detected) {
      console.log(`  ${runtime.kind.padEnd(10)} ${runtime.version.padEnd(24)} ${runtime.execPath}`);
    }

    const lists = store.listChannels();
    let bound: { name: string; repoPath: string } | null = null;
    if (repoPath !== null) {
      /*
       * `project.team_id` is NOT NULL in the retained pipeline-era schema. The
       * direct-dispatch product does not use it, so one deliberately empty,
       * internal Team satisfies the column without reintroducing experts or roles.
       */
      const team =
        store.getTeamByName(INTERNAL_TEAM_NAME) ?? store.createTeam(INTERNAL_TEAM_NAME);

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

    console.log(`\n清单：`);
    if (bound !== null) {
      console.log(`  ${bound.name.padEnd(16)} → ${bound.repoPath}`);
    } else {
      const openLists = store.listChannels().filter((ch) => ch.kind === "channel" && ch.archivedAt === null);
      if (openLists.length === 0) console.log("  暂无；请在界面创建清单");
      for (const list of openLists) {
        const path = list.projectId === null ? null : store.getProject(list.projectId)?.repoPath ?? null;
        console.log(path === null ? `  ${list.name.padEnd(16)} 纯待办` : `  ${list.name.padEnd(16)} → ${path}`);
      }
    }

    const anyDispatchable =
      bound !== null ||
      store.listChannels().some(
        (ch) => ch.kind === "channel" && ch.archivedAt === null && ch.projectId !== null,
      );
    if (anyDispatchable) {
      console.log(`\n清单已就绪。启动 pnpm dev 和 pnpm dev:web，去界面添加任务。`);
    } else {
      console.log(`\n本机 CLI 已检测，但还没有能派发的清单。`);
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
