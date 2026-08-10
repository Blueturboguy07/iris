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
import type { InstallRecipe, RecipeOutput } from "../services/autopilot/recipe";
import { AutopilotRunner, type AutopilotEvent, type RunnerStatus } from "../services/autopilot/runner";
import type { ShellSession } from "../services/autopilot/shell";
import { PowerShellSession } from "./powershell-session";
import { PosixShellSession } from "./posix-shell-session";

/// The real shell for this host: PowerShell on Windows (the shipped product),
/// a zsh login shell on macOS/Linux (running Iris on a Mac to test the flow).
function defaultShell(): ShellSession {
  return process.platform === "win32" ? new PowerShellSession() : new PosixShellSession();
}

/// Everything the autopilot needs from the app, injected so the controller is
/// testable without Electron.
export interface AutopilotHost {
  /// Forward a runner event to the renderer (the animated terminal).
  emitEvent(event: AutopilotEvent): void;
  /// Open a URL or app the reader should land in.
  openExternal(url: string): void;
  /// Float the eye/panel to a gate and show the instruction. `href` is the page
  /// a sign-in step already opened, for context.
  floatToGate(instruction: string, href: string | undefined): void;
  /// The install finished; open the result and let the app refresh its list.
  onFinished(output: RecipeOutput): void;
}

export class AutopilotController {
  private runner: AutopilotRunner | undefined;
  private shell: ShellSession | undefined;

  constructor(
    private readonly host: AutopilotHost,
    private readonly makeShell: () => ShellSession = defaultShell,
    // Injected so tests can drive recipes the built-in set does not carry; in
    // production it is the reviewed, version-pinned recipe registry.
    private readonly resolveRecipe: (slug: string) => InstallRecipe | undefined = recipeForSlug,
  ) {}

  /// Whether Iris knows how to install this app on Windows.
  canInstall(slug: string): boolean {
    return this.resolveRecipe(slug) !== undefined;
  }

  /// Begins an install and pumps it to the first thing that needs a human (or to
  /// the end). Throws only if the slug has no recipe.
  async start(slug: string): Promise<RunnerStatus> {
    const recipe = this.resolveRecipe(slug);
    if (recipe === undefined) {
      throw new Error(`Iris has no Windows recipe for '${slug}'.`);
    }
    this.dispose();
    this.shell = this.makeShell();
    this.runner = new AutopilotRunner(recipe);
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

  dispose(): void {
    this.shell?.dispose();
    this.shell = undefined;
    this.runner = undefined;
  }

  /// Drains the runner's events, forwards each to the renderer, and performs the
  /// app-only side effects — opening an `open` step's link, floating to a gate,
  /// and opening the finished app.
  private pump(status: RunnerStatus): RunnerStatus {
    for (const event of this.runner?.drainEvents() ?? []) {
      this.host.emitEvent(event);
      if (event.type === "openRequested") {
        this.host.openExternal(event.href);
      } else if (event.type === "handedToReader") {
        this.host.floatToGate(event.instruction, event.href);
      }
    }
    if (status.type === "finished") {
      this.host.onFinished(status.output);
      this.dispose();
    }
    return status;
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
