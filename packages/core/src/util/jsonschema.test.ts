import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import {
  AdjudicationSchema,
  PlanSchema,
  RebuttalSchema,
  ReproSchema,
  ReviewSchema,
} from "../types.ts";
import { zodToJsonSchema } from "./jsonschema.ts";

/**
 * JSON-schema emission, checked against OpenAI's strict mode.
 *
 * This file exists because its absence hid the worst bug in the project. The
 * converter omitted optional and defaulted fields from `required` — correct
 * standard JSON Schema — but codex sends the schema to OpenAI's structured output,
 * which runs strict and rejects anything less with HTTP 400:
 *
 *   invalid_json_schema: 'required' is required to be supplied and to be an array
 *   including every key in properties. Missing 'evidence'.
 *
 * Measured from the real attempt history before the fix: codex completed 11/11
 * `repro` turns — the one schema whose fields are all mandatory — and 0/10
 * `review` turns. codex is seeded as reviewer/verifier, so cross-vendor review,
 * the premise of the whole system, had been running one vendor short for the
 * entire life of the project. Nothing failed loudly: `collectReviews` logged
 * `review:errored` and carried on, and the other runtimes get no schema at all so
 * they were unaffected.
 */

/** Every object node in an emitted schema, with the path that reaches it. */
function objectNodes(
  node: unknown,
  path = "$",
  out: Array<{ path: string; node: Record<string, unknown> }> = [],
): Array<{ path: string; node: Record<string, unknown> }> {
  if (node === null || typeof node !== "object") return out;
  const obj = node as Record<string, unknown>;

  if (obj["type"] === "object" && obj["properties"] !== undefined) {
    out.push({ path, node: obj });
    for (const [key, value] of Object.entries(obj["properties"] as Record<string, unknown>)) {
      objectNodes(value, `${path}.${key}`, out);
    }
  }
  if (obj["items"] !== undefined) objectNodes(obj["items"], `${path}[]`, out);
  return out;
}

const REAL_SCHEMAS: Array<[string, z.ZodTypeAny]> = [
  ["plan", PlanSchema],
  ["review", ReviewSchema],
  ["rebuttal", RebuttalSchema],
  ["adjudicate", AdjudicationSchema],
  ["repro", ReproSchema],
];

test("strict mode: every property of every real schema is required", () => {
  /*
   * The exact invariant OpenAI enforces, asserted on the schemas actually sent
   * rather than on a toy one. `review` is the case that failed in production:
   * `evidence`, `suggestedTest` and `patch` are defaulted, so all three were
   * missing from `required` and the whole request was rejected.
   */
  for (const [name, schema] of REAL_SCHEMAS) {
    for (const { path, node } of objectNodes(zodToJsonSchema(schema))) {
      const keys = Object.keys(node["properties"] as Record<string, unknown>);
      const required = Array.isArray(node["required"]) ? (node["required"] as string[]) : [];
      const missing = keys.filter((k) => !required.includes(k));
      assert.deepEqual(
        missing,
        [],
        `${name} at ${path}: properties not listed in required — strict mode rejects this`,
      );
    }
  }
});

test("strict mode: every object closes additionalProperties", () => {
  // The other half of strict mode. This half was already right, and its comment
  // showed the author knew about strict mode — only `required` was missed.
  for (const [name, schema] of REAL_SCHEMAS) {
    for (const { path, node } of objectNodes(zodToJsonSchema(schema))) {
      assert.equal(
        node["additionalProperties"],
        false,
        `${name} at ${path}: additionalProperties must be false`,
      );
    }
  }
});

test("strict mode: a nullable field can still be answered with null", () => {
  /*
   * Requiring every key is only acceptable because a field the model may not have
   * an answer for is nullable — it writes `null` rather than omitting the key. If
   * the emitted type were a bare "string", requiring it would force the model to
   * invent a value.
   */
  const emitted = zodToJsonSchema(ReviewSchema);
  const findings = (emitted["properties"] as Record<string, Record<string, unknown>>)["findings"];
  const item = findings?.["items"] as Record<string, Record<string, unknown>> | undefined;
  const props = item?.["properties"] as Record<string, Record<string, unknown>> | undefined;

  assert.ok(props, "findings items must emit properties");
  for (const field of ["suggestedTest", "patch"]) {
    const type = props?.[field]?.["type"];
    assert.ok(
      Array.isArray(type) && type.includes("null"),
      `${field} is required, so it must accept null; got ${JSON.stringify(type)}`,
    );
  }
});

test("defaults still apply when a runtime omits a field", () => {
  /*
   * The claim that made requiring everything safe, checked rather than asserted in
   * a comment: only codex receives a schema. Every other runtime is asked in prose
   * and parsed with zod, so it may legitimately omit a defaulted key — and the
   * `.default()` has to keep filling it in.
   */
  const parsed = ReviewSchema.parse({
    overall: "request_changes",
    findings: [{ severity: "nit", claim: "naming", verifiable: false }],
  });

  assert.equal(parsed.findings[0]?.evidence, "", "evidence must default to an empty string");
  assert.equal(parsed.findings[0]?.suggestedTest, null);
  assert.equal(parsed.findings[0]?.patch, null);

  // And an omitted array still arrives as an array rather than undefined.
  const empty = ReviewSchema.parse({ overall: "approve" });
  assert.deepEqual(empty.findings, []);
});

test("required is omitted entirely for an object with no properties", () => {
  // `required: []` is itself invalid in strict mode, so an empty object must not
  // emit the key at all.
  const emitted = zodToJsonSchema(z.object({}));
  assert.equal(emitted["type"], "object");
  assert.equal("required" in emitted, false, "an empty object must not emit `required: []`");
});

test("a defaulted field is required and keeps its inner type", () => {
  /*
   * Directly pins the regression. Before the fix `note` was absent from `required`
   * because it is a ZodDefault; the emitted type must still describe the inner
   * value so the model knows what to produce.
   */
  const emitted = zodToJsonSchema(
    z.object({ id: z.string(), note: z.string().default(""), count: z.number().optional() }),
  );
  const required = emitted["required"];

  assert.ok(Array.isArray(required));
  assert.deepEqual([...(required as string[])].sort(), ["count", "id", "note"]);

  const props = emitted["properties"] as Record<string, Record<string, unknown>>;
  assert.equal(props["note"]?.["type"], "string", "the default's inner type must survive");
});
