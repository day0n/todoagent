import assert from "node:assert/strict";
import { test } from "node:test";
import { isAllowedOrigin } from "./origin.ts";

/**
 * Which browser origins may drive this API.
 *
 * This is the only access control the engine has. There is no auth, and every
 * adapter runs its CLI with tool confirmation bypassed, so an origin that gets
 * through here can execute arbitrary code on the user's machine. That makes these
 * cases worth pinning individually rather than trusting the regex by inspection —
 * a prefix check would pass most of the tests below and still be exploitable.
 */

/** Runs `fn` with `TODOAGENT_WEB_ORIGIN` set, restoring it afterwards. */
function withEnv(value: string | undefined, fn: () => void): void {
  const before = process.env["TODOAGENT_WEB_ORIGIN"];
  if (value === undefined) delete process.env["TODOAGENT_WEB_ORIGIN"];
  else process.env["TODOAGENT_WEB_ORIGIN"] = value;
  try {
    fn();
  } finally {
    if (before === undefined) delete process.env["TODOAGENT_WEB_ORIGIN"];
    else process.env["TODOAGENT_WEB_ORIGIN"] = before;
  }
}

test("any loopback port is allowed", () => {
  /*
   * The M2 bug this fixes: the allowlist was pinned to :3000, so serving the web
   * app on any other port made every request fail in the browser while curl
   * against the same endpoint returned 200 — the app rendered its shell with no
   * data and no error, which reads as a client bug.
   */
  for (const origin of [
    "http://localhost:3000",
    "http://localhost:3111",
    "http://localhost:5173",
    "http://127.0.0.1:3000",
    "http://127.0.0.1:8787",
    "http://[::1]:3000",
    // No port at all is port 80, still loopback.
    "http://localhost",
    "http://127.0.0.1",
  ]) {
    withEnv(undefined, () => {
      assert.equal(isAllowedOrigin(origin), true, `${origin} should be allowed`);
    });
  }
});

test("a hostname that merely STARTS with localhost is refused", () => {
  /*
   * The attack the anchoring exists for. `localhost.evil.com` is a domain an
   * attacker can register, and it begins with the string "localhost" — so a
   * `startsWith` check, or an unanchored regex, hands any page served from it the
   * ability to drive this API. Given that reaching this API means arbitrary code
   * execution, this is the single most important assertion in the file.
   */
  for (const origin of [
    "http://localhost.evil.com",
    "http://localhost.evil.com:3000",
    "http://localhost.example.com",
    "http://127.0.0.1.evil.com",
    "http://127.0.0.1.evil.com:8787",
    // A prefix on the other side, in case the pattern is ever loosened at the front.
    "http://evil-localhost",
    "http://notlocalhost:3000",
    "http://evil.com/localhost",
  ]) {
    withEnv(undefined, () => {
      assert.equal(isAllowedOrigin(origin), false, `${origin} must be refused`);
    });
  }
});

test("a plain remote origin is refused", () => {
  withEnv(undefined, () => {
    assert.equal(isAllowedOrigin("http://evil.com"), false);
    assert.equal(isAllowedOrigin("https://example.com"), false);
    assert.equal(isAllowedOrigin("null"), false, "sandboxed iframes send the literal string");
    assert.equal(isAllowedOrigin(""), false, "a same-origin request sends no Origin header");
  });
});

test("https is not assumed, and neither is a bare host", () => {
  // Local dev is http; an operator wanting https names it explicitly below. This
  // is asserted so that widening it later is a deliberate decision, not a typo.
  withEnv(undefined, () => {
    assert.equal(isAllowedOrigin("https://localhost:3000"), false);
    assert.equal(isAllowedOrigin("localhost:3000"), false, "no scheme is not an origin");
    assert.equal(isAllowedOrigin("//localhost:3000"), false);
  });
});

test("a malformed port is refused rather than ignored", () => {
  withEnv(undefined, () => {
    assert.equal(isAllowedOrigin("http://localhost:"), false);
    assert.equal(isAllowedOrigin("http://localhost:abc"), false);
    // Six digits cannot be a port; the anchor is what rejects the trailing digit.
    assert.equal(isAllowedOrigin("http://localhost:123456"), false);
    assert.equal(isAllowedOrigin("http://localhost:3000/"), false, "an origin has no path");
    assert.equal(isAllowedOrigin("http://localhost:3000#x"), false);
  });
});

test("TODOAGENT_WEB_ORIGIN adds exact origins", () => {
  withEnv("https://todo.example.com", () => {
    assert.equal(isAllowedOrigin("https://todo.example.com"), true);
    // Exact means exact: no subdomain, no sibling path, no scheme swap.
    assert.equal(isAllowedOrigin("https://evil.todo.example.com"), false);
    assert.equal(isAllowedOrigin("http://todo.example.com"), false);
    assert.equal(isAllowedOrigin("https://todo.example.com.evil.com"), false);
  });
});

test("TODOAGENT_WEB_ORIGIN accepts a comma-separated list and tolerates spacing", () => {
  withEnv(" https://a.example.com , https://b.example.com/ ", () => {
    assert.equal(isAllowedOrigin("https://a.example.com"), true);
    // A trailing slash is stripped, since that is how a person pastes a URL.
    assert.equal(isAllowedOrigin("https://b.example.com"), true);
    assert.equal(isAllowedOrigin("https://c.example.com"), false);
  });
});

test("an empty or whitespace-only env var adds nothing", () => {
  // The bug this guards: splitting "" on "," yields [""], so an unset variable
  // would allowlist the empty origin and every request with no Origin header.
  for (const raw of ["", "   ", ",", " , , "]) {
    withEnv(raw, () => {
      assert.equal(isAllowedOrigin(""), false, `raw=${JSON.stringify(raw)}`);
      assert.equal(isAllowedOrigin("http://evil.com"), false);
      // Loopback still works regardless of the variable.
      assert.equal(isAllowedOrigin("http://localhost:3000"), true);
    });
  }
});

test("a change to the env var is picked up rather than cached forever", () => {
  // The cache keys on the raw string precisely so this holds; caching the parsed
  // set unconditionally would pin the first value read for the process lifetime.
  withEnv("https://first.example.com", () => {
    assert.equal(isAllowedOrigin("https://first.example.com"), true);
  });
  withEnv("https://second.example.com", () => {
    assert.equal(isAllowedOrigin("https://second.example.com"), true);
    assert.equal(isAllowedOrigin("https://first.example.com"), false);
  });
});
