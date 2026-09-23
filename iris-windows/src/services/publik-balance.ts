/**
 * publik-balance.ts
 *
 * What the user has left on publik API, what one message costs there, and the
 * one place "Add credit" goes. Founder decision, 2026-09-22: the balance and an
 * Add credit button live in Iris itself, not only on the dashboard.
 *
 * Pure, like `publik-api.ts`: the one network call here takes its `fetch` as a
 * parameter, so the whole file is reachable from `tests/publik-balance.test.ts`.
 * `main/publik-setup.ts` owns the timing (launch, a window opening, after a
 * reply) and the renderers own the drawing.
 *
 * This mirrors `iris-macos/leanring-buddy/PublikAPIBalance.swift`. One
 * difference is deliberate: this client asks the gateway for NON-streaming
 * answers, and a non-streaming answer is settled before its headers are
 * written, so `x-publik-charge-micros` and `x-publik-balance` on it are the
 * real charge and the real balance after it (CONTRACT section 11.6). The Mac
 * streams, gets neither, and prices the reply from the stream's usage instead.
 *
 * Copy rule (CONTRACT.md section 12 item 5): dollars and "publik API", never
 * tokens and never "credits" — the one exception is the button label
 * "Add credit", which the founder chose.
 */

import {
  AssistantTransport,
  makeBalanceRequest,
} from "./assistant-transport";
import {
  PublikClaimState,
  PublikModelAlias,
  formatMicrosAsDollars,
} from "./publik-api";

// MARK: - Tier prices

/**
 * What publik charges per million tokens on each tier, in micros. A copy of the
 * gateway's own rows (`lib/publik-api/pricing/sheet.ts` in the publik repo,
 * `priceFactor` 1.0). Used only for the "typical message" figure shown before
 * the first reply; every real charge comes from the gateway's own header.
 */
export const PUBLIK_TIER_PRICES: Readonly<
  Record<PublikModelAlias, { inputMicrosPerMillion: number; outputMicrosPerMillion: number }>
> = {
  "publik-fast": { inputMicrosPerMillion: 200_000, outputMicrosPerMillion: 1_200_000 },
  "publik-balanced": { inputMicrosPerMillion: 2_000_000, outputMicrosPerMillion: 12_000_000 },
  "publik-smart": { inputMicrosPerMillion: 4_000_000, outputMicrosPerMillion: 20_000_000 },
};

/** The message the typical figure is quoted for: 2,000 tokens in, 500 out. */
export const TYPICAL_MESSAGE_INPUT_TOKENS = 2_000;
export const TYPICAL_MESSAGE_OUTPUT_TOKENS = 500;

/** `Math.round(tokens × rate / 1,000,000)` per part, the way the gateway rounds. */
export function typicalMessageChargeMicros(modelAlias: PublikModelAlias): number {
  const price = PUBLIK_TIER_PRICES[modelAlias];
  return (
    Math.round((TYPICAL_MESSAGE_INPUT_TOKENS * price.inputMicrosPerMillion) / 1_000_000) +
    Math.round((TYPICAL_MESSAGE_OUTPUT_TOKENS * price.outputMicrosPerMillion) / 1_000_000)
  );
}

// MARK: - Money, in words

/**
 * Under a quarter the balance line turns into a warning and "Add credit"
 * becomes the loud button. A quarter is a couple of dozen messages on the
 * default tier: enough warning to act, not so early that it nags.
 */
export const LOW_BALANCE_THRESHOLD_MICROS = 250_000;

/** Strictly under the threshold. Exactly $0.25 is not yet low. */
export function balanceIsLow(balanceMicros: number): boolean {
  return balanceMicros < LOW_BALANCE_THRESHOLD_MICROS;
}

/** "$1.84 left". */
export function balanceLine(balanceMicros: number): string {
  return `${formatMicrosAsDollars(balanceMicros)} left`;
}

/**
 * A per-message price, to a tenth of a cent: "$0.004", "$0.010". Rounded to
 * the nearest tenth of a cent: this is what a message cost, not money the
 * user has. A cost too small to show at that precision says so instead of
 * reading "$0.000", which would look free.
 */
export function formatCostMicros(micros: number): string {
  if (!Number.isFinite(micros) || micros <= 0) return "$0.00";
  const tenthsOfACent = Math.round(micros / 1_000);
  if (tenthsOfACent === 0) return "under $0.001";
  const dollars = Math.floor(tenthsOfACent / 1_000);
  const remainder = String(tenthsOfACent % 1_000).padStart(3, "0");
  return `$${dollars}.${remainder}`;
}

/**
 * The one short line under the balance: what the last reply cost, or — before
 * there has been one — what a typical message costs on the tier Iris uses.
 */
export function costPerMessageLine(
  lastReplyChargeMicros: number | null,
  modelAlias: PublikModelAlias
): string {
  if (lastReplyChargeMicros !== null) {
    return `Last reply: ${formatCostMicros(lastReplyChargeMicros)}`;
  }
  return `About ${formatCostMicros(typicalMessageChargeMicros(modelAlias))} per message on ${modelAlias}`;
}

// MARK: - The one link

/** Used when the gateway named no page Iris will open. It asks the user to
 *  sign in, which is always a way forward. */
export const ADD_CREDIT_FALLBACK_URL = "https://publikhq.com/dashboard/api/add";

/**
 * A page on publik, over https, with no credentials in it. The same two hosts
 * `assistant-transport.ts` lets a publik key reach — a link opened in the
 * user's browser is checked even though the gateway named it.
 */
export function isPublikPage(candidate: string): boolean {
  try {
    const url = new URL(candidate);
    if (url.protocol !== "https:") return false;
    if (url.username || url.password) return false;
    const host = url.hostname.toLowerCase();
    return host === "publikhq.com" || host === "www.publikhq.com";
  } catch {
    return false;
  }
}

function firstPublikPage(candidates: Array<string | null | undefined>): string {
  for (const candidate of candidates) {
    if (candidate && isPublikPage(candidate)) return candidate;
  }
  return ADD_CREDIT_FALLBACK_URL;
}

/**
 * Where the balance row's "Add credit" goes: `top_up_url` first (the gateway
 * already chose the claim page while anonymous, the add-credit page once
 * claimed), else the page the claim state implies, else the add-credit page.
 * An anonymous install is not sent straight to add-credit while a claim page
 * exists, because credit added to an account this computer is not linked to
 * would not reach this key.
 */
export function addCreditUrlFor(balance: {
  claimState: PublikClaimState;
  claimUrl: string | null;
  addCreditUrl: string | null;
  topUpUrl: string | null;
}): string {
  return balance.claimState === "anonymous"
    ? firstPublikPage([balance.topUpUrl, balance.claimUrl, balance.addCreditUrl])
    : firstPublikPage([balance.topUpUrl, balance.addCreditUrl]);
}

/** Where a 402's "Add credit" goes: the one link the refusal named, through
 *  the same rules — so it and the balance row cannot disagree. */
export function addCreditUrlForRefusal(topUpUrl: string | null): string {
  return firstPublikPage([topUpUrl]);
}

// MARK: - Reading GET /balance

export interface PublikBalance {
  balanceMicros: number;
  claimState: PublikClaimState;
  claimUrl: string | null;
  addCreditUrl: string | null;
  topUpUrl: string | null;
}

function stringField(source: Record<string, unknown>, name: string): string | null {
  const value = source[name];
  return typeof value === "string" && value.length > 0 ? value : null;
}

/**
 * Reads one `GET /api/v1/balance` body. Null when it carries no balance at
 * all, so a malformed answer leaves the last good number on screen instead of
 * replacing it with $0.00.
 */
export function parseBalanceResponse(rawBody: string): PublikBalance | null {
  let parsed: Record<string, unknown>;
  try {
    const candidate: unknown = JSON.parse(rawBody);
    if (!candidate || typeof candidate !== "object") return null;
    parsed = candidate as Record<string, unknown>;
  } catch {
    return null;
  }

  // `available_micros` is the /balance alias of `balance_micros`; either is
  // accepted so a rename on one side does not blank the balance line.
  const balanceMicros = [parsed.available_micros, parsed.balance_micros].find(
    (value): value is number => typeof value === "number" && Number.isFinite(value)
  );
  if (balanceMicros === undefined) return null;

  return {
    balanceMicros,
    claimState: parsed.claim_state === "claimed" ? "claimed" : "anonymous",
    claimUrl: stringField(parsed, "claim_url"),
    addCreditUrl: stringField(parsed, "add_credit_url"),
    topUpUrl: stringField(parsed, "top_up_url"),
  };
}

/** The response shape `readPublikBalance` needs from a `fetch`. */
export type BalanceFetch = (
  url: string,
  init: { method: string; headers: Record<string, string> }
) => Promise<{ ok: boolean; text: () => Promise<string> }>;

/**
 * One `GET /balance` for the publik key. The request is built and checked by
 * `assistant-transport.ts` — still the only place a key is attached — so it
 * passes the same "a publik key only reaches publik" gate as every chat
 * request. Null on anything short of a readable balance.
 */
export async function readPublikBalance(
  transport: AssistantTransport,
  fetchImplementation: BalanceFetch
): Promise<PublikBalance | null> {
  try {
    const request = makeBalanceRequest(transport);
    const response = await fetchImplementation(request.url, {
      method: request.method,
      headers: request.headers,
    });
    if (!response.ok) return null;
    return parseBalanceResponse(await response.text());
  } catch {
    return null;
  }
}

// MARK: - What the UI draws

/**
 * Everything the tray, the settings panel and the chat title show about the
 * balance, in one value. Null whenever publik API is not the provider that
 * answers: a user on their own key or on codex sees nothing new.
 */
export interface PublikBalanceView {
  /** "$1.84 left", or null before any balance has been read. */
  balanceLine: string | null;
  isLow: boolean;
  costLine: string;
  addCreditUrl: string;
}

export function publikBalanceView(options: {
  answeringWithPublik: boolean;
  /** Null until the gateway has said anything about this key's balance. */
  balanceMicros: number | null;
  lastReplyChargeMicros: number | null;
  modelAlias: PublikModelAlias;
  claimState: PublikClaimState;
  claimUrl: string | null;
  addCreditUrl: string | null;
  topUpUrl: string | null;
}): PublikBalanceView | null {
  if (!options.answeringWithPublik) return null;
  return {
    balanceLine: options.balanceMicros === null ? null : balanceLine(options.balanceMicros),
    // Nothing is known to be low before the first balance has been read.
    isLow: options.balanceMicros !== null && balanceIsLow(options.balanceMicros),
    costLine: costPerMessageLine(options.lastReplyChargeMicros, options.modelAlias),
    addCreditUrl: addCreditUrlFor(options),
  };
}

/**
 * The tray's balance item: "publik API: $1.84 left". A menu item cannot be
 * coloured, so a low balance says so in words instead.
 */
export function publikBalanceMenuLabel(view: PublikBalanceView): string {
  if (!view.balanceLine) return "publik API";
  return view.isLow
    ? `publik API: ${view.balanceLine} — running low`
    : `publik API: ${view.balanceLine}`;
}

// MARK: - One reply, however many calls

/**
 * Adds up what one reply cost. A chat answer here is the query plus any
 * point-refinement calls it triggers, and "Last reply" means all of them.
 * Calls that belong to no reply (pointing at an autopilot gate) still move the
 * balance but never land in this line.
 */
export class PublikReplyCostTally {
  private replyInProgress: number | null = null;
  private nextReplyNumber = 1;
  private chargeOfTheReplyInProgress = 0;
  private lastReplyCharge: number | null = null;

  get lastReplyChargeMicros(): number | null {
    return this.lastReplyCharge;
  }

  beginAReply(): number {
    const replyNumber = this.nextReplyNumber;
    this.nextReplyNumber += 1;
    this.replyInProgress = replyNumber;
    this.chargeOfTheReplyInProgress = 0;
    return replyNumber;
  }

  /** Closes the reply only if it is still the current one, so a reply that
   *  finishes after its replacement began cannot close the new one. */
  finishTheReply(replyNumber: number): void {
    if (this.replyInProgress === replyNumber) this.replyInProgress = null;
  }

  addACall(chargeMicros: number): void {
    if (this.replyInProgress === null) return;
    this.chargeOfTheReplyInProgress += Math.max(0, chargeMicros);
    this.lastReplyCharge = this.chargeOfTheReplyInProgress;
  }

  forgetEverything(): void {
    this.replyInProgress = null;
    this.chargeOfTheReplyInProgress = 0;
    this.lastReplyCharge = null;
  }
}
