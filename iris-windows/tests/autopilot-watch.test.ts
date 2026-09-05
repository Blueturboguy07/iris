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
  MINIMUM_HAMMING_DISTANCE_THAT_COUNTS,
  hammingDistanceBetweenFingerprints,
  defaultWatchSeams,
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
  captureScreenFingerprint: number;
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
  /** A per-tool answer, consulted when `toolInstalled` is not given — lets a
   *  test make git present but node absent for the AND-semantics cases. */
  toolInstalledByName?: Record<string, boolean>;
  foregroundProcessName?: string | undefined;
  foregroundBrowserHost?: string | undefined;
  axElementPresent?: boolean;
  screenshot?: string | undefined;
  visualVerdict?: WatchVerdict | undefined;
  /** Seconds the clock advances on each poll's `waitForMilliseconds`. */
  secondsAdvancedPerPoll?: number;
  /** The screen fingerprints handed back per `captureScreenFingerprint` call,
   *  in order; the last value repeats. Undefined entries mean "capture not
   *  wired". Absent (the default) leaves the fingerprint seam unwired entirely,
   *  which is the shipped production default (side signals read every poll). */
  fingerprints?: (bigint | undefined)[];
} = {}): FakeSeamsController {
  const calls: SeamCallCounts = {
    isToolInstalled: 0,
    readForegroundProcess: 0,
    readForegroundBrowserHost: 0,
    isAxElementPresent: 0,
    captureScreenshotJpegBase64: 0,
    evaluateVisualCheck: 0,
    captureScreenFingerprint: 0,
  };
  const secondsAtEachVisualCheck: number[] = [];
  const toolsAskedAbout: string[] = [];
  let clockSeconds = 0;

  const seams: WatchSeams = {
    async isToolInstalled(tool: string): Promise<boolean> {
      calls.isToolInstalled += 1;
      toolsAskedAbout.push(tool);
      if (script.toolInstalled !== undefined) return script.toolInstalled(tool);
      return script.toolInstalledByName?.[tool] ?? false;
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
    async captureScreenFingerprint() {
      const index = calls.captureScreenFingerprint;
      calls.captureScreenFingerprint += 1;
      if (script.fingerprints === undefined) return undefined; // unwired
      return script.fingerprints[Math.min(index, script.fingerprints.length - 1)];
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
// AND semantics across a step's side signals (finding 1)
// ---------------------------------------------------------------------------

describe("multiple side signals verify with AND, not OR", () => {
  it("does NOT settle a two-tool check when only the first tool is present", async () => {
    // The `check-tools` step shared across the Windows guides:
    // expect [toolVersion git, toolVersion node]. git is installed, node is not.
    // The step must keep waiting — verifying here would march into an npm step
    // with node still missing.
    const fake = makeFakeSeams({ toolInstalledByName: { git: true, node: false } });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([
        { type: "toolVersion", tool: "git" },
        { type: "toolVersion", tool: "node" },
      ]),
      { maximumPolls: 3 },
    );

    expect(outcome.kind).toBe("timedOut");
  });

  it("settles the two-tool check only once BOTH tools are present", async () => {
    const fake = makeFakeSeams({ toolInstalledByName: { git: true, node: true } });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([
        { type: "toolVersion", tool: "git" },
        { type: "toolVersion", tool: "node" },
      ]),
      { maximumPolls: 3 },
    );

    // Verified, and named by the strongest (last, most-expensive) side signal —
    // here both are toolVersion, so node (authored second).
    expect(outcome).toEqual({ kind: "verified", verifiedBy: "toolVersion" });
  });

  it("short-circuits the AND on the first unsatisfied signal, never spawning the costlier probe", async () => {
    // toolVersion (git) is absent, so the costlier urlHost probe below it must
    // never be read: one failed cheap check already means "not all satisfied".
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      foregroundBrowserHost: "publikhq.com",
    });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([
        { type: "toolVersion", tool: "git" },
        { type: "urlHost", host: "publikhq.com" },
      ]),
      { maximumPolls: 2 },
    );

    expect(outcome.kind).toBe("timedOut");
    expect(fake.calls.readForegroundBrowserHost).toBe(0);
  });

  it("falls to the visual rung when a side signal is unsatisfied but a visual is declared", async () => {
    // node missing (side signal not all satisfied) AND a visual is declared:
    // macOS `localSignalsCannotTell` → consult the model, which says completed.
    const fake = makeFakeSeams({
      toolInstalledByName: { node: false },
      visualVerdict: { kind: "completed" },
      secondsAdvancedPerPoll: 100,
    });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([
        { type: "toolVersion", tool: "node" },
        { type: "visual", prompt: "does it look done?" },
      ]),
      { maximumPolls: 3 },
    );

    expect(outcome).toEqual({ kind: "verified", verifiedBy: "visual" });
    expect(fake.calls.evaluateVisualCheck).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// The perceptual-diff rung — "free unless the screen changed" (finding 4)
// ---------------------------------------------------------------------------

describe("the screen-diff gate", () => {
  it("reads the side signals every poll when no fingerprint seam is wired (the shipped default)", async () => {
    // fingerprints absent → capture returns undefined → the gate is inert and
    // every poll reads the (never-satisfied) side signal.
    const fake = makeFakeSeams({ toolInstalledByName: { git: false } });
    const executor = new WatchStepExecutor(fake.seams);

    await executor.awaitStepCompletion(watchOf([{ type: "toolVersion", tool: "git" }]), {
      maximumPolls: 4,
    });

    // Four polls, four side-signal reads — nothing gated them.
    expect(fake.calls.isToolInstalled).toBe(4);
  });

  it("skips the side-signal read on an unchanged screen once a fingerprint seam is wired", async () => {
    // A steady screen (same fingerprint every capture): the baseline poll reads
    // the side signal, every unchanged poll after it reads nothing.
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      fingerprints: [0n], // one value, repeats — the screen never changes
    });
    const executor = new WatchStepExecutor(fake.seams);

    await executor.awaitStepCompletion(watchOf([{ type: "toolVersion", tool: "git" }]), {
      maximumPolls: 5,
    });

    // Only the baseline frame read the side signal; the four unchanged polls were
    // free. This is the rung that makes the common case cost nothing.
    expect(fake.calls.isToolInstalled).toBe(1);
    expect(fake.calls.captureScreenFingerprint).toBeGreaterThan(1);
  });

  it("reads the side signals again on a meaningfully-changed screen", async () => {
    // Baseline 0n, then a value far enough away to clear the Hamming threshold on
    // the second poll, then steady — so exactly two side-signal reads happen.
    const changed = (1n << BigInt(MINIMUM_HAMMING_DISTANCE_THAT_COUNTS)) - 1n; // >= threshold bits set
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      fingerprints: [0n, changed, changed, changed],
    });
    const executor = new WatchStepExecutor(fake.seams);

    await executor.awaitStepCompletion(watchOf([{ type: "toolVersion", tool: "git" }]), {
      maximumPolls: 5,
    });

    // Baseline (poll 0) + the changed frame (poll 1) both read; the steady polls
    // after that do not.
    expect(fake.calls.isToolInstalled).toBe(2);
  });

  it("never fingerprints a sensitive step", async () => {
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      fingerprints: [0n],
    });
    const executor = new WatchStepExecutor(fake.seams);

    await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }], /* sensitive */ true),
      { maximumPolls: 3 },
    );

    expect(fake.calls.captureScreenFingerprint).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Progress-aware timeout (finding 3)
// ---------------------------------------------------------------------------

describe("the progress-aware timeout", () => {
  it("keeps watching a still-changing screen well past the no-progress ceiling", async () => {
    // The screen changes every poll (each fingerprint clears the threshold vs the
    // last), so a slow-but-live step is never handed back at the ceiling. With a
    // no-progress ceiling of 3 and 12 always-changing polls, it does NOT time out
    // early — it runs to the poll budget the test caps it at.
    const everChanging: bigint[] = [];
    for (let i = 0; i < 12; i += 1) {
      // Alternate between two distant fingerprints so consecutive frames always
      // differ by more than the threshold.
      everChanging.push(i % 2 === 0 ? 0n : 0xffffffffffffffffn);
    }
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      fingerprints: everChanging,
    });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }]),
      { maximumPolls: 3 },
    );

    // It polled far more than the no-progress ceiling of 3 because every change
    // reset the counter — evidence the step is still progressing.
    expect(outcome.kind).toBe("timedOut");
    expect(fake.calls.captureScreenFingerprint).toBeGreaterThan(3);
  });

  it("times out at the no-progress ceiling when the screen sits still", async () => {
    const fake = makeFakeSeams({
      toolInstalledByName: { git: false },
      fingerprints: [7n], // steady
    });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }]),
      { maximumPolls: 3 },
    );

    expect(outcome.kind).toBe("timedOut");
    // Baseline + 2 unchanged polls = 3 no-progress polls, then it gives up.
    expect(fake.calls.captureScreenFingerprint).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// Abort cancels an in-flight watch promptly (finding 2)
// ---------------------------------------------------------------------------

describe("shouldAbort", () => {
  it("returns aborted promptly and stops polling when the escape hatch fires", async () => {
    let aborted = false;
    const fake = makeFakeSeams({ toolInstalledByName: { git: false } });
    const executor = new WatchStepExecutor(fake.seams);

    // Abort after the first poll's side-signal read.
    const originalIsToolInstalled = fake.seams.isToolInstalled.bind(fake.seams);
    (fake.seams as { isToolInstalled: WatchSeams["isToolInstalled"] }).isToolInstalled = async (
      tool: string,
    ) => {
      aborted = true;
      return originalIsToolInstalled(tool);
    };

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }]),
      { maximumPolls: 90, shouldAbort: () => aborted },
    );

    expect(outcome).toEqual({ kind: "aborted" });
    // It did NOT poll its whole budget after the abort — one side-signal read,
    // then it noticed the abort and returned.
    expect(fake.calls.isToolInstalled).toBe(1);
  });

  it("returns aborted before doing any work when already aborted", async () => {
    const fake = makeFakeSeams({ toolInstalledByName: { git: true } });
    const executor = new WatchStepExecutor(fake.seams);

    const outcome = await executor.awaitStepCompletion(
      watchOf([{ type: "toolVersion", tool: "git" }]),
      { maximumPolls: 5, shouldAbort: () => true },
    );

    expect(outcome).toEqual({ kind: "aborted" });
    expect(fake.calls.isToolInstalled).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// The Hamming helper + the production seam plumbing (findings 4 and 7)
// ---------------------------------------------------------------------------

describe("hammingDistanceBetweenFingerprints", () => {
  it("counts the differing bits of two 64-bit hashes", () => {
    expect(hammingDistanceBetweenFingerprints(0n, 0n)).toBe(0);
    expect(hammingDistanceBetweenFingerprints(0n, 1n)).toBe(1);
    expect(hammingDistanceBetweenFingerprints(0b1010n, 0b0101n)).toBe(4);
    expect(hammingDistanceBetweenFingerprints(0n, 0xffffffffffffffffn)).toBe(64);
  });
});

describe("defaultWatchSeams", () => {
  it("wires the toolVersion rung through an injected isToolInstalled instead of the false default", async () => {
    // The production wiring (main/index.ts) hands in a real checker; without an
    // override the seam answers false forever, which is the bug finding 7 fixes.
    const asked: string[] = [];
    const wired = defaultWatchSeams({
      isToolInstalled: async (tool) => {
        asked.push(tool);
        return tool === "cargo";
      },
    });
    expect(await wired.isToolInstalled("cargo")).toBe(true);
    expect(await wired.isToolInstalled("git")).toBe(false);
    expect(asked).toEqual(["cargo", "git"]);

    // The unwired default is false (not "wired"): a fingerprint capture and a
    // tool check both answer the inert value until a host supplies them.
    const bare = defaultWatchSeams();
    expect(await bare.isToolInstalled("cargo")).toBe(false);
    expect(await bare.captureScreenFingerprint()).toBeUndefined();
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

describe("a watch that can never verify hands back at once (finding: no ~3-minute silent stall)", () => {
  /** Minimal seams with call counters, and a fixed screenshot value (undefined =
   *  the capture seam is not wired). The fingerprint seam is always unwired, the
   *  production default. */
  function countingSeams(screenshot: string | undefined): {
    seams: WatchSeams;
    counts: () => { waits: number; captures: number };
  } {
    let waits = 0;
    let captures = 0;
    const seams: WatchSeams = {
      async isToolInstalled() {
        return false;
      },
      async readForegroundProcess() {
        return undefined;
      },
      async readForegroundBrowserHost() {
        return undefined;
      },
      async isAxElementPresent() {
        return false;
      },
      async captureScreenshotJpegBase64() {
        captures += 1;
        return screenshot;
      },
      async captureScreenFingerprint() {
        return undefined;
      },
      async evaluateVisualCheck() {
        return undefined; // the model never confirms
      },
      nowInSeconds() {
        return 0;
      },
      async waitForMilliseconds() {
        waits += 1;
      },
    };
    return { seams, counts: () => ({ waits, captures }) };
  }

  it("hands a sensitive visual-only step back immediately, never capturing and never polling", async () => {
    const { seams, counts } = countingSeams("a-frame");
    const outcome = await new WatchStepExecutor(seams).awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "the key is pasted?" }], /* sensitive */ true),
      { maximumPolls: 90 },
    );
    expect(outcome.kind).toBe("timedOut");
    expect(counts().captures).toBe(0); // a sensitive step is never looked at
    expect(counts().waits).toBe(0); // and does not burn the 90-poll budget
  });

  it("hands a non-sensitive visual-only step back once it learns the capture seam is unwired", async () => {
    const { seams, counts } = countingSeams(undefined); // capture not wired
    const outcome = await new WatchStepExecutor(seams).awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "looks done?" }]),
      { maximumPolls: 90 },
    );
    expect(outcome.kind).toBe("timedOut");
    expect(counts().captures).toBe(1); // it tried once, learned the rung is dead
    expect(counts().waits).toBe(0); // then gave up instead of polling ~3 minutes
  });

  it("still polls a visual-only step to its budget when capture IS wired (unchanged)", async () => {
    const { seams, counts } = countingSeams("a-frame"); // wired; model keeps saying not-yet
    const outcome = await new WatchStepExecutor(seams).awaitStepCompletion(
      watchOf([{ type: "visual", prompt: "looks done?" }]),
      { maximumPolls: 3 },
    );
    expect(outcome.kind).toBe("timedOut");
    expect(counts().waits).toBeGreaterThan(0); // it genuinely watched, no fast-fail
  });
});
