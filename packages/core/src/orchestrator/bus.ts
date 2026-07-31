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
}

export const bus = new RunBus();
