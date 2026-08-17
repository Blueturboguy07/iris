import { describe, expect, it } from "vitest";
import { AutopilotController, type AutopilotHost, type FinishedInstall } from "../src/main/autopilot-controller";
import type { InstallRecipe } from "../src/services/autopilot/recipe";
import type { AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell } from "../src/services/autopilot/shell";

/**
 * The controller is the seam between the pure runner and Electron. These pin the
 * two app-only side effects it owns — opening links and floating to a gate — plus
 * that a finished install reports its output. All with a fake host and a mock
 * shell, so it runs on any host.
 */

class RecordingHost implements AutopilotHost {
  readonly events: AutopilotEvent[] = [];
  readonly opened: string[] = [];
  readonly floated: Array<{ instruction: string; href: string | undefined }> = [];
  finishedInstall: FinishedInstall | undefined;

  emitEvent(event: AutopilotEvent): void {
    this.events.push(event);
  }
  openExternal(url: string): void {
    this.opened.push(url);
  }
  floatToGate(instruction: string, href: string | undefined): void {
    this.floated.push({ instruction, href });
  }
  onFinished(finishedInstall: FinishedInstall): void {
    this.finishedInstall = finishedInstall;
  }
}

function controllerFor(recipe: InstallRecipe, shell = MockShell.alwaysSucceeds()): { controller: AutopilotController; host: RecordingHost; shell: MockShell } {
  const host = new RecordingHost();
  const controller = new AutopilotController(host, () => shell, (slug) => (slug === recipe.slug ? recipe : undefined));
  return { controller, host, shell };
}

const localWebRecipe: InstallRecipe = {
  slug: "web",
  appName: "Web",
  output: { type: "local_web", url: "http://localhost:5173" },
  steps: [
    { id: "clone", title: "Clone", kind: "command", command: "git clone https://example.com/x.git" },
    { id: "open", title: "Open it", kind: "open", href: "http://localhost:5173" },
  ],
};

describe("the autopilot controller", () => {
  it("streams events, opens an open step's link, and reports the finished output", async () => {
    const { controller, host, shell } = controllerFor(localWebRecipe);

    const status = await controller.start("web");

    expect(status.type).toBe("finished");
    expect(shell.commandsRun).toEqual(["git clone https://example.com/x.git"]);
    expect(host.opened).toContain("http://localhost:5173"); // the open step
    expect(host.finishedInstall?.output).toEqual({ type: "local_web", url: "http://localhost:5173" });
    expect(host.events.some((event) => event.type === "finished")).toBe(true);
  });

  it("reports the finished install's provenance facts — clone flag, clone path, repo, and commit", async () => {
    const desktopRecipe: InstallRecipe = {
      slug: "publikclip",
      appName: "publikclip",
      output: { type: "desktop_app", launch: { via: "path", path: "C:\\App\\app.exe" } },
      canonicalRepo: "Blueturboguy07/publikclip",
      pinnedCommit: "a53a359b985b1d2d666266062936cc186f02340b",
      steps: [
        { id: "clone", title: "Clone", kind: "command", command: "git clone https://github.com/Blueturboguy07/publikclip.git" },
        { id: "enter", title: "Enter", kind: "command", command: "cd publikclip" },
      ],
    };
    // A shell whose cwd is the clone directory the recipe cd'd into.
    const shell = new MockShell([], "C:\\Users\\test\\publikclip");
    const { controller, host } = controllerFor(desktopRecipe, shell);

    const status = await controller.start("publikclip");

    expect(status.type).toBe("finished");
    expect(host.finishedInstall).toEqual({
      slug: "publikclip",
      appName: "publikclip",
      output: { type: "desktop_app", launch: { via: "path", path: "C:\\App\\app.exe" } },
      canonicalRepo: "Blueturboguy07/publikclip",
      pinnedCommit: "a53a359b985b1d2d666266062936cc186f02340b",
      clonedARepo: true,
      clonePath: "C:\\Users\\test\\publikclip",
    });
  });

  it("floats to a gate on a sign-in step and resumes when the reader is done", async () => {
    const signInRecipe: InstallRecipe = {
      slug: "auth",
      appName: "Auth",
      output: { type: "none" },
      steps: [
        {
          id: "sign-in",
          title: "Sign in",
          kind: "sign_in",
          href: "https://example.com/login",
          instruction: "Sign in, then Iris carries on.",
        },
        { id: "after", title: "Finish", kind: "command", command: "npm run setup" },
      ],
    };
    const { controller, host, shell } = controllerFor(signInRecipe);

    const blocked = await controller.start("auth");
    expect(blocked.type).toBe("needsReader");
    expect(host.floated).toEqual([{ instruction: "Sign in, then Iris carries on.", href: "https://example.com/login" }]);
    expect(shell.commandsRun).toHaveLength(0);

    const resumed = await controller.readerFinished();
    expect(resumed.type).toBe("finished");
    expect(shell.commandsRun).toEqual(["npm run setup"]);
  });

  it("waits for a confirm without floating, then runs on approval", async () => {
    const riskyRecipe: InstallRecipe = {
      slug: "risky",
      appName: "Risky",
      output: { type: "none" },
      steps: [{ id: "elevate", title: "Elevate", kind: "command", command: "Set-ExecutionPolicy Bypass -Scope Process" }],
    };
    const { controller, host, shell } = controllerFor(riskyRecipe);

    const blocked = await controller.start("risky");
    expect(blocked.type).toBe("needsConfirm");
    expect(host.floated).toHaveLength(0);
    expect(shell.commandsRun).toHaveLength(0);

    const done = await controller.confirm(true);
    expect(done.type).toBe("finished");
    expect(shell.commandsRun).toHaveLength(1);
  });

  it("knows which apps it can install", () => {
    const { controller } = controllerFor(localWebRecipe);
    expect(controller.canInstall("web")).toBe(true);
    expect(controller.canInstall("nope")).toBe(false);
  });

  it("throws when asked to install an app it has no recipe for", async () => {
    const { controller } = controllerFor(localWebRecipe);
    await expect(controller.start("nope")).rejects.toThrow(/no Windows recipe/);
  });
});
