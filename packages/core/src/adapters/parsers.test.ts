import assert from "node:assert/strict";
import { test } from "node:test";
import { newLineContext } from "./process.ts";
import { parseClaudeLine } from "./claude.ts";
import { parseCodexLine } from "./codex.ts";
import { parseCursorLine } from "./cursor.ts";
import { filterBlockedArgs } from "./types.ts";

/**
 * Fixtures below are VERBATIM lines captured from the real CLIs on this machine
 * (claude 2.1.220, codex-cli 0.146.0). Hand-written fixtures would encode what
 * I assumed the protocol looks like, which is exactly the bug class these tests
 * need to catch.
 */

// ── codex: the trap ─────────────────────────────────────────

test("codex: an item of type error is a warning, not a failed turn", () => {
  const ctx = newLineContext();
  // Verbatim from a stock local install. Both of these appear on a run that
  // completes perfectly well.
  const lines = [
    `{"type":"thread.started","thread_id":"019fb841-c36e-7253-8da8-ee5a23644a75"}`,
    `{"type":"item.completed","item":{"id":"item_0","type":"error","message":"clamping SessionEnd hook timeout to 3s in /Users/x/.codex/hooks.json"}}`,
    `{"type":"turn.started"}`,
    `{"type":"item.completed","item":{"id":"item_1","type":"error","message":"Skill descriptions were shortened to fit the 2% skills context budget."}}`,
    `{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"OK"}}`,
    `{"type":"turn.completed","usage":{"input_tokens":19049,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}`,
  ];
  for (const l of lines) parseCodexLine(l, ctx);

  // The critical assertion: mapping these to failure would mark essentially
  // every codex run failed on a normally-configured machine.
  assert.equal(ctx.failure, null, "benign warnings must not set failure");
  assert.equal(ctx.warnings.length, 2, "they should still be recorded");
  assert.equal(ctx.turnCompleted, true);
  assert.equal(ctx.lastText, "OK");
  assert.equal(ctx.sessionId, "019fb841-c36e-7253-8da8-ee5a23644a75");
  assert.equal(ctx.usage.inputTokens, 19049);
  assert.equal(ctx.usage.cacheReadTokens, 11008);
});

test("codex: turn.failed is a real failure", () => {
  const ctx = newLineContext();
  const evs = parseCodexLine(`{"type":"turn.failed","error":{"message":"model overloaded"}}`, ctx);
  assert.equal(ctx.failure, "model overloaded");
  assert.deepEqual(evs, [{ type: "error", message: "model overloaded" }]);
});

test("codex: only completed items yield settled content", () => {
  const ctx = newLineContext();
  const started = parseCodexLine(
    `{"type":"item.started","item":{"id":"i1","type":"agent_message","text":"partial"}}`,
    ctx,
  );
  assert.equal(started, null, "a started message would duplicate the completed one");
  assert.equal(ctx.lastText, "");
});

test("codex: command_execution maps to a tool pair", () => {
  const ctx = newLineContext();
  const start = parseCodexLine(
    `{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls -la"}}`,
    ctx,
  );
  assert.deepEqual(start, [{ type: "tool_use", tool: "shell", callId: "c1", input: { command: "ls -la" } }]);
  const done = parseCodexLine(
    `{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls -la","aggregated_output":"total 0"}}`,
    ctx,
  );
  assert.deepEqual(done, [{ type: "tool_result", tool: "shell", callId: "c1", output: "total 0" }]);
});

// ── claude: field order and hook noise ──────────────────────

test("claude: the result event is recognized despite type arriving last", () => {
  const ctx = newLineContext();
  // Verbatim shape: `"type":"result"` sits near the END of the object, so any
  // parser that peeks at a prefix or relies on key order misses the terminal
  // event entirely and the run looks like it never finished.
  const line = `{"is_error":false,"duration_api_ms":4341,"num_turns":1,"session_id":"cabb3fb8","total_cost_usd":0.181785,"usage":{"input_tokens":36352,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1},"subtype":"success","result":"OK","type":"result","duration_ms":5018}`;
  const evs = parseClaudeLine(line, ctx);
  assert.equal(ctx.turnCompleted, true, "terminal event must be detected");
  assert.equal(ctx.lastText, "OK");
  assert.equal(ctx.sessionId, "cabb3fb8");
  assert.equal(ctx.usage.inputTokens, 36352);
  assert.equal(ctx.usage.costUsd, 0.181785);
  assert.deepEqual(evs, [{ type: "status", status: "done" }]);
});

test("claude: hook lifecycle chatter never reaches the timeline", () => {
  const ctx = newLineContext();
  const hookStart = parseClaudeLine(
    `{"type":"system","subtype":"hook_started","hook_id":"39d2649c","hook_name":"SessionStart:startup","session_id":"s1"}`,
    ctx,
  );
  const hookResp = parseClaudeLine(
    `{"type":"system","subtype":"hook_response","hook_id":"39d2649c","output":"OK\\n","exit_code":0,"session_id":"s1"}`,
    ctx,
  );
  assert.equal(hookStart, null, "hook noise is not agent output");
  assert.equal(hookResp, null);
  // Session id is still harvested from the noise, which is useful.
  assert.equal(ctx.sessionId, "s1");
});

test("claude: init yields a status carrying the session id", () => {
  const ctx = newLineContext();
  const evs = parseClaudeLine(`{"type":"system","subtype":"init","cwd":"/tmp","session_id":"abc","tools":["Bash"]}`, ctx);
  assert.deepEqual(evs, [{ type: "status", status: "init", sessionId: "abc" }]);
});

test("claude: is_error on the result sets failure", () => {
  const ctx = newLineContext();
  const evs = parseClaudeLine(`{"is_error":true,"result":"boom","type":"result","session_id":"s"}`, ctx);
  assert.equal(ctx.failure, "boom");
  assert.equal(evs?.[0]?.type, "error");
});

test("claude: assistant text and tool_use blocks both surface", () => {
  const ctx = newLineContext();
  const evs = parseClaudeLine(
    `{"type":"assistant","message":{"content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},"session_id":"s"}`,
    ctx,
  );
  assert.equal(evs?.length, 2);
  assert.deepEqual(evs?.[0], { type: "text", content: "hello" });
  assert.equal(evs?.[1]?.type, "tool_use");
  assert.equal(ctx.lastText, "hello");
});

// ── cursor: dual casing ─────────────────────────────────────

test("cursor: usage is read in either snake_case or camelCase", () => {
  const snake = newLineContext();
  parseCursorLine(`{"type":"result","result":"ok","input_tokens":10,"output_tokens":20,"session_id":"s"}`, snake);
  assert.equal(snake.usage.inputTokens, 10);
  assert.equal(snake.usage.outputTokens, 20);

  const camel = newLineContext();
  parseCursorLine(`{"type":"result","result":"ok","inputTokens":11,"outputTokens":22,"session_id":"s"}`, camel);
  assert.equal(camel.usage.inputTokens, 11, "camelCase must not silently record zero");
  assert.equal(camel.usage.outputTokens, 22);
});

test("cursor: thinking deltas are dropped, settled blocks kept", () => {
  const ctx = newLineContext();
  assert.equal(parseCursorLine(`{"type":"thinking","subtype":"delta","text":"a"}`, ctx), null);
  const done = parseCursorLine(`{"type":"thinking","subtype":"completed","text":"reasoned"}`, ctx);
  assert.deepEqual(done, [{ type: "thinking", content: "reasoned" }]);
});

// ── shared parser robustness ────────────────────────────────

test("all parsers ignore non-JSON banner noise instead of throwing", () => {
  const noise = ["", "   ", "Loading...", "warning: something", "not json at all", "[]"];
  for (const line of noise) {
    for (const parse of [parseClaudeLine, parseCodexLine, parseCursorLine]) {
      const ctx = newLineContext();
      assert.doesNotThrow(() => parse(line, ctx), `${parse.name} threw on ${JSON.stringify(line)}`);
      assert.equal(parse(line, ctx), null);
    }
  }
});

test("all parsers survive a truncated line", () => {
  // A killed process can leave a half-written line in the pipe.
  const truncated = `{"type":"assistant","message":{"content":[{"type":"text","text":"hel`;
  for (const parse of [parseClaudeLine, parseCodexLine, parseCursorLine]) {
    const ctx = newLineContext();
    assert.doesNotThrow(() => parse(truncated, ctx));
  }
});

test("parsers tolerate a null message body", () => {
  const ctx = newLineContext();
  assert.doesNotThrow(() => parseClaudeLine(`{"type":"assistant","message":null}`, ctx));
  assert.equal(parseClaudeLine(`{"type":"assistant","message":null}`, ctx), null);
});

// ── blocked args ────────────────────────────────────────────

test("blocked args cannot be spoofed by a user", () => {
  const blocked = { "--output-format": "withValue", "--yolo": "standalone" } as const;
  const { kept, dropped } = filterBlockedArgs(
    ["--output-format", "text", "--yolo", "--model-alias", "x"],
    blocked,
  );
  // Silently switching off the streaming protocol would kill the parse chain
  // without any error surfacing.
  assert.deepEqual(kept, ["--model-alias", "x"]);
  assert.deepEqual(dropped, ["--output-format", "text", "--yolo"]);
});

test("blocked args also catch the --flag=value form", () => {
  const { kept, dropped } = filterBlockedArgs(["--output-format=text", "--keep"], {
    "--output-format": "withValue",
  });
  assert.deepEqual(kept, ["--keep"]);
  assert.deepEqual(dropped, ["--output-format=text"]);
});

test("a blocked withValue flag does not swallow a following flag", () => {
  const { kept } = filterBlockedArgs(["--model", "--verbose"], { "--model": "withValue" });
  // "--verbose" starts with a dash, so it is a flag rather than --model's value.
  assert.deepEqual(kept, ["--verbose"]);
});
