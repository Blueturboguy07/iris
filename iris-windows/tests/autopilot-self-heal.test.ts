import { describe, expect, it } from "vitest";

import type { InstallRecipe } from "../src/services/autopilot/recipe";
import { AutopilotRunner } from "../src/services/autopilot/runner";
import { MockShell, type CommandOutcome } from "../src/services/autopilot/shell";

/**
 * The mid-recipe missing-tool self-heal in the runner — the Windows port of
 * macOS `installTheMissingToolTheGuideInstallsItself`. A command that dies
 * because a tool it needs is not on the PATH, when the recipe has its OWN earlier
 * step that installs that tool, gets the install step re-run once and the command
 * retried — before any surface (or, later, model ladder). Once only: a step that
 * still fails after the repair escalates.
 */

const NOT_RECOGNIZED = "pnpm : The term 'pnpm' is not recognized as the name of a cmdlet, function, script file";

// A recipe whose step 0 installs pnpm and whose step 1 uses it — the shape that
// exercises the self-heal.
function pnpmRecipe(): InstallRecipe {
  return {
    slug: "demo",
    appName: "Demo",
    output: { type: "local_web", url: "http://localhost:5173" },
    steps: [
      { id: "install-pnpm", title: "Install pnpm", kind: "command", command: "npm.cmd install -g pnpm", check: { type: "tool_version", tool: "pnpm" } },
      { id: "use-pnpm", title: "Install deps", kind: "command", command: "pnpm install" },
    ],
  };
}

function grantedRunner(recipe: InstallRecipe): AutopilotRunner {
  // Granted, as production always is once the reader consents.
  return new AutopilotRunner(recipe, "win32", true);
}

describe("the runner's missing-tool self-heal", () => {
  it("re-runs the recipe's own install step once and retries the failed command", async () => {
    const shell = new MockShell([
      { kind: "succeeded", output: "" }, // step 0: install pnpm (the tool is on disk but not yet on PATH)
      { kind: "failed", exitCode: 1, output: NOT_RECOGNIZED }, // step 1: pnpm not recognized
      { kind: "succeeded", output: "" }, // self-heal: re-run the install step
      { kind: "succeeded", output: "" }, // self-heal: retry pnpm install — now works
    ]);
    const runner = grantedRunner(pnpmRecipe());

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("finished");
    // The install step was run twice (once in order, once to repair) and the
    // failing command twice (the failure, then the successful retry).
    expect(shell.commandsRun).toEqual([
      "npm.cmd install -g pnpm",
      "pnpm install",
      "npm.cmd install -g pnpm",
      "pnpm install",
    ]);
    const events = runner.drainEvents();
    const heal = events.find((e) => e.type === "installingMissingTool");
    expect(heal).toMatchObject({ type: "installingMissingTool", tool: "pnpm", command: "npm.cmd install -g pnpm" });
  });

  it("escalates (surfaces) when the command still fails after the one repair", async () => {
    const shell = new MockShell([
      { kind: "succeeded", output: "" }, // step 0
      { kind: "failed", exitCode: 1, output: NOT_RECOGNIZED }, // step 1 fails
      { kind: "succeeded", output: "" }, // repair install
      { kind: "failed", exitCode: 1, output: NOT_RECOGNIZED }, // retry STILL fails
    ]);
    const runner = grantedRunner(pnpmRecipe());

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("surfaced");
    // Exactly one repair: the install step ran twice, not three-plus times.
    expect(shell.commandsRun.filter((c) => c === "npm.cmd install -g pnpm")).toHaveLength(2);
    expect(shell.commandsRun.filter((c) => c === "pnpm install")).toHaveLength(2);
  });

  it("does not self-heal an ordinary (non-command-not-found) failure", async () => {
    const shell = new MockShell([
      { kind: "succeeded", output: "" }, // step 0
      { kind: "failed", exitCode: 1, output: "npm ERR! ELIFECYCLE build broke" }, // an ordinary failure
    ]);
    const runner = grantedRunner(pnpmRecipe());

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("surfaced");
    // The install step was NOT re-run; the failing command was NOT retried.
    expect(shell.commandsRun).toEqual(["npm.cmd install -g pnpm", "pnpm install"]);
    expect(runner.drainEvents().some((e) => e.type === "installingMissingTool")).toBe(false);
  });

  it("does not self-heal when the recipe has no install step for the missing tool", async () => {
    const recipe: InstallRecipe = {
      slug: "demo",
      appName: "Demo",
      output: { type: "none" },
      steps: [
        { id: "check-git", title: "Check Git", kind: "command", command: "git --version", check: { type: "tool_version", tool: "git" } },
        { id: "build", title: "Build", kind: "command", command: "foo build" },
      ],
    };
    const shell = new MockShell([
      { kind: "succeeded", output: "" }, // git --version
      { kind: "failed", exitCode: 1, output: "'foo' is not recognized as the name of a cmdlet" }, // foo missing, no install step for it
    ]);
    const runner = grantedRunner(recipe);

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("surfaced");
    expect(shell.commandsRun).toEqual(["git --version", "foo build"]);
    expect(runner.drainEvents().some((e) => e.type === "installingMissingTool")).toBe(false);
  });

  it("runs the repair install step in the folder it declares", async () => {
    const recipe: InstallRecipe = {
      slug: "demo",
      appName: "Demo",
      output: { type: "none" },
      steps: [
        { id: "install-pnpm", title: "Install pnpm", kind: "command", command: "npm.cmd install -g pnpm", check: { type: "tool_version", tool: "pnpm" }, workingDirectory: "~/app" },
        { id: "use-pnpm", title: "Install deps", kind: "command", command: "pnpm install", workingDirectory: "~/app" },
      ],
    };
    const shell = new MockShell([
      { kind: "succeeded", output: "" }, // move into ~/app for step 0
      { kind: "succeeded", output: "" }, // step 0 install
      { kind: "succeeded", output: "" }, // move into ~/app for step 1
      { kind: "failed", exitCode: 1, output: NOT_RECOGNIZED }, // step 1 fails
      { kind: "succeeded", output: "" }, // repair: move into ~/app
      { kind: "succeeded", output: "" }, // repair: install
      { kind: "succeeded", output: "" }, // retry: move into ~/app
      { kind: "succeeded", output: "" }, // retry: pnpm install works
    ]);
    const runner = grantedRunner(recipe);

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("finished");
    // Set-Location ~/app appears both for the ordinary steps and the repair.
    expect(shell.commandsRun.filter((c) => c === "Set-Location ~/app").length).toBeGreaterThanOrEqual(4);
  });
});

// Keep the outcome shape imported so a future edit that drops it is caught.
const _shape: CommandOutcome = { kind: "succeeded", output: "" };
void _shape;
