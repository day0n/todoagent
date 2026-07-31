import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Store } from "@council/core";

/**
 * Expert creation validation.
 *
 * Same class of problem as the git check on projects: without validation the
 * expert is created happily, joins the roster, gets routed work, and then every
 * turn assigned to it fails — at run time, far from the cause, after its
 * stage-mates have already spent real tokens.
 *
 * The "not installed" case is produced by booting the engine with a minimal PATH
 * and a throwaway HOME, since `which` also searches ~/.local/bin and
 * /opt/homebrew/bin. Which runtimes that hides depends on the machine, so the test
 * asks the API which ones are missing rather than hardcoding a guess.
 */

const SERVER = join(fileURLToPath(new URL(".", import.meta.url)), "server.ts");
const PORT = 8809; // distinct from the other engine suites

interface Fixture {
  dbPath: string;
  fakeHome: string;
  dispose: () => Promise<void>;
}

async function fixture(): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "council-experts-"));
  const fakeHome = join(root, "home");
  await mkdir(fakeHome, { recursive: true });

  const dbPath = join(root, "e.db");
  // Touch the database so the engine opens an already-migrated file.
  new Store(dbPath).close();

  return { dbPath, fakeHome, dispose: () => rm(root, { recursive: true, force: true }) };
}

/** Boots the engine, optionally with a restricted PATH/HOME. */
async function withEngine<T>(
  f: Fixture,
  fn: () => Promise<T>,
  restrict?: { path: string; home: string },
): Promise<T> {
  const child = spawn(process.execPath, ["--experimental-strip-types", SERVER], {
    env: {
      ...process.env,
      COUNCIL_DB: f.dbPath,
      COUNCIL_PORT: String(PORT),
      ...(restrict ? { PATH: restrict.path, HOME: restrict.home } : {}),
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

test("an expert on an uninstalled runtime is refused", async () => {
  const f = await fixture();
  try {
    await withEngine(
      f,
      async () => {
        const rt = await runtimes();
        // With a stripped PATH and HOME, several CLIs become invisible. Derived
        // from the API so the test does not depend on this machine's installs.
        const absent = rt.missing[0];
        assert.ok(
          absent !== undefined,
          "the restricted environment should hide at least one runtime",
        );

        const res = await createExpert({ name: "Ghost", runtimeKind: absent });

        assert.equal(res.status, 400);
        const body = (await res.json()) as { error: string };
        assert.match(body.error, /not installed/);
        // The message must say what IS available, so the user can pick instead of
        // guessing, and point at the probe rather than claiming the others work.
        assert.match(body.error, /Available:/);
        assert.match(body.error, /doctor --probe/);

        // Nothing stored, so the failure cannot resurface at run time.
        const list = (await (await fetch(`http://127.0.0.1:${PORT}/api/experts`)).json()) as unknown[];
        assert.equal(list.length, 0);
      },
      { path: "/usr/bin:/bin", home: f.fakeHome },
    );
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
