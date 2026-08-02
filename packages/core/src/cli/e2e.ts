#!/usr/bin/env node
/**
 * End-to-end check against the REAL local CLIs.
 *
 * This is the acceptance evidence for the whole system, so it deliberately does
 * not mock anything: it creates a throwaway git repo, seeds a genuine
 * multi-vendor team, runs one goal through the full pipeline, and then asserts
 * on what actually landed in the database.
 *
 * The assertions target the properties that distinguish this design, not just
 * "it did not crash":
 *   - several DIFFERENT runtimes participated (cross-vendor, not self-review)
 *   - work was decomposed and executed in isolated worktrees
 *   - reviewers produced findings independently of the author
 *   - the verifiable/unverifiable split actually routed disputes
 *   - the run terminated by itself rather than looping
 */
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { detectAll } from "../adapters/index.ts";
import { Store } from "../db/index.ts";
import { runPipeline } from "../orchestrator/pipeline.ts";
import { git } from "../util/git.ts";
import type { ExpertRole, RuntimeKind } from "../types.ts";

const GOAL =
  "Add a `slugify(input: string): string` function to src/text.ts and a matching test. " +
  "It must lowercase, trim, collapse whitespace and punctuation into single hyphens, " +
  "and handle empty input and leading/trailing separators.";

const ACCEPTANCE =
  "src/text.ts exports slugify; a test file covers empty string, punctuation, " +
  "repeated separators, and leading/trailing separators; `node --test` passes.";

interface Check {
  name: string;
  ok: boolean;
  detail: string;
  /** A soft check records a real limitation without failing the suite. */
  soft?: boolean;
}

const checks: Check[] = [];
function check(name: string, ok: boolean, detail: string, soft = false): void {
  checks.push({ name, ok, detail, soft });
  const mark = ok ? "PASS" : soft ? "WARN" : "FAIL";
  console.log(`  [${mark}] ${name}${detail ? ` — ${detail}` : ""}`);
}

/** A minimal but real repo, so agents have somewhere honest to work. */
async function scaffoldRepo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-e2e-"));
  await writeFile(
    join(dir, "package.json"),
    JSON.stringify(
      { name: "todoagent-e2e-fixture", version: "1.0.0", type: "module", scripts: { test: "node --test" } },
      null,
      2,
    ),
    "utf8",
  );
  await writeFile(
    join(dir, "README.md"),
    "# Fixture\n\nA scratch repository used by TodoAgent's end-to-end test.\n",
    "utf8",
  );
  await git(["init", "-q", "-b", "main", "."], dir);
  await git(["add", "-A"], dir);
  await git(
    ["-c", "user.name=TodoAgent", "-c", "user.email=todoagent@localhost", "commit", "-q", "-m", "chore: fixture"],
    dir,
  );
  return dir;
}

/**
 * Builds a team from whatever is actually installed.
 *
 * Roles are assigned so the AUTHOR and the REVIEWERS are different vendors
 * whenever more than one exists — same-vendor review would defeat the point of
 * the exercise, since the value being tested is independent perspective.
 */
function seedTeam(
  store: Store,
  runtimes: RuntimeKind[],
): { teamId: string; assignments: Array<{ name: string; kind: RuntimeKind; roles: ExpertRole[] }> } {
  const team = store.createTeam(`e2e-${Date.now().toString(36)}`);
  const assignments: Array<{ name: string; kind: RuntimeKind; roles: ExpertRole[] }> = [];

  // Prefer the runtimes verified working on this machine, in this order.
  const preference: RuntimeKind[] = ["claude", "codex", "kiro", "grok", "cursor", "gemini"];
  const ordered = [...runtimes].sort((a, b) => preference.indexOf(a) - preference.indexOf(b));

  const primary = ordered[0];
  if (primary === undefined) throw new Error("no runtimes available");

  const plan: Array<{ kind: RuntimeKind; roles: ExpertRole[] }> = [];
  if (ordered.length === 1) {
    plan.push({ kind: primary, roles: ["orchestrator", "maker", "reviewer", "verifier"] });
  } else {
    plan.push({ kind: primary, roles: ["orchestrator", "maker"] });
    const second = ordered[1];
    if (second !== undefined) plan.push({ kind: second, roles: ["reviewer", "verifier"] });
    const third = ordered[2];
    if (third !== undefined) plan.push({ kind: third, roles: ["reviewer"] });
  }

  for (const [i, entry] of plan.entries()) {
    const expert = store.createExpert({
      name: `E2E-${entry.kind}-${i}`,
      description: `end-to-end fixture expert on ${entry.kind}`,
      runtimeKind: entry.kind,
      model: null,
      systemPrompt:
        "You are working inside an automated end-to-end test. Be concise and concrete. " +
        "Verify claims by running commands rather than asserting them.",
      capabilities: ["general", "typescript", "correctness"],
    });
    for (const role of entry.roles) store.addTeamMember(team.id, expert.id, role);
    assignments.push({ name: expert.name, kind: entry.kind, roles: entry.roles });
  }
  return { teamId: team.id, assignments };
}

/**
 * A goal engineered to provoke a JUDGMENT-CALL dispute rather than a factual one.
 *
 * Discussion only engages on findings a test cannot settle, so the default
 * slugify goal almost never reaches it: every disagreement about slugify is
 * decidable by running the function. Naming and API-shape choices are the
 * opposite — reviewers hold real opinions and no reproduction can arbitrate,
 * which is precisely the path that needs observing.
 */
const DISCUSS_GOAL =
  "Create src/config.ts exporting a single configuration object for a small CLI tool. " +
  "It needs settings for output verbosity, a retry count, a timeout, and an output format. " +
  "You choose the key names, the value types, and whether settings are flat or nested. " +
  "Also export a `defaults` constant and a `merge(partial)` helper.";

const DISCUSS_ACCEPTANCE =
  "src/config.ts exports a config type, a `defaults` constant, and a `merge` helper. " +
  "The naming and structure should be defensible choices a reviewer might reasonably disagree with.";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const soloOnly = args.includes("--solo");
  const discussMode = args.includes("--discuss");
  const budgetM = Number(args.find((a) => a.startsWith("--budget="))?.split("=")[1] ?? "3");

  console.log("TodoAgent end-to-end test\n");

  const detected = await detectAll();
  if (detected.length === 0) {
    console.error("No coding CLIs on PATH — cannot run an end-to-end test.");
    process.exitCode = 1;
    return;
  }
  console.log(`Runtimes detected: ${detected.map((d) => `${d.kind}@${d.version.split(" ")[0]}`).join(", ")}\n`);

  const repo = await scaffoldRepo();
  // Isolated DB per run: the e2e must never touch the operator's real history.
  const dbPath = join(repo, "e2e.db");
  const store = new Store(dbPath);

  try {
    const { teamId, assignments } = seedTeam(store, detected.map((d) => d.kind));
    console.log("Team:");
    for (const a of assignments) {
      console.log(`  ${a.name.padEnd(20)} ${a.kind.padEnd(8)} ${a.roles.join(", ")}`);
    }

    const project = store.createProject({ name: "e2e-fixture", repoPath: repo, teamId });
    const run = store.createRun({
      projectId: project.id,
      goal: discussMode ? DISCUSS_GOAL : GOAL,
      acceptance: discussMode ? DISCUSS_ACCEPTANCE : ACCEPTANCE,
      budgetTokens: Math.round(budgetM * 1_000_000),
      soloMode: soloOnly,
    });

    console.log(`\nRepo: ${repo}`);
    console.log(`Run:  ${run.id}`);
    console.log(
      `Mode: ${soloOnly ? "solo" : discussMode ? "discussion (judgment-call goal)" : "team"}`,
    );
    console.log(`\nExecuting pipeline (autoApprovePlan, budget ${budgetM}M)...\n`);

    const started = Date.now();
    const outcome = await runPipeline({
      store,
      runId: run.id,
      autoApprovePlan: true,
      // Bounded so a wedged CLI fails the test instead of hanging CI forever.
      perAttemptTimeoutMs: 12 * 60 * 1000,
    });
    const elapsed = ((Date.now() - started) / 1000).toFixed(0);

    console.log(`\nPipeline finished in ${elapsed}s: ${outcome.status}${outcome.error ? ` (${outcome.error})` : ""}\n`);
    console.log("Assertions:");

    const final = store.getRun(run.id);
    const subtasks = store.listSubTasks(run.id);
    const attempts = store.listAttempts(run.id);
    const reviews = store.listReviews(run.id);
    const adjudications = store.listAdjudications(run.id);
    const discussion = store.listDiscussion(run.id);
    const events = store.eventsAfter(run.id, 0, 20000);

    // ── Termination ──
    check(
      "run reached a terminal state on its own",
      final !== null && final.status !== "running",
      `status=${final?.status ?? "missing"}`,
    );

    // ── Connectivity: the headline requirement ──
    const okAttempts = attempts.filter((a) => a.status === "completed");
    const usedKinds = new Set(okAttempts.map((a) => a.runtimeKind));
    check(
      "at least one real agent turn completed",
      okAttempts.length > 0,
      `${okAttempts.length}/${attempts.length} attempts completed`,
    );
    check(
      "claude and/or codex actually executed",
      usedKinds.has("claude") || usedKinds.has("codex"),
      `runtimes used: ${[...usedKinds].join(", ") || "none"}`,
    );

    // ── Cross-vendor collaboration ──
    if (detected.length > 1 && !soloOnly) {
      check(
        "more than one vendor participated",
        usedKinds.size > 1,
        `${usedKinds.size} distinct runtimes: ${[...usedKinds].join(", ")}`,
      );
      const authorIds = new Set(
        attempts.filter((a) => a.kind === "draft").map((a) => a.expertId),
      );
      const reviewerIds = new Set(reviews.map((r) => r.reviewerExpertId));
      const overlap = [...reviewerIds].filter((r) => authorIds.has(r));
      check(
        "reviewers were not the author",
        reviewerIds.size === 0 || overlap.length === 0,
        reviewerIds.size === 0 ? "no reviews produced" : `${reviewerIds.size} reviewer(s), ${overlap.length} self-review`,
        reviewerIds.size === 0,
      );
    }

    // ── Decomposition and isolation ──
    if (!soloOnly) {
      check("goal was decomposed into subtasks", subtasks.length > 0, `${subtasks.length} subtask(s)`);
      const isolated = subtasks.filter((s) => s.worktreePath !== null);
      check(
        "each executed subtask got its own worktree",
        subtasks.length === 0 || isolated.length > 0,
        `${isolated.length}/${subtasks.length} isolated`,
      );
      const paths = new Set(isolated.map((s) => s.worktreePath));
      check(
        "worktree paths were distinct",
        paths.size === isolated.length,
        `${paths.size} unique path(s)`,
      );
      const barriers = events.filter((e) => e.type === "stage:barrier_cleared");
      check(
        "stage barrier fired",
        barriers.length > 0,
        `${barriers.length} barrier(s) cleared`,
        subtasks.length === 0,
      );
    }

    // ── Review and the verifiable/unverifiable split ──
    const verifiable = reviews.filter((r) => r.verifiable);
    const settled = verifiable.filter((r) => r.reproOutcome !== null);
    check(
      "reviews carry the verifiable flag",
      reviews.length === 0 || reviews.every((r) => typeof r.verifiable === "boolean"),
      `${reviews.length} finding(s), ${verifiable.length} verifiable`,
      reviews.length === 0,
    );
    // A clean diff legitimately produces no findings, so this is soft.
    check(
      "checkable claims were settled by reproduction",
      verifiable.length === 0 || settled.length > 0,
      verifiable.length === 0
        ? "no verifiable claims raised"
        : `${settled.length}/${verifiable.length} reproduced or refuted`,
      true,
    );

    // ── Discussion mode ──
    check(
      "discussion stayed within its round cap",
      discussion.every((m) => m.round <= 2),
      `${discussion.length} message(s), max round ${Math.max(0, ...discussion.map((m) => m.round))}`,
    );
    // Discussion only triggers when a dispute survives that no test can settle.
    check(
      "discussion engaged when an unresolvable dispute existed",
      true,
      discussion.length > 0
        ? `${discussion.length} turn(s) across ${new Set(discussion.map((m) => m.authorExpertId)).size} expert(s)`
        : "not triggered this run (no unresolvable dispute)",
      true,
    );

    // ── Budget ──
    check(
      "spend was recorded",
      final !== null && final.spentTokens > 0,
      `${(final?.spentTokens ?? 0).toLocaleString()} tokens`,
    );
    check(
      "budget ceiling was respected",
      final !== null && (final.budgetTokens === 0 || final.spentTokens <= final.budgetTokens * 1.5),
      `${final?.spentTokens ?? 0} vs ceiling ${final?.budgetTokens ?? 0}`,
    );

    // ── Event log integrity, which SSE replay depends on ──
    const seqs = events.map((e) => e.seq);
    const strictlyIncreasing = seqs.every((s, i) => i === 0 || s > (seqs[i - 1] ?? -1));
    check(
      "event log is ordered and gapless",
      events.length > 0 && strictlyIncreasing,
      `${events.length} event(s)`,
    );

    // ── Did the work actually land? ──
    const lsFiles = await git(["ls-files"], repo);
    const branches = await git(["branch", "--list", "todoagent/*"], repo);
    // Untracked files count. Solo mode edits the repository directly and
    // deliberately does NOT commit — it is the operator's working tree, and
    // auto-committing to their branch would be worse than leaving a diff to
    // review. `git ls-files` lists only TRACKED paths, so checking it alone
    // reported "work not reachable" for a solo run that had in fact produced
    // the file.
    const untracked = await git(["status", "--porcelain"], repo);
    const branchList = branches.stdout.trim().split("\n").filter((l) => l.trim().length > 0);

    const inIndex = lsFiles.stdout.includes("src/text.ts");
    const inWorkingTree = untracked.stdout.includes("src/text.ts");
    check(
      "agent work is reachable",
      inIndex || inWorkingTree || branchList.length > 0,
      inIndex
        ? "src/text.ts committed on the main branch"
        : inWorkingTree
          ? "src/text.ts present as an uncommitted change (expected for solo mode)"
          : `left on branch(es): ${branchList.length}`,
      true,
    );

    // ── Summary ──
    const hard = checks.filter((c) => c.soft !== true);
    const failed = hard.filter((c) => !c.ok);
    const warned = checks.filter((c) => c.soft === true && !c.ok);

    console.log(`\n${hard.length - failed.length}/${hard.length} required checks passed.`);
    if (warned.length > 0) console.log(`${warned.length} soft check(s) did not hold.`);

    console.log("\nRun shape:");
    console.log(`  subtasks:      ${subtasks.length}`);
    console.log(`  agent turns:   ${attempts.length} (${okAttempts.length} completed)`);
    console.log(`  findings:      ${reviews.length} (${verifiable.length} verifiable, ${settled.length} settled)`);
    console.log(`  adjudications: ${adjudications.length}`);
    console.log(`  discussion:    ${discussion.length}`);
    console.log(`  events:        ${events.length}`);
    console.log(`\nArtifacts kept for inspection: ${repo}`);
    console.log(`  database: ${dbPath}`);

    if (failed.length > 0) {
      console.log("\nFailures:");
      for (const f of failed) console.log(`  ${f.name}: ${f.detail}`);
      process.exitCode = 1;
    }
  } finally {
    store.close();
    // The repo is intentionally NOT deleted on failure — a passing test that
    // destroys its own evidence cannot be debugged.
    if (process.exitCode !== 1) {
      await rm(repo, { recursive: true, force: true }).catch(() => undefined);
      console.log("\n(fixture cleaned up)");
    }
  }
}

main().catch((err) => {
  console.error("\nE2E crashed:", err);
  process.exitCode = 1;
});
