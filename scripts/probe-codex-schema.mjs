#!/usr/bin/env node
/**
 * Measures how badly the codex JSON-schema rejection actually bites.
 *
 * Written to a file rather than passed to `node -e` because the query needs
 * single-quoted SQL string literals inside a shell command that is itself
 * single-quoted — the exact nested-escaping hazard that has bitten several times
 * this session. Here there are no string literals in the SQL at all: everything
 * is grouped and filtered in JS.
 *
 * The claim under test: "every codex structured turn is rejected". That was
 * asserted before being checked, and it is probably too strong — the schema is
 * only sent to codex, and OpenAI's strict mode only objects when `required` omits
 * a key that `properties` declares. A schema whose every field is mandatory would
 * pass fine.
 */

import { DatabaseSync } from "node:sqlite";
import { defaultDbPath } from "../packages/core/src/db/index.ts";
import {
  AdjudicationSchema,
  PlanSchema,
  RebuttalSchema,
  ReproSchema,
  ReviewSchema,
} from "../packages/core/src/types.ts";
import { zodToJsonSchema } from "../packages/core/src/util/jsonschema.ts";

const STRUCTURED = new Set(["plan", "review", "rebuttal", "adjudicate", "repro"]);

// ── 1. What the converter emits ─────────────────────────────

/** Walks a JSON schema, reporting objects whose `required` misses a property. */
function offendingPaths(node, path = "$", out = []) {
  if (node === null || typeof node !== "object") return out;

  if (node.type === "object" && node.properties !== undefined) {
    const keys = Object.keys(node.properties);
    const required = Array.isArray(node.required) ? node.required : [];
    const missing = keys.filter((k) => !required.includes(k));
    if (missing.length > 0) out.push({ path, missing });
    for (const [key, value] of Object.entries(node.properties)) {
      offendingPaths(value, `${path}.${key}`, out);
    }
  }
  if (node.items !== undefined) offendingPaths(node.items, `${path}[]`, out);
  return out;
}

const SCHEMAS = {
  plan: PlanSchema,
  review: ReviewSchema,
  rebuttal: RebuttalSchema,
  adjudicate: AdjudicationSchema,
  repro: ReproSchema,
};

console.log("Which schemas violate OpenAI strict mode (required must list every property)?\n");
const broken = [];
for (const [kind, schema] of Object.entries(SCHEMAS)) {
  const offenders = offendingPaths(zodToJsonSchema(schema));
  if (offenders.length === 0) {
    console.log(`  ok      ${kind}`);
    continue;
  }
  broken.push(kind);
  console.log(`  REJECT  ${kind}`);
  for (const o of offenders) console.log(`            ${o.path} missing: ${o.missing.join(", ")}`);
}

// ── 2. What actually happened, historically ─────────────────

console.log("\nAttempt history from the real database:\n");
const db = new DatabaseSync(defaultDbPath());
// No SQL string literals: group everything, filter in JS.
const rows = db
  .prepare("SELECT runtime_kind, kind, status, COUNT(*) c FROM attempt GROUP BY runtime_kind, kind, status")
  .all();
db.close();

const structured = rows.filter((r) => STRUCTURED.has(String(r.kind)));
const byRuntime = new Map();
for (const r of structured) {
  const key = String(r.runtime_kind);
  if (!byRuntime.has(key)) byRuntime.set(key, { completed: 0, failed: 0, kinds: new Map() });
  const entry = byRuntime.get(key);
  const n = Number(r.c);
  if (String(r.status) === "completed") entry.completed += n;
  else entry.failed += n;

  const kindKey = String(r.kind);
  if (!entry.kinds.has(kindKey)) entry.kinds.set(kindKey, { completed: 0, failed: 0 });
  const k = entry.kinds.get(kindKey);
  if (String(r.status) === "completed") k.completed += n;
  else k.failed += n;
}

for (const [runtime, entry] of [...byRuntime].sort()) {
  console.log(`  ${runtime}: ${entry.completed} completed, ${entry.failed} failed`);
  for (const [kind, k] of [...entry.kinds].sort()) {
    const flag = broken.includes(kind) ? "  <- schema rejected by strict mode" : "";
    console.log(`      ${kind.padEnd(11)} ${k.completed} ok / ${k.failed} failed${flag}`);
  }
}

const codex = byRuntime.get("codex");
console.log("");
if (codex === undefined) {
  console.log("VERDICT: codex has never run a structured turn — nothing to conclude from history.");
} else if (codex.completed === 0) {
  console.log(`VERDICT: codex has NEVER completed a structured turn (${codex.failed} failures).`);
} else {
  console.log(
    `VERDICT: codex HAS completed ${codex.completed} structured turn(s), so "every codex`,
  );
  console.log('         structured turn fails" is too strong — it depends on the schema.');
}
