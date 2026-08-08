#!/usr/bin/env node
/**
 * Connectivity check: which runtimes are installed, and can each one actually
 * complete a turn?
 *
 * Detection alone is not enough — `cursor-agent` sits on PATH and exits
 * immediately when its stored credentials have expired, and codex blocks
 * forever if stdin is left open. Only a real round trip tells you the truth,
 * so `--probe` spawns each CLI with a trivial prompt.
 */
import { detectAll, getAdapter } from "../adapters/index.ts";
import { probeRuntime } from "../runtime/probe.ts";
import { RUNTIME_DISPLAY_NAMES, RUNTIME_KINDS, type RuntimeKind } from "../types.ts";

interface ProbeResult {
  kind: RuntimeKind;
  installed: boolean;
  version: string;
  probed: boolean;
  ok: boolean;
  output: string;
  error: string | null;
  ms: number;
  /**
   * How many events the adapter's parser produced, and of what kinds.
   *
   * Reported because "completed with zero events" is a distinct failure that
   * looks like success from the outside: the transport worked, the process
   * exited cleanly, and the PARSER understood nothing. Two runtimes — gemini and
   * grok — had never executed against their real CLIs at all, so their parsers
   * had only unit coverage, and that is exactly the state this distinguishes.
   */
  events: number;
  types: string[];
}

async function probe(kind: RuntimeKind): Promise<ProbeResult> {
  const adapter = getAdapter(kind);
  const detected = await adapter.detect();
  if (!detected) {
    return {
      kind,
      installed: false,
      version: "",
      probed: false,
      ok: false,
      output: "",
      error: "not on PATH",
      ms: 0,
      events: 0,
      types: [],
    };
  }

  const result = await probeRuntime({
    runtimeKind: kind,
    displayName: RUNTIME_DISPLAY_NAMES[kind],
    execPath: detected.execPath,
    version: detected.version,
  });
  return {
    kind,
    installed: true,
    version: detected.version,
    probed: true,
    ok: result.ok,
    output: result.output,
    error: result.error,
    ms: result.durationMs,
    events: result.eventCount,
    types: result.eventTypes,
  };
}

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const doProbe = args.includes("--probe");
  const only = args
    .filter((a) => !a.startsWith("--"))
    .filter((a): a is RuntimeKind => (RUNTIME_KINDS as readonly string[]).includes(a));

  console.log("TodoAgent doctor\n");

  const detected = await detectAll();
  console.log("Detected runtimes:");
  if (detected.length === 0) {
    console.log("  (none — install at least one coding CLI)");
  }
  for (const d of detected) {
    console.log(`  ${pad(d.kind, 10)} ${pad(d.version, 28)} ${d.execPath}`);
  }
  const missing = RUNTIME_KINDS.filter((k) => !detected.some((d) => d.kind === k));
  if (missing.length > 0) console.log(`  missing: ${missing.join(", ")}`);

  if (!doProbe) {
    console.log("\nPass --probe to run a real turn against each runtime.");
    console.log("Detection only proves the binary exists; it cannot tell you");
    console.log("whether its credentials are still valid.");
    return;
  }

  const targets = only.length > 0 ? only : detected.map((d) => d.kind);
  console.log(`\nProbing ${targets.length} runtime(s) in disposable repositories ...\n`);

  // Sequential on purpose: parallel probes race for the same rate limits and a
  // 429 would look like a broken adapter.
  const results: ProbeResult[] = [];
  for (const kind of targets) {
    process.stdout.write(`  ${pad(kind, 10)} ... `);
    const r = await probe(kind);
    results.push(r);
    if (r.ok) {
      // The event count is shown, not just stored: it is the only way to see that
      // a turn "worked" while the parser understood nothing of it.
      console.log(
        `OK   ${(r.ms / 1000).toFixed(1)}s  ${r.events} event(s)  "${r.output.slice(0, 50)}"`,
      );
    } else {
      console.log(`FAIL ${(r.ms / 1000).toFixed(1)}s  ${(r.error ?? "no output").slice(0, 160)}`);
    }
  }

  const ok = results.filter((r) => r.ok);
  console.log(`\n${ok.length}/${results.length} runtime(s) completed a turn.`);
  if (ok.length > 0) console.log(`Usable: ${ok.map((r) => r.kind).join(", ")}`);

  /*
   * Reported separately from failure, because it is not one.
   *
   * A runtime that returns text with zero events means the transport works and the
   * PARSER understood nothing on the way through — which looks like success from
   * outside and is the one degradation this whole command exists to expose.
   */
  const silent = ok.filter((r) => r.events === 0);
  if (silent.length > 0) {
    console.log(
      `\nCompleted but emitted NO events (parser suspect): ${silent.map((r) => r.kind).join(", ")}`,
    );
  }

  const failed = results.filter((r) => !r.ok);
  if (failed.length > 0) {
    console.log("\nFailures:");
    for (const f of failed) console.log(`  ${f.kind}: ${(f.error ?? "unknown").slice(0, 300)}`);
  }
  // Nonzero exit only when nothing works — one broken vendor should not fail CI.
  if (ok.length === 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
