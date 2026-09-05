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
import { advancesWithoutRunningAnything, commandForPlatform, workingDirectoryForPlatform } from "./recipe";
import type { ApprovedCommand, Provenance } from "./risk";
import { approve, approveAfterAReaderTap, assess } from "./risk";
import { friendlyLabel } from "./friendly-label";
import {
  DEFAULT_COMMAND_TIMEOUT_MS,
  LONG_RUNNING_GRACE_MS,
  type CommandOutcome,
  type ShellSession,
} from "./shell";

const RECIPE_PROVENANCE: Provenance = "vetted_recipe";

/// A `Set-Location` is instant; anything longer means the shell is wedged, and
/// waiting the full command deadline for one would just hide that.
const FOLDER_MOVE_TIMEOUT_MS = 30_000;

/// A folder a recipe may send the shell to: a plain path under home, the root,
/// or a Windows drive, with nothing in it that a shell would expand, split or
/// run.
///
/// This repeats the web side's `WORKING_DIRECTORY` check rather than trusting
/// it, because the value can arrive over the wire from a guide table and is
/// about to become the argument of a real `Set-Location` in the reader's live
/// shell. `~` is deliberately left unquoted and unexpanded so the shell itself
/// resolves it against its own home — the one place that always knows the right
/// answer, on either platform. Mirrors `GuideAutopilotRunner.isAPlainFolder` on
/// macOS.
export function isAPlainFolder(folder: string): boolean {
  if (folder === "") return false;
  const looksLikeAPath =
    folder.startsWith("~") || folder.startsWith("/") || /^[A-Za-z]:[\\/]/.test(folder);
  if (!looksLikeAPath) return false;
  if (!/^[A-Za-z0-9._~@+\-/\\:]+$/.test(folder)) return false;
  return !folder.split(/[\\/]/).includes("..");
}

/// The line that moves a shell into `folder`, in the language of the shell the
/// runner is actually driving.
///
/// This is not cosmetic. `Set-Location` is a PowerShell cmdlet and nothing else:
/// typed into the zsh session the runner uses when Iris runs on a Mac it is
/// `command not found`, exit 127 — so every step that declared a folder would
/// have been surfaced as "Iris couldn't move into …" on macOS, which is the
/// resume bug wearing the fix's own clothes. `cd` is a builtin in zsh and an
/// alias for `Set-Location` in PowerShell, but the cmdlet is spelled out on
/// Windows because that is the shipped platform and its own logs read better.
export function moveIntoCommandFor(folder: string, platform: NodeJS.Platform): string {
  return platform === "win32" ? `Set-Location ${folder}` : `cd ${folder}`;
}

function wrongFolderDiagnosis(folder: string): string {
  return (
    `Iris couldn't move into ${folder}, so it didn't run the command — ` +
    "running it in the wrong folder is how this step failed before. " +
    "Check that the folder is there; the step that copies the code onto this " +
    "computer is the one to go back to."
  );
}

/// Something the runner did that the UI should render. Plain objects: serialized
/// straight to the renderer over IPC.
export type AutopilotEvent =
  | { readonly type: "stepStarted"; readonly index: number; readonly total: number; readonly title: string; readonly kind: StepKind }
  /// `friendlyLabel` is the plain-English line the terminal shows above the raw
  /// `text`, for a non-technical reader (see `friendly-label.ts`).
  | { readonly type: "commandStarted"; readonly text: string; readonly friendlyLabel: string }
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
  // The URL a dev-server step actually served on, if it differed from the recipe
  // default (e.g. Vite moved to :5174 because :5173 was taken). Used so the
  // "open" step lands on the app that is really there.
  private detectedServedUrl: string | undefined;

  // The host platform, injected so a recipe's Windows or macOS command is chosen
  // deterministically (and so tests can pin it). Defaults to the real host.
  constructor(
    private readonly recipe: InstallRecipe,
    private readonly platform: NodeJS.Platform = process.platform,
    // The one-time "Let Iris take control" grant. When true, the gate runs every
    // command that is not in the catastrophe floor without a tap. The controller
    // only constructs a runner with `true` after the reader has consented, so in
    // production an autopilot run is always granted; kept a parameter (default
    // false) so the un-granted three-tier behavior stays unit-testable.
    private readonly autonomyGranted: boolean = false,
  ) {}

  private commandFor(step: RecipeStep): string | undefined {
    return commandForPlatform(step, this.platform);
  }

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

  /// The recipe's output, but with a local-web URL swapped for the port the dev
  /// server actually came up on when they differ.
  private effectiveOutput(): RecipeOutput {
    const output = this.recipe.output;
    if (output.type === "local_web" && this.detectedServedUrl !== undefined) {
      return { type: "local_web", url: this.detectedServedUrl };
    }
    return output;
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
        const output = this.effectiveOutput();
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

      if (advancesWithoutRunningAnything(step.kind)) {
        // A prose `noop` step, or a `verify` step whose looking is the watch
        // loop's job: nothing for the command runner to do, so it succeeds the
        // instant it is reached — the same as macOS's nil-command → succeeded.
        this.advance();
        continue;
      }

      // sign_in / permission / manual / web / paste: only the reader can finish it.
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
    const command = this.commandFor(step);
    if (command === undefined) {
      return this.surface("This step has no command to run.");
    }
    if (!approved) {
      return this.surface("You skipped this command, so Iris stopped here.", command);
    }
    const approvedCommand = approveAfterAReaderTap(command, RECIPE_PROVENANCE, this.autonomyGranted);
    if (approvedCommand === undefined) {
      return this.surface("Iris won't run this command automatically.", command);
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
    const command = this.commandFor(step);
    if (command === undefined) {
      return { kind: "blocked", status: this.surface("This step has no command to run.") };
    }
    const verdict = assess(command, RECIPE_PROVENANCE, this.autonomyGranted);
    if (verdict.tier === "runs_without_asking") {
      const approved = approve(command, RECIPE_PROVENANCE, this.autonomyGranted)!;
      return this.execute(approved, step, shell);
    }
    if (verdict.tier === "needs_a_confirm_tap") {
      this.emit({ type: "needsConfirm", command, reason: verdict.reason });
      return {
        kind: "blocked",
        status: { type: "needsConfirm", stepIndex: this.index, command, reason: verdict.reason },
      };
    }
    return {
      kind: "blocked",
      status: this.surface(`Iris won't run this command automatically: ${verdict.reason}`, command),
    };
  }

  private async execute(
    approved: ApprovedCommand,
    step: RecipeStep,
    shell: ShellSession,
  ): Promise<StepProgress> {
    const rawCommand = this.commandFor(step) ?? "";

    // Put the shell where the step says it runs, before it runs. A step that
    // declares nothing is left exactly where the shell already is — that is
    // every recipe written before this field, and it must not change.
    const folder = workingDirectoryForPlatform(step, this.platform);
    if (folder !== undefined) {
      const moved = await this.moveInto(folder, shell);
      if (!moved) {
        return {
          kind: "blocked",
          status: this.surface(wrongFolderDiagnosis(folder), rawCommand),
        };
      }
    }

    this.emit({ type: "commandStarted", text: rawCommand, friendlyLabel: friendlyLabel(rawCommand) });
    const outcome: CommandOutcome = step.longRunning
      ? await shell.runLongRunning(approved, step.readyWhen, LONG_RUNNING_GRACE_MS)
      : await shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);

    switch (outcome.kind) {
      case "succeeded":
        if (outcome.servedUrl !== undefined) this.detectedServedUrl = outcome.servedUrl;
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

  /// Moves `shell` into the folder the step declared, and reports whether it
  /// landed there.
  ///
  /// Deliberately a SEPARATE command whose outcome is checked, not a
  /// `Set-Location X; <cmd>` chain: PowerShell's `;` does not abort on a failed
  /// `Set-Location`, so a chain would run the command in whatever folder the
  /// shell happened to be in — the exact defect this closes, in a new disguise.
  /// `&&` is not an option either: Windows PowerShell 5.1 does not have it.
  ///
  /// The line itself comes from `moveIntoCommandFor`, because the runner drives
  /// zsh when Iris runs on a Mac and zsh has never heard of `Set-Location`.
  ///
  /// It does not emit `commandStarted`, because a hidden move is not work the
  /// reader is waiting to watch; a move that FAILS is surfaced by the caller.
  private async moveInto(folder: string, shell: ShellSession): Promise<boolean> {
    if (!isAPlainFolder(folder)) return false;
    const approved = approve(
      moveIntoCommandFor(folder, this.platform),
      RECIPE_PROVENANCE,
      this.autonomyGranted,
    );
    if (approved === undefined) return false;
    const outcome = await shell.run(approved, FOLDER_MOVE_TIMEOUT_MS);
    return outcome.kind === "succeeded";
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
