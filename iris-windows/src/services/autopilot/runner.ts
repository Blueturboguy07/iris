//
// The autopilot state machine — the Windows port of the macOS drive loop in
// `GuideSessionController.driveAutopilotFromTheCurrentStep`.
//
// It is a *pumped* machine, not a background task: the main process calls
// `runUntilBlocked`, drains the events it produced, and forwards them to the
// renderer; when the machine stops on something only the reader can settle (a
// sign-in, a confirm tap) the caller resumes it with `readerFinishedCurrentStep`
// or `confirmCurrentCommand`. Keeping timers and windows out of the core is what
// lets the whole thing be unit-tested with a `MockShell` on any host.
//
// The no-click rule matches macOS: a `command` step runs and advances itself; an
// `open` step is finished the moment Iris opens it, so it advances with no tap;
// only `sign_in`/`permission`/`manual` steps stop and wait for the reader, with
// an instruction the UI floats the eye next to.
//

import type { InstallRecipe, RecipeOutput, RecipeStep, StepCheck, StepKind } from "./recipe";
import type { ApprovedCommand, Provenance } from "./risk";
import { approve, approveAfterAReaderTap, assess } from "./risk";
import {
  DEFAULT_COMMAND_TIMEOUT_MS,
  LONG_RUNNING_GRACE_MS,
  type CommandOutcome,
  type ShellSession,
} from "./shell";

const RECIPE_PROVENANCE: Provenance = "vetted_recipe";

/// Something the runner did that the UI should render. Plain objects: serialized
/// straight to the renderer over IPC.
export type AutopilotEvent =
  | { readonly type: "stepStarted"; readonly index: number; readonly total: number; readonly title: string; readonly kind: StepKind }
  | { readonly type: "commandStarted"; readonly text: string }
  | { readonly type: "commandFinished"; readonly exitCode: number; readonly output: string }
  /// The main process should open this URL/app; opening it is the whole step.
  | { readonly type: "openRequested"; readonly href: string }
  /// Only the reader can finish this. Float the eye to it and show this.
  | { readonly type: "handedToReader"; readonly instruction: string; readonly href?: string }
  /// A command needs one explicit tap before it runs.
  | { readonly type: "needsConfirm"; readonly command: string; readonly reason: string }
  /// A command no tap can make informed; the install stops here for the reader.
  | { readonly type: "surfaced"; readonly reason: string; readonly failingCommand?: string }
  | { readonly type: "advanced"; readonly index: number }
  | { readonly type: "finished"; readonly output: RecipeOutput };

/// Why the runner stopped pumping. Everything except `finished`/`sessionFailed`
/// is resumable.
export type RunnerStatus =
  | { readonly type: "finished"; readonly output: RecipeOutput }
  | {
      readonly type: "needsReader";
      readonly stepIndex: number;
      readonly instruction: string;
      readonly href?: string;
      /// Present when Iris can confirm the step itself by polling this check, so
      /// the reader never has to tap "done".
      readonly check?: StepCheck;
    }
  | { readonly type: "needsConfirm"; readonly stepIndex: number; readonly command: string; readonly reason: string }
  | { readonly type: "surfaced"; readonly stepIndex: number; readonly reason: string; readonly failingCommand?: string }
  | { readonly type: "sessionFailed" };

type StepProgress = { readonly kind: "advanced" } | { readonly kind: "blocked"; readonly status: RunnerStatus };

export class AutopilotRunner {
  private index = 0;
  private finished = false;
  private events: AutopilotEvent[] = [];

  constructor(private readonly recipe: InstallRecipe) {}

  /// Takes the events produced since the last drain. The caller forwards these
  /// to the renderer.
  drainEvents(): AutopilotEvent[] {
    const drained = this.events;
    this.events = [];
    return drained;
  }

  currentIndex(): number {
    return this.index;
  }

  private currentStep(): RecipeStep | undefined {
    return this.recipe.steps[this.index];
  }

  private emit(event: AutopilotEvent): void {
    this.events.push(event);
  }

  private advance(): void {
    this.index += 1;
    this.emit({ type: "advanced", index: this.index });
  }

  private surface(reason: string, failingCommand?: string): RunnerStatus {
    this.emit({ type: "surfaced", reason, failingCommand });
    return { type: "surfaced", stepIndex: this.index, reason, failingCommand };
  }

  /// Runs and auto-advances every step Iris owns until it either finishes, or
  /// reaches something only the reader can settle.
  async runUntilBlocked(shell: ShellSession): Promise<RunnerStatus> {
    for (;;) {
      if (this.index >= this.recipe.steps.length) {
        this.finished = true;
        const output = this.recipe.output;
        this.emit({ type: "finished", output });
        return { type: "finished", output };
      }

      const step = this.recipe.steps[this.index]!;
      this.emit({
        type: "stepStarted",
        index: this.index,
        total: this.recipe.steps.length,
        title: step.title,
        kind: step.kind,
      });

      if (step.kind === "command") {
        const progress = await this.runCommandStep(step, shell);
        if (progress.kind === "blocked") {
          return progress.status;
        }
        continue;
      }

      if (step.kind === "open") {
        // Opening it is the entire step — no tap, no wait.
        if (step.href !== undefined) {
          this.emit({ type: "openRequested", href: step.href });
        }
        this.advance();
        continue;
      }

      // sign_in / permission / manual: only the reader can finish it.
      const instruction = this.instructionFor(step);
      this.emit({ type: "handedToReader", instruction, href: step.href });
      return {
        type: "needsReader",
        stepIndex: this.index,
        instruction,
        href: step.href,
        check: step.check,
      };
    }
  }

  /// The reader tapped "run it" (or declined) on a confirm-tier command.
  async confirmCurrentCommand(approved: boolean, shell: ShellSession): Promise<RunnerStatus> {
    const step = this.currentStep();
    if (step === undefined) {
      return this.runUntilBlocked(shell);
    }
    if (step.command === undefined) {
      return this.surface("This step has no command to run.");
    }
    if (!approved) {
      return this.surface("You skipped this command, so Iris stopped here.", step.command);
    }
    const approvedCommand = approveAfterAReaderTap(step.command, RECIPE_PROVENANCE);
    if (approvedCommand === undefined) {
      return this.surface("Iris won't run this command automatically.", step.command);
    }
    const progress = await this.execute(approvedCommand, step, shell);
    return progress.kind === "advanced" ? this.runUntilBlocked(shell) : progress.status;
  }

  /// The reader finished a sign-in / permission / manual step. Resume.
  async readerFinishedCurrentStep(shell: ShellSession): Promise<RunnerStatus> {
    this.advance();
    return this.runUntilBlocked(shell);
  }

  private async runCommandStep(step: RecipeStep, shell: ShellSession): Promise<StepProgress> {
    if (step.command === undefined) {
      return { kind: "blocked", status: this.surface("This step has no command to run.") };
    }
    const verdict = assess(step.command, RECIPE_PROVENANCE);
    if (verdict.tier === "runs_without_asking") {
      const approved = approve(step.command, RECIPE_PROVENANCE)!;
      return this.execute(approved, step, shell);
    }
    if (verdict.tier === "needs_a_confirm_tap") {
      this.emit({ type: "needsConfirm", command: step.command, reason: verdict.reason });
      return {
        kind: "blocked",
        status: { type: "needsConfirm", stepIndex: this.index, command: step.command, reason: verdict.reason },
      };
    }
    return {
      kind: "blocked",
      status: this.surface(
        `Iris won't run this command automatically: ${verdict.reason}`,
        step.command,
      ),
    };
  }

  private async execute(
    approved: ApprovedCommand,
    step: RecipeStep,
    shell: ShellSession,
  ): Promise<StepProgress> {
    const rawCommand = step.command ?? "";
    this.emit({ type: "commandStarted", text: rawCommand });
    const outcome: CommandOutcome = step.longRunning
      ? await shell.runLongRunning(approved, step.readyWhen, LONG_RUNNING_GRACE_MS)
      : await shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);

    switch (outcome.kind) {
      case "succeeded":
        this.emit({ type: "commandFinished", exitCode: 0, output: outcome.output });
        this.advance();
        return { kind: "advanced" };
      case "failed":
        this.emit({ type: "commandFinished", exitCode: outcome.exitCode, output: outcome.output });
        // The failure ladder (a model proposing a fix) is a later increment; for
        // now a failed command surfaces rather than pretending to recover.
        return {
          kind: "blocked",
          status: this.surface("That command didn't finish cleanly. Here's where it stopped.", rawCommand),
        };
      case "timed_out":
        return {
          kind: "blocked",
          status: this.surface("That command took too long, so Iris stopped it.", rawCommand),
        };
      case "session_failed":
        return { kind: "blocked", status: { type: "sessionFailed" } };
    }
  }

  private instructionFor(step: RecipeStep): string {
    if (step.instruction !== undefined) {
      return step.instruction;
    }
    switch (step.kind) {
      case "sign_in":
        return "Sign in here, then Iris will carry on.";
      case "permission":
        return "Grant this when Windows asks, then Iris will carry on.";
      default:
        return "Finish this step, then Iris will carry on.";
    }
  }
}
