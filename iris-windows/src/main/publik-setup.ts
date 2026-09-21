/**
 * publik-setup.ts
 *
 * The main-process side of setting up publik API: it owns the Electron-flavoured
 * pieces (randomness, the app's version, storing the key) and delegates every
 * decision to `services/publik-provisioning.ts`, which is where the suite can
 * reach it.
 *
 * CONTRACT.md section 12 (4) is enforced here rather than in the renderer:
 * "an app must not consume the starter without having shown (a)–(c) at least
 * once". `publikCardHasBeenShown` gates spending, not just drawing — a card the
 * user closed before it painted must not be treated as shown.
 */

import { app } from "electron";
import { randomBytes } from "node:crypto";
import * as os from "node:os";
import { SettingsStore } from "./settings";
import { publikAppToken } from "./publik-app-token";
import {
  ProvisioningOutcome,
  provisionPublikInstall,
} from "../services/publik-provisioning";
import { PublikCardState, looksLikeAPublikApiKey, publikCardState } from "../services/publik-api";

export class PublikSetup {
  private readonly settings: SettingsStore;

  constructor(settings: SettingsStore) {
    this.settings = settings;
  }

  /** True when this install already has a key and needs no provisioning. */
  hasKey(): boolean {
    return Boolean(this.settings.getPublikApiKey());
  }

  /**
   * Runs the machine route. The caller must have shown the disclosure and got
   * consent first — CONTRACT section 3.2 [S4], "consent precedes mint".
   */
  async provision(): Promise<ProvisioningOutcome> {
    const outcome = await provisionPublikInstall({
      apiBaseUrl: this.settings.getPublikApiBaseUrl(),
      appToken: publikAppToken(),
      alreadyHoldsAKey: this.hasKey(),
      seams: {
        fetchImplementation: async (url, init) => {
          const response = await fetch(url, {
            method: init.method,
            headers: init.headers,
            body: init.body,
          });
          return { status: response.status, text: () => response.text() };
        },
        randomBytes: (byteCount) => new Uint8Array(randomBytes(byteCount)),
        readStoredInstallId: () => this.settings.get("publikInstallId") || null,
        writeStoredInstallId: (installId) => this.settings.set("publikInstallId", installId),
        appVersion: app.getVersion(),
        osVersion: os.release(),
        arch: process.arch,
        deviceName: os.hostname(),
      },
    });

    if (outcome.kind === "provisioned") this.storeProvisionedInstall(outcome);
    return outcome;
  }

  private storeProvisionedInstall(outcome: Extract<ProvisioningOutcome, { kind: "provisioned" }>): void {
    const { install } = outcome;
    if (install.apiKey) this.settings.setPublikApiKey(install.apiKey);
    if (install.claimUrl) this.settings.set("publikClaimUrl", install.claimUrl);
    if (install.addCreditUrl) this.settings.set("publikAddCreditUrl", install.addCreditUrl);
    this.settings.set("publikClaimState", install.claimState);
    if (install.starterMicros > 0) this.settings.set("publikStarterMicros", install.starterMicros);
    if (install.balanceMicros > 0) this.settings.set("publikBalanceMicros", install.balanceMicros);

    // The gateway is allowed to move (CONTRACT section 1 [S8]). Only a publik
    // origin is honoured — an unexpected host here would be the one input that
    // could aim a key somewhere else, and `assistant-transport` would refuse
    // the request anyway, so it is dropped rather than stored.
    if (install.baseUrl) {
      try {
        const movedTo = new URL(install.baseUrl);
        if (/(^|\.)publikhq\.com$/i.test(movedTo.hostname)) {
          this.settings.set("publikBaseUrl", movedTo.origin);
        }
      } catch {
        // Keep the compiled default.
      }
    }
  }

  /** The human route: a key pasted from publikhq.com/dashboard/api. */
  acceptPastedKey(pastedKey: string): boolean {
    const trimmed = pastedKey.trim();
    if (!looksLikeAPublikApiKey(trimmed)) return false;
    if (!this.settings.setPublikApiKey(trimmed)) return false;
    // A pasted key belongs to an account that already exists, so there is no
    // starter to disclose and nothing for the first-run card to gate.
    this.settings.set("publikCardHasBeenShown", true);
    return true;
  }

  /** What the §12 card should render right now. */
  cardState(isFirstRun: boolean): PublikCardState {
    return publikCardState({
      balanceMicros: this.settings.get("publikBalanceMicros"),
      starterMicros: this.settings.get("publikStarterMicros"),
      claimState: this.settings.get("publikClaimState") === "claimed" ? "claimed" : "anonymous",
      claimUrl: this.settings.get("publikClaimUrl") || null,
      addCreditUrl: this.settings.get("publikAddCreditUrl") || null,
      isFirstRun,
    });
  }

  markCardShown(): void {
    this.settings.set("publikCardHasBeenShown", true);
  }

  /**
   * CONTRACT section 12 (4). A provisioned install whose card has never been
   * shown must not spend its starter, so this is checked before a request, not
   * only before a paint.
   */
  maySpendStarter(): boolean {
    return this.settings.get("publikCardHasBeenShown");
  }
}
