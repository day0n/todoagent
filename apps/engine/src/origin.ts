/**
 * Which browser origins may call this API.
 *
 * Its own module, with no side effects, because `server.ts` cannot be imported
 * from a test: that file opens `defaultDbPath()`, calls `reconcileOrphanedRuns()`
 * — which marks live-looking runs as failed — and binds a port, all at module
 * load. A unit test importing it would rewrite the user's real database. Every
 * engine suite therefore spawns a subprocess with `TODOAGENT_DB` pointed
 * elsewhere, and this logic is the one part worth testing directly.
 */

/** Cache for the parsed env var, keyed on its raw value so a change is picked up. */
let cached: { raw: string; origins: Set<string> } | null = null;

function extraOrigins(): Set<string> {
  const raw = process.env["TODOAGENT_WEB_ORIGIN"] ?? "";
  if (cached !== null && cached.raw === raw) return cached.origins;
  const origins = new Set(
    raw
      .split(",")
      .map((o) => o.trim().replace(/\/$/, ""))
      .filter((o) => o.length > 0),
  );
  cached = { raw, origins };
  return origins;
}

/**
 * Any loopback origin on any port, plus whatever `TODOAGENT_WEB_ORIGIN` names.
 *
 * The pattern is ANCHORED, which is the whole reason it is a regex rather than a
 * `startsWith` check. `http://localhost.evil.com` begins with `http://localhost`
 * and is a domain an attacker can register; a prefix test would hand any such
 * page the ability to drive this API. That matters more here than in most
 * services: every adapter runs its CLI with tool confirmation bypassed, so
 * reaching this API means arbitrary code execution on the user's machine. The
 * origin check is the only thing standing in front of it, since there is no auth.
 *
 * Widening from the previous hardcoded `:3000` does not enlarge the attack
 * surface — a process that can bind a loopback port can already call this API
 * directly, without a browser — but that argument only holds while the host is
 * pinned to the end of the string.
 *
 * `TODOAGENT_WEB_ORIGIN` entries are compared EXACTLY: no wildcards, no prefixes,
 * no scheme guessing. An operator opting into a non-loopback origin should have to
 * write it out in full.
 */
export function isAllowedOrigin(origin: string): boolean {
  if (origin === "") return false;
  if (extraOrigins().has(origin)) return true;
  return /^http:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?$/.test(origin);
}
