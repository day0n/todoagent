#!/usr/bin/env node
/**
 * Reports exported symbols that nothing in the repository consumes.
 *
 * Exists because "declared but never wired up" has been the single most common
 * defect in this codebase — a semaphore that was never passed, an endpoint the UI
 * could not reach, a `resolveEscalation` whose result nothing read. Each looked
 * finished and did nothing. `noUnusedLocals` catches the file-local case; this
 * catches the cross-file one.
 *
 * Written as a FILE rather than `node -e`. The first attempt was inline in a
 * single-quoted shell string, where `"\\\\b"` reached Node as a literal
 * backslash-then-b instead of a word boundary — so every pattern matched nothing
 * and the script confidently reported all 117 exports as dead. A tool that lies
 * about its own subject is worse than no tool.
 *
 * A test counts as a consumer: a symbol exported solely so it can be tested is
 * legitimately used, and the alternative is testing through a private path.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOTS = [
  "packages/core/src",
  "apps/engine/src",
  "apps/web/lib",
  "apps/web/components",
  "apps/web/app",
];

/** Names that are consumed by a framework or tool, not by our own code. */
const FRAMEWORK_EXPORTS = new Set([
  // Next.js reads these off the module itself.
  "metadata",
  "viewport",
  "default",
  "generateMetadata",
]);

function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === ".next" || entry.name === "node_modules") continue;
      walk(full, out);
    } else if (/\.tsx?$/.test(entry.name) && statSync(full).isFile()) {
      out.push(full);
    }
  }
  return out;
}

const files = ROOTS.flatMap((r) => walk(r));
const sources = files.map((file) => ({ file, src: readFileSync(file, "utf8") }));

// ── Collect exports (tests are consumers, not producers) ──
const exported = new Map();
for (const { file, src } of sources) {
  if (/\.test\.tsx?$/.test(file)) continue;
  const re = /^export\s+(?:async\s+)?(?:function|const|class|let)\s+([A-Za-z_$][\w$]*)/gm;
  for (const m of src.matchAll(re)) {
    if (m[1] !== undefined) exported.set(m[1], file);
  }
}

// ── Count references ──
const dead = [];
for (const [name, origin] of exported) {
  if (FRAMEWORK_EXPORTS.has(name)) continue;
  // Word-boundary match, built from a real RegExp literal source so no escaping
  // layer can mangle it.
  const re = new RegExp(String.raw`\b` + name + String.raw`\b`, "g");
  let refs = 0;
  for (const { file, src } of sources) {
    const hits = src.match(re)?.length ?? 0;
    // The declaration itself is not a use.
    refs += file === origin ? Math.max(0, hits - 1) : hits;
  }
  if (refs === 0) dead.push([name, origin]);
}

console.log(`${exported.size} exported symbols across ${files.length} files.`);
if (dead.length === 0) {
  console.log("Every export has at least one consumer.");
} else {
  console.log(`\n${dead.length} with no consumer:`);
  for (const [name, file] of dead.sort((a, b) => a[0].localeCompare(b[0]))) {
    console.log(`  ${name.padEnd(30)} ${file}`);
  }
}

// Reported, not enforced: a genuinely-public API can legitimately have no internal
// caller yet, and failing the build over that would be obstruction.
process.exitCode = 0;
