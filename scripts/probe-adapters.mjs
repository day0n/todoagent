#!/usr/bin/env node
/**
 * Exercises every detected adapter against its REAL CLI, with one trivial prompt.
 *
 * Written because the attempt table showed gemini and grok at zero attempts
 * across nine real runs: their parsers have unit coverage only, and "six runtimes
 * supported" was an untested claim for two of the six. A full pipeline run would
 * cost a hundred thousand tokens to learn the same thing, and might not even route
 * to them — selection is deterministic, so the third reviewer rarely participates.
 *
 * This asks each CLI a question whose answer is one word. What it verifies is the
 * PLUMBING: the binary spawns, the transport parses, a terminal result arrives, and
 * usage is reported. That is exactly the part that has never run.
 *
 * Costs real tokens on the user's account, deliberately and minimally — one short
 * turn per runtime is the cheapest possible proof that a runtime works at all.
 *
 *   node --experimental-strip-types scripts/probe-adapters.mjs          # all detected
 *   node --experimental-strip-types scripts/probe-adapters.mjs gemini grok
 */

import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { argv } from "node:process";
import { detectAll, getAdapter } from "../packages/core/src/adapters/index.ts";

/** Short, because a wedged or unauthenticated CLI must not hang the probe. */
const TIMEOUT_MS = 90_000;
/** Shorter still: an authenticated CLI answers this in seconds. */
const IDLE_MS = 45_000;

const PROMPT = "Reply with exactly one word: ready";

const wanted = new Set(argv.slice(2).filter((a) => !a.startsWith("--")));

const detected = await detectAll();
if (detected.length === 0) {
  console.log("No agent CLIs found on PATH.");
  process.exit(1);
}

const targets = detected.filter((d) => wanted.size === 0 || wanted.has(d.kind));
if (targets.length === 0) {
  console.log(`None of [${[...wanted].join(", ")}] are installed.`);
  console.log(`Detected: ${detected.map((d) => d.kind).join(", ")}`);
  process.exit(1);
}

console.log(`Probing ${targets.length} runtime(s) with one short turn each.\n`);

const dir = await mkdtemp(join(tmpdir(), "council-probe-"));
const results = [];

for (const runtime of targets) {
  const started = Date.now();
  const row = { kind: runtime.kind, version: runtime.version, events: 0, types: new Set() };

  try {
    const run = getAdapter(runtime.kind).execute(PROMPT, {
      cwd: dir,
      model: null,
      systemPrompt: null,
      timeoutMs: TIMEOUT_MS,
      idleTimeoutMs: IDLE_MS,
    });

    /*
     * The stream is drained CONCURRENTLY with awaiting the result.
     *
     * Adapters close the event channel before settling, so consuming it after the
     * result would deadlock on a runtime that fills its queue — and an undrained
     * stream can hold the child process open.
     */
    const drain = (async () => {
      for await (const ev of run.events) {
        row.events++;
        row.types.add(ev.type);
      }
    })();

    const result = await run.result;
    await drain;

    row.status = result.status;
    row.ms = Date.now() - started;
    row.output = (result.output ?? "").trim().slice(0, 60);
    row.error = result.error;
    row.tokens = result.usage.inputTokens + result.usage.outputTokens;
    row.costUsd = result.usage.costUsd;
  } catch (err) {
    row.status = "threw";
    row.ms = Date.now() - started;
    row.error = err instanceof Error ? err.message : String(err);
  }

  results.push(row);

  const mark = row.status === "completed" ? "ok  " : "FAIL";
  console.log(`  ${mark} ${row.kind.padEnd(7)} ${String(row.ms).padStart(6)}ms  ${row.status}`);
  console.log(`         version: ${row.version}`);
  if (row.output !== undefined && row.output !== "") console.log(`         output:  ${JSON.stringify(row.output)}`);
  console.log(`         events:  ${row.events} (${[...row.types].sort().join(", ") || "none"})`);
  if (row.tokens !== undefined) {
    console.log(`         usage:   ${row.tokens} tokens${row.costUsd ? `, $${row.costUsd}` : ""}`);
  }
  if (row.error !== null && row.error !== undefined) {
    console.log(`         error:   ${String(row.error).split("\n")[0].slice(0, 120)}`);
  }
  console.log("");
}

await rm(dir, { recursive: true, force: true });

const ok = results.filter((r) => r.status === "completed");
const bad = results.filter((r) => r.status !== "completed");

console.log(`${ok.length}/${results.length} runtime(s) completed a turn.`);

/*
 * Zero events is reported separately from failure. A runtime that returns a
 * result with no events parsed nothing on the way — the transport is working and
 * the PARSER is not, which looks like success from the outside and is exactly the
 * silent degradation worth naming.
 */
const silent = ok.filter((r) => r.events === 0);
if (silent.length > 0) {
  console.log(`\nCompleted but emitted NO events (parser suspect): ${silent.map((r) => r.kind).join(", ")}`);
}
if (bad.length > 0) {
  console.log(`\nFailed: ${bad.map((r) => `${r.kind} (${r.status})`).join(", ")}`);
}

process.exit(bad.length > 0 ? 1 : 0);
