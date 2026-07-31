import assert from "node:assert/strict";
import { test } from "node:test";
import { findMentions, resolveResponders, segmentBody } from "./mentions.ts";

/**
 * Mention parsing.
 *
 * This module decides who answers a message, so a miss is not a cosmetic bug —
 * it is a message that silently goes unanswered. The cases below are the ones
 * where a naive `@(\w+)` regex gets it wrong, and every one of them is reachable
 * by ordinary typing rather than by adversarial input.
 */

const TEAM = [
  { id: "e-atlas", name: "Atlas" },
  { id: "e-probe", name: "Probe" },
  { id: "e-iris", name: "Iris" },
];

test("mentions: a plain mention is found with its span", () => {
  const found = findMentions("@Atlas 看一下这个", TEAM);
  assert.equal(found.length, 1);
  assert.deepEqual(found[0], { id: "e-atlas", name: "Atlas", start: 0, end: 6 });
});

test("mentions: CJK immediately after a name still counts as a boundary", () => {
  /*
   * The load-bearing case for this UI. `@Atlas看一下这个` with no space is how a
   * mention is actually typed in Chinese, and treating CJK as a name character
   * would make it fail to match — the message would be routed to nobody, with no
   * error anywhere.
   */
  const found = findMentions("@Atlas看一下这个", TEAM);
  assert.deepEqual(
    found.map((m) => m.id),
    ["e-atlas"],
  );
  assert.equal(found[0]?.end, 6, "the span covers only the name, not the CJK text");
});

test("mentions: punctuation and line ends are boundaries", () => {
  for (const body of ["@Atlas, 麻烦你", "@Atlas。", "@Atlas\n下一行", "(@Atlas)", "@Atlas"]) {
    assert.deepEqual(
      findMentions(body, TEAM).map((m) => m.id),
      ["e-atlas"],
      `expected a match in ${JSON.stringify(body)}`,
    );
  }
});

test("mentions: an email address is not a mention", () => {
  // `@` preceded by a name character is an address, and the text after it would
  // otherwise read as whoever it happens to spell.
  assert.deepEqual(findMentions("mail me at bob@Atlas.dev", TEAM), []);
  assert.deepEqual(findMentions("a@Probe", TEAM), []);
});

test("mentions: a longer name wins over a prefix of it", () => {
  const withSuffix = [...TEAM, { id: "e-iris2", name: "Iris-2" }];
  assert.deepEqual(
    findMentions("@Iris-2 你来", withSuffix).map((m) => m.id),
    ["e-iris2"],
    "the shorter Iris must not claim the match",
  );
  // And the short name still matches when it stands alone.
  assert.deepEqual(
    findMentions("@Iris 你来", withSuffix).map((m) => m.id),
    ["e-iris"],
  );
});

test("mentions: a name that is only a prefix of a longer word does not match", () => {
  assert.deepEqual(findMentions("@Atlasson", TEAM), []);
  assert.deepEqual(findMentions("@Atlas-2", TEAM), [], "a trailing dash is part of the word");
});

test("mentions: matching is case-insensitive but reports the canonical name", () => {
  const found = findMentions("@atlas 和 @PROBE", TEAM);
  assert.deepEqual(
    found.map((m) => m.name),
    ["Atlas", "Probe"],
  );
});

test("mentions: several mentions come back in order of appearance", () => {
  const found = findMentions("@Probe 先看，然后 @Atlas 改，@Iris 收尾", TEAM);
  assert.deepEqual(
    found.map((m) => m.id),
    ["e-probe", "e-atlas", "e-iris"],
  );
});

test("mentions: an unknown name is not a mention", () => {
  assert.deepEqual(findMentions("@nobody 在吗", TEAM), []);
  // And an empty roster cannot match anything, including an empty-named entry.
  assert.deepEqual(findMentions("@Atlas", []), []);
  assert.deepEqual(findMentions("@Atlas", [{ id: "x", name: "" }]), []);
});

test("mentions: a name containing regex metacharacters is matched literally", () => {
  /*
   * Names are arbitrary user data. Building one into a pattern would mean
   * escaping it correctly forever; this scans instead, so `.` matches a dot
   * rather than any character.
   */
  const odd = [{ id: "e-dot", name: "c.p+p" }];
  assert.deepEqual(
    findMentions("@c.p+p 来一下", odd).map((m) => m.id),
    ["e-dot"],
  );
  assert.deepEqual(findMentions("@cXpYp 来一下", odd), [], "the dot must not act as a wildcard");
});

// ── Routing ─────────────────────────────────────────────────

test("routing: a DM needs no mention", () => {
  // Opening somebody's conversation IS addressing them.
  assert.deepEqual(
    resolveResponders({
      body: "在吗",
      channelKind: "dm",
      dmExpertId: "e-atlas",
      candidates: TEAM,
    }),
    ["e-atlas"],
  );
});

test("routing: a channel requires an explicit mention", () => {
  /*
   * Six agents answering every message would make a channel unusable, and
   * picking one implicitly would be a guess presented as a routing decision.
   */
  assert.deepEqual(
    resolveResponders({ body: "这个怎么做", channelKind: "channel", dmExpertId: null, candidates: TEAM }),
    [],
  );
  assert.deepEqual(
    resolveResponders({
      body: "@Probe 看看这个",
      channelKind: "channel",
      dmExpertId: null,
      candidates: TEAM,
    }),
    ["e-probe"],
  );
});

test("routing: an agent is never made to answer itself", () => {
  // Otherwise an agent that repeats its own name mid-reply starts a loop.
  assert.deepEqual(
    resolveResponders({
      body: "我是 @Atlas，我来处理",
      channelKind: "channel",
      dmExpertId: null,
      candidates: TEAM,
      authorId: "e-atlas",
    }),
    [],
  );
  assert.deepEqual(
    resolveResponders({
      body: "在吗",
      channelKind: "dm",
      dmExpertId: "e-atlas",
      candidates: TEAM,
      authorId: "e-atlas",
    }),
    [],
    "a DM's own agent replying to itself has no second party",
  );
});

test("routing: repeated mentions of one agent yield one responder", () => {
  assert.deepEqual(
    resolveResponders({
      body: "@Atlas 你先看，@Atlas 记得跑测试",
      channelKind: "channel",
      dmExpertId: null,
      candidates: TEAM,
    }),
    ["e-atlas"],
  );
});

test("routing: a DM with no agent on the other side routes to nobody", () => {
  assert.deepEqual(
    resolveResponders({ body: "hello", channelKind: "dm", dmExpertId: null, candidates: TEAM }),
    [],
  );
});

// ── Rendering ───────────────────────────────────────────────

test("segments: the pieces always reassemble into the original body", () => {
  /*
   * The invariant that matters for a renderer: dropping or duplicating a
   * character would corrupt displayed text, which is worse than not
   * highlighting at all.
   */
  for (const body of [
    "@Atlas 看一下",
    "先问 @Probe，再问 @Iris。",
    "@Atlas看一下这个",
    "没有提及",
    "",
    "bob@Atlas.dev 是邮箱",
    "@Atlas",
  ]) {
    const joined = segmentBody(body, TEAM)
      .map((s) => s.text)
      .join("");
    assert.equal(joined, body, `segments must reassemble ${JSON.stringify(body)}`);
  }
});

test("segments: mentions are marked and carry the id the router would use", () => {
  const segments = segmentBody("先问 @Probe，再问 @Iris。", TEAM);
  assert.deepEqual(
    segments.filter((s) => s.kind === "mention").map((s) => (s.kind === "mention" ? s.id : "")),
    ["e-probe", "e-iris"],
  );
  // The displayed text is what the user typed, including the `@`.
  assert.deepEqual(
    segments.filter((s) => s.kind === "mention").map((s) => s.text),
    ["@Probe", "@Iris"],
  );
});

test("segments: an empty body yields no segments rather than one empty one", () => {
  assert.deepEqual(segmentBody("", TEAM), []);
});
