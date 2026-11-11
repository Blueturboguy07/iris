/**
 * publik-setup.ts
 *
 * The main-process side of publik API: the key this install uses, the
 * balance, and what each reply cost. The install itself comes from the publik
 * module (`./publik`). Its gate runs at start-up (`main/index.ts`) and makes
 * this computer's key, so nothing here mints an install of its own.
 *
 * CONTRACT.md section 12 (4) is enforced here rather than in the renderer:
 * "an app must not consume the starter without having shown (a)–(c) at least
 * once". `publikCardHasBeenShown` gates spending, not just drawing. The gate's
 * plan screen shows the plan or the balance before the person connects it, so
 * Connect your plan marks the card as shown.
 */

import { SettingsStore } from "./settings";
import { PublikCredential, provision as provisionWithPublik, readCredential, setChoice } from "./publik";
import {
  DEFAULT_PUBLIK_MODEL,
  PublikCardState,
  PublikUsageSnapshot,
  looksLikeAPublikApiKey,
  publikCardState,
} from "../services/publik-api";
import {
  PublikBalance,
  PublikBalanceView,
  PublikReplyCostTally,
  publikBalanceView,
  readPublikBalance,
} from "../services/publik-balance";

/**
 * How long to wait after a reply that carried no settled charge before reading
 * the balance back: the gateway settles such a call after its last byte, and
 * asking at once would read the balance with the call's hold still taken out.
 */
const BALANCE_REFRESH_DELAY_AFTER_A_REPLY_MS = 1_500;

/** What `provision()` reports to the window that asked. */
export type ProvisioningOutcome =
  | { kind: "provisioned" }
  /** publik answered, but not with a key this computer can use. */
  | { kind: "refused"; message: string }
  | { kind: "networkFailure" };

/** True for an error that means publik did not answer at all. The same test the module uses. */
function publikWasNotReachable(error: unknown): boolean {
  return error instanceof TypeError || (error instanceof Error && /abort|timeout/i.test(error.name));
}

export class PublikSetup {
  private readonly settings: SettingsStore;
  /** Adds the calls of one chat answer together for "Last reply". */
  private readonly replyCostTally = new PublikReplyCostTally();
  /** The one pending balance read after a reply; replaced, not stacked. */
  private pendingBalanceRefresh: ReturnType<typeof setTimeout> | null = null;
  /** A read already on the wire, shared by anyone who asks meanwhile. */
  private balanceReadInFlight: Promise<boolean> | null = null;
  private readonly balanceListeners = new Set<() => void>();

  constructor(settings: SettingsStore) {
    this.settings = settings;
  }

  /** True when this install already has a key and needs no provisioning. */
  hasKey(): boolean {
    return Boolean(this.settings.getPublikApiKey());
  }

  /**
   * The machine route, from the settings page, the chat window or the
   * first-run window. The gate made this computer's install at start-up, so
   * this adopts the module's credential. It provisions again only when the
   * credential file is gone. The person pressed a button under the disclosure,
   * so the stored choice becomes "publik".
   */
  async provision(): Promise<ProvisioningOutcome> {
    let credential: PublikCredential;
    try {
      credential = readCredential() ?? (await provisionWithPublik());
    } catch (error) {
      if (publikWasNotReachable(error)) return { kind: "networkFailure" };
      return { kind: "refused", message: error instanceof Error ? error.message : String(error) };
    }
    if (!this.connectThePlan(credential.key)) {
      return {
        kind: "refused",
        message: "Windows will not let Iris encrypt stored secrets on this machine, so the key cannot be saved safely.",
      };
    }
    setChoice("publik");
    return { kind: "provisioned" };
  }

  /**
   * After Connect your plan, at the gate or here: the module's install key is
   * the publik API key. The gate showed the plan or the balance before the
   * person agreed, so the card counts as shown. A key pasted in Settings is
   * replaced: the choice "publik" means the install key. Returns false when
   * Windows refused to store the key.
   */
  connectThePlan(installKey: string): boolean {
    if (this.settings.getPublikApiKey() !== installKey) {
      if (!this.settings.setPublikApiKey(installKey)) return false;
      // Whatever was known about the balance belonged to the key this replaced.
      this.forgetTheBalance();
    }
    const credential = readCredential();
    if (credential?.key === installKey) this.honourAMovedGateway(credential.base_url);
    this.settings.set("publikCardHasBeenShown", true);
    void this.refreshBalance();
    return true;
  }

  /**
   * The gateway is allowed to move (CONTRACT section 1 [S8]). Only a publik
   * origin is honoured: an unexpected host here would be the one input that
   * could aim a key somewhere else, and `assistant-transport` would refuse
   * the request anyway, so it is dropped rather than stored.
   */
  private honourAMovedGateway(baseUrl: string): void {
    try {
      const movedTo = new URL(baseUrl);
      if (/(^|\.)publikhq\.com$/i.test(movedTo.hostname)) {
        this.settings.set("publikBaseUrl", movedTo.origin);
      }
    } catch {
      // Keep the compiled default.
    }
  }

  /** Settings: Clear. The key goes, and the gate asks again at the next start. */
  forgetTheKey(): boolean {
    this.settings.setPublikApiKey("");
    this.forgetTheBalance();
    setChoice(null);
    return true;
  }

  /** The human route: a key pasted from publikhq.com/dashboard/api. */
  acceptPastedKey(pastedKey: string): boolean {
    const trimmed = pastedKey.trim();
    if (!looksLikeAPublikApiKey(trimmed)) return false;
    if (!this.settings.setPublikApiKey(trimmed)) return false;
    // A pasted key belongs to an account that already exists, so there is no
    // starter to disclose and nothing for the first-run card to gate.
    this.settings.set("publikCardHasBeenShown", true);
    // Whatever was known about the balance belonged to the key this replaced.
    this.forgetTheBalance();
    void this.refreshBalance();
    return true;
  }

  /** What the §12 card should render right now. */
  cardState(): PublikCardState {
    return publikCardState({
      balanceMicros: this.settings.get("publikBalanceMicros"),
      claimState: this.settings.get("publikClaimState") === "claimed" ? "claimed" : "anonymous",
      claimUrl: this.settings.get("publikClaimUrl") || null,
      addCreditUrl: this.settings.get("publikAddCreditUrl") || null,
    });
  }

  markCardShown(): void {
    this.settings.set("publikCardHasBeenShown", true);
  }

  /**
   * CONTRACT section 12 (4). A provisioned install whose card has never been
   * shown must not spend its balance, so this is checked before a request, not
   * only before a paint.
   */
  maySpendStarter(): boolean {
    return this.settings.get("publikCardHasBeenShown");
  }

  // MARK: - The balance, and what each reply cost

  /** Told whenever anything the balance view shows may have changed. */
  onBalanceChanged(listener: () => void): () => void {
    this.balanceListeners.add(listener);
    return () => this.balanceListeners.delete(listener);
  }

  private notifyBalanceChanged(): void {
    for (const listener of this.balanceListeners) listener();
  }

  /**
   * What the tray, the settings panel and the chat title show, or null when
   * publik API is not the provider answering (a user on their own key or on
   * codex sees nothing new). The chat route always asks for the default alias,
   * so that is the tier the typical figure is quoted for.
   */
  balanceView(answeringWithPublik: boolean): PublikBalanceView | null {
    return publikBalanceView({
      answeringWithPublik: answeringWithPublik && this.hasKey(),
      balanceMicros: this.settings.get("publikBalanceSeen") ? this.settings.get("publikBalanceMicros") : null,
      lastReplyChargeMicros: this.replyCostTally.lastReplyChargeMicros,
      modelAlias: DEFAULT_PUBLIK_MODEL,
      claimState: this.settings.get("publikClaimState") === "claimed" ? "claimed" : "anonymous",
      claimUrl: this.settings.get("publikClaimUrl") || null,
      addCreditUrl: this.settings.get("publikAddCreditUrl") || null,
      topUpUrl: this.settings.get("publikTopUpUrl") || null,
    });
  }

  /**
   * Reads `GET /balance` and keeps what it says. False — and the last good
   * number left in place — on anything short of a readable balance: a line
   * that blanked or dropped to $0.00 because one read failed would tell the
   * user something false about their money.
   */
  refreshBalance(): Promise<boolean> {
    if (this.balanceReadInFlight) return this.balanceReadInFlight;
    const publikApiKey = this.settings.getPublikApiKey();
    if (!publikApiKey) return Promise.resolve(false);

    this.balanceReadInFlight = readPublikBalance(
      { tier: "publik", publikApiKey, apiBaseUrl: this.settings.getPublikApiBaseUrl() },
      async (url, init) => {
        const response = await fetch(url, init);
        return { ok: response.ok, text: () => response.text() };
      }
    )
      .then((balance) => {
        if (!balance) return false;
        this.storeBalance(balance);
        this.notifyBalanceChanged();
        return true;
      })
      .finally(() => {
        this.balanceReadInFlight = null;
      });
    return this.balanceReadInFlight;
  }

  /** Reads the balance once the gateway has had time to settle the call that
   *  just finished. A second call inside the delay replaces the first. */
  refreshBalanceSoon(): void {
    if (this.pendingBalanceRefresh) clearTimeout(this.pendingBalanceRefresh);
    this.pendingBalanceRefresh = setTimeout(() => {
      this.pendingBalanceRefresh = null;
      void this.refreshBalance();
    }, BALANCE_REFRESH_DELAY_AFTER_A_REPLY_MS);
  }

  private storeBalance(balance: PublikBalance): void {
    this.settings.set("publikBalanceMicros", balance.balanceMicros);
    this.settings.set("publikBalanceSeen", true);
    this.settings.set("publikClaimState", balance.claimState);
    this.settings.set("publikTopUpUrl", balance.topUpUrl ?? "");
    if (balance.claimUrl) this.settings.set("publikClaimUrl", balance.claimUrl);
    if (balance.addCreditUrl) this.settings.set("publikAddCreditUrl", balance.addCreditUrl);
  }

  private forgetTheBalance(): void {
    this.settings.set("publikBalanceSeen", false);
    this.settings.set("publikBalanceMicros", 0);
    this.settings.set("publikTopUpUrl", "");
    this.replyCostTally.forgetEverything();
    this.notifyBalanceChanged();
  }

  /** Starts adding up one chat answer; hand the number back to finish it. */
  beginCountingAReply(): number {
    return this.replyCostTally.beginAReply();
  }

  finishCountingTheReply(replyNumber: number): void {
    this.replyCostTally.finishTheReply(replyNumber);
  }

  /**
   * What one metered response's `x-publik-*` headers said. A settled answer
   * carries its charge and the balance after it, so nothing more is needed; a
   * response without a charge (a refusal, or a stream) has a balance header
   * that may predate settlement, so the balance is read back shortly after.
   */
  recordUsage(usage: PublikUsageSnapshot): void {
    if (usage.balanceMicros !== null) {
      this.settings.set("publikBalanceMicros", usage.balanceMicros);
      this.settings.set("publikBalanceSeen", true);
    }
    if (usage.claimState !== null) this.settings.set("publikClaimState", usage.claimState);
    if (usage.chargeMicros !== null) {
      this.replyCostTally.addACall(usage.chargeMicros);
    } else {
      this.refreshBalanceSoon();
    }
    this.notifyBalanceChanged();
  }
}
