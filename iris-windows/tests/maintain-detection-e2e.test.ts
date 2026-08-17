import { describe, expect, it, vi } from "vitest";
import {
  CrashArtifactWatcher,
  type DirectoryWatchHandle,
} from "../src/services/maintain/crash-watcher";
import { WindowsAppInventory } from "../src/services/maintain/app-inventory";
import {
  InMemoryMaintainIncidentGatePersistence,
  MaintainIncidentCoordinator,
} from "../src/services/maintain/incident-coordinator";
import type { MaintainPoolClient, PooledFixRecipe } from "../src/services/maintain/pool-client";
import type { InstallProvenanceStore } from "../src/services/maintain/install-provenance";
import type { RecipeReplayEngine } from "../src/services/maintain/replay-engine";
import { buildAppCrashWerText } from "./fixtures/wer-signature-fixture";

/**
 * The item-4 end-to-end: a REAL Windows crash artifact for the publikclip
 * recipe's installed exe (`publikclip-app.exe`) flows through the real
 * `CrashArtifactWatcher` → the real `WindowsAppInventory` matcher → the real
 * `MaintainIncidentCoordinator`, which raises exactly one ask attributed to
 * publikclip. This is the whole "live detection self-triggers for the recipe's
 * app" claim, proven with injected filesystem seams (no real WER directory, no
 * Windows API) so it runs on the Mac and on windows-latest alike.
 */

const REPORT_ARCHIVE = "/fake/report-archive";
const CRASH_DUMPS = "/fake/crash-dumps";
const flushMicrotasks = () => new Promise((resolve) => setTimeout(resolve, 0));

function makeCoordinator(): {
  coordinator: MaintainIncidentCoordinator;
  poolClient: MaintainPoolClient;
} {
  const poolClient = {
    lookupRecipes: vi.fn(async () => ({ recipes: [] as PooledFixRecipe[], matchedBy: null })),
    fileConfirmedBreak: vi.fn(async () => ({ breakId: "break-1" })),
  } as unknown as MaintainPoolClient;
  const provenanceStore = { localPatchingIsPermitted: vi.fn(() => false) } as unknown as InstallProvenanceStore;
  const replayEngine = { replay: vi.fn() } as unknown as RecipeReplayEngine;

  const coordinator = new MaintainIncidentCoordinator({
    poolClient,
    provenanceStore,
    replayEngine,
    persistence: new InMemoryMaintainIncidentGatePersistence(),
    generateAskId: () => "ask-1",
    nowEpochMs: () => 1_700_000_000_000,
    resolveMachineArchitecture: () => "x64",
  });
  return { coordinator, poolClient };
}

describe("live crash detection self-triggers for the publikclip recipe's app", () => {
  it("attributes a publikclip-app.exe crash artifact and raises a publikclip ask", async () => {
    const { coordinator, poolClient } = makeCoordinator();
    const inventory = new WindowsAppInventory();

    // A realistic AppCrash Report.wer whose Application Name is the recipe's
    // installed exe — exactly what Windows Error Reporting writes.
    const reportDirectoryName = "publikclip_crash_0001";
    const werText = buildAppCrashWerText({
      applicationName: "publikclip-app.exe",
      applicationVersion: "0.1.0.0",
      faultModuleName: "publikclip-app.exe",
      exceptionCode: "c0000005",
      exceptionOffset: "000000000004a1b0",
      reportIdentifier: "abcdef01-2345-6789-abcd-ef0123456789",
    });

    // The report directory is not present at start (old news is ignored); it
    // appears after the watch is hooked, and the watch fires.
    const reportArchiveEntries: string[] = [];
    let fireReportArchiveChange: (() => void) | undefined;

    const watcher = new CrashArtifactWatcher({
      appMatcher: inventory,
      reportArchiveDirectoryPath: REPORT_ARCHIVE,
      crashDumpsDirectoryPath: CRASH_DUMPS,
      listDirectoryEntries: async (path) => (path === REPORT_ARCHIVE ? [...reportArchiveEntries] : []),
      readReportWerText: async (dir) => (dir.endsWith(reportDirectoryName) ? werText : undefined),
      watchDirectory: (path, onChange): DirectoryWatchHandle => {
        if (path === REPORT_ARCHIVE) fireReportArchiveChange = onChange;
        return { close: () => undefined };
      },
      sleepMs: async () => undefined,
    });

    // The whole wire: a detected artifact becomes a native-crash signal to the
    // coordinator, with the display name resolved from the inventory — the same
    // hook `main/maintain/controller.ts` installs.
    watcher.onCrashArtifactDetected = (artifact) => {
      coordinator.handleNativeCrash({
        parsedCrash: artifact.report,
        appSlug: artifact.catalogAppSlug,
        appName: inventory.appNameForSlug(artifact.catalogAppSlug),
        appStack: artifact.catalogAppStack,
      });
    };

    await watcher.start();
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull(); // nothing yet

    // publikclip crashes: WER writes the report, the archive changes.
    reportArchiveEntries.push(reportDirectoryName);
    fireReportArchiveChange?.();
    await flushMicrotasks();

    const ask = coordinator.currentSnapshot().pendingAsk;
    expect(ask).not.toBeNull();
    expect(ask?.appSlug).toBe("publikclip");
    expect(ask?.appName).toBe("publikclip");
    expect(ask?.evidenceSentence).toBe("publikclip quit unexpectedly a moment ago.");
    // The cache lookup fired for publikclip's signature — the zero-token first
    // rung of the fix ladder.
    expect(poolClient.lookupRecipes).toHaveBeenCalledWith(
      expect.objectContaining({ appSlug: "publikclip", signatureId: ask?.signatureId })
    );
  });

  it("ignores a crash artifact for a process that is not one of ours", async () => {
    const { coordinator } = makeCoordinator();
    const inventory = new WindowsAppInventory();

    const reportArchiveEntries: string[] = [];
    let fireChange: (() => void) | undefined;
    const watcher = new CrashArtifactWatcher({
      appMatcher: inventory,
      reportArchiveDirectoryPath: REPORT_ARCHIVE,
      crashDumpsDirectoryPath: CRASH_DUMPS,
      listDirectoryEntries: async (path) => (path === REPORT_ARCHIVE ? [...reportArchiveEntries] : []),
      readReportWerText: async () => buildAppCrashWerText({ applicationName: "notepad.exe", exceptionCode: "c0000005" }),
      watchDirectory: (path, onChange): DirectoryWatchHandle => {
        if (path === REPORT_ARCHIVE) fireChange = onChange;
        return { close: () => undefined };
      },
      sleepMs: async () => undefined,
    });
    watcher.onCrashArtifactDetected = (artifact) =>
      coordinator.handleNativeCrash({
        parsedCrash: artifact.report,
        appSlug: artifact.catalogAppSlug,
        appName: inventory.appNameForSlug(artifact.catalogAppSlug),
        appStack: artifact.catalogAppStack,
      });

    await watcher.start();
    reportArchiveEntries.push("notepad_crash");
    fireChange?.();
    await flushMicrotasks();

    // Not a catalog app → no artifact delivered → no ask.
    expect(coordinator.currentSnapshot().pendingAsk).toBeNull();
  });
});
