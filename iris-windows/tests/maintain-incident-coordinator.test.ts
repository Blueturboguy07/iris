import { describe, it, expect, vi } from "vitest";
import {
  MaintainIncidentCoordinator,
  InMemoryMaintainIncidentGatePersistence,
  MINIMUM_MS_BETWEEN_ASKS_PER_APP,
  type MaintainIncidentCoordinatorOptions,
  type MaintainIncidentSnapshot,
} from "../src/services/maintain/incident-coordinator";
import type { MaintainPoolClient, PooledFixRecipe } from "../src/services/maintain/pool-client";
import type { InstallProvenanceStore } from "../src/services/maintain/install-provenance";
import type { RecipeReplayEngine } from "../src/services/maintain/replay-engine";
import type { ParsedWindowsCrash } from "../src/services/maintain/break-signature";

/**
 * incident-coordinator.ts is the accuracy layer of maintain mode — the ladder
 * that turns raw signals into AT MOST one careful, rate-limited question. The
 * audit flagged it as the only maintain-mode orchestrator with zero direct
 * tests; this is that file. Every collaborator is an injected seam, so the
 * whole ask gate can be driven deterministically off a fake clock.
 */

const flushMicrotasks = () => new Promise((resolve) => setTimeout(resolve, 0));

function makePoolClient(overrides: Partial<Record<"lookupRecipes" | "fileConfirmedBreak", unknown>> = {}): MaintainPoolClient {
  return {
    lookupRecipes: vi.fn(async () => ({ recipes: [] as PooledFixRecipe[], matchedBy: null })),
    fileConfirmedBreak: vi.fn(async () => ({ breakId: "break-1" })),
    ...overrides,
  } as unknown as MaintainPoolClient;
}

function makeProvenanceStore(localPatchingIsPermitted = false): InstallProvenanceStore {
  return { localPatchingIsPermitted: vi.fn(() => localPatchingIsPermitted) } as unknown as InstallProvenanceStore;
}

function makeReplayEngine(replayResult: unknown = { type: "patchAppliedAndVerified", branchName: "iris/fix-abc" }): RecipeReplayEngine {
  return { replay: vi.fn(async () => replayResult) } as unknown as RecipeReplayEngine;
}

interface Harness {
  coordinator: MaintainIncidentCoordinator;
  persistence: InMemoryMaintainIncidentGatePersistence;
  clock: { now: number };
  snapshots: MaintainIncidentSnapshot[];
  poolClient: MaintainPoolClient;
}

function makeCoordinator(options: Partial<MaintainIncidentCoordinatorOptions> = {}): Harness {
  const persistence = new InMemoryMaintainIncidentGatePersistence();
  const clock = { now: 1_700_000_000_000 };
  const snapshots: MaintainIncidentSnapshot[] = [];
  const poolClient = options.poolClient ?? makePoolClient();
  let askCounter = 0;

  const coordinator = new MaintainIncidentCoordinator({
    poolClient,
    provenanceStore: options.provenanceStore ?? makeProvenanceStore(),
    replayEngine: options.replayEngine ?? makeReplayEngine(),
    persistence,
    generateAskId: () => `ask-${(askCounter += 1)}`,
    nowEpochMs: () => clock.now,
    onStateChanged: (snapshot) => snapshots.push(snapshot),
    resolveMachineArchitecture: () => "x64",
    ...options,
  });

  return { coordinator, persistence, clock, snapshots, poolClient };
}

function crash(coordinator: MaintainIncidentCoordinator, appSlug = "demo", appName = "Demo"): void {
  const parsedCrash: ParsedWindowsCrash = {
    appName: `${appSlug}.exe`,
    exceptionCode: "c0000005",
    faultingModuleName: `${appSlug}.exe`,
    faultingOffset: "0000000000001234",
  };
  coordinator.handleNativeCrash({ parsedCrash, appSlug, appName, appStack: "electron" });
}

describe("MaintainIncidentCoordinator — the ask gate", () => {
  it("raises exactly one ask on a native crash, with an evidence sentence and a fired state change", () => {
    const { coordinator, snapshots } = makeCoordinator();
    crash(coordinator);

    const snapshot = coordinator.currentSnapshot();
    expect(snapshot.pendingAsk).not.toBeNull();
    expect(snapshot.pendingAsk?.appSlug).toBe("demo");
    expect(snapshot.pendingAsk?.evidenceSentence).toBe("Demo quit unexpectedly a moment ago.");
    expect(snapshots.length).toBeGreaterThanOrEqual(1);
  });

  it("suppresses a second ask while one is already pending", () => {
    const { coordinator } = makeCoordinator();
    crash(coordinator, "demo", "Demo");
    const firstAskId = coordinator.currentSnapshot().pendingAsk?.id;
    crash(coordinator, "other", "Other");
    // Still the first app's ask; the second never displaced it.
    expect(coordinator.currentSnapshot().pendingAsk?.id).toBe(firstAskId);
    expect(coordinator.currentSnapshot().pendingAsk?.appSlug).toBe("demo");
  });

  it("does not ask about a muted app", () => {
    const { coordinator } = makeCoordinator();
    crash(coordinator);
    coordinator.answerPendingAsk("neverAskAboutThisApp");
    expect(coordinator.mutedApps()).toContain("demo");

    // A new crash more than 24h later would otherwise be allowed by the rate gate.
    const { coordinator: c2, clock, persistence } = makeCoordinator();
    crash(c2);
    c2.answerPendingAsk("neverAskAboutThisApp");
    clock.now += MINIMUM_MS_BETWEEN_ASKS_PER_APP + 1;
    crash(c2);
    expect(c2.currentSnapshot().pendingAsk).toBeNull();
    expect(persistence.readGateState().mutedAppSlugs).toContain("demo");
  });

  it("unmuteApp reverses a mute", () => {
    const { coordinator } = makeCoordinator();
    crash(coordinator);
    coordinator.answerPendingAsk("neverAskAboutThisApp");
    expect(coordinator.mutedApps()).toContain("demo");
    coordinator.unmuteApp("demo");
    expect(coordinator.mutedApps()).not.toContain("demo");
  });

  it('"thatWasMe" suppresses that signature so an identical later crash never asks', () => {
    const { coordinator, clock } = makeCoordinator();
    crash(coordinator);
    coordinator.answerPendingAsk("thatWasMe");
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull();

    // Past the 24h gate, an identical-signature crash is still silent (benign).
    clock.now += MINIMUM_MS_BETWEEN_ASKS_PER_APP + 1;
    crash(coordinator);
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull();
  });

  it("enforces the 24h minimum gap between unsolicited asks about the same app", () => {
    const { coordinator, clock } = makeCoordinator();
    crash(coordinator);
    coordinator.answerPendingAsk("somethingIsBroken");

    // One hour later: still inside the 24h window → suppressed.
    clock.now += 60 * 60 * 1000;
    crash(coordinator);
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull();

    // Just past 24h → allowed again.
    clock.now += MINIMUM_MS_BETWEEN_ASKS_PER_APP;
    crash(coordinator);
    expect(coordinator.currentSnapshot().pendingAsk).not.toBeNull();
  });

  it("answerPendingAsk is a no-op when nothing is pending", () => {
    const { coordinator, snapshots } = makeCoordinator();
    const before = snapshots.length;
    coordinator.answerPendingAsk("somethingIsBroken");
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull();
    expect(snapshots.length).toBe(before);
  });
});

describe("MaintainIncidentCoordinator — on confirmation", () => {
  it("files the break and records the diagnosis title", async () => {
    const poolClient = makePoolClient();
    const { coordinator } = makeCoordinator({ poolClient });
    crash(coordinator);
    coordinator.answerPendingAsk("somethingIsBroken");
    await flushMicrotasks();

    expect(poolClient.fileConfirmedBreak).toHaveBeenCalledTimes(1);
    expect(coordinator.currentLastConfirmedDiagnosisTitle()).toBe("Demo quit unexpectedly a moment ago.");
  });

  it("replays the top pooled recipe when one matched the signature", async () => {
    const recipe = { id: "r1" } as unknown as PooledFixRecipe;
    const poolClient = makePoolClient({ lookupRecipes: vi.fn(async () => ({ recipes: [recipe], matchedBy: "fingerprintStrict" })) });
    const replayEngine = makeReplayEngine({ type: "patchAppliedAndVerified", branchName: "iris/fix-xyz" });
    const { coordinator } = makeCoordinator({ poolClient, replayEngine });

    crash(coordinator);
    await flushMicrotasks(); // let the cache lookup land so recipesForPendingAsk fills
    expect(coordinator.currentSnapshot().recipesForPendingAsk).toHaveLength(1);

    coordinator.answerPendingAsk("somethingIsBroken");
    await flushMicrotasks();

    expect(replayEngine.replay).toHaveBeenCalledTimes(1);
    expect(coordinator.currentSnapshot().fixStatusLine).toContain("iris/fix-xyz");
  });

  it("falls back to Tier C when no recipe matched but a BYO key and a patchable clone exist", async () => {
    const attemptNovelFix = vi.fn(async () => "iris/fix-novel");
    const { coordinator } = makeCoordinator({
      provenanceStore: makeProvenanceStore(true),
      attemptNovelFix,
    });
    crash(coordinator);
    await flushMicrotasks();
    coordinator.answerPendingAsk("somethingIsBroken");
    await flushMicrotasks();

    expect(attemptNovelFix).toHaveBeenCalledTimes(1);
    expect(coordinator.currentSnapshot().fixStatusLine).toContain("iris/fix-novel");
  });

  it("lands on the honest 'no known fix yet' status with no recipe and no BYO key", async () => {
    const { coordinator } = makeCoordinator(); // provenance denies patching, no attemptNovelFix
    crash(coordinator);
    await flushMicrotasks();
    coordinator.answerPendingAsk("somethingIsBroken");
    await flushMicrotasks();

    expect(coordinator.currentSnapshot().fixStatusLine).toContain("No known fix yet");
  });

  it("clearFixStatus dismisses the post-answer status", async () => {
    const { coordinator } = makeCoordinator();
    crash(coordinator);
    coordinator.answerPendingAsk("somethingIsBroken");
    await flushMicrotasks();
    expect(coordinator.currentSnapshot().fixStatusLine).not.toBeNull();

    coordinator.clearFixStatus();
    expect(coordinator.currentSnapshot().fixStatusLine).toBeNull();
    expect(coordinator.currentSnapshot()).toEqual({
      pendingAsk: null,
      recipesForPendingAsk: [],
      fixStatusLine: null,
      fixGuidanceSteps: [],
    });
  });
});
