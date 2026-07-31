#!/usr/bin/env node
/**
 * Verifies that the responsive rules the desktop layout depends on are compiled.
 *
 * Exists because the layout cannot be checked visually here: the automation
 * browser is a WKWebView locked at 755px, below the 768px `md` breakpoint, and
 * `browser.viewport.set` is unsupported on it. Three attempts to work around that
 * were all invalid, and worth recording so they are not repeated:
 *
 *   1. `body.style.zoom = 0.5` — does not change `innerWidth` and does not
 *      re-evaluate media queries.
 *   2. Shrinking the root font size so `48rem` resolves smaller — by spec, `rem`
 *      inside a media query is fixed to the INITIAL root size, otherwise the
 *      query would depend on its own result. It also visibly broke the layout,
 *      since every rem-based dimension halved.
 *   3. Grepping the stylesheet for `@media (min-width: 48rem)` — Tailwind v4
 *      emits the range syntax `@media (width >= 48rem)`, so the search could
 *      never match.
 *
 * Class names are matched as LITERAL substrings rather than by regex. Building a
 * pattern for `.md\:static` through a shell into `node -e` is how attempt 3 went
 * wrong twice: the escaping collapsed and every lookup returned "NOT FOUND" on a
 * stylesheet that plainly contained the rules.
 */

import { readFileSync } from "node:fs";
import { argv, exit } from "node:process";

const cssPath = argv[2];
if (cssPath === undefined) {
  console.error("usage: check-breakpoints.mjs <stylesheet.css>");
  exit(2);
}

const css = readFileSync(cssPath, "utf8");

/** Tailwind escapes the variant colon, so `md:static` is written `md\:static`. */
const REQUIRED = [
  // The sidebar: absolutely positioned and slid off-screen on a narrow viewport,
  // static and visible from `md` up. All three are needed — without `md:static`
  // it stays overlaid, without `md:translate-x-0` it stays slid away.
  String.raw`md\:static`,
  String.raw`md\:left-auto`,
  String.raw`md\:translate-x-0`,
  // The mobile-only controls (hamburger, scrim) disappear at `md`.
  String.raw`md\:hidden`,
  // The board's four columns: 1 → 2 → 4 as width allows.
  String.raw`md\:grid-cols-2`,
  String.raw`xl\:grid-cols-4`,
];

/** The breakpoint blocks themselves, in the syntax Tailwind v4 actually emits. */
const BREAKPOINTS = ["(width >= 48rem)", "(width >= 80rem)"];

let bad = 0;

console.log(`stylesheet: ${cssPath} (${css.length} bytes)\n`);

console.log("breakpoint blocks:");
for (const bp of BREAKPOINTS) {
  const present = css.includes(bp);
  if (!present) bad++;
  console.log(`  ${present ? "ok " : "MISSING"}  @media ${bp}`);
}

console.log("\nresponsive utilities:");
for (const cls of REQUIRED) {
  const present = css.includes(cls);
  if (!present) bad++;
  console.log(`  ${present ? "ok " : "MISSING"}  .${cls}`);
}

/*
 * A rule can exist and still sit outside its media block, which would apply it at
 * every width. Checking that `md\:static` appears AFTER the 48rem block opens is a
 * cheap guard against that, given the block ordering Tailwind produces.
 */
const mdAt = css.indexOf("(width >= 48rem)");
const staticAt = css.indexOf(String.raw`md\:static`);
console.log("\nplacement:");
if (mdAt >= 0 && staticAt >= 0) {
  const inside = staticAt > mdAt;
  if (!inside) bad++;
  console.log(`  ${inside ? "ok " : "SUSPECT"}  md\\:static appears after the 48rem block opens`);
} else {
  console.log("  skipped — one of the two markers is absent");
}

console.log(bad === 0 ? "\nOK — every responsive rule the layout needs is compiled." : `\n${bad} problem(s).`);
exit(bad === 0 ? 0 : 1);
