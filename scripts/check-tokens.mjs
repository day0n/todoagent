#!/usr/bin/env node
/**
 * Verifies that every `--color-*` referenced by the app is actually defined.
 *
 * This exists because two hand-written grep checks both produced false
 * positives, in opposite directions, and nearly sent me chasing a bug that was
 * not there:
 *
 *   - `--color-muted-fg` matches a `d-fg` corruption pattern (`mute` + `d-fg`),
 *     so a valid token looked like damage.
 *   - `\blabel\b` matches the `label` inside `t-label`, because a hyphen is a
 *     word boundary — so correctly-migrated class names looked stale.
 *
 * A set difference has no such ambiguity: a token is either defined or it is
 * not. An undefined custom property is invisible at build time (CSS treats it as
 * a no-op and the element silently renders with no background), which is exactly
 * the class of bug that needs a mechanical check rather than an eyeball.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

const WEB = argv[2] ?? "apps/web";
const CSS = join(WEB, "app/globals.css");

/** Collects the tokens declared inside the `@theme { … }` block. */
function definedTokens(cssPath) {
  const css = readFileSync(cssPath, "utf8");
  const start = css.indexOf("@theme");
  if (start === -1) throw new Error(`no @theme block in ${cssPath}`);

  // Walk braces to find the matching close, so a nested block cannot truncate
  // the scan early.
  let depth = 0;
  let end = -1;
  for (let i = css.indexOf("{", start); i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) {
      end = i;
      break;
    }
  }
  if (end === -1) throw new Error("unterminated @theme block");

  const block = css.slice(start, end);
  return new Set(block.match(/--color-[a-z0-9-]+(?=\s*:)/g) ?? []);
}

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry === ".next") continue;
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.tsx?$/.test(entry)) out.push(p);
  }
  return out;
}

const defined = definedTokens(CSS);
const refs = new Map();

for (const file of [...walk(join(WEB, "app")), ...walk(join(WEB, "components"))]) {
  const src = readFileSync(file, "utf8");
  for (const token of src.match(/--color-[a-z0-9-]+/g) ?? []) {
    if (!refs.has(token)) refs.set(token, new Set());
    refs.get(token).add(file);
  }
}

const missing = [...refs.keys()].filter((t) => !defined.has(t)).sort();

console.log(`defined:    ${defined.size} tokens in ${CSS}`);
console.log(`referenced: ${refs.size} tokens across ${WEB}`);

if (missing.length === 0) {
  console.log("\nOK — every referenced token is defined.");
  exit(0);
}

console.log(`\nUNDEFINED (${missing.length}):`);
for (const token of missing) {
  console.log(`  ${token}`);
  for (const file of [...refs.get(token)].sort()) console.log(`      ${file}`);
}
exit(1);
