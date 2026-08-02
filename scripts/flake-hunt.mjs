#!/usr/bin/env node
/**
 * Runs the test suite repeatedly and keeps the evidence when it fails.
 *
 * Exists because I lost a real failure twice in one session. The command was
 * `pnpm test | grep -oE '… (pass|fail) [0-9]+'`, which reports the COUNTS and
 * discards everything else — so a run that said "1 failed" left no record of
 * WHICH test failed or why. By the time I noticed, the process had exited and the
 * output was gone.
 *
 * That is a bad trade for a project whose whole subject is parallel agents:
 * concurrency bugs surface as one failure in N runs, and the one run that catches
 * them is the only chance to see them. So every run's full output is written to
 * disk, and failing runs are kept and summarised.
 *
 *   node scripts/flake-hunt.mjs            # 5 rounds of `pnpm test`
 *   node scripts/flake-hunt.mjs 20         # 20 rounds
 *   node scripts/flake-hunt.mjs 10 --keep  # keep passing logs too
 */

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { argv, exit } from "node:process";

const rounds = Number(argv.find((a) => /^\d+$/.test(a)) ?? 5);
const keepAll = argv.includes("--keep");

const dir = mkdtempSync(join(tmpdir(), "todoagent-flake-"));
console.log(`logs: ${dir}`);

/** Runs one round, returning its output and exit code. */
function once(round) {
  return new Promise((resolve) => {
    const child = spawn("pnpm", ["test"], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (c) => (out += c.toString()));
    child.stderr.on("data", (c) => (out += c.toString()));
    child.on("error", (e) => resolve({ code: -1, out: `${out}\nspawn failed: ${e.message}` }));
    child.on("close", (code) => {
      const path = join(dir, `round-${String(round).padStart(2, "0")}.log`);
      writeFileSync(path, out);
      resolve({ code: code ?? -1, out, path });
    });
  });
}

/** Sums the per-package `ℹ pass N` / `ℹ fail N` lines Turborepo interleaves. */
function tally(out, kind) {
  let total = 0;
  for (const m of out.matchAll(new RegExp(`ℹ ${kind} (\\d+)`, "g"))) total += Number(m[1]);
  return total;
}

/** The lines that actually identify a failure, in order of usefulness. */
function evidence(out) {
  const lines = out.split("\n");
  const names = [...new Set(lines.filter((l) => /✖ /.test(l) && !/failing tests/.test(l)))];
  const errors = lines.filter((l) => /(AssertionError|^\s*Error:|fatal|致命错误|not ok)/.test(l));
  return [...names.slice(0, 8), ...errors.slice(0, 12)];
}

const failed = [];
for (let round = 1; round <= rounds; round++) {
  const { code, out, path } = await once(round);
  const pass = tally(out, "pass");
  const fail = tally(out, "fail");
  const bad = code !== 0 || fail > 0;

  console.log(`round ${round}/${rounds}: exit=${code} pass=${pass} fail=${fail}${bad ? "  <-- FAILED" : ""}`);

  if (bad) {
    failed.push({ round, path });
    for (const line of evidence(out)) console.log(`    ${line.trim().slice(0, 160)}`);
  } else if (!keepAll && path) {
    rmSync(path, { force: true });
  }
}

console.log(`\n${rounds - failed.length}/${rounds} rounds clean.`);
if (failed.length === 0) {
  console.log("No failure captured. That is NOT proof the suite is deterministic —");
  console.log("a 1-in-30 flake survives 10 clean rounds comfortably.");
  if (!keepAll) rmSync(dir, { recursive: true, force: true });
  exit(0);
}

console.log(`\nFull logs for the ${failed.length} failing round(s):`);
for (const f of failed) console.log(`  ${f.path}`);
exit(1);
