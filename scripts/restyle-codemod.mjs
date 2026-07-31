#!/usr/bin/env node
/**
 * One-shot codemod: brutalist/dark class names -> the zinc design system.
 *
 * Why a script rather than hand-editing six files: the mapping is purely
 * mechanical, but three of the old class names (`surface`, `label`, `meta`) are
 * also ordinary English words that appear as props, variables and object keys in
 * these same files. A blind global replace would corrupt real code, so this
 * rewrites tokens ONLY inside `className` values and leaves everything else
 * alone.
 *
 * CSS custom properties are handled separately and globally: `--color-foo` can
 * never collide with an identifier, so there is nothing to disambiguate.
 *
 * Run with --check to fail without writing (useful once, to confirm the codemod
 * is idempotent and no stale token survives).
 */

import { readFileSync, writeFileSync } from "node:fs";
import { argv } from "node:process";

/** Old class -> new class. Order is irrelevant; matching is whole-token. */
const CLASS_MAP = new Map(
  Object.entries({
    // Surfaces
    surface: "card",
    "surface-raised": "card",
    "surface-inset": "inset",
    "surface-hero": "card",
    "card-link": "card-hover",
    brut: "card",
    "brut-lift": "card",
    "brut-flat": "panel",
    "brut-inset": "inset",
    "brut-press": "card-hover",

    // Typography
    label: "t-label",
    meta: "t-meta",
    "title-md": "t-md",
    "title-lg": "t-lg",
    "title-hero": "t-hero",

    // Buttons
    "btn-bare": "btn-ghost",
    "btn-signal": "btn-primary",

    // Chrome
    "panel-header": "app-header",
    "divide-hard": "divide-soft",

    // Motion
    breathe: "pulse",
    blink: "pulse",
    marching: "indeterminate",

    // Tailwind colour utilities bound to deleted tokens
    "bg-paper": "bg-bg",
    "bg-signal": "bg-warn-soft",
    "bg-faint": "bg-surface-2",
    "bg-faint-2": "bg-muted",
    "border-ink": "border-line",
    "text-ink": "text-fg",
    "text-mute": "text-muted-fg",
    "bg-ink": "bg-fg",
  }),
);

/** Old CSS custom property -> new one. Applied everywhere, not just className. */
const VAR_MAP = new Map(
  Object.entries({
    "--color-fg-muted": "--color-muted-fg",
    "--color-fg-subtle": "--color-subtle-fg",
    "--color-surface-raised": "--color-bg",
    "--color-surface-sunken": "--color-surface",
    "--color-danger": "--color-bad",
    "--color-accent-dim": "--color-accent-soft",
    "--color-aqua": "--color-info",
    "--color-aqua-soft": "--color-info-soft",
    "--color-signal": "--color-warn",
    "--color-signal-soft": "--color-warn-soft",
    // Reasoning/"thinking" output shares the purple used for subjective review
    // findings — both mean "a model's opinion", not a measured fact.
    "--color-think": "--color-grape",
    "--color-faint": "--color-surface-2",
    "--color-faint-2": "--color-line-strong",
    "--color-paper": "--color-bg",
    "--color-ink": "--color-fg",
    "--color-mute": "--color-muted-fg",
  }),
);

/**
 * Rewrites the class tokens inside one className value.
 *
 * Splits on whitespace so only whole tokens match: `surface` is replaced,
 * `bg-surface` and `surfaceRef` are not. Tailwind variant prefixes are preserved
 * by mapping only the part after the last colon, so `md:surface` and
 * `hover:card-link` both work.
 */
function rewriteClassValue(value) {
  return value.replace(/[^\s`${}"'()?:]+/g, (token) => {
    const cut = token.lastIndexOf(":");
    const prefix = cut === -1 ? "" : token.slice(0, cut + 1);
    const bare = cut === -1 ? token : token.slice(cut + 1);
    const mapped = CLASS_MAP.get(bare);
    return mapped ? prefix + mapped : token;
  });
}

/**
 * Finds every className value in a file and rewrites just those spans.
 *
 * Handles `className="..."`, `className={"..."}` and `className={`...`}`,
 * including template literals with `${}` interpolations — the callback skips
 * expression punctuation, so a ternary's string branches are rewritten while the
 * surrounding expression is untouched.
 */
function rewriteFile(src) {
  let out = src;

  // className="..."  |  className='...'
  out = out.replace(/className=(["'])([\s\S]*?)\1/g, (m, q, v) => `className=${q}${rewriteClassValue(v)}${q}`);

  // className={ ...anything... } — rewrite string and template contents inside.
  out = out.replace(/className=\{([\s\S]*?)\}(?=[\s/>])/g, (m, expr) => {
    const rewritten = expr
      .replace(/(["'])((?:(?!\1)[\s\S])*?)\1/g, (s, q, v) => `${q}${rewriteClassValue(v)}${q}`)
      .replace(/`((?:[^`\\]|\\[\s\S])*?)`/g, (s, v) => `\`${rewriteClassValue(v)}\``);
    return `className={${rewritten}}`;
  });

  out = rewriteVars(out);

  return out;
}

/**
 * Rewrites CSS custom properties by WHOLE token.
 *
 * The obvious implementation — `src.split(from).join(to)` per entry — is wrong,
 * and wrong in a way that silently corrupts correct code: `--color-mute` is a
 * prefix of `--color-muted-fg`, so substring replacement turned the already-valid
 * `--color-muted-fg` into `--color-muted-fgd-fg`. Twelve occurrences, in files
 * that still compiled afterwards because a bad var name is only a runtime no-op.
 *
 * Matching the entire `--color-…` identifier greedily and then looking it up
 * makes prefix collisions structurally impossible rather than merely avoided:
 * `--color-muted-fg` matches in full, misses the map, and is left alone.
 */
function rewriteVars(src) {
  return src.replace(/--color-[a-z0-9-]+/g, (token) => VAR_MAP.get(token) ?? token);
}

const check = argv.includes("--check");
const files = argv.slice(2).filter((a) => !a.startsWith("--"));
if (files.length === 0) {
  console.error("usage: restyle-codemod.mjs [--check] <file>...");
  process.exit(2);
}

let changed = 0;
for (const file of files) {
  const before = readFileSync(file, "utf8");
  const after = rewriteFile(before);
  if (before === after) {
    console.log(`  ok    ${file}`);
    continue;
  }
  changed++;
  if (check) {
    console.log(`  WOULD ${file}`);
  } else {
    writeFileSync(file, after);
    console.log(`  wrote ${file}`);
  }
}
console.log(check ? `${changed} file(s) would change` : `${changed} file(s) rewritten`);
process.exit(check && changed > 0 ? 1 : 0);
