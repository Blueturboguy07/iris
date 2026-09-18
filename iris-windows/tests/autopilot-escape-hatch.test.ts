import { describe, expect, it } from "vitest";
import { AutopilotController, type AutopilotHost, type FinishedInstall } from "../src/main/autopilot-controller";
import type { InstallRecipe, RecipeStep } from "../src/services/autopilot/recipe";
import { AutopilotRunner, type AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell, type CommandOutcome, type ShellSession } from "../src/services/autopilot/shell";
import type { ApprovedCommand } from "../src/services/autopilot/risk";

/**
 * The red 'Stop' escape hatch — the Windows port of macOS `Test6EscapeHatchTests`.
 * The two properties that make the button trustworthy: closing is UNCONDITIONAL
 * (never a dead button, even when the run has already stopped), and an abort ends
 * the run for good — the running command's process tree is killed and NO further
 * step runs.
 */

function commandStep(id: string, command: string): RecipeStep {
  return { id, title: `Run ${id}`, kind: "command", command };
}

function recipe(steps: RecipeStep[]): InstallRecipe {
  return {
    slug: "demo",
    appName: "Demo",
    output: { type: "local_web", url: "http://localhost:1234" },
    steps,
  };
}

/// A shell whose `run` blocks until the test releases it, so an abort can land
/// while a command is genuinely in flight (a `MockShell` finishes instantly).
class GatedShell implements ShellSession {
  readonly commandsRun: string[] = [];
  aborted = false;
  cwd = "C:\\Users\\test\\app";
  private release: (() => void) | null = null;

  async run(command: ApprovedCommand, _deadlineMs: number): Promise<CommandOutcome> {
    this.commandsRun.push(command.text);
    await new Promise<void>((resolve) => {
      this.release = resolve;
    });
    // Whatever a killed process would report — this is discarded once aborted.
    return { kind: "succeeded", output: "" };
  }

  async runLongRunning(command: ApprovedCommand): Promise<CommandOutcome> {
    return this.run(command, 0);
  }

  /// Lets the currently-blocked `run` resolve.
  releaseCurrent(): void {
    const release = this.release;
    this.release = null;
    release?.();
  }

  currentDirectory(): string {
    return this.cwd;
  }

  abort(): void {
    this.aborted = true;
  }

  dispose(): void {
    // Nothing to tear down.
  }
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

describe("the runner's escape hatch", () => {
  it("runs no step at all when aborted before it starts", async () => {
    const runner = new AutopilotRunner(recipe([commandStep("a", "npm ci")]), "win32", true);
    const shell = MockShell.alwaysSucceeds();

    const status = runner.abort();
    expect(status.type).toBe("aborted");

    const afterward = await runner.runUntilBlocked(shell);
    expect(afterward.type).toBe("aborted");
    expect(shell.commandsRun).toEqual([]);
  });

  it("ends a running install mid-command and runs no further step", async () => {
    const runner = new AutopilotRunner(
      recipe([commandStep("a", "npm ci"), commandStep("b", "cargo build --release")]),
      "win32",
      true,
    );
    const shell = new GatedShell();

    // Start pumping. The first command reaches the shell synchronously and then
    // blocks in `run`, so the runner is now sitting inside step A.
    const pumping = runner.runUntilBlocked(shell);
    expect(shell.commandsRun).toEqual(["npm ci"]);

    // The reader hits 'Stop' while A is running.
    runner.abort();
    // The killed command's outcome comes back…
    shell.releaseCurrent();
    const status = await pumping;

    expect(status.type).toBe("aborted");
    // …and B never ran.
    expect(shell.commandsRun).toEqual(["npm ci"]);
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "aborted")).toBe(true);
  });

  it("stays aborted when the reader tries to resume", async () => {
    const runner = new AutopilotRunner(
      recipe([{ id: "s", title: "Sign in", kind: "sign_in" }, commandStep("b", "npm ci")]),
      "win32",
      true,
    );
    const shell = MockShell.alwaysSucceeds();

    await runner.runUntilBlocked(shell); // stops at the sign-in for the reader
    runner.abort();

    expect((await runner.readerFinishedCurrentStep(shell)).type).toBe("aborted");
    expect((await runner.confirmCurrentCommand(true, shell)).type).toBe("aborted");
    expect(shell.commandsRun).toEqual([]); // nothing ran after the abort
  });

  it("is idempotent — a second abort changes nothing", () => {
    const runner = new AutopilotRunner(recipe([commandStep("a", "npm ci")]), "win32", true);
    runner.abort();
    runner.drainEvents();
    const status = runner.abort();
    expect(status.type).toBe("aborted");
    // No second `aborted` event on the repeat.
    expect(runner.drainEvents().some((event) => event.type === "aborted")).toBe(false);
  });
});

class RecordingHost implements AutopilotHost {
  readonly events: AutopilotEvent[] = [];
  aborts = 0;
  autonomyAnswer = true;

  async ensureAutonomyGranted(): Promise<boolean> {
    return this.autonomyAnswer;
  }
  emitEvent(event: AutopilotEvent): void {
    this.events.push(event);
  }
  openExternal(): void {}
  floatToGate(): void {}
  onFinished(_finishedInstall: FinishedInstall): void {}
  onAborted(): void {
    this.aborts += 1;
  }
}

describe("the controller's escape hatch", () => {
  it("folds the window away even when nothing is running (the dead-button fix)", () => {
    const host = new RecordingHost();
    const controller = new AutopilotController(host, () => MockShell.alwaysSucceeds());

    // No install has started — the old bug returned early and closed nothing.
    const status = controller.abort();

    expect(status.type).toBe("aborted");
    expect(host.aborts).toBe(1);
  });

  it("kills the shell, ends the run, and folds the window away mid-install", async () => {
    const host = new RecordingHost();
    const shell = new GatedShell();
    const installRecipe = recipe([commandStep("a", "npm ci"), commandStep("b", "cargo build --release")]);
    const controller = new AutopilotController(host, () => shell, (slug) =>
      slug === installRecipe.slug ? installRecipe : undefined,
    );

    const running = controller.start("demo");
    await tick(); // let consent resolve and command A reach the (gated) shell
    expect(shell.commandsRun).toEqual(["npm ci"]);

    const aborted = controller.abort();
    expect(aborted.type).toBe("aborted");
    expect(shell.aborted).toBe(true); // the process tree was told to die
    expect(host.aborts).toBe(1);
    expect(host.events.some((event) => event.type === "aborted")).toBe(true);

    shell.releaseCurrent();
    const finalStatus = await running;
    expect(finalStatus.type).toBe("aborted");
    expect(shell.commandsRun).toEqual(["npm ci"]); // B never ran
  });
});
