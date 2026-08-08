import { accessSync, constants } from "node:fs";
import { isAbsolute } from "node:path";
import { getAdapter } from "../adapters/index.ts";
import type { Store } from "../db/index.ts";
import {
  RUNTIME_DISPLAY_NAMES,
  RUNTIME_KINDS,
  type DetectedRuntime,
  type ExecutionTarget,
  type LocalRuntime,
  type RuntimeInfo,
  type RuntimeKind,
  type RuntimeStatus,
} from "../types.ts";
import { probeRuntime, type RuntimeProbeResult } from "./probe.ts";

export const DEFAULT_RUNTIME_REFRESH_INTERVAL_MS = 120_000;
const DETECTION_ERROR_PREFIX = "runtime detection failed: ";

export interface RuntimeManagerOptions {
  refreshIntervalMs?: number;
  detect?: (kind: RuntimeKind) => Promise<DetectedRuntime | null>;
  probe?: (target: ExecutionTarget) => Promise<RuntimeProbeResult>;
  now?: () => string;
}

/** True when a failure means the CLI itself is no longer trustworthy. */
export function classifyRuntimeFailure(error: string): "auth_required" | "error" | null {
  if (
    /not authenticated|authentication|unauthori[sz]ed|forbidden|log[ -]?in|sign[ -]?in|credentials?|api[_ -]?key|\b401\b|\b403\b/i.test(
      error,
    )
  ) {
    return "auth_required";
  }
  if (
    /spawn failed|\bENOENT\b|\bEACCES\b|executable .*not found|no such file|produced no completed turn|no parseable events|protocol|parse error|invalid json|handshake/i.test(
      error,
    )
  ) {
    return "error";
  }
  return null;
}

/**
 * Detection failures are cheap, transient observations and may be healed by the
 * next successful scan. Real probe failures are deliberately excluded: a PATH
 * refresh cannot prove that authentication or the streaming protocol recovered.
 *
 * The bare SQLite messages cover rows written by development builds before the
 * explicit prefix existed.
 */
function isDetectionError(error: string | null): boolean {
  if (error === null) return false;
  return (
    error.startsWith(DETECTION_ERROR_PREFIX) ||
    /^database is locked\b/i.test(error.trim()) ||
    /^SQLITE_BUSY\b/i.test(error.trim())
  );
}

/** Owns discovery, real verification, readiness persistence and refresh timing. */
export class RuntimeManager {
  private readonly store: Store;
  private readonly detectRuntime: (kind: RuntimeKind) => Promise<DetectedRuntime | null>;
  private readonly probeTarget: (target: ExecutionTarget) => Promise<RuntimeProbeResult>;
  private readonly now: () => string;
  private readonly refreshIntervalMs: number;
  private readonly verifications = new Map<RuntimeKind, Promise<RuntimeInfo>>();
  private refreshInFlight: Promise<RuntimeInfo[]> | null = null;
  private refreshTimer: NodeJS.Timeout | null = null;

  constructor(store: Store, options: RuntimeManagerOptions = {}) {
    this.store = store;
    this.detectRuntime = options.detect ?? ((kind) => getAdapter(kind).detect());
    this.probeTarget = options.probe ?? probeRuntime;
    this.now = options.now ?? (() => new Date().toISOString());
    this.refreshIntervalMs = options.refreshIntervalMs ?? DEFAULT_RUNTIME_REFRESH_INTERVAL_MS;

    // A caller can render all six runtimes before the asynchronous startup scan
    // finishes. This is idempotent and never overwrites persisted verification.
    for (const kind of RUNTIME_KINDS) {
      if (this.store.getLocalRuntime(kind) !== null) continue;
      this.store.upsertLocalRuntime(this.missing(kind));
    }
  }

  /** Initial scan plus the two-minute rediscovery loop. Safe to call repeatedly. */
  async start(): Promise<RuntimeInfo[]> {
    const runtimes = await this.refresh();
    if (this.refreshTimer === null && this.refreshIntervalMs > 0) {
      this.refreshTimer = setInterval(() => void this.refresh(), this.refreshIntervalMs);
      this.refreshTimer.unref();
    }
    return runtimes;
  }

  stop(): void {
    if (this.refreshTimer !== null) clearInterval(this.refreshTimer);
    this.refreshTimer = null;
  }

  refresh(): Promise<RuntimeInfo[]> {
    if (this.refreshInFlight !== null) return this.refreshInFlight;
    const pending = this.doRefresh().finally(() => {
      if (this.refreshInFlight === pending) this.refreshInFlight = null;
    });
    this.refreshInFlight = pending;
    return pending;
  }

  private async doRefresh(): Promise<RuntimeInfo[]> {
    await Promise.all(
      RUNTIME_KINDS.map(async (kind) => {
        const previous = this.store.getLocalRuntime(kind) ?? this.missing(kind);
        try {
          const detected = await this.detectRuntime(kind);
          if (detected === null) {
            this.store.upsertLocalRuntime({
              ...this.missing(kind),
              detectedAt: previous.detectedAt,
              verifyError: previous.execPath === null ? null : `${RUNTIME_DISPLAY_NAMES[kind]} was not found`,
            });
            return;
          }

          const unchanged =
            previous.execPath === detected.execPath && previous.version === detected.version;
          let status: RuntimeStatus = unchanged ? previous.status : "unverified";
          let verifyError = unchanged ? previous.verifyError : null;
          if (unchanged && status === "error" && isDetectionError(previous.verifyError)) {
            // The same binary is visible again. Restore only what was previously
            // earned: a successful probe may return to ready; an executable that
            // was never verified returns to unverified.
            status = previous.verifiedAt === null ? "unverified" : "ready";
            verifyError = null;
          }
          // A process can die while verification is in flight. On the next app
          // start there is no promise to settle this persisted transient state.
          if (status === "verifying" && !this.verifications.has(kind)) status = "unverified";
          this.store.upsertLocalRuntime({
            kind,
            execPath: detected.execPath,
            version: detected.version,
            status,
            detectedAt: this.now(),
            verifiedAt: unchanged ? previous.verifiedAt : null,
            verifyError,
          });
        } catch (error) {
          this.store.upsertLocalRuntime({
            ...previous,
            status: "error",
            verifyError: `${DETECTION_ERROR_PREFIX}${error instanceof Error ? error.message : String(error)}`,
          });
        }
      }),
    );
    return this.list();
  }

  verify(kind: RuntimeKind): Promise<RuntimeInfo> {
    const existing = this.verifications.get(kind);
    if (existing) return existing;
    const pending = this.doVerify(kind).finally(() => {
      if (this.verifications.get(kind) === pending) this.verifications.delete(kind);
    });
    this.verifications.set(kind, pending);
    return pending;
  }

  private async doVerify(kind: RuntimeKind): Promise<RuntimeInfo> {
    const current = this.store.getLocalRuntime(kind);
    if (current?.execPath === null || current?.version === null || current === null) {
      const missing: LocalRuntime = {
        ...(current ?? this.missing(kind)),
        status: "missing",
        verifyError: `${RUNTIME_DISPLAY_NAMES[kind]} is not installed`,
      };
      this.store.upsertLocalRuntime(missing);
      return this.info(missing, 0);
    }
    this.store.upsertLocalRuntime({ ...current, status: "verifying", verifyError: null });
    const target: ExecutionTarget = {
      runtimeKind: kind,
      displayName: RUNTIME_DISPLAY_NAMES[kind],
      execPath: current.execPath,
      version: current.version,
    };
    let result: RuntimeProbeResult;
    try {
      result = await this.probeTarget(target);
    } catch (error) {
      result = {
        kind,
        ok: false,
        output: "",
        error: error instanceof Error ? error.message : String(error),
        durationMs: 0,
        eventCount: 0,
        eventTypes: [],
      };
    }
    // Ignore a stale probe if a refresh observed a different executable while it
    // was running. That new binary must earn readiness with its own probe.
    const latest = this.store.getLocalRuntime(kind);
    if (
      latest?.execPath !== target.execPath ||
      latest.version !== target.version
    ) {
      return this.info(latest ?? this.missing(kind), 0);
    }
    const failure = result.error ?? "runtime verification failed";
    const status: RuntimeStatus = result.ok
      ? "ready"
      : classifyRuntimeFailure(failure) === "auth_required"
        ? "auth_required"
        : "error";
    const next: LocalRuntime = {
      ...latest,
      status,
      verifiedAt: result.ok ? this.now() : latest.verifiedAt,
      verifyError: result.ok ? null : failure,
    };
    this.store.upsertLocalRuntime(next);
    return this.info(next, 0);
  }

  list(activeCounts: Partial<Record<RuntimeKind, number>> = {}): RuntimeInfo[] {
    return RUNTIME_KINDS.map((kind) =>
      this.info(this.store.getLocalRuntime(kind) ?? this.missing(kind), activeCounts[kind] ?? 0),
    );
  }

  getReadyTarget(kind: RuntimeKind): ExecutionTarget | null {
    const runtime = this.store.getLocalRuntime(kind);
    if (
      runtime?.status !== "ready" ||
      runtime.execPath === null ||
      runtime.version === null
    ) {
      return null;
    }
    if (!isAbsolute(runtime.execPath)) {
      this.store.upsertLocalRuntime({
        ...runtime,
        status: "error",
        verifyError: "verified executable path is not absolute",
      });
      return null;
    }
    try {
      accessSync(runtime.execPath, constants.X_OK);
    } catch {
      this.store.upsertLocalRuntime({
        ...this.missing(kind),
        detectedAt: runtime.detectedAt,
        verifyError: `${RUNTIME_DISPLAY_NAMES[kind]} executable is no longer available`,
      });
      return null;
    }
    return {
      runtimeKind: kind,
      displayName: RUNTIME_DISPLAY_NAMES[kind],
      execPath: runtime.execPath,
      version: runtime.version,
    };
  }

  /**
   * Invalidates readiness only for CLI-level failures. A test failure or a bad
   * implementation is task output and must not make the runtime disappear.
   */
  recordExecutionFailure(target: ExecutionTarget, error: string | null): void {
    if (!error) return;
    const status = classifyRuntimeFailure(error);
    if (status === null) return;
    const current = this.store.getLocalRuntime(target.runtimeKind);
    if (
      current?.status !== "ready" ||
      current.execPath !== target.execPath ||
      current.version !== target.version
    ) {
      return;
    }
    this.store.upsertLocalRuntime({ ...current, status, verifyError: error });
  }

  private info(runtime: LocalRuntime, activeRuns: number): RuntimeInfo {
    const displayName = RUNTIME_DISPLAY_NAMES[runtime.kind];
    return { ...runtime, displayName, label: displayName, activeRuns };
  }

  private missing(kind: RuntimeKind): LocalRuntime {
    return {
      kind,
      execPath: null,
      version: null,
      status: "missing",
      detectedAt: null,
      verifiedAt: null,
      verifyError: null,
    };
  }
}
