/**
 * model-provider.ts
 *
 * Ported from `iris-macos/leanring-buddy/MaintainModelProvider.swift`.
 *
 * Tier C (and Tier B's patch adapter, see `replay-engine.ts`) run on the
 * user's OWN model access — never the funded proxy (ratified D4/D5). Two
 * providers speak one interface, `MaintainModelProviding`, so the fix loop
 * does not care which the user brought:
 *
 *   anthropic   the user's own Anthropic key, through the same BYO transport
 *               `assistant-transport.ts` already isolates (`{ tier: "byo" }`).
 *   openai      the user's own OpenAI key, straight to api.openai.com — kept
 *               behind this one seam so nothing else in the app learns a
 *               second SDK.
 *
 * The whole interface is one turn: a system prompt and a conversation history
 * in, one assistant text turn out. The ReAct loop that drives Tier C's actual
 * back-and-forth lives in `maintain-tier-c-fixer.ts` (a later increment), not
 * here — this file only has to answer "what did the model say", once.
 *
 * WHY THIS FILE NEVER TOUCHES A SECRET AT REST: `src/main/secrets.ts` is the
 * only code in this app allowed to read one, and it lives in `main/` (Electron
 * APIs, side effects) — a layer `services/` must not depend on, and this file
 * lives in `services/maintain/`. So credential access here is a plain
 * `() => string | null` function the caller injects, exactly like every other
 * OS-touching capability in this codebase (`ShellSession`/`MockShell`,
 * `FetchLike`). The real callback, wired up wherever this module is
 * constructed, is `() => readSecret("anthropicApiKey")` /
 * `() => readSecret("openaiApiKey")`.
 *
 * INTERLOCK — not fixed by this file: `secrets.ts`'s `SecretName` union is
 * currently `"anthropicApiKey" | "supabaseRefreshToken"` only. It needs
 * `"openaiApiKey"` added before `OpenAIMaintainProvider` can be wired to a
 * real stored key. That is a one-line edit to a file this task does not own;
 * flagged here rather than done silently.
 *
 * No `maintainTrace` calls in this file: the Swift original
 * (`MaintainModelProvider.swift`) has none either, and every dependency this
 * file would otherwise need beyond what already ships (`assistant-transport.ts`,
 * `claude.ts`'s `FetchLike`) is kept out on purpose so it can be built and
 * tested standalone rather than waiting on the rest of `services/maintain/`.
 */

import {
  ANTHROPIC_API_VERSION,
  makeChatRequest,
  type AssistantTransport,
} from "../assistant-transport";
import type { FetchLike } from "../claude";

/**
 * One conversational turn, provider-agnostic. The loop is text-only — no
 * images, no tool-calling API — matching Swift's `MaintainChatTurn`.
 */
export interface MaintainChatTurn {
  readonly role: "user" | "assistant";
  readonly text: string;
}

/** Every way asking a maintain-mode model provider for a turn can fail. */
export type MaintainModelProviderErrorKind =
  /** No usable BYO key for this provider — the honest funded-tier ceiling. */
  | { readonly kind: "noCredential" }
  /** The network reached the provider, but it declined or the response could
   *  not be read. `reason` is for logs/diagnosis, never shown raw to a user. */
  | { readonly kind: "requestFailed"; readonly reason: string };

export class MaintainModelProviderFailure extends Error {
  readonly detail: MaintainModelProviderErrorKind;

  constructor(detail: MaintainModelProviderErrorKind) {
    super(
      detail.kind === "noCredential"
        ? "no bring-your-own credential is available for this model provider"
        : `maintain-mode model request failed: ${detail.reason}`,
    );
    this.name = "MaintainModelProviderFailure";
    this.detail = detail;
  }
}

/**
 * One provider the fix ladder can ask for a turn. Mirrors Swift's
 * `MaintainModelProviding` protocol; `isAvailable` is a method rather than a
 * computed property (idiomatic TS), everything else is a straight port.
 */
export interface MaintainModelProviding {
  readonly displayName: string;
  isAvailable(): boolean;
  respond(options: {
    readonly systemPrompt: string;
    readonly conversation: readonly MaintainChatTurn[];
    readonly maximumOutputTokens: number;
  }): Promise<string>;
}

/**
 * The model every maintain-mode Anthropic call asks for. Matches the Windows
 * app's existing default (`src/main/settings.ts`'s `claudeModel`) rather than
 * Swift's own default (`claude-sonnet-4-6`) — this is a per-platform constant,
 * not shared wire vocabulary, so tracking the Windows app's own default is the
 * right kind of parity here.
 */
const MAINTAIN_ANTHROPIC_MODEL_ID = "claude-sonnet-4-5-20250929";

/**
 * Anthropic, via the user's own key. Reuses `assistant-transport.ts`'s
 * exported `makeChatRequest` for the BYO route — never the private
 * `anthropicDirectChatRequest` — so the key-isolation property that function
 * enforces (never sent to a publik host) applies here too, structurally.
 */
export class AnthropicMaintainProvider implements MaintainModelProviding {
  readonly displayName = "Anthropic (your key)";

  constructor(
    /** Reads the user's stored Anthropic key, or null when there is none. */
    private readonly readAnthropicApiKey: () => string | null,
    private readonly fetchImplementation: FetchLike = globalThis.fetch as unknown as FetchLike,
  ) {}

  isAvailable(): boolean {
    const key = this.readAnthropicApiKey();
    return key !== null && key.length > 0;
  }

  async respond(options: {
    readonly systemPrompt: string;
    readonly conversation: readonly MaintainChatTurn[];
    readonly maximumOutputTokens: number;
  }): Promise<string> {
    const anthropicApiKey = this.readAnthropicApiKey();
    if (anthropicApiKey === null || anthropicApiKey.length === 0) {
      throw new MaintainModelProviderFailure({ kind: "noCredential" });
    }

    const transport: AssistantTransport = { tier: "byo", anthropicApiKey };
    const preparedRequest = await makeChatRequest(transport);
    // `makeChatRequest`'s BYO route already sets this, but this file does not
    // depend on that being true forever — belt and suspenders, cheaply.
    if (!preparedRequest.headers["anthropic-version"]) {
      preparedRequest.headers["anthropic-version"] = ANTHROPIC_API_VERSION;
    }

    const body = {
      model: MAINTAIN_ANTHROPIC_MODEL_ID,
      max_tokens: options.maximumOutputTokens,
      system: options.systemPrompt,
      messages: options.conversation.map((turn) => ({ role: turn.role, content: turn.text })),
    };

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await this.fetchImplementation(preparedRequest.url, {
        method: preparedRequest.method,
        headers: preparedRequest.headers,
        body: JSON.stringify(body),
      });
    } catch (error) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: error instanceof Error ? error.message : String(error),
      });
    }

    const rawResponseBody = await response.text();
    if (!response.ok) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: `HTTP ${response.status}`,
      });
    }

    let parsedResponseBody: { content?: Array<{ type: string; text?: string }> };
    try {
      parsedResponseBody = JSON.parse(rawResponseBody);
    } catch {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: "the model returned something Iris could not read",
      });
    }

    return (parsedResponseBody.content ?? [])
      .filter((block) => block.type === "text")
      .map((block) => block.text ?? "")
      .join("");
  }
}

/** Where the user's own OpenAI key goes — straight to the source, never a
 *  publik host, matching the isolation property `assistant-transport.ts`
 *  enforces for the Anthropic BYO route. */
const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

/** A capable coding model; the user's key, the user's spend. Matches Swift's
 *  `OpenAIMaintainProvider.model` exactly — this one IS shared wire
 *  vocabulary in the sense that it names a model OpenAI hosts, not app state,
 *  so there is no platform-specific reason to diverge from Swift's choice. */
const OPENAI_MODEL_ID = "gpt-4o";

/**
 * OpenAI, via the user's own key. Iris's first non-Anthropic model call,
 * deliberately kept behind this one seam so nothing else in the app learns a
 * second SDK — a plain `fetch` against the Chat Completions API.
 */
export class OpenAIMaintainProvider implements MaintainModelProviding {
  readonly displayName = "OpenAI (your key)";

  constructor(
    /** Reads the user's stored OpenAI key, or null when there is none. */
    private readonly readOpenAiApiKey: () => string | null,
    private readonly fetchImplementation: FetchLike = globalThis.fetch as unknown as FetchLike,
  ) {}

  isAvailable(): boolean {
    const key = this.readOpenAiApiKey();
    return key !== null && key.length > 0;
  }

  async respond(options: {
    readonly systemPrompt: string;
    readonly conversation: readonly MaintainChatTurn[];
    readonly maximumOutputTokens: number;
  }): Promise<string> {
    const openAiApiKey = this.readOpenAiApiKey();
    if (openAiApiKey === null || openAiApiKey.length === 0) {
      throw new MaintainModelProviderFailure({ kind: "noCredential" });
    }

    const messages = [
      { role: "system", content: options.systemPrompt },
      ...options.conversation.map((turn) => ({ role: turn.role, content: turn.text })),
    ];

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await this.fetchImplementation(OPENAI_CHAT_COMPLETIONS_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openAiApiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: OPENAI_MODEL_ID,
          messages,
          max_tokens: options.maximumOutputTokens,
          temperature: 0,
        }),
      });
    } catch (error) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: error instanceof Error ? error.message : String(error),
      });
    }

    const rawResponseBody = await response.text();
    if (!response.ok) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: `HTTP ${response.status}`,
      });
    }

    let parsedResponseBody: { choices?: Array<{ message?: { content?: string } }> };
    try {
      parsedResponseBody = JSON.parse(rawResponseBody);
    } catch {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: "the model returned something Iris could not read",
      });
    }

    const messageContent = parsedResponseBody.choices?.[0]?.message?.content;
    if (messageContent === undefined) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: "the model's response carried no message content",
      });
    }
    return messageContent;
  }
}

/**
 * The provider to use for Tier C (and Tier B's adapter), preferring Anthropic
 * when both keys are present — its BYO isolation is already proven and
 * tested via `assistant-transport.ts`. `undefined` when the user brought no
 * key at all — the honest funded-tier ceiling, matching Swift's
 * `MaintainModelProviderResolver.firstAvailable() -> MaintainModelProviding?`.
 */
export function firstAvailableMaintainProvider(options: {
  readonly readAnthropicApiKey: () => string | null;
  readonly readOpenAiApiKey: () => string | null;
  readonly fetchImplementation?: FetchLike;
}): MaintainModelProviding | undefined {
  const anthropicProvider = new AnthropicMaintainProvider(
    options.readAnthropicApiKey,
    options.fetchImplementation,
  );
  if (anthropicProvider.isAvailable()) {
    return anthropicProvider;
  }

  const openAiProvider = new OpenAIMaintainProvider(
    options.readOpenAiApiKey,
    options.fetchImplementation,
  );
  if (openAiProvider.isAvailable()) {
    return openAiProvider;
  }

  return undefined;
}
