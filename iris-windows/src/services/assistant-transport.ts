/**
 * assistant-transport.ts
 *
 * Decides where a chat request goes, and is the single place in this app that
 * is allowed to attach credentials to one.
 *
 * `docs/assistant-credentials.md` (repo root) is the cross-platform contract;
 * CONTRACT.md is the gateway's own spec. Three routes, all speaking the
 * identical wire format (the Anthropic Messages API), so one response parser
 * serves all of them:
 *
 *   publik  ->  POST {base}/messages    x-api-key: pk_live_…   (the default)
 *   BYO     ->  POST https://api.anthropic.com/v1/messages   x-api-key: sk-ant-…
 *   codex   ->  the user's own `codex` binary, no network call from here
 *
 * The funded tier is GONE. It used to win unconditionally whenever the user was
 * signed in: `POST {publik}/api/assistant/chat` on publik's own Anthropic key,
 * free to the user and capped only per-user, so publik's exposure grew with the
 * number of accounts. That is what kept Iris from being handed out publicly.
 * publik API replaces it — the same "it just works" first run, paid by the
 * person using it. The server route stays up for builds already installed; this
 * one must not call it.
 *
 * THE PROPERTY THIS FILE EXISTS TO PROTECT: a credential only ever reaches the
 * host that issued it. The user's own Anthropic key must never be seen by a
 * publik host, and a publik key must never be seen by Anthropic. Losing either
 * is a ship-blocker, so it is enforced three ways rather than by convention:
 *
 *   1. Structurally. Each builder knows its own destination. The Anthropic
 *      builder takes NO url at all — it builds api.anthropic.com from a
 *      constant, so "send the Anthropic key somewhere else" is not a sentence
 *      this file can express. The publik builder does take a base URL, because
 *      provisioning is allowed to move the gateway (CONTRACT.md section 1
 *      [S8]), and it validates that URL against its own credential's permitted
 *      hosts BEFORE writing the header — a non-publik base URL throws instead
 *      of being called.
 *   2. By assertion. Every request leaves through `validatedRequest`, which
 *      re-derives the pairing from the table below and refuses any request
 *      whose credential and destination disagree — including a request that
 *      carries a key header while declaring no credential at all.
 *   3. By test. `tests/assistant-transport.test.ts` asserts every cell of that
 *      table, in both directions, including the negative cases.
 *
 * This mirrors `iris-macos/leanring-buddy/AssistantTransport.swift`, which
 * implements the same contract in Swift.
 */

import {
  DEFAULT_PUBLIK_MODEL,
  PUBLIK_API_DEFAULT_BASE_URL,
  PublikClaimState,
  parseInsufficientCredit,
} from "./publik-api";

/** The only host the BYO Anthropic key may ever reach. */
export const ANTHROPIC_API_HOST = "api.anthropic.com";

/** The Anthropic Messages API version every direct request must declare. */
export const ANTHROPIC_API_VERSION = "2023-06-01";

/** Where publik lives when nothing overrides it. */
export const DEFAULT_PUBLIK_BASE_URL = "https://publikhq.com";

/**
 * Hosts that belong to publik. A publik API key may reach these and nothing
 * else; the user's Anthropic key may reach none of them.
 */
const PUBLIK_HOSTS = new Set(["publikhq.com", "www.publikhq.com"]);

export function isPublikHost(host: string): boolean {
  return PUBLIK_HOSTS.has(host.toLowerCase());
}

/**
 * Every kind of credential this file can attach, and — in the table below —
 * the only hosts each one may reach.
 *
 * Naming the kinds is what let the old single hardcoded host generalise without
 * weakening: before publik API existed there was one credential and one
 * permitted host, so `destinationHost !== ANTHROPIC_API_HOST` WAS the rule. Now
 * there are two of each, and the rule is the pairing rather than any one host.
 */
export type CredentialKind = "anthropicApiKey" | "publikApiKey";

const PERMITTED_HOST_FOR_CREDENTIAL: Record<CredentialKind, (host: string) => boolean> = {
  // The user's own key: Anthropic, and nowhere else. Explicitly not publik.
  anthropicApiKey: (host) => host === ANTHROPIC_API_HOST,
  // A publik-issued key: publik's own gateway, and nowhere else. Sending it to
  // Anthropic would both leak it and fail, since Anthropic never issued it.
  publikApiKey: (host) => isPublikHost(host),
};

export function credentialMayReachHost(credentialKind: CredentialKind, host: string): boolean {
  return PERMITTED_HOST_FOR_CREDENTIAL[credentialKind](host.toLowerCase());
}

/** A request that has not been sent yet: everything but the body. */
export interface PreparedRequest {
  url: string;
  method: "POST";
  headers: Record<string, string>;
  /**
   * Which credential this request carries, so `validatedRequest` can check the
   * pairing rather than guess it from header names. `null` means the request
   * carries no credential of ours at all, and must therefore carry no key
   * header either.
   */
  credentialKind: CredentialKind | null;
}

/**
 * The routes, and the credential each one carries.
 *
 * `codex` holds nothing: the CLI owns the user's OpenAI credential and Iris
 * never sees it, which is the entire reason that route is allowed to exist
 * (see `docs/assistant-credentials.md` on why Anthropic OAuth is not).
 */
export type AssistantTransport =
  | {
      readonly tier: "publik";
      /** A `pk_live_…` key issued by provisioning, or pasted by the user. */
      readonly publikApiKey: string;
      /** The gateway base, honouring what provisioning returned. */
      readonly apiBaseUrl: string;
    }
  | {
      readonly tier: "byo";
      /** The user's own Anthropic key. Deliberately paired with no URL. */
      readonly anthropicApiKey: string;
    }
  | {
      readonly tier: "codex";
    };

/** Which provider the user has chosen, as stored in settings. */
export type ProviderPreference = "publikApi" | "anthropicKey" | "codex";

export const PROVIDER_PREFERENCES: readonly ProviderPreference[] = [
  "publikApi",
  "anthropicKey",
  "codex",
] as const;

export function isProviderPreference(candidate: string): candidate is ProviderPreference {
  return (PROVIDER_PREFERENCES as readonly string[]).includes(candidate);
}

/**
 * Every route now picks its own model: publik takes an alias, BYO takes
 * whatever the user configured, and codex is driven by its own CLI. The funded
 * route was the only one that pinned a model server-side and therefore wanted
 * the field omitted, and it is gone.
 */
export function shouldSendModelInRequestBody(transport: AssistantTransport): boolean {
  return transport.tier === "publik" || transport.tier === "byo";
}

/** The model to send when the caller has no better idea. */
export function defaultModelForTransport(
  transport: AssistantTransport,
  configuredAnthropicModel: string
): string {
  return transport.tier === "publik" ? DEFAULT_PUBLIK_MODEL : configuredAnthropicModel;
}

/** For UI that wants to name the route without pattern-matching on a secret. */
export function tierDescription(transport: AssistantTransport): string {
  switch (transport.tier) {
    case "publik":
      return "publik API";
    case "byo":
      return "your Anthropic key";
    case "codex":
      return "your ChatGPT sign-in";
  }
}

/**
 * The publik route.
 *
 * Unlike the Anthropic builder this one takes a destination, because
 * provisioning is allowed to move the gateway. The destination is checked
 * against the publik key's own permitted hosts here, before the header is
 * written, so a caller cannot use this function to send the key somewhere else
 * even by supplying a hostile base URL.
 */
function publikApiChatRequest(publikApiKey: string, apiBaseUrl: string): PreparedRequest {
  let destinationHost: string;
  try {
    destinationHost = new URL(apiBaseUrl).hostname;
  } catch {
    throw new AssistantTransportFailure({
      kind: "transportFailure",
      reason: "the publik API address is not a valid URL",
    });
  }

  if (!credentialMayReachHost("publikApiKey", destinationHost)) {
    throw new AssistantTransportFailure({
      kind: "credentialWouldLeaveItsHost",
      credentialKind: "publikApiKey",
      attemptedHost: destinationHost || "an unknown host",
    });
  }

  const base = apiBaseUrl.replace(/\/+$/, "");
  return {
    url: `${base}/messages`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": publikApiKey,
      "anthropic-version": ANTHROPIC_API_VERSION,
    },
    credentialKind: "publikApiKey",
  };
}

/**
 * The BYO route, and the only place the user's own Anthropic key is written.
 *
 * There is no URL parameter on purpose. A caller cannot ask this function to
 * send the key anywhere, because the destination is not something the caller
 * supplies — it is the constant below.
 */
function anthropicDirectChatRequest(anthropicApiKey: string): PreparedRequest {
  return {
    url: `https://${ANTHROPIC_API_HOST}/v1/messages`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": anthropicApiKey,
      "anthropic-version": ANTHROPIC_API_VERSION,
    },
    credentialKind: "anthropicApiKey",
  };
}

/**
 * Refuses any request whose credential and destination do not match.
 *
 * This duplicates what the builders above already guarantee, and that is the
 * point: a later refactor that merges them, adds a fourth route, or
 * "helpfully" copies headers between requests trips this instead of silently
 * shipping a key to a server that should never see it.
 */
export function validatedRequest(candidate: PreparedRequest): PreparedRequest {
  let destinationHost: string;
  try {
    destinationHost = new URL(candidate.url).hostname.toLowerCase();
  } catch {
    throw new AssistantTransportFailure({ kind: "transportFailure", reason: "malformed request URL" });
  }

  // Header lookup is case-insensitive: a refactor that writes "X-API-Key" must
  // not be able to walk past this gate.
  const carriesAKeyHeader = Object.keys(candidate.headers).some(
    (headerName) => headerName.toLowerCase() === "x-api-key"
  );

  if (candidate.credentialKind === null) {
    // No declared credential means no key header is allowed — otherwise an
    // undeclared secret would sail past the pairing check entirely.
    if (carriesAKeyHeader) {
      throw new AssistantTransportFailure({
        kind: "credentialWouldLeaveItsHost",
        credentialKind: "anthropicApiKey",
        attemptedHost: destinationHost || "an unknown host",
      });
    }
    return candidate;
  }

  if (!credentialMayReachHost(candidate.credentialKind, destinationHost)) {
    throw new AssistantTransportFailure({
      kind: "credentialWouldLeaveItsHost",
      credentialKind: candidate.credentialKind,
      attemptedHost: destinationHost || "an unknown host",
    });
  }

  return candidate;
}

/**
 * Produces the URL and headers for one chat request. The caller supplies the
 * body, which is identical on every route apart from the `model` field.
 *
 * `codex` has no prepared request: it runs a local binary rather than making an
 * HTTP call, so asking for one is a programming error rather than a user-facing
 * state.
 */
export async function makeChatRequest(transport: AssistantTransport): Promise<PreparedRequest> {
  switch (transport.tier) {
    case "publik":
      return validatedRequest(publikApiChatRequest(transport.publikApiKey, transport.apiBaseUrl));
    case "byo":
      return validatedRequest(anthropicDirectChatRequest(transport.anthropicApiKey));
    case "codex":
      throw new AssistantTransportFailure({
        kind: "transportFailure",
        reason: "the codex route does not make HTTP requests",
      });
  }
}

/**
 * Picks the route for the current state of the app.
 *
 * An explicit preference is honoured even when another provider would work,
 * and a chosen provider that has become unusable is reported as ITSELF rather
 * than quietly falling through to a different one — spending someone's money
 * on an account they did not pick is worse than an error message.
 *
 * With no preference stored, the order is publik API, then a stored Anthropic
 * key, then codex: `docs/assistant-credentials.md`, "Choosing between them".
 */
export function selectTransport(options: {
  preference: ProviderPreference | null;
  storedPublikApiKey: string | null;
  publikApiBaseUrl: string;
  storedAnthropicApiKey: string | null;
  codexIsAvailable: boolean;
}): AssistantTransport {
  const publikTransport = (): AssistantTransport | null =>
    options.storedPublikApiKey
      ? {
          tier: "publik",
          publikApiKey: options.storedPublikApiKey,
          apiBaseUrl: options.publikApiBaseUrl || PUBLIK_API_DEFAULT_BASE_URL,
        }
      : null;

  const anthropicTransport = (): AssistantTransport | null =>
    options.storedAnthropicApiKey
      ? { tier: "byo", anthropicApiKey: options.storedAnthropicApiKey }
      : null;

  const codexTransport = (): AssistantTransport | null =>
    options.codexIsAvailable ? { tier: "codex" } : null;

  if (options.preference !== null) {
    const chosen =
      options.preference === "publikApi"
        ? publikTransport()
        : options.preference === "anthropicKey"
          ? anthropicTransport()
          : codexTransport();
    if (chosen) return chosen;
    throw new AssistantTransportFailure({
      kind: "chosenProviderUnavailable",
      preference: options.preference,
    });
  }

  const firstUsable = publikTransport() ?? anthropicTransport() ?? codexTransport();
  if (firstUsable) return firstUsable;

  throw new AssistantTransportFailure({ kind: "noCredentialsAvailable" });
}

// MARK: - Failures

/**
 * Every way a chat request can fail, in the vocabulary the panel uses to talk to
 * the user. A raw server body is never shown to anybody — with one deliberate
 * exception, `publikCreditExhausted`, whose message the gateway writes FOR the
 * user and which CONTRACT.md section 12 requires be rendered verbatim.
 */
export type AssistantTransportErrorKind =
  /** No provider is usable and none was chosen. The one state that is the user's move. */
  | { kind: "noCredentialsAvailable" }
  /** The provider the user picked cannot run right now. Never falls through. */
  | { kind: "chosenProviderUnavailable"; preference: ProviderPreference }
  /** `401 invalid_api_key` / `key_revoked` from the gateway. */
  | { kind: "publikKeyRejected"; mayReprovision: boolean }
  /** `402 insufficient_credit`. Carries the server's own message and one link. */
  | {
      kind: "publikCreditExhausted";
      message: string;
      topUpUrl: string | null;
      claimState: PublikClaimState;
    }
  /** `429` from either host, with `Retry-After` when it was sent. */
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  /** `503 gateway_unavailable`. publik's own outage, not the user's. */
  | { kind: "assistantUnavailable" }
  /** Every other status. Deliberately vague: the body may quote the model. */
  | { kind: "requestFailed"; statusCode: number }
  /** The user's own key was rejected by Anthropic (HTTP 401 on the BYO route). */
  | { kind: "bringYourOwnKeyRejected" }
  /** The codex CLI is not installed, not signed in, or refused to answer. */
  | { kind: "codexUnavailable"; reason: string }
  /** The network never got there. */
  | { kind: "transportFailure"; reason: string }
  /** The credential-isolation property was about to be violated. This should be
   *  impossible; it exists so that if it ever happens the request dies here
   *  rather than on the wire. */
  | { kind: "credentialWouldLeaveItsHost"; credentialKind: CredentialKind; attemptedHost: string };

export class AssistantTransportFailure extends Error {
  readonly detail: AssistantTransportErrorKind;

  constructor(detail: AssistantTransportErrorKind) {
    super(userFacingMessage(detail));
    this.name = "AssistantTransportFailure";
    this.detail = detail;
  }
}

/** How each provider is named to a user. "publik API" is the copy rule's word. */
export function preferenceDescription(preference: ProviderPreference): string {
  switch (preference) {
    case "publikApi":
      return "publik API";
    case "anthropicKey":
      return "your Anthropic key";
    case "codex":
      return "your ChatGPT sign-in";
  }
}

/**
 * What the panel shows. Lowercase to match the assistant's own voice in the
 * system prompt, which is what the same text area displays.
 */
export function userFacingMessage(detail: AssistantTransportErrorKind): string {
  switch (detail.kind) {
    case "noCredentialsAvailable":
      return "i need a way to reach a model first — set up publik api, add your own anthropic key, or sign in with chatgpt.";
    case "chosenProviderUnavailable":
      return `${preferenceDescription(detail.preference)} isn't working right now, and i won't quietly switch to something else. fix it in settings, or pick a different option there.`;
    case "publikKeyRejected":
      return detail.mayReprovision
        ? "this computer's publik api key went stale. set it up again in settings and i'll be right here."
        : "publik api turned that key down. check it in settings, or paste a new one.";
    case "publikCreditExhausted":
      // The gateway writes this sentence for the user and section 12 requires
      // it verbatim, so it is passed through rather than paraphrased.
      return detail.message;
    case "rateLimited":
      return `you've hit the request limit for now. ${retryPhrase(detail.retryAfterSeconds)} or switch provider in settings.`;
    case "assistantUnavailable":
      return "publik api is unavailable right now. this one's on publik, not you — try again in a bit.";
    case "requestFailed":
      return "hm, something went wrong reaching the assistant. check your connection and try again.";
    case "bringYourOwnKeyRejected":
      return "anthropic turned that key down. check it's still active and paste it again.";
    case "codexUnavailable":
      return `i couldn't use your chatgpt sign-in: ${detail.reason}`;
    case "transportFailure":
      return "i couldn't reach the assistant. check your connection and try again.";
    case "credentialWouldLeaveItsHost":
      return "iris stopped that request: a key was about to go somewhere it shouldn't.";
  }
}

/** True when the right response is to put the setup options back in front of
 *  the user rather than just showing them a message. */
export function requiresSetup(detail: AssistantTransportErrorKind): boolean {
  return (
    detail.kind === "noCredentialsAvailable" ||
    detail.kind === "chosenProviderUnavailable" ||
    detail.kind === "publikKeyRejected"
  );
}

/** True when money, not software, is what stopped them — the case where the
 *  top-up link is the genuinely useful thing to show. */
export function shouldOfferTopUp(detail: AssistantTransportErrorKind): boolean {
  return detail.kind === "publikCreditExhausted";
}

function retryPhrase(retryAfterSeconds: number | null): string {
  if (retryAfterSeconds === null || retryAfterSeconds <= 0) {
    return "try again shortly,";
  }
  if (retryAfterSeconds < 90) {
    return `try again in ${retryAfterSeconds} seconds,`;
  }
  const retryAfterMinutes = Math.ceil(retryAfterSeconds / 60);
  if (retryAfterMinutes < 90) {
    return `try again in about ${retryAfterMinutes} minutes,`;
  }
  const retryAfterHours = Math.ceil(retryAfterMinutes / 60);
  return `try again in about ${retryAfterHours} hours,`;
}

/**
 * Turns one HTTP failure into the state the user sees.
 *
 * The same status means different things on the two HTTP routes — a 401 from
 * publik is "this install's key is stale", a 401 from Anthropic is "your key is
 * bad" — so the route is part of the question, not something inferred later.
 */
export function failureForStatusCode(options: {
  statusCode: number;
  rawBody: string;
  retryAfterHeaderValue: string | null;
  tier: AssistantTransport["tier"];
}): AssistantTransportErrorKind {
  const parsed = options.retryAfterHeaderValue
    ? Number.parseInt(options.retryAfterHeaderValue.trim(), 10)
    : Number.NaN;
  const retryAfterSeconds = Number.isFinite(parsed) ? parsed : null;
  const isPublik = options.tier === "publik";

  switch (options.statusCode) {
    case 401:
      if (!isPublik) return { kind: "bringYourOwnKeyRejected" };
      return {
        kind: "publikKeyRejected",
        mayReprovision: revokedKeyWantsReprovisioningSafely(options.rawBody),
      };
    case 402: {
      const exhausted = parseInsufficientCredit(options.rawBody);
      if (exhausted) {
        return {
          kind: "publikCreditExhausted",
          message: exhausted.message,
          topUpUrl: exhausted.topUpUrl,
          claimState: exhausted.claimState,
        };
      }
      return { kind: "requestFailed", statusCode: options.statusCode };
    }
    case 429:
      return { kind: "rateLimited", retryAfterSeconds };
    case 503:
      return { kind: "assistantUnavailable" };
    default:
      return { kind: "requestFailed", statusCode: options.statusCode };
  }
}

/** Kept local so a malformed body can never throw out of failure mapping. */
function revokedKeyWantsReprovisioningSafely(rawBody: string): boolean {
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
