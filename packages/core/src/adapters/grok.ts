import { which } from "../util/which.ts";
import { probeVersion } from "./process.ts";
import { runAcp } from "./acp.ts";
import { execPathForRuntime, filterBlockedArgs, type AgentAdapter, type BlockedArgMode, type ExecOptions } from "./types.ts";
import type { DetectedRuntime } from "../types.ts";

const BLOCKED: Readonly<Record<string, BlockedArgMode>> = {
  "--always-approve": "standalone",
  "-m": "withValue",
  "--model": "withValue",
  "--reasoning-effort": "withValue",
  "--effort": "withValue",
  "--reauth": "standalone",
  "--leader": "standalone",
  // Leader mode shares one backend across clients. Parallel subtasks must each
  // own their process, so the adapter forces a fresh agent per run.
  "--no-leader": "standalone",
};

/**
 * xAI Grok Build CLI over ACP (`grok agent stdio`), verified present as
 * grok 0.2.114.
 *
 * `--always-approve` is mandatory for headless operation, same reason as Kiro's
 * `-a`. `--no-leader` is forced because Grok defaults to attaching to a shared
 * leader process when `[cli] use_leader` is set in config.toml — that would let
 * two parallel subtasks share one backend and interleave their turns.
 *
 * Grok is the only runtime that states its own spend (`_meta.usage.costUsdTicks`,
 * in ticks of 1e-10 USD). The ACP transport reads it, which matters because a
 * tokens-times-rate estimate cannot reproduce request-level pricing rules.
 */
export class GrokAdapter implements AgentAdapter {
  readonly kind = "grok" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("grok");
    if (!execPath) return null;
    const version = await probeVersion(execPath, ["--version"]);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    const args = ["agent", "--always-approve", "--no-leader"];
    if (opts.model) args.push("-m", opts.model);
    const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
    args.push(...kept);
    // Subcommand goes last: `grok agent [OPTIONS] stdio`.
    args.push("stdio");
    return runAcp(prompt, { ...opts, execPath: execPathForRuntime(this.kind, opts), args });
  }
}
