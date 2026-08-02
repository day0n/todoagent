import assert from "node:assert/strict";
import { test } from "node:test";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { Store } from "./db/index.ts";
import {
  MAX_AGENT_CHAIN,
  MAX_DELIVERY_TURNS,
  chatLoad,
  deliverMessage,
  replyToMessage,
} from "./chat.ts";
import type { Channel, Expert, Message } from "./types.ts";

/**
 * Agent replies in channels and DMs.
 *
 * Every test here runs a FAKE cli placed ahead of the real ones on PATH. Nothing
 * in this file may resolve or execute a user-installed agent — a default test
 * that shells out to the real `claude` would spend the user's quota and depend on
 * their machine.
 *
 * The loop guard gets the most attention because it is the one failure mode that
 * costs money while looking like the feature working: agents are told to address
 * each other by name, so one mentioning another produces a reply that mentions
 * the first, and nothing in the data model stops that on its own.
 */

/**
 * Every agent executable this repo can spawn.
 *
 * The fixture shadows ALL of them, so no test in this file can reach a real CLI
 * no matter which runtime an expert names. An earlier version only faked
 * `claude` and gave one expert the `grok` runtime to force a failure — on a
 * machine with grok actually installed, that test spawned the user's real CLI
 * and spent their quota. "This runtime probably is not installed" is not a
 * safety mechanism; shadowing the name is.
 */
const AGENT_EXECUTABLES = ["claude", "codex", "gemini", "cursor-agent", "grok", "kiro-cli"] as const;

/**
 * A CLI that refuses immediately, whatever protocol it was supposed to speak.
 *
 * Used for every executable a test does not explicitly stub. Failing fast is the
 * right default: a stub that hung would turn a mis-targeted test into a timeout
 * rather than an error, and exiting non-zero is a failure every transport
 * recognises without knowing its wire format.
 */
function fakeRefusing(name: string): string {
  return `#!/usr/bin/env node
process.stderr.write(${JSON.stringify(`${name} is stubbed out in tests\n`)});
process.exit(3);
`;
}

/**
 * A fake `claude`, in Node rather than shell.
 *
 * Claude's terminal event is a single JSON object with `type` written last, which
 * is what the real CLI emits — building it with JSON.stringify avoids the
 * three-level quoting hazard that made an earlier shell version emit unparseable
 * JSON while still passing, since a failed parse and an empty reply are
 * indistinguishable from outside.
 *
 * `mode` decides what it says, so one script covers every scenario:
 *   echo     — a plain acknowledgement naming whoever was asked
 *   mention  — a reply that @-mentions another agent, to drive the chain guard
 *   empty    — succeeds with no output, which a real CLI can do
 *   fail     — exits non-zero
 */
function fakeClaude(
  mode: "echo" | "mention" | "empty" | "fail" | "pingpong",
  mentionName = "",
): string {
  return `#!/usr/bin/env node
const argv = process.argv.slice(2);
// claude passes the prompt via -p; taking the longest entry also covers a
// positional form, since a prompt is always far longer than any flag.
const prompt = argv.reduce((longest, a) => (a.length > longest.length ? a : longest), "");
const who = (prompt.match(/^你是 ([^\\u3002]+)/) || [])[1] || "someone";

function emit(result) {
  process.stdout.write(
    JSON.stringify({
      is_error: false,
      session_id: "fake-session",
      result,
      usage: { input_tokens: 10, output_tokens: 5 },
      type: "result",
    }) + "\\n",
  );
}

const mode = ${JSON.stringify(mode)};
if (mode === "fail") {
  process.stderr.write("fake cli refused\\n");
  process.exit(3);
} else if (mode === "empty") {
  emit("");
} else if (mode === "mention") {
  emit(who + " 说：这个得问 @${mentionName}");
} else if (mode === "pingpong") {
  // Mentions whichever of the pair is NOT the speaker, so this genuinely bounces
  // A → B → A. The plain "mention" mode cannot: it names one fixed agent, and a
  // self-mention is filtered by the router, so the chain dies after one hop and
  // the depth guard is never exercised.
  const pair = ${JSON.stringify(mentionName)}.split(",");
  const other = pair.find((n) => n !== who) || pair[0];
  emit(who + " 说：交给 @" + other);
} else {
  emit(who + " 回复：收到");
}
`;
}

interface Fixture {
  store: Store;
  channel: Channel;
  dm: Channel;
  atlas: Expert;
  probe: Expert;
  cwd: string;
  dispose: () => Promise<void>;
}

/**
 * Builds a store, a channel, a DM, two experts, and a fake CLI on PATH.
 *
 * PATH is restored on dispose. Leaving it mutated would leak into every later
 * test in the process, and the symptom — a different suite quietly running a
 * fake agent — would be very hard to trace back here.
 */
async function fixture(
  mode: "echo" | "mention" | "empty" | "fail" | "pingpong" = "echo",
  mentionName = "",
): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-chat-"));
  const binDir = join(root, "bin");
  await mkdir(binDir, { recursive: true });

  /*
   * Every agent executable is shadowed, not just the one under test.
   *
   * `claude` gets the behaviour this fixture was asked for; the rest refuse. That
   * way an expert on any runtime resolves to something inert, and no test can
   * reach a CLI the user actually installed.
   */
  for (const name of AGENT_EXECUTABLES) {
    const path = join(binDir, name);
    await writeFile(path, name === "claude" ? fakeClaude(mode, mentionName) : fakeRefusing(name), "utf8");
    await chmod(path, 0o755);
  }

  const originalPath = process.env["PATH"] ?? "";
  process.env["PATH"] = `${binDir}${delimiter}${originalPath}`;

  const store = new Store(":memory:");
  const mk = (name: string, description: string): Expert =>
    store.createExpert({
      name,
      description,
      runtimeKind: "claude",
      model: null,
      systemPrompt: "",
      capabilities: ["general"],
    });
  const atlas = mk("Atlas", "写代码");
  const probe = mk("Probe", "找 bug");

  const channel = store.createChannel({
    name: "demo",
    purpose: "",
    kind: "channel",
    projectId: null,
    dmExpertId: null,
  });
  const dm = store.createChannel({
    name: "Atlas",
    purpose: "",
    kind: "dm",
    projectId: null,
    dmExpertId: atlas.id,
  });

  return {
    store,
    channel,
    dm,
    atlas,
    probe,
    cwd: root,
    dispose: async () => {
      process.env["PATH"] = originalPath;
      store.close();
      await rm(root, { recursive: true, force: true });
    },
  };
}

function say(
  f: Fixture,
  channel: Channel,
  body: string,
  opts: { author?: Expert; parentId?: string | null } = {},
): Message {
  return f.store.createMessage({
    channelId: channel.id,
    authorKind: opts.author ? "expert" : "human",
    authorId: opts.author?.id ?? null,
    parentId: opts.parentId ?? null,
    body,
  });
}

function reply(f: Fixture, channel: Channel, message: Message) {
  return replyToMessage({
    store: f.store,
    message,
    channel,
    experts: f.store.listExperts(),
    cwd: f.cwd,
  });
}

function deliver(f: Fixture, channel: Channel, message: Message) {
  return deliverMessage({
    store: f.store,
    message,
    channel,
    experts: f.store.listExperts(),
    cwd: f.cwd,
  });
}

/** Another expert on the faked runtime, so it resolves to the stub. */
function addExpert(f: Fixture, name: string): Expert {
  return f.store.createExpert({
    name,
    description: "",
    runtimeKind: "claude",
    model: null,
    systemPrompt: "",
    capabilities: [],
  });
}

// ── Routing ─────────────────────────────────────────────────

test("dm: an agent answers without being mentioned", async () => {
  const f = await fixture();
  try {
    const msg = say(f, f.dm, "这个项目怎么起？");
    const res = await reply(f, f.dm, msg);

    assert.equal(res.skipped, null);
    assert.equal(res.posted.length, 1);
    assert.equal(res.posted[0]?.authorKind, "expert");
    assert.equal(res.posted[0]?.authorId, f.atlas.id);
    assert.match(res.posted[0]?.body ?? "", /Atlas 回复/);
    // The reply threads under the message rather than becoming a second root.
    assert.equal(res.posted[0]?.parentId, msg.id);
  } finally {
    await f.dispose();
  }
});

test("channel: nobody answers a message that mentions nobody", async () => {
  const f = await fixture();
  try {
    // Six agents answering every line would make a channel unusable, and picking
    // one implicitly would be a guess presented as a routing decision.
    const res = await reply(f, f.channel, say(f, f.channel, "这个怎么做？"));
    assert.equal(res.skipped, "no_responder");
    assert.equal(res.posted.length, 0);
    assert.equal(f.store.listChannelMessages(f.channel.id).length, 1);
  } finally {
    await f.dispose();
  }
});

test("channel: a mention routes to exactly that agent", async () => {
  const f = await fixture();
  try {
    const res = await reply(f, f.channel, say(f, f.channel, "@Probe 看一下这个"));
    assert.equal(res.posted.length, 1);
    assert.equal(res.posted[0]?.authorId, f.probe.id);
  } finally {
    await f.dispose();
  }
});

test("channel: two mentions answer in order, each seeing the one before", async () => {
  const f = await fixture();
  try {
    const msg = say(f, f.channel, "@Atlas 和 @Probe 都说一下");
    const res = await reply(f, f.channel, msg);

    assert.deepEqual(
      res.posted.map((m) => m.authorId),
      [f.atlas.id, f.probe.id],
      "replies are produced in mention order",
    );
    // Sequential rather than parallel is the whole point of asking several: the
    // second can disagree with the first instead of duplicating it. Parallel
    // replies would be N independent answers to the same prompt.
    assert.ok(
      res.posted.every((m) => m.parentId === msg.id),
      "both land in the same thread",
    );
    // And the stream still shows one root.
    assert.equal(f.store.listChannelMessages(f.channel.id).length, 1);
    assert.equal(f.store.listChannelMessages(f.channel.id)[0]?.replyCount, 2);
  } finally {
    await f.dispose();
  }
});

// ── Loop guard ──────────────────────────────────────────────

test("chain: an agent-authored root already counts as one link", async () => {
  const f = await fixture();
  try {
    /*
     * Regression test for an off-by-one that made the guard measure one short.
     *
     * `listThreadReplies` returns replies only, so building the chain from it
     * alone left an agent-authored ROOT out of its own chain — the count came
     * back 0 instead of 1, and every reply after it was undercounted, allowing
     * one extra hop before the cap engaged.
     */
    const root = say(f, f.channel, "@Probe 你看", { author: f.atlas });
    let previous: Message = root;
    for (let i = 1; i < MAX_AGENT_CHAIN; i++) {
      previous = say(f, f.channel, "@Probe 继续", { author: f.atlas, parentId: root.id });
    }
    // MAX_AGENT_CHAIN consecutive agent messages exist counting the root, so the
    // next one must be refused.
    const res = await reply(f, f.channel, previous);
    assert.equal(res.skipped, "chain_limit");
    assert.equal(res.posted.length, 0);
  } finally {
    await f.dispose();
  }
});

test("chain: a human message resets it", async () => {
  const f = await fixture();
  try {
    const root = say(f, f.channel, "开始");
    for (let i = 0; i < MAX_AGENT_CHAIN; i++) {
      say(f, f.channel, "@Probe 继续", { author: f.atlas, parentId: root.id });
    }
    // A person joining in is what makes this a conversation rather than a loop,
    // so their message clears the count even in a thread full of agent traffic.
    const human = say(f, f.channel, "@Probe 我来问一句", { parentId: root.id });

    const res = await reply(f, f.channel, human);
    assert.equal(res.skipped, null);
    assert.equal(res.posted.length, 1);
  } finally {
    await f.dispose();
  }
});

test("chain: an agent mentioning another does not run away", async () => {
  // The fake replies with "@Probe", so left unguarded this drives a Probe reply
  // that mentions Probe again, and so on.
  const f = await fixture("mention", "Probe");
  try {
    let message = say(f, f.channel, "@Probe 开始");
    let hops = 0;

    for (let i = 0; i < 12; i++) {
      const res = await reply(f, f.channel, message);
      if (res.skipped !== null || res.posted.length === 0) break;
      hops++;
      message = res.posted[res.posted.length - 1]!;
    }

    assert.ok(hops > 0, "at least one reply must happen, or the test proves nothing");
    assert.ok(
      hops <= MAX_AGENT_CHAIN,
      `expected the chain to stop within ${MAX_AGENT_CHAIN} hops, got ${hops}`,
    );
  } finally {
    await f.dispose();
  }
});

test("routing: an agent is never made to answer its own message", async () => {
  const f = await fixture();
  try {
    // Otherwise an agent that repeats its own name mid-reply talks to itself.
    const res = await reply(f, f.dm, say(f, f.dm, "我是 Atlas", { author: f.atlas }));
    assert.equal(res.skipped, "no_responder");
    assert.equal(res.posted.length, 0);
  } finally {
    await f.dispose();
  }
});

// ── Cascade (agent → agent) ─────────────────────────────────

test("cascade: a reply that mentions another agent actually reaches them", async () => {
  // The fake always answers with "@Probe", so Atlas handing off must pull Probe in.
  const f = await fixture("mention", "Probe");
  try {
    const res = await deliver(f, f.channel, say(f, f.channel, "@Atlas 你看看"));

    /*
     * This is the agent-to-agent half of the feature. `replyToMessage` alone
     * answers ONE message, so Atlas replying "这个得问 @Probe" stopped there and
     * Probe was never asked — which makes the prompt's instruction to hand work
     * off by name a lie.
     */
    assert.deepEqual(
      res.posted.map((m) => m.authorId),
      [f.atlas.id, f.probe.id],
      "Atlas answers, then the Probe it named answers too",
    );
    // Probe's own reply names Probe, and a self-mention is filtered, so the
    // branch ends on its own rather than by hitting a ceiling.
    assert.equal(res.truncated, false);
  } finally {
    await f.dispose();
  }
});

test("cascade: a ping-pong between two agents is bounded", async () => {
  // Each reply names the OTHER one, so nothing stops this except the guards.
  const f = await fixture("pingpong", "Atlas,Probe");
  try {
    const res = await deliver(f, f.channel, say(f, f.channel, "@Atlas 开始"));

    const turns = res.posted.length + res.failed.length;
    assert.ok(turns > 1, "the cascade must actually bounce, or this proves nothing");
    assert.ok(
      turns <= MAX_DELIVERY_TURNS,
      `expected at most ${MAX_DELIVERY_TURNS} turns, got ${turns}`,
    );
  } finally {
    await f.dispose();
  }
});

test("cascade: the turn ceiling holds for one message naming many agents", async () => {
  const f = await fixture();
  try {
    /*
     * Regression test for a hole in the ceiling I found while reviewing it.
     *
     * `MAX_DELIVERY_TURNS` was only consulted BETWEEN queued messages, while the
     * responder loop inside one call answers every mention in that message. So a
     * single line naming eight agents spawned eight CLIs and overshot a six-turn
     * limit before control ever returned to the check. Depth and breadth are
     * different bounds, and only depth was enforced.
     */
    const extra = ["Vera", "Wren", "Xu", "Yuki", "Zane", "Nia"].map((n) => addExpert(f, n));
    const everyone = [f.atlas, f.probe, ...extra];
    const body = everyone.map((e) => `@${e.name}`).join(" ") + " 都说一下";

    const res = await deliver(f, f.channel, say(f, f.channel, body));

    const turns = res.posted.length + res.failed.length;
    assert.equal(everyone.length, 8, "the fixture must exceed the ceiling for this to bite");
    assert.ok(
      turns <= MAX_DELIVERY_TURNS,
      `expected at most ${MAX_DELIVERY_TURNS} turns, got ${turns}`,
    );
    assert.equal(res.truncated, true, "declining work must be reported, not silent");
  } finally {
    await f.dispose();
  }
});

test("cascade: one agent is asked once per delivery, not once per mention", async () => {
  // Each reply names the OTHER of the pair, so without dedup this bounces until
  // the turn ceiling.
  const f = await fixture("pingpong", "Atlas,Probe");
  try {
    /*
     * Regression test for waste observed in a REAL run.
     *
     * A message named both Atlas and Probe: Probe answered it, then Atlas's reply
     * also named Probe, so Probe was spawned a second time and produced
     * near-identical advice. Two real CLI invocations, two lots of tokens, and the
     * same paragraph twice in the channel — a failure that looks like the feature
     * working, which is why it needs a test rather than a code comment.
     */
    const res = await deliver(f, f.channel, say(f, f.channel, "@Atlas @Probe 都说一下"));

    assert.deepEqual(
      res.posted.map((m) => m.authorId),
      [f.atlas.id, f.probe.id],
      "both answer the human once, and neither answers the other's mention",
    );
    // The cascade ends because everyone addressed has spoken, NOT because it ran
    // out of budget — which is the difference between converging and being cut off.
    assert.equal(res.truncated, false);
  } finally {
    await f.dispose();
  }
});

test("cascade: an agent whose cli fails is not retried on every mention", async () => {
  const f = await fixture("fail");
  try {
    // Otherwise a broken CLI that people keep naming becomes a retry loop that
    // spends the whole ceiling on one agent which cannot answer.
    const res = await deliver(f, f.channel, say(f, f.channel, "@Atlas @Probe 都说一下"));

    assert.deepEqual(res.posted, []);
    assert.equal(res.failed.length, 2, "each agent is attempted exactly once");
    assert.deepEqual(
      [...new Set(res.failed.map((x) => x.expertName))].sort(),
      ["Atlas", "Probe"],
    );
  } finally {
    await f.dispose();
  }
});

test("cascade: a message nobody is addressed in spends nothing", async () => {
  const f = await fixture();
  try {
    const res = await deliver(f, f.channel, say(f, f.channel, "自言自语"));
    assert.deepEqual(res.posted, []);
    assert.deepEqual(res.failed, []);
    assert.equal(res.truncated, false);
  } finally {
    await f.dispose();
  }
});

// ── Failure handling ────────────────────────────────────────

test("failure: a broken cli is reported, not written as a message", async () => {
  const f = await fixture("fail");
  try {
    const res = await reply(f, f.dm, say(f, f.dm, "在吗"));

    assert.equal(res.posted.length, 0);
    assert.equal(res.failed.length, 1);
    assert.equal(res.failed[0]?.expertName, "Atlas");
    // Nothing lands in the channel, so a failed reply cannot read as a teammate
    // having said something.
    assert.equal(f.store.listThreadReplies(f.dm.id).length, 0);
  } finally {
    await f.dispose();
  }
});

test("failure: an empty reply is a failure rather than an empty message", async () => {
  const f = await fixture("empty");
  try {
    // A CLI can exit cleanly having produced nothing. Writing that as a message
    // renders as a teammate saying nothing at all, which reads as a bug.
    const res = await reply(f, f.dm, say(f, f.dm, "在吗"));
    assert.equal(res.posted.length, 0);
    assert.deepEqual(
      res.failed.map((x) => x.error),
      ["空回复"],
    );
  } finally {
    await f.dispose();
  }
});

test("failure: one agent failing does not lose the others' replies", async () => {
  const f = await fixture();
  try {
    /*
     * A third expert on a runtime whose stub REFUSES, so its turn fails while the
     * claude-backed one succeeds.
     *
     * The failure has to come from a stub rather than from the runtime being
     * absent. Relying on absence is what made an earlier version of this test
     * spawn the user's real grok CLI on a machine that had it installed.
     */
    f.store.createExpert({
      name: "Ghost",
      description: "会拒绝的运行时",
      runtimeKind: "grok",
      model: null,
      systemPrompt: "",
      capabilities: [],
    });

    const res = await reply(f, f.channel, say(f, f.channel, "@Ghost @Atlas 都说一下"));

    assert.equal(res.posted.length, 1, "Atlas still answers");
    assert.equal(res.posted[0]?.authorId, f.atlas.id);
    assert.equal(res.failed.length, 1);
    assert.equal(res.failed[0]?.expertName, "Ghost");
  } finally {
    await f.dispose();
  }
});

test("slots: the concurrency slot is released even when the turn throws", async () => {
  const f = await fixture("fail");
  try {
    const before = chatLoad();
    await reply(f, f.dm, say(f, f.dm, "在吗"));
    const after = chatLoad();

    // A leaked slot permanently shrinks the cap, and with a small limit a couple
    // of leaks wedge chat entirely — with no error, just replies that never come.
    assert.equal(after.active, before.active);
    assert.equal(after.available, before.available);
  } finally {
    await f.dispose();
  }
});

test("cancel: an aborted signal stops before spawning anything", async () => {
  const f = await fixture();
  try {
    const controller = new AbortController();
    controller.abort();

    const res = await replyToMessage({
      store: f.store,
      message: say(f, f.dm, "在吗"),
      channel: f.dm,
      experts: f.store.listExperts(),
      cwd: f.cwd,
      signal: controller.signal,
    });

    assert.equal(res.posted.length, 0);
    assert.equal(chatLoad().active, 0, "the slot must not stay held after an abort");
  } finally {
    await f.dispose();
  }
});
