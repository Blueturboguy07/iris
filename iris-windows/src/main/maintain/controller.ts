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
 * NOT wired here, flagged rather than silently skipped (porting spec §5):
 *
 *   - Real crash/hang/launch-failure SIGNAL SOURCES. `services/maintain/crash-watcher.ts`
 *     (`CrashArtifactWatcher`) and `services/maintain/hang-probe.ts` (`HangProbe` +
 *     `checkProcessResponsiveViaPowerShell`) already exist as pure/real pairs
 *     in this repo, but nothing here constructs or starts them, for a concrete
 *     reason and not an oversight: `CrashArtifactWatcher` needs a
 *     `CrashArtifactAppMatching` table (process name → catalog slug/stack),
 *     and there is currently no Windows catalog app anywhere in this repo with
 *     a known `.exe` launch target to build that table from —
 *     `services/autopilot/recipes.ts`'s one built-in recipe (OpenASCII) is a
 *     `local_web` app with no exe at all (porting spec §5 gap 4). A live
 *     watcher wired to zero real entries would be worse than not wiring one.
 *     This controller instead exposes `reportNativeCrash`/`reportConfirmedHang`/
 *     `reportLaunchFailure` — the exact call shape a real watcher will use
 *     once a Windows catalog app with a known exe exists — plus a narrow,
 *     env-var-gated manual trigger (`triggerDemoIncidentIfConfigured`) that
 *     proves the whole ladder end to end today, the same way
 *     `IRIS_AUTOPILOT_DEMO` proves the autopilot end to end with no real
 *     guide click.
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
 *   - `install-provenance.ts`'s own interlock: nothing here calls
 *     `InstallProvenanceStore.recordGuideSourceClone` on a successful
 *     autopilot install finish (`main/autopilot-controller.ts`'s
 *     `onFinished`) — that interlock needs `services/autopilot/recipe.ts`'s
 *     `InstallRecipe`/`RecipeOutput` to carry a `canonicalRepo` field first,
 *     per that module's own header, and is out of this file's ownership.
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
import { defaultVerificationCommandsForStack } from "../../services/maintain/incoming-fix-reviewer";
import { MaintainInstallIdentity } from "../../services/maintain/install-identity";
import { InstallProvenanceStore } from "../../services/maintain/install-provenance";
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
