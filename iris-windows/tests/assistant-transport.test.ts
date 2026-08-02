import { describe, expect, it } from "vitest";
import {
  ANTHROPIC_API_HOST,
  AssistantTransport,
  AssistantTransportFailure,
  PreparedRequest,
  failureForStatusCode,
  isPublikHost,
  makeChatRequest,
  requiresReSignIn,
  selectTransport,
  serverErrorCodeInFailureBody,
  shouldOfferBringYourOwnKey,
  shouldSendModelInRequestBody,
  userFacingMessage,
  validatedRequest,
} from "../src/services/assistant-transport";

/**
 * The property this file exists to protect: the user's own Anthropic key never
 * reaches a publik host, and the funded route never carries one.
 *
 * It is asserted in BOTH directions on purpose. "The BYO request goes to
 * Anthropic" and "a publik request has no x-api-key" are the same rule seen from
 * two sides, and a refactor can break either one without touching the other.
 */

const THE_USERS_KEY = "sk-ant-this-key-must-never-leave-anthropic";

function headerNames(request: PreparedRequest): string[] {
  return Object.keys(request.headers).map((name) => name.toLowerCase());
}

function byoTransport(): AssistantTransport {
  return { tier: "byo", anthropicApiKey: THE_USERS_KEY };
}

function fundedTransport(publikBaseUrl = "https://publikhq.com"): AssistantTransport {
  return {
    tier: "funded",
    publikBaseUrl,
    currentAccessToken: async () => "supabase-access-token",
  };
}

describe("key isolation — direction 1: the BYO key only ever goes to Anthropic", () => {
  it("sends the BYO request to api.anthropic.com and nowhere else", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(new URL(request.url).hostname).toBe(ANTHROPIC_API_HOST);
    expect(request.url).toBe("https://api.anthropic.com/v1/messages");
  });

  it("attaches the key as x-api-key on that request", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(request.headers["x-api-key"]).toBe(THE_USERS_KEY);
    expect(request.headers["anthropic-version"]).toBe("2023-06-01");
  });

  it("never puts the key in an Authorization header", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(request.headers.Authorization).toBeUndefined();
    expect(JSON.stringify(request.headers)).not.toContain("Bearer");
  });

  it.each([
    "https://publikhq.com/api/assistant/chat",
    "https://www.publikhq.com/api/assistant/chat",
    "https://evil.tld/v1/messages",
    "https://api.anthropic.com.evil.tld/v1/messages",
    "http://localhost:3000/api/assistant/chat",
  ])("refuses to let an x-api-key request reach %s", (url) => {
    const smuggled: PreparedRequest = {
      url,
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": THE_USERS_KEY },
    };
    expect(() => validatedRequest(smuggled)).toThrowError(AssistantTransportFailure);
    try {
      validatedRequest(smuggled);
    } catch (error) {
      const failure = error as AssistantTransportFailure;
      expect(failure.detail.kind).toBe("bringYourOwnKeyWouldLeaveAnthropic");
    }
  });

  it("catches the header even when a refactor spells it with different case", () => {
    const smuggled: PreparedRequest = {
      url: "https://publikhq.com/api/assistant/chat",
      method: "POST",
      headers: { "X-API-Key": THE_USERS_KEY },
    };
    expect(() => validatedRequest(smuggled)).toThrowError(AssistantTransportFailure);
  });

  it("still allows the legitimate Anthropic destination through the same gate", () => {
    const legitimate: PreparedRequest = {
      url: "https://api.anthropic.com/v1/messages",
      method: "POST",
      headers: { "x-api-key": THE_USERS_KEY },
    };
    expect(validatedRequest(legitimate)).toBe(legitimate);
  });
});

describe("key isolation — direction 2: the funded route never sends x-api-key", () => {
  it("builds the funded request with a Bearer token and no key header", async () => {
    const request = await makeChatRequest(fundedTransport());
    expect(request.url).toBe("https://publikhq.com/api/assistant/chat");
    expect(request.headers.Authorization).toBe("Bearer supabase-access-token");
    expect(headerNames(request)).not.toContain("x-api-key");
  });

  it("does not leak the key even when one is also stored on disk", async () => {
    // Signed in AND holding a key is the ordinary state for a user who tried
    // both. The funded route must still carry only the Supabase token.
    const transport = selectTransport({
      isSignedIn: true,
      publikBaseUrl: "https://publikhq.com",
      storedAnthropicApiKey: THE_USERS_KEY,
      currentAccessToken: async () => "supabase-access-token",
    });
    const request = await makeChatRequest(transport);
    expect(headerNames(request)).not.toContain("x-api-key");
    expect(JSON.stringify(request)).not.toContain(THE_USERS_KEY);
  });

  it("reports a missing access token as sign-in required, not as a transport error", async () => {
    const transport: AssistantTransport = {
      tier: "funded",
      publikBaseUrl: "https://publikhq.com",
      currentAccessToken: async () => null,
    };
    await expect(makeChatRequest(transport)).rejects.toThrowError(AssistantTransportFailure);
    await makeChatRequest(transport).catch((error: AssistantTransportFailure) => {
      expect(error.detail.kind).toBe("signInRequired");
    });
  });

  it("knows which hosts are publik's", () => {
    expect(isPublikHost("publikhq.com")).toBe(true);
    expect(isPublikHost("WWW.PUBLIKHQ.COM")).toBe(true);
    expect(isPublikHost("publikhq.com.evil.tld")).toBe(false);
    expect(isPublikHost("api.anthropic.com")).toBe(false);
  });
});

describe("transport selection", () => {
  it("prefers the funded tier when signed in, because it costs the user nothing", () => {
    const transport = selectTransport({
      isSignedIn: true,
      publikBaseUrl: "https://publikhq.com",
      storedAnthropicApiKey: THE_USERS_KEY,
      currentAccessToken: async () => "token",
    });
    expect(transport.tier).toBe("funded");
  });

  it("falls back to a stored key when not signed in", () => {
    const transport = selectTransport({
      isSignedIn: false,
      publikBaseUrl: "https://publikhq.com",
      storedAnthropicApiKey: THE_USERS_KEY,
      currentAccessToken: async () => null,
    });
    expect(transport.tier).toBe("byo");
  });

  it("reports having neither as its own state rather than failing at request time", () => {
    expect(() =>
      selectTransport({
        isSignedIn: false,
        publikBaseUrl: "https://publikhq.com",
        storedAnthropicApiKey: null,
        currentAccessToken: async () => null,
      })
    ).toThrowError(AssistantTransportFailure);
  });

  it("omits the model on the funded route and sends it on the BYO route", () => {
    // The funded server pins the model; sending one it ignores would only make a
    // reader of the code believe the client chose it.
    expect(shouldSendModelInRequestBody(fundedTransport())).toBe(false);
    expect(shouldSendModelInRequestBody(byoTransport())).toBe(true);
  });

  it("normalises a publik base URL that carries a trailing slash", async () => {
    const request = await makeChatRequest(fundedTransport("https://publikhq.com/"));
    expect(request.url).toBe("https://publikhq.com/api/assistant/chat");
  });
});

describe("funded-tier error codes map to user-visible states", () => {
  it("maps 401 on the funded route to sign-in required", () => {
    const detail = failureForStatusCode({
      statusCode: 401,
      serverErrorCode: "sign_in_required",
      retryAfterHeaderValue: null,
      isFundedTier: true,
    });
    expect(detail.kind).toBe("signInRequired");
    expect(requiresReSignIn(detail)).toBe(true);
    expect(shouldOfferBringYourOwnKey(detail)).toBe(false);
  });

  it("maps 401 on the BYO route to a rejected key — the same status, the opposite meaning", () => {
    const detail = failureForStatusCode({
      statusCode: 401,
      serverErrorCode: null,
      retryAfterHeaderValue: null,
      isFundedTier: false,
    });
    expect(detail.kind).toBe("bringYourOwnKeyRejected");
    expect(requiresReSignIn(detail)).toBe(false);
  });

  it("maps 429 rate_limited with Retry-After to a quota state carrying the delay", () => {
    const detail = failureForStatusCode({
      statusCode: 429,
      serverErrorCode: "rate_limited",
      retryAfterHeaderValue: "45",
      isFundedTier: true,
    });
    expect(detail).toEqual({ kind: "rateLimited", retryAfterSeconds: 45 });
    expect(shouldOfferBringYourOwnKey(detail)).toBe(true);
    expect(userFacingMessage(detail)).toContain("45 seconds");
  });

  it("distinguishes daily_budget_exhausted from a plain rate limit", () => {
    const detail = failureForStatusCode({
      statusCode: 429,
      serverErrorCode: "daily_budget_exhausted",
      retryAfterHeaderValue: "7200",
      isFundedTier: true,
    });
    expect(detail.kind).toBe("dailyBudgetExhausted");
    expect(shouldOfferBringYourOwnKey(detail)).toBe(true);
    // 7200s is two hours; the sentence must not read "7200 seconds".
    expect(userFacingMessage(detail)).toContain("2 hours");
  });

  it("tolerates a missing or unparseable Retry-After", () => {
    for (const headerValue of [null, "", "soon", "Wed, 21 Oct 2026 07:28:00 GMT"]) {
      const detail = failureForStatusCode({
        statusCode: 429,
        serverErrorCode: "rate_limited",
        retryAfterHeaderValue: headerValue,
        isFundedTier: true,
      });
      expect(detail).toEqual({ kind: "rateLimited", retryAfterSeconds: null });
      expect(userFacingMessage(detail)).toContain("try again shortly");
    }
  });

  it("maps 503 assistant_unconfigured to an outage that is not the user's fault", () => {
    const detail = failureForStatusCode({
      statusCode: 503,
      serverErrorCode: "assistant_unconfigured",
      retryAfterHeaderValue: null,
      isFundedTier: true,
    });
    expect(detail.kind).toBe("assistantUnavailable");
    expect(userFacingMessage(detail)).toContain("on publik, not you");
  });

  it.each([400, 402, 418, 500, 502, 504])("maps %i to a generic failure", (statusCode) => {
    const detail = failureForStatusCode({
      statusCode,
      serverErrorCode: "upstream_error",
      retryAfterHeaderValue: null,
      isFundedTier: true,
    });
    expect(detail).toEqual({ kind: "requestFailed", statusCode });
  });

  it("never surfaces the server's own body to the user", () => {
    const body = JSON.stringify({
      error: "upstream_error",
      detail: "the model said something embarrassing about the user",
    });
    expect(serverErrorCodeInFailureBody(body)).toBe("upstream_error");
    const detail = failureForStatusCode({
      statusCode: 502,
      serverErrorCode: serverErrorCodeInFailureBody(body),
      retryAfterHeaderValue: null,
      isFundedTier: true,
    });
    expect(userFacingMessage(detail)).not.toContain("embarrassing");
    expect(userFacingMessage(detail)).not.toContain("upstream_error");
  });

  it("reads no error code out of a body that is not JSON", () => {
    expect(serverErrorCodeInFailureBody("<html>502 Bad Gateway</html>")).toBeNull();
    expect(serverErrorCodeInFailureBody("{}")).toBeNull();
    expect(serverErrorCodeInFailureBody('{"error": ""}')).toBeNull();
  });

  it("gives every failure a sentence with no status code in it", () => {
    const everyFailure = [
      { kind: "noCredentialsAvailable" },
      { kind: "signInRequired" },
      { kind: "rateLimited", retryAfterSeconds: 10 },
      { kind: "dailyBudgetExhausted", retryAfterSeconds: null },
      { kind: "assistantUnavailable" },
      { kind: "requestFailed", statusCode: 500 },
      { kind: "bringYourOwnKeyRejected" },
      { kind: "transportFailure", reason: "ECONNREFUSED" },
      { kind: "bringYourOwnKeyWouldLeaveAnthropic", attemptedHost: "evil.tld" },
    ] as const;
    for (const detail of everyFailure) {
      const message = userFacingMessage(detail);
      expect(message.length).toBeGreaterThan(10);
      expect(message).not.toMatch(/\b[45]\d\d\b/);
    }
  });
});
