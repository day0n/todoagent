#!/usr/bin/env node
/**
 * Runs every static checker in this directory and reports one verdict.
 *
 * They exist because each one caught a real bug that typecheck, the test suite,
 * and an HTTP 200 all reported as fine:
 *
 *   check-bytes       a NUL byte in a template literal, which made `file` report
 *                     the source as binary and grep silently return nothing
 *   check-styles      five class names and one custom property left over from the
 *                     previous design system, all of which styled nothing
 *   check-tokens      a `--color-*` reference with no definition
 *   check-breakpoints the responsive rules, which cannot be checked visually here
 *   dead-exports      exported symbols with no consumer
 *
 * Individually they are easy to forget, which defeats the point of having written
 * them. One entry point is the difference between a check that runs and a check
 * that exists.
 *
 * Exit codes from each script: 0 pass, 1 fail, 2 unavailable (a prerequisite is
 * missing rather than something being wrong). Only 1 fails the run — treating
 * "could not check" as "checked and fine" is exactly the confusion these scripts
 * were written to remove.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

const HERE = join(import.meta.dirname);
const ROOT = join(HERE, "..");
const WEB = join(ROOT, "apps/web");
const verbose = argv.includes("--verbose");

/**
 * Locates the compiled stylesheet.
 *
 * Two checkers need it, and it only exists after a build or a page load in dev.
 * Finding it once here means each of them reports "unavailable" for the same
 * reason rather than each inventing its own.
 */
function findCompiledCss() {
  for (const dir of [join(WEB, ".next/static/css/app"), join(WEB, ".next/static/css")]) {
    if (!existsSync(dir)) continue;
    for (const entry of readdirSync(dir)) {
      const p = join(dir, entry);
      if (statSync(p).isFile() && entry.endsWith(".css")) return p;
    }
  }
  return null;
}

const css = findCompiledCss();

const CHECKS = [
  {
    name: "bytes",
    what: "stray control characters in source",
    args: ["check-bytes.mjs", "apps", "packages", "scripts"],
  },
  {
    name: "tokens",
    what: "--color-* references against @theme",
    args: ["check-tokens.mjs", "apps/web"],
  },
  {
    name: "styles",
    what: "classes and custom properties against compiled CSS",
    args: ["check-styles.mjs", "apps/web"],
    // The script finds the sheet itself; this only decides whether to try.
    unavailable: css === null ? "no compiled CSS — run a build or load a page" : null,
  },
  {
    name: "breakpoints",
    what: "responsive rules the desktop layout needs",
    args: css === null ? null : ["check-breakpoints.mjs", css],
    unavailable: css === null ? "no compiled CSS — run a build or load a page" : null,
  },
  {
    name: "dead-exports",
    what: "exported symbols with no consumer",
    args: ["dead-exports.mjs"],
  },
];

const results = [];

for (const check of CHECKS) {
  if (check.unavailable !== null && check.unavailable !== undefined) {
    results.push({ ...check, status: "skip", detail: check.unavailable });
    continue;
  }
  /*
   * `args[0]` is the script; the rest are ITS arguments.
   *
   * Spreading them all into `join` instead concatenated them into one path —
   * `scripts/check-bytes.mjs/apps/packages/scripts` — so every check would have
   * failed with MODULE_NOT_FOUND. Loud rather than silent, but still wrong.
   */
  const [script, ...scriptArgs] = check.args;
  const res = spawnSync(process.execPath, [join(HERE, script), ...scriptArgs], {
    cwd: ROOT,
    encoding: "utf8",
  });
  const status = res.status === 0 ? "pass" : res.status === 2 ? "skip" : "fail";
  results.push({ ...check, status, output: `${res.stdout ?? ""}${res.stderr ?? ""}` });
}

const width = Math.max(...CHECKS.map((c) => c.name.length));
console.log("");
for (const r of results) {
  const mark = r.status === "pass" ? "ok  " : r.status === "skip" ? "skip" : "FAIL";
  console.log(`  ${mark}  ${r.name.padEnd(width)}  ${r.what}`);
  if (r.status === "skip" && r.detail !== undefined) console.log(`        ${r.detail}`);
  // A failure's own output is the useful part; a pass's is noise unless asked for.
  if (r.status === "fail" || verbose) {
    for (const line of (r.output ?? "").split("\n")) {
      if (line.trim() !== "") console.log(`        ${line}`);
    }
  }
}

const failed = results.filter((r) => r.status === "fail");
const skipped = results.filter((r) => r.status === "skip");

console.log("");
if (failed.length === 0) {
  console.log(
    skipped.length === 0
      ? "All checks passed."
      : `${results.length - skipped.length} passed, ${skipped.length} could not run.`,
  );
  exit(0);
}
console.log(`${failed.length} check(s) failed: ${failed.map((f) => f.name).join(", ")}`);
exit(1);
