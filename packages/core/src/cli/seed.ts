#!/usr/bin/env node
/**
 * Creates a default team from whatever runtimes are actually installed.
 *
 * Role assignment is deliberately capability-driven rather than vendor-driven.
 * The "gemini has taste, claude writes code, codex finds bugs" folklore is
 * community lore that drifts with every model release, so it lives here as
 * DATA — a starting guess that the run history is meant to correct — never as
 * branching logic elsewhere in the system.
 */
import { detectAll } from "../adapters/index.ts";
import { Store, defaultDbPath } from "../db/index.ts";
import { isGitRepo } from "../util/git.ts";
import type { ExpertRole, RuntimeKind } from "../types.ts";

interface Blueprint {
  name: string;
  description: string;
  roles: ExpertRole[];
  capabilities: string[];
  systemPrompt: string;
}

/**
 * Per-runtime starting profile. Every claim here is a hypothesis, not a
 * measurement — which is exactly why `attempt` and `review` rows record what
 * actually happened, so this table can eventually be replaced by evidence.
 */
const BLUEPRINTS: Readonly<Record<RuntimeKind, Blueprint>> = {
  claude: {
    name: "Atlas",
    description: "Implementation lead. Writes and refactors code across the stack.",
    roles: ["orchestrator", "maker"],
    capabilities: ["backend", "refactor", "general", "typescript", "api"],
    systemPrompt:
      "You are a senior implementation engineer. Read surrounding code before writing any, and match its existing conventions rather than importing your own. Prefer the smallest change that fully solves the problem. State plainly what you verified and what you did not.",
  },
  codex: {
    name: "Probe",
    description: "Deep analysis and defect hunting. Prefers evidence over opinion.",
    roles: ["reviewer", "verifier"],
    capabilities: ["debugging", "correctness", "concurrency", "performance", "security"],
    systemPrompt:
      "You are a defect-hunting specialist. Your value is finding failures others miss, so prioritise correctness, race conditions, error propagation, and unchecked edge cases. When you make a claim, prefer a reproduction over an assertion — a failing test is worth more than a paragraph of suspicion. Never invent findings to appear thorough.",
  },
  gemini: {
    name: "Iris",
    description: "Interface and visual design. Owns how things look and feel.",
    roles: ["maker"],
    capabilities: ["frontend", "frontend-aesthetics", "visual-design", "ux", "css", "accessibility"],
    systemPrompt:
      "You are an interface designer who writes code. Care about hierarchy, spacing, contrast, and motion, and treat accessibility as part of correctness rather than an afterthought. Judgment calls about taste are yours to make and defend; say plainly when a tradeoff is a matter of preference rather than fact.",
  },
  cursor: {
    name: "Vector",
    description: "Fast broad edits across many files.",
    roles: ["maker"],
    capabilities: ["frontend", "refactor", "general", "migration"],
    systemPrompt:
      "You are a pragmatic engineer working at speed without being careless. Follow the existing patterns in the repository, keep changes tightly scoped to the task, and verify before declaring completion.",
  },
  kiro: {
    name: "Warden",
    description: "Structured planning and specification review.",
    roles: ["reviewer"],
    capabilities: ["architecture", "planning", "spec", "documentation"],
    systemPrompt:
      "You review work for structural soundness: are the boundaries right, will this shape hold as the system grows, does the implementation actually match its stated intent? Flag architectural drift and unstated assumptions.",
  },
  grok: {
    name: "Quill",
    description: "Independent second opinion with a contrarian streak.",
    roles: ["reviewer"],
    capabilities: ["correctness", "general", "review"],
    systemPrompt:
      "You are the independent voice on this team. Your job is to disagree when disagreement is warranted — converging on whatever the previous reviewer said destroys the entire reason several vendors are being paid. Reason from the code in front of you, not from what others concluded.",
  },
};

/** A run needs a maker, someone to review, and someone to plan. */
function coverage(assigned: Map<ExpertRole, string[]>): ExpertRole[] {
  const required: ExpertRole[] = ["orchestrator", "maker", "reviewer", "verifier"];
  return required.filter((role) => (assigned.get(role) ?? []).length === 0);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const repoArg = args.find((a) => !a.startsWith("--"));
  const repoPath = repoArg ?? process.cwd();
  const teamName = valueOf(args, "--team") ?? "Council";
  const projectName = valueOf(args, "--project") ?? repoPath.split("/").filter(Boolean).at(-1) ?? "project";

  const detected = await detectAll();
  if (detected.length === 0) {
    console.error("No coding CLIs found on PATH. Install at least one (claude, codex, cursor-agent, gemini, kiro-cli, grok).");
    process.exitCode = 1;
    return;
  }

  if (!(await isGitRepo(repoPath))) {
    // Not fatal at seed time, but the pipeline will refuse to run: worktree
    // isolation is the only thing stopping parallel agents from overwriting
    // each other.
    console.warn(`Warning: ${repoPath} is not a git repository. Runs will fail until it is one.`);
  }

  const store = new Store(defaultDbPath());
  console.log(`Database: ${defaultDbPath()}\n`);

  const assigned = new Map<ExpertRole, string[]>();
  const team = store.getTeamByName(teamName) ?? store.createTeam(teamName);

  for (const runtime of detected) {
    const bp = BLUEPRINTS[runtime.kind];
    // Reuse an existing expert of the same name so re-seeding is idempotent.
    const expert =
      store.getExpertByName(bp.name) ??
      store.createExpert({
        name: bp.name,
        description: bp.description,
        runtimeKind: runtime.kind,
        model: null,
        systemPrompt: bp.systemPrompt,
        capabilities: bp.capabilities,
      });

    for (const role of bp.roles) {
      store.addTeamMember(team.id, expert.id, role);
      assigned.set(role, [...(assigned.get(role) ?? []), expert.name]);
    }
    console.log(
      `  ${expert.name.padEnd(8)} ${runtime.kind.padEnd(8)} roles: ${bp.roles.join(", ").padEnd(24)} ${runtime.version}`,
    );
  }

  // With a single runtime installed there is nobody to review anyone, so let
  // that one expert cover the empty roles rather than producing a team that
  // silently skips review.
  const gaps = coverage(assigned);
  if (gaps.length > 0) {
    const fallback = store.getExpertByName(BLUEPRINTS[detected[0]!.kind].name);
    if (fallback) {
      for (const role of gaps) store.addTeamMember(team.id, fallback.id, role);
      console.log(`\n  Note: ${fallback.name} also covers ${gaps.join(", ")} (only ${detected.length} runtime(s) available).`);
      if (detected.length === 1) {
        console.log("  With one runtime, review is self-review — the independent-perspective");
        console.log("  benefit of a multi-vendor team is absent. Install a second CLI for real cross-review.");
      }
    }
  }

  const existing = store.listProjects().find((p) => p.repoPath === repoPath);
  const project = existing ?? store.createProject({ name: projectName, repoPath, teamId: team.id });

  /*
   * One channel per project, plus a DM per agent.
   *
   * Chat is the workspace, so a fresh install that opens onto an empty sidebar
   * has nowhere to start. One channel per project is the right granularity — a
   * project is exactly one repository's stream of work — and a DM per agent is
   * what makes them addressable individually rather than only as a team.
   *
   * Idempotent, like everything else here: re-seeding finds the existing rows
   * instead of stacking duplicates.
   */
  const channels = store.listChannels();
  const channel =
    channels.find((c) => c.kind === "channel" && c.projectId === project.id) ??
    store.createChannel({
      name: project.name,
      purpose: `${project.repoPath} 的工作频道`,
      kind: "channel",
      projectId: project.id,
      dmExpertId: null,
    });

  const dmCount = detected.reduce((made, runtime) => {
    const expert = store.getExpertByName(BLUEPRINTS[runtime.kind].name);
    if (!expert) return made;
    if (channels.some((c) => c.kind === "dm" && c.dmExpertId === expert.id)) return made;
    store.createChannel({
      name: expert.name,
      purpose: expert.description,
      kind: "dm",
      // A DM has no repository, and that is a legitimate state: a task created
      // there cannot start a run, which is an honest limit rather than a bug.
      projectId: null,
      dmExpertId: expert.id,
    });
    return made + 1;
  }, 0);

  console.log(`\nTeam:    ${team.name} (${team.id})`);
  console.log(`Project: ${project.name} → ${project.repoPath}`);
  console.log(`Channel: #${channel.name}${dmCount > 0 ? ` (+ ${dmCount} 个私信)` : ""}`);
  console.log(`\nStart the engine with: pnpm dev`);
  store.close();
}

function valueOf(args: string[], flag: string): string | null {
  const i = args.indexOf(flag);
  if (i < 0) return null;
  return args[i + 1] ?? null;
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
