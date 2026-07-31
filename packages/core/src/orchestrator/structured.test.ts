import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import { extractJson, repairPrompt, tryParse } from "./structured.ts";
import { PlanSchema, ReviewSchema } from "../types.ts";
import { zodToJsonSchema } from "../util/jsonschema.ts";

/**
 * Boundary tests for the text→object boundary.
 *
 * These CLIs emit prose, not objects. Everything the pipeline does downstream —
 * decomposition, review findings, verdicts — arrives through this parser, so a
 * gap here does not degrade gracefully: it fails every structured phase and the
 * run dies at planning.
 */

// ── extractJson: the shapes agents actually produce ─────────

test("extract: a bare object", () => {
  assert.equal(extractJson('{"a":1}'), '{"a":1}');
});

test("extract: a fenced block, with and without the language tag", () => {
  assert.equal(extractJson('```json\n{"a":1}\n```'), '{"a":1}');
  assert.equal(extractJson('```\n{"a":1}\n```'), '{"a":1}');
});

test("extract: prose wrapped around the object", () => {
  // The single most common real shape — an agent explaining itself first.
  const text = 'Here is the plan you asked for:\n\n{"summary":"x","subtasks":[]}\n\nLet me know if you want changes.';
  assert.equal(extractJson(text), '{"summary":"x","subtasks":[]}');
});

test("extract: a fenced block with trailing commentary", () => {
  const text = 'Sure.\n\n```json\n{"a":1}\n```\n\nThat covers it.';
  assert.equal(extractJson(text), '{"a":1}');
});

test("extract: nested braces are balanced correctly", () => {
  const json = '{"a":{"b":{"c":[1,2,{"d":3}]}}}';
  assert.equal(extractJson(`prefix ${json} suffix`), json);
});

test("extract: a brace inside a string does not end the scan", () => {
  // Naive depth counting truncates here and yields invalid JSON.
  const json = '{"claim":"the } character breaks parsers","ok":true}';
  assert.equal(extractJson(json), json);
  const parsed: unknown = JSON.parse(extractJson(json) ?? "null");
  assert.deepEqual(parsed, { claim: "the } character breaks parsers", ok: true });
});

test("extract: an escaped quote does not end the string", () => {
  const json = '{"msg":"he said \\"stop\\" then }","n":1}';
  const got = extractJson(json);
  assert.equal(got, json);
  assert.deepEqual(JSON.parse(got ?? "null"), { msg: 'he said "stop" then }', n: 1 });
});

test("extract: an escaped backslash before a quote is handled", () => {
  // "path\\" — the backslash is escaped, so the following quote DOES close.
  const json = '{"path":"C:\\\\temp\\\\","n":2}';
  const got = extractJson(json);
  assert.ok(got !== null);
  assert.deepEqual(JSON.parse(got), { path: "C:\\temp\\", n: 2 });
});

test("extract: a diff containing braces inside a JSON string survives", () => {
  // Review findings routinely carry code snippets in their `patch` field.
  const patch = "if (x) {\\n  return { a: 1 };\\n}";
  const json = `{"severity":"major","patch":"${patch}"}`;
  const got = extractJson(json);
  assert.ok(got !== null);
  const parsed = JSON.parse(got) as { patch: string };
  assert.ok(parsed.patch.includes("return { a: 1 };"));
});

test("extract: an array at top level", () => {
  assert.equal(extractJson("[1,2,3]"), "[1,2,3]");
  assert.equal(extractJson('text [{"a":1}] more'), '[{"a":1}]');
});

test("extract: returns null rather than guessing", () => {
  for (const text of ["", "   ", "no json here", "just prose about {braces} in words"]) {
    const got = extractJson(text);
    // The last case does extract "{braces}"; assert only that we never throw and
    // that genuinely empty input yields null.
    if (text.trim().length === 0 || !text.includes("{")) assert.equal(got, null, JSON.stringify(text));
  }
});

test("extract: unbalanced braces yield null instead of a truncated object", () => {
  // A killed process leaves half a line. Returning a prefix would parse as
  // valid-looking nonsense.
  assert.equal(extractJson('{"a":1'), null);
  assert.equal(extractJson('{"a":{"b":2'), null);
});

test("extract: picks the first complete object when several appear", () => {
  const got = extractJson('{"first":1} and {"second":2}');
  assert.equal(got, '{"first":1}');
});

test("extract: a fenced block that is not JSON falls through to the scan", () => {
  // Agents sometimes fence a shell command and put the object after it.
  const text = '```sh\nnpm test\n```\n\n{"outcome":"confirmed","evidence":"ok"}';
  const got = extractJson(text);
  assert.ok(got !== null);
  assert.deepEqual(JSON.parse(got), { outcome: "confirmed", evidence: "ok" });
});

// ── tryParse: schema enforcement ────────────────────────────

test("tryParse: applies defaults from the schema", () => {
  const res = tryParse(ReviewSchema, '{"overall":"approve"}');
  assert.equal(res.ok, true);
  // `findings` has .default([]) — at runtime it is present even though the
  // agent omitted it. This is exactly why the schema type is pinned to zod's
  // OUTPUT side rather than its input side.
  assert.deepEqual(res.value?.findings, []);
});

test("tryParse: reports the failing path, not just 'invalid'", () => {
  const res = tryParse(PlanSchema, '{"summary":"x","subtasks":[{"title":"t"}]}');
  assert.equal(res.ok, false);
  assert.ok(res.error !== null);
  // The repair turn feeds this back verbatim, so it has to name the field.
  assert.match(res.error, /subtasks/);
});

test("tryParse: an empty subtasks array is rejected", () => {
  // A plan with no work is not a plan; accepting it would produce a silent no-op run.
  const res = tryParse(PlanSchema, '{"summary":"nothing to do","subtasks":[]}');
  assert.equal(res.ok, false);
});

/** Builds a minimal valid subtask, for the plan-shape tests below. */
function planSubtask(id: string, stage = 0, dependsOn: string[] = []): Record<string, unknown> {
  return { id, title: `t-${id}`, brief: "b", acceptance: "a", capability: "general", stage, dependsOn };
}

const plan = (subtasks: Array<Record<string, unknown>>): string =>
  JSON.stringify({ summary: "s", subtasks });

test("tryParse: duplicate subtask ids are rejected, and the message names them", () => {
  const res = tryParse(PlanSchema, plan([planSubtask("a"), planSubtask("a"), planSubtask("b")]));
  /*
   * Duplicates do not crash anything, which is why they need catching: each
   * subtask gets its own row regardless, so `dependsOn: ["a"]` silently becomes an
   * ambiguous reference and the intended ordering is unknowable. At roughly six
   * agent turns per subtask, executing a plan the model did not think through is
   * expensive.
   */
  assert.equal(res.ok, false);
  /*
   * The id itself must appear. A first attempt at this used
   * `filter(id => !seen.add(id))`, but `Set.add()` returns the SET — always truthy
   * — so nothing matched and the message read "repeated: " with no ids at all.
   * That message is exactly what the repair prompt feeds back, so an empty list
   * asks the model to guess what was wrong.
   */
  assert.match(res.error ?? "", /repeated: a/);
});

test("tryParse: several duplicate ids are all listed", () => {
  const res = tryParse(
    PlanSchema,
    plan([planSubtask("a"), planSubtask("a"), planSubtask("b"), planSubtask("b"), planSubtask("c")]),
  );
  assert.equal(res.ok, false);
  assert.match(res.error ?? "", /repeated: a, b/);
});

test("tryParse: unique ids pass", () => {
  const res = tryParse(PlanSchema, plan([planSubtask("a"), planSubtask("b"), planSubtask("c")]));
  // A bug in the uniqueness check would reject every plan, which is worse than the
  // problem it solves.
  assert.equal(res.ok, true);
  assert.equal(res.value?.subtasks.length, 3);
});

test("tryParse: the plan size cap holds at 12", () => {
  /*
   * One subtask costs a draft plus two reviews, and often a reproduction, a
   * rebuttal and an adjudication — roughly six agent turns. Fifty subtasks is ~300
   * turns: the budget ceiling would stop it, but only after spending everything,
   * and the plan gate would ask a human to review a fifty-item list.
   */
  const twelve = Array.from({ length: 12 }, (_, i) => planSubtask(`s${i}`));
  assert.equal(tryParse(PlanSchema, plan(twelve)).ok, true, "twelve is allowed");

  const thirteen = Array.from({ length: 13 }, (_, i) => planSubtask(`s${i}`));
  assert.equal(tryParse(PlanSchema, plan(thirteen)).ok, false, "thirteen is refused");
});

test("tryParse: a negative stage is rejected", () => {
  // Stages index the execution order; a negative one would sort ahead of the first
  // stage and silently reorder the plan.
  assert.equal(tryParse(PlanSchema, plan([planSubtask("a", -1)])).ok, false);
});

test("tryParse: a valid plan round-trips with dependsOn defaulted", () => {
  const res = tryParse(
    PlanSchema,
    JSON.stringify({
      summary: "s",
      subtasks: [{ id: "a", title: "t", brief: "b", acceptance: "acc", capability: "general", stage: 0 }],
    }),
  );
  assert.equal(res.ok, true);
  assert.deepEqual(res.value?.subtasks[0]?.dependsOn, []);
});

test("tryParse: rejects a non-object top level", () => {
  assert.equal(tryParse(PlanSchema, "[1,2,3]").ok, false);
  assert.equal(tryParse(PlanSchema, "no json").ok, false);
});

test("tryParse: malformed JSON is reported as a parse failure", () => {
  const res = tryParse(PlanSchema, '{"summary":"x",}');
  assert.equal(res.ok, false);
  assert.match(res.error ?? "", /JSON parse failed/);
});

test("tryParse: the verifiable flag must be present on a finding", () => {
  // Without it the pipeline cannot route the dispute, so it is deliberately
  // required rather than defaulted — a wrong default would silently send every
  // judgment call down the reproduction path.
  const res = tryParse(
    ReviewSchema,
    '{"overall":"request_changes","findings":[{"severity":"blocker","claim":"c"}]}',
  );
  assert.equal(res.ok, false);
  assert.match(res.error ?? "", /verifiable/);
});

test("tryParse: an oversized finding is truncated, not rejected", () => {
  const huge = "x".repeat(20_000);
  const res = tryParse(
    ReviewSchema,
    JSON.stringify({
      overall: "request_changes",
      findings: [
        {
          severity: "major",
          claim: "c",
          evidence: huge,
          verifiable: false,
          suggestedTest: null,
          patch: huge,
        },
      ],
    }),
  );

  /*
   * Truncation rather than rejection is the deliberate choice.
   *
   * A hard `.max()` would fail the whole review and burn a retry, discarding real
   * findings over their length — and a finding's substance is almost always at the
   * start. Leaving it unbounded was not an option either: these strings flow
   * verbatim into the rework prompt, so one enormous patch failed the NEXT turn as
   * a provider rejection, which reads like an adapter bug.
   */
  assert.equal(res.ok, true);
  const finding = res.value?.findings[0];
  assert.ok(finding);
  assert.ok(finding.evidence.length < 9_000, `evidence was ${finding.evidence.length} chars`);
  assert.ok((finding.patch?.length ?? 0) < 13_000);
  // Marked, so a reader can tell truncation from an agent that stopped mid-sentence.
  assert.match(finding.evidence, /truncated/);
  assert.match(finding.patch ?? "", /truncated/);
});

test("tryParse: an absurd number of findings is rejected", () => {
  // Each blocking finding costs a rebuttal entry, possibly a reproduction turn, and
  // a line in the rework brief. Hundreds means the reviewer stopped reviewing and
  // started listing.
  const one = {
    severity: "nit",
    claim: "c",
    evidence: "",
    verifiable: false,
    suggestedTest: null,
    patch: null,
  };
  const res = tryParse(
    ReviewSchema,
    JSON.stringify({ overall: "request_changes", findings: Array.from({ length: 41 }, () => one) }),
  );
  assert.equal(res.ok, false);
  assert.equal(
    tryParse(
      ReviewSchema,
      JSON.stringify({ overall: "request_changes", findings: Array.from({ length: 40 }, () => one) }),
    ).ok,
    true,
    "exactly 40 is allowed",
  );
});

test("tryParse: a well-formed finding keeps its nullable fields", () => {
  const res = tryParse(
    ReviewSchema,
    JSON.stringify({
      overall: "request_changes",
      findings: [
        { severity: "blocker", claim: "races", evidence: "x.ts:12", verifiable: true, suggestedTest: "node --test", patch: null },
      ],
    }),
  );
  assert.equal(res.ok, true);
  const f = res.value?.findings[0];
  assert.equal(f?.verifiable, true);
  assert.equal(f?.suggestedTest, "node --test");
  assert.equal(f?.patch, null);
});

test("tryParse: extra unknown keys are tolerated", () => {
  // Agents add commentary fields. Rejecting on those would fail useful output.
  const res = tryParse(ReviewSchema, '{"overall":"approve","confidence":0.9,"note":"looks fine"}');
  assert.equal(res.ok, true);
});

// ── repairPrompt ────────────────────────────────────────────

test("repair: carries the error, the bad output, and the original ask", () => {
  const prompt = repairPrompt("ORIGINAL_ASK", "schema mismatch: subtasks: required", "BAD_OUTPUT");
  assert.match(prompt, /schema mismatch: subtasks: required/);
  assert.match(prompt, /BAD_OUTPUT/);
  assert.match(prompt, /ORIGINAL_ASK/);
});

test("repair: truncates a huge previous response", () => {
  const prompt = repairPrompt("ask", "err", "x".repeat(10_000));
  // A retry that re-sends 10k of garbage wastes the budget it is trying to save.
  assert.ok(prompt.length < 6000, `repair prompt was ${prompt.length} chars`);
});

// ── zodToJsonSchema (feeds codex --output-schema) ───────────

test("jsonschema: emits an object schema with required fields", () => {
  const schema = zodToJsonSchema(PlanSchema) as {
    type: string;
    required?: string[];
    properties: Record<string, unknown>;
  };
  assert.equal(schema.type, "object");
  assert.ok(schema.required?.includes("summary"));
  assert.ok(schema.required?.includes("subtasks"));
});

test("jsonschema: a .default() field IS required, because strict mode demands it", () => {
  /*
   * This test used to assert the opposite, reasoning that "`findings` is
   * defaulted, so demanding it would make codex reject its own otherwise-valid
   * output". Plausible, and empirically wrong: what gets rejected is the REQUEST,
   * not the model's answer. OpenAI's structured output runs strict and returns
   * HTTP 400 when `required` omits any key in `properties`:
   *
   *   invalid_json_schema: 'required' ... an array including every key in
   *   properties. Missing 'evidence'.
   *
   * The attempt history settles it: codex went 0/10 on `review` (three defaulted
   * fields) and 11/11 on `repro` (every field mandatory). Since codex is seeded as
   * the reviewer, cross-vendor review had been running a vendor short for the
   * project's whole life, logged only as `review:errored`.
   *
   * Safe because a field the model may have no answer for is emitted as nullable,
   * so it writes `null` rather than omitting the key — and the zod `.default()`
   * still covers the other runtimes, which receive no schema at all.
   */
  const schema = zodToJsonSchema(ReviewSchema) as { required?: string[] };
  assert.ok((schema.required ?? []).includes("findings"), "a defaulted key must still be required");
  assert.ok((schema.required ?? []).includes("overall"));
});

test("jsonschema: enums become string enums", () => {
  const schema = zodToJsonSchema(ReviewSchema) as {
    properties: { overall?: { type?: string; enum?: string[] } };
  };
  assert.equal(schema.properties.overall?.type, "string");
  assert.deepEqual(schema.properties.overall?.enum, ["approve", "request_changes"]);
});

test("jsonschema: nullable becomes a type union with null", () => {
  const s = zodToJsonSchema(z.object({ a: z.string().nullable() })) as {
    properties: { a?: { type?: unknown } };
  };
  assert.deepEqual(s.properties.a?.type, ["string", "null"]);
});

test("jsonschema: integer checks are preserved", () => {
  const s = zodToJsonSchema(z.object({ n: z.number().int(), f: z.number() })) as {
    properties: { n?: { type?: string }; f?: { type?: string } };
  };
  assert.equal(s.properties.n?.type, "integer");
  assert.equal(s.properties.f?.type, "number");
});

test("jsonschema: a .transform() field keeps its wire type", () => {
  /*
   * Regression guard for a bug that typecheck cannot see.
   *
   * `.transform()` wraps a schema in ZodEffects. The converter did not know that
   * construct, so it fell into the permissive default and emitted `{}` — telling
   * codex "anything goes" for `claim`, `evidence`, `suggestedTest` and `patch`,
   * where "must be a string" was intended. The degradation is type-safe and
   * silent; it only surfaces as a wasted retry when the model returns the wrong
   * shape and zod rejects it downstream.
   */
  const s = zodToJsonSchema(ReviewSchema) as {
    properties: {
      findings?: {
        maxItems?: number;
        items?: { properties?: Record<string, { type?: unknown }> };
      };
    };
  };
  const fields = s.properties.findings?.items?.properties ?? {};

  assert.equal(fields["claim"]?.type, "string");
  assert.equal(fields["evidence"]?.type, "string");
  // Nullable + transformed: a union with null, not an empty object.
  assert.deepEqual(fields["suggestedTest"]?.type, ["string", "null"]);
  assert.deepEqual(fields["patch"]?.type, ["string", "null"]);

  for (const [name, spec] of Object.entries(fields)) {
    assert.notDeepEqual(spec, {}, `${name} degraded to an empty schema`);
  }
});

test("jsonschema: array length bounds are declared, not just enforced", () => {
  // Otherwise the native schema says any size is fine while the parser refuses
  // anything over the cap — the model has to discover the rule by being rejected.
  const review = zodToJsonSchema(ReviewSchema) as {
    properties: { findings?: { maxItems?: number } };
  };
  assert.equal(review.properties.findings?.maxItems, 40);

  const plan = zodToJsonSchema(PlanSchema) as {
    properties: { subtasks?: { minItems?: number; maxItems?: number } };
  };
  assert.equal(plan.properties.subtasks?.minItems, 1);
  assert.equal(plan.properties.subtasks?.maxItems, 12);
});

test("jsonschema: an unknown construct degrades instead of throwing", () => {
  // Better to emit a permissive schema and reparse the text than to crash a run.
  assert.doesNotThrow(() => zodToJsonSchema(z.object({ d: z.date(), m: z.map(z.string(), z.string()) })));
});

test("jsonschema: deep nesting terminates", () => {
  let schema: z.ZodTypeAny = z.object({ leaf: z.string() });
  for (let i = 0; i < 40; i++) schema = z.object({ next: schema });
  assert.doesNotThrow(() => zodToJsonSchema(schema));
});
