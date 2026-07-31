import assert from "node:assert/strict";
import { test } from "node:test";
import { acceptMessages, highestSeq } from "./chat-state.ts";
import type { MessageWithThread } from "./types.ts";

/**
 * Message-stream reconciliation: identity first, then ordering.
 *
 * The cross-channel case is the serious one and it is not hypothetical. `Chat` is
 * not keyed by channel and the page reuses one instance across navigations, so
 * switching channels leaves the previous channel's request in flight — and it was
 * applied unconditionally on arrival, putting one conversation on screen under
 * another channel's name.
 */

function msg(seq: number, over: Partial<MessageWithThread> = {}): MessageWithThread {
  return {
    seq,
    id: `m${seq}`,
    channelId: "chan-a",
    authorKind: "human",
    authorId: null,
    parentId: null,
    body: `message ${seq}`,
    createdAt: "2026-08-01T00:00:00.000Z",
    replyCount: 0,
    lastReplyAt: null,
    ...over,
  };
}

// ── Identity ────────────────────────────────────────────────

test("a response about another channel is rejected outright", () => {
  /*
   * The sequence: open A, navigate to B, A's in-flight poll lands. Ordering cannot
   * rescue this — seq is a global AUTOINCREMENT so A's numbers may well be higher
   * than B's — which is why identity is checked before anything else.
   */
  const showing = [msg(10, { channelId: "chan-b", body: "B's conversation" })];
  const fromOtherChannel = [msg(99, { channelId: "chan-a", body: "A's conversation" })];

  const settled = acceptMessages({
    current: showing,
    incoming: fromOtherChannel,
    incomingChannelId: "chan-a",
    channelId: "chan-b",
  });

  assert.equal(settled, showing, "the wrong channel's messages must never be shown");
});

test("identity beats a higher seq", () => {
  // Explicit, because the naive guard would be seq-only and would accept this.
  const settled = acceptMessages({
    current: [msg(5, { channelId: "chan-b" })],
    incoming: [msg(500, { channelId: "chan-a" })],
    incomingChannelId: "chan-a",
    channelId: "chan-b",
  });
  assert.equal(settled?.[0]?.seq, 5);
});

test("an empty response for the wrong channel does not blank the stream", () => {
  const showing = [msg(3, { channelId: "chan-b" })];
  const settled = acceptMessages({
    current: showing,
    incoming: [],
    incomingChannelId: "chan-a",
    channelId: "chan-b",
  });
  assert.equal(settled, showing);
});

// ── Ordering, within one channel ────────────────────────────

test("an out-of-order response is rejected", () => {
  /*
   * `send` calls `load()` after posting, so two requests can be in flight at once.
   * If the older lands last the message the user just sent disappears — the pending
   * row was already removed — and nothing corrects it until the next poll, up to
   * four seconds later.
   */
  const withSent = [msg(1), msg(2), msg(3, { body: "the message just sent" })];
  const stale = [msg(1), msg(2)];

  const settled = acceptMessages({
    current: withSent,
    incoming: stale,
    incomingChannelId: "chan-a",
    channelId: "chan-a",
  });

  assert.equal(settled, withSent, "a response older than what is shown must be dropped");
  assert.equal(settled?.length, 3);
});

test("a newer response is applied", () => {
  const settled = acceptMessages({
    current: [msg(1)],
    incoming: [msg(1), msg(2)],
    incomingChannelId: "chan-a",
    channelId: "chan-a",
  });
  assert.equal(settled?.length, 2);
});

test("an equal-seq response is applied, because replies change without new roots", () => {
  /*
   * The reason the guard rejects on STRICTLY lower rather than on "not higher". A
   * reply bumps its root's `replyCount` and `lastReplyAt` and creates no new root,
   * so a genuinely newer response can carry the same highest seq. Requiring a
   * strictly higher one would freeze reply counts on screen.
   */
  const before = [msg(7, { replyCount: 2, lastReplyAt: "2026-08-01T00:01:00.000Z" })];
  const after = [msg(7, { replyCount: 3, lastReplyAt: "2026-08-01T00:02:00.000Z" })];

  const settled = acceptMessages({
    current: before,
    incoming: after,
    incomingChannelId: "chan-a",
    channelId: "chan-a",
  });

  assert.equal(settled?.[0]?.replyCount, 3, "a new reply must show up");
});

test("an empty response never blanks a populated stream", () => {
  // Messages are append-only in this product — nothing deletes one — so an empty
  // list can only come from before the channel had any.
  const showing = [msg(1), msg(2)];
  const settled = acceptMessages({
    current: showing,
    incoming: [],
    incomingChannelId: "chan-a",
    channelId: "chan-a",
  });
  assert.equal(settled, showing);
});

// ── First load ──────────────────────────────────────────────

test("the first response is always accepted", () => {
  // `null` means not loaded yet; an empty array means a channel with no messages.
  for (const current of [null, []]) {
    const settled = acceptMessages({
      current,
      incoming: [msg(1)],
      incomingChannelId: "chan-a",
      channelId: "chan-a",
    });
    assert.equal(settled?.length, 1, `from ${JSON.stringify(current)}`);
  }

  // And an empty channel legitimately stays empty.
  const empty = acceptMessages({
    current: null,
    incoming: [],
    incomingChannelId: "chan-a",
    channelId: "chan-a",
  });
  assert.deepEqual(empty, []);
});

// ── highestSeq ──────────────────────────────────────────────

test("highestSeq is a max, not the last element", () => {
  /*
   * The stream is returned oldest-first today, so `at(-1)` would work — and would
   * silently break the guard if that order ever changed.
   */
  assert.equal(highestSeq([msg(3), msg(1), msg(2)]), 3);
  assert.equal(highestSeq([msg(5)]), 5);
  // Zero for an empty list, so a first load compares as "nothing shown yet".
  assert.equal(highestSeq([]), 0);
});

// ── The interleaving, end to end ────────────────────────────

test("a send survives a poll landing at any point around it", () => {
  const beforeSend = [msg(1), msg(2)];
  const afterSend = [msg(1), msg(2), msg(3, { body: "sent" })];

  for (const landsAt of ["before-send", "after-send"] as const) {
    let state: MessageWithThread[] | null = beforeSend;

    if (landsAt === "before-send") {
      // Harmless: it matches what is already shown.
      state = acceptMessages({
        current: state,
        incoming: beforeSend,
        incomingChannelId: "chan-a",
        channelId: "chan-a",
      });
    }

    // The POST returned and `load()` brought back the message.
    state = acceptMessages({
      current: state,
      incoming: afterSend,
      incomingChannelId: "chan-a",
      channelId: "chan-a",
    });

    if (landsAt === "after-send") {
      // The stale poll, issued before the send, resolving last.
      state = acceptMessages({
        current: state,
        incoming: beforeSend,
        incomingChannelId: "chan-a",
        channelId: "chan-a",
      });
    }

    assert.equal(state?.length, 3, `the sent message must survive a poll landing ${landsAt}`);
    assert.equal(state?.[2]?.body, "sent");
  }
});
