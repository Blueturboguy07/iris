/**
 * The one place Iris suggests publik API to somebody using another provider —
 * the Windows half of `PublikAPINudge.swift`, held to the same founder-approved
 * policy (2026-09-25):
 *
 *   - At most ONE nudge per session (a launch of Iris).
 *   - Only at the decision points: (a) the reader picks a provider or a model;
 *     (b) the first AI call on a provider that is not publik API.
 *   - "Not now" silences every nudge for 7 days, and that survives a relaunch.
 *   - Never modal and never in the way: an inline card; the question the
 *     reader asked goes out exactly as it would have.
 *
 * (c), a MEASURED cost crossing a threshold, is not implemented on Windows,
 * and deliberately not faked: this client does not read the token usage an
 * Anthropic response reports (there is no spend ledger here, unlike macOS's
 * `AssistantSpendLedger`), so there is no measured cost to cross anything.
 * A ChatGPT plan is flat-rate on either platform, so it would never apply there.
 *
 * (b) has no app context on Windows: the chat window cannot see which catalog
 * app the reader was in, so "the first AI call in an app" is the first call
 * of the session. It only ever makes the nudge rarer, never more frequent.
 *
 * What a nudge may say: only numbers from publik's price comparison. With the
 * comparison not loaded there is no nudge. On the own-key route there is no
 * nudge while publik lists above the reader's model, and it always says a
 * different model answers on publik API.
 */

import type { ComparisonOption } from "./model-price-comparison";
import type { UsageProvider } from "./usage-monitor";

export type NudgeDecisionPoint = "modelSelection" | "firstAICall";

export const QUIET_PERIOD_AFTER_DISMISSAL_MS = 7 * 24 * 60 * 60 * 1000;

export interface PublikApiNudge {
  decisionPoint: NudgeDecisionPoint;
  headline: string;
  detail: string;
}

/** Whether a nudge may appear at all right now. */
export function mayNudge(options: {
  provider: UsageProvider | null;
  hasAlreadyNudgedThisSession: boolean;
  lastDismissedAtMs: number | null;
  nowMs: number;
}): boolean {
  if (options.provider !== "anthropic-key" && options.provider !== "codex") return false;
  if (options.hasAlreadyNudgedThisSession) return false;
  return !isQuiet(options.lastDismissedAtMs, options.nowMs);
}

/** Inside the 7 days after a dismissal. A clock set backwards still counts as quiet. */
export function isQuiet(lastDismissedAtMs: number | null, nowMs: number): boolean {
  if (lastDismissedAtMs === null || lastDismissedAtMs <= 0) return false;
  return nowMs - lastDismissedAtMs < QUIET_PERIOD_AFTER_DISMISSAL_MS;
}

function dollars(value: number): string {
  return `$${value.toFixed(2)}`;
}

/** The words, or null when there is nothing true and specific to say. */
export function composeNudge(options: {
  decisionPoint: NudgeDecisionPoint;
  provider: UsageProvider | null;
  comparisonOptions: ComparisonOption[] | null;
}): PublikApiNudge | null {
  const publik = options.comparisonOptions?.find((option) => option.provider === "publik-api");
  if (!publik || publik.inputUsdPerMillion === null || publik.outputUsdPerMillion === null) return null;
  const publikPrice = `${dollars(publik.inputUsdPerMillion)} in / ${dollars(publik.outputUsdPerMillion)} out per 1M tokens`;
  const answeredBy = publik.servedBy ? ` (${publik.servedBy} answers)` : "";

  if (options.provider === "anthropic-key") {
    const key = options.comparisonOptions?.find((option) => option.provider === "anthropic-key");
    if (!key || key.inputUsdPerMillion === null || key.outputUsdPerMillion === null) return null;
    if (publik.inputUsdPerMillion > key.inputUsdPerMillion || publik.outputUsdPerMillion > key.outputUsdPerMillion) return null;
    return {
      decisionPoint: options.decisionPoint,
      headline: `publik API at this tier: ${publikPrice}`,
      detail:
        `${publik.model}${answeredBy}: ${publikPrice}. Your key's ${key.model}: ` +
        `${dollars(key.inputUsdPerMillion)} / ${dollars(key.outputUsdPerMillion)}. A different model answers on publik API.`,
    };
  }
  if (options.provider === "codex") {
    // Flat-rate: no price is compared against a plan the reader already pays
    // for, and no advantage is claimed that this client does not have (chat
    // sends no tools on any Windows route). Just the two billing facts.
    return {
      decisionPoint: options.decisionPoint,
      headline: `publik API at this tier: ${publikPrice}`,
      detail:
        `You are on your ChatGPT plan, which costs nothing extra per question. publik API bills per use instead: ` +
        `${publik.model}${answeredBy}.`,
    };
  }
  return null;
}

/**
 * The session's one nudge. The main process owns one; the dismissal time is
 * persisted through the injected pair so it survives a relaunch.
 */
export class PublikApiNudgeSession {
  private visible: PublikApiNudge | null = null;
  private nudgedThisSession = false;
  private anAICallHasGoneOutThisSession = false;

  constructor(
    private readonly seams: {
      nowMs: () => number;
      lastDismissedAtMs: () => number | null;
      recordDismissal: (atMs: number) => void;
      currentProvider: () => UsageProvider | null;
      comparisonOptions: () => ComparisonOption[] | null;
      onChange?: (nudge: PublikApiNudge | null) => void;
    }
  ) {}

  get visibleNudge(): PublikApiNudge | null {
    return this.visible;
  }

  get hasNudgedThisSession(): boolean {
    return this.nudgedThisSession;
  }

  /** (a) A provider or model was picked. */
  readerPickedAProviderOrModel(): void {
    if (this.seams.currentProvider() === "publik-api") {
      this.setVisible(null);
      return;
    }
    this.consider("modelSelection");
  }

  /** (b) Called for every call; only the session's first is a decision point. */
  anAICallIsGoingOut(): void {
    const isFirst = !this.anAICallHasGoneOutThisSession;
    this.anAICallHasGoneOutThisSession = true;
    if (!isFirst || this.seams.currentProvider() === "publik-api") return;
    this.consider("firstAICall");
  }

  /** "Not now": gone, and every nudge stays away for 7 days. */
  dismiss(): void {
    this.seams.recordDismissal(this.seams.nowMs());
    this.setVisible(null);
  }

  /** "Compare" / "Use publik API": gone for this session, no 7-day quiet. */
  readerActedOnIt(): void {
    this.setVisible(null);
  }

  private consider(decisionPoint: NudgeDecisionPoint): void {
    const provider = this.seams.currentProvider();
    if (
      !mayNudge({
        provider,
        hasAlreadyNudgedThisSession: this.nudgedThisSession,
        lastDismissedAtMs: this.seams.lastDismissedAtMs(),
        nowMs: this.seams.nowMs(),
      })
    ) {
      return;
    }
    const nudge = composeNudge({ decisionPoint, provider, comparisonOptions: this.seams.comparisonOptions() });
    if (!nudge) return;
    this.nudgedThisSession = true;
    this.setVisible(nudge);
  }

  private setVisible(nudge: PublikApiNudge | null): void {
    this.visible = nudge;
    this.seams.onChange?.(nudge);
  }
}
