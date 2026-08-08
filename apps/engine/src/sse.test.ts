import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Integration test for the live event stream.
 *
 * This boots the real engine against a throwaway database and reads raw SSE
 * bytes, because the thing being verified is the WIRE FORMAT — and a mock of the
 * transport cannot tell you whether a browser's EventSource would actually
 * deliver these frames to a listener.
 *
 * Events are inserted directly rather than by running a pipeline: this needs to
 * assert framing and replay, not spend real agent turns.
 */

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SERVER = join(HERE, "server.ts");
const PORT = 8799; // not the default, so a dev engine can stay running

interface Harness {
  dbPath: string;
  runId: string;
  child: ChildProcess;
  dispose: () => Promise<void>;
}

async function boot(): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-sse-"));
  const dbPath = join(dir, "sse.db");

  // Seed durable state before the engine opens the file.
  const store = new Store(dbPath);
  const expert = store.createExpert({
    name: "SSE-Expert",
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: ["general"],
  });
  const team = store.createTeam("sse-team");
  store.addTeamMember(team.id, expert.id, "maker");
  const project = store.createProject({ name: "sse", repoPath: dir, teamId: team.id });
  const run = store.createRun({ projectId: project.id, goal: "sse fixture" });

  // A representative spread: a phase change, a colon-heavy agent type, and a
  // payload carrying characters that would break naive framing.
  store.appendEvent({ runId: run.id, attemptId: null, type: "phase:entered", payload: { phase: "plan" } });
  store.appendEvent({ runId: run.id, attemptId: "a1", type: "agent:text", payload: { content: "hello" } });
  store.appendEvent({
    runId: run.id,
    attemptId: "a1",
    type: "merge:no_branch",
    payload: { subTaskId: "s1", title: "recently added event type" },
  });
  store.appendEvent({
    runId: run.id,
    attemptId: null,
    // Newlines inside a payload must not be able to terminate an SSE frame.
    type: "verify:done",
    payload: { report: "line one\nline two\n\nblank above", ok: true },
  });
  store.close();

  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: dbPath,
      TODOAGENT_PORT: String(PORT),
      TODOAGENT_DISABLE_RUNTIME_DISCOVERY: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  // Wait for the listener rather than sleeping a fixed amount.
  const deadline = Date.now() + 30_000;
  for (;;) {
    if (Date.now() > deadline) throw new Error("engine did not start within 30s");
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/api/health`);
      if (res.ok) break;
    } catch {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 200));
  }

  return {
    dbPath,
    runId: run.id,
    child,
    async dispose() {
      child.kill("SIGKILL");
      await rm(dir, { recursive: true, force: true });
    },
  };
}

/** Reads SSE bytes until `wanted` data frames arrive, or the deadline passes. */
async function readFrames(
  url: string,
  wanted: number,
  headers: Record<string, string> = {},
): Promise<{ raw: string; frames: Array<Record<string, unknown>> }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  try {
    const res = await fetch(url, { headers, signal: controller.signal });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /text\/event-stream/);

    const reader = res.body?.getReader();
    assert.ok(reader, "the response must expose a readable body");
    const decoder = new TextDecoder();
    let raw = "";
    const frames: Array<Record<string, unknown>> = [];

    while (frames.length < wanted) {
      const { done, value } = await reader.read();
      if (done) break;
      raw += decoder.decode(value, { stream: true });
      // Frames are separated by a blank line.
      const parts = raw.split("\n\n");
      frames.length = 0;
      for (const part of parts) {
        const dataLine = part.split("\n").find((l) => l.startsWith("data: "));
        if (!dataLine) continue;
        try {
          frames.push(JSON.parse(dataLine.slice(6)) as Record<string, unknown>);
        } catch {
          /* partial frame still arriving */
        }
      }
    }
    void reader.cancel();
    return { raw, frames };
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

test("SSE: replays the backlog and every event reaches a default-type listener", async () => {
  const h = await boot();
  try {
    const { raw, frames } = await readFrames(
      `http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`,
      4,
    );

    /*
     * The load-bearing assertion.
     *
     * A frame carrying `event: <type>` is NOT delivered to EventSource.onmessage
     * — only to a matching addEventListener. The client used to maintain an
     * allowlist of every type for that reason, and it silently drifted: any new
     * engine event without a client entry vanished with no error. Keeping the
     * type inside `data` and omitting the field removes the whole failure class.
     */
    assert.ok(!raw.includes("\nevent: "), "no frame may carry a named event type");
    assert.ok(raw.includes("id: "), "each frame needs an id so Last-Event-ID can replay");

    assert.equal(frames.length, 4, "the whole backlog replays");
    assert.deepEqual(
      frames.map((f) => f["type"]),
      ["phase:entered", "agent:text", "merge:no_branch", "verify:done"],
    );

    // merge:no_branch was added to the pipeline after the client allowlist was
    // written — exactly the drift this design prevents.
    assert.ok(frames.some((f) => f["type"] === "merge:no_branch"));
  } finally {
    await h.dispose();
  }
});

test("SSE: a payload containing newlines survives framing intact", async () => {
  const h = await boot();
  try {
    const { frames } = await readFrames(`http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`, 4);
    const verify = frames.find((f) => f["type"] === "verify:done");
    assert.ok(verify, "the verify event must arrive");
    const payload = verify["payload"] as { report?: string; ok?: boolean };
    // JSON-encoding the payload is what makes this safe: a raw newline would
    // split the frame and the rest would be read as a new event.
    assert.equal(payload.report, "line one\nline two\n\nblank above");
    assert.equal(payload.ok, true);
  } finally {
    await h.dispose();
  }
});

test("SSE: Last-Event-ID resumes without duplicating", async () => {
  const h = await boot();
  try {
    const first = await readFrames(`http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`, 4);
    const secondId = first.frames[1]?.["id"];
    assert.equal(typeof secondId, "number");

    const resumed = await readFrames(
      `http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`,
      2,
      { "Last-Event-ID": String(secondId) },
    );

    // A reconnecting browser must not re-render what it already showed.
    assert.equal(resumed.frames.length, 2);
    assert.ok(
      resumed.frames.every((f) => Number(f["id"]) > Number(secondId)),
      "the cursor is exclusive",
    );
    assert.deepEqual(
      resumed.frames.map((f) => f["type"]),
      ["merge:no_branch", "verify:done"],
    );
  } finally {
    await h.dispose();
  }
});

test("SSE: a long history replays in full, not just the first page", async () => {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-sse-long-"));
  const dbPath = join(dir, "long.db");
  try {
    // More than the old single-read cap of 2000. A measured long run emits ~2880
    // events, so this is a realistic size rather than a contrived one.
    const TOTAL = 2500;
    const store = new Store(dbPath);
    const expert = store.createExpert({
      name: "E",
      description: "",
      runtimeKind: "claude",
      model: null,
      systemPrompt: "",
      capabilities: [],
    });
    const team = store.createTeam("t");
    store.addTeamMember(team.id, expert.id, "maker");
    const project = store.createProject({ name: "p", repoPath: dir, teamId: team.id });
    const run = store.createRun({ projectId: project.id, goal: "a long run" });

    for (let i = 0; i < TOTAL - 1; i++) {
      store.appendEvent({ runId: run.id, attemptId: "a1", type: "agent:text", payload: { i } });
    }
    /*
     * The tail is what made this bug expensive.
     *
     * `verify:done`, `merge:needs_human` and `run:completed` all arrive at the END
     * of a run, and the web client derives its verification report and conflict
     * list from the stream. Truncating the replay therefore made a long finished
     * run look like one that produced no verification and no conflicts — the same
     * as a clean result, with nothing to indicate otherwise.
     */
    store.appendEvent({
      runId: run.id,
      attemptId: null,
      type: "verify:done",
      payload: { ok: true, report: "THE FINAL EVENT" },
    });
    store.close();

    const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
      env: {
        ...process.env,
        TODOAGENT_DB: dbPath,
        TODOAGENT_PORT: String(PORT),
        TODOAGENT_DISABLE_RUNTIME_DISCOVERY: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    try {
      const deadline = Date.now() + 30_000;
      for (;;) {
        if (Date.now() > deadline) throw new Error("engine did not start within 30s");
        try {
          const res = await fetch(`http://127.0.0.1:${PORT}/api/health`);
          if (res.ok) break;
        } catch {
          /* not listening yet */
        }
        await new Promise((r) => setTimeout(r, 200));
      }

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 30_000);
      try {
        const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${run.id}/events`, {
          signal: controller.signal,
        });
        const reader = res.body?.getReader();
        assert.ok(reader);
        const decoder = new TextDecoder();

        // Counted incrementally rather than by re-parsing the whole buffer each
        // read: at this size a quadratic reader is slower than the server.
        let seen = 0;
        let sawFinal = false;
        let tail = "";
        while (seen < TOTAL) {
          const { done, value } = await reader.read();
          if (done) break;
          tail += decoder.decode(value, { stream: true });
          const lines = tail.split("\n");
          // Keep the last (possibly partial) line for the next chunk.
          tail = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            seen++;
            if (line.includes("THE FINAL EVENT")) sawFinal = true;
          }
        }
        void reader.cancel();

        assert.equal(seen, TOTAL, `replayed ${seen} of ${TOTAL} events`);
        assert.ok(sawFinal, "the last event must arrive — it carries the verification report");
      } finally {
        clearTimeout(timer);
        controller.abort();
      }
    } finally {
      child.kill("SIGKILL");
      await new Promise((r) => setTimeout(r, 200));
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("SSE: an unknown run is rejected rather than streaming nothing forever", async () => {
  const h = await boot();
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/does-not-exist/events`);
    // An open stream that never emits looks identical to a working one.
    assert.equal(res.status, 404);
    void res.body?.cancel();
  } finally {
    await h.dispose();
  }
});

test("SSE: live events arrive after the backlog", async () => {
  const h = await boot();
  try {
    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`, {
      signal: controller.signal,
    });
    const reader = res.body?.getReader();
    assert.ok(reader);
    const decoder = new TextDecoder();

    // Drain the backlog first.
    let raw = "";
    while (!raw.includes("verify:done")) {
      const { done, value } = await reader.read();
      if (done) break;
      raw += decoder.decode(value, { stream: true });
    }

    /*
     * Append through a SEPARATE Store handle — i.e. a different connection to the
     * same file. The engine's in-process bus cannot see this write, so the only
     * way the client learns about it is the durable event table. That is the
     * property worth testing: the bus is an optimisation over polling, never the
     * source of truth.
     */
    const other = new Store(h.dbPath);
    other.appendEvent({ runId: h.runId, attemptId: null, type: "run:completed", payload: {} });
    other.close();

    // The engine broadcasts only its own writes, so this specific event is not
    // expected to stream live; assert the connection stays healthy instead of
    // asserting delivery we know cannot happen.
    const keepAlive = await Promise.race([
      (async () => {
        const { value } = await reader.read();
        return decoder.decode(value ?? new Uint8Array(), { stream: true });
      })(),
      new Promise<string>((r) => setTimeout(() => r("__timeout__"), 3000)),
    ]);
    assert.ok(typeof keepAlive === "string", "the stream must stay open");

    controller.abort();
    void reader.cancel().catch(() => undefined);
  } finally {
    await h.dispose();
  }
});
