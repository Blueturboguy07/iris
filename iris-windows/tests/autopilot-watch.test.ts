import { describe, expect, it } from "vitest";
import type { StepWatch, WatchExpectation } from "../src/services/autopilot/recipe";
import {
  buildActiveBrowserUrlCommand,
  buildAxElementQueryCommand,
  foregroundProcessSatisfiesIdentity,
  hostFromAddressBarText,
  hostMatchesExpectedHost,
  orderExpectationsCheapestFirst,
  parseActiveBrowserUrlOutput,
  parseAxElementPresenceOutput,
  verdictFromVisualModelAnswer,
  visualCheckSystemPrompt,
  visualCheckUserPrompt,
  windowsExecutableForForegroundIdentity,
  WatchStepExecutor,
  MAXIMUM_VISUAL_CHECKS_PER_STEP,
  MINIMUM_SECONDS_BETWEEN_VISUAL_CHECKS,
  type WatchSeams,
  type WatchVerdict,
} from "../src/services/autopilot/watch";

/**
 * The watch-expectation executor — the Windows analog of the macOS adaptive
 * WatchLoop. Every OS call is a fake seam here, so the ladder ordering, the
 * visual budget/spacing, the sensitive suppression, and the timeout handoff are
 * all provable without a screen, a clock, a model, or Windows.
 */

// ---------------------------------------------------------------------------
// A fake set of seams that counts every call and lets a test script each one.
// ---------------------------------------------------------------------------

interface SeamCallCounts {
  isToolInstalled: number;
  readForegroundProcess: number;
  readForegroundBrowserHost: number;
  isAxElementPresent: number;
  captureScreenshotJpegBase64: number;
  evaluateVisualCheck: number;
}

interface FakeSeamsController {
  seams: WatchSeams;
  calls: SeamCallCounts;
  /** The `nowInSeconds` values at which each visual check actually fired. */
  secondsAtEachVisualCheck: number[];
  /** The tools `isToolInstalled` was asked about. */
  toolsAskedAbout: string[];
}

function makeFakeSeams(script: {
  toolInstalled?: (tool: string) => boolean;
  foregroundProcessName?: string | undefined;
  foregroundBrowserHost?: string | undefined;
  axElementPresent?: boolean;
  screenshot?: string | undefined;
  visualVerdict?: WatchVerdict | undefined;
  /** Seconds the clock advances on each poll's `waitForMilliseconds`. */
  secondsAdvancedPerPoll?: number;
} = {}): FakeSeamsController {
  const calls: SeamCallCounts = {
    isToolInstalled: 0,
    readForegroundProcess: 0,
    readForegroundBrowserHost: 0,
    isAxElementPresent: 0,
    captureScreenshotJpegBase64: 0,
    evaluateVisualCheck: 0,
  };
  const secondsAtEachVisualCheck: number[] = [];
  const toolsAskedAbout: string[] = [];
  let clockSeconds = 0;

  const seams: WatchSeams = {
    async isToolInstalled(tool: string): Promise<boolean> {
      calls.isToolInstalled += 1;
      toolsAskedAbout.push(tool);
      return script.toolInstalled?.(tool) ?? false;
    },
    async readForegroundProcess() {
      calls.readForegroundProcess += 1;
      return script.foregroundProcessName === undefined
        ? undefined
        : { pid: 1234, processName: script.foregroundProcessName };
    },
    async readForegroundBrowserHost() {
      calls.readForegroundBrowserHost += 1;
      return script.foregroundBrowserHost;
    },
    async isAxElementPresent() {
      calls.isAxElementPresent += 1;
      return script.axElementPresent ?? false;
    },
    async captureScreenshotJpegBase64() {
      calls.captureScreenshotJpegBase64 += 1;
      return script.screenshot ?? "ZmFrZS1qcGVn";
    },
    async evaluateVisualCheck() {
      calls.evaluateVisualCheck += 1;
      secondsAtEachVisualCheck.push(clockSeconds);
      return script.visualVerdict;
    },
    nowInSeconds() {
      return clockSeconds;
    },
    async waitForMilliseconds() {
      clockSeconds += script.secondsAdvancedPerPoll ?? 0;
    },
  };

  return { seams, calls, secondsAtEachVisualCheck, toolsAskedAbout };
}

function watchOf(expect: WatchExpectation[], sensitive = false): StepWatch {
  return { sensitive, expect };
}

// ---------------------------------------------------------------------------
// Cheapest-first ordering
// ---------------------------------------------------------------------------

describe("orderExpectationsCheapestFirst", () => {
  it("orders toolVersion → foregroundApp → urlHost → axElement → visual", () => {
    const authored: WatchExpectation[] = [
      { type: "visual", prompt: "looks done?" },
      { type: "axElement", roleLabel: "Finish" },
      { type: "urlHost", host: "publikhq.com" },
      { type: "foregroundApp", bundleId: "com.publikhq.publikclip" },
      { type: "toolVersion", tool: "git" },
    ];
    expect(orderExpectationsCheapestFirst(authored).map((e) => e.type)).toEqual([
      "toolVersion",
      "foregroundApp",
      "urlHost",
      "axElement",
      "visual",
    ]);
  });

  it("is stable for two expectations of the same cost", () => {
    const authored: WatchExpectation[] = [
      { type: "toolVersion", tool: "git" },
      { type: "toolVersion", tool: "node" },
    ];
    expect(orderExpectationsCheapestFirst(authored).map((e) => (e as { tool: string }).tool)).toEqual([
      "git",
      "node",
    ]);
  });

  it("does not mutate its input", () => {
    const authored: WatchExpectation[] = [
      { type: "visual", prompt: "?" },
      { type: "toolVersion", tool: "git" },
    ];
    orderExpectationsCheapestFirst(authored);
    expect(authored[0]!.type).toBe("visual");
  });
});

// ---------------------------------------------------------------------------
// Cheapest-first short-circuit + each side signal verifying
// ---------------------------------------------------------------------------

describe("the executor's cheapest-first evaluation", () => {
  it("stops at the first (cheapest) expectation that verifies and never reaches the costlier ones", async () => {
    // Authored with visual FIRST, but toolVersion is cheaper and verifies, so
    // the screenshot/model rung is never touched.
    const fake = makeFakeSeams({ toolInstalled: () => true });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([
        { type: "visual", prompt: "?" },
        { type: "toolVersion", tool: "git" },
      ]),
    );

    expect(outcome).toEqual({ kind: "verified", verifiedBy: "toolVersion" });
    expect(fake.calls.captureScreenshotJpegBase64).toBe(0);
    expect(fake.calls.evaluateVisualCheck).toBe(0);
  });

  it("verifies a foregroundApp by mapping the guide identity to a Windows exe", async () => {
    const fake = makeFakeSeams({ foregroundProcessName: "publikclip-app.exe" });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "foregroundApp", bundleId: "com.publikhq.publikclip" }]),
    );
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "foregroundApp" });
  });

  it("verifies a urlHost when the frontmost tab is a subdomain of the expected host", async () => {
    const fake = makeFakeSeams({ foregroundBrowserHost: "console.anthropic.com" });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "urlHost", host: "anthropic.com" }]),
      { maximumPolls: 1 },
    );
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "urlHost" });
  });

  it("verifies an axElement when UIA reports it present", async () => {
    const fake = makeFakeSeams({ axElementPresent: true });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "axElement", roleLabel: "Finish setup" }]),
      { maximumPolls: 1 },
    );
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "axElement" });
  });

  it("never asks about a tool that is not on the allowlist", async () => {
    const fake = makeFakeSeams({ toolInstalled: () => true });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "evilprogram" }]),
      { maximumPolls: 1 },
    );
    expect(outcome.kind).toBe("timedOut");
    expect(fake.calls.isToolInstalled).toBe(0);
    expect(fake.toolsAskedAbout).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Visual budget + spacing
// ---------------------------------------------------------------------------

describe("the visual model budget", () => {
  it("never runs more than the per-step ceiling of visual checks", async () => {
    // Spacing always allows (clock jumps 100s per poll), the model always says
    // not-yet, and there are far more polls than the ceiling.
    const fake = makeFakeSeams({ visualVerdict: { kind: "notYet" }, secondsAdvancedPerPoll: 100 });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "looks done?" }]),
      { maximumPolls: 40 },
    );

    expect(outcome.kind).toBe("timedOut");
    expect(fake.calls.evaluateVisualCheck).toBe(MAXIMUM_VISUAL_CHECKS_PER_STEP);
  });

  it("keeps every pair of visual checks at least the minimum interval apart", async () => {
    // Each poll advances the clock 3s; spacing must hold checks ≥ 10s apart.
    const fake = makeFakeSeams({ visualVerdict: { kind: "notYet" }, secondsAdvancedPerPoll: 3 });
    const executor = new WatchStepExecutor(fake.seams);

    await executor.awaitStepCompletion(watchOf([{ type: "visual", prompt: "?" }]), {
      maximumPolls: 20,
    });

    const timestamps = fake.secondsAtEachVisualCheck;
    expect(timestamps.length).toBeGreaterThan(1);
    for (let i = 1; i < timestamps.length; i += 1) {
      expect(timestamps[i]! - timestamps[i - 1]!).toBeGreaterThanOrEqual(
        MINIMUM_SECONDS_BETWEEN_VISUAL_CHECKS,
      );
    }
  });

  it("verifies as soon as one visual check comes back completed", async () => {
    const fake = makeFakeSeams({ visualVerdict: { kind: "completed" }, secondsAdvancedPerPoll: 100 });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "?" }]),
      { maximumPolls: 5 },
    );
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "visual" });
    expect(fake.calls.evaluateVisualCheck).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Sensitive suppression
// ---------------------------------------------------------------------------

describe("a sensitive watch", () => {
  it("never captures a screenshot and never calls the model", async () => {
    const fake = makeFakeSeams({ visualVerdict: { kind: "completed" }, secondsAdvancedPerPoll: 100 });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "the key is pasted?" }], /* sensitive */ true),
      { maximumPolls: 5 },
    );

    // A sensitive step's only expectation is the forbidden one, so it cannot
    // verify from pixels — it times out rather than ever capturing.
    expect(outcome.kind).toBe("timedOut");
    expect(fake.calls.captureScreenshotJpegBase64).toBe(0);
    expect(fake.calls.evaluateVisualCheck).toBe(0);
  });

  it("still settles a sensitive step from a pixel-free side signal", async () => {
    const fake = makeFakeSeams({ foregroundProcessName: "publikclip-app.exe" });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf(
        [
          { type: "foregroundApp", bundleId: "com.publikhq.publikclip" },
          { type: "visual", prompt: "?" },
        ],
        true,
      ),
    );
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "foregroundApp" });
    expect(fake.calls.captureScreenshotJpegBase64).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Timeout
// ---------------------------------------------------------------------------

describe("the timeout", () => {
  it("times out when nothing verifies within the poll budget", async () => {
    const fake = makeFakeSeams({ toolInstalled: () => false });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }]),
      { maximumPolls: 3 },
    );
    expect(outcome).toEqual({ kind: "timedOut" });
  });

  it("carries the last stuck hint the model produced into the timeout", async () => {
    const fake = makeFakeSeams({
      visualVerdict: { kind: "userStuck", hint: "A dialog is blocking the window." },
      secondsAdvancedPerPoll: 100,
    });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "?" }]),
      { maximumPolls: 3 },
    );
    expect(outcome).toEqual({ kind: "timedOut", stuckHint: "A dialog is blocking the window." });
  });
});

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

describe("windowsExecutableForForegroundIdentity", () => {
  it("maps the reviewed catalog bundle id to its Windows exe", () => {
    expect(windowsExecutableForForegroundIdentity("com.publikhq.publikclip")).toBe("publikclip-app");
  });
  it("takes an identity that already names an exe", () => {
    expect(windowsExecutableForForegroundIdentity("SomeApp.exe")).toBe("someapp");
  });
  it("resolves a reviewed catalog slug to its exe", () => {
    expect(windowsExecutableForForegroundIdentity("publikclip")).toBe("publikclip-app");
  });
  it("returns undefined for an unknown identity", () => {
    expect(windowsExecutableForForegroundIdentity("com.example.unknown")).toBeUndefined();
    expect(windowsExecutableForForegroundIdentity("")).toBeUndefined();
  });
});

describe("foregroundProcessSatisfiesIdentity", () => {
  it("matches case-insensitively and tolerates a missing .exe", () => {
    expect(foregroundProcessSatisfiesIdentity("publikclip-app", "com.publikhq.publikclip")).toBe(true);
    expect(foregroundProcessSatisfiesIdentity("PUBLIKCLIP-APP.EXE", "com.publikhq.publikclip")).toBe(true);
  });
  it("does not match a different process", () => {
    expect(foregroundProcessSatisfiesIdentity("explorer.exe", "com.publikhq.publikclip")).toBe(false);
  });
});

describe("hostMatchesExpectedHost", () => {
  it("matches the host itself and any subdomain, but not a lookalike", () => {
    expect(hostMatchesExpectedHost("anthropic.com", "anthropic.com")).toBe(true);
    expect(hostMatchesExpectedHost("console.anthropic.com", "anthropic.com")).toBe(true);
    expect(hostMatchesExpectedHost("evilanthropic.com", "anthropic.com")).toBe(false);
    expect(hostMatchesExpectedHost(undefined, "anthropic.com")).toBe(false);
  });
});

describe("hostFromAddressBarText", () => {
  it("reads the host out of a full URL, a bare host, and a host with a path", () => {
    expect(hostFromAddressBarText("https://console.anthropic.com/settings/keys")).toBe(
      "console.anthropic.com",
    );
    expect(hostFromAddressBarText("publikhq.com")).toBe("publikhq.com");
    expect(hostFromAddressBarText("github.com/Blueturboguy07/publik")).toBe("github.com");
    expect(hostFromAddressBarText("   ")).toBeUndefined();
  });
});

describe("parseActiveBrowserUrlOutput", () => {
  it("reads the last URL| line into a host and ignores noise", () => {
    expect(parseActiveBrowserUrlOutput("noise\nURL|https://publikhq.com/x\n")).toBe("publikhq.com");
    expect(parseActiveBrowserUrlOutput("nothing here")).toBeUndefined();
  });
});

describe("parseAxElementPresenceOutput", () => {
  it("is true only when the AX|1 marker is present", () => {
    expect(parseAxElementPresenceOutput("AX|1")).toBe(true);
    expect(parseAxElementPresenceOutput("some\nAX|1\nmore")).toBe(true);
    expect(parseAxElementPresenceOutput("nope")).toBe(false);
  });
});

describe("the PowerShell command builders", () => {
  it("read the address bar over UI Automation from the foreground window", () => {
    const command = buildActiveBrowserUrlCommand();
    expect(command).toContain("GetForegroundWindow");
    expect(command).toContain("UIAutomationClient");
    expect(command).toContain("URL|");
  });

  it("escape a role label so it can never become code", () => {
    const command = buildAxElementQueryCommand("Finish'; Remove-Item C:\\");
    // The single quote is doubled (PowerShell single-quoted-string escaping), so
    // the label stays a string literal rather than closing the quote.
    expect(command).toContain("Finish''; Remove-Item");
    expect(command).toContain("AX|1");
  });
});

describe("verdictFromVisualModelAnswer", () => {
  it("reads COMPLETED / NOT_YET / STUCK and treats anything else as learned-nothing", () => {
    expect(verdictFromVisualModelAnswer("COMPLETED", [])).toEqual({ kind: "completed" });
    expect(verdictFromVisualModelAnswer("NOT_YET", [])).toEqual({ kind: "notYet" });
    expect(verdictFromVisualModelAnswer("NOT YET, still building", [])).toEqual({ kind: "notYet" });
    expect(verdictFromVisualModelAnswer("STUCK: an error dialog is up", [])).toEqual({
      kind: "userStuck",
      hint: "an error dialog is up",
    });
    expect(verdictFromVisualModelAnswer("banana", [])).toBeUndefined();
  });

  it("falls back to the author's first hint when STUCK carries none", () => {
    expect(verdictFromVisualModelAnswer("STUCK:", ["try re-running it"])).toEqual({
      kind: "userStuck",
      hint: "try re-running it",
    });
    expect(verdictFromVisualModelAnswer("STUCK:", [])).toEqual({ kind: "notYet" });
  });
});

describe("the visual prompt shape", () => {
  it("asks for exactly one of the three answers and names the step and command", () => {
    const systemPrompt = visualCheckSystemPrompt(["reopen the terminal"]);
    expect(systemPrompt).toContain("COMPLETED");
    expect(systemPrompt).toContain("NOT_YET");
    expect(systemPrompt).toContain("STUCK:");
    expect(systemPrompt).toContain("reopen the terminal");

    const userPrompt = visualCheckUserPrompt({
      stepTitle: "Start the app",
      visualPrompt: "is the window open?",
      context: { frontmostApplicationName: "publikclip", commandTheStepAsksFor: "pnpm dev" },
    });
    expect(userPrompt).toContain('"Start the app"');
    expect(userPrompt).toContain("pnpm dev");
    expect(userPrompt).toContain("is the window open?");
  });
});
