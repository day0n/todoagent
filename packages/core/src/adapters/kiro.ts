import { which } from "../util/which.ts";
import { probeVersion } from "./process.ts";
import { runAcp } from "./acp.ts";
import { execPathForRuntime, filterBlockedArgs, type AgentAdapter, type BlockedArgMode, type ExecOptions } from "./types.ts";
import type { DetectedRuntime } from "../types.ts";

const BLOCKED: Readonly<Record<string, BlockedArgMode>> = {
  "-a": "standalone",
  "--trust-all-tools": "standalone",
  "--trust-tools": "withValue",
  "--model": "withValue",
  "--agent": "withValue",
};

/**
 * Kiro CLI over ACP (`kiro-cli acp`), verified against Kiro CLI Agent 2.12.2.
 *
 * `-a/--trust-all-tools` is mandatory: without it the agent raises
 * `session/request_permission` and blocks on a human that a headless run does
 * not have. The ACP transport also auto-answers that request as a second line
 * of defence, since permission prompts can still arrive per-tool.
 */
export class KiroAdapter implements AgentAdapter {
  readonly kind = "kiro" as const;

  async detect(): Promise<DetectedRuntime | null> {
    const execPath = await which("kiro-cli");
    if (!execPath) return null;
    const version = await probeVersion(execPath, ["--version"]);
    return { kind: this.kind, execPath, version: version ?? "unknown" };
  }

  execute(prompt: string, opts: ExecOptions) {
    const args = ["acp", "-a"];
    if (opts.model) args.push("--model", opts.model);
    const { kept } = filterBlockedArgs(opts.extraArgs ?? [], BLOCKED);
    args.push(...kept);
    return runAcp(prompt, { ...opts, execPath: execPathForRuntime(this.kind, opts), args });
  }
}
