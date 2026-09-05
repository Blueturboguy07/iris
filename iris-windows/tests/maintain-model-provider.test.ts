import { describe, expect, it } from "vitest";
import type { FetchLike } from "../src/services/claude";
import {
  AnthropicMaintainProvider,
  MaintainModelProviderFailure,
  OpenAIMaintainProvider,
  firstAvailableMaintainProvider,
  type MaintainModelRespondOptions,
} from "../src/services/maintain/model-provider";

/**
 * `model-provider.ts` — Tier C's (and Tier B's) BYO-only model access. The
 * property under test throughout is the same one `assistant-transport.ts`
 * and `claude-service.test.ts` already prove one layer down: whatever this
 * file does, it must never reach a publik host, and it must never run
 * without the user's own key. `firstAvailableMaintainProvider` never grows a
 * funded branch — there is nothing here for one to grow from.
 */

interface RecordedCall {
  readonly url: string;
  readonly headers: Record<string, string>;
  readonly body: string;
}

function recordingFetch(response: {
  ok?: boolean;
  status?: number;
  body?: string;
}): { fetchImplementation: FetchLike; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const fetchImplementation: FetchLike = async (url, init) => {
    calls.push({ url, headers: init.headers, body: init.body });
    return {
      ok: response.ok ?? true,
      status: response.status ?? 200,
      text: async () => response.body ?? "{}",
      headers: { get: () => null },
    };
  };
  return { fetchImplementation, calls };
}

function throwingFetch(message = "network down"): FetchLike {
  return async () => {
    throw new Error(message);
  };
}

const A_TURN: MaintainModelRespondOptions = {
  systemPrompt: "system prompt",
  conversation: [{ role: "user", text: "hello" }],
  maximumOutputTokens: 500,
};

async function failureDetail(promise: Promise<unknown>) {
  try {
    await promise;
    throw new Error("expected the promise to reject");
  } catch (error) {
    if (!(error instanceof MaintainModelProviderFailure)) throw error;
    return error.detail;
  }
}

describe("AnthropicMaintainProvider", () => {
  it("isAvailable reflects only whether a key is present", () => {
    expect(new AnthropicMaintainProvider(() => null).isAvailable()).toBe(false);
    expect(new AnthropicMaintainProvider(() => "").isAvailable()).toBe(false);
    expect(new AnthropicMaintainProvider(() => "sk-ant-real").isAvailable()).toBe(true);
  });

  it("throws noCredential rather than calling fetch at all when there is no key", async () => {
    const { fetchImplementation, calls } = recordingFetch({});
    const provider = new AnthropicMaintainProvider(() => null, fetchImplementation);
    expect(await failureDetail(provider.respond(A_TURN))).toEqual({ kind: "noCredential" });
    expect(calls).toHaveLength(0);
  });

  it("NEVER reaches a publik host — hits api.anthropic.com with x-api-key, never a bearer token", async () => {
    const { fetchImplementation, calls } = recordingFetch({
      body: JSON.stringify({ content: [{ type: "text", text: "diagnosis: stale cache" }] }),
    });
    const provider = new AnthropicMaintainProvider(() => "sk-ant-the-users-key", fetchImplementation);
    const text = await provider.respond(A_TURN);

    expect(text).toBe("diagnosis: stale cache");
    expect(calls).toHaveLength(1);
    expect(new URL(calls[0].url).hostname).toBe("api.anthropic.com");
    expect(calls[0].headers["x-api-key"]).toBe("sk-ant-the-users-key");
    expect(calls[0].headers.Authorization).toBeUndefined();
    expect(JSON.stringify(calls[0])).not.toContain("publikhq.com");

    const sentBody = JSON.parse(calls[0].body);
    expect(sentBody.model).toBe("claude-sonnet-4-5-20250929");
    expect(sentBody.system).toBe("system prompt");
    expect(sentBody.messages).toEqual([{ role: "user", content: "hello" }]);
    expect(sentBody.max_tokens).toBe(500);
  });

  it("joins multiple text content blocks and drops non-text blocks", async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({
        content: [
          { type: "text", text: "first " },
          { type: "tool_use", name: "ignored" },
          { type: "text", text: "second" },
        ],
      }),
    });
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", fetchImplementation);
    expect(await provider.respond(A_TURN)).toBe("first second");
  });

  it("wraps a non-2xx response into requestFailed with the status code", async () => {
    const { fetchImplementation } = recordingFetch({ ok: false, status: 529, body: "{}" });
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", fetchImplementation);
    expect(await failureDetail(provider.respond(A_TURN))).toEqual({
      kind: "requestFailed",
      reason: "HTTP 529",
    });
  });

  it("wraps unparseable JSON into requestFailed rather than throwing a raw parse error", async () => {
    const { fetchImplementation } = recordingFetch({ body: "not json at all" });
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", fetchImplementation);
    const detail = await failureDetail(provider.respond(A_TURN));
    expect(detail.kind).toBe("requestFailed");
  });

  it("wraps a thrown network error into requestFailed", async () => {
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", throwingFetch("DNS failure"));
    expect(await failureDetail(provider.respond(A_TURN))).toEqual({
      kind: "requestFailed",
      reason: "DNS failure",
    });
  });
});

describe("OpenAIMaintainProvider", () => {
  it("isAvailable reflects only whether a key is present", () => {
    expect(new OpenAIMaintainProvider(() => null).isAvailable()).toBe(false);
    expect(new OpenAIMaintainProvider(() => "sk-proj-real").isAvailable()).toBe(true);
  });

  it("throws noCredential rather than calling fetch at all when there is no key", async () => {
    const { fetchImplementation, calls } = recordingFetch({});
    const provider = new OpenAIMaintainProvider(() => null, fetchImplementation);
    expect(await failureDetail(provider.respond(A_TURN))).toEqual({ kind: "noCredential" });
    expect(calls).toHaveLength(0);
  });

  it("hits api.openai.com/v1/chat/completions with a bearer token, gpt-4o, temperature 0", async () => {
    const { fetchImplementation, calls } = recordingFetch({
      body: JSON.stringify({ choices: [{ message: { content: "try reinstalling the driver" } }] }),
    });
    const provider = new OpenAIMaintainProvider(() => "sk-the-users-openai-key", fetchImplementation);
    const text = await provider.respond(A_TURN);

    expect(text).toBe("try reinstalling the driver");
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://api.openai.com/v1/chat/completions");
    expect(calls[0].headers.Authorization).toBe("Bearer sk-the-users-openai-key");
    expect(JSON.stringify(calls[0])).not.toContain("publikhq.com");

    const sentBody = JSON.parse(calls[0].body);
    expect(sentBody.model).toBe("gpt-4o");
    expect(sentBody.temperature).toBe(0);
    // The system prompt rides as the first message — OpenAI has no separate field.
    expect(sentBody.messages[0]).toEqual({ role: "system", content: "system prompt" });
    expect(sentBody.messages[1]).toEqual({ role: "user", content: "hello" });
  });

  it("treats a response with no message content as requestFailed, not a crash", async () => {
    const { fetchImplementation } = recordingFetch({ body: JSON.stringify({ choices: [{}] }) });
    const provider = new OpenAIMaintainProvider(() => "sk-key", fetchImplementation);
    const detail = await failureDetail(provider.respond(A_TURN));
    expect(detail.kind).toBe("requestFailed");
  });

  it("wraps a non-2xx response into requestFailed with the status code", async () => {
    const { fetchImplementation } = recordingFetch({ ok: false, status: 401, body: "{}" });
    const provider = new OpenAIMaintainProvider(() => "sk-key", fetchImplementation);
    expect(await failureDetail(provider.respond(A_TURN))).toEqual({
      kind: "requestFailed",
      reason: "HTTP 401",
    });
  });
});

describe("firstAvailableMaintainProvider — resolution, never the funded proxy", () => {
  it("prefers Anthropic when both keys are present", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => "sk-ant-a",
      readOpenAiApiKey: () => "sk-openai-b",
    });
    expect(provider).toBeInstanceOf(AnthropicMaintainProvider);
  });

  it("falls back to OpenAI when only that key is present", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => null,
      readOpenAiApiKey: () => "sk-openai-b",
    });
    expect(provider).toBeInstanceOf(OpenAIMaintainProvider);
  });

  it("returns undefined — the honest funded-tier ceiling — when neither key is present", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => null,
      readOpenAiApiKey: () => null,
    });
    expect(provider).toBeUndefined();
  });
});

describe("the per-call timeout (finding: the model call was the one unbounded wait)", () => {
  /** A fetch that never resolves — a hung TCP connection / broken proxy. */
  function hangingFetch(): FetchLike {
    return () => new Promise(() => {});
  }

  it("Anthropic: a stalled request is abandoned as requestFailed rather than blocking forever", async () => {
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", hangingFetch(), 20);
    const detail = await failureDetail(provider.respond(A_TURN));
    expect(detail.kind).toBe("requestFailed");
    if (detail.kind === "requestFailed") {
      expect(detail.reason).toMatch(/didn't respond in time/i);
    }
  });

  it("OpenAI: a stalled request is abandoned as requestFailed rather than blocking forever", async () => {
    const provider = new OpenAIMaintainProvider(() => "sk-openai-key", hangingFetch(), 20);
    const detail = await failureDetail(provider.respond(A_TURN));
    expect(detail.kind).toBe("requestFailed");
    if (detail.kind === "requestFailed") {
      expect(detail.reason).toMatch(/didn't respond in time/i);
    }
  });

  it("a request that answers within the deadline is unaffected by the bound", async () => {
    const { fetchImplementation } = recordingFetch({
      body: JSON.stringify({ content: [{ type: "text", text: "on time" }] }),
    });
    // A generous bound the instant fake resolves well inside.
    const provider = new AnthropicMaintainProvider(() => "sk-ant-key", fetchImplementation, 10_000);
    expect(await provider.respond(A_TURN)).toBe("on time");
  });
});
