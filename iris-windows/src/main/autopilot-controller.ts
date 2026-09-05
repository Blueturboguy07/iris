//
// The bridge between the pure autopilot runner and the Electron app.
//
// It owns the runner + the shell for one install, pumps the runner, and turns
// the events it produces into the two side-effects only the app can do: opening
// a URL/app, and floating the eye to a gate the reader must handle. Everything
// the app provides is behind `AutopilotHost`, so this whole class is unit-tested
// with a fake host and a `MockShell` on any host — the Electron glue in
// `index.ts` stays a thin adaptor.
//

import { recipeForSlug } from "../services/autopilot/recipes";
import { recipeClonesARepo, type InstallRecipe, type RecipeOutput } from "../services/autopilot/recipe";
import { AutopilotRunner, type AutopilotEvent, type RunnerStatus } from "../services/autopilot/runner";
import type { FixLadder } from "../services/autopilot/fix-ladder";
import type { ShellSession } from "../services/autopilot/shell";
import {
  runSetupDetour,
  type DetourClock,
  type ToolProbe,
} from "../services/autopilot/setup-detour";
import { defaultWatchExecutor, type WatchStepExecutor } from "../services/autopilot/watch";
import { PowerShellSession } from "./powershell-session";
import { PosixShellSession } from "./posix-shell-session";

/// The real shell for this host: PowerShell on Windows (the shipped product),
/// a zsh login shell on macOS/Linux (running Iris on a Mac to test the flow).
function defaultShell(): ShellSession {
  return process.platform === "win32" ? new PowerShellSession() : new PosixShellSession();
}

/// The full picture of what a finished install produced — enough for the app
/// to open the result AND for maintain mode to record how the app got onto this
/// machine (`main/maintain/controller.ts`'s `recordInstallProvenance`). The
/// Windows analog of what macOS `CompanionManager.onGuideCompleted` has in hand
/// at completion: the recipe's identity, whether it cloned source, and where the
/// clone landed (the shell's cwd, after the recipe cd'd into the clone).
export interface FinishedInstall {
  readonly slug: string;
  readonly appName: string;
  readonly output: RecipeOutput;
  /// `"owner/name"` of the canonical repo, for a source-build recipe. Undefined
  /// for a signed-download recipe.
  readonly canonicalRepo: string | undefined;
  readonly pinnedCommit: string | undefined;
  /// Whether this recipe cloned a repo — the guide-source-clone vs
  /// signed-download discriminator (see `recipeClonesARepo`).
  readonly clonedARepo: boolean;
  /// The shell's working directory the instant the install finished. For a
  /// cloning recipe this is the clone directory; undefined once the session is
  /// gone or was never started.
  readonly clonePath: string | undefined;
}

/// Everything the autopilot needs from the app, injected so the controller is
/// testable without Electron.
export interface AutopilotHost {
  /// The one-time "Let Iris take control of your PC?" consent. Returns true if
  /// the reader has already granted it (remembered across installs) or grants it
  /// now; false if they decline. The real host reads/writes the persisted
  /// `autopilotAutonomyGranted` setting and shows a dialog when it is not yet
  /// set; a test returns a fixed answer. `start` refuses to run when it is false.
  ensureAutonomyGranted(): Promise<boolean>;
  /// Forward a runner event to the renderer (the animated terminal).
  emitEvent(event: AutopilotEvent): void;
  /// Open a URL or app the reader should land in.
  openExternal(url: string): void;
  /// Float the eye/panel to a gate and show the instruction. `href` is the page
  /// a sign-in step already opened, for context.
  floatToGate(instruction: string, href: string | undefined): void;
  /// The install finished; open the result, record its provenance, and let the
  /// app refresh its list. Carries the whole `FinishedInstall`, not just the
  /// output, so provenance can be recorded at the one moment it is knowable.
  onFinished(finishedInstall: FinishedInstall): void;
  /// The reader hit the red 'Stop': the run is over and its shell has been
  /// killed. The host folds the autopilot window away — mirroring macOS
  /// `onAutopilotDidStop`, which the escape hatch calls unconditionally so the
  /// reader is never left with a window and no way out. Optional so existing
  /// hosts/tests need not implement it.
  onAborted?(): void;
}

export class AutopilotController {
  private runner: AutopilotRunner | undefined;
  private shell: ShellSession | undefined;
  /// The recipe the current install is running, kept so `onFinished` can report
  /// the finished install's identity (slug, canonical repo, pinned commit) and
  /// whether it cloned. Cleared by `dispose`.
  private recipe: InstallRecipe | undefined;

  constructor(
    private readonly host: AutopilotHost,
    private readonly makeShell: () => ShellSession = defaultShell,
    // Injected so tests can drive recipes the built-in set does not carry. In
    // production it is the guide-backed resolver (fetch the publik guide, derive
    // a recipe, fall back to the built-in table only when the fetch fails), so it
    // may answer asynchronously; a synchronous resolver (the built-in table, the
    // test doubles) is still accepted unchanged because `await` passes a plain
    // value straight through.
    private readonly resolveRecipe: (
      slug: string,
    ) => InstallRecipe | undefined | Promise<InstallRecipe | undefined> = recipeForSlug,
    // Builds the self-repair ladder for one install, or undefined when the app
    // has no model key to power it — the ladder then degrades to "surface
    // immediately". Injected so `index.ts` can wire the reader's own model
    // provider and the OS strings while this class stays testable with none; the
    // default gives no ladder, so a failed command surfaces exactly as before.
    private readonly makeFixLadder: (recipe: InstallRecipe) => FixLadder | undefined = () => undefined,
    // The setup-recovery detour's seams (tool probing + wall clock). Present in
    // production (wired in `main/index.ts`); absent in unit tests that are not
    // exercising the detour, in which case the detour is skipped entirely so a
    // recipe's prerequisite checks never shell out in the suite.
    private readonly detourSeams: { readonly probe: ToolProbe; readonly clock: DetourClock } | undefined = undefined,
    // Builds the watch executor a `verify`/watched step blocks on. The default
    // runs the real Windows PowerShell side signals; the visual rung stays inert
    // until a host wires screenshot capture + a model evaluator into it. Injected
    // (and one-per-install) so tests can hand in a fake with no OS calls.
    private readonly makeWatchExecutor: () => WatchStepExecutor = () => defaultWatchExecutor(),
  ) {}

  /// Whether Iris knows how to install this app on Windows. Async because the
  /// production resolver answers from the fetched guide.
  async canInstall(slug: string): Promise<boolean> {
    return (await this.resolveRecipe(slug)) !== undefined;
  }

  /// Begins an install and pumps it to the first thing that needs a human (or to
  /// the end). Throws only if the slug has no recipe.
  async start(slug: string): Promise<RunnerStatus> {
    const recipe = await this.resolveRecipe(slug);
    if (recipe === undefined) {
      throw new Error(`Iris has no Windows recipe for '${slug}'.`);
    }
    // The one-time "Let Iris take control?" consent, remembered across installs.
    // Asked before any shell is started; a decline stops here rather than
    // running an install the reader did not agree to.
    const autonomyGranted = await this.host.ensureAutonomyGranted();
    if (!autonomyGranted) {
      return {
        type: "surfaced",
        stepIndex: 0,
        reason: "Iris needs your go-ahead to run installs on your PC. Start it again when you're ready.",
      };
    }
    this.dispose();
    this.shell = this.makeShell();
    this.recipe = recipe;

    // Before the recipe's first step, walk the setup-recovery detour: check the
    // prerequisites the recipe needs but does not install (git, node), and if
    // any is missing, install it (winget under the grant) or send the reader to
    // its download page and wait for it to appear. A detour that gives up
    // surfaces here rather than marching into a recipe whose first step would
    // fail on a missing tool. Skipped when the detour seams are not wired
    // (unit tests that are not exercising it).
    if (this.detourSeams !== undefined) {
      const detour = await runSetupDetour(recipe, this.shell, {
        probe: this.detourSeams.probe,
        clock: this.detourSeams.clock,
        platform: process.platform,
        autonomyGranted: true,
        emit: (event) => this.forwardEvent(event),
      });
      if (detour.kind === "surfaced") {
        const status: RunnerStatus = { type: "surfaced", stepIndex: 0, reason: detour.reason };
        this.host.emitEvent({ type: "surfaced", reason: detour.reason });
        this.dispose();
        return status;
      }
    }

    // Granted, so the runner runs the whole vetted install hands-off (only the
    // catastrophe floor can still stop a command). The fix ladder, when the
    // reader has a model key, lets a failed command self-repair before it ever
    // reaches them; the watch executor lets a `verify`/watched step confirm
    // itself and advance without a tap. Both are undefined-tolerant.
    this.runner = new AutopilotRunner(
      recipe,
      process.platform,
      true,
      this.makeFixLadder(recipe),
      this.makeWatchExecutor(),
    );
    return this.pump(await this.runner.runUntilBlocked(this.shell));
  }

  /// The reader tapped "run it" / "skip" on a confirm-tier command.
  async confirm(approved: boolean): Promise<RunnerStatus> {
    if (this.runner === undefined || this.shell === undefined) {
      throw new Error("No install is running.");
    }
    return this.pump(await this.runner.confirmCurrentCommand(approved, this.shell));
  }

  /// The reader finished a sign-in / permission / manual step.
  async readerFinished(): Promise<RunnerStatus> {
    if (this.runner === undefined || this.shell === undefined) {
      throw new Error("No install is running.");
    }
    return this.pump(await this.runner.readerFinishedCurrentStep(this.shell));
  }

  /// The reader chose "Try again" on a surfaced step — re-run it from the top.
  async retry(): Promise<RunnerStatus> {
    if (this.runner === undefined || this.shell === undefined) {
      throw new Error("No install is running.");
    }
    return this.pump(await this.runner.retryCurrentStep(this.shell));
  }

  /// The reader chose "Continue past it" on a surfaced step — skip it and go on.
  async continuePast(): Promise<RunnerStatus> {
    if (this.runner === undefined || this.shell === undefined) {
      throw new Error("No install is running.");
    }
    return this.pump(await this.runner.continuePastCurrentStep(this.shell));
  }

  /// The red 'Stop' escape hatch. Kills the running step's process tree, marks
  /// the run terminal (no further step runs), streams the `aborted` event to the
  /// terminal, and folds the window away via the host. Unconditional and
  /// idempotent — safe when nothing is running, mirroring macOS
  /// `abortOrCloseAutopilotFromTheEscapeHatch`, so the button is never dead.
  abort(): RunnerStatus {
    const status: RunnerStatus = this.runner ? this.runner.abort() : { type: "aborted", stepIndex: 0 };
    // Forward the `aborted` event (and anything else queued) before the runner
    // is torn down, so the terminal shows the run ending.
    for (const event of this.runner?.drainEvents() ?? []) {
      this.host.emitEvent(event);
    }
    // Kill the running command's whole process tree, then tear the session down.
    this.shell?.abort();
    this.dispose();
    this.host.onAborted?.();
    return status;
  }

  dispose(): void {
    this.shell?.dispose();
    this.shell = undefined;
    this.runner = undefined;
    this.recipe = undefined;
  }

  /// Drains the runner's events, forwards each to the renderer, and performs the
  /// app-only side effects — opening an `open` step's link, floating to a gate,
  /// and opening the finished app.
  private pump(status: RunnerStatus): RunnerStatus {
    for (const event of this.runner?.drainEvents() ?? []) {
      this.forwardEvent(event);
    }
    if (status.type === "finished") {
      // Capture the clone path (the shell's cwd) BEFORE dispose tears the
      // session down — after a cloning recipe cd's into its clone, this is the
      // clone directory maintain mode may later patch.
      this.host.onFinished(this.buildFinishedInstall(status.output));
      this.dispose();
    }
    return status;
  }

  /// Streams one event to the renderer and performs the app-only side effect it
  /// implies. Shared by the runner pump and the setup detour so an `openRequested`
  /// from either one opens its URL the same way.
  private forwardEvent(event: AutopilotEvent): void {
    this.host.emitEvent(event);
    if (event.type === "openRequested") {
      this.host.openExternal(event.href);
    } else if (event.type === "handedToReader") {
      this.host.floatToGate(event.instruction, event.href);
    }
  }

  /// Assembles the `FinishedInstall` handed to `onFinished` from the recipe the
  /// install ran and the shell's current directory. `recipe` is always set at a
  /// `finished` status (it is set in `start` before the first pump), but the
  /// fallbacks keep this total rather than asserting.
  private buildFinishedInstall(output: RecipeOutput): FinishedInstall {
    const recipe = this.recipe;
    return {
      slug: recipe?.slug ?? "",
      appName: recipe?.appName ?? "",
      output,
      canonicalRepo: recipe?.canonicalRepo,
      pinnedCommit: recipe?.pinnedCommit,
      clonedARepo: recipe !== undefined ? recipeClonesARepo(recipe) : false,
      clonePath: this.shell?.currentDirectory(),
    };
  }
}

/// Opens whatever a finished recipe produced — the "once it's done the app just
/// opens" behaviour. Returns the URL to open, or undefined when there is nothing
/// to open (a credential flow, or a desktop app the caller launches differently).
export function openTargetForOutput(output: RecipeOutput): string | undefined {
  switch (output.type) {
    case "local_web":
      return output.url;
    case "desktop_app":
      return output.launch.via === "path" ? output.launch.path : undefined;
    default:
      return undefined;
  }
}
