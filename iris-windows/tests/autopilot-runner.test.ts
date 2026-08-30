import { describe, expect, it } from "vitest";
import type { InstallRecipe, RecipeStep } from "../src/services/autopilot/recipe";
import { AutopilotRunner, isAPlainFolder } from "../src/services/autopilot/runner";
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

  // Parity with the macOS runner's `moveInto` — the resume bug, which is the
  // same bug on both clients: a resumed install starts a brand-new shell in the
  // home folder, so a step written relative to an earlier `cd` runs in the
  // wrong place and fails with a 127 nobody can read.
  //
  // The platform is PINNED in both directions, and that is the point of the
  // second case. This test used to construct the runner with the default
  // platform — `process.platform`, i.e. darwin on the machine this is written
  // on — and still assert a `Set-Location`. `MockShell` answers "succeeded" to
  // any string, so it passed while the real zsh session the runner drives on a
  // Mac would have answered `command not found: Set-Location`, exit 127, and
  // surfaced every declared step. The test was measuring that the runner emits
  // a string, not that the string is a command the shell speaks.
  it("moves into the folder a step declares before running its command", async () => {
    const runner = new AutopilotRunner(
      recipe([
        { ...commandStep("build", "pnpm build"), workingDirectory: "~/publikclip/app" },
      ]),
      "win32",
    );
    const shell = MockShell.alwaysSucceeds();

    expect((await runner.runUntilBlocked(shell)).type).toBe("finished");
    // A SEPARATE Set-Location whose outcome is checked, never a `;` chain:
    // PowerShell's `;` does not abort on a failed Set-Location.
    expect(shell.commandsRun).toEqual(["Set-Location ~/publikclip/app", "pnpm build"]);
  });

  it("uses a folder move the shell it is actually driving understands", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          ...commandStep("build", "pnpm build"),
          workingDirectory: "~/publikclip/app",
          posixWorkingDirectory: "~/iris-apps/publikclip/app",
        },
      ]),
      "darwin",
    );
    const shell = MockShell.alwaysSucceeds();

    expect((await runner.runUntilBlocked(shell)).type).toBe("finished");
    // `cd`, not `Set-Location` — and the posix folder, because the two
    // platforms' clone steps do not land in the same place.
    expect(shell.commandsRun).toEqual(["cd ~/iris-apps/publikclip/app", "pnpm build"]);
  });

  it("treats an empty declared folder as no declaration at all", async () => {
    // The guide renderers fill the field in with "" when a step omits it, and a
    // `cd` with no argument goes home — which is the bug, not the fix.
    const runner = new AutopilotRunner(
      recipe([{ ...commandStep("build", "npm ci"), workingDirectory: "" }]),
      "win32",
    );
    const shell = MockShell.alwaysSucceeds();

    expect((await runner.runUntilBlocked(shell)).type).toBe("finished");
    expect(shell.commandsRun).toEqual(["npm ci"]);
  });

  it("leaves a step that declares no folder exactly where the shell already is", async () => {
    const runner = new AutopilotRunner(recipe([commandStep("build", "npm ci")]));
    const shell = MockShell.alwaysSucceeds();

    expect((await runner.runUntilBlocked(shell)).type).toBe("finished");
    expect(shell.commandsRun).toEqual(["npm ci"]);
  });

  it("stops the step rather than running the command in the wrong folder", async () => {
    const failedMove: CommandOutcome = { kind: "failed", exitCode: 1, output: "Cannot find path" };
    const runner = new AutopilotRunner(
      recipe([
        { ...commandStep("build", "pnpm build"), workingDirectory: "~/publikclip/app" },
      ]),
      "win32",
    );
    const shell = new MockShell([failedMove]);

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("surfaced");
    if (status.type === "surfaced") {
      expect(status.reason).toContain("~/publikclip/app");
    }
    // The command itself was never typed — that is the whole point.
    expect(shell.commandsRun).toEqual(["Set-Location ~/publikclip/app"]);
  });

  it("refuses a declared folder that is not a plain path", () => {
    for (const folder of ["~/cue; rm -rf ~", "~/cue/../../etc", "$HOME/cue", '"~/cue"', "cue", ""]) {
      expect(isAPlainFolder(folder), folder).toBe(false);
    }
    for (const folder of ["~/cue", "~/publikclip/app", "/opt/src", "C:\\Users\\me\\cue"]) {
      expect(isAPlainFolder(folder), folder).toBe(true);
    }
  });
});
