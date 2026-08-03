import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, resolveCliModel } from "@earendil-works/pi-coding-agent";

/**
 * `Model<Api>`, without importing pi-ai.
 *
 * The obvious `import type { Api, Model } from "@earendil-works/pi-ai"` does not
 * compile here: pnpm does not hoist transitive dependencies, so that specifier is
 * unresolvable from this workspace even though the package is on disk. pi-ai IS
 * resolvable from inside pi-coding-agent's own directory, which is why its `.d.ts`
 * files may name these types and this file may borrow one through a signature it
 * already exports.
 *
 * The alternative was declaring pi-ai as a dependency purely to make the reference
 * legal — permitted by the milestone, but it adds a second version to keep in step
 * with pi-coding-agent for no capability we do not already have.
 */
type PiModel = NonNullable<ReturnType<typeof resolveCliModel>["model"]>;

/**
 * Resolving the configured model, once, for everything that needs one.
 *
 * Two consumers with different lifetimes: the secretary builds a long-lived
 * `AgentSession` on top of this at startup, and the classifier makes a single
 * non-streaming call per finished run. Both need the identical five steps —
 * read the spec, create a runtime over the same auth files, resolve the spec to a
 * model, inject `TODOAGENT_API_KEY`, confirm credentials actually exist — and
 * getting any of them subtly different between the two would mean chat works while
 * classification silently falls back to the heuristic, or the reverse.
 *
 * `ModelRuntime` and `resolveCliModel` come from pi-coding-agent, which is already a
 * declared dependency. The two names imported from pi-ai here are TYPES only, so
 * they are erased before runtime and never hit module resolution.
 */

export interface ResolvedModel {
  /** The pi-ai `Models` collection, with auth resolved. */
  runtime: ModelRuntime;
  model: PiModel;
  /** `provider/id`, for display and logs. */
  spec: string;
}

/**
 * Success, or a sentence written for a person to read.
 *
 * "Not configured" is a first-class state rather than an error: the whole app works
 * without a model. Chat says so in a banner; classification just uses its
 * heuristic. So every failure reason here has to be legible to a user, not a
 * developer.
 */
export type ModelResolution = { ok: true; resolved: ResolvedModel } | { ok: false; reason: string };

/** Where the secretary's own pi state lives, isolated from the user's `~/.pi`. */
export function agentDir(): string {
  return process.env["TODOAGENT_AGENT_DIR"] ?? join(homedir(), ".todoagent", "pi");
}

export async function resolveModel(): Promise<ModelResolution> {
  const modelSpec = process.env["TODOAGENT_MODEL"];
  if (modelSpec === undefined || modelSpec.trim() === "") {
    return {
      ok: false,
      reason:
        "未配置模型。设置 TODOAGENT_MODEL（如 anthropic/claude-haiku-4-5）和对应的 API key 后重启引擎。",
    };
  }

  const dir = agentDir();
  const runtime = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: join(dir, "models.json"),
  });

  const resolved = resolveCliModel({ cliModel: modelSpec, modelRuntime: runtime });
  if (resolved.error !== undefined || resolved.model === undefined) {
    return {
      ok: false,
      reason: `模型 ${modelSpec} 无法解析：${resolved.error ?? "未找到"}。检查 TODOAGENT_MODEL 的 provider/model 拼写。`,
    };
  }
  const model = resolved.model;

  const apiKey = process.env["TODOAGENT_API_KEY"];
  if (apiKey !== undefined && apiKey !== "") {
    runtime.setRuntimeApiKey(model.provider, apiKey);
  }

  /*
   * Availability is checked here rather than left to the first call.
   *
   * Without it a missing key surfaces as a provider error in the middle of a chat
   * turn — or, for the classifier, as a silent fall back to the heuristic with
   * nothing saying why. Asking up front turns both into one sentence naming the
   * environment variable to set.
   */
  const available = await runtime.getAvailable();
  if (!available.some((m) => m.provider === model.provider && m.id === model.id)) {
    return {
      ok: false,
      reason: `模型 ${modelSpec} 缺少凭据。设置 TODOAGENT_API_KEY 或对应厂商的环境变量（如 ANTHROPIC_API_KEY）。`,
    };
  }

  return { ok: true, resolved: { runtime, model, spec: `${model.provider}/${model.id}` } };
}
