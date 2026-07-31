/**
 * Orchestrator entry point.
 *
 * Declared in package.json's exports map but never created, so any
 * `import ... from "@council/core/orchestrator"` failed to resolve. Nothing
 * imported it yet, which is exactly why it went unnoticed.
 */
export { bus, type BusEvent } from "./bus.ts";
export {
  BudgetExceededError,
  recordEvent,
  runOne,
  runStructured,
  type RunOneOptions,
  type RunOneResult,
} from "./runner.ts";
export {
  approvePlanAndContinue,
  enforceDependencyStages,
  isBlocking,
  needsHumanJudgment,
  needsReproduction,
  pickReviewers,
  resolveEscalationAndContinue,
  routeMaker,
  runDiscussion,
  runPipeline,
  MAX_DISCUSSION_ROUNDS,
  MAX_ROUNDS,
  REVIEWERS_PER_SUBTASK,
  type PipelineOptions,
  type RosterEntry,
  type StagedTask,
} from "./pipeline.ts";
export { extractJson, repairPrompt, tryParse } from "./structured.ts";
