import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { Store } from "../db/index.ts";
import { MAX_EVENT_STRING, boundPayload, runOne } from "./runner.ts";

/**
 * Event payloads are bounded; the durable transcript is not.
 *
 * Adapters cap tool OUTPUT at 20k, but text and thinking content were unbounded —
 * an agent that dumps a large file into its reply wrote the whole thing into the
 * event log and then pushed it down every open SSE connection as one frame.
 *
 * The pairing is the point, and it is what these tests check: the STREAM is
 * trimmed so the log and the live feed stay usable, while `attempt.output` keeps
 * the full text so nothing is actually lost. Trimming both would be data loss
 * dressed up as a performance fix.
 *
 * Driven through `runOne` with a fake CLI on PATH, so the assertions cover the
 * real path rather than a helper in isolation.
 */

const HUGE = 60_000;

interface Fixture {
  store: Store;
  runId: string;
  expertId: string;
  cwd: string;
  dispose: () => Promise<void>;
}

/**
 * A fake `claude` that emits one enormous payload, then a terminal result.
 *
 * `mode: "tool"` puts the huge string inside a tool_use `input` object. That case
 * matters specifically: the claude adapter caps tool_result output at 20k but
 * passes tool_use `input` through untouched, so a nested guard is the only thing
 * standing between a large file write and an enormous event row.
 */
function fakeScript(chars: number, mode: "text" | "tool" = "text"): string {
  const block =
    mode === "tool"
      ? `{ type: "tool_use", id: "t1", name: "Write", input: { file_path: "/tmp/x.ts", content: big, meta: { note: big } } }`
      : `{ type: "text", text: big }`;
  return `#!/usr/bin/env node
const big = "x".repeat(${chars});
process.stdout.write(JSON.stringify({
  type: "assistant",
  message: { content: [${block}] },
  session_id: "fake",
}) + "\\n");
process.stdout.write(JSON.stringify({
  is_error: false,
  session_id: "fake",
  result: big,
  usage: { input_tokens: 10, output_tokens: 5 },
  type: "result",
}) + "\\n");
`;
}

async function fixture(chars: number, mode: "text" | "tool" = "text"): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-bounds-"));
  const binDir = join(root, "bin");
  await mkdir(binDir, { recursive: true });
  const fake = join(binDir, "claude");
  await writeFile(fake, fakeScript(chars, mode), "utf8");
  await chmod(fake, 0o755);

  const originalPath = process.env["PATH"] ?? "";
  process.env["PATH"] = `${binDir}${delimiter}${originalPath}`;

  const store = new Store(join(root, "b.db"));
  const expert = store.createExpert({
    name: "Verbose",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
  const team = store.createTeam("t");
  store.addTeamMember(team.id, expert.id, "maker");
  const project = store.createProject({ name: "p", repoPath: root, teamId: team.id });
  const run = store.createRun({ projectId: project.id, goal: "g" });

  return {
    store,
    runId: run.id,
    expertId: expert.id,
    cwd: root,
    async dispose() {
      process.env["PATH"] = originalPath;
      store.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

test("a huge text event is trimmed in the log but kept whole in the transcript", async () => {
  const f = await fixture(HUGE);
  try {
    const expert = f.store.getExpert(f.expertId);
    assert.ok(expert);

    const res = await runOne({
      store: f.store,
      runId: f.runId,
      expert,
      kind: "draft",
      subTaskId: null,
      prompt: "say a lot",
      cwd: f.cwd,
      timeoutMs: 60_000,
    });
    assert.equal(res.ok, true, res.error ?? "");

    // ── The stream is bounded ──
    const events = f.store.eventsAfter(f.runId, 0, 500);
    const textEvents = events.filter((e) => e.type === "agent:text");
    assert.ok(textEvents.length > 0, "the text event was recorded");

    for (const ev of textEvents) {
      const content = (ev.payload as { content?: string }).content ?? "";
      /*
       * A little over the cap is expected: the truncation notice is appended after
       * the cut, so the stored string is `MAX_EVENT_STRING` plus that marker.
       */
      assert.ok(
        content.length < MAX_EVENT_STRING + 500,
        `event content was ${content.length} chars, cap is ${MAX_EVENT_STRING}`,
      );
      // Marked, because a transcript that simply stops looks like an agent that
      // stopped — a materially different diagnosis.
      assert.match(content, /truncated/);
      // And it points at where the full text lives.
      assert.match(content, /transcript/);
    }

    // ── The durable copy is NOT bounded ──
    const attempt = f.store.getAttempt(res.attemptId);
    assert.ok(attempt);
    assert.equal(
      attempt.output?.length,
      HUGE,
      "the full text must survive in attempt.output, or this is data loss rather than trimming",
    );
  } finally {
    await f.dispose();
  }
});

test("ordinary output is left completely untouched", async () => {
  // The cap has to be generous enough that normal agent chatter never sees it;
  // otherwise every transcript in the UI would carry a truncation notice.
  const SMALL = 2_000;
  const f = await fixture(SMALL);
  try {
    const expert = f.store.getExpert(f.expertId);
    assert.ok(expert);

    const res = await runOne({
      store: f.store,
      runId: f.runId,
      expert,
      kind: "draft",
      subTaskId: null,
      prompt: "say a normal amount",
      cwd: f.cwd,
      timeoutMs: 60_000,
    });
    assert.equal(res.ok, true, res.error ?? "");

    const textEvents = f.store
      .eventsAfter(f.runId, 0, 500)
      .filter((e) => e.type === "agent:text");
    assert.ok(textEvents.length > 0);
    for (const ev of textEvents) {
      const content = (ev.payload as { content?: string }).content ?? "";
      assert.equal(content.length, SMALL, "a normal-sized payload must pass through verbatim");
      assert.ok(!content.includes("truncated"));
    }
  } finally {
    await f.dispose();
  }
});

test("a huge string NESTED in a tool payload is bounded too", async () => {
  /*
   * The case a top-level-only guard would miss, and the one most likely to be
   * enormous in practice.
   *
   * The claude adapter caps tool_RESULT output at 20k but passes tool_USE `input`
   * through untouched — so a `Write` call carrying a whole generated file arrives
   * as an unbounded nested string. Walking the payload is the only thing between
   * that and a multi-megabyte event row pushed down every open SSE connection.
   */
  const f = await fixture(HUGE, "tool");
  try {
    const expert = f.store.getExpert(f.expertId);
    assert.ok(expert);

    const res = await runOne({
      store: f.store,
      runId: f.runId,
      expert,
      kind: "draft",
      subTaskId: null,
      prompt: "write a big file",
      cwd: f.cwd,
      timeoutMs: 60_000,
    });
    assert.equal(res.ok, true, res.error ?? "");

    const toolEvent = f.store
      .eventsAfter(f.runId, 0, 500)
      .find((e) => e.type === "agent:tool_use");
    assert.ok(toolEvent, "the tool_use event was recorded");

    const payload = toolEvent.payload as {
      tool?: string;
      input?: { file_path?: string; content?: string; meta?: { note?: string } };
    };

    // One level down.
    const content = payload.input?.content ?? "";
    assert.ok(
      content.length < MAX_EVENT_STRING + 500,
      `nested content was ${content.length} chars, cap is ${MAX_EVENT_STRING}`,
    );
    assert.match(content, /truncated/);

    // Two levels down — a single-level walk would have let this through.
    const note = payload.input?.meta?.note ?? "";
    assert.ok(note.length < MAX_EVENT_STRING + 500, `meta.note was ${note.length} chars`);
    assert.match(note, /truncated/);

    // Short siblings must survive verbatim, or the walk is destroying structure
    // rather than trimming excess.
    assert.equal(payload.input?.file_path, "/tmp/x.ts");
    assert.equal(payload.tool, "Write");
  } finally {
    await f.dispose();
  }
});

test("boundPayload leaves non-string values completely alone", () => {
  /*
   * Called directly, on purpose.
   *
   * A first version of this test used `store.appendEvent` and asserted the result —
   * which bypasses `boundPayload` entirely and only proves that JSON round-trips.
   * The test name claimed to check the walk while checking something else, which is
   * the failure mode this whole file exists to catch.
   *
   * Non-strings must survive untouched: the UI reads `ok`, `status` and token counts
   * off event payloads to decide what to render, so coercing a boolean or dropping a
   * number would silently change the display.
   */
  const input = {
    n: 42,
    t: true,
    f: false,
    nul: null,
    arr: [1, "two", null],
    nested: { deep: 7, deeper: { flag: false } },
    short: "fine",
  };
  assert.deepEqual(boundPayload(input), input);
});

test("boundPayload trims strings at any depth, including inside arrays", () => {
  const huge = "z".repeat(HUGE);
  const out = boundPayload({
    top: huge,
    nested: { mid: { deep: huge } },
    list: [huge, "short"],
    keep: 1,
  }) as {
    top: string;
    nested: { mid: { deep: string } };
    list: string[];
    keep: number;
  };

  for (const [label, value] of [
    ["top", out.top],
    ["nested.mid.deep", out.nested.mid.deep],
    ["list[0]", out.list[0] ?? ""],
  ] as const) {
    assert.ok(
      value.length < MAX_EVENT_STRING + 500,
      `${label} was ${value.length} chars, cap is ${MAX_EVENT_STRING}`,
    );
    assert.match(value, /truncated/);
  }
  // Arrays are walked without being reshaped, and short entries are untouched.
  assert.equal(out.list.length, 2);
  assert.equal(out.list[1], "short");
  assert.equal(out.keep, 1);
});

test("boundPayload handles a bare string and empty containers", () => {
  // A payload is not always an object — `agent:status` carries a plain string.
  assert.equal(boundPayload("short"), "short");
  assert.match(String(boundPayload("q".repeat(HUGE))), /truncated/);
  assert.deepEqual(boundPayload({}), {});
  assert.deepEqual(boundPayload([]), []);
  assert.equal(boundPayload(null), null);
  assert.equal(boundPayload(undefined), undefined);
});
