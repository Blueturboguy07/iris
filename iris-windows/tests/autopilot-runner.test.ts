import { describe, expect, it } from "vitest";
import type { InstallRecipe, RecipeStep } from "../src/services/autopilot/recipe";
import { AutopilotRunner } from "../src/services/autopilot/runner";
import { MockShell, type CommandOutcome } from "../src/services/autopilot/shell";

/**
 * The no-click state machine. Command and open steps advance themselves; only a
 * sign-in / permission / manual step stops for the reader, and a failed command
 * surfaces rather than pretending to recover.
 */

function commandStep(id: string, command: string): RecipeStep {
  return { id, title: `Run ${id}`, kind: "command", command };
}

function recipe(steps: RecipeStep[]): InstallRecipe {
  return {
    slug: "demo",
    appName: "Demo",
    output: { type: "desktop_app", launch: { via: "shell", command: 'start "" Demo' } },
    steps,
  };
}

describe("the autopilot runner", () => {
  it("runs a clean recipe to the end and reports what to open", async () => {
    const runner = new AutopilotRunner(
      recipe([commandStep("clone", "git clone https://example.com/x.git"), commandStep("build", "npm ci")]),
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("finished");
    if (status.type === "finished") {
      expect(status.output.type).toBe("desktop_app");
    }
    expect(shell.commandsRun).toHaveLength(2);
    expect(runner.drainEvents().at(-1)?.type).toBe("finished");
  });

  it("advances an open step with no tap", async () => {
    const runner = new AutopilotRunner(
      recipe([
        { id: "docs", title: "Open the docs", kind: "open", href: "https://publikhq.com" },
        commandStep("build", "npm ci"),
      ]),
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("finished");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested")).toBe(true);
    expect(events.some((event) => event.type === "handedToReader")).toBe(false);
  });

  it("stops for the reader at a sign-in, then resumes on its own", async () => {
    const runner = new AutopilotRunner(
      recipe([
        commandStep("clone", "git clone https://example.com/x.git"),
        {
          id: "sign-in",
          title: "Sign in",
          kind: "sign_in",
          href: "https://example.com/login",
          instruction: "Sign in and come back.",
        },
        commandStep("finish", "npm run setup"),
      ]),
    );
    const shell = MockShell.alwaysSucceeds();

    const blocked = await runner.runUntilBlocked(shell);
    expect(blocked.type).toBe("needsReader");
    if (blocked.type === "needsReader") {
      expect(blocked.stepIndex).toBe(1);
      expect(blocked.instruction).toBe("Sign in and come back.");
      expect(blocked.href).toBe("https://example.com/login");
    }

    const resumed = await runner.readerFinishedCurrentStep(shell);
    expect(resumed.type).toBe("finished");
    expect(shell.commandsRun).toEqual(["git clone https://example.com/x.git", "npm run setup"]);
  });

  it("surfaces a failing command rather than pretending", async () => {
    const runner = new AutopilotRunner(recipe([commandStep("build", "npm ci")]));
    const failing: CommandOutcome = { kind: "failed", exitCode: 1, output: "npm ERR!" };
    const shell = new MockShell([failing]);

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("surfaced");
  });

  it("waits at a confirm-tier command, then runs it on approval", async () => {
    const runner = new AutopilotRunner(recipe([commandStep("elevate", "Set-ExecutionPolicy Bypass -Scope Process")]));
    const shell = MockShell.alwaysSucceeds();

    const blocked = await runner.runUntilBlocked(shell);
    expect(blocked.type).toBe("needsConfirm");
    expect(shell.commandsRun).toHaveLength(0);

    const approved = await runner.confirmCurrentCommand(true, shell);
    expect(approved.type).toBe("finished");
    expect(shell.commandsRun).toHaveLength(1);
  });

  it("surfaces and never runs a declined confirm command", async () => {
    const runner = new AutopilotRunner(recipe([commandStep("elevate", "Start-Process powershell -Verb RunAs")]));
    const shell = MockShell.alwaysSucceeds();

    expect((await runner.runUntilBlocked(shell)).type).toBe("needsConfirm");
    expect((await runner.confirmCurrentCommand(false, shell)).type).toBe("surfaced");
    expect(shell.commandsRun).toHaveLength(0);
  });

  it("starts a long-running dev server instead of hanging on it", async () => {
    const runner = new AutopilotRunner(
      recipe([{ id: "run", title: "Start server", kind: "command", command: "pnpm dev", longRunning: true, readyWhen: "localhost" }]),
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("finished");
    expect(shell.commandsRun).toEqual(["pnpm dev"]);
  });
});
