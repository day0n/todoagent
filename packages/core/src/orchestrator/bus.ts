import { EventEmitter } from "node:events";

/** One row as it goes out over SSE. `id` is the DB rowid, used for replay. */
export interface BusEvent {
  id: number;
  runId: string;
  attemptId: string | null;
  seq: number;
  type: string;
  payload: unknown;
  createdAt: string;
}

/**
 * "Something in the task/list world changed; re-read it."
 *
 * Deliberately carries NO data. The client's response is to call its existing
 * fetch-and-reconcile path, which means there is exactly one code path that turns
 * server state into UI state whether the trigger was a poll, a click, or this
 * event. Two independent data paths would eventually disagree, and the losing one
 * would be whichever arrived second.
 *
 * `taskId` is for reading the stream by hand while debugging. The client ignores
 * it on purpose: acting on it would make this a data channel again.
 */
export interface BoardEvent {
  type: "board:changed";
  taskId: string | null;
}

/**
 * The channel board events fan out on.
 *
 * It cannot collide with a run id — those are `randomUUID()`, which is hex and
 * dashes — and the colon is what guarantees that. It also must not be `"*"`,
 * which is the every-run firehose.
 */
const BOARD_CHANNEL = "board:changed";

/**
 * Chat events, all scoped to one `chat_session` now that several can be live
 * at once. `chat:delta` is the streaming case: one per token/chunk while an
 * `AgentSession` is generating, ephemeral like `chat:thinking` — a dropped
 * delta costs a few missing characters until `chat:message` triggers a
 * history refetch, never a correctness problem.
 */
export type ChatBusEvent =
  | { type: "chat:message"; sessionId: string }
  | { type: "chat:thinking"; on: boolean; sessionId: string }
  | { type: "chat:delta"; sessionId: string; text: string };

const CHAT_CHANNEL = "chat:event";

/**
 * In-process fan-out for live run events.
 *
 * Events are persisted first and broadcast second, so a subscriber that misses
 * a broadcast can always recover it from the event table by id. The bus is only
 * an optimization over polling — never the source of truth.
 */
class RunBus {
  private readonly emitter = new EventEmitter();

  constructor() {
    // A run with many watchers is normal; the default cap of 10 would warn.
    this.emitter.setMaxListeners(0);
  }

  publish(ev: BusEvent): void {
    this.emitter.emit(ev.runId, ev);
    this.emitter.emit("*", ev);
  }

  subscribe(runId: string, fn: (ev: BusEvent) => void): () => void {
    this.emitter.on(runId, fn);
    return () => this.emitter.off(runId, fn);
  }

  subscribeAll(fn: (ev: BusEvent) => void): () => void {
    this.emitter.on("*", fn);
    return () => this.emitter.off("*", fn);
  }

  /**
   * Announces a board change on its OWN channel.
   *
   * Not published as a `BusEvent`, which is the whole point. A BusEvent goes out
   * on `ev.runId` and on `"*"`, and `/api/runs/:id/events` subscribes by run id —
   * so a board event carrying any run id at all would surface in that run's
   * stream, where the web client parses every frame as a run event. Giving it a
   * separate channel makes that leak impossible rather than merely unlikely.
   *
   * Not persisted either. It is a hint to re-read, so a missed one costs a few
   * seconds until the backstop poll; the event table is keyed by run and this
   * belongs to no run.
   */
  publishBoard(taskId: string | null = null): void {
    this.emitter.emit(BOARD_CHANNEL, { type: "board:changed", taskId } satisfies BoardEvent);
  }

  subscribeBoard(fn: (ev: BoardEvent) => void): () => void {
    this.emitter.on(BOARD_CHANNEL, fn);
    return () => this.emitter.off(BOARD_CHANNEL, fn);
  }

  /**
   * Chat traffic, on its own channel for the same reason the board has one:
   * `/api/runs/:id/events` must never see it. Same invalidation philosophy too —
   * `chat:message` tells the client to re-read history, it does not carry the
   * message. `chat:thinking` is the one exception (a boolean), because "the
   * agent is typing" is ephemeral UI state with nothing to re-read.
   */
  publishChat(ev: ChatBusEvent): void {
    this.emitter.emit(CHAT_CHANNEL, ev);
  }

  subscribeChat(fn: (ev: ChatBusEvent) => void): () => void {
    this.emitter.on(CHAT_CHANNEL, fn);
    return () => this.emitter.off(CHAT_CHANNEL, fn);
  }
}

export const bus = new RunBus();
