import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { newLineContext, parseJsonLine, spawnStream, type LineContext } from "./process.ts";
import type { AgentEvent, AgentResult } from "./types.ts";

/**
 * Transport-layer tests for the watchdogs and process lifecycle.
 *
 * These use FAKE executables written by the test, never a real agent CLI: the
 * behaviour under test is "what happens when a subprocess misbehaves", and a
 * real CLI cannot be made to hang or exit 3 on demand. It also keeps the suite
 * free of network calls, quota, and multi-minute runtimes.
 *
 * Everything here was asserted in comments and never verified. The watchdogs are
 * the only thing standing between a wedged agent and a run that hangs forever.
 */

interface Fixture {
  dir: string;
  script: (body: string) => Promise<string>;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const dir = await mkdtemp(join(tmpdir(), "council-proc-"));
  let n = 0;
  return {
    dir,
    async script(body: string): Promise<string> {
      n++;
      const path = join(dir, `fake-${n}.sh`);
      await writeFile(path, `#!/bin/sh\n${body}\n`, "utf8");
      await chmod(path, 0o755);
      return path;
    },
    dispose: () => rm(dir, { recursive: true, force: true }),
  };
}

/** Minimal parser: one JSON object per line, `text` and tool events. */
function onLine(line: string, ctx: LineContext): AgentEvent[] | null {
  const obj = parseJsonLine(line);
  if (!obj) return null;
  const type = typeof obj["type"] === "string" ? obj["type"] : "";
  if (type === "text") {
    const content = typeof obj["content"] === "string" ? obj["content"] : "";
    ctx.lastText = content;
    return [{ type: "text", content }];
  }
  if (type === "tool_use") {
    return [{ type: "tool_use", tool: "sleep", callId: "c1", input: null }];
  }
  if (type === "tool_result") {
    return [{ type: "tool_result", tool: "sleep", callId: "c1", output: "done" }];
  }
  if (type === "done") {
    ctx.turnCompleted = true;
    return [{ type: "status", status: "done" }];
  }
  if (type === "boom") {
    ctx.failure = "the agent reported failure";
    return [{ type: "error", message: ctx.failure }];
  }
  return null;
}

function finalize(ctx: LineContext, exitCode: number | null, stderrTail: string): AgentResult {
  const ok = exitCode === 0 && ctx.failure === null;
  return {
    status: ok ? "completed" : "failed",
    output: ctx.lastText,
    error: ok ? null : (ctx.failure ?? `exited ${exitCode}: ${stderrTail.slice(-200)}`),
    sessionId: ctx.sessionId,
    durationMs: 0,
    usage: ctx.usage,
  };
}

/** Runs to completion, draining events so the queue cannot grow unbounded. */
async function run(
  execPath: string,
  cwd: string,
  opts: { idleTimeoutMs?: number; timeoutMs?: number; signal?: AbortSignal } = {},
): Promise<{ result: AgentResult; events: AgentEvent[]; eventsClosedFirst: boolean }> {
  const started = Date.now();
  const session = spawnStream({ execPath, args: [], cwd, onLine, finalize, ...opts });
  const events: AgentEvent[] = [];
  let eventsClosedAt = 0;
  const drain = (async () => {
    for await (const ev of session.events) events.push(ev);
    eventsClosedAt = Date.now() - started;
  })();
  const result = await session.result;
  const resultAt = Date.now() - started;
  await drain;
  return { result, events, eventsClosedFirst: eventsClosedAt <= resultAt };
}

// ── Happy path ──────────────────────────────────────────────

test("a well-behaved process completes and yields its events", async () => {
  const f = await fixture();
  try {
    const script = await f.script(
      `echo '{"type":"text","content":"hello"}'\necho '{"type":"done"}'\nexit 0`,
    );
    const { result, events } = await run(script, f.dir);
    assert.equal(result.status, "completed");
    assert.equal(result.output, "hello");
    assert.equal(result.error, null);
    assert.ok(result.durationMs >= 0);
    assert.deepEqual(events.map((e) => e.type), ["text", "status"]);
  } finally {
    await f.dispose();
  }
});

test("the event channel closes before the result settles", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`echo '{"type":"text","content":"x"}'\nexit 0`);
    const { eventsClosedFirst } = await run(script, f.dir);
    // Consumers drain the stream and then read the outcome; if the result
    // settled first they could deadlock waiting on a channel that never closes.
    assert.equal(eventsClosedFirst, true);
  } finally {
    await f.dispose();
  }
});

// ── Watchdogs ───────────────────────────────────────────────

test("the idle watchdog kills a process that goes silent", async () => {
  const f = await fixture();
  try {
    /*
     * Emits once, then hangs far longer than the idle window.
     *
     * The window has to clear process startup. The watchdog is armed at spawn, so
     * a 400ms window raced the shell's own launch (a few hundred ms on a loaded
     * machine): the kill sometimes landed before the first line, leaving empty
     * output and a flaky assertion. 1.5s puts the first line comfortably inside
     * the window, so what trips the watchdog is unambiguously the silence after
     * it. The product default is 10 minutes, where startup is irrelevant.
     */
    const script = await f.script(`echo '{"type":"text","content":"then silence"}'\nsleep 30`);
    const started = Date.now();
    const { result } = await run(script, f.dir, { idleTimeoutMs: 1500 });
    const elapsed = Date.now() - started;

    assert.equal(result.status, "timeout", "a silent agent must not stall the run forever");
    assert.match(result.error ?? "", /idle watchdog/);
    // Partial output is still surrendered rather than discarded.
    assert.equal(result.output, "then silence");
    assert.ok(elapsed < 15_000, `killed in ${elapsed}ms, not after the script's own sleep`);
  } finally {
    await f.dispose();
  }
});

test("the idle watchdog is reset by each new line", async () => {
  const f = await fixture();
  try {
    /*
     * Five lines 400ms apart under a 1.5s window: total runtime (~2s plus
     * startup) far exceeds the window, but no single GAP does — which is the
     * property being tested.
     *
     * The window must also clear process startup, since the watchdog is armed at
     * spawn and launching a shell costs a few hundred ms on a loaded machine. A
     * 500ms window flaked for exactly that reason, killing the process before its
     * first line rather than because of any gap. The product default is 10
     * minutes, so startup latency is irrelevant there.
     */
    const script = await f.script(
      `for i in 1 2 3 4 5; do echo '{"type":"text","content":"tick"}'; sleep 0.4; done\necho '{"type":"done"}'\nexit 0`,
    );
    const { result } = await run(script, f.dir, { idleTimeoutMs: 1500 });
    assert.equal(result.status, "completed");
  } finally {
    await f.dispose();
  }
});

test("an in-flight tool call extends the idle window", async () => {
  const f = await fixture();
  try {
    /*
     * A long build is not a hang. The script goes quiet for 3s AFTER announcing a
     * tool call, well past the 1.5s generic window — without the separate, longer
     * tool budget this would be killed, and so would any agent running a real
     * build or test suite.
     *
     * The window has to exceed process startup: the watchdog is armed at spawn,
     * and launching a shell costs a few hundred ms on a loaded machine. A 300ms
     * window killed the process before its first line ever arrived, which looked
     * like a missing tool budget but was just an unrealistically short timeout.
     * The product default is 10 minutes, so startup latency is a non-issue there.
     */
    const script = await f.script(
      `echo '{"type":"tool_use"}'\nsleep 3\necho '{"type":"tool_result"}'\necho '{"type":"done"}'\nexit 0`,
    );
    const { result, events } = await run(script, f.dir, { idleTimeoutMs: 1500 });
    assert.equal(result.status, "completed", "a tool call in flight must not be treated as a hang");
    assert.ok(events.some((e) => e.type === "tool_use"));
    assert.ok(events.some((e) => e.type === "tool_result"));
  } finally {
    await f.dispose();
  }
});

test("the idle window narrows again once the tool finishes", async () => {
  const f = await fixture();
  try {
    // Tool completes, then the process goes silent — back under the short window.
    // 1.5s for the same startup reason as the test above.
    const script = await f.script(
      `echo '{"type":"tool_use"}'\necho '{"type":"tool_result"}'\nsleep 30`,
    );
    const started = Date.now();
    const { result } = await run(script, f.dir, { idleTimeoutMs: 1500 });
    assert.equal(result.status, "timeout");
    assert.ok(Date.now() - started < 15_000, "the extended budget must not persist after the tool");
  } finally {
    await f.dispose();
  }
});

test("a hard timeout bounds a process that keeps talking", async () => {
  const f = await fixture();
  try {
    // Never idle, so only the wall-clock cap can stop it.
    const script = await f.script(
      `while true; do echo '{"type":"text","content":"chatty"}'; sleep 0.1; done`,
    );
    const started = Date.now();
    const { result } = await run(script, f.dir, { timeoutMs: 800, idleTimeoutMs: 0 });
    assert.equal(result.status, "timeout");
    assert.match(result.error ?? "", /wall-clock/);
    assert.ok(Date.now() - started < 10_000);
  } finally {
    await f.dispose();
  }
});

test("idleTimeoutMs of zero disables the idle watchdog", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`sleep 0.8\necho '{"type":"done"}'\nexit 0`);
    // An explicit 0 must mean "no idle bound", not "kill immediately".
    const { result } = await run(script, f.dir, { idleTimeoutMs: 0 });
    assert.equal(result.status, "completed");
  } finally {
    await f.dispose();
  }
});

// ── Cancellation ────────────────────────────────────────────

test("aborting the signal cancels the run", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`echo '{"type":"text","content":"working"}'\nsleep 30`);
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 300);
    const started = Date.now();
    const { result } = await run(script, f.dir, { signal: controller.signal, idleTimeoutMs: 0 });
    assert.equal(result.status, "cancelled");
    assert.equal(result.error, "cancelled");
    // Cancelling a run must actually reap the subprocess, not orphan it.
    assert.ok(Date.now() - started < 10_000);
  } finally {
    await f.dispose();
  }
});

test("an already-aborted signal cancels immediately", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`sleep 30`);
    const controller = new AbortController();
    controller.abort();
    const { result } = await run(script, f.dir, { signal: controller.signal, idleTimeoutMs: 0 });
    assert.equal(result.status, "cancelled");
  } finally {
    await f.dispose();
  }
});

// ── Failure modes ───────────────────────────────────────────

test("a missing executable fails instead of throwing", async () => {
  const f = await fixture();
  try {
    const { result } = await run(join(f.dir, "does-not-exist"), f.dir);
    // A throw here would take down the whole pipeline rather than one subtask.
    assert.equal(result.status, "failed");
    assert.match(result.error ?? "", /spawn failed/);
  } finally {
    await f.dispose();
  }
});

test("a nonzero exit is reported with a stderr tail", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`echo "something went wrong" >&2\nexit 3`);
    const { result } = await run(script, f.dir);
    assert.equal(result.status, "failed");
    // Without the tail, the operator sees a bare exit code and has to guess.
    assert.match(result.error ?? "", /something went wrong/);
  } finally {
    await f.dispose();
  }
});

test("an adapter-declared failure beats a zero exit code", async () => {
  const f = await fixture();
  try {
    // Several CLIs report an error in-band and still exit 0.
    const script = await f.script(`echo '{"type":"boom"}'\nexit 0`);
    const { result, events } = await run(script, f.dir);
    assert.equal(result.status, "failed");
    assert.equal(result.error, "the agent reported failure");
    assert.ok(events.some((e) => e.type === "error"));
  } finally {
    await f.dispose();
  }
});

test("stdin is closed so a reading process does not hang", async () => {
  const f = await fixture();
  try {
    /*
     * Regression guard for a real failure: codex blocks on "Reading additional
     * input from stdin..." when stdin stays open and never reaches its turn. It
     * must receive EOF immediately.
     */
    const script = await f.script(`cat > /dev/null\necho '{"type":"done"}'\nexit 0`);
    const started = Date.now();
    const { result } = await run(script, f.dir, { idleTimeoutMs: 3000 });
    assert.equal(result.status, "completed", "the process must see EOF on stdin, not block");
    assert.ok(Date.now() - started < 3000);
  } finally {
    await f.dispose();
  }
});

test("a parser that throws does not kill the run", async () => {
  const f = await fixture();
  try {
    const script = await f.script(`echo '{"type":"text","content":"a"}'\necho '{"type":"done"}'\nexit 0`);
    const session = spawnStream({
      execPath: script,
      args: [],
      cwd: f.dir,
      onLine: (line, ctx) => {
        if (line.includes('"a"')) throw new Error("parser bug");
        return onLine(line, ctx);
      },
      finalize,
    });
    const events: AgentEvent[] = [];
    const drain = (async () => {
      for await (const ev of session.events) events.push(ev);
    })();
    const result = await session.result;
    await drain;

    // The bug is surfaced as an error event; the remaining lines still parse.
    assert.ok(
      events.some((e) => e.type === "error" && e.message.includes("parse error")),
      "the parser failure must surface as an error event",
    );
    assert.equal(result.status, "completed");
  } finally {
    await f.dispose();
  }
});

test("non-JSON banner noise is ignored", async () => {
  const f = await fixture();
  try {
    const script = await f.script(
      `echo "Loading model..."\necho ""\necho "warning: deprecated flag"\necho '{"type":"text","content":"real"}'\necho '{"type":"done"}'\nexit 0`,
    );
    const { result, events } = await run(script, f.dir);
    assert.equal(result.status, "completed");
    assert.equal(result.output, "real");
    // Every real CLI interleaves human-readable chatter with its protocol.
    assert.deepEqual(events.map((e) => e.type), ["text", "status"]);
  } finally {
    await f.dispose();
  }
});

test("a truncated final line does not corrupt the result", async () => {
  const f = await fixture();
  try {
    // `printf` without a newline: the last line arrives unterminated.
    const script = await f.script(
      `echo '{"type":"text","content":"good"}'\nprintf '{"type":"text","content":"trunc'\nexit 0`,
    );
    const { result } = await run(script, f.dir);
    assert.equal(result.status, "completed");
    assert.equal(result.output, "good", "the half-written line must be discarded, not parsed");
  } finally {
    await f.dispose();
  }
});

test("a large burst of output is delivered without loss", async () => {
  const f = await fixture();
  try {
    const script = await f.script(
      `i=0\nwhile [ $i -lt 500 ]; do echo '{"type":"text","content":"line"}'; i=$((i+1)); done\necho '{"type":"done"}'\nexit 0`,
    );
    const { result, events } = await run(script, f.dir, { idleTimeoutMs: 5000 });
    assert.equal(result.status, "completed");
    // Backpressure between a fast producer and the async consumer must not drop
    // events — the event log is the only durable record of what an agent did.
    assert.equal(events.filter((e) => e.type === "text").length, 500);
  } finally {
    await f.dispose();
  }
});

// ── Context accumulation ────────────────────────────────────

test("newLineContext starts clean", () => {
  const ctx = newLineContext();
  assert.equal(ctx.sessionId, null);
  assert.equal(ctx.lastText, "");
  assert.equal(ctx.failure, null);
  assert.equal(ctx.turnCompleted, false);
  assert.equal(ctx.toolInFlight, 0);
  assert.deepEqual(ctx.warnings, []);
  assert.equal(ctx.usage.inputTokens, 0);
});
