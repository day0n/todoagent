import type { MessageWithThread } from "./types.ts";

/**
 * Decides whether a message-stream response may be shown.
 *
 * Two distinct hazards, and the first one is worse than the race I set out to fix.
 *
 * CROSS-CHANNEL CONTAMINATION. `Chat` is not keyed by channel, and the page reuses
 * one instance across navigations, so switching channels leaves the previous
 * channel's request in flight. When it lands it was applied unconditionally —
 * putting another channel's conversation on screen under the current channel's
 * name. The endpoint returns the channel alongside its messages precisely so this
 * is checkable, and identity is checked FIRST because no ordering signal can save
 * a response about the wrong subject.
 *
 * OUT-OF-ORDER RESPONSES. `send` calls `load()` after posting, so two requests can
 * be in flight for the same channel; if the older one lands last, the message the
 * user just sent vanishes until the next poll up to four seconds later.
 *
 * `seq` is the ordering signal, and a premise worth stating because I got it wrong
 * first: `message.seq` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so it is GLOBAL
 * across the table, not per channel. Two channels' ranges interleave — measured on
 * the dev database, one holds seq 1..15 and another 3..4. That makes seq useless
 * for comparing across channels and perfectly sound within one, which is exactly
 * how it is used here.
 */
export function acceptMessages(opts: {
  current: MessageWithThread[] | null;
  incoming: MessageWithThread[];
  /** The channel this response describes, as the server reported it. */
  incomingChannelId: string;
  /** The channel currently open. */
  channelId: string;
}): MessageWithThread[] | null {
  // Wrong subject entirely. Nothing about the payload can make it relevant.
  if (opts.incomingChannelId !== opts.channelId) return opts.current;

  if (opts.current === null || opts.current.length === 0) return opts.incoming;

  /*
   * An empty response while messages are shown is rejected.
   *
   * Messages are append-only — nothing in this product deletes one — so an empty
   * list can only come from before the channel had any. Treating it as truth would
   * blank a populated stream.
   */
  if (opts.incoming.length === 0) return opts.current;

  /*
   * Rejected on STRICTLY lower, not on "not higher".
   *
   * A newer response can legitimately carry the same highest root seq: a reply
   * bumps its root's `replyCount` and `lastReplyAt` without creating a new root.
   * Requiring a strictly higher seq would freeze reply counts.
   */
  return highestSeq(opts.incoming) < highestSeq(opts.current) ? opts.current : opts.incoming;
}

/**
 * The newest `seq` in a list.
 *
 * A max rather than `at(-1)`: the stream is returned oldest-first today, but
 * depending on that here would make this silently wrong if the order ever changed.
 * Lists are capped at 500 by the engine.
 */
export function highestSeq(messages: readonly MessageWithThread[]): number {
  let max = 0;
  for (const m of messages) if (m.seq > max) max = m.seq;
  return max;
}
