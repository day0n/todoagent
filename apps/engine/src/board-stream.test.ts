import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Integration test for `GET /api/stream`, the board invalidation channel.
 *
 * Boots the real engine and reads raw SSE bytes, for the same reason the run
 * stream's suite does: the thing under test is the wire format, and a mocked
 * transport cannot tell you whether a browser's EventSource would deliver these
 * frames to `onmessage`.
 *
 * The design being pinned here is that this stream carries INVALIDATION and no
 * data. So the assertions are about when a signal fires and when it must stay
 * silent — not about payload contents, of which there are deliberately none.
 */

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SERVER = join(HERE, "server.ts");
/*
 * 8816: above every other suite's port (8799–8814) and the 8787 default.
 *
 * Not 8801 — that is reconcile's. Node runs test FILES in parallel, so a shared
 * port means two engines race to bind it: one dies with "other side closed" and
 * the survivor answers the other suite's requests from a database that has none
 * of its rows, which surfaces as a scatter of unrelated 404s. Cost 11 failures in
 * suites this file never touches.
 */
const PORT = 8816;

interface Harness {
  runId: string;
  listId: string;
  child: ChildProcess;
  dispose: () => Promise<void>;
}

async function boot(): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), "todoagent-board-sse-"));
  const dbPath = join(dir, "board.db");

  const store = new Store(dbPath);
  const list = store.createChannel({
    name: "工作",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
    color: null,
  });
  const project = store.createProject({
    name: "board",
    repoPath: dir,
    teamId: store.createTeam("board-team").id,
  });
  const run = store.createRun({ projectId: project.id, goal: "board fixture" });
  // A backlog on the run stream, so that test has something to read and can
  // distinguish "no board event" from "no events at all".
  store.appendEvent({ runId: run.id, attemptId: null, type: "phase:entered", payload: { phase: "plan" } });
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

  const deadline = Date.now() + 30_000;
  for (;;) {
    if (Date.now() > deadline) throw new Error("engine did not start within 30s");
    try {
      if ((await fetch(`http://127.0.0.1:${PORT}/api/health`)).ok) break;
    } catch {
      /* not listening yet */
    }
    await new Promise((r) => setTimeout(r, 150));
  }

  return {
    runId: run.id,
    listId: list.id,
    child,
    async dispose() {
      child.kill("SIGKILL");
      await rm(dir, { recursive: true, force: true });
    },
  };
}

/**
 * An open SSE connection whose frames can be awaited one at a time.
 *
 * Held open across a mutation, rather than the read-N-then-close helper the run
 * stream's suite uses: the sequence being tested is "listen, change something,
 * observe the signal", and a stream opened after the change would prove nothing
 * because this channel deliberately has no replay.
 */
interface Listener {
  /** Resolves with the next data frame, or null if none arrives in `ms`. */
  next(ms: number): Promise<Record<string, unknown> | null>;
  raw(): string;
  close(): void;
}

async function listen(url: string): Promise<Listener> {
  const controller = new AbortController();
  const res = await fetch(url, { signal: controller.signal });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type") ?? "", /text\/event-stream/);

  const reader = res.body?.getReader();
  assert.ok(reader, "the response must expose a readable body");

  const decoder = new TextDecoder();
  let raw = "";
  let cursor = 0; // bytes of `raw` already turned into frames
  const queue: Array<Record<string, unknown>> = [];

  /** Pulls complete frames out of the buffer, leaving any partial tail alone. */
  const drain = (): void => {
    for (;;) {
      const at = raw.indexOf("\n\n", cursor);
      if (at === -1) return;
      const chunk = raw.slice(cursor, at);
      cursor = at + 2;
      const dataLine = chunk.split("\n").find((l) => l.startsWith("data: "));
      // Comment frames (`: keepalive`) have no data line and are skipped.
      if (dataLine === undefined) continue;
      try {
        queue.push(JSON.parse(dataLine.slice(6)) as Record<string, unknown>);
      } catch {
        /* not valid JSON; not something this stream sends */
      }
    }
  };

  let done = false;
  const pump = (async () => {
    try {
      for (;;) {
        const r = await reader.read();
        if (r.done) break;
        raw += decoder.decode(r.value, { stream: true });
        drain();
      }
    } catch {
      /* aborted, which is how this ends */
    } finally {
      done = true;
    }
  })();

  return {
    async next(ms: number) {
      const deadline = Date.now() + ms;
      for (;;) {
        const head = queue.shift();
        if (head !== undefined) return head;
        if (done) return null;
        if (Date.now() > deadline) return null;
        await new Promise((r) => setTimeout(r, 20));
      }
    },
    raw: () => raw,
    close() {
      controller.abort();
      void pump;
    },
  };
}

function req(path: string, method: string, body?: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${PORT}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

test("stream: announces itself, then signals on a task write", async () => {
  const h = await boot();
  const stream = await listen(`http://127.0.0.1:${PORT}/api/stream`);
  try {
    /*
     * The opening frame exists because EventSource does not fire `onopen` until
     * the body starts arriving, and the server does not flush headers on their
     * own. Without it the client cannot distinguish "connected and idle" from
     * "still connecting", and would sit on its fast polling fallback while a
     * perfectly good stream was open.
     */
    const ready = await stream.next(5_000);
    assert.equal(ready?.["type"], "stream:ready", "the stream announces itself immediately");

    const created = await req("/api/tasks", "POST", { title: "买猫粮", listId: h.listId });
    assert.equal(created.status, 201);

    const signal = await stream.next(5_000);
    assert.equal(signal?.["type"], "board:changed", "a task write reaches the stream");

    // No named event field: EventSource routes a named event only to a matching
    // addEventListener, never to `onmessage`, so naming it would force the client
    // to keep a list that silently drifts out of date.
    assert.ok(!stream.raw().includes("\nevent: "), "no frame may carry a named event type");

    // A PATCH and a DELETE are writes too — every mutating route is covered, not
    // just the one the middleware was first written for.
    const task = (await created.json()) as { id: string };
    await req(`/api/tasks/${task.id}`, "PATCH", { status: "done" });
    assert.equal((await stream.next(5_000))?.["type"], "board:changed", "PATCH signals");

    await req(`/api/tasks/${task.id}`, "DELETE");
    assert.equal((await stream.next(5_000))?.["type"], "board:changed", "DELETE signals");

    // Lists share the channel: the sidebar's counts move on a list write too.
    await req("/api/lists", "POST", { name: "灵光一现" });
    assert.equal((await stream.next(5_000))?.["type"], "board:changed", "a list write signals");
  } finally {
    stream.close();
    await h.dispose();
  }
});

test("stream: stays silent for reads and for refusals", async () => {
  const h = await boot();
  const stream = await listen(`http://127.0.0.1:${PORT}/api/stream`);
  try {
    assert.equal((await stream.next(5_000))?.["type"], "stream:ready");

    // A read changes nothing.
    await req("/api/lists", "GET");
    await req(`/api/tasks?view=list:${h.listId}`, "GET");

    /*
     * ...and neither does a refusal. This is the case worth pinning: dispatch
     * answering 409 because the repository is locked, or 400 because the list has
     * no repo, must not tell every open window to re-read state that is exactly as
     * they left it. Publishing on the way out of the middleware without checking
     * the status would do precisely that.
     */
    const badBody = await req("/api/tasks", "POST", { title: "" });
    assert.equal(badBody.status, 400);
    const unknownTask = await req("/api/tasks/nope", "PATCH", { status: "done" });
    assert.equal(unknownTask.status, 404);
    const unknownDelete = await req("/api/tasks/nope", "DELETE");
    assert.equal(unknownDelete.status, 404);

    /*
     * A negative assertion, and a sound one despite the timeout: the publish is
     * synchronous in the middleware immediately after the handler returns, so a
     * signal that is going to arrive arrives in microseconds. A full second is
     * three orders of magnitude of headroom.
     */
    const quiet = await stream.next(1_000);
    assert.equal(quiet, null, `nothing should have been announced, got ${JSON.stringify(quiet)}`);
  } finally {
    stream.close();
    await h.dispose();
  }
});

test("stream: board events do not leak into a run's event stream", async () => {
  /*
   * The isolation this design depends on.
   *
   * `bus.publish` fans a BusEvent out on both `ev.runId` and `"*"`, and
   * `/api/runs/:id/events` subscribes by run id — so a board event published as a
   * BusEvent with any run id at all would surface in that run's stream, where the
   * web client parses every frame as a run event and derives the phase rail and
   * the verification report from them. `publishBoard` uses its own channel so the
   * leak is impossible rather than merely unlikely, and this is the assertion that
   * says so.
   */
  const h = await boot();
  const runStream = await listen(`http://127.0.0.1:${PORT}/api/runs/${h.runId}/events`);
  try {
    // The seeded backlog, so a silent stream cannot be mistaken for a working one.
    const first = await runStream.next(5_000);
    assert.equal(first?.["type"], "phase:entered", "the run stream replays its own backlog");

    // Three board mutations, none of which belong to this run.
    await req("/api/tasks", "POST", { title: "任务一", listId: h.listId });
    await req("/api/lists", "POST", { name: "任务二的清单" });
    await req(`/api/lists/${h.listId}`, "PATCH", { name: "改名" });

    for (;;) {
      const frame = await runStream.next(1_000);
      if (frame === null) break;
      assert.notEqual(
        frame["type"],
        "board:changed",
        "a board event must never appear in a run's stream",
      );
    }
  } finally {
    runStream.close();
    await h.dispose();
  }
});
