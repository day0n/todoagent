import type { z } from "zod";

/**
 * Minimal zod → JSON Schema converter.
 *
 * Only exists to feed `codex exec --output-schema`, which enforces a schema
 * natively instead of making us reparse prose. Every other runtime ignores it,
 * so an imperfect conversion degrades to "reparse the text" rather than
 * breaking a run — hence the permissive fallback instead of a throw.
 *
 * Handles exactly the constructs the pipeline's schemas use. A new construct
 * lands in the fallback, which is safe but unenforced.
 */
export function zodToJsonSchema(schema: z.ZodTypeAny): Record<string, unknown> {
  return convert(schema, 0);
}

const MAX_DEPTH = 12;

function convert(schema: z.ZodTypeAny, depth: number): Record<string, unknown> {
  if (depth > MAX_DEPTH) return {};

  const def = (schema as { _def?: Record<string, unknown> })._def;
  if (!def) return {};
  const typeName = typeof def["typeName"] === "string" ? def["typeName"] : "";

  switch (typeName) {
    case "ZodString":
      return { type: "string" };
    case "ZodNumber": {
      const checks = Array.isArray(def["checks"]) ? def["checks"] : [];
      const isInt = checks.some(
        (c) => typeof c === "object" && c !== null && (c as { kind?: string }).kind === "int",
      );
      return { type: isInt ? "integer" : "number" };
    }
    case "ZodBoolean":
      return { type: "boolean" };
    case "ZodNull":
      return { type: "null" };

    case "ZodLiteral": {
      const value = def["value"];
      return { const: value };
    }

    case "ZodEnum": {
      const values = def["values"];
      return { type: "string", enum: Array.isArray(values) ? values : [] };
    }

    case "ZodArray": {
      const inner = def["type"] as z.ZodTypeAny | undefined;
      /*
       * Length bounds are carried through so the native schema states the same
       * contract zod enforces.
       *
       * Without them codex was told an array of any size was acceptable while the
       * parser rejected anything over the cap — the model would have had to
       * discover the limit by being refused, wasting a retry on a rule that could
       * simply have been declared.
       */
      const minLen = (def["minLength"] as { value?: number } | null)?.value;
      const maxLen = (def["maxLength"] as { value?: number } | null)?.value;
      return {
        type: "array",
        items: inner ? convert(inner, depth + 1) : {},
        ...(typeof minLen === "number" ? { minItems: minLen } : {}),
        ...(typeof maxLen === "number" ? { maxItems: maxLen } : {}),
      };
    }

    case "ZodObject": {
      const shapeFn = def["shape"];
      const shape =
        typeof shapeFn === "function"
          ? (shapeFn as () => Record<string, z.ZodTypeAny>)()
          : ((shapeFn ?? {}) as Record<string, z.ZodTypeAny>);
      const properties: Record<string, unknown> = {};
      const required: string[] = [];
      for (const [key, value] of Object.entries(shape)) {
        properties[key] = convert(value, depth + 1);
        if (!isSkippable(value)) required.push(key);
      }
      return {
        type: "object",
        properties,
        ...(required.length > 0 ? { required } : {}),
        // Codex enforces the schema strictly; leaving this open invites extra
        // keys that then have to be tolerated downstream.
        additionalProperties: false,
      };
    }

    case "ZodNullable": {
      const inner = def["innerType"] as z.ZodTypeAny | undefined;
      if (!inner) return {};
      const base = convert(inner, depth + 1);
      const t = base["type"];
      if (typeof t === "string") return { ...base, type: [t, "null"] };
      return { anyOf: [base, { type: "null" }] };
    }

    case "ZodOptional":
    case "ZodDefault": {
      const inner = def["innerType"] as z.ZodTypeAny | undefined;
      return inner ? convert(inner, depth + 1) : {};
    }

    case "ZodEffects": {
      /*
       * `.transform()` changes the value AFTER validation, not the wire type, so the
       * emitted schema is the inner one.
       *
       * Without this case, the review schema's truncating string fields fell into
       * the permissive default and codex received `{}` for `claim`, `evidence`,
       * `suggestedTest` and `patch` — i.e. "anything goes" where "must be a string"
       * was intended. That is invisible to typecheck and only shows up as a wasted
       * retry when the model returns the wrong shape and zod catches it downstream.
       */
      const inner = def["schema"] as z.ZodTypeAny | undefined;
      return inner ? convert(inner, depth + 1) : {};
    }

    case "ZodPipeline": {
      // Incoming data must satisfy the INPUT side; the output side is what the
      // pipeline produces afterwards.
      const input = def["in"] as z.ZodTypeAny | undefined;
      return input ? convert(input, depth + 1) : {};
    }

    case "ZodUnion": {
      const options = def["options"];
      if (!Array.isArray(options)) return {};
      return { anyOf: options.map((o) => convert(o as z.ZodTypeAny, depth + 1)) };
    }

    case "ZodRecord":
      return { type: "object" };

    default:
      // Unknown construct: permissive rather than wrong.
      return {};
  }
}

/** Optional and defaulted fields are not required in the emitted schema. */
function isSkippable(schema: z.ZodTypeAny): boolean {
  const def = (schema as { _def?: Record<string, unknown> })._def;
  const typeName = typeof def?.["typeName"] === "string" ? def["typeName"] : "";
  return typeName === "ZodOptional" || typeName === "ZodDefault";
}
