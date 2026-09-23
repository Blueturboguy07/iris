import { describe, expect, it } from "vitest";
import { ClaudeService, FetchLike } from "../src/services/claude";
import {
  AssistantTransport,
  AssistantTransportFailure,
} from "../src/services/assistant-transport";

/**
 * The transport tests prove the request BUILDER is safe. This file proves the
 * thing that actually reaches the wire is too — the same property asserted one
 * layer further out, where a future "just add a header here" would show up.
 */

const THE_USERS_KEY = "sk-ant-must-never-reach-publik";
const THE_PUBLIK_KEY = "pk_live_abcdef123456_0123456789abcdef0123456789abcdef";

interface SentRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

function recordingFetch(response: {
  ok?: boolean;
  status?: number;
  body?: string;
  retryAfter?: string | null;
  publikHeaders?: Record<string, string>;
}): { fetchImplementation: FetchLike; sent: SentRequest[] } {
  const sent: SentRequest[] = [];
  const fetchImplementation: FetchLike = async (url, init) => {
    sent.push({ url, headers: init.headers, body: init.body });
    return {
      ok: response.ok ?? true,
      status: response.status ?? 200,
      text: async () => response.body ?? JSON.stringify({ content: [{ type: "text", text: "hi" }] }),
      headers: {
        get: (name) => {
          const lowered = name.toLowerCase();
          if (lowered === "retry-after") return response.retryAfter ?? null;
          return response.publikHeaders?.[lowered] ?? null;
        },
      },
    };
  };
  return { fetchImplementation, sent };
}

const A_QUERY = {
  userMessage: "where is the save button?",
  screenshots: [
    {
      data: "BASE64JPEG",
      imageDimensions: { width: 1568, height: 882 },
      bounds: { x: 0, y: 0, width: 1920, height: 1080 },
    },
  ],
  cursorPosition: { x: 10, y: 10 },
  conversationHistory: [{ role: "user" as const, content: "where is the save button?" }],
};

describe("what actually goes on the wire", () => {
  it("BYO: hits api.anthropic.com carrying x-api-key and no bearer token", async () => {
    const { fetchImplementation, sent } = recordingFetch({});
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    await new ClaudeService({ transport, model: "claude-sonnet-4-5", fetchImplementation }).query(
      A_QUERY
    );

    expect(sent).toHaveLength(1);
    expect(new URL(sent[0].url).hostname).toBe("api.anthropic.com");
    expect(sent[0].headers["x-api-key"]).toBe(THE_USERS_KEY);
    expect(sent[0].headers.Authorization).toBeUndefined();
    // The BYO tier picks its own model, so it must be sent.
    expect(JSON.parse(sent[0].body).model).toBe("claude-sonnet-4-5");
  });

  it("publik: hits the gateway with the publik key, and never the user's own", async () => {
    const { fetchImplementation, sent } = recordingFetch({});
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    await new ClaudeService({ transport, model: "publik-balanced", fetchImplementation }).query(
      A_QUERY
    );

    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe("https://publikhq.com/api/v1/messages");
    expect(sent[0].headers["x-api-key"]).toBe(THE_PUBLIK_KEY);

    // Not merely absent as a header — absent from the whole request.
    expect(JSON.stringify(sent[0])).not.toContain(THE_USERS_KEY);
    // The gateway takes an alias, and the client is the one that picks it.
    expect(JSON.parse(sent[0].body).model).toBe("publik-balanced");
  });

  it("reports the balance the gateway stamped on the response", async () => {
    const { fetchImplementation } = recordingFetch({
      publikHeaders: { "x-publik-balance": "182400", "x-publik-claim-state": "anonymous" },
    });
    const seen: Array<{ balanceMicros: number | null }> = [];
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    await new ClaudeService({
      transport,
      model: "publik-balanced",
      fetchImplementation,
      reportPublikUsage: (usage) => seen.push(usage),
    }).query(A_QUERY);

    expect(seen).toHaveLength(1);
    expect(seen[0].balanceMicros).toBe(182_400);
  });

  it("reports what a settled answer cost, so the settings panel can say what the last reply cost", async () => {
    // A non-streaming answer is settled before its headers are written, so the
    // charge and the balance beside it are final (CONTRACT section 11.6).
    const { fetchImplementation } = recordingFetch({
      publikHeaders: { "x-publik-charge-micros": "4321", "x-publik-balance": "1838889" },
    });
    const seen: Array<{ chargeMicros: number | null; balanceMicros: number | null }> = [];
    await new ClaudeService({
      transport: { tier: "publik", publikApiKey: THE_PUBLIK_KEY, apiBaseUrl: "https://publikhq.com/api/v1" },
      model: "publik-balanced",
      fetchImplementation,
      reportPublikUsage: (usage) => seen.push(usage),
    }).query(A_QUERY);

    expect(seen).toEqual([expect.objectContaining({ chargeMicros: 4_321, balanceMicros: 1_838_889 })]);
  });

  it("caps max_tokens at the documented limit", async () => {
    const { fetchImplementation, sent } = recordingFetch({});
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    await new ClaudeService({ transport, model: "m", fetchImplementation }).query(A_QUERY);
    expect(JSON.parse(sent[0].body).max_tokens).toBeLessThanOrEqual(2048);
  });

  it("never sends more than 50 messages", async () => {
    const { fetchImplementation, sent } = recordingFetch({});
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    const longHistory = Array.from({ length: 200 }, (_unused, index) => ({
      role: (index % 2 === 0 ? "user" : "assistant") as "user" | "assistant",
      content: `message ${index}`,
    }));
    await new ClaudeService({ transport, model: "m", fetchImplementation }).query({
      ...A_QUERY,
      conversationHistory: longHistory,
    });
    expect(JSON.parse(sent[0].body).messages.length).toBeLessThanOrEqual(50);
  });
});

describe("failures reach the user as sentences, not statuses", () => {
  it.each([
    [401, "publikKeyRejected"],
    [429, "rateLimited"],
    [503, "assistantUnavailable"],
    [502, "requestFailed"],
  ])("maps a publik %i to %s", async (status, expectedKind) => {
    const { fetchImplementation } = recordingFetch({ ok: false, status, body: "{}" });
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    const service = new ClaudeService({ transport, model: "m", fetchImplementation });
    await expect(service.query(A_QUERY)).rejects.toThrowError(AssistantTransportFailure);
    await service.query(A_QUERY).catch((error: AssistantTransportFailure) => {
      expect(error.detail.kind).toBe(expectedKind);
    });
  });

  it("reads Retry-After off the response for a 429", async () => {
    const { fetchImplementation } = recordingFetch({
      ok: false,
      status: 429,
      body: "{}",
      retryAfter: "120",
    });
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    await new ClaudeService({ transport, model: "m", fetchImplementation })
      .query(A_QUERY)
      .catch((error: AssistantTransportFailure) => {
        expect(error.detail).toEqual({ kind: "rateLimited", retryAfterSeconds: 120 });
      });
  });

  it("passes a 402's own message straight through to the user", async () => {
    const { fetchImplementation } = recordingFetch({
      ok: false,
      status: 402,
      body: JSON.stringify({
        error: {
          type: "insufficient_credit",
          message: "Not enough publik credit for this request.",
          claim_state: "anonymous",
          top_up_url: "https://publikhq.com/claim/HK7F-2QWD",
        },
      }),
    });
    const transport: AssistantTransport = {
      tier: "publik",
      publikApiKey: THE_PUBLIK_KEY,
      apiBaseUrl: "https://publikhq.com/api/v1",
    };
    await new ClaudeService({ transport, model: "m", fetchImplementation })
      .query(A_QUERY)
      .catch((error: AssistantTransportFailure) => {
        expect(error.detail.kind).toBe("publikCreditExhausted");
        expect(error.message).toBe("Not enough publik credit for this request.");
      });
  });

  it("maps a BYO 401 to a rejected key rather than to a sign-in prompt", async () => {
    const { fetchImplementation } = recordingFetch({ ok: false, status: 401, body: "{}" });
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    await new ClaudeService({ transport, model: "m", fetchImplementation })
      .query(A_QUERY)
      .catch((error: AssistantTransportFailure) => {
        expect(error.detail.kind).toBe("bringYourOwnKeyRejected");
      });
  });
});

describe("second-pass refinement", () => {
  it("parses the x,y the model returns", async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({ content: [{ type: "text", text: "148,203" }] }),
    });
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    const refined = await new ClaudeService({
      transport,
      model: "m",
      fetchImplementation,
    }).refinePoint({ cropBase64: "x", cropWidth: 300, cropHeight: 300, label: "Save button" });
    expect(refined).toEqual({ x: 148, y: 203 });
  });

  it('returns null when the model says "none", so the first-pass estimate survives', async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({ content: [{ type: "text", text: "none" }] }),
    });
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    const refined = await new ClaudeService({
      transport,
      model: "m",
      fetchImplementation,
    }).refinePoint({ cropBase64: "x", cropWidth: 300, cropHeight: 300, label: "Save button" });
    expect(refined).toBeNull();
  });

  it("returns null rather than throwing when refinement fails outright", async () => {
    const { fetchImplementation } = recordingFetch({ ok: false, status: 500, body: "{}" });
    const transport: AssistantTransport = { tier: "byo", anthropicApiKey: THE_USERS_KEY };
    const refined = await new ClaudeService({
      transport,
      model: "m",
      fetchImplementation,
    }).refinePoint({ cropBase64: "x", cropWidth: 300, cropHeight: 300, label: "Save" });
    expect(refined).toBeNull();
  });
});
