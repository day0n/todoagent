/**
 * Agent replies in channels and DMs.
 *
 * A chat reply is ONE turn, not a pipeline. `runOne` cannot serve it: that
 * function is built around a run — it charges tokens against `run.spent_tokens`,
 * writes an `attempt` row keyed to a run id, and streams into that run's event
 * log for SSE replay. A message in a DM has none of those, and inventing a
 * synthetic run for every reply would put rows in the delegation list that the
 * user never asked for and cannot cancel meaningfully.
 *
 * So this drives the adapter directly, and pays for that by re-implementing the
 * three things `runOne` gets right, which are the three things that actually
 * matter here:
 *
 *   1. A global cap on live CLI processes, held at the single spawn point.
 *   2. A wall-clock and idle ceiling, since nothing else will stop a wedged CLI.
 *   3. A loop guard, which the pipeline does not need and chat absolutely does.
 */

import { getAdapter } from "./adapters/index.ts";
import type { Store } from "./db/index.ts";
import { resolveResponders } from "./mentions.ts";
import type { Channel, Expert, Message } from "./types.ts";
import { Semaphore, defaultConcurrency } from "./util/concurrency.ts";

/**
 * Hard ceiling on agent turns per delivered message.
 *
 * A backstop independent of the chain guard, which bounds DEPTH but not BREADTH:
 * one message can mention three agents, and each of their replies can mention
 * more, so a depth-3 chain still permits a wide tree. This caps the whole
 * cascade — every turn is a real CLI process, so the bound has to be on total
 * work, not on one path through it.
 */
export const MAX_DELIVERY_TURNS = 6;

/**
 * How many agent messages may precede a reply before routing stops.
 *
 * The failure this prevents is not hypothetical: agents are instructed to
 * address each other by name, so one mentioning another produces a reply that
 * mentions the first, and nothing in the data model stops that from running
 * until the budget or the machine gives out. A human message resets the chain,
 * so a conversation a person is actually part of never hits the cap.
 *
 * Three is enough for a real hand-off (A asks B, B answers, A acknowledges) and
 * short enough that a runaway costs cents rather than dollars.
 */
export const MAX_AGENT_CHAIN = 3;

/** Wall clock for one reply. A chat answer that takes minutes is already wrong. */
export const REPLY_TIMEOUT_MS = 120_000;

/** No-new-events watchdog, for a CLI that connects and then goes silent. */
export const REPLY_IDLE_MS = 45_000;

/** How much history an agent sees. */
const CONTEXT_MESSAGES = 24;

/**
 * Global cap on concurrent chat replies.
 *
 * Module-level and deliberately separate from a pipeline's semaphore: those are
 * per-run, so N runs already permit N × limit processes, and chat has no run to
 * hang a limit off at all. Without this, mentioning six agents in one message
 * spawns six full CLIs at once, each one hundreds of megabytes.
 */
const slots = new Semaphore(Math.max(1, Math.floor(defaultConcurrency() / 2)));

/** Exposed for tests and for a status endpoint to report queue depth. */
export function chatLoad(): { active: number; available: number } {
  return { active: slots.active, available: slots.available };
}

export interface ReplyOptions {
  store: Store;
  /** The message that may need answering. */
  message: Message;
  channel: Channel;
  /** Everyone addressable here. */
  experts: readonly Expert[];
  /**
   * Working directory for the CLI.
   *
   * The project's repo when the channel has one, so an agent can actually read
   * the code it is being asked about. See the warning on `buildPrompt`: nothing
   * MECHANICALLY stops a reply from editing files, because every adapter runs
   * with tool confirmation bypassed. The prompt says not to; that is a request,
   * not a sandbox.
   */
  cwd: string;
  signal?: AbortSignal;
  /**
   * Ceiling on agent turns this single call may spend. Omitted means unlimited.
   *
   * Needed because the responder loop runs EVERY mentioned agent within one
   * call. Without it, `deliverMessage`'s budget was only consulted between
   * queued messages, so one message naming eight agents spawned eight CLIs and
   * blew past a six-turn ceiling before the check was ever reached.
   */
  maxTurns?: number;
}

export interface ReplyResult {
  /** Replies that were written, in the order they were produced. */
  posted: Message[];
  /** Experts that were asked but failed, with the reason. */
  failed: Array<{ expertId: string; expertName: string; error: string }>;
  /** Set when routing declined to answer at all, with why. */
  skipped: "no_responder" | "chain_limit" | "author_is_expert_in_channel" | null;
  /** Set when `maxTurns` stopped this call with responders still unanswered. */
  truncated: boolean;
}

/**
 * Answers a message, if anyone was addressed.
 *
 * Returns rather than throws for a failed reply: one agent's CLI being broken
 * must not lose the replies from the others, and the caller has already
 * acknowledged the user's message by the time this runs.
 */
export async function replyToMessage(opts: ReplyOptions): Promise<ReplyResult> {
  const { store, message, channel, experts, cwd } = opts;
  const empty: ReplyResult = { posted: [], failed: [], skipped: null, truncated: false };

  const responders = resolveResponders({
    body: message.body,
    channelKind: channel.kind,
    dmExpertId: channel.dmExpertId,
    candidates: experts.map((e) => ({ id: e.id, name: e.name })),
    authorId: message.authorId,
  });
  if (responders.length === 0) return { ...empty, skipped: "no_responder" };

  if (agentChainLength(store, message) >= MAX_AGENT_CHAIN) {
    return { ...empty, skipped: "chain_limit" };
  }

  /*
   * Replies land in the thread, not the channel.
   *
   * A root message with three agents answering would otherwise put four
   * top-level entries in the stream for one question. `parentId` is the root of
   * whichever thread the message belongs to — replying to a reply keeps both in
   * the same thread, which is also the only shape the schema allows.
   */
  const parentId = message.parentId ?? message.id;

  const context = buildContext(store, channel, message, experts);
  const posted: Message[] = [];
  const failed: ReplyResult["failed"] = [];

  /*
   * Sequential, not parallel.
   *
   * Each agent sees the replies before it, which is the entire point of asking
   * several: the second one can disagree with the first instead of duplicating
   * it. Parallel replies would be N independent answers to the same prompt, so
   * paying several vendors would buy nothing.
   */
  let truncated = false;

  for (const expertId of responders) {
    const expert = experts.find((e) => e.id === expertId);
    if (!expert) continue;
    if (opts.signal?.aborted === true) break;

    /*
     * Checked per responder, not per message.
     *
     * A failed turn counts: it still cost a spawn, so a roster of broken CLIs
     * must not buy unlimited attempts. `truncated` is set only when responders
     * remain, so it means "work was declined" rather than "we stopped exactly at
     * the limit".
     */
    if (opts.maxTurns !== undefined && posted.length + failed.length >= opts.maxTurns) {
      truncated = true;
      break;
    }

    try {
      const body = await runTurn({
        expert,
        prompt: buildPrompt({ expert, channel, context, transcriptTail: posted, experts }),
        cwd,
        ...(opts.signal ? { signal: opts.signal } : {}),
      });

      // An adapter can succeed and still return nothing — a CLI that exits
      // cleanly with no output. Writing an empty message would render as a
      // teammate saying nothing, which reads as a bug rather than as silence.
      if (body.trim() === "") {
        failed.push({ expertId: expert.id, expertName: expert.name, error: "空回复" });
        continue;
      }

      posted.push(
        store.createMessage({
          channelId: channel.id,
          authorKind: "expert",
          authorId: expert.id,
          parentId,
          body: body.trim(),
        }),
      );
    } catch (err) {
      failed.push({
        expertId: expert.id,
        expertName: expert.name,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { posted, failed, skipped: null, truncated };
}

export interface DeliverResult {
  /** Every reply written across the whole cascade, in the order produced. */
  posted: Message[];
  failed: Array<{ expertId: string; expertName: string; error: string }>;
  /** Set when the turn ceiling stopped the cascade with work still queued. */
  truncated: boolean;
}

/**
 * Delivers a message and follows every hand-off it causes.
 *
 * This is the agent-to-agent half of the feature, and without it the rest is
 * decoration: `replyToMessage` answers ONE message, so Atlas replying "这个得问
 * @Probe" produced a reply that mentioned Probe and then stopped. Probe was never
 * asked. The prompt tells agents to hand work off by name, so not following that
 * mention makes the instruction a lie.
 *
 * Breadth-first, so a message mentioning three agents gets all three answers
 * before any of their follow-ups are pursued — the direct answers to what a
 * person asked matter more than a tangent between two agents.
 *
 * Two independent bounds apply, because they stop different things:
 *   - `MAX_AGENT_CHAIN`, inside `replyToMessage`, bounds DEPTH along one thread.
 *   - `MAX_DELIVERY_TURNS`, here, bounds TOTAL turns. A depth-3 limit still
 *     permits a wide tree, and every node in it is a real CLI process.
 */
export async function deliverMessage(opts: ReplyOptions): Promise<DeliverResult> {
  const posted: Message[] = [];
  const failed: DeliverResult["failed"] = [];
  const queue: Message[] = [opts.message];
  let turns = 0;
  let truncated = false;

  while (queue.length > 0) {
    const next = queue.shift();
    if (next === undefined) break;
    if (opts.signal?.aborted === true) break;
    // Checked after dequeuing, so `truncated` means "there was work left that we
    // declined to do" rather than "we happened to stop at the limit".
    if (turns >= MAX_DELIVERY_TURNS) {
      truncated = true;
      break;
    }

    /*
     * The REMAINING budget is handed down, not the total.
     *
     * This is the half that makes the ceiling real. Checking `turns` only between
     * queued messages left the inner loop free to answer every mention in one
     * message, so a single line naming eight agents spawned eight CLIs and
     * overshot a six-turn limit before control ever came back here.
     */
    const res = await replyToMessage({
      ...opts,
      message: next,
      maxTurns: MAX_DELIVERY_TURNS - turns,
    });

    // Failures count against the ceiling too: a broken CLI still costs a spawn,
    // and a roster of failing agents must not buy unlimited attempts.
    turns += res.posted.length + res.failed.length;
    posted.push(...res.posted);
    failed.push(...res.failed);
    if (res.truncated) truncated = true;

    // Each reply may itself address somebody. A branch ends naturally when a
    // reply mentions nobody, or when the chain guard refuses it.
    queue.push(...res.posted);
  }

  return { posted, failed, truncated };
}

/**
 * How many agent messages immediately precede this one in its thread.
 *
 * Counts backwards from the message and stops at the first human, because a
 * person joining in is what makes a conversation a conversation rather than a
 * loop. Only the thread is examined: two agents talking in one thread should not
 * be silenced by unrelated agent traffic elsewhere in the channel.
 */
function agentChainLength(store: Store, message: Message): number {
  if (message.authorKind !== "expert") return 0;

  const rootId = message.parentId ?? message.id;
  /*
   * The root is fetched unconditionally, including when the message IS the root.
   *
   * `listThreadReplies` returns replies only, so building the list from it alone
   * left an agent-authored root out of its own chain: the count came back 0
   * instead of 1, and every subsequent reply was measured one short of reality.
   */
  const root = store.getMessage(rootId);
  const thread = [...(root === null ? [] : [root]), ...store.listThreadReplies(rootId)];

  let chain = 0;
  for (const m of thread) {
    // Only messages up to and including this one count; later ones are not
    // "before" it even though they exist by the time this runs.
    if (m.seq > message.seq) break;
    chain = m.authorKind === "expert" ? chain + 1 : 0;
  }
  return chain;
}

/** Recent conversation, oldest first, as `Name: body` lines. */
function buildContext(
  store: Store,
  channel: Channel,
  message: Message,
  experts: readonly Expert[],
): string {
  const rootId = message.parentId ?? message.id;
  const roots = store.listChannelMessages(channel.id, { limit: CONTEXT_MESSAGES });
  const thread = store.listThreadReplies(rootId);

  const seen = new Set<number>();
  const all = [...roots, ...thread]
    .filter((m) => {
      if (seen.has(m.seq)) return false;
      seen.add(m.seq);
      // Nothing after the message being answered — including replies from
      // siblings that happened to be written while this one was queued.
      return m.seq <= message.seq;
    })
    .sort((a, b) => a.seq - b.seq)
    .slice(-CONTEXT_MESSAGES);

  return all.map((m) => `${displayName(m, experts)}: ${m.body}`).join("\n\n");
}

function displayName(message: Message, experts: readonly Expert[]): string {
  if (message.authorKind !== "expert") return "用户";
  return experts.find((e) => e.id === message.authorId)?.name ?? "某个 agent";
}

/**
 * The prompt for one reply.
 *
 * Two constraints are stated because neither is enforceable from here:
 *
 *   - Do not modify files. Every adapter runs with tool confirmation bypassed,
 *     so an agent CAN write to the repo. A question in chat is not a work order,
 *     and this asks it not to — which is a request, not a sandbox. Work that
 *     should change code goes through the pipeline, where each subtask gets an
 *     isolated worktree and nothing merges without review.
 *   - Answer briefly. A CLI agent's default register is a report; a chat reply
 *     that arrives as a 2000-word document is unreadable in a message stream.
 */
function buildPrompt(opts: {
  expert: Expert;
  channel: Channel;
  context: string;
  /** Replies already written in this pass, so the next agent can respond to them. */
  transcriptTail: readonly Message[];
  experts: readonly Expert[];
}): string {
  const { expert, channel, context, transcriptTail, experts } = opts;

  const others = experts
    .filter((e) => e.id !== expert.id)
    .map((e) => `- @${e.name}: ${e.description}`)
    .join("\n");

  const already =
    transcriptTail.length === 0
      ? ""
      : `\n刚刚已经有人回复了这条消息：\n\n${transcriptTail
          .map((m) => `${displayName(m, experts)}: ${m.body}`)
          .join("\n\n")}\n\n不要重复他们说过的内容。如果你不同意，直接说明理由。\n`;

  const place =
    channel.kind === "dm"
      ? "这是你和用户的私聊。"
      : `这是频道 #${channel.name}${channel.purpose === "" ? "" : `（${channel.purpose}）`}，有人 @ 了你。`;

  return `你是 ${expert.name}。${place}

对话记录（从旧到新）：

${context}
${already}
现在请你回复最后一条消息。

要求：
- 说人话，简短。这是聊天，不是报告。通常两三句话就够，除非对方明确要求细节。
- 不要修改任何文件。这是对话，不是派活。真要动代码，让用户把它变成一个任务。
- 你可以读代码来回答问题。
- 需要别人补充时，用 @名字 点他。团队里还有：
${others === "" ? "（暂无其他成员）" : others}
- 不确定的事就说不确定，别编。
- 直接输出你要说的话，不要加"好的，我来回复："这类前缀。`;
}

/**
 * One agent turn, through the adapter.
 *
 * The slot is acquired before spawning and released in `finally`, which is the
 * same ordering `runOne` uses and for the same reason: a leaked slot permanently
 * shrinks the cap, and with a small limit a couple of leaks wedge chat entirely.
 */
async function runTurn(opts: {
  expert: Expert;
  prompt: string;
  cwd: string;
  signal?: AbortSignal;
}): Promise<string> {
  await slots.acquire();
  try {
    if (opts.signal?.aborted === true) throw new Error("已取消");

    const adapter = getAdapter(opts.expert.runtimeKind);
    const execution = adapter.execute(opts.prompt, {
      cwd: opts.cwd,
      model: opts.expert.model,
      systemPrompt: opts.expert.systemPrompt,
      timeoutMs: REPLY_TIMEOUT_MS,
      idleTimeoutMs: REPLY_IDLE_MS,
      ...(opts.signal ? { signal: opts.signal } : {}),
    });

    /*
     * The event stream is drained and discarded.
     *
     * Not optional: adapters close the event channel before settling `result`, so
     * an unconsumed stream can hold the process open. There is no run to log
     * these against, and a chat reply's intermediate tool calls are not something
     * the message stream shows — only the final text is.
     */
    const drain = (async () => {
      for await (const _ of execution.events) {
        if (opts.signal?.aborted === true) execution.cancel();
      }
    })();

    const result = await execution.result;
    await drain;

    if (result.status !== "completed") {
      throw new Error(result.error ?? `agent ${result.status}`);
    }
    return result.output;
  } finally {
    slots.release();
  }
}
