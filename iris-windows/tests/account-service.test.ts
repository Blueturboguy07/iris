import { describe, expect, it } from "vitest";
import {
  AUTH_CALLBACK_URL,
  AccountServiceError,
  TokenFetchLike,
  authorizationUrl,
  createPkceCodePair,
  exchangeAuthorizationCode,
  parseSessionResponse,
  sessionNeedsRefresh,
} from "../src/services/account-service";
import { parseIrisDeepLink } from "../src/services/deep-link-parser";

const PROJECT = {
  projectUrl: "https://abcdefgh.supabase.co",
  anonymousKey: "public-anon-key",
};

describe("PKCE", () => {
  it("produces a verifier and a different S256 challenge, both base64url", () => {
    const pair = createPkceCodePair();
    expect(pair.codeVerifier).not.toBe(pair.codeChallenge);
    for (const value of [pair.codeVerifier, pair.codeChallenge]) {
      expect(value).toMatch(/^[A-Za-z0-9_-]+$/);
      expect(value.length).toBeGreaterThanOrEqual(43);
    }
  });

  it("produces a new pair every time", () => {
    expect(createPkceCodePair().codeVerifier).not.toBe(createPkceCodePair().codeVerifier);
  });
});

describe("the authorize URL", () => {
  it("asks Supabase for PKCE with the iris:// callback as the redirect", () => {
    const url = new URL(
      authorizationUrl({
        project: PROJECT,
        provider: "google",
        codeChallenge: "the-challenge",
        opaqueStateToken: "the-state",
      })
    );

    expect(url.origin + url.pathname).toBe("https://abcdefgh.supabase.co/auth/v1/authorize");
    expect(url.searchParams.get("provider")).toBe("google");
    expect(url.searchParams.get("code_challenge")).toBe("the-challenge");
    expect(url.searchParams.get("code_challenge_method")).toBe("s256");
    expect(url.searchParams.get("redirect_to")).toBe(`${AUTH_CALLBACK_URL}?state=the-state`);
  });

  it("folds the state into redirect_to, so the callback Supabase sends back is one Iris accepts", () => {
    // Supabase merges its own `code` into the redirect URL's query. Simulating
    // that here proves the round trip lands on a link the parser accepts.
    const url = new URL(
      authorizationUrl({
        project: PROJECT,
        provider: "github",
        codeChallenge: "c",
        opaqueStateToken: "state-abc",
      })
    );
    const redirectTarget = url.searchParams.get("redirect_to")!;
    const whatSupabaseSendsBack = `${redirectTarget}&code=auth-code-xyz`;

    const parsed = parseIrisDeepLink(whatSupabaseSendsBack);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok || parsed.link.kind !== "authCallback") {
      throw new Error("the OAuth round trip must produce a valid auth callback");
    }
    expect(parsed.link.authCallback.opaqueStateToken).toBe("state-abc");
    expect(parsed.link.authCallback.authorizationCode).toBe("auth-code-xyz");
  });

  it("never sends the redirect to a host other than the iris scheme", () => {
    const url = new URL(
      authorizationUrl({
        project: PROJECT,
        provider: "google",
        codeChallenge: "c",
        opaqueStateToken: "s",
      })
    );
    expect(url.searchParams.get("redirect_to")!.startsWith("iris://auth/callback")).toBe(true);
  });
});

describe("the token exchange", () => {
  function tokenResponder(options: { status: number; body: string }): {
    fetchImplementation: TokenFetchLike;
    seen: Array<{ url: string; headers: Record<string, string>; body: string }>;
  } {
    const seen: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
    const fetchImplementation: TokenFetchLike = async (url, init) => {
      seen.push({ url, headers: init.headers, body: init.body });
      return {
        ok: options.status >= 200 && options.status < 300,
        status: options.status,
        text: async () => options.body,
      };
    };
    return { fetchImplementation, seen };
  }

  it("posts the code and verifier to the pkce grant with the anon key", async () => {
    const { fetchImplementation, seen } = tokenResponder({
      status: 200,
      body: JSON.stringify({
        access_token: "access",
        refresh_token: "refresh",
        expires_in: 3600,
        user: { email: "a@b.com" },
      }),
    });

    const session = await exchangeAuthorizationCode({
      project: PROJECT,
      authorizationCode: "the-code",
      codeVerifier: "the-verifier",
      fetchImplementation,
    });

    expect(seen[0].url).toBe("https://abcdefgh.supabase.co/auth/v1/token?grant_type=pkce");
    expect(seen[0].headers.apikey).toBe("public-anon-key");
    expect(JSON.parse(seen[0].body)).toEqual({
      auth_code: "the-code",
      code_verifier: "the-verifier",
    });
    expect(session.accessToken).toBe("access");
    expect(session.refreshToken).toBe("refresh");
    expect(session.userEmail).toBe("a@b.com");
  });

  it("turns a rejection into a message without leaking the whole body", async () => {
    const { fetchImplementation } = tokenResponder({
      status: 400,
      body: JSON.stringify({ error: "invalid_grant", error_description: "code verifier mismatch" }),
    });
    await expect(
      exchangeAuthorizationCode({
        project: PROJECT,
        authorizationCode: "c",
        codeVerifier: "v",
        fetchImplementation,
      })
    ).rejects.toThrowError(AccountServiceError);
  });
});

describe("session parsing and refresh timing", () => {
  it("refuses a response with no tokens in it", () => {
    expect(() => parseSessionResponse("{}")).toThrowError(AccountServiceError);
    expect(() => parseSessionResponse('{"access_token":"a"}')).toThrowError(AccountServiceError);
    expect(() => parseSessionResponse("not json")).toThrowError(AccountServiceError);
  });

  it("derives expiry from expires_in when expires_at is absent", () => {
    const nowInSeconds = Math.floor(Date.now() / 1000);
    const session = parseSessionResponse(
      JSON.stringify({ access_token: "a", refresh_token: "r", expires_in: 3600 })
    );
    expect(session.expiresAt).toBeGreaterThanOrEqual(nowInSeconds + 3590);
  });

  it("refreshes a minute early so a request never races expiry", () => {
    const now = 1_000_000;
    expect(sessionNeedsRefresh({ accessToken: "a", refreshToken: "r", expiresAt: now + 3600, userEmail: null }, now)).toBe(false);
    expect(sessionNeedsRefresh({ accessToken: "a", refreshToken: "r", expiresAt: now + 61, userEmail: null }, now)).toBe(false);
    expect(sessionNeedsRefresh({ accessToken: "a", refreshToken: "r", expiresAt: now + 60, userEmail: null }, now)).toBe(true);
    expect(sessionNeedsRefresh({ accessToken: "a", refreshToken: "r", expiresAt: now - 1, userEmail: null }, now)).toBe(true);
  });
});
