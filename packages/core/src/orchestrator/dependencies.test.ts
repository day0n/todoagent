import assert from "node:assert/strict";
import { test } from "node:test";
import { enforceDependencyStages, type StagedTask } from "./pipeline.ts";

/**
 * Tests for reconciling declared dependencies against execution stages.
 *
 * `stage` is the only ordering the executor honours: a stage runs in parallel and
 * the barrier gates the next one. `dependsOn` was persisted and never read, so a
 * plan that placed two subtasks in the same stage and declared a dependency
 * between them ran them concurrently in isolated worktrees — the downstream one
 * literally could not see its prerequisite's output. No error, just work built on
 * a missing foundation.
 */

function task(id: string, stage: number, dependsOn: string[] = []): StagedTask {
  return { id, stage, dependsOn };
}

const stageOf = (tasks: StagedTask[], id: string): number | undefined =>
  tasks.find((t) => t.id === id)?.stage;

test("a same-stage dependency pushes the dependent later", () => {
  const { tasks, promoted, cycle } = enforceDependencyStages([
    task("a", 0),
    task("b", 0, ["a"]),
  ]);

  // The core repair: b cannot run beside a and still see its output.
  assert.equal(stageOf(tasks, "a"), 0);
  assert.equal(stageOf(tasks, "b"), 1);
  assert.deepEqual(promoted, [{ id: "b", from: 0, to: 1 }]);
  assert.deepEqual(cycle, []);
});

test("an already-correct plan is left untouched", () => {
  const input = [task("a", 0), task("b", 1, ["a"]), task("c", 2, ["b"])];
  const { tasks, promoted } = enforceDependencyStages(input);
  // No spurious promotions: a plan the model got right must not be rewritten,
  // or the log fills with noise nobody can act on.
  assert.deepEqual(promoted, []);
  assert.deepEqual(
    tasks.map((t) => t.stage),
    [0, 1, 2],
  );
});

test("a chain collapses into sequential stages", () => {
  const { tasks } = enforceDependencyStages([
    task("a", 0),
    task("b", 0, ["a"]),
    task("c", 0, ["b"]),
    task("d", 0, ["c"]),
  ]);
  assert.deepEqual(
    tasks.map((t) => t.stage),
    [0, 1, 2, 3],
  );
});

test("a chain resolves regardless of input order", () => {
  // Relaxation must not depend on the array happening to be topologically sorted.
  const { tasks, cycle } = enforceDependencyStages([
    task("c", 0, ["b"]),
    task("b", 0, ["a"]),
    task("a", 0),
  ]);
  assert.deepEqual(cycle, []);
  assert.equal(stageOf(tasks, "a"), 0);
  assert.equal(stageOf(tasks, "b"), 1);
  assert.equal(stageOf(tasks, "c"), 2);
});

test("independent tasks stay in the same stage", () => {
  const { tasks, promoted } = enforceDependencyStages([
    task("a", 0),
    task("b", 0),
    task("c", 0),
  ]);
  // Parallelism is the point; nothing should be serialised without a reason.
  assert.deepEqual(
    tasks.map((t) => t.stage),
    [0, 0, 0],
  );
  assert.deepEqual(promoted, []);
});

test("multiple dependencies push past the LATEST of them", () => {
  const { tasks } = enforceDependencyStages([
    task("a", 0),
    task("b", 2),
    task("c", 0, ["a", "b"]),
  ]);
  // Clearing only the earliest dependency would still race the later one.
  assert.equal(stageOf(tasks, "c"), 3);
});

test("a dependency already in a later stage is respected", () => {
  const { tasks } = enforceDependencyStages([task("a", 5), task("b", 0, ["a"])]);
  assert.equal(stageOf(tasks, "b"), 6);
});

test("an unknown dependency id is ignored", () => {
  const { tasks, promoted, cycle } = enforceDependencyStages([
    task("a", 0, ["does-not-exist"]),
  ]);
  /*
   * Models invent ids. Failing the whole plan over a hallucinated reference would
   * cost a full extra planning turn to fix something that constrains nothing —
   * there is no such task, so there is nothing to wait for.
   */
  assert.equal(stageOf(tasks, "a"), 0);
  assert.deepEqual(promoted, []);
  assert.deepEqual(cycle, []);
});

test("a self-dependency is ignored rather than deadlocking", () => {
  const { tasks, cycle } = enforceDependencyStages([task("a", 0, ["a"])]);
  // A task cannot wait for itself; treating it literally would loop forever.
  assert.equal(stageOf(tasks, "a"), 0);
  assert.deepEqual(cycle, []);
});

test("a two-node cycle is reported instead of looping forever", () => {
  const { cycle } = enforceDependencyStages([task("a", 0, ["b"]), task("b", 0, ["a"])]);
  /*
   * Bounded relaxation is what makes this terminate: a chain of N tasks settles in
   * at most N passes, so exceeding that proves a cycle. The caller refuses the
   * plan — executing an order that cannot satisfy its own constraints would
   * produce work built on nothing.
   */
  assert.ok(cycle.length > 0, "the cycle must be reported");
  assert.ok(cycle.includes("a") || cycle.includes("b"));
});

test("a longer cycle is also caught", () => {
  const { cycle } = enforceDependencyStages([
    task("a", 0, ["c"]),
    task("b", 0, ["a"]),
    task("c", 0, ["b"]),
  ]);
  assert.ok(cycle.length > 0);
});

test("a cycle among some tasks does not hide the rest", () => {
  const { cycle } = enforceDependencyStages([
    task("ok", 0),
    task("x", 0, ["y"]),
    task("y", 0, ["x"]),
  ]);
  // Still refused: a partially executable plan is not what the orchestrator
  // asked for, and silently dropping the cyclic half would lose scope.
  assert.ok(cycle.length > 0);
});

test("an empty plan is handled", () => {
  const { tasks, promoted, cycle } = enforceDependencyStages([]);
  assert.deepEqual(tasks, []);
  assert.deepEqual(promoted, []);
  assert.deepEqual(cycle, []);
});

test("extra fields on the task survive the rewrite", () => {
  // The pipeline passes full plan subtasks through this, so title/brief/etc must
  // not be dropped on the way to the database.
  const input = [
    { id: "a", stage: 0, dependsOn: [], title: "First", capability: "backend" },
    { id: "b", stage: 0, dependsOn: ["a"], title: "Second", capability: "frontend" },
  ];
  const { tasks } = enforceDependencyStages(input);
  assert.equal(tasks[1]?.title, "Second");
  assert.equal(tasks[1]?.capability, "frontend");
  assert.equal(tasks[1]?.stage, 1);
});

test("the input array is not mutated", () => {
  const input = [task("a", 0), task("b", 0, ["a"])];
  const snapshot = JSON.parse(JSON.stringify(input));
  enforceDependencyStages(input);
  // The caller logs the original plan alongside the repair; mutating in place
  // would make the "from" side of every promotion identical to the "to" side.
  assert.deepEqual(input, snapshot);
});

test("a wide fan-out converges", () => {
  // One root with 20 dependents, all declared in stage 0.
  const tasks: StagedTask[] = [task("root", 0)];
  for (let i = 0; i < 20; i++) tasks.push(task(`leaf-${i}`, 0, ["root"]));
  const { tasks: out, cycle, promoted } = enforceDependencyStages(tasks);
  assert.deepEqual(cycle, []);
  assert.equal(promoted.length, 20);
  // All leaves land in the SAME stage: they depend on root, not on each other, so
  // serialising them would throw away the parallelism the design exists for.
  assert.ok(out.slice(1).every((t) => t.stage === 1));
});
