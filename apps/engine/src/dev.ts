/**
 * Development entry point: load `.env`, then start the engine.
 *
 * A separate file rather than a `process.loadEnvFile` call inside `server.ts`, and
 * the reason is the test suite. Eleven engine suites spawn `server.ts` directly and
 * do NOT set `TODOAGENT_MODEL`, so loading a `.env` from inside the server would
 * hand every one of them a real API key: any test whose stub CLI completes
 * successfully would then make a live classification request — real latency, real
 * money, and a suite whose result depends on someone else's network.
 *
 * Keeping the load here means the tests bypass it by construction rather than by
 * remembering to neutralise an environment variable in each file.
 *
 * `.env` is gitignored. It is read from the repository root because that is where a
 * person expects to put it, not from this package's directory.
 */
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const ENV_FILE = join(HERE, "..", "..", "..", ".env");

if (existsSync(ENV_FILE)) {
  /*
   * Values already in the environment WIN over the file.
   *
   * That is `loadEnvFile`'s own behaviour and it is the behaviour we want: an
   * explicit `TODOAGENT_MODEL= pnpm dev` has to be able to turn the model off for a
   * session without editing a file. Note that an empty string counts as set, which
   * is exactly how the test suites express "no model configured".
   */
  process.loadEnvFile(ENV_FILE);
  const model = process.env["TODOAGENT_MODEL"];
  console.log(
    model === undefined || model.trim() === ""
      ? "Loaded .env (no TODOAGENT_MODEL — chat and classification use their fallbacks)"
      : `Loaded .env — model ${model}`,
  );
} else {
  console.log("No .env at the repository root — chat is dormant, classification uses its heuristic.");
}

// Imported AFTER the load, so module-level `process.env` reads in the server see it.
await import("./server.ts");
