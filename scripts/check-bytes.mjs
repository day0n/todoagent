#!/usr/bin/env node
/**
 * Fails when a source file contains bytes that break text tooling.
 *
 * Written after a single NUL byte reached `apps/web/components/chat.tsx` — I had
 * meant to type a space in a template literal and produced a NUL byte instead. The
 * bug was invisible by every normal measure: NUL is a legal code point, so
 * TypeScript compiled it, the tests passed, and the page rendered correctly. The
 * value was only ever used as a React key, and it worked as a separator.
 *
 * What it DID break was the toolchain, silently. `file` reported the file as
 * `data` rather than text, so grep treated it as binary and printed nothing at
 * all — no error, no "binary file matches", just an empty result. Three separate
 * greps came back clean on a file that plainly contained the string, and a
 * `grep -c $'\0'` check meant to detect exactly this also returned nothing,
 * because grep had already given up on the file. Only `grep -a` worked.
 *
 * That is the reason this check exists rather than a code comment: any grep-based
 * verification against such a file reports success by returning nothing, which is
 * indistinguishable from a real pass.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

const ROOTS = argv.slice(2).filter((a) => !a.startsWith("--"));
const SKIP = new Set(["node_modules", ".next", ".git", "dist", "build", "coverage"]);
const EXTENSIONS = /\.(ts|tsx|js|jsx|mjs|cjs|css|json|sql|md|yaml|yml|txt)$/;

/** Tab, LF and CR are the only control characters a source file needs. */
const ALLOWED = new Set([0x09, 0x0a, 0x0d]);

function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (SKIP.has(entry)) continue;
    const path = join(dir, entry);
    let st;
    try {
      st = statSync(path);
    } catch {
      continue;
    }
    if (st.isDirectory()) walk(path, out);
    else if (EXTENSIONS.test(entry)) out.push(path);
  }
  return out;
}

/** Byte offset -> 1-based line number, counting LFs. */
function lineAt(buf, offset) {
  let line = 1;
  for (let i = 0; i < offset; i++) if (buf[i] === 0x0a) line++;
  return line;
}

const files = ROOTS.length > 0 ? ROOTS.flatMap((r) => (statSync(r).isDirectory() ? walk(r) : [r])) : walk(".");

const problems = [];
for (const file of files) {
  const buf = readFileSync(file);
  for (let i = 0; i < buf.length; i++) {
    const b = buf[i];
    // DEL (0x7f) is included: it is equally invisible and equally confusing.
    if ((b < 0x20 && !ALLOWED.has(b)) || b === 0x7f) {
      problems.push({ file, offset: i, byte: b, line: lineAt(buf, i) });
    }
  }
}

console.log(`scanned ${files.length} file(s)`);

if (problems.length === 0) {
  console.log("OK — no stray control bytes.");
  exit(0);
}

// Grouped by file, since one bad edit usually leaves several in one place.
const byFile = new Map();
for (const p of problems) {
  if (!byFile.has(p.file)) byFile.set(p.file, []);
  byFile.get(p.file).push(p);
}

console.log(`\nFOUND ${problems.length} stray control byte(s):`);
for (const [file, list] of byFile) {
  console.log(`\n  ${file}`);
  for (const p of list.slice(0, 5)) {
    const hex = `0x${p.byte.toString(16).padStart(2, "0")}`;
    console.log(`    line ${p.line} (offset ${p.offset}): ${hex}`);
  }
  if (list.length > 5) console.log(`    …and ${list.length - 5} more`);
}
console.log("\nNote: grep cannot reliably find these — it treats such a file as");
console.log("binary and prints nothing, so a grep check will look like it passed.");
exit(1);
