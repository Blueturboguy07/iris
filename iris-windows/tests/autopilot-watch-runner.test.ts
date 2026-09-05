import { describe, expect, it } from "vitest";
import type { InstallRecipe, RecipeStep } from "../src/services/autopilot/recipe";
import { AutopilotRunner, type AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell } from "../src/services/autopilot/shell";
import { WatchStepExecutor, type WatchSeams } from "../src/services/autopilot/watch";

/**
 * How the runner wires the watch executor in: a `verify` step blocks on it, a
 * reader step that carries a watch is auto-advanced when it verifies, and a
 * timeout hands the step back to the reader with the verifier label.
 */

/** Fake seams whose only live signal is a foreground process name (enough to
 *  make a foregroundApp expectation verify or not). Everything else is inert,
 *  and the clock never advances, so a non-verifying watch just polls to timeout
 *  in zero real time. */
function seamsWithForeground(processName: string | undefined): WatchSeams {
  return {
    async isToolInstalled() {
      return false;
    },
    async readForegroundProcess() {
      return processName === undefined ? undefined : { pid: 1, processName };
    },
    async readForegroundBrowserHost() {
      return undefined;
    },
    async isAxElementPresent() {
      return false;
    },
    async captureScreenshotJpegBase64() {
      return undefined;
    },
    async evaluateVisualCheck() {
      return undefined;
    },
    nowInSeconds() {
      return 0;
    },
    async waitForMilliseconds() {
      // Instant — the whole point of the seam is that a bounded poll loop runs
      // in zero real time in the suite.
    },
  };
}

function recipe(steps: RecipeStep[]): InstallRecipe {
  return {
    slug: "demo",
    appName: "Demo",
    output: { type: "desktop_app", launch: { via: "shell", command: 'start "" Demo' } },
    steps,
  };
}

/** A verify step keeps the poll budget tiny so a timeout is instant. */
function executorThatVerifiesForeground(processName: string | undefined): WatchStepExecutor {
  return new WatchStepExecutor(seamsWithForeground(processName));
}

describe("the runner's watch wiring", () => {
  it("advances a verify step on its own when the watch verifies", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "confirm-open",
          title: "Wait for the app to open",
          kind: "verify",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "Open publikclip to finish.",
        },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      executorThatVerifiesForeground("publikclip-app.exe"),
    );

    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("finished");

    const events = runner.drainEvents();
    const watchVerified = events.find((event) => event.type === "watchVerified");
    expect(watchVerified).toMatchObject({ type: "watchVerified", verifiedBy: "foregroundApp" });
    // A pure verify step never surfaces "your turn" when it verifies on its own.
    expect(events.some((event) => event.type === "handedToReader")).toBe(false);
  });

  it("hands a verify step to the reader with its verifier label when the watch times out", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "confirm-open",
          title: "Wait for the app to open",
          kind: "verify",
          watch: {
            expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }],
          },
          verifierLabel: "Open publikclip to finish.",
        },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      // Nothing is in front, so the foregroundApp expectation never verifies.
      executorThatVerifiesForeground(undefined),
    );

    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("needsReader");
    if (status.type === "needsReader") {
      expect(status.instruction).toBe("Open publikclip to finish.");
    }

    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "watchTimedOut")).toBe(true);
    const handedToReader = events.find((event) => event.type === "handedToReader");
    expect(handedToReader).toMatchObject({ type: "handedToReader", instruction: "Open publikclip to finish." });
  });

  it("falls back to a reader handoff for a verify step with no executor wired", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "confirm-open",
          title: "Wait for the app to open",
          kind: "verify",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "Open publikclip to finish.",
        },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      // No executor.
    );

    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("needsReader");
    const events = runner.drainEvents();
    // Nothing was watched, so no verified/timed-out event — just the handoff.
    expect(events.some((event) => event.type === "watchTimedOut")).toBe(false);
    expect(events.some((event) => event.type === "handedToReader")).toBe(true);
  });

  it("auto-advances a reader step that carries a watch when it verifies, with no tap", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "sign-in",
          title: "Sign in",
          kind: "sign_in",
          href: "https://example.com/login",
          instruction: "Sign in and come back.",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
        },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      executorThatVerifiesForeground("publikclip-app.exe"),
    );

    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("finished");

    const events: AutopilotEvent[] = runner.drainEvents();
    // It surfaces "your turn" up front (so the reader can act) AND then advances
    // itself once the watch verifies.
    const handedIndex = events.findIndex((event) => event.type === "handedToReader");
    const verifiedIndex = events.findIndex((event) => event.type === "watchVerified");
    expect(handedIndex).toBeGreaterThanOrEqual(0);
    expect(verifiedIndex).toBeGreaterThan(handedIndex);
  });

  it("hands a watched reader step back on timeout, then resumes when the reader finishes", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "sign-in",
          title: "Sign in",
          kind: "sign_in",
          href: "https://example.com/login",
          instruction: "Sign in and come back.",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
        },
        { id: "finish", title: "Finish", kind: "command", command: "npm run setup" },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      executorThatVerifiesForeground(undefined),
    );
    const shell = MockShell.alwaysSucceeds();

    const blocked = await runner.runUntilBlocked(shell);
    expect(blocked.type).toBe("needsReader");
    if (blocked.type === "needsReader") {
      // The reader's own instruction, not the verifier label — this step is the
      // reader's to do; the watch was only a chance to skip the tap.
      expect(blocked.instruction).toBe("Sign in and come back.");
    }
    expect(runner.drainEvents().some((event) => event.type === "watchTimedOut")).toBe(true);

    const resumed = await runner.readerFinishedCurrentStep(shell);
    expect(resumed.type).toBe("finished");
    expect(shell.commandsRun).toEqual(["npm run setup"]);
  });

  it("leaves a reader step with no watch exactly as it was", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "sign-in",
          title: "Sign in",
          kind: "sign_in",
          href: "https://example.com/login",
          instruction: "Sign in and come back.",
        },
      ]),
      "win32",
      true,
      undefined, // no fix ladder in the watch-runner tests
      executorThatVerifiesForeground("publikclip-app.exe"),
    );

    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("needsReader");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "watchVerified")).toBe(false);
    expect(events.some((event) => event.type === "handedToReader")).toBe(true);
  });
});
