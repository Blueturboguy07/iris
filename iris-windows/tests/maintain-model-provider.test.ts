import { describe, expect, it } from "vitest";
import type { FetchLike } from "../src/services/claude";
import {
  AnthropicMaintainProvider,
  MaintainModelProviderFailure,
  OpenAIMaintainProvider,
  firstAvailableMaintainProvider,
} from "../src/services/maintain/model-provider";

/**
 * Tier C (and Tier B's adapter) run on the user's OWN model access, never the
 * funded proxy. These tests prove the resolver picks Anthropic first, that an
 * absent key is a terminal `noCredential` rather than a silent fallback to
 * anywhere else, and that both providers speak the same one-turn interface.
 */

const THE_USERS_ANTHROPIC_KEY = "sk-ant-maintain-mode-test";
const THE_USERS_OPENAI_KEY = "sk-openai-maintain-mode-test";

interface SentRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

function recordingFetch(responseText = JSON.stringify({ content: [{ type: "text", text: "hi" }] })): {
  fetchImplementation: FetchLike;
  sent: SentRequest[];
} {
  const sent: SentRequest[] = [];
  const fetchImplementation: FetchLike = async (url, init) => {
    sent.push({ url, headers: init.headers, body: init.body });
    return {
      ok: true,
      status: 200,
      text: async () => responseText,
      headers: { get: () => null },
    };
  };
  return { fetchImplementation, sent };
}

function failingFetch(status: number, body = "{}"): FetchLike {
  return async () => ({
    ok: false,
    status,
    text: async () => body,
    headers: { get: () => null },
  });
}

const A_CONVERSATION = [{ role: "user" as const, text: "the app hangs when I open Settings" }];

describe("AnthropicMaintainProvider", () => {
  it("is unavailable with no stored key, and refuses to send anything", async () => {
    const provider = new AnthropicMaintainProvider(() => null);
    expect(provider.isAvailable()).toBe(false);

    await expect(
      provider.respond({ systemPrompt: "sys", conversation: A_CONVERSATION, maximumOutputTokens: 100 }),
    ).rejects.toThrow(MaintainModelProviderFailure);
  });

  it("hits api.anthropic.com with x-api-key and never a bearer token", async () => {
    const { fetchImplementation, sent } = recordingFetch();
    const provider = new AnthropicMaintainProvider(() => THE_USERS_ANTHROPIC_KEY, fetchImplementation);
    expect(provider.isAvailable()).toBe(true);

    const text = await provider.respond({
      systemPrompt: "You adapt patches.",
      conversation: A_CONVERSATION,
      maximumOutputTokens: 500,
    });

    expect(text).toBe("hi");
    expect(sent).toHaveLength(1);
    expect(new URL(sent[0].url).hostname).toBe("api.anthropic.com");
    expect(sent[0].headers["x-api-key"]).toBe(THE_USERS_ANTHROPIC_KEY);
    expect(sent[0].headers.Authorization).toBeUndefined();

    const body = JSON.parse(sent[0].body);
    expect(body.system).toBe("You adapt patches.");
    expect(body.max_tokens).toBe(500);
    expect(body.messages).toEqual([{ role: "user", content: "the app hangs when I open Settings" }]);

    // The key never appears anywhere else in the request.
    expect(JSON.stringify(sent[0])).not.toContain(THE_USERS_OPENAI_KEY);
  });

  it("surfaces a rejected key as requestFailed, not a thrown network error", async () => {
    const provider = new AnthropicMaintainProvider(
      () => THE_USERS_ANTHROPIC_KEY,
      failingFetch(401, JSON.stringify({ error: "invalid key" })),
    );
    await expect(
      provider.respond({ systemPrompt: "sys", conversation: A_CONVERSATION, maximumOutputTokens: 100 }),
    ).rejects.toMatchObject({ detail: { kind: "requestFailed" } });
  });
});

describe("OpenAIMaintainProvider", () => {
  it("is unavailable with no stored key", () => {
    const provider = new OpenAIMaintainProvider(() => null);
    expect(provider.isAvailable()).toBe(false);
  });

  it("hits api.openai.com with a bearer token and the gpt-4o model", async () => {
    const { fetchImplementation, sent } = recordingFetch(
      JSON.stringify({ choices: [{ message: { content: "adapted diff" } }] }),
    );
    const provider = new OpenAIMaintainProvider(() => THE_USERS_OPENAI_KEY, fetchImplementation);

    const text = await provider.respond({
      systemPrompt: "You adapt patches.",
      conversation: A_CONVERSATION,
      maximumOutputTokens: 300,
    });

    expect(text).toBe("adapted diff");
    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe("https://api.openai.com/v1/chat/completions");
    expect(sent[0].headers.Authorization).toBe(`Bearer ${THE_USERS_OPENAI_KEY}`);

    const body = JSON.parse(sent[0].body);
    expect(body.model).toBe("gpt-4o");
    expect(body.messages[0]).toEqual({ role: "system", content: "You adapt patches." });
    expect(body.messages[1]).toEqual({ role: "user", content: "the app hangs when I open Settings" });
  });

  it("rejects when the response carries no message content", async () => {
    const provider = new OpenAIMaintainProvider(
      () => THE_USERS_OPENAI_KEY,
      recordingFetch(JSON.stringify({ choices: [] })).fetchImplementation,
    );
    await expect(
      provider.respond({ systemPrompt: "sys", conversation: A_CONVERSATION, maximumOutputTokens: 100 }),
    ).rejects.toThrow(MaintainModelProviderFailure);
  });
});

describe("firstAvailableMaintainProvider", () => {
  it("prefers Anthropic when both keys are present", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => THE_USERS_ANTHROPIC_KEY,
      readOpenAiApiKey: () => THE_USERS_OPENAI_KEY,
    });
    expect(provider?.displayName).toBe("Anthropic (your key)");
  });

  it("falls back to OpenAI when only that key is present", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => null,
      readOpenAiApiKey: () => THE_USERS_OPENAI_KEY,
    });
    expect(provider?.displayName).toBe("OpenAI (your key)");
  });

  it("is undefined — never the funded proxy — when the user brought no key at all", () => {
    const provider = firstAvailableMaintainProvider({
      readAnthropicApiKey: () => null,
      readOpenAiApiKey: () => null,
    });
    expect(provider).toBeUndefined();
  });
});
