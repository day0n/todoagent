import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runAcp } from "./acp.ts";
import type { AgentEvent } from "./types.ts";

/**
 * The ACP transport, driven by a fake JSON-RPC agent.
 *
 * This is the last major transport with no coverage. It went through the real
 * `doctor --probe` once against kiro and grok, which proves a happy path exists —
 * but the interesting logic was never exercised:
 *
 *  - Kiro streams text ONE CHARACTER AT A TIME (verified against Kiro CLI 2.12.2),
 *    so the transport coalesces chunks. If a pending buffer is dropped when the
 *    process exits, text is silently lost — the worst possible failure here,
 *    because a short reply looks like a terse agent rather than a bug.
 *  - A `session/request_permission` that goes unanswered hangs the turn forever,
 *    with no output to indicate why.
 *
 * A fake agent makes both deterministic and costs no tokens.
 */

interface Fake {
  path: string;
  dispose: () => Promise<void>;
}

/**
 * Writes a fake ACP agent.
 *
 * `mode` selects the behaviour under test. Everything is line-delimited JSON-RPC on
 * stdio, mirroring the real handshake: initialize → session/new → session/prompt.
 */
async function fakeAgent(mode: string, text = "hello world"): Promise<Fake> {
  const dir = await mkdtemp(join(tmpdir(), "acp-fake-"));
  const path = join(dir, "agent");
  await writeFile(
    path,
    `#!/usr/bin/env node
const readline = require("node:readline");
const MODE = ${JSON.stringify(mode)};
const TEXT = ${JSON.stringify(text)};

const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
const notify = (method, params) => send({ jsonrpc: "2.0", method, params });

let sessionId = "fake-session";

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }

  if (msg.method === "initialize") {
    if (MODE === "hang-handshake") return; // never reply
    send({ jsonrpc: "2.0", id: msg.id, result: {
      protocolVersion: 1,
      agentCapabilities: {},
      agentInfo: { name: "Fake", version: "1.0" },
    }});
    return;
  }

  if (msg.method === "session/new") {
    send({ jsonrpc: "2.0", id: msg.id, result: { sessionId } });
    return;
  }

  if (msg.method === "session/prompt") {
    if (MODE === "permission") {
      // Ask for permission and only continue once answered. An unanswered request
      // is exactly how a headless turn hangs forever.
      send({ jsonrpc: "2.0", id: 9001, method: "session/request_permission", params: {
        sessionId,
        options: [
          { optionId: "reject-once", kind: "reject_once", name: "No" },
          { optionId: "allow-always", kind: "allow_always", name: "Yes" },
        ],
      }});
      return;
    }
    respond(msg.id);
    return;
  }

  // Our reply to the permission request.
  if (msg.id === 9001 && msg.result) {
    notify("session/update", { sessionId, update: {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "chose:" + msg.result.outcome.optionId },
    }});
    // The prompt id is always 3 in this transport's fixed handshake order.
    respond(3);
    return;
  }
});

function respond(promptId) {
  if (MODE === "tool") {
    notify("session/update", { sessionId, update: {
      sessionUpdate: "tool_call", toolCallId: "t1", title: "shell", rawInput: { cmd: "ls" },
    }});
    notify("session/update", { sessionId, update: {
      sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed",
      content: [{ content: { type: "text", text: "total 0" } }],
    }});
  }

  if (MODE !== "permission") {
    // One CHARACTER per notification, as Kiro actually does.
    for (const ch of TEXT) {
      notify("session/update", { sessionId, update: {
        sessionUpdate: "agent_message_chunk", content: { type: "text", text: ch },
      }});
    }
  }

  if (MODE === "refusal") {
    send({ jsonrpc: "2.0", id: promptId, result: { stopReason: "refusal" } });
    return;
  }
  if (MODE === "grok-usage") {
    send({ jsonrpc: "2.0", id: promptId, result: {
      stopReason: "end_turn",
      // Grok reports its own price in ticks of 1e-10 USD.
      _meta: { usage: { inputTokens: 1234, outputTokens: 56, costUsdTicks: 42_000_000 } },
    }});
    return;
  }
  send({ jsonrpc: "2.0", id: promptId, result: { stopReason: "end_turn" } });
}
`,
    "utf8",
  );
  await chmod(path, 0o755);
  return { path, dispose: () => rm(dir, { recursive: true, force: true }) };
}

async function drive(
  fake: Fake,
  cwd: string,
  opts: { timeoutMs?: number; handshakeTimeoutMs?: number } = {},
) {
  const run = runAcp("do the thing", {
    execPath: fake.path,
    args: [],
    cwd,
    timeoutMs: 60_000,
    ...opts,
  });
  const events: AgentEvent[] = [];
  const drain = (async () => {
    for await (const ev of run.events) events.push(ev);
  })();
  const result = await run.result;
  await drain;
  return { result, events };
}

test("character-by-character text is reassembled without loss", async () => {
  const TEXT = "The quick brown fox jumps over the lazy dog.";
  const fake = await fakeAgent("plain", TEXT);
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result, events } = await drive(fake, cwd);

    assert.equal(result.status, "completed", result.error ?? "");
    /*
     * The assertion that matters. Kiro emits one character per notification, so a
     * dropped buffer at exit — or a flush that misses the tail — loses text
     * silently. A truncated reply reads as a terse agent, not as a bug.
     */
    assert.equal(result.output, TEXT);

    // Coalesced rather than one event per character, or the timeline would be
    // unusable and the event log enormous.
    const textEvents = events.filter((e) => e.type === "text");
    assert.ok(
      textEvents.length < TEXT.length / 4,
      `${textEvents.length} text events for ${TEXT.length} chars — not coalescing`,
    );
    // And the concatenation still equals the original.
    assert.equal(textEvents.map((e) => (e.type === "text" ? e.content : "")).join(""), TEXT);
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a short reply is not lost to the flush timer", async () => {
  /*
   * Below both flush thresholds (120 chars, 400ms), so the ONLY thing that emits it
   * is the flush on settle. Without that, every brief answer — "OK", "LGTM", a
   * one-line verdict — would vanish.
   */
  const fake = await fakeAgent("plain", "OK");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result, events } = await drive(fake, cwd);
    assert.equal(result.status, "completed", result.error ?? "");
    assert.equal(result.output, "OK");
    assert.ok(events.some((e) => e.type === "text" && e.content === "OK"));
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a long reply crossing the flush threshold arrives intact", async () => {
  // Well past 120 chars, so mid-stream flushes happen and the tail still has to be
  // emitted at settle.
  const TEXT = "abcdefghij".repeat(40); // 400 chars
  const fake = await fakeAgent("plain", TEXT);
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result, events } = await drive(fake, cwd);
    assert.equal(result.output, TEXT, "no characters may be dropped across flushes");
    const joined = events
      .filter((e) => e.type === "text")
      .map((e) => (e.type === "text" ? e.content : ""))
      .join("");
    assert.equal(joined, TEXT);
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a permission request is answered so the turn cannot hang", async () => {
  const fake = await fakeAgent("permission");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const started = Date.now();
    const { result } = await drive(fake, cwd, { timeoutMs: 20_000 });

    /*
     * An unanswered `session/request_permission` hangs the turn until a watchdog
     * kills it, with no output to explain why. Kiro is launched with
     * `--trust-all-tools` and grok with `--always-approve`, but per-tool prompts can
     * still arrive, so the transport answers them itself.
     */
    assert.equal(result.status, "completed", result.error ?? "");
    assert.ok(Date.now() - started < 15_000, "it must not wait for a watchdog");
    // An allow-ish option is preferred over the reject offered first — picking the
    // first option blindly would deny every tool and produce useless runs.
    assert.match(result.output, /allow-always/);
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("tool calls surface as paired events", async () => {
  const fake = await fakeAgent("tool", "done");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result, events } = await drive(fake, cwd);
    assert.equal(result.status, "completed", result.error ?? "");

    const use = events.find((e) => e.type === "tool_use");
    const done = events.find((e) => e.type === "tool_result");
    assert.ok(use, "the tool call must be visible");
    assert.ok(done, "and so must its result");
    assert.equal(use.type === "tool_use" ? use.callId : "", "t1");
    assert.equal(done.type === "tool_result" ? done.output : "", "total 0");

    // Text is flushed BEFORE the tool event, so the timeline reads in the order
    // things actually happened rather than interleaved.
    const toolIndex = events.indexOf(use);
    const lateText = events.findIndex((e, i) => i > toolIndex && e.type === "text");
    assert.ok(lateText > toolIndex, "text after the tool call still appears after it");
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a refusal is reported as a failure", async () => {
  const fake = await fakeAgent("refusal", "partial");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result } = await drive(fake, cwd);
    // `end_turn` and a client cancel are the only clean stops; anything else is a
    // real failure and must not be reported as success.
    assert.equal(result.status, "failed");
    assert.match(result.error ?? "", /refusal/);
    // Whatever text did arrive is still handed back rather than discarded.
    assert.equal(result.output, "partial");
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a provider-reported cost is read from _meta", async () => {
  const fake = await fakeAgent("grok-usage", "ok");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result } = await drive(fake, cwd);
    assert.equal(result.status, "completed", result.error ?? "");
    assert.equal(result.usage.inputTokens, 1234);
    assert.equal(result.usage.outputTokens, 56);
    /*
     * 42,000,000 ticks of 1e-10 USD = $0.0042. The provider's own figure beats any
     * local estimate: xAI bills a request at 2x once its prompt reaches 200K tokens,
     * and aggregated token counts cannot say which requests crossed that line.
     */
    assert.ok(
      Math.abs(result.usage.costUsd - 0.0042) < 1e-9,
      `costUsd was ${result.usage.costUsd}, expected 0.0042`,
    );
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a stalled handshake fails fast instead of hanging", async () => {
  const fake = await fakeAgent("hang-handshake");
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const started = Date.now();
    const { result } = await drive(fake, cwd, { handshakeTimeoutMs: 1_500, timeoutMs: 60_000 });
    const elapsed = Date.now() - started;

    // A wedged startup must not consume the full wall-clock budget; the handshake
    // has its own, much shorter bound.
    assert.equal(result.status, "timeout");
    assert.ok(elapsed < 20_000, `took ${elapsed}ms — the handshake bound did not apply`);
    assert.match(result.error ?? "", /initialize|timed out/i);
  } finally {
    await fake.dispose();
    await rm(cwd, { recursive: true, force: true });
  }
});

test("a missing executable fails without throwing", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "acp-cwd-"));
  try {
    const { result } = await drive({ path: join(cwd, "nope"), dispose: async () => {} }, cwd, {
      handshakeTimeoutMs: 3_000,
    });
    // A throw here would take down the whole pipeline rather than one subtask.
    assert.notEqual(result.status, "completed");
    assert.ok((result.error ?? "").length > 0);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});
