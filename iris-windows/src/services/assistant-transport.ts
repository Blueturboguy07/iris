/**
 * assistant-transport.ts
 *
 * Decides where a chat request goes, and is the single place in this app that
 * is allowed to attach credentials to one.
 *
 * `docs/iris-assistant-protocol.md` section 1 defines exactly two routes, and
 * they speak the identical wire format (the Anthropic Messages API), so one
 * response parser serves both:
 *
 *   funded  ->  POST {publik}/api/assistant/chat        Authorization: Bearer <supabase access token>
 *   BYO     ->  POST https://api.anthropic.com/v1/messages   x-api-key: <the user's own key>
 *
 * THE PROPERTY THIS FILE EXISTS TO PROTECT: the user's own Anthropic key is
 * never sent to any publik host. Losing that is a ship-blocker, so it is
 * enforced three ways rather than by convention:
 *
 *   1. Structurally. `anthropicDirectChatRequest(anthropicApiKey)` is the ONLY
 *      function that writes an `x-api-key` header, and it takes no URL — it
 *      builds `https://api.anthropic.com/v1/messages` from a constant. There is
 *      no function anywhere that accepts both a key and a destination, so "send
 *      the key somewhere else" is not a mistake this file can express.
 *   2. By assertion. Every request leaves through `validatedRequest`, which
 *      refuses a request carrying `x-api-key` to any host but api.anthropic.com,
 *      and — stated from the other direction — refuses to let a publik host see
 *      that header at all.
 *   3. By test. `tests/assistant-transport.test.ts` asserts the property in both
 *      directions.
 *
 * This mirrors `iris-macos/leanring-buddy/AssistantTransport.swift`, which is
 * the reference implementation of the same contract.
 */

/** The only host the BYO key may ever reach. */
export const ANTHROPIC_API_HOST = "api.anthropic.com";

/** The Anthropic Messages API version every direct request must declare. */
export const ANTHROPIC_API_VERSION = "2023-06-01";

/** Where publik lives when nothing overrides it. */
export const DEFAULT_PUBLIK_BASE_URL = "https://publikhq.com";

/**
 * Hosts that belong to publik. Used only to state the key-isolation rule from
 * the second direction — "a publik host must never see an x-api-key" — so the
 * gate below reads as the rule itself rather than as a proxy for it.
 */
const PUBLIK_HOSTS = new Set(["publikhq.com", "www.publikhq.com"]);

export function isPublikHost(host: string): boolean {
  return PUBLIK_HOSTS.has(host.toLowerCase());
}

/** A request that has not been sent yet: everything but the body. */
export interface PreparedRequest {
  url: string;
  method: "POST";
  headers: Record<string, string>;
}

/**
 * The two model routes, and the credential each one carries.
 *
 * The funded case holds a *provider* rather than a token because the Supabase
 * access token is short-lived: it may need refreshing between the moment the
 * transport was chosen and the moment a request is actually built.
 */
export type AssistantTransport =
  | {
      readonly tier: "funded";
      readonly publikBaseUrl: string;
      readonly currentAccessToken: () => Promise<string | null>;
    }
  | {
      readonly tier: "byo";
      /** The user's own Anthropic key. Deliberately paired with no URL. */
      readonly anthropicApiKey: string;
    };

/**
 * The funded route's server prepends its own system block, pins the model, and
 * caps `max_tokens`; sending a model it will ignore only invites a reader of the
 * code to believe the client picked it. On the BYO route the model is genuinely
 * the client's choice and must be sent.
 */
export function shouldSendModelInRequestBody(transport: AssistantTransport): boolean {
  return transport.tier === "byo";
}

/** For UI that wants to name the tier without pattern-matching on a secret. */
export function tierDescription(transport: AssistantTransport): string {
  return transport.tier === "funded" ? "publik account" : "your Anthropic key";
}

/**
 * The funded route. Note what this function does NOT take: an API key. The only
 * credential it can attach is a Supabase access token, which is a publik-issued
 * value that publik is supposed to see.
 */
function fundedChatRequest(publikBaseUrl: string, supabaseAccessToken: string): PreparedRequest {
  const base = publikBaseUrl.replace(/\/+$/, "");
  return {
    url: `${base}/api/assistant/chat`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${supabaseAccessToken}`,
    },
  };
}

/**
 * The BYO route, and the only place `x-api-key` is ever written.
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
  };
}

/**
 * Refuses any request whose credentials and destination do not match.
 *
 * This duplicates what the two builders above already guarantee, and that is the
 * point: a later refactor that merges them, adds a third route, or "helpfully"
 * copies headers between requests trips this instead of silently shipping the
 * user's key to a server that should never see it.
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
  const carriesBringYourOwnKey = Object.keys(candidate.headers).some(
    (headerName) => headerName.toLowerCase() === "x-api-key"
  );

  if (carriesBringYourOwnKey && destinationHost !== ANTHROPIC_API_HOST) {
    throw new AssistantTransportFailure({
      kind: "bringYourOwnKeyWouldLeaveAnthropic",
      attemptedHost: destinationHost || "an unknown host",
    });
  }

  // The same rule stated from the other direction, so it reads as the rule
  // rather than as an implementation detail of the rule.
  if (isPublikHost(destinationHost) && carriesBringYourOwnKey) {
    throw new AssistantTransportFailure({
      kind: "bringYourOwnKeyWouldLeaveAnthropic",
      attemptedHost: destinationHost,
    });
  }

  return candidate;
}

/**
 * Produces the URL and headers for one chat request. The caller supplies the
 * body, which is identical for both routes apart from the `model` field.
 */
export async function makeChatRequest(transport: AssistantTransport): Promise<PreparedRequest> {
  if (transport.tier === "funded") {
    const accessToken = await transport.currentAccessToken();
    if (!accessToken) {
      // No usable access token means the refresh already failed. That is exactly
      // the state the funded tier's 401 describes, so it is reported the same
      // way rather than as a transport failure.
      throw new AssistantTransportFailure({ kind: "signInRequired" });
    }
    return validatedRequest(fundedChatRequest(transport.publikBaseUrl, accessToken));
  }

  return validatedRequest(anthropicDirectChatRequest(transport.anthropicApiKey));
}

/**
 * Picks the route for the current state of the app.
 *
 * Funded wins when the user is signed in, because it costs them nothing. A
 * stored key is the fallback. Having neither is a real state the panel has to
 * explain, not a silent failure at request time — which is why it is a thrown
 * `noCredentialsAvailable` rather than a null transport.
 */
export function selectTransport(options: {
  isSignedIn: boolean;
  publikBaseUrl: string;
  storedAnthropicApiKey: string | null;
  currentAccessToken: () => Promise<string | null>;
}): AssistantTransport {
  if (options.isSignedIn) {
    return {
      tier: "funded",
      publikBaseUrl: options.publikBaseUrl,
      currentAccessToken: options.currentAccessToken,
    };
  }

  if (options.storedAnthropicApiKey) {
    return { tier: "byo", anthropicApiKey: options.storedAnthropicApiKey };
  }

  throw new AssistantTransportFailure({ kind: "noCredentialsAvailable" });
}

// MARK: - Failures

/**
 * Every way a chat request can fail, in the vocabulary the panel uses to talk to
 * the user. The funded tier's error codes (protocol section 1) each map to
 * exactly one variant, so the panel never interprets a status code and a raw
 * server body is never shown to anybody.
 */
export type AssistantTransportErrorKind =
  /** Not signed in and no key stored. The one state that is the user's move. */
  | { kind: "noCredentialsAvailable" }
  /** `sign_in_required` (HTTP 401). The session is gone or was rejected. */
  | { kind: "signInRequired" }
  /** `rate_limited` (HTTP 429 + `Retry-After`). */
  | { kind: "rateLimited"; retryAfterSeconds: number | null }
  /** `daily_budget_exhausted` (HTTP 429 + `Retry-After`). */
  | { kind: "dailyBudgetExhausted"; retryAfterSeconds: number | null }
  /** `assistant_unconfigured` (HTTP 503). publik's own outage, not the user's. */
  | { kind: "assistantUnavailable" }
  /** `upstream_error` and every other status. Deliberately vague: the server's
   *  body may quote the model's own words back and is never surfaced. */
  | { kind: "requestFailed"; statusCode: number }
  /** The user's own key was rejected by Anthropic (HTTP 401 on the BYO route). */
  | { kind: "bringYourOwnKeyRejected" }
  /** The network never got there. */
  | { kind: "transportFailure"; reason: string }
  /** The key-isolation property was about to be violated. This should be
   *  impossible; it exists so that if it ever happens the request dies here
   *  rather than on the wire. */
  | { kind: "bringYourOwnKeyWouldLeaveAnthropic"; attemptedHost: string };

export class AssistantTransportFailure extends Error {
  readonly detail: AssistantTransportErrorKind;

  constructor(detail: AssistantTransportErrorKind) {
    super(userFacingMessage(detail));
    this.name = "AssistantTransportFailure";
    this.detail = detail;
  }
}

/**
 * What the panel shows. Lowercase to match the assistant's own voice in the
 * system prompt, which is what the same text area displays.
 */
export function userFacingMessage(detail: AssistantTransportErrorKind): string {
  switch (detail.kind) {
    case "noCredentialsAvailable":
      return "sign in with your publik account, or add your own anthropic key, and i'll be right here.";
    case "signInRequired":
      return "your sign-in expired. sign in again and ask me one more time.";
    case "rateLimited":
      return `you've hit the request limit for now. ${retryPhrase(detail.retryAfterSeconds)} or add your own anthropic key to keep going.`;
    case "dailyBudgetExhausted":
      return `that's today's free assistant budget used up. ${retryPhrase(detail.retryAfterSeconds)} or add your own anthropic key to keep going.`;
    case "assistantUnavailable":
      return "the assistant is unavailable right now. this one's on publik, not you — try again in a bit.";
    case "requestFailed":
      return "hm, something went wrong reaching the assistant. check your connection and try again.";
    case "bringYourOwnKeyRejected":
      return "anthropic turned that key down. check it's still active and paste it again.";
    case "transportFailure":
      return "i couldn't reach the assistant. check your connection and try again.";
    case "bringYourOwnKeyWouldLeaveAnthropic":
      return "iris stopped that request: your api key was about to go somewhere it shouldn't.";
  }
}

/** True when the right response is to put the sign-in buttons back in front of
 *  the user rather than just showing them a message. */
export function requiresReSignIn(detail: AssistantTransportErrorKind): boolean {
  return detail.kind === "signInRequired";
}

/** True when the user's quota, not the software, is what stopped them — the case
 *  where offering the BYO key is genuinely useful advice. */
export function shouldOfferBringYourOwnKey(detail: AssistantTransportErrorKind): boolean {
  return detail.kind === "rateLimited" || detail.kind === "dailyBudgetExhausted";
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
 * `serverErrorCode` is the `{"error": "..."}` string the funded route returns.
 * It is read only to choose between two 429s that mean different things to the
 * user — "wait a few minutes" versus "that's it for today" — and is never itself
 * displayed, because an unknown code must not become user-visible text.
 */
export function failureForStatusCode(options: {
  statusCode: number;
  serverErrorCode: string | null;
  retryAfterHeaderValue: string | null;
  isFundedTier: boolean;
}): AssistantTransportErrorKind {
  const parsed = options.retryAfterHeaderValue
    ? Number.parseInt(options.retryAfterHeaderValue.trim(), 10)
    : Number.NaN;
  const retryAfterSeconds = Number.isFinite(parsed) ? parsed : null;

  switch (options.statusCode) {
    case 401:
      // The same status means opposite things on the two routes: publik is
      // saying "sign in again", Anthropic is saying "this key is bad".
      return options.isFundedTier ? { kind: "signInRequired" } : { kind: "bringYourOwnKeyRejected" };
    case 429:
      if (options.serverErrorCode === "daily_budget_exhausted") {
        return { kind: "dailyBudgetExhausted", retryAfterSeconds };
      }
      return { kind: "rateLimited", retryAfterSeconds };
    case 503:
      return { kind: "assistantUnavailable" };
    default:
      return { kind: "requestFailed", statusCode: options.statusCode };
  }
}

/**
 * Pulls the `{"error": "code"}` string out of a funded-tier failure body. Only
 * the code is ever read — the rest of the body is dropped on the floor so it can
 * never reach the panel.
 */
export function serverErrorCodeInFailureBody(failureBody: string): string | null {
  try {
    const parsed = JSON.parse(failureBody) as { error?: unknown };
    return typeof parsed.error === "string" && parsed.error.length > 0 ? parsed.error : null;
  } catch {
    return null;
  }
}
