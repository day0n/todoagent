import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAdapter } from "../adapters/index.ts";
import type { ExecutionTarget, RuntimeKind } from "../types.ts";
import { git } from "../util/git.ts";

export const RUNTIME_PROBE_PROMPT = "Reply with exactly: TODOAGENT_OK";
export const RUNTIME_PROBE_TIMEOUT_MS = 180_000;

export interface RuntimeProbeResult {
  kind: RuntimeKind;
  ok: boolean;
  output: string;
  error: string | null;
  durationMs: number;
  eventCount: number;
  eventTypes: string[];
}

export interface RuntimeProbeOptions {
  prompt?: string;
  timeoutMs?: number;
  idleTimeoutMs?: number;
}

/**
 * Performs a real CLI round trip inside a disposable Git repository.
 *
 * The executable path comes from the verified target and is passed unchanged to
 * the adapter. The directory is removed in `finally`, covering failed Git init,
 * spawn errors, parser errors, cancellation and successful completion alike.
 */
export async function probeRuntime(
  target: ExecutionTarget,
  options: RuntimeProbeOptions = {},
): Promise<RuntimeProbeResult> {
  const startedAt = Date.now();
  const dir = await mkdtemp(join(tmpdir(), "todoagent-runtime-probe-"));
  try {
    const init = await git(["init", "-q", "."], dir);
    if (init.code !== 0) throw new Error(`could not initialize probe repository: ${init.stderr}`);
    const commit = await git(
      [
        "-c",
        "user.name=TodoAgent",
        "-c",
        "user.email=todoagent@localhost",
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        "init",
      ],
      dir,
    );
    if (commit.code !== 0) throw new Error(`could not prepare probe repository: ${commit.stderr}`);

    const adapter = getAdapter(target.runtimeKind);
    const execution = adapter.execute(options.prompt ?? RUNTIME_PROBE_PROMPT, {
      cwd: dir,
      execPath: target.execPath,
      timeoutMs: options.timeoutMs ?? RUNTIME_PROBE_TIMEOUT_MS,
      idleTimeoutMs: options.idleTimeoutMs ?? 90_000,
    });

    const textEvents: string[] = [];
    const eventTypes = new Set<string>();
    let eventCount = 0;
    const drain = (async () => {
      for await (const event of execution.events) {
        eventCount++;
        eventTypes.add(event.type);
        if (event.type === "text") textEvents.push(event.content);
      }
    })();
    const result = await execution.result;
    await drain;

    const output = (result.output || textEvents.join("")).trim();
    let error = result.error;
    if (result.status === "completed" && eventCount === 0) {
      error = "runtime completed but emitted no parseable events";
    } else if (result.status === "completed" && !output.includes("TODOAGENT_OK")) {
      error = "runtime completed but did not return the probe marker";
    }
    const ok = result.status === "completed" && eventCount > 0 && error === null;
    return {
      kind: target.runtimeKind,
      ok,
      output: output.slice(0, 200),
      error: ok ? null : (error ?? `runtime probe ${result.status}`),
      durationMs: Date.now() - startedAt,
      eventCount,
      eventTypes: [...eventTypes].sort(),
    };
  } catch (error) {
    return {
      kind: target.runtimeKind,
      ok: false,
      output: "",
      error: error instanceof Error ? error.message : String(error),
      durationMs: Date.now() - startedAt,
      eventCount: 0,
      eventTypes: [],
    };
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => undefined);
  }
}
