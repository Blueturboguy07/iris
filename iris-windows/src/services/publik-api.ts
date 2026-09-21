/**
 * publik-api.ts
 *
 * The publik API gateway, as this app sees it. Pure: every network call is the
 * caller's to make, so the whole file is reachable from the vitest suite.
 *
 * The gateway speaks the Anthropic Messages wire format on `/messages`
 * (CONTRACT.md section 1), which is the same format `claude.ts` already writes
 * and parses. That is why adding this provider is a base-URL and auth-header
 * swap rather than a second client: nothing about the body changes except the
 * model name, which must be one of the three aliases below.
 *
 * What this file owns:
 *   - provisioning an install (the "auto setup": disclosure -> POST /installs)
 *   - reading the `x-publik-*` headers every metered response carries
 *   - reading a 402 `insufficient_credit` body into something the CTA can render
 *   - the money vocabulary (micros -> dollars) and the justification sentence
 *
 * Copy rule, from CONTRACT.md section 1 and repeated in section 12: the product
 * is called "publik API", amounts are shown in DOLLARS, never in tokens and
 * never as "credits", and the upstream provider is never named to a user. The
 * strings in this file are the ones the UI renders, so the rule is enforced
 * here by `tests/publik-api.test.ts` rather than left to whoever writes markup.
 */

/** Where the gateway lives when a provisioning response has not said otherwise. */
export const PUBLIK_API_DEFAULT_BASE_URL = "https://publikhq.com/api/v1";

/**
 * The only model names that may be sent. Raw upstream slugs are rejected by the
 * gateway with `400 unknown_model`, and naming one in the UI would break the
 * copy rule, so the app's vocabulary stops at these three.
 */
export type PublikModelAlias = "publik-fast" | "publik-balanced" | "publik-smart";

export const PUBLIK_MODEL_ALIASES: readonly PublikModelAlias[] = [
  "publik-fast",
  "publik-balanced",
  "publik-smart",
] as const;

/**
 * What the companion chat asks for. `publik-smart` is deliberately not the
 * default: an anonymous (unclaimed) key asking for it is answered
 * `402 model_requires_claim`, which would turn a first run into an error.
 */
export const DEFAULT_PUBLIK_MODEL: PublikModelAlias = "publik-balanced";

export function isPublikModelAlias(candidate: string): candidate is PublikModelAlias {
  return (PUBLIK_MODEL_ALIASES as readonly string[]).includes(candidate);
}

/** `anonymous` until the user has linked the install to a publik account. */
export type PublikClaimState = "anonymous" | "claimed";

// MARK: - Money

/**
 * Micros to a dollar string. The gateway counts in millionths of a dollar and
 * the user is only ever shown dollars — "$0.25", not "250000", and never a
 * token count.
 *
 * Rounded to cents once the amount is big enough for cents to be the honest
 * unit, and to four places below that, so a balance of a fifth of a cent reads
 * as "$0.0020" rather than as "$0.00", which would look like nothing left.
 */
export function formatMicrosAsDollars(micros: number): string {
  if (!Number.isFinite(micros)) return "$0.00";
  const dollars = Math.max(0, micros) / 1_000_000;
  if (dollars >= 0.01 || dollars === 0) return `$${dollars.toFixed(2)}`;
  return `$${dollars.toFixed(4)}`;
}

/**
 * The one-sentence justification, verbatim from CONTRACT.md section 12 (b).
 *
 * It is a fixed string rather than something assembled at the call site because
 * section 12 requires it to appear wherever money is mentioned, and because
 * every clause in it is a promise: half the provider's list price, nothing
 * charged silently, every call visible on the dashboard.
 */
export const WHY_IT_COSTS_SENTENCE =
  "The AI model behind Iris is run by a provider that charges per use; publik passes that on at half the provider's list price, nothing is charged behind your back, and every call is visible on your dashboard.";

/** The disclosure shown BEFORE provisioning. Consent precedes the mint (section 3.2 [S4]). */
export const PROVISIONING_DISCLOSURE =
  "Iris will set up publik API on this computer so it can answer you. It starts with free usage, and you will see the balance before anything is spent.";

/**
 * Bumped when the disclosure text changes materially. The server records it and
 * never rejects on it, so this is an audit trail rather than a gate.
 */
export const DISCLOSURE_VERSION = 1;

// MARK: - Install identity

/**
 * A v4 UUID naming this installation. It is minted by the app, persisted, and
 * replayed: presenting the same `install_id` a second time is answered `200`
 * with `"key": null`, which is the server telling us it already gave us a key.
 */
export function newInstallId(randomBytes: (byteCount: number) => Uint8Array): string {
  const bytes = randomBytes(16);
  if (bytes.length < 16) throw new Error("newInstallId needs 16 random bytes");
  const withVersion = Uint8Array.from(bytes.subarray(0, 16));
  withVersion[6] = (withVersion[6] & 0x0f) | 0x40; // version 4
  withVersion[8] = (withVersion[8] & 0x3f) | 0x80; // variant 10xx
  const hex = Array.from(withVersion, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

/** `pk_(live|test)_<12>_<32>`, per CONTRACT.md section 1. */
const PUBLIK_KEY_PATTERN = /^pk_(live|test)_[a-z0-9]{12}_[a-z0-9]{32}$/;

export function looksLikeAPublikApiKey(candidate: string): boolean {
  return PUBLIK_KEY_PATTERN.test(candidate.trim());
}

/**
 * `pat_<slug>_<32>`. Checked before a provisioning call so a build carrying a
 * malformed token fails locally with something readable instead of spending a
 * round trip to be told `401`.
 */
export function looksLikeAnAppToken(candidate: string): boolean {
  return /^pat_[a-z0-9][a-z0-9-]*_[a-z0-9]{32}$/.test(candidate.trim());
}

// MARK: - Provisioning

export interface InstallProvisioningRequest {
  appToken: string;
  appSlug: string;
  appVersion: string;
  osVersion: string;
  arch: string;
  installId: string;
  deviceName?: string;
}

/** The URL and body for `POST /installs`. The caller does the fetch. */
export function buildInstallProvisioningRequest(
  apiBaseUrl: string,
  request: InstallProvisioningRequest
): { url: string; headers: Record<string, string>; body: string } {
  const base = apiBaseUrl.replace(/\/+$/, "");
  const body: Record<string, unknown> = {
    app_token: request.appToken,
    app_slug: request.appSlug,
    app_version: request.appVersion,
    os: "windows",
    os_version: request.osVersion,
    arch: request.arch,
    install_id: request.installId,
    disclosure_version: DISCLOSURE_VERSION,
    // Iris speaks the Anthropic Messages format, not chat/completions.
    dialects: ["messages"],
  };
  if (request.deviceName) body.device_name = request.deviceName;

  return {
    url: `${base}/installs`,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

export interface ProvisionedInstall {
  /**
   * Null on a replay: the server has already minted a key for this
   * `install_id` and will not show it twice. A client with no stored key that
   * gets a null here mints ONE fresh `install_id` and tries again (section 3.2
   * [B1]) — more than once would be a mint loop.
   */
  apiKey: string | null;
  claimCode: string | null;
  claimUrl: string | null;
  addCreditUrl: string | null;
  claimState: PublikClaimState;
  starterMicros: number;
  balanceMicros: number;
  /** Honoured over any compiled default, per CONTRACT.md section 1 [S8]. */
  baseUrl: string | null;
}

function readString(source: Record<string, unknown>, ...names: string[]): string | null {
  for (const name of names) {
    const value = source[name];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return null;
}

function readMicros(source: Record<string, unknown>, ...names: string[]): number {
  for (const name of names) {
    const value = source[name];
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return 0;
}

/**
 * Reads a `201` (or a replayed `200`) provisioning body.
 *
 * Field names are read with their documented aliases because section 3.2 ships
 * `balance_micros` and `starting_credit_micros` as the same value "so every app
 * spec's field name resolves" — a client that insists on one spelling would
 * work today and break on the release that drops the other.
 */
export function parseProvisionedInstall(rawBody: string): ProvisionedInstall | null {
  let parsed: Record<string, unknown>;
  try {
    const candidate: unknown = JSON.parse(rawBody);
    if (!candidate || typeof candidate !== "object") return null;
    parsed = candidate as Record<string, unknown>;
  } catch {
    return null;
  }

  const apiKey = readString(parsed, "key", "api_key");
  const claimStateRaw = readString(parsed, "claim_state");

  return {
    apiKey: apiKey && looksLikeAPublikApiKey(apiKey) ? apiKey : null,
    claimCode: readString(parsed, "claim_code", "code"),
    claimUrl: readString(parsed, "claim_url"),
    addCreditUrl: readString(parsed, "add_credit_url"),
    claimState: claimStateRaw === "claimed" ? "claimed" : "anonymous",
    starterMicros: readMicros(parsed, "starter_micros", "starting_credit_micros"),
    balanceMicros: readMicros(parsed, "balance_micros", "starting_credit_micros", "starter_micros"),
    baseUrl: readString(parsed, "base_url"),
  };
}

// MARK: - Reading a metered response

/**
 * What the `x-publik-*` headers on a metered response say. Everything is
 * optional because a failure response may carry none of them, and a missing
 * balance must not be read as a balance of zero.
 */
export interface PublikUsageSnapshot {
  balanceMicros: number | null;
  claimState: PublikClaimState | null;
  starterRemainingMicros: number | null;
  servedModel: string | null;
}

export interface HeaderReader {
  get(name: string): string | null;
}

export function readPublikUsageHeaders(headers: HeaderReader): PublikUsageSnapshot {
  const numeric = (name: string): number | null => {
    const raw = headers.get(name);
    if (raw === null) return null;
    const parsed = Number.parseInt(raw.trim(), 10);
    return Number.isFinite(parsed) ? parsed : null;
  };

  const claimStateRaw = headers.get("x-publik-claim-state");
  return {
    balanceMicros: numeric("x-publik-balance"),
    claimState:
      claimStateRaw === "claimed" ? "claimed" : claimStateRaw === "anonymous" ? "anonymous" : null,
    starterRemainingMicros: numeric("x-publik-starter-remaining"),
    servedModel: headers.get("x-publik-model"),
  };
}

/**
 * A `402 insufficient_credit`, read into the two things section 12 (3) says to
 * render: the server's own message, and exactly ONE link.
 *
 * Neither is rewritten. The message already carries the justification and says
 * in words what the link does, and inventing our own copy here would put a
 * second, drifting version of the pricing explanation in the app.
 */
export interface PublikCreditExhausted {
  message: string;
  topUpUrl: string | null;
  claimState: PublikClaimState;
}

export function parseInsufficientCredit(rawBody: string): PublikCreditExhausted | null {
  let error: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object") return null;
    const candidate = (parsed as Record<string, unknown>).error;
    if (!candidate || typeof candidate !== "object") return null;
    error = candidate as Record<string, unknown>;
  } catch {
    return null;
  }

  const type = readString(error, "type");
  if (type !== "insufficient_credit" && type !== "model_requires_claim") return null;

  const claimStateRaw = readString(error, "claim_state");
  return {
    message: readString(error, "message") ?? "Not enough publik credit for this request.",
    topUpUrl: readString(error, "top_up_url", "claim_url", "add_credit_url"),
    claimState: claimStateRaw === "claimed" ? "claimed" : "anonymous",
  };
}

/**
 * `401 key_revoked` carries `"reprovision": true` only when the idle sweep
 * retired the key, which is the one case where minting a new install is the
 * right answer rather than telling the user their key is bad.
 */
export function revokedKeyWantsReprovisioning(rawBody: string): boolean {
  try {
    const parsed: unknown = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object") return false;
    const error = (parsed as Record<string, unknown>).error;
    if (!error || typeof error !== "object") return false;
    return (error as Record<string, unknown>).reprovision === true;
  } catch {
    return false;
  }
}

// MARK: - What the CTA renders

/**
 * The state of the publik card, in one value. Section 12 pins both the shape
 * and the wording: while the install is anonymous the button links the computer
 * and picks a plan; once claimed it adds a plan or a pack.
 */
export interface PublikCardState {
  balanceLine: string;
  whyItCosts: string;
  buttonLabel: string;
  buttonUrl: string | null;
}

export function publikCardState(options: {
  balanceMicros: number;
  starterMicros: number;
  claimState: PublikClaimState;
  claimUrl: string | null;
  addCreditUrl: string | null;
  /** True only on the card shown immediately after provisioning. */
  isFirstRun: boolean;
}): PublikCardState {
  const amount = formatMicrosAsDollars(options.balanceMicros);
  const balanceLine =
    options.isFirstRun && options.starterMicros > 0
      ? `${formatMicrosAsDollars(options.starterMicros)} of free starter usage`
      : `${amount} left`;

  const claimed = options.claimState === "claimed";
  return {
    balanceLine,
    whyItCosts: WHY_IT_COSTS_SENTENCE,
    buttonLabel: claimed ? "Add a plan or pack" : "Link this computer & pick a plan",
    buttonUrl: claimed ? options.addCreditUrl : options.claimUrl,
  };
}
