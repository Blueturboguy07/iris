/**
 * controller.ts
 *
 * The composition root for maintain mode's main-process side. Mirrors
 * `main/autopilot-controller.ts`'s shape: it owns the pure
 * `MaintainIncidentCoordinator`, wires the real (Windows-only)
 * implementations of every seam the coordinator and its collaborators need,
 * forwards state changes to the renderer through an injected `MaintainHost`,
 * and answers the IPC-driven `answerAsk`/`clearFixStatus` calls
 * `main/index.ts` routes to it.
 *
 * ## What this file wires today, and what it deliberately does not
 *
 * Wired for real: the recipe pool (`MaintainPoolClient` over `fetch`), the
 * ask-gate/provenance/install-identity persistence (`MaintainStateStore`, one
 * `userData/maintain.json`), the patch queue (`PatchQueue` over
 * `userData/patch-queue/`), the Tier A/B replay engine (`RecipeReplayEngine`
 * over a real `WindowsMaintainShellRunner` and the Anthropic BYO patch
 * adapter), and Tier C (`MaintainTierCFixer` over the same shell runner, the
 * real `WindowsJobObjectSandbox`, and whichever BYO model provider the user
 * configured).
 *
 * NOW WIRED (the gap the porting spec §5 gap 4 flagged is closed): real
 * crash + hang SIGNAL SOURCES self-trigger. `startDetection()` constructs and
 * starts `services/maintain/crash-watcher.ts`'s `CrashArtifactWatcher` against
 * `services/maintain/app-inventory.ts`'s `WindowsAppInventory` (the matcher +
 * frontmost tracker + slug→stack dict), and runs a ~2s hang-probe tick over
 * whatever catalog app is frontmost, buffering a confirmed hang until it
 * recovers/exits before asking (the `confirmedHangByPid` latch, mirroring
 * macOS's `CompanionManager.startMaintainMode`). This became wireable once a
 * Windows catalog app with a known exe exists: `services/autopilot/recipes.ts`
 * now carries the publikclip source-build recipe, whose installed
 * `publikclip-app.exe` `WindowsAppInventory` recognizes. `reportNativeCrash`/
 * `reportConfirmedHang`/`reportLaunchFailure` remain the seam the watchers call
 * (and the env-gated `triggerDemoIncidentIfConfigured` still exercises the
 * whole ladder with no real crash). The hang TICK is gated to Windows —
 * `checkProcessResponsiveViaPowerShell` and the foreground read both need
 * `powershell.exe` — so the Mac dev build does not spawn a failing probe every
 * two seconds; the crash watcher itself starts everywhere (it watches Windows
 * paths that simply do not exist on the Mac, so it stays quiet there).
 *
 * STILL not wired here, flagged rather than silently skipped (porting spec §5):
 *
 *   - Launch-failure detection has no watcher yet — `reportLaunchFailure`
 *     exists for an autopilot/direct-launch path to call, but nothing calls it
 *     automatically (there is no Windows "process died seconds after spawn"
 *     signal source in this repo).
 *   - `installedVersionLookup`. There is no Windows analog of macOS's
 *     `AppInventoryService` in this repo yet, so a pooled recipe's
 *     `applicability.app_version` range is matched against whatever version
 *     the crash/hang signal itself carried (`ParsedWindowsCrash.appVersion`),
 *     never a separately-looked-up installed version. Wiring a real
 *     `installedVersionLookup` closure through here is additive once that
 *     service exists.
 *   - The OpenAI BYO key stays deliberately unwired: `readOpenAiApiKey` below
 *     always answers `null`, so Tier C runs on the Anthropic BYO key alone.
 *     This is policy, not an interlock — Iris is Anthropic-only (`CLAUDE.md`,
 *     "Do not reintroduce ... a non-Anthropic provider"), even though the
 *     ported `model-provider.ts` still carries the macOS `OpenAIMaintainProvider`
 *     class. Reintroducing OpenAI is a founder decision, not a wiring gap.
 *     (The GitHub device-flow token pair, by contrast, is now persisted for
 *     real through `safeStorage` — see `github-token-storage.ts` — so a
 *     connected fork-backup survives relaunch, matching macOS's Keychain pair.)
 *
 * Install provenance IS now recorded on a real autopilot install finish:
 * `main/autopilot-controller.ts`'s `onFinished` hands the finished install to
 * this file's `recordInstallProvenance`, which runs the pure
 * `decideInstallProvenance` and calls `recordGuideSourceClone` /
 * `recordSignedDownload`. `InstallRecipe` now carries `canonicalRepo` and
 * `pinnedCommit`, closing the interlock `install-provenance.ts`'s header flagged.
 */

import { app, shell } from "electron";
import * as path from "node:path";
import { readSecret } from "../secrets";
import { createWindowsMaintainShellRunner } from "./maintain-shell-runner-windows";
import { MaintainStateStore } from "./state-store";
import {
  MaintainIncidentCoordinator,
  type MaintainAskAnswer,
  type MaintainIncidentSnapshot,
} from "../../services/maintain/incident-coordinator";
import type { BreakAppStack, ParsedWindowsCrash } from "../../services/maintain/break-signature";
import { CrashArtifactWatcher, type DetectedCrashArtifact } from "../../services/maintain/crash-watcher";
import {
  HangProbe,
  checkProcessResponsiveViaPowerShell,
  type HangProbeVerdict,
} from "../../services/maintain/hang-probe";
import {
  WindowsAppInventory,
  windowsCatalogAppForSlug,
  type FrontmostCatalogApp,
} from "../../services/maintain/app-inventory";
import { defaultVerificationCommandsForStack } from "../../services/maintain/incoming-fix-reviewer";
import { MaintainInstallIdentity } from "../../services/maintain/install-identity";
import { InstallProvenanceStore, decideInstallProvenance } from "../../services/maintain/install-provenance";
import type { FinishedInstall } from "../autopilot-controller";
import { GitHubForkService } from "../../services/maintain/github-fork-service";
import { SecretsBackedGitHubTokenStorage } from "./github-token-storage";
import { firstAvailableMaintainProvider } from "../../services/maintain/model-provider";
import { FileSystemPatchQueueStorage, PatchQueue } from "../../services/maintain/patch-queue";
import { MaintainPoolClient } from "../../services/maintain/pool-client";
import { AnthropicPatchAdapter, RecipeReplayEngine } from "../../services/maintain/replay-engine";
import { WindowsJobObjectSandbox } from "../../services/maintain/sandbox";
import { MaintainTierCFixer } from "../../services/maintain/tier-c-fixer";
import { maintainTrace } from "../../services/maintain/trace";

/** Everything the coordinator needs from the app — the renderer-forwarding
 *  half. Mirrors `AutopilotHost` in `main/autopilot-controller.ts`. */
export interface MaintainHost {
  emitSnapshot(snapshot: MaintainIncidentSnapshot): void;
}

/** How often the hang probe ticks over the frontmost catalog app — the direct
 *  port of macOS's `Timer.scheduledTimer(withTimeInterval: 2, ...)`. Four
 *  consecutive failed probes at this cadence is ~8–10s of confirmed silence
 *  before anything escalates (see `hang-probe.ts`). */
const HANG_PROBE_TICK_INTERVAL_MS = 2000;

export class MaintainController {
  private readonly host: MaintainHost;
  private readonly stateStore: MaintainStateStore;
  private readonly poolClient: MaintainPoolClient;
  private readonly provenanceStore: InstallProvenanceStore;
  private readonly installIdentity: MaintainInstallIdentity;
  private readonly patchQueue: PatchQueue;
  private readonly gitHubForkService: GitHubForkService;
  private readonly replayEngine: RecipeReplayEngine;
  private readonly coordinator: MaintainIncidentCoordinator;

  // MARK: - Detection (the always-on signal sources)

  private readonly appInventory: WindowsAppInventory;
  private readonly crashArtifactWatcher: CrashArtifactWatcher;
  private readonly hangProbe: HangProbe;
  private hangProbeInterval: ReturnType<typeof setInterval> | undefined;
  /** Guards against a slow foreground read overlapping the next 2s tick. */
  private hangTickInFlight = false;
  /** The catalog app the last tick probed — read by the hang-verdict handler
   *  to attribute a confirmed hang to a slug/pid (mirrors macOS reading
   *  `NSWorkspace.frontmostApplication` inside its verdict closure). */
  private lastProbedFrontmostApp: FrontmostCatalogApp | undefined;
  /** The hang the probe is currently tracking per pid, so the ask fires ONCE
   *  on recovery/exit rather than every tick — the Windows analog of macOS's
   *  `confirmedHangByPid`. Mutable `seconds` so a still-hanging app updates its
   *  duration in place. */
  private readonly confirmedHangByPid = new Map<
    number,
    { slug: string; appName: string; stack: BreakAppStack; exeName: string | undefined; seconds: number }
  >();

  constructor(host: MaintainHost) {
    this.host = host;
    this.stateStore = new MaintainStateStore();
    this.poolClient = new MaintainPoolClient();
    this.provenanceStore = new InstallProvenanceStore({ persistence: this.stateStore });
    this.installIdentity = new MaintainInstallIdentity({ persistence: this.stateStore });
    this.patchQueue = new PatchQueue(new FileSystemPatchQueueStorage(path.join(this.userDataPath(), "patch-queue")));
    this.gitHubForkService = new GitHubForkService({
      // Persisted for real through `safeStorage` (DPAPI), the Windows analog of
      // the Keychain pair `iris-macos` keeps — so a connected fork-backup
      // survives relaunch. See `github-token-storage.ts`.
      tokenStorage: new SecretsBackedGitHubTokenStorage(),
      openExternal: (url) => {
        void shell.openExternal(url);
      },
    });
    this.replayEngine = new RecipeReplayEngine({
      provenanceStore: this.provenanceStore,
      poolClient: this.poolClient,
      getCurrentInstallId: () => this.installIdentity.currentInstallId(),
      patchQueue: this.patchQueue,
      createShellRunner: createWindowsMaintainShellRunner,
      verificationCommandsForStack: defaultVerificationCommandsForStack,
      fixAdapter: new AnthropicPatchAdapter(() => readSecret("anthropicApiKey")),
    });
    this.coordinator = new MaintainIncidentCoordinator({
      poolClient: this.poolClient,
      provenanceStore: this.provenanceStore,
      replayEngine: this.replayEngine,
      persistence: this.stateStore,
      backUpFixBranch: (branchName, appSlug) => this.backUpFixBranch(branchName, appSlug),
      attemptNovelFix: (appSlug, appStack, signatureId, evidence) =>
        this.attemptNovelFix(appSlug, appStack, signatureId, evidence),
      onStateChanged: (snapshot) => this.host.emitSnapshot(snapshot),
    });

    // The always-on detection layer. Constructed here; started by
    // `startDetection()` from `main/index.ts` after the app is ready.
    this.appInventory = new WindowsAppInventory();
    this.crashArtifactWatcher = new CrashArtifactWatcher({ appMatcher: this.appInventory });
    this.crashArtifactWatcher.onCrashArtifactDetected = (artifact) => this.onCrashArtifactDetected(artifact);
    this.hangProbe = new HangProbe({
      checkResponsive: (processId) => checkProcessResponsiveViaPowerShell(processId),
      onVerdict: (processId, verdict) => this.onHangVerdict(processId, verdict),
    });
  }

  // MARK: - Detection lifecycle

  /**
   * Starts the always-on signal sources: the crash-artifact watch (event-
   * driven, free) and — on Windows only — the ~2s hang-probe tick over the
   * frontmost catalog app. Called once from `main/index.ts`'s bootstrap.
   * Mirrors macOS `CompanionManager.startMaintainMode`; everything funnels into
   * the coordinator, whose only output is a question.
   */
  startDetection(): void {
    void this.appInventory.refreshCatalog();
    void this.crashArtifactWatcher.start();

    // The probe mechanism (`Get-Process ... Responding`) and the foreground
    // read are PowerShell — Windows only. The Mac dev build starts the crash
    // watcher (harmless on non-Windows paths) but not this tick, so it never
    // spawns a failing `powershell.exe` every two seconds.
    if (process.platform === "win32" && this.hangProbeInterval === undefined) {
      this.hangProbeInterval = setInterval(() => void this.hangProbeTick(), HANG_PROBE_TICK_INTERVAL_MS);
    }
  }

  /** Stops the detection layer. Not wired to a quit path today (Iris is a tray
   *  app whose windows closing does not quit it), but symmetrical and used by
   *  tests. */
  stopDetection(): void {
    this.crashArtifactWatcher.stop();
    if (this.hangProbeInterval !== undefined) {
      clearInterval(this.hangProbeInterval);
      this.hangProbeInterval = undefined;
    }
  }

  /** A crash artifact for one of ours landed — hand it to the coordinator as a
   *  native crash, with the app's display name resolved from the inventory. */
  private onCrashArtifactDetected(artifact: DetectedCrashArtifact): void {
    this.reportNativeCrash({
      parsedCrash: artifact.report,
      appSlug: artifact.catalogAppSlug,
      appName: this.appInventory.appNameForSlug(artifact.catalogAppSlug),
      appStack: artifact.catalogAppStack,
    });
  }

  /** One 2s tick: probe whatever catalog app is frontmost, if any. A no-op
   *  when nothing of ours is in front. Guarded so a slow foreground read never
   *  overlaps the next tick. */
  private async hangProbeTick(): Promise<void> {
    if (this.hangTickInFlight) return;
    this.hangTickInFlight = true;
    try {
      const frontmost = await this.appInventory.frontmostCatalogApp();
      this.lastProbedFrontmostApp = frontmost;
      if (frontmost === undefined) return;
      await this.hangProbe.probe(frontmost.pid);
    } finally {
      this.hangTickInFlight = false;
    }
  }

  /**
   * Buffers a confirmed hang until it RECOVERS or EXITS, then asks — never
   * mid-hang, when a modal would land on someone already struggling. Straight
   * port of macOS's `hangProbe.onVerdict` closure and its `confirmedHangByPid`
   * bookkeeping. A `processDisappeared` also notes the exit to the crash
   * watcher, so a crash artifact that lands right after is corroborated.
   */
  private onHangVerdict(processId: number, verdict: HangProbeVerdict): void {
    switch (verdict.kind) {
      case "confirmedHang": {
        const alreadyTracking = this.confirmedHangByPid.get(processId);
        if (alreadyTracking !== undefined) {
          alreadyTracking.seconds = verdict.unresponsiveSeconds;
        } else if (this.lastProbedFrontmostApp?.pid === processId) {
          const frontmost = this.lastProbedFrontmostApp;
          this.confirmedHangByPid.set(processId, {
            slug: frontmost.slug,
            appName: frontmost.appName,
            stack: frontmost.stack,
            exeName: windowsCatalogAppForSlug(frontmost.slug)?.exeName,
            seconds: verdict.unresponsiveSeconds,
          });
        }
        break;
      }
      case "responsive":
      case "processDisappeared": {
        const hang = this.confirmedHangByPid.get(processId);
        if (hang !== undefined) {
          this.confirmedHangByPid.delete(processId);
          this.reportConfirmedHang({
            appSlug: hang.slug,
            appName: hang.appName,
            appStack: hang.stack,
            unresponsiveSeconds: hang.seconds,
          });
        }
        if (verdict.kind === "processDisappeared") {
          const exeName = hang?.exeName ?? windowsCatalogAppForSlug(this.lastProbedFrontmostApp?.slug ?? "")?.exeName;
          if (exeName !== undefined) {
            this.crashArtifactWatcher.noteProcessExited(exeName);
          }
        }
        break;
      }
      case "unresponsiveButBelowThreshold":
        break;
    }
  }

  // MARK: - Signal entry points (the future watchers' call shape — see the
  // module header for why nothing in this repo calls these for real yet)

  /** Called by a real crash watcher once one exists (see the module header).
   *  Exposed today so `triggerDemoIncidentIfConfigured` has a single,
   *  identical way in. */
  reportNativeCrash(options: {
    readonly parsedCrash: ParsedWindowsCrash;
    readonly appSlug: string;
    readonly appName: string;
    readonly appStack: BreakAppStack;
  }): void {
    this.coordinator.handleNativeCrash(options);
  }

  /** Called by a real hang probe once one is wired to a live process id. */
  reportConfirmedHang(options: {
    readonly appSlug: string;
    readonly appName: string;
    readonly appStack: BreakAppStack;
    readonly unresponsiveSeconds: number;
  }): void {
    this.coordinator.handleConfirmedHang(options);
  }

  /** Called by an autopilot/direct-launch path that notices a spawn failure
   *  or an immediate non-zero exit — see `incident-coordinator.ts`'s
   *  `handleLaunchFailure` header for why this is genuinely new surface, not
   *  a Swift parity item. */
  reportLaunchFailure(options: {
    readonly appSlug: string;
    readonly appName: string;
    readonly appStack: BreakAppStack;
    readonly daemon: string;
    readonly reason: string;
  }): void {
    this.coordinator.handleLaunchFailure(options);
  }

  /**
   * Proves the whole ladder end to end with no real crash — the maintain-mode
   * analog of `IRIS_AUTOPILOT_DEMO`. Reads `IRIS_MAINTAIN_DEMO_CRASH=<slug>`
   * (a catalog app slug) at startup; when set, raises a synthetic native-crash
   * ask for that app a few seconds after the app is ready, so the ask card,
   * the pool round trip, and the fix ladder are all visibly exercised without
   * waiting for a real Windows crash artifact or a catalog app with a known
   * exe to match against.
   */
  triggerDemoIncidentIfConfigured(): void {
    const demoSlug = process.env.IRIS_MAINTAIN_DEMO_CRASH;
    if (!demoSlug || demoSlug.length === 0) return;
    maintainTrace(`maintain: IRIS_MAINTAIN_DEMO_CRASH=${demoSlug} — raising a synthetic ask in 3s`);
    setTimeout(() => {
      this.reportNativeCrash({
        appSlug: demoSlug,
        appName: demoSlug,
        appStack: "electron",
        parsedCrash: {
          appName: `${demoSlug}.exe`,
          exceptionCode: "c0000005",
          faultingModuleName: `${demoSlug}.exe`,
          faultingOffset: "0x00001234",
        },
      });
    }, 3000);
  }

  // MARK: - Install provenance (the D4 gate's ground truth)

  /**
   * Records how an app just got onto this machine, called from
   * `main/autopilot-controller.ts`'s `onFinished` — the one moment provenance
   * is knowable for certain. The Windows mirror of macOS
   * `CompanionManager.recordInstallProvenance`: a `desktop_app` build that
   * cloned source becomes a `guide_source_clone` maintain mode may patch; any
   * other `desktop_app` install a `signed_app_download` it never may; a
   * `local_web`/`credential` install records nothing (there is no built binary
   * with a trust boundary). The provenance decision itself is the pure
   * `decideInstallProvenance`; this method only dispatches it to the store.
   */
  recordInstallProvenance(finishedInstall: FinishedInstall): void {
    const decision = decideInstallProvenance({
      outputType: finishedInstall.output.type,
      clonedARepo: finishedInstall.clonedARepo,
      clonePath: finishedInstall.clonePath,
      canonicalRepo: finishedInstall.canonicalRepo,
      pinnedCommit: finishedInstall.pinnedCommit,
    });
    switch (decision.kind) {
      case "guide_source_clone":
        this.provenanceStore.recordGuideSourceClone({
          appSlug: finishedInstall.slug,
          clonePath: decision.clonePath,
          pinnedCommit: decision.pinnedCommit,
          canonicalRepo: decision.canonicalRepo,
        });
        break;
      case "signed_app_download":
        this.provenanceStore.recordSignedDownload(finishedInstall.slug);
        break;
      case "none":
        maintainTrace(
          `maintain: nothing to record for ${finishedInstall.slug || "install"} (${finishedInstall.output.type} install)`
        );
        break;
    }
  }

  // MARK: - IPC-driven surface (see `main/index.ts`'s `setupIPC`)

  currentSnapshot(): MaintainIncidentSnapshot {
    return this.coordinator.currentSnapshot();
  }

  answerAsk(answer: MaintainAskAnswer): MaintainIncidentSnapshot {
    this.coordinator.answerPendingAsk(answer);
    return this.coordinator.currentSnapshot();
  }

  clearFixStatus(): MaintainIncidentSnapshot {
    this.coordinator.clearFixStatus();
    return this.coordinator.currentSnapshot();
  }

  mutedApps(): readonly string[] {
    return this.coordinator.mutedApps();
  }

  unmuteApp(appSlug: string): void {
    this.coordinator.unmuteApp(appSlug);
  }

  // MARK: - The two coordinator-injected async closures

  /** Tier C: no pooled recipe fit, but the user brought a BYO key and this
   *  install is a patchable source clone (the D4 gate, already checked by
   *  the coordinator before this is ever called). */
  private async attemptNovelFix(
    appSlug: string,
    appStack: BreakAppStack,
    signatureId: string,
    evidence: string
  ): Promise<string | undefined> {
    const modelProvider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => readSecret("anthropicApiKey"),
      // Deliberately null: Iris is Anthropic-only (`CLAUDE.md`), so Tier C
      // never runs on OpenAI even though `model-provider.ts` still carries the
      // ported provider. This is policy — see the module header — not a
      // pending interlock.
      readOpenAiApiKey: () => null,
    });
    if (modelProvider === undefined) {
      maintainTrace("maintain: Tier C skipped — no BYO model key configured");
      return undefined;
    }

    const record = this.provenanceStore.provenanceForAppSlug(appSlug);
    if (record === null || record.clonePath === null) {
      // Should not happen — the coordinator already checked
      // `localPatchingIsPermitted` before calling this — but this file fails
      // closed rather than handing `MaintainTierCFixer` a path it cannot use.
      return undefined;
    }

    const fixer = new MaintainTierCFixer({
      provider: modelProvider,
      createShellRunner: createWindowsMaintainShellRunner,
      sandbox: new WindowsJobObjectSandbox(),
      verificationCommandsForStack: defaultVerificationCommandsForStack,
    });

    const result = await fixer.attemptFix({
      clonePath: record.clonePath,
      appSlug,
      appStack,
      signatureId,
      crashEvidence: evidence,
    });
    if (result.type !== "fixedAndVerified") {
      maintainTrace(`maintain: Tier C did not produce a fix (${result.type}: ${result.reason})`);
      return undefined;
    }
    return result.branchName;
  }

  /** Backs a verified fix branch up to the user's GitHub fork (or, if the
   *  connected user owns the canonical repo, merges it straight in) — the
   *  ownership-aware propagation `github-fork-service.ts`'s `propagateFix`
   *  already implements. Absence of a summary is never an error: the fix is
   *  safe locally either way, per that module's own contract. */
  private async backUpFixBranch(branchName: string, appSlug: string): Promise<string | undefined> {
    const record = this.provenanceStore.provenanceForAppSlug(appSlug);
    if (record === null || record.clonePath === null || record.canonicalRepo === null) {
      return undefined;
    }
    const runner = createWindowsMaintainShellRunner(record.clonePath);
    if (runner === undefined) {
      return undefined;
    }

    const propagation = await this.gitHubForkService.propagateFix({
      branch: branchName,
      canonicalRepo: record.canonicalRepo,
      diagnosisTitle: this.coordinator.currentLastConfirmedDiagnosisTitle() ?? `Fix for ${appSlug}`,
      cloneRunner: runner,
    });
    switch (propagation.type) {
      case "merged_to_canonical":
        return `Merged straight into ${propagation.repo}`;
      case "pull_request_opened":
        return `Opened a fix PR (#${propagation.number}) on ${appSlug}'s repo for its owner to review`;
      case "backed_up_only":
        return `Backed up to your fork (${propagation.branch})`;
      case "not_connected":
      case "failed":
        // Not connected / a transient failure — no summary line, never an
        // error surfaced to the user. See the module header.
        return undefined;
    }
  }

  private userDataPath(): string {
    return app.isReady() ? app.getPath("userData") : path.join(process.env.APPDATA || process.env.HOME || ".", "iris");
  }
}
