#!/usr/bin/env node
/**
 * Fails when a component uses a class or custom property that nothing defines.
 *
 * This is the check that should have existed from the start. `check-tokens.mjs`
 * only diffed `--color-*` against the `@theme` block, and reported OK while four
 * class names and one custom property from the previous design system were still
 * in use:
 *
 *   .input       -> the system defines .field      (4 sites)
 *   .body-muted  -> the system defines .t-meta     (7 sites)
 *   .title-xl    -> the system defines .t-hero     (2 sites)
 *   .sweep       -> the system defines .indeterminate (1 site)
 *   var(--highlight) -> never defined              (3 sites)
 *
 * Nothing failed, which is the whole problem. An undefined class is not an error
 * in CSS — it styles nothing. `title-xl` still rendered large because it sat on an
 * `<h1>`, and `body-muted` still rendered text, so the pages looked plausible.
 * `--highlight` was worse than inert: an undefined `var()` invalidates the ENTIRE
 * declaration at computed-value time, so `box-shadow: var(--shadow-md),
 * var(--highlight)` resolved to none and took the working half down with it.
 *
 * Typecheck cannot see any of this, tests do not render CSS, and an HTTP 200 says
 * nothing about it. Hence a mechanical check against the COMPILED stylesheet,
 * which is the only artifact that knows what actually exists — my hand-written
 * `@theme` block does not contain the Tailwind-supplied tokens (`--radius-lg`,
 * `--shadow-md`) that the components legitimately use.
 *
 *   node scripts/check-styles.mjs [apps/web]
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

const WEB = argv[2] ?? "apps/web";

/**
 * Finds the compiled stylesheet.
 *
 * Read from disk rather than fetched over HTTP so this runs without a dev server,
 * which is what makes it usable in CI or as a pre-commit step.
 */
function findCss(root) {
  const dirs = [join(root, ".next/static/css"), join(root, ".next/static/css/app")];
  const found = [];
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    for (const entry of readdirSync(dir)) {
      const p = join(dir, entry);
      if (statSync(p).isFile() && entry.endsWith(".css")) found.push(p);
    }
  }
  return found;
}

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry === ".next") continue;
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.tsx$/.test(entry)) out.push(p);
  }
  return out;
}

/**
 * Extracts the class tokens a file actually asks for.
 *
 * The naive version of this produced 40 findings of which 5 were real, and every
 * false positive came from tokenising too eagerly:
 *
 *  - Splitting on `:` turned `md:static` into `md` and `static`, so every variant
 *    prefix looked like a missing class. Variants are stripped instead.
 *  - Splitting on `${}` pulled JS identifiers out of template literals, reporting
 *    `.dragOver` and `.sidebarOpen` as classes. Interpolations are removed whole.
 *  - Splitting on `()` pulled `--color-accent` out of `text-[var(--color-accent)]`,
 *    reporting a custom property as a class. Arbitrary values are skipped.
 */
function classesIn(src) {
  const out = new Set();

  /** Every className value, whether a plain string, a template, or an expression. */
  const spans = [];
  for (const m of src.matchAll(/className=(["'])([\s\S]*?)\1/g)) spans.push(m[2]);
  for (const m of src.matchAll(/className=\{([\s\S]*?)\}(?=[\s/>])/g)) {
    /*
     * Comparison operands are dropped before anything else.
     *
     * `className={`item${view === "today" ? " on" : ""}`}` contains two string
     * literals with completely different meanings: " on" is a class, and "today"
     * is a value being tested. Extracting both reported `.today` and `.user` as
     * undefined classes — the same shape of false positive as the `${}` and
     * variant-prefix cases below, and the reason those were fixed: a checker that
     * cries wolf about correct code stops being read.
     */
    const expr = m[1].replace(/[=!]==?\s*(["'])(?:(?!\1)[\s\S])*?\1/g, " ");
    // String branches of a ternary, and the static halves of a template.
    for (const q of expr.matchAll(/(["'])((?:(?!\1)[\s\S])*?)\1/g)) spans.push(q[2]);
    for (const t of expr.matchAll(/`((?:[^`\\]|\\[\s\S])*?)`/g)) {
      // Interpolations dropped entirely: what they evaluate to is not knowable
      // here, and their contents are code, not class names.
      spans.push(t[1].replace(/\$\{[^}]*\}/g, " "));
    }
  }

  for (const span of spans) {
    for (const raw of span.split(/\s+/)) {
      if (raw === "") continue;
      // Arbitrary values and modifiers compile to escaped selectors this check
      // cannot match literally, so they are out of scope rather than reported.
      if (/[[\]/!#$%^&*()<>?'"`{}]/.test(raw)) continue;
      /*
       * The token is kept WHOLE, variants included.
       *
       * Stripping `md:` and looking for the bare `.grid-cols-4` was wrong: a class
       * used only as `xl:grid-cols-4` compiles solely to `.xl\:grid-cols-4`, so the
       * bare form legitimately does not exist and the check reported four false
       * positives. Matching the escaped selector is the actual question being
       * asked — "did Tailwind emit a rule for what this file wrote".
       */
      if (!/^[a-z][a-z0-9-]*(:[a-z][a-z0-9-]*)*$/.test(raw)) continue;
      out.add(raw);
    }
  }
  return out;
}

/** Every `var(--x)` a file reads. */
function varsIn(src) {
  const out = new Set();
  for (const m of src.matchAll(/var\((--[a-z0-9-]+)/g)) out.add(m[1]);
  return out;
}

/**
 * Is `.cls` a real selector in the compiled sheet?
 *
 * Checked at a boundary rather than by looking for `.cls{`: minified CSS follows
 * a selector with any of `{ , : . >` or whitespace, and assuming a brace is what
 * made an earlier version report `.card` and `.field` as missing when both were
 * plainly present.
 */
function definedClass(css, cls) {
  // Tailwind escapes the variant colon, so `xl:grid-cols-4` is written
  // `.xl\:grid-cols-4` in the output.
  const selector = `.${cls.replace(/:/g, "\\:")}`;
  let at = css.indexOf(selector);
  while (at >= 0) {
    const next = css[at + selector.length];
    // `)` is included for Tailwind v4's marker classes: `group` only ever appears
    // inside `:is(:where(.group):hover *)`, never as a rule of its own.
    if (next === undefined || "{,:. \n\t>+~)".includes(next)) return true;
    at = css.indexOf(selector, at + 1);
  }
  return false;
}

const sheets = findCss(WEB);
if (sheets.length === 0) {
  console.error(`No compiled CSS under ${WEB}/.next/static/css — run a build or load a page first.`);
  exit(2);
}
const css = sheets.map((p) => readFileSync(p, "utf8")).join("\n");
console.log(`stylesheets: ${sheets.length} (${css.length} bytes)`);

const files = [...walk(join(WEB, "app")), ...walk(join(WEB, "components"))];
console.log(`components:  ${files.length}`);

const badClasses = new Map();
const badVars = new Map();

for (const file of files) {
  const src = readFileSync(file, "utf8");
  const short = file.replace(`${WEB}/`, "");

  for (const cls of classesIn(src)) {
    if (definedClass(css, cls)) continue;
    if (!badClasses.has(cls)) badClasses.set(cls, new Set());
    badClasses.get(cls).add(short);
  }
  for (const v of varsIn(src)) {
    if (css.includes(`${v}:`)) continue;
    if (!badVars.has(v)) badVars.set(v, new Set());
    badVars.get(v).add(short);
  }
}

let problems = 0;

if (badVars.size > 0) {
  problems += badVars.size;
  console.log(`\nUNDEFINED custom properties (${badVars.size}) — these void the whole declaration:`);
  for (const [v, where] of [...badVars].sort()) {
    console.log(`  var(${v})`);
    for (const f of [...where].sort()) console.log(`      ${f}`);
  }
}

if (badClasses.size > 0) {
  problems += badClasses.size;
  console.log(`\nCLASSES with no rule (${badClasses.size}) — these style nothing, silently:`);
  for (const [cls, where] of [...badClasses].sort()) {
    console.log(`  .${cls}`);
    for (const f of [...where].sort()) console.log(`      ${f}`);
  }
}

console.log(
  problems === 0
    ? "\nOK — every class and custom property in use is defined."
    : `\n${problems} undefined name(s).`,
);
exit(problems === 0 ? 0 : 1);
