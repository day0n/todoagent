import assert from "node:assert/strict";
import { test } from "node:test";
import { buildArgs as claudeArgs } from "./claude.ts";
import { buildArgs as cursorArgs } from "./cursor.ts";

/**
 * Session resume, from `ExecOptions` to the CLI's argv.
 *
 * Worth its own file because this capability existed at both ends and was joined
 * by nothing. Both adapters have pushed `--resume` since M0 and every adapter has
 * recorded `attempt.sessionId` since M0 — but `RunOneOptions` had no field for it,
 * so no orchestration code could carry an id from one to the other. The answer
 * loop is the first consumer.
 *
 * Asserting on argv rather than on a spawned process: argv IS the contract with
 * the CLI, and a test that spawns `claude` would either need it installed or be
 * testing a stub's opinion of the flag instead of the flag.
 */

/** Finds a flag and returns the token after it, or null when absent. */
function valueAfter(args: string[], flag: string): string | null {
  const i = args.indexOf(flag);
  if (i < 0) return null;
  return args[i + 1] ?? null;
}

const SESSION = "3608803c-8f21-4c0e-9d77-5b1a2e4f6c90";

test("claude carries the session id as --resume", () => {
  const args = claudeArgs("继续", { cwd: "/tmp/x", resumeSessionId: SESSION });

  // Adjacency, not mere presence: `--resume` takes its value as the next token, so
  // an id that landed anywhere else would be parsed as a positional argument.
  assert.equal(valueAfter(args, "--resume"), SESSION);
});

test("cursor carries the session id as --resume", () => {
  const args = cursorArgs("继续", { cwd: "/tmp/x", resumeSessionId: SESSION });
  assert.equal(valueAfter(args, "--resume"), SESSION);
});

test("no session id means no --resume flag at all", () => {
  // Passing the flag with an empty value would start a cold session on claude and
  // error on cursor, so absence has to be absence.
  for (const build of [claudeArgs, cursorArgs]) {
    assert.equal(build("从头开始", { cwd: "/tmp/x" }).includes("--resume"), false);
    assert.equal(
      build("从头开始", { cwd: "/tmp/x", resumeSessionId: null }).includes("--resume"),
      false,
    );
    // Empty string is falsy and must behave like null rather than emitting `--resume ""`.
    assert.equal(
      build("从头开始", { cwd: "/tmp/x", resumeSessionId: "" }).includes("--resume"),
      false,
    );
  }
});

test("a user-supplied --resume cannot override the platform's", () => {
  /*
   * `--resume` is in both adapters' BLOCKED maps, and this pins why that matters
   * now that the platform actually sets it. An expert's `extraArgs` reaching the
   * CLI with a second `--resume` would have the last one win, silently continuing
   * a session the engine knows nothing about — with the answer the user typed
   * delivered into the wrong conversation.
   */
  for (const build of [claudeArgs, cursorArgs]) {
    const args = build("继续", {
      cwd: "/tmp/x",
      resumeSessionId: SESSION,
      extraArgs: ["--resume", "attacker-session"],
    });
    assert.equal(args.filter((a) => a === "--resume").length, 1, "exactly one --resume survives");
    assert.equal(valueAfter(args, "--resume"), SESSION);
    assert.equal(args.includes("attacker-session"), false);
  }
});

test("resume does not disturb the flags that make a headless run work", () => {
  // A resumed turn is still unattended: it cannot answer a permission prompt, and
  // it still has to emit the streaming protocol the parser reads.
  const c = claudeArgs("继续", { cwd: "/tmp/x", resumeSessionId: SESSION });
  assert.equal(valueAfter(c, "--output-format"), "stream-json");
  assert.equal(valueAfter(c, "--permission-mode"), "bypassPermissions");
  assert.equal(valueAfter(c, "-p"), "继续");

  const u = cursorArgs("继续", { cwd: "/tmp/x", resumeSessionId: SESSION });
  assert.equal(valueAfter(u, "--output-format"), "stream-json");
  assert.equal(u.includes("--force"), true);
  assert.equal(valueAfter(u, "--workspace"), "/tmp/x");
});

test("a model override and a resume coexist", () => {
  // Both are optional and both push two tokens; an ordering bug here would pair a
  // flag with the other's value.
  const args = claudeArgs("继续", {
    cwd: "/tmp/x",
    model: "claude-opus-5",
    resumeSessionId: SESSION,
  });
  assert.equal(valueAfter(args, "--model"), "claude-opus-5");
  assert.equal(valueAfter(args, "--resume"), SESSION);
});
