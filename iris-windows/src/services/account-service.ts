/**
 * account-service.ts
 *
 * Supabase sign-in with no Supabase SDK: it is an authorize URL plus a token
 * exchange, which is all protocol section 4 asks for. Ported from
 * `iris-macos/leanring-buddy/AccountService.swift` so both clients present the
 * same identity to the same project.
 *
 * The sign-in flow is PKCE **in the system browser**. Never a webview: Google
 * refuses to complete OAuth inside embedded browser views, and the protocol
 * requires the real browser regardless. Windows has no
 * `ASWebAuthenticationSession`, so the callback arrives the ordinary way — the
 * OS hands the registered `iris://` URL to the running instance, which is why
 * `main/index.ts` takes the single-instance lock and treats `second-instance`
 * as a deep-link delivery.
 *
 * The URL-building and token-parsing halves live here as pure functions with an
 * injected fetch, so the whole module is testable without a browser or network.
 */

import { createHash, randomBytes } from "node:crypto";

/** The redirect Windows registers and Supabase must allow. */
export const AUTH_CALLBACK_URL = "iris://auth/callback";

export type AccountSignInProvider = "google" | "github";

export interface SupabaseProjectConfiguration {
  /** e.g. `https://abcdefgh.supabase.co` */
  readonly projectUrl: string;
  /** The publishable anon key. Public by design; it identifies the project. */
  readonly anonymousKey: string;
}

export interface SupabaseSession {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Epoch seconds. */
  readonly expiresAt: number;
  readonly userEmail: string | null;
}

// MARK: - PKCE

export interface PkceCodePair {
  readonly codeVerifier: string;
  readonly codeChallenge: string;
}

/**
 * A PKCE verifier/challenge pair. The verifier is 32 random bytes in base64url,
 * and the challenge is its SHA-256, also base64url — the `S256` method, which is
 * the only one worth using.
 */
export function createPkceCodePair(): PkceCodePair {
  const codeVerifier = base64UrlEncode(randomBytes(32));
  const codeChallenge = base64UrlEncode(createHash("sha256").update(codeVerifier).digest());
  return { codeVerifier, codeChallenge };
}

/** An opaque, single-use value that ties a callback back to the request that
 *  started it. A callback whose state does not match is discarded. */
export function createOpaqueStateToken(): string {
  return base64UrlEncode(randomBytes(24));
}

function base64UrlEncode(buffer: Buffer): string {
  return buffer.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// MARK: - The authorize step

/**
 * Builds `{supabase}/auth/v1/authorize?provider=…&redirect_to=…&code_challenge=…`.
 *
 * The state token is folded into `redirect_to` rather than sent as its own
 * `state` parameter because Supabase manages `state` itself for the trip to the
 * identity provider, but parses `redirect_to` as a URL and merges its own `code`
 * into that URL's query. So a redirect of `iris://auth/callback?state=abc` comes
 * back as `iris://auth/callback?state=abc&code=xyz` — exactly the shape
 * `parseIrisDeepLink` already validates.
 *
 * NOTE FOR DEPLOYMENT: publik's Supabase project must allow
 * `iris://auth/callback` *with a query string* in its redirect allow list (an
 * `iris://auth/callback**` entry). An exact-match-only entry rejects the state
 * token and sign-in fails at the authorize step.
 */
export function authorizationUrl(options: {
  project: SupabaseProjectConfiguration;
  provider: AccountSignInProvider;
  codeChallenge: string;
  opaqueStateToken: string;
}): string {
  const base = options.project.projectUrl.replace(/\/+$/, "");
  const redirectTarget = `${AUTH_CALLBACK_URL}?state=${encodeURIComponent(options.opaqueStateToken)}`;

  const authorize = new URL(`${base}/auth/v1/authorize`);
  authorize.searchParams.set("provider", options.provider);
  authorize.searchParams.set("redirect_to", redirectTarget);
  authorize.searchParams.set("code_challenge", options.codeChallenge);
  authorize.searchParams.set("code_challenge_method", "s256");
  return authorize.toString();
}

// MARK: - The token step

export type AccountServiceErrorKind =
  | { kind: "supabaseIsNotConfiguredInThisBuild" }
  | { kind: "signInWasCancelled" }
  | { kind: "callbackStateDidNotMatch" }
  | { kind: "authorizationServerRejectedTheRequest"; reason: string }
  | { kind: "couldNotReachTheAuthorizationServer"; reason: string }
  | { kind: "theSessionResponseCouldNotBeRead" };

export class AccountServiceError extends Error {
  readonly detail: AccountServiceErrorKind;
  constructor(detail: AccountServiceErrorKind) {
    super(accountErrorMessage(detail));
    this.name = "AccountServiceError";
    this.detail = detail;
  }
}

export function accountErrorMessage(detail: AccountServiceErrorKind): string {
  switch (detail.kind) {
    case "supabaseIsNotConfiguredInThisBuild":
      return "This build of Iris has no publik account configured.";
    case "signInWasCancelled":
      return "Sign-in was cancelled.";
    case "callbackStateDidNotMatch":
      return "Iris ignored a sign-in response it did not ask for.";
    case "authorizationServerRejectedTheRequest":
      return `Sign-in failed: ${detail.reason}`;
    case "couldNotReachTheAuthorizationServer":
      return `Iris could not reach the sign-in service: ${detail.reason}`;
    case "theSessionResponseCouldNotBeRead":
      return "Iris could not read the sign-in response.";
  }
}

export type TokenFetchLike = (
  url: string,
  init: { method: string; headers: Record<string, string>; body: string }
) => Promise<{ ok: boolean; status: number; text: () => Promise<string> }>;

/**
 * `POST {supabase}/auth/v1/token?grant_type=<grant>`, which serves the PKCE
 * exchange and the refresh grant identically apart from the body.
 */
async function requestSession(options: {
  project: SupabaseProjectConfiguration;
  grantType: "pkce" | "refresh_token";
  requestBody: Record<string, string>;
  fetchImplementation: TokenFetchLike;
}): Promise<SupabaseSession> {
  const base = options.project.projectUrl.replace(/\/+$/, "");
  const tokenUrl = `${base}/auth/v1/token?grant_type=${encodeURIComponent(options.grantType)}`;

  let response: Awaited<ReturnType<TokenFetchLike>>;
  try {
    response = await options.fetchImplementation(tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // Supabase identifies the project by this header. It is the public anon
        // key, not a secret.
        apikey: options.project.anonymousKey,
      },
      body: JSON.stringify(options.requestBody),
    });
  } catch (error) {
    throw new AccountServiceError({
      kind: "couldNotReachTheAuthorizationServer",
      reason: error instanceof Error ? error.message : String(error),
    });
  }

  const rawBody = await response.text();
  if (!response.ok) {
    throw new AccountServiceError({
      kind: "authorizationServerRejectedTheRequest",
      reason: readAuthErrorDescription(rawBody) ?? `HTTP ${response.status}`,
    });
  }

  return parseSessionResponse(rawBody);
}

/** Exchanges the authorization code from `iris://auth/callback` for a session. */
export function exchangeAuthorizationCode(options: {
  project: SupabaseProjectConfiguration;
  authorizationCode: string;
  codeVerifier: string;
  fetchImplementation: TokenFetchLike;
}): Promise<SupabaseSession> {
  return requestSession({
    project: options.project,
    grantType: "pkce",
    requestBody: { auth_code: options.authorizationCode, code_verifier: options.codeVerifier },
    fetchImplementation: options.fetchImplementation,
  });
}

/** Trades the stored refresh token for a fresh access token. */
export function refreshSession(options: {
  project: SupabaseProjectConfiguration;
  refreshToken: string;
  fetchImplementation: TokenFetchLike;
}): Promise<SupabaseSession> {
  return requestSession({
    project: options.project,
    grantType: "refresh_token",
    requestBody: { refresh_token: options.refreshToken },
    fetchImplementation: options.fetchImplementation,
  });
}

export function parseSessionResponse(rawBody: string): SupabaseSession {
  let payload: {
    access_token?: unknown;
    refresh_token?: unknown;
    expires_in?: unknown;
    expires_at?: unknown;
    user?: { email?: unknown };
  };
  try {
    payload = JSON.parse(rawBody);
  } catch {
    throw new AccountServiceError({ kind: "theSessionResponseCouldNotBeRead" });
  }

  const accessToken = typeof payload.access_token === "string" ? payload.access_token : "";
  const refreshToken = typeof payload.refresh_token === "string" ? payload.refresh_token : "";
  if (!accessToken || !refreshToken) {
    throw new AccountServiceError({ kind: "theSessionResponseCouldNotBeRead" });
  }

  const nowInSeconds = Math.floor(Date.now() / 1000);
  const expiresAt =
    typeof payload.expires_at === "number"
      ? payload.expires_at
      : typeof payload.expires_in === "number"
        ? nowInSeconds + payload.expires_in
        : nowInSeconds + 3600;

  return {
    accessToken,
    refreshToken,
    expiresAt,
    userEmail: typeof payload.user?.email === "string" ? payload.user.email : null,
  };
}

/** An access token is refreshed a minute early so a request never races expiry. */
export function sessionNeedsRefresh(session: SupabaseSession, nowInSeconds: number): boolean {
  return session.expiresAt - 60 <= nowInSeconds;
}

function readAuthErrorDescription(rawBody: string): string | null {
  try {
    const parsed = JSON.parse(rawBody) as {
      error_description?: unknown;
      msg?: unknown;
      error?: unknown;
    };
    for (const candidate of [parsed.error_description, parsed.msg, parsed.error]) {
      if (typeof candidate === "string" && candidate.length > 0) return candidate;
    }
  } catch {
    // A non-JSON body is never surfaced verbatim.
  }
  return null;
}
