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

import type { InstallRecipe, RecipeOutput, RecipeStep, StepCheck, StepKind, WatchExpectation } from "./recipe";
import { advancesWithoutRunningAnything, commandForPlatform, workingDirectoryForPlatform } from "./recipe";
import type { ApprovedCommand, Provenance } from "./risk";
import { approve, approveAfterAReaderTap, assess } from "./risk";
import { friendlyLabel } from "./friendly-label";
// Type-only: the ladder is INJECTED (the controller builds it with the model
// provider + the recipe's hosts), so the runner needs its shape, never its
// module at runtime — which also keeps the fix-ladder↔runner import a type cycle,
// not a value one.
import type { FixLadder } from "./fix-ladder";
import { firstProgramToken, selfHealStepForFailure } from "./setup-detour";
import type { WatchStepExecutor } from "./watch";
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
  /// The fix ladder's plain-English line for what the model diagnosed / did on a
  /// failed command, shown between the failing command and its retry (or the
  /// surface). Streamed by `FixLadder`, never by a clean step.
  | { readonly type: "fixProposed"; readonly diagnosis: string }
  /// The main process should open this URL/app; opening it is the whole step.
  | { readonly type: "openRequested"; readonly href: string }
  /// A prerequisite the recipe needs was missing, so the setup-recovery detour
  /// began. Lists each missing tool with the page that installs it; emitted once,
  /// before any download page is opened, by `runSetupDetour`.
  | { readonly type: "setupDetour"; readonly missing: readonly { readonly tool: string; readonly downloadHref: string }[] }
  /// A command died because a tool it needs was not on the PATH, and the recipe
  /// has its own earlier step for installing that tool. Iris is re-running that
  /// step now, before it treats the failure as a real failure.
  | { readonly type: "installingMissingTool"; readonly tool: string; readonly command: string }
  /// Only the reader can finish this. Float the eye to it and show this.
  | { readonly type: "handedToReader"; readonly instruction: string; readonly href?: string }
  /// A command needs one explicit tap before it runs.
  | { readonly type: "needsConfirm"; readonly command: string; readonly reason: string }
  /// A command no tap can make informed; the install stops here for the reader.
  | { readonly type: "surfaced"; readonly reason: string; readonly failingCommand?: string }
  /// A watched step's expectation verified on its own — the step advanced with
  /// no tap. `verifiedBy` names which expectation settled it.
  | { readonly type: "watchVerified"; readonly index: number; readonly verifiedBy: WatchExpectation["type"] }
  /// A watched step's expectations never verified within the bounded wait, so
  /// Iris hands it back to the reader with `verifierLabel`.
  | { readonly type: "watchTimedOut"; readonly index: number; readonly verifierLabel: string }
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
  // Steps that have already had the missing-tool self-heal run for them, so a
  // step is repaired at most once: if it still fails as "command not found"
  // after the recipe's own install step was re-run, it escalates (surfaces)
  // rather than looping. Mirrors macOS running the guide's install step once.
  private readonly selfHealedStepIds = new Set<string>();
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
    // The self-repair ladder, built once per install by the controller with the
    // reader's own model provider and this recipe's reachable hosts. Undefined
    // keeps the old behavior EXACTLY — a failed command surfaces at once instead
    // of trying to recover — which is what every existing caller and test relies
    // on. When present, a non-zero exit runs the ladder before surfacing.
    private readonly fixLadder: FixLadder | undefined = undefined,
    // Watches a step's `watch` expectations and blocks a `verify` step until one
    // verifies — the Windows analog of the macOS adaptive `WatchLoop`. Injected
    // so the whole runner stays testable with a fake; undefined means "no
    // watching wired", and a watched step then falls back to the reader handoff.
    private readonly watchExecutor: WatchStepExecutor | undefined = undefined,
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
        // A prose `noop` step: nothing for the command runner to do, so it
        // succeeds the instant it is reached — the same as macOS's nil-command →
        // succeeded. (A `verify` step is NOT self-completing anymore; it is
        // settled by the watch block just below.)
        this.advance();
        continue;
      }

      // A `verify` step, or any reader step carrying a `watch` block, is settled
      // by watching the reader's machine rather than by a tap — the Windows
      // analog of the macOS adaptive watch loop. A `verify` step is pure watch
      // (Iris surfaces nothing until it either verifies or times out); a reader
      // step (sign_in/permission/manual) that carries a watch still surfaces
      // "your turn" up front so the reader can act, and is advanced without a tap
      // the moment the watch verifies. A reader step with no watch falls through
      // to the plain handoff below, unchanged.
      if (step.kind === "verify" || step.watch !== undefined) {
        const isReaderStep = step.kind !== "verify";
        const readerInstruction = isReaderStep ? this.instructionFor(step) : this.verifierLabelFor(step);

        if (isReaderStep) {
          this.emit({ type: "handedToReader", instruction: readerInstruction, href: step.href });
        }

        const canWatch =
          this.watchExecutor !== undefined &&
          step.watch !== undefined &&
          step.watch.expect.length > 0;
        if (canWatch) {
          const outcome = await this.watchExecutor!.awaitStepCompletion(step.watch!, {
            stepTitle: step.title,
            commandTheStepAsksFor: this.commandFor(step),
          });
          if (outcome.kind === "verified") {
            this.emit({ type: "watchVerified", index: this.index, verifiedBy: outcome.verifiedBy });
            this.advance();
            continue;
          }
          // Timed out: the watch could not confirm it, so hand it back.
          this.emit({ type: "watchTimedOut", index: this.index, verifierLabel: this.verifierLabelFor(step) });
        }

        // Either nothing was watchable, or the watch timed out. A reader step
        // already surfaced above; a verify step surfaces the handoff now.
        if (!isReaderStep) {
          this.emit({ type: "handedToReader", instruction: readerInstruction, href: step.href });
        }
        return {
          type: "needsReader",
          stepIndex: this.index,
          instruction: readerInstruction,
          href: step.href,
          check: step.check,
        };
      }

      // sign_in / permission / manual / web / paste with no watch: only the
      // reader can finish it.
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
      case "failed": {
        this.emit({ type: "commandFinished", exitCode: outcome.exitCode, output: outcome.output });
        // A command that died because a tool it needs is not on the PATH, when
        // the recipe has its own earlier step for installing that tool, is
        // repaired here FIRST — the install step is re-run once and the command
        // retried — before either the model ladder or the reader sees it. This
        // is the cheap, deterministic rung, and it mirrors macOS
        // `installTheMissingToolTheGuideInstallsItself` running ahead of
        // `climbTheFixLadder`.
        const healed = await this.trySelfHealMissingTool(step, rawCommand, outcome, approved, shell);
        if (healed !== undefined) return healed;
        // Self-repair before surfacing: when a ladder is wired, a non-zero exit
        // gets a model-proposed fix (run under the gate) and a retry of the
        // original before the reader ever sees a dead terminal. Without a ladder
        // the behavior is unchanged — surface at once.
        if (this.fixLadder !== undefined) {
          return this.runFixLadder(this.fixLadder, approved, step, rawCommand, outcome.exitCode, outcome.output, shell);
        }
        return {
          kind: "blocked",
          status: this.surface("That command didn't finish cleanly. Here's where it stopped.", rawCommand),
        };
      }
      case "timed_out":
        return {
          kind: "blocked",
          status: this.surface("That command took too long, so Iris stopped it.", rawCommand),
        };
      case "session_failed":
        return { kind: "blocked", status: { type: "sessionFailed" } };
    }
  }

  /// Hands a failed command to the fix ladder and translates the ladder's
  /// verdict back into the runner's own vocabulary: a repaired step advances, a
  /// hand-back floats the eye, and an exhausted ladder surfaces the failing
  /// command with the diagnosis the ladder settled on (the renderer offers "Try
  /// again / Continue past it" on that surface).
  ///
  /// `retryOriginal` re-runs the ALREADY-APPROVED original command — the ladder
  /// never needs to re-approve it, because the runner minted it once and owns
  /// where it runs. A repair may have moved the shell, so the declared folder is
  /// re-entered first, exactly as the first run did.
  private async runFixLadder(
    ladder: FixLadder,
    approved: ApprovedCommand,
    step: RecipeStep,
    rawCommand: string,
    exitCode: number,
    output: string,
    shell: ShellSession,
  ): Promise<StepProgress> {
    const result = await ladder.repair({
      step,
      command: rawCommand,
      exitCode,
      output,
      workingDirectory: shell.currentDirectory(),
      shell,
      retryOriginal: async () => {
        const folder = workingDirectoryForPlatform(step, this.platform);
        if (folder !== undefined) {
          const moved = await this.moveInto(folder, shell);
          if (!moved) {
            return { kind: "failed", exitCode: 1, output: `Iris couldn't move back into ${folder} to retry.` };
          }
        }
        return step.longRunning
          ? shell.runLongRunning(approved, step.readyWhen, LONG_RUNNING_GRACE_MS)
          : shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);
      },
      emit: (event) => this.emit(event),
    });

    if (result.kind === "repaired") {
      this.advance();
      return { kind: "advanced" };
    }
    if (result.kind === "hand_to_reader") {
      this.emit({ type: "handedToReader", instruction: result.instruction });
      return {
        kind: "blocked",
        status: { type: "needsReader", stepIndex: this.index, instruction: result.instruction },
      };
    }
    return { kind: "blocked", status: this.surface(result.diagnosis, rawCommand) };
  }

  /// The reader chose "Try again" on a surfaced step: re-run the SAME step from
  /// the top (its command, its folder move), rather than skipping it. Distinct
  /// from `continuePastCurrentStep`, which skips it. Mirrors the macOS surface's
  /// two-way "Try again / Continue past it" choice.
  async retryCurrentStep(shell: ShellSession): Promise<RunnerStatus> {
    return this.runUntilBlocked(shell);
  }

  /// The reader chose "Continue past it" on a surfaced step: skip the failing
  /// step and carry on with the rest of the install.
  async continuePastCurrentStep(shell: ShellSession): Promise<RunnerStatus> {
    this.advance();
    return this.runUntilBlocked(shell);
  }

  /// Repairs a "command not found" failure the recipe can fix itself: when the
  /// failed command reached for a tool an EARLIER recipe step installs, re-run
  /// that install step once and retry the command. Returns the resumed progress
  /// on a repair (advanced on a clean retry, blocked/surfaced on a retry that
  /// still failed), or undefined when this is not a self-healable failure and
  /// the caller should surface it the ordinary way.
  ///
  /// Nothing here is model-proposed: the command run is one the recipe already
  /// publishes, so it goes through the risk gate under the same provenance as
  /// any recipe command. Once-only per step (`selfHealedStepIds`) so a genuinely
  /// broken step escalates instead of looping.
  private async trySelfHealMissingTool(
    step: RecipeStep,
    rawCommand: string,
    outcome: Extract<CommandOutcome, { kind: "failed" }>,
    originalApproved: ApprovedCommand,
    shell: ShellSession,
  ): Promise<StepProgress | undefined> {
    if (this.selfHealedStepIds.has(step.id)) return undefined;
    const installStep = selfHealStepForFailure(
      this.recipe,
      this.index,
      rawCommand,
      outcome.exitCode,
      outcome.output,
      this.platform,
    );
    if (installStep === undefined) return undefined;

    const installCommand = this.commandFor(installStep);
    if (installCommand === undefined) return undefined;
    const approvedInstall = approve(installCommand, RECIPE_PROVENANCE, this.autonomyGranted);
    if (approvedInstall === undefined) return undefined;

    // Only now commit to the repair — from here it counts as this step's one
    // attempt whether or not it succeeds.
    this.selfHealedStepIds.add(step.id);
    const missingTool = firstProgramToken(rawCommand);
    this.emit({ type: "installingMissingTool", tool: missingTool, command: installCommand });

    // Run the recipe's own install step, in the folder it declares.
    const installFolder = workingDirectoryForPlatform(installStep, this.platform);
    if (installFolder !== undefined && !(await this.moveInto(installFolder, shell))) return undefined;
    this.emit({ type: "commandStarted", text: installCommand, friendlyLabel: friendlyLabel(installCommand) });
    const installOutcome = await shell.run(approvedInstall, DEFAULT_COMMAND_TIMEOUT_MS);
    if (installOutcome.kind === "session_failed") {
      return { kind: "blocked", status: { type: "sessionFailed" } };
    }
    if (installOutcome.kind !== "succeeded") {
      this.emit({
        type: "commandFinished",
        exitCode: installOutcome.kind === "failed" ? installOutcome.exitCode : 1,
        output: installOutcome.kind === "failed" ? installOutcome.output : "",
      });
      return undefined; // install didn't take — let the caller surface the original failure
    }
    this.emit({ type: "commandFinished", exitCode: 0, output: installOutcome.output });

    // Retry the original command, back in ITS folder. The per-command PowerShell
    // re-reads the PATH from the registry, so the just-installed tool is visible.
    const stepFolder = workingDirectoryForPlatform(step, this.platform);
    if (stepFolder !== undefined && !(await this.moveInto(stepFolder, shell))) return undefined;
    this.emit({ type: "commandStarted", text: rawCommand, friendlyLabel: friendlyLabel(rawCommand) });
    const retry = await shell.run(originalApproved, DEFAULT_COMMAND_TIMEOUT_MS);
    switch (retry.kind) {
      case "succeeded":
        if (retry.servedUrl !== undefined) this.detectedServedUrl = retry.servedUrl;
        this.emit({ type: "commandFinished", exitCode: 0, output: retry.output });
        this.advance();
        return { kind: "advanced" };
      case "failed":
        this.emit({ type: "commandFinished", exitCode: retry.exitCode, output: retry.output });
        return undefined; // still broken — escalate via the caller's surface
      case "timed_out":
        return { kind: "blocked", status: this.surface("That command took too long, so Iris stopped it.", rawCommand) };
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

  /// The line shown when a watched step could not be confirmed on its own and
  /// Iris hands it back — the step's own `verifierLabel`, or a generic sentence.
  private verifierLabelFor(step: RecipeStep): string {
    if (step.verifierLabel !== undefined && step.verifierLabel.length > 0) {
      return step.verifierLabel;
    }
    if (step.instruction !== undefined && step.instruction.length > 0) {
      return step.instruction;
    }
    return "Iris couldn't tell this step finished on its own — finish it, then it will carry on.";
  }
}
