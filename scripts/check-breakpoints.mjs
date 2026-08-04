#!/usr/bin/env node
/**
 * Verifies that the responsive rules the three-pane layout depends on are compiled.
 *
 * Exists because the layout cannot be checked visually here: the automation
 * browser is a WKWebView locked at 755px, and `browser.viewport.set` is
 * unsupported on it. Three attempts to work around that were all invalid, and
 * worth keeping on record so they are not repeated:
 *
 *   1. `body.style.zoom = 0.5` — does not change `innerWidth` and does not
 *      re-evaluate media queries.
 *   2. Shrinking the root font size so a rem-based query resolves smaller — by
 *      spec, `rem` inside a media query is fixed to the INITIAL root size,
 *      otherwise the query would depend on its own result.
 *   3. Grepping for the authored text — the minifier rewrites it, so a search for
 *      `(max-width: 1050px)` with its space can never match.
 *
 * Rewritten twice, and the reason is the same both times. It first required
 * `md:static` and `xl:grid-cols-4` from the icon-rail shell deleted in M2; then
 * `.side{width:68px` and `.item .n.hot` from the flex three-pane layout replaced
 * in M7. Neither set became WRONG when the layout changed — they became
 * assertions about nothing, which is worse: a passing check on a layout that no
 * longer exists reads as coverage.
 *
 * The M7 shell is a CSS grid, so what collapses at each breakpoint is the COLUMN
 * TRACK, not a width on the panel. `.chat{display:none}` alone would leave a
 * 336px empty gutter, which is why both halves are asserted.
 *
 *   1050px  the secretary column's track is dropped and the panel hidden
 *    720px  the sidebar track narrows to 68px; labels, calendar and the new-list
 *           form go; per-row repo and status tags go
 *
 * Every needle is a LITERAL substring of the MINIFIED output, which is why they
 * carry no spaces after colons. Building regexes for this through a shell into
 * `node -e` is how attempt 3 went wrong twice. Needles are also selector-anchored
 * rather than full declarations wherever the minifier is free to reorder
 * properties: `.side{width:244px` matches nothing in practice, because it emits
 * that rule's properties in its own order.
 *
 *   node scripts/check-breakpoints.mjs <stylesheet.css>
 */

import { readFileSync } from "node:fs";
import { argv, exit } from "node:process";

const cssPath = argv[2];
if (cssPath === undefined) {
  console.error("usage: check-breakpoints.mjs <stylesheet.css>");
  exit(2);
}

const css = readFileSync(cssPath, "utf8");

/**
 * The `[start, end)` character range of a media block's body.
 *
 * Brace-walked rather than assumed, so "is this rule inside that block" is a real
 * containment test. The previous version only checked that the rule appeared
 * after the query STARTED, which a rule in any later block also satisfies — so a
 * declaration that drifted from the 1050px block into the 720px one would have
 * passed while changing when it applies.
 */
function blockRange(source, query) {
  const at = source.indexOf(query);
  if (at === -1) return null;
  const open = source.indexOf("{", at);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return [open + 1, i];
  }
  return null;
}

const BREAKPOINTS = [
  "@media (max-width:1050px)",
  "@media (max-width:720px)",
  // Not a width, but the same class of rule and the same invisibility here: a
  // pulsing status dot, a lifting quick-add row and a sliding toast are exactly
  // the motion this has to switch off.
  "@media (prefers-reduced-motion:reduce)",
];

/** Each declaration, and the block it has to sit inside to mean anything. */
const RULES = [
  {
    decl: ".chat{display:none}",
    inside: "@media (max-width:1050px)",
    what: "chat pane hidden",
  },
  {
    // Both halves of hiding the secretary: the panel AND its grid track. Without
    // the track, `display:none` leaves a 336px empty gutter.
    decl: ".shell{grid-template-columns:216px",
    inside: "@media (max-width:1050px)",
    what: "secretary column's track dropped",
  },
  {
    decl: ".shell{grid-template-columns:68px",
    inside: "@media (max-width:720px)",
    what: "sidebar track narrowed to icons",
  },
  {
    decl: ".main-in{padding:32px",
    inside: "@media (max-width:720px)",
    what: "task pane padding tightened",
  },
  {
    decl: ".repo,.st{display:none}",
    inside: "@media (max-width:720px)",
    what: "per-row repo and status tags dropped",
  },
  {
    /*
     * The needs-you dot survives, repositioned. It is the one signal that still
     * has to be visible once there is no label for it to sit beside.
     *
     * Anchored on the selector alone: the minifier reorders this rule's properties
     * (`margin:0;position:absolute;top:5px;right:12px`), so a needle carrying any
     * declaration would match by luck rather than by contract.
     */
    decl: ".srow .dot-badge{",
    inside: "@media (max-width:720px)",
    what: "needs-you dot repositioned, not dropped",
  },
  {
    // The calendar and the new-list form have no icon to fall back on: a month
    // grid at 68px is unreadable and the form is two text fields.
    decl: ".cal,.nlform{display:none}",
    inside: "@media (max-width:720px)",
    what: "calendar and new-list form dropped",
  },
  {
    decl: "animation-duration:.01ms",
    inside: "@media (prefers-reduced-motion:reduce)",
    what: "animation suppressed",
  },
];

/**
 * The base rules the narrow overrides have to beat.
 *
 * Same specificity, so source order decides. A base `.chat` rule emitted AFTER
 * `.chat{display:none}` would silently restore the panel at every width — the
 * failure this pair exists to catch.
 *
 * `base` is a bare selector, matched at its FIRST occurrence. If the base rule
 * were missing entirely the match would land on the override itself, the two
 * indices would be equal, and the check fails — which is the right verdict.
 */
const OVERRIDES = [
  { base: ".chat{", override: ".chat{display:none}", what: "secretary panel" },
  /*
   * The grid's own track definition, which every breakpoint overrides.
   *
   * The base `.shell{` is the three-column rule; the first match lands on it
   * because the media blocks are emitted last. If the base were missing the match
   * would land on an override, the indices would compare equal, and the check
   * fails — which is the right verdict.
   */
  {
    base: ".shell{",
    override: ".shell{grid-template-columns:68px",
    what: "sidebar track width",
  },
];

let bad = 0;

console.log(`stylesheet: ${cssPath} (${css.length} bytes)\n`);

console.log("breakpoint blocks:");
for (const bp of BREAKPOINTS) {
  const present = css.includes(bp);
  if (!present) bad++;
  console.log(`  ${present ? "ok " : "MISSING"}  ${bp}`);
}

console.log("\nrules, and the block each must sit inside:");
for (const { decl, inside, what } of RULES) {
  const range = blockRange(css, inside);
  if (range === null) {
    bad++;
    console.log(`  NOBLOCK  ${inside} is absent, so ${decl} cannot be inside it`);
    continue;
  }

  /*
   * Searched from the block's start, not from the start of the sheet.
   *
   * Several of these selectors legitimately appear TWICE — `.item .n.hot` is the
   * blue pill at full width and a bare 7px dot at 720px, `.chat` is a 360px pane
   * and then `display:none`. A global search finds the base rule first and then
   * reports it as sitting outside the media block, which is a false positive
   * about correct CSS. The question being asked is "does this block contain this
   * rule", so the search is scoped to the block.
   */
  const at = css.indexOf(decl, range[0]);
  if (at !== -1 && at < range[1]) {
    console.log(`  ok       ${decl}   (${what})`);
    continue;
  }

  bad++;
  // Present somewhere but not here means it drifted between blocks, which is a
  // different bug from never having been emitted — and a different fix.
  console.log(
    css.includes(decl)
      ? `  OUTSIDE  ${decl}   exists but not inside ${inside} — applies at the wrong widths`
      : `  MISSING  ${decl}   (${what})`,
  );
}

console.log("\nsource order — the narrow rule must come last to win:");
for (const { base, override, what } of OVERRIDES) {
  const baseAt = css.indexOf(base);
  const overrideAt = css.indexOf(override);
  if (baseAt === -1 || overrideAt === -1) {
    bad++;
    console.log(`  MISSING  ${what} — one of the two rules is absent`);
    continue;
  }
  const ok = overrideAt > baseAt;
  if (!ok) bad++;
  console.log(
    `  ${ok ? "ok " : "SUSPECT"}      ${what}: base at ${baseAt}, override at ${overrideAt}`,
  );
}

console.log(
  bad === 0
    ? "\nOK — every responsive rule the layout needs is compiled and correctly placed."
    : `\n${bad} problem(s).`,
);
exit(bad === 0 ? 0 : 1);
