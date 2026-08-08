import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@todoagent/core";

/**
 * Expert creation validation.
 *
 * Same class of problem as the git check on projects: without validation the
 * expert is created happily, joins the roster, gets routed work, and then every
 * turn assigned to it fails — at run time, far from the cause, after its
 * stage-mates have already spent real tokens.
 *
 * Every runtime is shadowed below so these compatibility checks never invoke a
 * developer's real CLI.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8809; // distinct from the other engine suites

interface Fixture {
  dbPath: string;
  fakeHome: string;
  stubbedPath: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "todoagent-experts-"));
  const fakeHome = join(root, "home");
  const binDir = join(root, "bin");
  await mkdir(fakeHome, { recursive: true });
  await mkdir(binDir, { recursive: true });

  // Every detection candidate is shadowed, so this suite never executes a
  // developer's real coding CLI merely to learn its version.
  for (const name of ["claude", "codex", "gemini", "cursor-agent", "grok", "kiro-cli"]) {
    const path = join(binDir, name);
    await writeFile(path, "#!/bin/sh\nprintf 'stub 1.0.0\\n'\n", "utf8");
    await chmod(path, 0o755);
  }

  const dbPath = join(root, "e.db");
  // Touch the database so the engine opens an already-migrated file.
  new Store(dbPath).close();

  return {
    dbPath,
    fakeHome,
    stubbedPath: `${binDir}${delimiter}/usr/bin:/bin`,
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

/** Boots the engine against only the fixture CLIs. */
async function withEngine<T>(f: Fixture, fn: () => Promise<T>): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      TODOAGENT_DB: f.dbPath,
      TODOAGENT_PORT: String(PORT),
      PATH: f.stubbedPath,
      HOME: f.fakeHome,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const deadline = Date.now() + 30_000;
    for (;;) {
      if (Date.now() > deadline) throw new Error("engine did not start within 30s");
      try {
        const res = await fetch(`http://127.0.0.1:${PORT}/api/health`);
        if (res.ok) break;
      } catch {
        /* not listening yet */
      }
      await new Promise((r) => setTimeout(r, 150));
    }
    return await fn();
  } finally {
    child.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 200));
  }
}

function createExpert(body: Record<string, unknown>): Promise<Response> {
  return fetch(`http://127.0.0.1:${PORT}/api/experts`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      description: "",
      model: null,
      systemPrompt: "",
      capabilities: [],
      ...body,
    }),
  });
}

async function runtimes(): Promise<{ detected: Array<{ kind: string }>; missing: string[] }> {
  return (await (await fetch(`http://127.0.0.1:${PORT}/api/runtimes`)).json()) as {
    detected: Array<{ kind: string }>;
    missing: string[];
  };
}

test("runtime API exposes all CLIs, compatibility fields, refresh and verification state", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const first = (await (
        await fetch(`http://127.0.0.1:${PORT}/api/runtimes`)
      ).json()) as {
        runtimes: Array<{
          kind: string;
          label: string;
          displayName: string;
          status: string;
          execPath: string | null;
          activeRuns: number;
        }>;
        detected: Array<{ kind: string }>;
        known: string[];
        missing: string[];
      };
      assert.equal(first.runtimes.length, 6);
      assert.equal(first.known.length, 6);
      assert.equal(first.detected.length, 6);
      assert.deepEqual(first.missing, []);
      assert.ok(first.runtimes.every((runtime) => runtime.status === "unverified"));
      assert.ok(first.runtimes.every((runtime) => runtime.label === runtime.displayName));
      assert.ok(first.runtimes.every((runtime) => runtime.execPath?.startsWith(f.stubbedPath.split(delimiter)[0] ?? "")));
      assert.ok(first.runtimes.every((runtime) => runtime.activeRuns === 0));

      const refreshed = await fetch(`http://127.0.0.1:${PORT}/api/runtimes/refresh`, {
        method: "POST",
      });
      assert.equal(refreshed.status, 200);
      assert.equal(((await refreshed.json()) as { runtimes: unknown[] }).runtimes.length, 6);

      const unknown = await fetch(`http://127.0.0.1:${PORT}/api/runtimes/not-real/verify`, {
        method: "POST",
      });
      assert.equal(unknown.status, 400);

      // The stub only reports a version; it does not speak Claude's stream
      // protocol. Verification therefore completes as an explicit state rather
      // than turning a valid HTTP request into a 5xx.
      const verified = await fetch(`http://127.0.0.1:${PORT}/api/runtimes/claude/verify`, {
        method: "POST",
      });
      assert.equal(verified.status, 200);
      const state = (await verified.json()) as { status: string; verifyError: string | null };
      assert.notEqual(state.status, "ready");
      assert.ok((state.verifyError ?? "").length > 0);
    });
  } finally {
    await f.dispose();
  }
});

test("an expert on an installed runtime is accepted", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const rt = await runtimes();
      const present = rt.detected[0]?.kind;
      assert.ok(present !== undefined, "this machine has at least one coding CLI installed");

      const res = await createExpert({
        name: "Real",
        runtimeKind: present,
        capabilities: ["general"],
      });
      // A bug in the check would block ALL expert creation, which is worse than the
      // problem it fixes — so the positive path is asserted too.
      assert.equal(res.status, 201);
      const expert = (await res.json()) as { name: string; runtimeKind: string };
      assert.equal(expert.name, "Real");
      assert.equal(expert.runtimeKind, present);
    });
  } finally {
    await f.dispose();
  }
});

test("a duplicate expert name is refused", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const present = (await runtimes()).detected[0]?.kind;
      assert.ok(present !== undefined);

      assert.equal((await createExpert({ name: "Twin", runtimeKind: present })).status, 201);
      const again = await createExpert({ name: "Twin", runtimeKind: present });
      // Names are how experts are referenced in prompts and rosters; two with the
      // same name would make the record ambiguous.
      assert.equal(again.status, 409);
      assert.match(((await again.json()) as { error: string }).error, /already exists/);
    });
  } finally {
    await f.dispose();
  }
});

test("an unknown runtime kind is rejected at the schema", async () => {
  const f = await fixture();
  try {
    await withEngine(f, async () => {
      const res = await createExpert({ name: "Nonsense", runtimeKind: "gpt-5-imaginary" });
      // Caught by the enum before the install check, so the error names the field
      // rather than reporting it as "not installed" — which would be misleading.
      assert.equal(res.status, 400);
    });
  } finally {
    await f.dispose();
  }
});
