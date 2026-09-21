import { describe, expect, it } from "vitest";
import {
  ANTHROPIC_API_HOST,
  AssistantTransport,
  AssistantTransportFailure,
  CredentialKind,
  PreparedRequest,
  credentialMayReachHost,
  defaultModelForTransport,
  failureForStatusCode,
  isPublikHost,
  makeChatRequest,
  preferenceDescription,
  requiresSetup,
  selectTransport,
  shouldOfferTopUp,
  shouldSendModelInRequestBody,
  userFacingMessage,
  validatedRequest,
} from "../src/services/assistant-transport";

/**
 * The property this file exists to protect: a credential only ever reaches the
 * host that issued it. The user's own Anthropic key never reaches a publik
 * host, and a publik key never reaches Anthropic.
 *
 * It is asserted in BOTH directions on purpose, for BOTH credentials. "The BYO
 * request goes to Anthropic" and "a publik request never carries the user's
 * key" are the same rule seen from two sides, and a refactor can break either
 * one without touching the other.
 */

const THE_USERS_KEY = "sk-ant-this-key-must-never-leave-anthropic";
const THE_PUBLIK_KEY = "pk_live_abcdef123456_0123456789abcdef0123456789abcdef";
const PUBLIK_API_BASE = "https://publikhq.com/api/v1";

function headerNames(request: PreparedRequest): string[] {
  return Object.keys(request.headers).map((name) => name.toLowerCase());
}

function byoTransport(): AssistantTransport {
  return { tier: "byo", anthropicApiKey: THE_USERS_KEY };
}

function publikTransport(apiBaseUrl = PUBLIK_API_BASE): AssistantTransport {
  return { tier: "publik", publikApiKey: THE_PUBLIK_KEY, apiBaseUrl };
}

describe("credential isolation — the permitted-host table", () => {
  it("lets the Anthropic key reach Anthropic and nothing else", () => {
    expect(credentialMayReachHost("anthropicApiKey", ANTHROPIC_API_HOST)).toBe(true);
    expect(credentialMayReachHost("anthropicApiKey", "publikhq.com")).toBe(false);
    expect(credentialMayReachHost("anthropicApiKey", "www.publikhq.com")).toBe(false);
    expect(credentialMayReachHost("anthropicApiKey", "evil.example.com")).toBe(false);
  });

  it("lets the publik key reach publik and nothing else", () => {
    expect(credentialMayReachHost("publikApiKey", "publikhq.com")).toBe(true);
    expect(credentialMayReachHost("publikApiKey", "www.publikhq.com")).toBe(true);
    // Sending a publik key to Anthropic would both leak it and fail, since
    // Anthropic never issued it.
    expect(credentialMayReachHost("publikApiKey", ANTHROPIC_API_HOST)).toBe(false);
    expect(credentialMayReachHost("publikApiKey", "evil.example.com")).toBe(false);
  });

  it("is case-insensitive about the host", () => {
    expect(credentialMayReachHost("anthropicApiKey", "API.ANTHROPIC.COM")).toBe(true);
    expect(credentialMayReachHost("publikApiKey", "PublikHQ.com")).toBe(true);
  });

  it("knows which hosts are publik's", () => {
    expect(isPublikHost("publikhq.com")).toBe(true);
    expect(isPublikHost("WWW.PUBLIKHQ.COM")).toBe(true);
    expect(isPublikHost("api.anthropic.com")).toBe(false);
  });
});

describe("credential isolation — direction 1: the BYO key only ever goes to Anthropic", () => {
  it("sends the BYO request to api.anthropic.com and nowhere else", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(new URL(request.url).hostname).toBe(ANTHROPIC_API_HOST);
    expect(request.url).toBe("https://api.anthropic.com/v1/messages");
  });

  it("attaches the key as x-api-key and declares which credential it is", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(request.headers["x-api-key"]).toBe(THE_USERS_KEY);
    expect(request.credentialKind).toBe("anthropicApiKey");
  });

  it("never puts the key in an Authorization header", async () => {
    const request = await makeChatRequest(byoTransport());
    expect(headerNames(request)).not.toContain("authorization");
  });

  it("refuses a hand-built request that would send the Anthropic key to publik", () => {
    expect(() =>
      validatedRequest({
        url: "https://publikhq.com/api/v1/messages",
        method: "POST",
        headers: { "x-api-key": THE_USERS_KEY },
        credentialKind: "anthropicApiKey",
      })
    ).toThrow(AssistantTransportFailure);
  });

  it("catches the header even when a refactor spells it with different case", () => {
    expect(() =>
      validatedRequest({
        url: "https://publikhq.com/api/v1/messages",
        method: "POST",
        headers: { "X-API-Key": THE_USERS_KEY },
        credentialKind: "anthropicApiKey",
      })
    ).toThrow(AssistantTransportFailure);
  });

  it("still allows the legitimate Anthropic destination through the same gate", () => {
    const request = validatedRequest({
      url: `https://${ANTHROPIC_API_HOST}/v1/messages`,
      method: "POST",
      headers: { "x-api-key": THE_USERS_KEY },
      credentialKind: "anthropicApiKey",
    });
    expect(request.headers["x-api-key"]).toBe(THE_USERS_KEY);
  });
});

describe("credential isolation — direction 2: the publik key only ever goes to publik", () => {
  it("sends the publik request to the gateway's /messages", async () => {
    const request = await makeChatRequest(publikTransport());
    expect(request.url).toBe("https://publikhq.com/api/v1/messages");
    expect(request.credentialKind).toBe("publikApiKey");
  });

  it("carries the publik key and never the user's Anthropic key", async () => {
    const request = await makeChatRequest(publikTransport());
    expect(request.headers["x-api-key"]).toBe(THE_PUBLIK_KEY);
    expect(JSON.stringify(request)).not.toContain(THE_USERS_KEY);
  });

  it("normalises a base URL that carries a trailing slash", async () => {
    const request = await makeChatRequest(publikTransport("https://publikhq.com/api/v1/"));
    expect(request.url).toBe("https://publikhq.com/api/v1/messages");
  });

  it("refuses to build a request when the base URL is not a publik host", async () => {
    // The builder validates its destination BEFORE writing the header, so a
    // hostile base URL never reaches the point of carrying a key.
    await expect(makeChatRequest(publikTransport("https://evil.example.com/api/v1"))).rejects.toThrow(
      AssistantTransportFailure
    );
  });

  it("refuses to send the publik key to Anthropic", () => {
    expect(() =>
      validatedRequest({
        url: `https://${ANTHROPIC_API_HOST}/v1/messages`,
        method: "POST",
        headers: { "x-api-key": THE_PUBLIK_KEY },
        credentialKind: "publikApiKey",
      })
    ).toThrow(AssistantTransportFailure);
  });

  it("names the credential that was about to escape", () => {
    try {
      validatedRequest({
        url: "https://evil.example.com/v1/messages",
        method: "POST",
        headers: { "x-api-key": THE_PUBLIK_KEY },
        credentialKind: "publikApiKey",
      });
      throw new Error("expected the gate to refuse this request");
    } catch (error) {
      const failure = error as AssistantTransportFailure;
      expect(failure.detail.kind).toBe("credentialWouldLeaveItsHost");
      if (failure.detail.kind === "credentialWouldLeaveItsHost") {
        expect(failure.detail.credentialKind).toBe<CredentialKind>("publikApiKey");
        expect(failure.detail.attemptedHost).toBe("evil.example.com");
      }
    }
  });
});

describe("credential isolation — an undeclared key cannot sneak past", () => {
  it("refuses a key header on a request that declares no credential", () => {
    expect(() =>
      validatedRequest({
        url: "https://publikhq.com/api/v1/messages",
        method: "POST",
        headers: { "x-api-key": THE_USERS_KEY },
        credentialKind: null,
      })
    ).toThrow(AssistantTransportFailure);
  });

  it("allows a credential-free request to anywhere, since it carries no secret", () => {
    const request = validatedRequest({
      url: "https://publikhq.com/api/iris/guides/cue",
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentialKind: null,
    });
    expect(request.credentialKind).toBeNull();
  });

  it("refuses a malformed URL rather than guessing at its host", () => {
    expect(() =>
      validatedRequest({
        url: "not a url",
        method: "POST",
        headers: {},
        credentialKind: null,
      })
    ).toThrow(AssistantTransportFailure);
  });
});

describe("transport selection", () => {
  const noProviders = {
    preference: null,
    storedPublikApiKey: null,
    publikApiBaseUrl: PUBLIK_API_BASE,
    storedAnthropicApiKey: null,
    codexIsAvailable: false,
  };

  it("prefers publik API when nothing has been chosen, because it is the default", () => {
    const transport = selectTransport({
      ...noProviders,
      storedPublikApiKey: THE_PUBLIK_KEY,
      storedAnthropicApiKey: THE_USERS_KEY,
      codexIsAvailable: true,
    });
    expect(transport.tier).toBe("publik");
  });

  it("falls to a stored Anthropic key when there is no publik key", () => {
    const transport = selectTransport({
      ...noProviders,
      storedAnthropicApiKey: THE_USERS_KEY,
      codexIsAvailable: true,
    });
    expect(transport.tier).toBe("byo");
  });

  it("falls to codex when it is the only thing available", () => {
    const transport = selectTransport({ ...noProviders, codexIsAvailable: true });
    expect(transport.tier).toBe("codex");
  });

  it("reports having nothing as its own state rather than failing at request time", () => {
    expect(() => selectTransport(noProviders)).toThrow(AssistantTransportFailure);
    try {
      selectTransport(noProviders);
    } catch (error) {
      expect((error as AssistantTransportFailure).detail.kind).toBe("noCredentialsAvailable");
    }
  });

  it("honours an explicit choice even when another provider would work", () => {
    const transport = selectTransport({
      ...noProviders,
      preference: "anthropicKey",
      storedPublikApiKey: THE_PUBLIK_KEY,
      storedAnthropicApiKey: THE_USERS_KEY,
    });
    expect(transport.tier).toBe("byo");
  });

  it("never silently switches away from a chosen provider that broke", () => {
    // The whole point: spending someone's money on an account they did not
    // pick is worse than an error message.
    try {
      selectTransport({
        ...noProviders,
        preference: "anthropicKey",
        storedPublikApiKey: THE_PUBLIK_KEY,
        storedAnthropicApiKey: null,
      });
      throw new Error("expected the chosen provider to be reported as unavailable");
    } catch (error) {
      const failure = error as AssistantTransportFailure;
      expect(failure.detail.kind).toBe("chosenProviderUnavailable");
      if (failure.detail.kind === "chosenProviderUnavailable") {
        expect(failure.detail.preference).toBe("anthropicKey");
      }
    }
  });

  it("sends a model on both HTTP routes now that nothing pins one server-side", () => {
    expect(shouldSendModelInRequestBody(publikTransport())).toBe(true);
    expect(shouldSendModelInRequestBody(byoTransport())).toBe(true);
  });

  it("gives publik its own alias and leaves the configured model to the BYO route", () => {
    expect(defaultModelForTransport(publikTransport(), "claude-sonnet-4-5")).toBe("publik-balanced");
    expect(defaultModelForTransport(byoTransport(), "claude-sonnet-4-5")).toBe("claude-sonnet-4-5");
  });

  it("has no funded tier left to select", () => {
    const tiers = [publikTransport().tier, byoTransport().tier, "codex"];
    expect(tiers).not.toContain("funded");
  });
});

describe("failures map to user-visible states", () => {
  it("maps 401 on the publik route to a stale install key", () => {
    const detail = failureForStatusCode({
      statusCode: 401,
      rawBody: JSON.stringify({ error: { type: "key_revoked", reprovision: true } }),
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    expect(detail.kind).toBe("publikKeyRejected");
    if (detail.kind === "publikKeyRejected") expect(detail.mayReprovision).toBe(true);
    expect(requiresSetup(detail)).toBe(true);
  });

  it("does not offer reprovisioning for a plain invalid key", () => {
    const detail = failureForStatusCode({
      statusCode: 401,
      rawBody: JSON.stringify({ error: { type: "invalid_api_key" } }),
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    if (detail.kind === "publikKeyRejected") expect(detail.mayReprovision).toBe(false);
  });

  it("maps 401 on the BYO route to a rejected key — the same status, the opposite meaning", () => {
    const detail = failureForStatusCode({
      statusCode: 401,
      rawBody: "",
      retryAfterHeaderValue: null,
      tier: "byo",
    });
    expect(detail.kind).toBe("bringYourOwnKeyRejected");
  });

  it("renders the gateway's own 402 message and exactly one link", () => {
    const detail = failureForStatusCode({
      statusCode: 402,
      rawBody: JSON.stringify({
        error: {
          type: "insufficient_credit",
          message: "Not enough publik credit for this request.",
          claim_state: "anonymous",
          top_up_url: "https://publikhq.com/claim/HK7F-2QWD",
          claim_url: "https://publikhq.com/claim/HK7F-2QWD",
          add_credit_url: "https://publikhq.com/dashboard/api/add",
        },
      }),
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    expect(detail.kind).toBe("publikCreditExhausted");
    if (detail.kind === "publikCreditExhausted") {
      // Verbatim — CONTRACT section 12 (3) requires the server's wording.
      expect(detail.message).toBe("Not enough publik credit for this request.");
      expect(detail.topUpUrl).toBe("https://publikhq.com/claim/HK7F-2QWD");
      expect(userFacingMessage(detail)).toBe("Not enough publik credit for this request.");
    }
    expect(shouldOfferTopUp(detail)).toBe(true);
  });

  it("does not mistake an unreadable 402 for a credit state", () => {
    const detail = failureForStatusCode({
      statusCode: 402,
      rawBody: "<html>gateway said no</html>",
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    expect(detail.kind).toBe("requestFailed");
  });

  it("maps 429 with Retry-After to a quota state carrying the delay", () => {
    const detail = failureForStatusCode({
      statusCode: 429,
      rawBody: "",
      retryAfterHeaderValue: "45",
      tier: "publik",
    });
    expect(detail.kind).toBe("rateLimited");
    if (detail.kind === "rateLimited") expect(detail.retryAfterSeconds).toBe(45);
    expect(userFacingMessage(detail)).toContain("45 seconds");
  });

  it("tolerates a missing or unparseable Retry-After", () => {
    for (const headerValue of [null, "soon"]) {
      const detail = failureForStatusCode({
        statusCode: 429,
        rawBody: "",
        retryAfterHeaderValue: headerValue,
        tier: "publik",
      });
      if (detail.kind === "rateLimited") expect(detail.retryAfterSeconds).toBeNull();
    }
  });

  it("maps 503 to an outage that is not the user's fault", () => {
    const detail = failureForStatusCode({
      statusCode: 503,
      rawBody: "",
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    expect(detail.kind).toBe("assistantUnavailable");
    expect(userFacingMessage(detail)).toContain("on publik, not you");
  });

  it("never surfaces the server's own body for an unknown status", () => {
    const detail = failureForStatusCode({
      statusCode: 500,
      rawBody: JSON.stringify({ error: { message: "the model said something embarrassing" } }),
      retryAfterHeaderValue: null,
      tier: "publik",
    });
    expect(userFacingMessage(detail)).not.toContain("embarrassing");
  });

  it("gives every failure a sentence with no status code in it", () => {
    const details = [
      { kind: "noCredentialsAvailable" },
      { kind: "chosenProviderUnavailable", preference: "codex" },
      { kind: "publikKeyRejected", mayReprovision: false },
      { kind: "rateLimited", retryAfterSeconds: 10 },
      { kind: "assistantUnavailable" },
      { kind: "requestFailed", statusCode: 500 },
      { kind: "bringYourOwnKeyRejected" },
      { kind: "codexUnavailable", reason: "the codex command isn't installed" },
      { kind: "transportFailure", reason: "offline" },
      { kind: "credentialWouldLeaveItsHost", credentialKind: "publikApiKey", attemptedHost: "x.com" },
    ] as const;
    for (const detail of details) {
      const message = userFacingMessage(detail);
      expect(message.length, detail.kind).toBeGreaterThan(10);
      expect(message, detail.kind).not.toContain("500");
    }
  });

  it("names the provider a user picked when telling them it broke", () => {
    expect(preferenceDescription("publikApi")).toBe("publik API");
    expect(userFacingMessage({ kind: "chosenProviderUnavailable", preference: "publikApi" })).toContain(
      "publik API"
    );
  });
});
