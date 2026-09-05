import { describe, expect, it } from "vitest";

import { AutopilotController, type AutopilotHost, type FinishedInstall } from "../src/main/autopilot-controller";
import type { InstallRecipe } from "../src/services/autopilot/recipe";
import type { AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell } from "../src/services/autopilot/shell";
import { wingetInstallCommand, type DetourClock, type ToolProbe } from "../src/services/autopilot/setup-detour";

/**
 * The controller wiring for the setup-recovery detour: with the detour seams
 * present, `start` walks the detour before the recipe, and an `openRequested`
 * from the detour reaches `openExternal` the same way a recipe's open step does.
 */

class RecordingHost implements AutopilotHost {
  readonly events: AutopilotEvent[] = [];
  readonly opened: string[] = [];
  finishedInstall: FinishedInstall | undefined;
  async ensureAutonomyGranted(): Promise<boolean> {
    return true;
  }
  emitEvent(event: AutopilotEvent): void {
    this.events.push(event);
  }
  openExternal(url: string): void {
    this.opened.push(url);
  }
  floatToGate(): void {}
  onFinished(finishedInstall: FinishedInstall): void {
    this.finishedInstall = finishedInstall;
  }
}

class FakeToolProbe implements ToolProbe {
  constructor(
    private readonly answers: Record<string, boolean[]>,
    private readonly wingetPresent = true,
  ) {}
  async isInstalled(tool: string): Promise<boolean> {
    const sequence = this.answers[tool] ?? [false];
    return sequence.length > 1 ? sequence.shift()! : sequence[0]!;
  }
  async isWingetAvailable(): Promise<boolean> {
    return this.wingetPresent;
  }
}

class FakeClock implements DetourClock {
  private t = 0;
  now(): number {
    return this.t;
  }
  async sleep(ms: number): Promise<void> {
    this.t += ms;
  }
}

const recipe: InstallRecipe = {
  slug: "demo",
  appName: "Demo",
  output: { type: "local_web", url: "http://localhost:5173" },
  steps: [
    { id: "check-git", title: "Check Git", kind: "command", command: "git --version", check: { type: "tool_version", tool: "git" } },
    { id: "check-node", title: "Check Node", kind: "command", command: "node --version", check: { type: "tool_version", tool: "node" } },
    { id: "clone", title: "Clone", kind: "command", command: "git clone https://example.com/x.git" },
  ],
};

function controllerWith(probe: ToolProbe): { controller: AutopilotController; host: RecordingHost; shell: MockShell } {
  const host = new RecordingHost();
  const shell = MockShell.alwaysSucceeds();
  const controller = new AutopilotController(
    host,
    () => shell,
    (slug) => (slug === recipe.slug ? recipe : undefined),
    { probe, clock: new FakeClock() },
  );
  return { controller, host, shell };
}

describe("the controller's setup detour", () => {
  it("installs a missing prerequisite with winget, then runs the recipe to the end", async () => {
    const { controller, host, shell } = controllerWith(
      new FakeToolProbe({ git: [false, true], node: [true] }, true),
    );

    const status = await controller.start("demo");

    expect(status.type).toBe("finished");
    expect(shell.commandsRun).toContain(wingetInstallCommand("Git.Git"));
    expect(shell.commandsRun).toContain("git clone https://example.com/x.git");
    expect(host.events.some((e) => e.type === "setupDetour")).toBe(true);
    expect(host.opened).not.toContain("https://git-scm.com/download/win"); // winget worked, no page
  });

  it("opens the download page through openExternal when winget is absent", async () => {
    const { controller, host } = controllerWith(
      new FakeToolProbe({ git: [false, true], node: [true] }, false),
    );

    const status = await controller.start("demo");

    expect(status.type).toBe("finished");
    // The detour's openRequested reached openExternal via the shared forwarder.
    expect(host.opened).toContain("https://git-scm.com/download/win");
  });

  it("surfaces (and never starts the recipe) when a prerequisite never appears", async () => {
    const { controller, host, shell } = controllerWith(
      new FakeToolProbe({ git: [false], node: [true] }, false),
    );

    const status = await controller.start("demo");

    expect(status.type).toBe("surfaced");
    // The recipe's own steps never ran — the detour stopped first.
    expect(shell.commandsRun).not.toContain("git clone https://example.com/x.git");
    expect(host.events.some((e) => e.type === "surfaced")).toBe(true);
  });
});
