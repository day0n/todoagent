/**
 * @-mention parsing.
 *
 * A dependency-free leaf module, like `review-rules.ts`: the engine needs it to
 * decide who should answer a message, and the browser needs the same answer to
 * highlight the mention as it is typed. Two implementations would drift, and the
 * failure would be silent — a name highlighted in the composer that the engine
 * then does not route to.
 *
 * Names are matched by scanning rather than by a name-shaped regex. An expert's
 * name is arbitrary user data, so building it into a pattern would mean escaping
 * it correctly forever; matching known names at a position cannot be broken by a
 * name containing `.`, `+` or `(`.
 */

/** The minimum an entity needs to be addressable. */
export interface Mentionable {
  id: string;
  name: string;
}

export interface Mention {
  id: string;
  name: string;
  /** Index of the `@`. */
  start: number;
  /** Index just past the matched name. */
  end: number;
}

/**
 * True when `ch` can be part of a name for boundary purposes.
 *
 * ASCII-only on purpose. The UI is Chinese, so `@Atlas看一下这个` is the normal
 * way a mention appears — if CJK counted as a name character, that would fail to
 * match and the message would silently go unanswered. A trailing `-` or digit
 * does count, so `@gpt-5` cannot match a hypothetical expert named `gpt`.
 */
function isNameChar(ch: string | undefined): boolean {
  if (ch === undefined) return false;
  return /[A-Za-z0-9_-]/.test(ch);
}

/**
 * Finds every mention of a known entity, in order of appearance.
 *
 * Only `@` preceded by a non-name character counts, so an email address never
 * reads as a mention of the text after its `@`. Matching is case-insensitive
 * because nobody capitalises consistently while typing, and the longest name at
 * a position wins so an expert called `Iris` cannot shadow one called `Iris-2`.
 */
export function findMentions(body: string, candidates: readonly Mentionable[]): Mention[] {
  if (candidates.length === 0) return [];

  // Longest first, so a prefix name never claims a longer one's match.
  const sorted = [...candidates].sort((a, b) => b.name.length - a.name.length);
  const lower = body.toLowerCase();
  const found: Mention[] = [];

  for (let i = 0; i < body.length; i++) {
    if (body[i] !== "@") continue;
    // `a@b` is an address, not a mention.
    if (isNameChar(body[i - 1])) continue;

    for (const candidate of sorted) {
      if (candidate.name.length === 0) continue;
      const name = candidate.name.toLowerCase();
      if (!lower.startsWith(name, i + 1)) continue;
      const end = i + 1 + candidate.name.length;
      // The match must not be a prefix of a longer word: `@Atlasson` is not Atlas.
      if (isNameChar(body[end])) continue;

      found.push({ id: candidate.id, name: candidate.name, start: i, end });
      // Skip past this mention so its own text cannot yield another match.
      i = end - 1;
      break;
    }
  }

  return found;
}

/**
 * Who should answer this message.
 *
 * A DM has exactly one possible responder and needs no mention — addressing
 * somebody by opening their conversation is the whole point. A channel requires
 * an explicit mention: six agents all answering every message would make a
 * channel unusable, and picking one implicitly would be a guess presented as a
 * routing decision.
 *
 * Returns ids, de-duplicated, preserving the order they were mentioned in.
 */
export function resolveResponders(opts: {
  body: string;
  channelKind: "channel" | "dm";
  /** For a DM, the agent on the other side. */
  dmExpertId: string | null;
  candidates: readonly Mentionable[];
  /** The author, so a self-mention cannot make an agent answer itself. */
  authorId?: string | null;
}): string[] {
  if (opts.channelKind === "dm") {
    if (opts.dmExpertId === null) return [];
    // A DM's own agent replying to itself would be a loop with no second party.
    return opts.dmExpertId === opts.authorId ? [] : [opts.dmExpertId];
  }

  const seen = new Set<string>();
  const out: string[] = [];
  for (const mention of findMentions(opts.body, opts.candidates)) {
    if (mention.id === opts.authorId) continue;
    if (seen.has(mention.id)) continue;
    seen.add(mention.id);
    out.push(mention.id);
  }
  return out;
}

/**
 * Splits a body into plain text and mention spans, for rendering.
 *
 * The renderer needs the same parse the router used; deriving highlights from a
 * separate regex in the browser is how a highlighted name that nothing routes to
 * comes about.
 */
export type BodySegment =
  | { kind: "text"; text: string }
  | { kind: "mention"; text: string; id: string };

export function segmentBody(body: string, candidates: readonly Mentionable[]): BodySegment[] {
  const mentions = findMentions(body, candidates);
  if (mentions.length === 0) return body === "" ? [] : [{ kind: "text", text: body }];

  const out: BodySegment[] = [];
  let at = 0;
  for (const mention of mentions) {
    if (mention.start > at) out.push({ kind: "text", text: body.slice(at, mention.start) });
    out.push({ kind: "mention", text: body.slice(mention.start, mention.end), id: mention.id });
    at = mention.end;
  }
  if (at < body.length) out.push({ kind: "text", text: body.slice(at) });
  return out;
}
