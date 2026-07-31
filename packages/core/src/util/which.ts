import { accessSync, constants } from "node:fs";
import { access } from "node:fs/promises";
import { delimiter, join } from "node:path";

/**
 * Resolves a command to an absolute executable path using PATH.
 *
 * Deliberately does not shell out: `which` under a shell would pick up aliases
 * and shell functions that a spawned child process cannot execute.
 */
export async function which(command: string): Promise<string | null> {
  if (command.includes("/")) {
    return (await isExecutable(command)) ? command : null;
  }
  for (const candidate of candidates(command)) {
    if (await isExecutable(candidate)) return candidate;
  }
  return null;
}

/**
 * Synchronous `which`, for the spawn path.
 *
 * Needed because adapters build their command synchronously, and passing a bare
 * name to spawn is unsafe here: Node searches PATH ONLY, while `which` also
 * looks in the extra install directories below. That mismatch meant a runtime
 * could be DETECTED and then fail at execution with ENOENT — an engine started
 * from a GUI app or launchd (minimal PATH) would list every CLI as available
 * and then fail every single run.
 */
export function whichSync(command: string): string | null {
  if (command.includes("/")) {
    return isExecutableSync(command) ? command : null;
  }
  for (const candidate of candidates(command)) {
    if (isExecutableSync(candidate)) return candidate;
  }
  return null;
}

/** PATH entries first, then install locations a GUI-launched process may miss. */
function candidates(command: string): string[] {
  const pathEnv = process.env["PATH"] ?? "";
  const dirs = pathEnv.split(delimiter).filter((d) => d.length > 0);
  const home = process.env["HOME"];
  const extra = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    ...(home ? [join(home, ".local", "bin"), join(home, ".bun", "bin")] : []),
  ];
  return [...dirs, ...extra].map((dir) => join(dir, command));
}

async function isExecutable(p: string): Promise<boolean> {
  try {
    await access(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function isExecutableSync(p: string): boolean {
  try {
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}
