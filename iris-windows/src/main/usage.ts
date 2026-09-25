import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { SettingsStore } from "./settings";
import {
  type ConsentDocument,
  parseConsentDocument,
  readerHasAnsweredTheUsageDisclosure,
  serializeConsentDocument,
  storedInstallIdentifier,
  usageDisclosureHasBeenShown,
  usageSharingState,
  withInstallIdentifier,
  withUsageDisclosureShown,
  withUsageSharingChoice,
} from "../services/consent-file";
import {
  UsageMonitor,
  type UsageEvent,
  type UsageModelTier,
  type UsageProvider,
  makeUsageSender,
  modelTierForModelName,
} from "../services/usage-monitor";
import {
  type ComparisonOption,
  type ModelPriceComparison,
  comparisonForThisPc,
  parseModelPriceComparison,
} from "../services/model-price-comparison";
import { PublikApiNudgeSession, type PublikApiNudge } from "../services/publik-api-nudge";

/**
 * usage.ts
 *
 * The main-process side of three things that share one rule — nothing in them
 * may hold anything up (the Windows half of the macOS `UsageMonitor`,
 * `ModelPriceComparisonStore` and `PublikAPINudgeCoordinator`):
 *
 *   - anonymous usage counts, and the switch for them in the shared
 *     consent.json;
 *   - the price comparison, fetched from publik once per launch;
 *   - the session's one publik API nudge.
 *
 * Every decision is in `services/` and tested there; this file owns the file
 * path, the network, the timer and the settings keys.
 */

export interface UsageSharingView {
  state: "notYetDisclosed" | "sharing" | "notSharing";
  showDisclosure: boolean;
}

export interface PriceComparisonView {
  state: "loading" | "unavailable" | "loaded";
  assumption?: string;
  caveat?: string;
  options?: ComparisonOption[];
}

/** `%LOCALAPPDATA%\publik\consent.json` on Windows; the macOS path when a
 *  developer runs this build on a Mac, so both clients share one file there. */
export function consentFilePath(): string {
  if (process.platform === "win32") {
    const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
    return path.join(localAppData, "publik", "consent.json");
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "publik", "consent.json");
  }
  return path.join(os.homedir(), ".local", "share", "publik", "consent.json");
}

export class UsageAndPricing {
  private readonly settings: SettingsStore;
  private readonly broadcast: (channel: string, payload: unknown) => void;
  private readonly filePath = consentFilePath();
  private consent: ConsentDocument;
  private readonly monitor: UsageMonitor;
  private comparison: ModelPriceComparison | null = null;
  private comparisonState: "loading" | "unavailable" | "loaded" = "loading";
  private comparisonFetchInFlight = false;
  private readonly nudgeSession: PublikApiNudgeSession;
  /** The e2e run must never count as usage or reach publik with it. */
  private readonly disabledForThisRun: boolean;
  /** Catalog-app processes already counted this session, so a frontmost
   *  poll every 2 s counts a launch once. */
  private readonly catalogAppProcessesSeen = new Set<number>();
  private readonly currentProvider: () => UsageProvider | null;

  constructor(options: {
    settings: SettingsStore;
    broadcast: (channel: string, payload: unknown) => void;
    irisVersion: string;
    currentProvider: () => UsageProvider | null;
  }) {
    this.settings = options.settings;
    this.broadcast = options.broadcast;
    this.disabledForThisRun = process.env.IRIS_E2E === "1";
    this.consent = this.readConsentFile();

    const sender = makeUsageSender(this.publikBaseUrl(), (input, init) => fetch(input, init));
    this.monitor = new UsageMonitor({
      isSharingEnabled: () => !this.disabledForThisRun && usageSharingState(this.consent) === "sharing",
      installIdentifier: () => this.installIdentifier(),
      irisVersion: options.irisVersion,
      operatingSystem: "windows",
      sendBatch: sender.sendBatch,
      eraseEverythingSent: sender.eraseEverythingSent,
    });

    this.nudgeSession = new PublikApiNudgeSession({
      nowMs: () => Date.now(),
      lastDismissedAtMs: () => {
        const stored = this.settings.get("publikNudgeLastDismissedAt");
        return stored > 0 ? stored : null;
      },
      recordDismissal: (atMs) => this.settings.set("publikNudgeLastDismissedAt", atMs),
      currentProvider: options.currentProvider,
      comparisonOptions: () => this.comparisonForThisPc()?.options ?? null,
      onChange: (nudge) => this.broadcast("nudge:changed", nudge),
    });
    this.currentProvider = options.currentProvider;
  }

  start(): void {
    if (!this.disabledForThisRun) this.monitor.start();
    this.loadComparisonIfNeeded();
  }

  stop(): void {
    this.monitor.stop();
  }

  // MARK: - The switch

  usageSharingView(): UsageSharingView {
    return {
      state: this.disabledForThisRun ? "notSharing" : usageSharingState(this.consent),
      showDisclosure: !this.disabledForThisRun && !readerHasAnsweredTheUsageDisclosure(this.consent),
    };
  }

  /** The disclosure is on screen: from now the default (ON) is in force. */
  disclosureWasShown(): UsageSharingView {
    if (!this.disabledForThisRun && !usageDisclosureHasBeenShown(this.consent)) {
      this.writeConsent(withUsageDisclosureShown(this.consent, randomUUID, new Date()));
    }
    return this.usageSharingView();
  }

  /** Continue, Turn off, or the settings switch. */
  setSharing(sharingOn: boolean): UsageSharingView {
    const wasSharing = usageSharingState(this.consent) === "sharing";
    this.writeConsent(withUsageSharingChoice(this.consent, sharingOn, randomUUID, new Date()));
    if (wasSharing && !sharingOn) this.monitor.sharingWasTurnedOff();
    const view = this.usageSharingView();
    this.broadcast("usage:changed", view);
    return view;
  }

  // MARK: - Counting (every one returns at once)

  record(event: UsageEvent): void {
    this.monitor.record(event);
  }

  /** A chat question is about to go out: one count, and nudge decision point (b). */
  anAICallIsGoingOut(): void {
    this.monitor.record({ kind: "ai_call", provider: this.currentProvider(), modelTier: this.currentTier() });
    this.nudgeSession.anAICallIsGoingOut();
  }

  /** A provider or model was picked: one count, and nudge decision point (a). */
  readerPickedAProviderOrModel(): void {
    this.monitor.record({ kind: "model_selected", provider: this.currentProvider(), modelTier: this.currentTier() });
    this.nudgeSession.readerPickedAProviderOrModel();
  }

  /** Maintain mode's frontmost poll saw one of ours. A process id not seen
   *  before this session is a launch. */
  catalogAppIsFrontmost(slug: string, processId: number): void {
    if (this.catalogAppProcessesSeen.has(processId)) return;
    this.catalogAppProcessesSeen.add(processId);
    this.monitor.record({ kind: "app_opened", appSlug: slug });
  }

  /**
   * publik API is always asked for `publik-balanced` on this client; the own
   * key's tier follows the picked model; codex runs whatever the CLI is set to,
   * which Iris does not know, so no tier is claimed for it.
   */
  private currentTier(): UsageModelTier | null {
    const provider = this.currentProvider();
    if (provider === "publik-api") return "balanced";
    if (provider === "anthropic-key") return modelTierForModelName(this.settings.get("claudeModel"));
    return null;
  }

  // MARK: - The nudge

  visibleNudge(): PublikApiNudge | null {
    return this.nudgeSession.visibleNudge;
  }

  dismissNudge(): void {
    this.nudgeSession.dismiss();
  }

  nudgeActedOn(): void {
    this.nudgeSession.readerActedOnIt();
  }

  // MARK: - The price comparison

  priceComparisonView(): PriceComparisonView {
    if (this.comparisonState !== "loaded") return { state: this.comparisonState };
    const forThisPc = this.comparisonForThisPc();
    if (!forThisPc) return { state: "unavailable" };
    return {
      state: "loaded",
      assumption: forThisPc.assumption.summary,
      caveat: forThisPc.caveat,
      options: forThisPc.options,
    };
  }

  /** Fetched once per launch; a failure is retried the next time settings opens. */
  loadComparisonIfNeeded(): Promise<PriceComparisonView> {
    if (this.comparisonState === "loaded" || this.comparisonFetchInFlight) {
      return Promise.resolve(this.priceComparisonView());
    }
    this.comparisonFetchInFlight = true;
    this.comparisonState = "loading";
    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort(), 10_000);
    return fetch(`${this.publikBaseUrl()}/api/iris/model-prices`, {
      headers: { Accept: "application/json" },
      signal: abort.signal,
    })
      .then(async (response) => (response.ok ? parseModelPriceComparison(await response.json()) : null))
      .catch(() => null)
      .then((parsed) => {
        clearTimeout(timeout);
        this.comparisonFetchInFlight = false;
        this.comparison = parsed;
        this.comparisonState = parsed ? "loaded" : "unavailable";
        const view = this.priceComparisonView();
        this.broadcast("prices:changed", view);
        return view;
      });
  }

  private comparisonForThisPc() {
    return this.comparison ? comparisonForThisPc(this.comparison, this.settings.get("claudeModel")) : null;
  }

  // MARK: - consent.json

  private publikBaseUrl(): string {
    return this.settings.get("publikBaseUrl").replace(/\/+$/, "");
  }

  private installIdentifier(): string {
    const stored = storedInstallIdentifier(this.consent);
    if (stored) return stored;
    this.writeConsent(withInstallIdentifier(this.consent, randomUUID, new Date()));
    return storedInstallIdentifier(this.consent) ?? randomUUID();
  }

  private readConsentFile(): ConsentDocument {
    try {
      return parseConsentDocument(fs.readFileSync(this.filePath, "utf-8"));
    } catch {
      return {};
    }
  }

  private writeConsent(next: ConsentDocument): void {
    // The in-memory answer is in force for this launch even if the write
    // fails; nothing about Iris depends on the file being written.
    this.consent = next;
    try {
      fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
      fs.writeFileSync(this.filePath, serializeConsentDocument(next));
    } catch {
      // Silent, like every settings write.
    }
  }
}
