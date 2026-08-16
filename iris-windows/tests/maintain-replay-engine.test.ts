import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { FetchLike } from "../src/services/claude";
import type { BreakAppStack } from "../src/services/maintain/break-signature";
import {
  InMemoryInstallProvenancePersistence,
  InstallProvenanceStore,
} from "../src/services/maintain/install-provenance";
import { MockMaintainShellRunner } from "../src/services/maintain/maintain-shell-runner";
import { InMemoryPatchQueueStorage, PatchQueue } from "../src/services/maintain/patch-queue";
import { MaintainPoolClient, type MaintainPoolFetchLike, type PooledFixRecipe } from "../src/services/maintain/pool-client";
import type { VerificationCommands } from "../src/services/maintain/verification-harness";
import {
  AnthropicPatchAdapter,
  RecipeReplayEngine,
  extractRecipeGuidanceSteps,
  recipeApplicabilityMatches,
  type MaintainFixAdapting,
  type MaintainFixAdaptation,
} from "../src/services/maintain/replay-engine";

/**
 * `replay-engine.ts` — Tier A (replay a pooled recipe verbatim) and Tier B
 * (one forced BYO call to re-anchor a stale diff). Three layers of tests:
 *
 *   - `recipeApplicabilityMatches` / `extractRecipeGuidanceSteps`: pure
 *     functions, tested directly against the fail-closed rules the porting
 *     spec documents.
 *   - `AnthropicPatchAdapter`: network-mocked, same key-isolation stance as
 *     `maintain-model-provider.test.ts`.
 *   - `RecipeReplayEngine.replay`: the shared apply-verify-commit spine,
 *     driven against `MockMaintainShellRunner` and real (in-memory-backed)
 *     collaborator classes — `InstallProvenanceStore`, `PatchQueue`, and
 *     `MaintainPoolClient` are concrete classes with private fields, so a
 *     duck-typed fake cannot stand in for them; each test constructs the
 *     real thing over an in-memory store or a scripted fetch instead.
 *
 *     One wrinkle the mock cannot paper over: `applyVerifyAndCommit` writes
 *     the recipe's patch text to a REAL file under `clonePath` with plain
 *     `node:fs` (`.iris-replay-<recipeId>.patch`) before ever touching the
 *     injected shell runner, and removes it again in a `finally`. Only the
 *     `git`/build/test *commands* are faked — the patch file itself is real
 *     I/O. So `clonePath` cannot be an opaque placeholder string the way it
 *     can in, say, `maintain-patch-queue.test.ts`'s in-memory-only tests: it
 *     has to be a real, writable directory, or the write throws and every
 *     apply attempt reports `patchDidNotApply` before a single shell command
 *     runs. `engineFor` below therefore roots every engine it builds at a
 *     real `mkdtempSync` directory, the same pattern
 *     `maintain-verification-harness.test.ts`'s real-repo section uses.
 */

// ---------------------------------------------------------------------------
// recipeApplicabilityMatches
// ---------------------------------------------------------------------------

describe("recipeApplicabilityMatches — fail-closed OSV-shaped ranges", () => {
  it("matches everything when applicability is absent", () => {
    expect(recipeApplicabilityMatches({ applicability: null, appVersion: "1.0.0", architecture: "x64" })).toBe(true);
    expect(
      recipeApplicabilityMatches({ applicability: undefined, appVersion: null, architecture: "x64" })
    ).toBe(true);
  });

  it("refuses rather than guesses when applicability is not readable JSON", () => {
    expect(recipeApplicabilityMatches({ applicability: "not-an-object", appVersion: "1.0.0", architecture: "x64" })).toBe(
      false
    );
    expect(recipeApplicabilityMatches({ applicability: ["arm64"], appVersion: "1.0.0", architecture: "x64" })).toBe(
      false
    );
  });

  it.each([
    [{ arch: ["arm64", "x64"] }, "x64", true],
    [{ arch: ["arm64"] }, "x64", false],
    [{ arch: [] }, "x64", true], // an empty list constrains nothing
    [{ arch: "x64" }, "x64", false], // unreadable (not an array) -> fail closed
  ])("arch constraint %j against %s -> %s", (applicability, architecture, expected) => {
    expect(recipeApplicabilityMatches({ applicability, appVersion: "1.0.0", architecture })).toBe(expected);
  });

  it("refuses when app_version is constrained but the installed version is unknown", () => {
    expect(
      recipeApplicabilityMatches({
        applicability: { app_version: [{ introduced: "1.0.0" }] },
        appVersion: null,
        architecture: "x64",
      })
    ).toBe(false);
  });

  it("refuses when the version ranges are not readable", () => {
    expect(
      recipeApplicabilityMatches({
        applicability: { app_version: "1.0.0" },
        appVersion: "1.0.0",
        architecture: "x64",
      })
    ).toBe(false);
  });

  it.each([
    ["1.3.9", true], // inside [1.0.0, 1.4.0)
    ["0.9.0", false], // before introduced
    ["1.4.0", false], // at fixed (fixed is exclusive)
    ["2.0.0", false], // past fixed
  ])("app_version %s against [1.0.0, 1.4.0) -> %s", (appVersion, expected) => {
    expect(
      recipeApplicabilityMatches({
        applicability: { app_version: [{ introduced: "1.0.0", fixed: "1.4.0" }] },
        appVersion,
        architecture: "x64",
      })
    ).toBe(expected);
  });

  it("an open-ended range (introduced only) matches everything at or after it", () => {
    expect(
      recipeApplicabilityMatches({
        applicability: { app_version: [{ introduced: "2.0.0" }] },
        appVersion: "9.9.9",
        architecture: "x64",
      })
    ).toBe(true);
  });

  it("requires every constrained dimension to pass — arch alone cannot rescue a version miss", () => {
    expect(
      recipeApplicabilityMatches({
        applicability: { arch: ["x64"], app_version: [{ fixed: "1.0.0" }] },
        appVersion: "1.0.0",
        architecture: "x64",
      })
    ).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// extractRecipeGuidanceSteps
// ---------------------------------------------------------------------------

describe("extractRecipeGuidanceSteps", () => {
  it("renders title+command, title-only, and command-only lines", () => {
    const steps = extractRecipeGuidanceSteps({
      steps: [
        { title: "Clear the cache", command: "rm -rf .cache" },
        { title: "Restart the app" },
        { command: "npm install" },
        { neitherTitleNorCommand: true },
        "not even an object",
      ],
    });
    expect(steps).toEqual([
      "Clear the cache: `rm -rf .cache`",
      "Restart the app",
      "Run `npm install`",
    ]);
  });

  it("falls back to one honest line for unreadable or empty recipe JSON", () => {
    const fallback = ["A fix is known for this break, but its steps could not be read — check the app's page on publik."];
    expect(extractRecipeGuidanceSteps(null)).toEqual(fallback);
    expect(extractRecipeGuidanceSteps("a string, not an object")).toEqual(fallback);
    expect(extractRecipeGuidanceSteps({ steps: [] })).toEqual(fallback);
    expect(extractRecipeGuidanceSteps({ noStepsKey: true })).toEqual(fallback);
  });
});

// ---------------------------------------------------------------------------
// AnthropicPatchAdapter — Tier B's forced tool call
// ---------------------------------------------------------------------------

interface RecordedCall {
  readonly url: string;
  readonly headers: Record<string, string>;
  readonly body: string;
}

function recordingFetch(response: { ok?: boolean; status?: number; body?: string }): {
  fetchImplementation: FetchLike;
  calls: RecordedCall[];
} {
  const calls: RecordedCall[] = [];
  const fetchImplementation: FetchLike = async (url, init) => {
    calls.push({ url, headers: init.headers, body: init.body });
    return {
      ok: response.ok ?? true,
      status: response.status ?? 200,
      text: async () => response.body ?? "{}",
      headers: { get: () => null },
    };
  };
  return { fetchImplementation, calls };
}

const AN_ADAPT_REQUEST = {
  diagnosis: "the config key was renamed",
  stalePatch: "--- a/config.json\n+++ b/config.json\n@@ -1 +1 @@\n-old\n+new\n",
  localFileExcerpts: "=== config.json ===\ncurrent contents",
  appSlug: "cue",
};

describe("AnthropicPatchAdapter", () => {
  it("declines with noBringYourOwnKeyAvailable, calling fetch zero times, when there is no key", async () => {
    const { fetchImplementation, calls } = recordingFetch({});
    const adapter = new AnthropicPatchAdapter(() => null, fetchImplementation);
    expect(await adapter.adaptPatch(AN_ADAPT_REQUEST)).toEqual({ type: "noBringYourOwnKeyAvailable" });
    expect(calls).toHaveLength(0);
  });

  it("NEVER reaches a publik host, and returns the adapted diff on a valid forced tool call", async () => {
    const adaptedDiff = "--- a/config.json\n+++ b/config.json\n@@ -1 +1 @@\n-old\n+renamed\n";
    const { fetchImplementation, calls } = recordingFetch({
      body: JSON.stringify({
        content: [{ type: "tool_use", name: "adapt_patch", input: { unified_diff: adaptedDiff } }],
      }),
    });
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", fetchImplementation);
    const result = await adapter.adaptPatch(AN_ADAPT_REQUEST);

    expect(result).toEqual({ type: "adaptedPatch", unifiedDiff: adaptedDiff });
    expect(calls).toHaveLength(1);
    expect(new URL(calls[0].url).hostname).toBe("api.anthropic.com");
    expect(calls[0].headers["x-api-key"]).toBe("sk-ant-key");
    expect(JSON.stringify(calls[0])).not.toContain("publikhq.com");

    const sentBody = JSON.parse(calls[0].body);
    expect(sentBody.tool_choice).toEqual({ type: "tool", name: "adapt_patch" });
    expect(sentBody.messages[0].content).toContain(AN_ADAPT_REQUEST.diagnosis);
  });

  it("honors an explicit cannot_adapt decline as the reason, not as a diff", async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({
        content: [
          { type: "tool_use", name: "adapt_patch", input: { cannot_adapt: "the file was deleted upstream" } },
        ],
      }),
    });
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", fetchImplementation);
    expect(await adapter.adaptPatch(AN_ADAPT_REQUEST)).toEqual({
      type: "modelCouldNotAdapt",
      reason: "the file was deleted upstream",
    });
  });

  it("treats a response with no adapt_patch tool_use block as a decline", async () => {
    const { fetchImplementation } = recordingFetch({ body: JSON.stringify({ content: [{ type: "text", text: "hi" }] }) });
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", fetchImplementation);
    const result = await adapter.adaptPatch(AN_ADAPT_REQUEST);
    expect(result).toEqual({ type: "modelCouldNotAdapt", reason: "no adapt_patch call in the response" });
  });

  it("refuses a diff missing the --- / +++ markers rather than trusting it blindly", async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({
        content: [{ type: "tool_use", name: "adapt_patch", input: { unified_diff: "not a real diff" } }],
      }),
    });
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", fetchImplementation);
    const result = await adapter.adaptPatch(AN_ADAPT_REQUEST);
    expect(result).toEqual({ type: "modelCouldNotAdapt", reason: "response carried no usable diff" });
  });

  it("wraps a non-2xx response into modelCouldNotAdapt with the status code", async () => {
    const { fetchImplementation } = recordingFetch({ ok: false, status: 529, body: "{}" });
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", fetchImplementation);
    expect(await adapter.adaptPatch(AN_ADAPT_REQUEST)).toEqual({
      type: "modelCouldNotAdapt",
      reason: "HTTP 529",
    });
  });

  it("wraps a thrown network error into modelCouldNotAdapt", async () => {
    const throwingFetchImplementation: FetchLike = async () => {
      throw new Error("connection reset");
    };
    const adapter = new AnthropicPatchAdapter(() => "sk-ant-key", throwingFetchImplementation);
    expect(await adapter.adaptPatch(AN_ADAPT_REQUEST)).toEqual({
      type: "modelCouldNotAdapt",
      reason: "connection reset",
    });
  });
});

// ---------------------------------------------------------------------------
// RecipeReplayEngine — the shared apply-verify-commit spine
// ---------------------------------------------------------------------------

function aRecipe(overrides: Partial<PooledFixRecipe> = {}): PooledFixRecipe {
  return {
    id: "recipe-1",
    breakId: "break-1",
    appSlug: "cue",
    recipeType: "patch_pr",
    modelTier: "tierA",
    recipe: { steps: [] },
    status: "active",
    signatureId: "abcdef0123456789abcdef0123456789",
    diagnosis: "the config key was renamed",
    patchSpecific: "--- a/config.json\n+++ b/config.json\n@@ -1 +1 @@\n-old\n+new\n",
    patchBaseSha: null,
    patchGeneral: null,
    patchFormat: null,
    applicability: null,
    parentRecipeId: null,
    reviewStatus: "approved",
    verifiedFixes: 3,
    cleanApplies: 5,
    distinctInstallsAttempted: 5,
    score: 1,
    ...overrides,
  };
}

function poolClientRecordingOutcomes(): { poolClient: MaintainPoolClient; outcomeCalls: Array<{ succeeded: boolean }> } {
  const outcomeCalls: Array<{ succeeded: boolean }> = [];
  const fetchImplementation: MaintainPoolFetchLike = async (url, init) => {
    if (url.includes("/outcome")) {
      outcomeCalls.push(JSON.parse(init.body ?? "{}"));
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ status: "recorded" }) };
  };
  return { poolClient: new MaintainPoolClient({ fetchImplementation }), outcomeCalls };
}

const NO_BUILD_OR_TEST: VerificationCommands = {};
const AN_APP_STACK: BreakAppStack = "other";

// `applyVerifyAndCommit` writes the patch file for real (see the file header
// above) — every test in the `RecipeReplayEngine` sections below gets a real,
// writable scratch directory to root its engine at, torn down afterward, the
// same `mkdtempSync`/`rmSync` pattern `maintain-verification-harness.test.ts`
// uses for its real-git-repo section.
let realClonePath: string;

beforeEach(() => {
  realClonePath = fs.mkdtempSync(path.join(os.tmpdir(), "iris-maintain-replay-"));
});

afterEach(() => {
  fs.rmSync(realClonePath, { recursive: true, force: true });
});

function engineFor(options: {
  runner: MockMaintainShellRunner;
  poolClient: MaintainPoolClient;
  clonePath?: string;
  verificationCommandsForStack?: (appStack: BreakAppStack, repoRootPath: string) => VerificationCommands;
  fixAdapter?: MaintainFixAdapting;
  createShellRunner?: (repoRootPath: string) => MockMaintainShellRunner | undefined;
}): { engine: RecipeReplayEngine; provenanceStore: InstallProvenanceStore; patchQueue: PatchQueue } {
  const clonePath = options.clonePath ?? realClonePath;
  const provenanceStore = new InstallProvenanceStore({
    persistence: new InMemoryInstallProvenancePersistence(),
    checkGitDirectoryExists: () => true,
  });
  provenanceStore.recordGuideSourceClone({
    appSlug: "cue",
    clonePath,
    pinnedCommit: "deadbeef",
    canonicalRepo: "publikhq/cue",
  });
  const patchQueue = new PatchQueue(new InMemoryPatchQueueStorage());

  const engine = new RecipeReplayEngine({
    provenanceStore,
    poolClient: options.poolClient,
    getCurrentInstallId: () => "install-abc-123",
    patchQueue,
    createShellRunner: options.createShellRunner ?? (() => options.runner),
    verificationCommandsForStack: options.verificationCommandsForStack ?? (() => NO_BUILD_OR_TEST),
    fixAdapter: options.fixAdapter,
  });
  return { engine, provenanceStore, patchQueue };
}

describe("RecipeReplayEngine.replay — early exits", () => {
  it("refuses a recipe outside its applicability range without touching the shell", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient } = poolClientRecordingOutcomes();
    const { engine } = engineFor({ runner, poolClient });
    const recipe = aRecipe({ applicability: { arch: ["arm64"] } });

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "outsideApplicabilityRange" });
    expect(runner.commandsRun).toHaveLength(0);
  });

  it("surfaces a non-patch recipe as guidance and runs nothing", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient } = poolClientRecordingOutcomes();
    const { engine } = engineFor({ runner, poolClient });
    const recipe = aRecipe({
      recipeType: "workaround",
      recipe: { steps: [{ title: "Clear the cache", command: "rm -rf .cache" }] },
    });

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "guidanceToShow", steps: ["Clear the cache: `rm -rf .cache`"] });
    expect(runner.commandsRun).toHaveLength(0);
  });

  it("refuses to patch when the D4 gate has not permitted local patching for this app", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient } = poolClientRecordingOutcomes();
    const provenanceStore = new InstallProvenanceStore({ persistence: new InMemoryInstallProvenancePersistence() });
    // No recordGuideSourceClone call — the app is unknown provenance, fail closed.
    const patchQueue = new PatchQueue(new InMemoryPatchQueueStorage());
    const engine = new RecipeReplayEngine({
      provenanceStore,
      poolClient,
      getCurrentInstallId: () => "install-1",
      patchQueue,
      createShellRunner: () => runner,
      verificationCommandsForStack: () => NO_BUILD_OR_TEST,
    });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchingNotPermittedForThisInstall" });
    expect(runner.commandsRun).toHaveLength(0);
  });

  it("treats an empty patchSpecific as patchDidNotApply without touching the shell", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient } = poolClientRecordingOutcomes();
    const { engine } = engineFor({ runner, poolClient });
    const recipe = aRecipe({ patchSpecific: "" });

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchDidNotApply" });
    expect(runner.commandsRun).toHaveLength(0);
  });

  it("reports patchingNotPermittedForThisInstall when a shell runner cannot be constructed", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient } = poolClientRecordingOutcomes();
    const { engine } = engineFor({ runner, poolClient, createShellRunner: () => undefined });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchingNotPermittedForThisInstall" });
  });
});

describe("RecipeReplayEngine.replay — Tier A apply-verify-commit", () => {
  it("applies, verifies clean, commits on an iris/fix-<sig>-<date> branch, and files a success outcome twice", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const { poolClient, outcomeCalls } = poolClientRecordingOutcomes();
    const { engine, patchQueue } = engineFor({ runner, poolClient });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result.type).toBe("patchAppliedAndVerified");
    if (result.type !== "patchAppliedAndVerified") throw new Error("unreachable");
    expect(result.branchName).toMatch(/^iris\/fix-abcdef012345-\d{8}$/);

    // The apply, then the commit — never chained with && or ||, PowerShell-safe.
    expect(runner.commandsRun.some((c) => c.includes("git apply --check --3way"))).toBe(true);
    expect(runner.commandsRun.some((c) => c.includes("git apply --3way") && !c.includes("--check"))).toBe(true);
    expect(runner.commandsRun.some((c) => c.startsWith("git commit -m"))).toBe(true);
    expect(runner.commandsRun.some((c) => c.includes("&&") || c.includes("||"))).toBe(false);

    // Two fire-and-forget outcomes: one for "applied", one for "verified".
    expect(outcomeCalls).toEqual([{ succeeded: true, installId: "install-abc-123" }, { succeeded: true, installId: "install-abc-123" }]);

    const queued = patchQueue.patchesForAppSlug("cue");
    expect(queued).toHaveLength(1);
    expect(queued[0]).toMatchObject({
      recipeId: "recipe-1",
      signatureId: recipe.signatureId,
      appSlug: "cue",
      branchName: result.branchName,
      patchText: recipe.patchSpecific,
    });
  });

  it("does not apply a patch that fails even the --3way dry-run, and files exactly one failed outcome", async () => {
    const runner = new MockMaintainShellRunner([{ succeeded: false, exitCode: 1, outputTail: "patch does not apply" }]);
    const { poolClient, outcomeCalls } = poolClientRecordingOutcomes();
    const { engine, patchQueue } = engineFor({ runner, poolClient });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchDidNotApply" });
    expect(runner.commandsRun).toEqual([expect.stringContaining("git apply --check --3way")]);
    expect(outcomeCalls).toEqual([{ succeeded: false, installId: "install-abc-123" }]);
    expect(patchQueue.patchesForAppSlug("cue")).toHaveLength(0);
  });

  it("reverts and reports patchRevertedAfterFailedVerification when the build fails after a clean apply", async () => {
    const runner = new MockMaintainShellRunner([
      { succeeded: true, exitCode: 0, outputTail: "" }, // 1: git apply --check --3way
      { succeeded: true, exitCode: 0, outputTail: "deadbeef\n" }, // 2: git rev-parse HEAD
      { succeeded: true, exitCode: 0, outputTail: "" }, // 3: git apply --3way
      { succeeded: true, exitCode: 0, outputTail: "" }, // 4: git diff --numstat HEAD (diff-scope gate)
      { succeeded: true, exitCode: 0, outputTail: "" }, // 5: git ls-files --others --exclude-standard
      { succeeded: false, exitCode: 1, outputTail: "error: missing dependency" }, // 6: the build command itself
    ]);
    const { poolClient, outcomeCalls } = poolClientRecordingOutcomes();
    const { engine, patchQueue } = engineFor({
      runner,
      poolClient,
      verificationCommandsForStack: () => ({ buildCommand: "npm run build" }),
    });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchRevertedAfterFailedVerification", blockedStage: "build" });
    expect(runner.commandsRun).toContain("git checkout -- .");
    expect(runner.commandsRun).toContain("git clean -fd --quiet");
    expect(runner.commandsRun.some((c) => c.startsWith("git commit"))).toBe(false);
    // "applied" outcome (true) then "verified" outcome (false) — a clean apply
    // that fails verification is reported as a failure, never as a half-success.
    expect(outcomeCalls).toEqual([
      { succeeded: true, installId: "install-abc-123" },
      { succeeded: false, installId: "install-abc-123" },
    ]);
    expect(patchQueue.patchesForAppSlug("cue")).toHaveLength(0);
  });
});

describe("RecipeReplayEngine.replay — Tier B, the stale-recipe adapt retry", () => {
  it("falls back to patchDidNotApply when there is no fixAdapter at all", async () => {
    const runner = new MockMaintainShellRunner([{ succeeded: false, exitCode: 1, outputTail: "stale" }]);
    const { poolClient } = poolClientRecordingOutcomes();
    const { engine } = engineFor({ runner, poolClient }); // no fixAdapter passed
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchDidNotApply" });
  });

  it("retries with the adapted diff and succeeds when the adapter re-anchors it", async () => {
    // Only the FIRST call (Tier A's dry-run) is scripted to fail; every call
    // after that (the retried dry-run, apply, diff-scope gate, commit steps)
    // falls through to MockMaintainShellRunner's default success.
    const runner = new MockMaintainShellRunner([{ succeeded: false, exitCode: 1, outputTail: "stale" }]);
    const { poolClient, outcomeCalls } = poolClientRecordingOutcomes();

    let adaptPatchCallCount = 0;
    const adaptedDiff = "--- a/config.json\n+++ b/config.json\n@@ -1 +1 @@\n-old\n+renamed\n";
    const scriptedAdapter: MaintainFixAdapting = {
      async adaptPatch(): Promise<MaintainFixAdaptation> {
        adaptPatchCallCount += 1;
        return { type: "adaptedPatch", unifiedDiff: adaptedDiff };
      },
    };

    const { engine, patchQueue } = engineFor({ runner, poolClient, fixAdapter: scriptedAdapter });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(adaptPatchCallCount).toBe(1);
    expect(result.type).toBe("patchAppliedAndVerified");
    // The Tier A failure filed one outcome (false); the Tier B success spine
    // filed two more (applied=true, verified=true).
    expect(outcomeCalls).toEqual([
      { succeeded: false, installId: "install-abc-123" },
      { succeeded: true, installId: "install-abc-123" },
      { succeeded: true, installId: "install-abc-123" },
    ]);
    const queued = patchQueue.patchesForAppSlug("cue");
    expect(queued).toHaveLength(1);
    expect(queued[0].patchText).toBe(adaptedDiff);
  });

  it("gives up as patchDidNotApply when the adapter itself declines", async () => {
    const runner = new MockMaintainShellRunner([{ succeeded: false, exitCode: 1, outputTail: "stale" }]);
    const { poolClient } = poolClientRecordingOutcomes();
    const decliningAdapter: MaintainFixAdapting = {
      async adaptPatch(): Promise<MaintainFixAdaptation> {
        return { type: "modelCouldNotAdapt", reason: "the file was deleted upstream" };
      },
    };
    const { engine } = engineFor({ runner, poolClient, fixAdapter: decliningAdapter });
    const recipe = aRecipe();

    const result = await engine.replay({
      recipe,
      appSlug: "cue",
      appStack: AN_APP_STACK,
      installedAppVersion: "1.0.0",
      signatureId: recipe.signatureId,
      machineArchitecture: "x64",
    });

    expect(result).toEqual({ type: "patchDidNotApply" });
  });
});
