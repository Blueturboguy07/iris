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
    async captureScreenFingerprint() {
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

  // ---- an `open` step consults its watch (finding 5) ----
  // publikclip / hickeyfield / whimprflow author `install-rust` as kind:"open"
  // with a watch: opening rustup.rs is NOT the finish — the reader still has to
  // run the installer, so the step must not advance until the watch confirms it.

  it("does not advance an open step past its watch until it verifies", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "install-rust",
          title: "Install Rust",
          kind: "open",
          href: "https://rustup.rs",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "Finish the rustup installer, then Iris will carry on.",
        },
        { id: "after", title: "Build it", kind: "command", command: "cargo build --release" },
      ]),
      "win32",
      true,
      undefined,
      executorThatVerifiesForeground(undefined), // the installer is not finished
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);

    // Opened the link and surfaced "your turn", but did NOT advance — the watch
    // could not confirm rustup finished, so it hands back rather than marching
    // into a `cargo build` in a shell that has no cargo.
    expect(status.type).toBe("needsReader");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested")).toBe(true);
    expect(events.some((event) => event.type === "watchTimedOut")).toBe(true);
    expect(shell.commandsRun).toEqual([]); // cargo never ran
  });

  it("advances an open step the moment its watch verifies", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "install-rust",
          title: "Install Rust",
          kind: "open",
          href: "https://rustup.rs",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
        },
        { id: "after", title: "Build it", kind: "command", command: "cargo build --release" },
      ]),
      "win32",
      true,
      undefined,
      executorThatVerifiesForeground("publikclip-app.exe"), // the installer landed
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("finished");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested")).toBe(true);
    expect(events.some((event) => event.type === "watchVerified")).toBe(true);
    expect(shell.commandsRun).toEqual(["cargo build --release"]);
  });

  // ---- the red 'Stop' cancels an in-flight watch (finding 2) ----

  it("discards a watched step's outcome and runs no further step when the reader aborts mid-watch", async () => {
    // A seam that WOULD verify the step, but aborts the run the instant it is
    // read — so the runner must discard the outcome rather than advance.
    const seams = seamsWithForeground("publikclip-app.exe");
    // eslint-disable-next-line prefer-const -- assigned just below, read in the seam
    let runner: AutopilotRunner;
    const originalRead = seams.readForegroundProcess;
    seams.readForegroundProcess = async () => {
      runner.abort();
      return originalRead();
    };
    runner = new AutopilotRunner(
      recipe([
        {
          id: "verify",
          title: "Wait for the app",
          kind: "verify",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "Open publikclip to finish.",
        },
        { id: "after", title: "After", kind: "command", command: "npm run setup" },
      ]),
      "win32",
      true,
      undefined,
      new WatchStepExecutor(seams),
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);

    expect(status.type).toBe("aborted");
    const events = runner.drainEvents();
    // No stale watchVerified / advanced despite the side signal being satisfiable.
    expect(events.some((event) => event.type === "watchVerified")).toBe(false);
    expect(shell.commandsRun).toEqual([]); // the next step never ran
  });
});

describe("an `open` step that carries a watch (finding: opening the page is not the finish)", () => {
  it("opens the page, surfaces 'your turn', and advances only once the watch verifies", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "install-rust",
          title: "Install Rust",
          kind: "open",
          href: "https://rustup.rs",
          // The live guide watches cargo + a visual prompt; a foregroundApp stand-in
          // keeps the fake seam able to verify it.
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "cargo responds with a version number",
        },
        { id: "build", title: "Build", kind: "command", command: "cargo build" },
      ]),
      "win32",
      true,
      undefined,
      executorThatVerifiesForeground("publikclip-app.exe"),
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("finished");

    const events = runner.drainEvents();
    // The page opened...
    expect(events.some((event) => event.type === "openRequested" && event.href === "https://rustup.rs")).toBe(true);
    // ...the reader was told it was their turn (the install is a manual GUI one)...
    const handedIndex = events.findIndex((event) => event.type === "handedToReader");
    const verifiedIndex = events.findIndex((event) => event.type === "watchVerified");
    expect(handedIndex).toBeGreaterThanOrEqual(0);
    // ...and only then did the step advance, so the later `cargo build` ran AFTER
    // rust was confirmed rather than before it existed.
    expect(verifiedIndex).toBeGreaterThan(handedIndex);
    expect(shell.commandsRun).toEqual(["cargo build"]);
  });

  it("hands an open+watch step back to the reader (not the next step) when the watch never verifies", async () => {
    const runner = new AutopilotRunner(
      recipe([
        {
          id: "install-rust",
          title: "Install Rust",
          kind: "open",
          href: "https://rustup.rs",
          watch: { expect: [{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }] },
          verifierLabel: "cargo responds with a version number",
        },
        { id: "build", title: "Build", kind: "command", command: "cargo build" },
      ]),
      "win32",
      true,
      undefined,
      executorThatVerifiesForeground(undefined), // nothing verifies
    );
    const shell = MockShell.alwaysSucceeds();

    const status = await runner.runUntilBlocked(shell);
    expect(status.type).toBe("needsReader");
    // The page opened, but the install did NOT march on to `cargo build` without rust.
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested")).toBe(true);
    expect(events.some((event) => event.type === "watchTimedOut")).toBe(true);
    expect(shell.commandsRun).toEqual([]);
  });

  it("still advances an `open` step with NO watch the instant it opens (unchanged)", async () => {
    const runner = new AutopilotRunner(
      recipe([
        { id: "open-store", title: "Open the store", kind: "open", href: "https://example.com" },
        { id: "done", title: "Done", kind: "command", command: "echo hi" },
      ]),
      "win32",
      true,
      undefined,
      executorThatVerifiesForeground(undefined),
    );
    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("finished");
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested")).toBe(true);
    // No watch, so no handoff and no watch events — opening it was the whole step.
    expect(events.some((event) => event.type === "handedToReader")).toBe(false);
    expect(events.some((event) => event.type === "watchVerified" || event.type === "watchTimedOut")).toBe(false);
  });
});

describe("the live event sink (finding: events must not be batched until the run blocks)", () => {
  it("delivers each event to the sink as it happens, leaving drainEvents empty", async () => {
    const sinkEvents: AutopilotEvent[] = [];
    const runner = new AutopilotRunner(
      recipe([{ id: "one", title: "One", kind: "command", command: "echo hi" }]),
      "win32",
      true,
      undefined,
      undefined,
      (event) => sinkEvents.push(event), // the eventSink
    );

    await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    // Everything went to the sink live; nothing was buffered for a later drain.
    expect(sinkEvents.length).toBeGreaterThan(0);
    expect(runner.drainEvents()).toEqual([]);
    expect(sinkEvents.some((event) => event.type === "finished")).toBe(true);
  });

  it("surfaces a reader step's 'your turn' to the sink BEFORE the watch begins its wait", async () => {
    const sinkEvents: AutopilotEvent[] = [];
    let sinkSnapshotWhenWatchStarted: AutopilotEvent[] | undefined;

    // Seams that, the first time the watch reads a signal, record what the sink
    // has already received — proving `handedToReader` arrived up front, not after.
    const seams: WatchSeams = {
      async isToolInstalled() {
        return false;
      },
      async readForegroundProcess() {
        if (sinkSnapshotWhenWatchStarted === undefined) {
          sinkSnapshotWhenWatchStarted = [...sinkEvents];
        }
        return undefined; // never verifies → times out
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
      async captureScreenFingerprint() {
        return undefined;
      },
      async evaluateVisualCheck() {
        return undefined;
      },
      nowInSeconds() {
        return 0;
      },
      async waitForMilliseconds() {
        /* instant */
      },
    };

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
      undefined,
      new WatchStepExecutor(seams),
      (event) => sinkEvents.push(event),
    );

    await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(sinkSnapshotWhenWatchStarted).toBeDefined();
    // The reader saw "your turn" the moment the step opened, not minutes later.
    expect((sinkSnapshotWhenWatchStarted ?? []).some((event) => event.type === "handedToReader")).toBe(true);
  });
});
