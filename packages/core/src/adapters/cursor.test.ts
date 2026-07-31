import assert from "node:assert/strict";
import { test } from "node:test";
import { newLineContext } from "./process.ts";
import { parseCursorLine } from "./cursor.ts";

/**
 * Cursor parsing, pinned to VERBATIM output from cursor-agent 2026.07.23.
 *
 * Every fixture below was captured by running a real task ("read app.ts, then write
 * note.txt") and copying the lines the CLI emitted. That matters: this parser was
 * originally written by translating Multica's Go struct definitions, and the shape
 * it assumed was wrong in a way no hand-written fixture would have revealed —
 * hand-written fixtures encode the author's assumptions, which is exactly what was
 * broken.
 *
 * The bug: there is no top-level `tool_name` and no top-level `output`. The tool is
 * identified by the KEY inside `tool_call` (`globToolCall`, `editToolCall`,
 * `readToolCall`) and its result is nested under `result.success`. Every cursor tool
 * call therefore rendered as "unknown" with empty output — a timeline that showed
 * the agent doing nothing legible, indistinguishable from one doing nothing.
 */

/*
 * NOTE on the ids below: `call_id` genuinely contains an embedded newline in cursor's
 * output. It is preserved rather than tidied, because a fixture that cleans up its
 * input stops testing the real thing.
 */
const TOOL_STARTED =
  '{"type":"tool_call","subtype":"started","call_id":"call-dd7bc1c7-0\\nfc_ouLrgyy-0","tool_call":{"globToolCall":{"args":{"globPattern":"**/app.ts"}},"hookAdditionalContexts":[],"toolCallId":"call-dd7bc1c7-0\\nfc_ouLrgyy-0","startedAtMs":"1785515118821"},"model_call_id":"e154b6ed-0-q6ej","session_id":"3608803c","timestamp_ms":1785515118818}';

const GLOB_COMPLETED =
  '{"type":"tool_call","subtype":"completed","call_id":"call-dd7bc1c7-0\\nfc_ouLrgyy-0","tool_call":{"globToolCall":{"args":{"globPattern":"**/app.ts"},"result":{"success":{"pattern":"","path":"","files":["./app.ts"],"totalFiles":1,"clientTruncated":false,"ripgrepTruncated":false}}},"hookAdditionalContexts":[],"toolCallId":"call-dd7bc1c7-0\\nfc_ouLrgyy-0","startedAtMs":"1785515118821","completedAtMs":"1785515119275"},"session_id":"3608803c","timestamp_ms":1785515119291}';

const EDIT_COMPLETED =
  '{"type":"tool_call","subtype":"completed","call_id":"call-dd7bc1c7-1","tool_call":{"editToolCall":{"args":{"path":"/tmp/cursor-probe/note.txt","streamContent":"DONE"},"result":{"success":{"path":"/tmp/cursor-probe/note.txt","linesAdded":1,"linesRemoved":0,"diffString":"--- /dev/null\\n+++ b//tmp/cursor-probe/note.txt\\n@@ -1,0 +1 @@\\n+DONE","afterFullFileContent":"DONE","message":"Wrote contents to /tmp/cursor-probe/note.txt"}}},"toolCallId":"call-dd7bc1c7-1","startedAtMs":"1785515118824","completedAtMs":"1785515120682"},"session_id":"3608803c","timestamp_ms":1785515120700}';

const READ_COMPLETED =
  '{"type":"tool_call","subtype":"completed","call_id":"call-130df6f6-2","tool_call":{"readToolCall":{"args":{"path":"/tmp/cursor-probe/app.ts"},"result":{"success":{"content":"export const version = 1;\\n","isEmpty":false,"exceededLimit":false,"totalLines":2,"fileSize":26,"path":"/tmp/cursor-probe/app.ts"}}},"toolCallId":"call-130df6f6-2","startedAtMs":"1785515122080","completedAtMs":"1785515123220"},"session_id":"3608803c","timestamp_ms":1785515123240}';

const RECONNECTING =
  '{"type":"connection","subtype":"reconnecting","session_id":"3608803c","timestamp_ms":1785515125191,"attempt":1,"endpoint_url":"https://agentn.global.api5.cursor.sh"}';

const RETRY_STARTING =
  '{"type":"retry","subtype":"starting","session_id":"3608803c","timestamp_ms":1785515127275,"attempt":1,"is_resume":true}';

const RESULT_SUCCESS =
  '{"type":"result","subtype":"success","duration_ms":18788,"duration_api_ms":18788,"is_error":false,"result":"Read app.ts and created note.txt.","session_id":"3608803c","request_id":"e154b6ed","usage":{"inputTokens":115,"outputTokens":18,"cacheReadTokens":19776,"cacheWriteTokens":0}}';

const SYSTEM_INIT =
  '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp/cursor-probe","session_id":"3608803c","model":"auto","permissionMode":"bypassPermissions"}';

test("the tool name comes from the nested key, not a tool_name field", () => {
  const ctx = newLineContext();
  const events = parseCursorLine(TOOL_STARTED, ctx);
  assert.ok(events);
  assert.equal(events.length, 1);
  const ev = events[0];
  assert.ok(ev?.type === "tool_use");

  /*
   * The regression this file exists for. Reading a non-existent `tool_name` yielded
   * "unknown" for every cursor tool call, so the timeline showed an agent doing
   * something unidentifiable.
   */
  assert.equal(ev.tool, "glob", `tool was ${JSON.stringify(ev.tool)}`);
  // The arguments come from the nested `args`, so a reviewer can see WHAT was run.
  assert.deepEqual(ev.input, { globPattern: "**/app.ts" });
  // The id is preserved verbatim, embedded newline and all.
  assert.match(ev.callId, /^call-dd7bc1c7-0\nfc_ouLrgyy-0$/);
});

test("a glob result renders its file list", () => {
  const ctx = newLineContext();
  const events = parseCursorLine(GLOB_COMPLETED, ctx);
  const ev = events?.[0];
  assert.ok(ev?.type === "tool_result");
  assert.equal(ev.tool, "glob");
  // There is no common `output` field; each tool's useful value sits at a different
  // key under result.success. For glob it is the file list.
  assert.equal(ev.output, "./app.ts");
});

test("an edit result renders its message", () => {
  const ctx = newLineContext();
  const ev = parseCursorLine(EDIT_COMPLETED, ctx)?.[0];
  assert.ok(ev?.type === "tool_result");
  assert.equal(ev.tool, "edit");
  // `message` is preferred over `diffString`: it states what happened in one line,
  // which is what belongs in a timeline.
  assert.equal(ev.output, "Wrote contents to /tmp/cursor-probe/note.txt");
});

test("a read result renders the file content", () => {
  const ctx = newLineContext();
  const ev = parseCursorLine(READ_COMPLETED, ctx)?.[0];
  assert.ok(ev?.type === "tool_result");
  assert.equal(ev.tool, "read");
  assert.equal(ev.output, "export const version = 1;\n");
});

test("an unknown tool shape stays legible instead of blank", () => {
  // Cursor will add tools. Falling back to JSON keeps the timeline useful, where an
  // empty string would look like a tool that did nothing.
  const ctx = newLineContext();
  const line =
    '{"type":"tool_call","subtype":"completed","call_id":"c9","tool_call":{"someFutureToolCall":{"args":{"x":1},"result":{"success":{"unexpected":"shape"}}},"toolCallId":"c9"}}';
  const ev = parseCursorLine(line, ctx)?.[0];
  assert.ok(ev?.type === "tool_result");
  assert.equal(ev.tool, "someFuture");
  assert.match(ev.output, /unexpected/);
});

test("a failed tool surfaces its error", () => {
  const ctx = newLineContext();
  const line =
    '{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/nope"},"result":{"error":{"message":"file not found"}}},"toolCallId":"c1"}}';
  const ev = parseCursorLine(line, ctx)?.[0];
  assert.ok(ev?.type === "tool_result");
  // A tool that errored is exactly what a reviewer needs to see, so it must not be
  // swallowed as an empty result.
  assert.match(ev.output, /file not found/);
});

test("connection churn and retries are surfaced, not swallowed", () => {
  /*
   * Both of these appeared in a single real capture — cursor drops and resumes its
   * own connection mid-turn. Dropping them silently made a genuine thirty-second
   * stall look identical to a hang, with nothing in the timeline to explain the gap.
   */
  const ctx = newLineContext();

  const reconnect = parseCursorLine(RECONNECTING, ctx)?.[0];
  assert.ok(reconnect?.type === "status");
  assert.match(reconnect.status, /connection/);
  assert.match(reconnect.status, /reconnecting/);
  assert.match(reconnect.status, /attempt 1/);

  const retry = parseCursorLine(RETRY_STARTING, ctx)?.[0];
  assert.ok(retry?.type === "status");
  assert.match(retry.status, /retry/);
  assert.match(retry.status, /starting/);
});

test("usage is read from the real camelCase result", () => {
  const ctx = newLineContext();
  parseCursorLine(RESULT_SUCCESS, ctx);

  /*
   * Confirms a guess made from Multica's Go source rather than observation: cursor
   * really does use camelCase here. The parser accepts both casings, so a version
   * that switches to snake_case will not silently record zeros.
   */
  assert.equal(ctx.usage.inputTokens, 115);
  assert.equal(ctx.usage.outputTokens, 18);
  assert.equal(ctx.usage.cacheReadTokens, 19776);
  assert.equal(ctx.turnCompleted, true);
  assert.equal(ctx.failure, null);
  assert.equal(ctx.lastText, "Read app.ts and created note.txt.");
});

test("the init line yields the session id", () => {
  const ctx = newLineContext();
  const ev = parseCursorLine(SYSTEM_INIT, ctx)?.[0];
  assert.ok(ev?.type === "status");
  assert.equal(ev.sessionId, "3608803c");
  assert.equal(ctx.sessionId, "3608803c");
});

test("a full captured transcript parses end to end", () => {
  // Ordered as the CLI actually emitted them, so the accumulated context reflects a
  // real turn rather than a hand-assembled one.
  const ctx = newLineContext();
  const lines = [
    SYSTEM_INIT,
    TOOL_STARTED,
    GLOB_COMPLETED,
    EDIT_COMPLETED,
    READ_COMPLETED,
    RECONNECTING,
    RETRY_STARTING,
    RESULT_SUCCESS,
  ];
  const events = lines.flatMap((l) => parseCursorLine(l, ctx) ?? []);

  assert.equal(ctx.turnCompleted, true);
  assert.equal(ctx.failure, null);
  assert.equal(ctx.usage.inputTokens, 115);

  // Not one tool call may be reported as unknown — that was the whole defect.
  const tools = events.filter((e) => e.type === "tool_use" || e.type === "tool_result");
  assert.equal(tools.length, 4);
  for (const t of tools) {
    const name = t.type === "tool_use" || t.type === "tool_result" ? t.tool : "";
    assert.notEqual(name, "unknown", `a tool was reported as unknown: ${JSON.stringify(t)}`);
    assert.ok(name.length > 0);
  }
});
