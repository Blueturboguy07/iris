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
 * back-and-forth lives in `tier-c-fixer.ts` (a later increment), not here —
 * this file only has to answer "what did the model say", once.
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
 * INTERLOCK CLOSED: `secrets.ts`'s `SecretName` union now carries
 * `"openaiApiKey"` and `main/maintain/controller.ts`'s `readOpenAiApiKey`
 * reads it for real (a founder decision — Tier C's BYO fixer only, never the
 * Anthropic-only companion chat). This file needed no change to make that
 * true: it never touches a secret at rest (see below), so wiring the real key
 * was entirely `main/`'s and `main/settings.ts`'s job.
 *
 * No `maintainTrace` calls in this file: the Swift original
 * (`MaintainModelProvider.swift`) has none either, and every dependency this
 * file would otherwise need beyond what already ships (`assistant-transport.ts`,
 * `claude.ts`'s `FetchLike`) is kept out on purpose so it can be built and
 * tested standalone rather than waiting on the rest of `services/maintain/`.
 */

import {
  makeChatRequest,
  ANTHROPIC_API_VERSION,
  type AssistantTransport,
} from "../assistant-transport";
import type { FetchLike } from "../claude";

/**
 * The ceiling on how long one model call may take before it is abandoned. Every
 * other wait in the autopilot design is explicitly bounded (a 15-minute command
 * timeout, a bounded watch budget, a 15-minute prerequisite-poll deadline); this
 * was the one unbounded await, sitting directly in the failure-recovery path a
 * hung TCP connection could freeze the whole fix ladder on. Two minutes is
 * generous for a single ~700-token completion and still bounds a broken proxy.
 */
export const DEFAULT_MAINTAIN_MODEL_REQUEST_TIMEOUT_MS = 120_000;

/** Thrown internally when a model call outruns its timeout, so `respond` can
 *  report it as a `requestFailed` with an honest reason rather than a raw
 *  rejection. `FetchLike` carries no `signal`, so the underlying socket is not
 *  cancelled — but the AWAIT is bounded, which is what keeps the ladder (and the
 *  whole `runUntilBlocked` chain behind it) from blocking forever on one stall. */
class MaintainModelRequestTimeout extends Error {}

/**
 * Bounds `work` to `timeoutMilliseconds`. Resolves/rejects with `work` when it
 * settles first; rejects with `MaintainModelRequestTimeout` when the deadline
 * wins. A non-positive/non-finite timeout means "no bound" (the await is
 * returned unwrapped), so a caller can opt out. The timer is `unref`'d where the
 * runtime supports it so a pending bound never by itself keeps the process alive.
 */
function withRequestTimeout<T>(work: Promise<T>, timeoutMilliseconds: number): Promise<T> {
  if (!Number.isFinite(timeoutMilliseconds) || timeoutMilliseconds <= 0) {
    return work;
  }
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new MaintainModelRequestTimeout(`the model did not respond within ${timeoutMilliseconds}ms`));
    }, timeoutMilliseconds);
    (timer as { unref?: () => void }).unref?.();
    work.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/** The `requestFailed` reason for a call that outran its timeout — kept in one
 *  place so both providers report a network stall the same way. */
function requestFailureReason(error: unknown): string {
  if (error instanceof MaintainModelRequestTimeout) {
    return "the model didn't respond in time";
  }
  return error instanceof Error ? error.message : String(error);
}

/**
 * One conversational turn, provider-agnostic. `text` is plain text (the loop
 * is text-only, no tool API) — mirrors Swift's `MaintainChatTurn`.
 */
export interface MaintainChatTurn {
  readonly role: "user" | "assistant";
  readonly text: string;
}

/** Everything one `respond` call needs, bundled — the TS-idiomatic shape of
 *  Swift's three positional parameters (`systemPrompt:conversation:maximumOutputTokens:`). */
export interface MaintainModelRespondOptions {
  readonly systemPrompt: string;
  readonly conversation: readonly MaintainChatTurn[];
  readonly maximumOutputTokens: number;
}

/** Every way a maintain-mode model call can fail — mirrors Swift's
 *  `MaintainModelProviderError` enum, TS-idiomatic as a discriminated union
 *  carried on an `Error` subclass rather than a bare `throw`n enum case. */
export type MaintainModelProviderFailureDetail =
  | { readonly kind: "noCredential" }
  | { readonly kind: "requestFailed"; readonly reason: string };

export class MaintainModelProviderFailure extends Error {
  readonly detail: MaintainModelProviderFailureDetail;

  constructor(detail: MaintainModelProviderFailureDetail) {
    super(
      detail.kind === "noCredential"
        ? "no bring-your-own credential is available for this model provider"
        : `maintain-mode model request failed: ${detail.reason}`
    );
    this.name = "MaintainModelProviderFailure";
    this.detail = detail;
  }
}

/** Mirrors Swift's `MaintainModelProviding` protocol. `isAvailable` is a
 *  method rather than a Swift-style computed property — this codebase's
 *  convention (see `ShellSession`, `MaintainShellRunner`) is methods for
 *  anything that reads live state. */
export interface MaintainModelProviding {
  readonly displayName: string;
  isAvailable(): boolean;
  respond(options: MaintainModelRespondOptions): Promise<string>;
}

// ---------------------------------------------------------------------------
// Anthropic (the user's own key, via the BYO-only transport)
// ---------------------------------------------------------------------------

/**
 * The model every maintain-mode Anthropic call asks for. Matches the Windows
 * app's existing default (`src/main/settings.ts`'s `claudeModel`) rather than
 * Swift's own default (`claude-sonnet-4-6`) — this is a per-platform constant,
 * not shared wire vocabulary, so tracking the Windows app's own default is the
 * right kind of parity here.
 */
const MAINTAIN_ANTHROPIC_MODEL_ID = "claude-sonnet-4-5-20250929";

/** The shape of an Anthropic Messages API response this file actually reads —
 *  deliberately narrow, not a full SDK type, since only assembling the text
 *  content blocks is this file's job. */
interface AnthropicMessagesResponseBody {
  readonly content?: ReadonlyArray<{ readonly type: string; readonly text?: string }>;
}

/**
 * Anthropic, via the user's own key. Reuses `assistant-transport.ts`'s
 * exported `makeChatRequest` for the BYO route — never the private
 * `anthropicDirectChatRequest` — so the key-isolation property that function
 * enforces (never sent to a publik host) applies here too, structurally.
 */
export class AnthropicMaintainProvider implements MaintainModelProviding {
  readonly displayName = "Anthropic (your key)";

  private readonly readAnthropicApiKey: () => string | null;
  private readonly fetchImplementation: FetchLike;
  private readonly requestTimeoutMilliseconds: number;

  constructor(
    /** Reads the user's stored Anthropic key, or null when there is none. */
    readAnthropicApiKey: () => string | null,
    fetchImplementation: FetchLike = globalThis.fetch as unknown as FetchLike,
    /** The per-call deadline; the default bounds the one wait that used to be
     *  unbounded. A test passes a tiny value to prove the bound fires. */
    requestTimeoutMilliseconds: number = DEFAULT_MAINTAIN_MODEL_REQUEST_TIMEOUT_MS
  ) {
    this.readAnthropicApiKey = readAnthropicApiKey;
    this.fetchImplementation = fetchImplementation;
    this.requestTimeoutMilliseconds = requestTimeoutMilliseconds;
  }

  isAvailable(): boolean {
    const key = this.readAnthropicApiKey();
    return key !== null && key.length > 0;
  }

  async respond(options: MaintainModelRespondOptions): Promise<string> {
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

    const body: {
      model: string;
      max_tokens: number;
      system: string;
      messages: Array<{ role: string; content: string }>;
    } = {
      model: MAINTAIN_ANTHROPIC_MODEL_ID,
      max_tokens: options.maximumOutputTokens,
      system: options.systemPrompt,
      messages: options.conversation.map((turn) => ({ role: turn.role, content: turn.text })),
    };

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await withRequestTimeout(
        this.fetchImplementation(preparedRequest.url, {
          method: preparedRequest.method,
          headers: preparedRequest.headers,
          body: JSON.stringify(body),
        }),
        this.requestTimeoutMilliseconds
      );
    } catch (error) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: requestFailureReason(error),
      });
    }

    const rawResponseBody = await response.text();
    if (!response.ok) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: `HTTP ${response.status}`,
      });
    }

    let parsedResponseBody: AnthropicMessagesResponseBody;
    try {
      parsedResponseBody = JSON.parse(rawResponseBody) as AnthropicMessagesResponseBody;
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

// ---------------------------------------------------------------------------
// OpenAI (the user's own key, straight to the source)
// ---------------------------------------------------------------------------

/** Where the user's own OpenAI key goes — straight to the source, never a
 *  publik host, matching the isolation property `assistant-transport.ts`
 *  enforces for the Anthropic BYO route. */
const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

/** A capable coding model; the user's key, the user's spend. Matches Swift's
 *  `OpenAIMaintainProvider.model` exactly — this one IS shared wire
 *  vocabulary in the sense that it names a model OpenAI hosts, not app state,
 *  so there is no platform-specific reason to diverge from Swift's choice. */
const OPENAI_MODEL_ID = "gpt-4o";

/** The shape of an OpenAI Chat Completions response this file actually
 *  reads — deliberately narrow, same reasoning as `AnthropicMessagesResponseBody`. */
interface OpenAiChatCompletionResponseBody {
  readonly choices?: ReadonlyArray<{ readonly message?: { readonly content?: string } }>;
}

/**
 * OpenAI, via the user's own key. Iris's first non-Anthropic model call,
 * deliberately kept behind this one seam so nothing else in the app learns a
 * second SDK — a plain `fetch` against the Chat Completions API.
 */
export class OpenAIMaintainProvider implements MaintainModelProviding {
  readonly displayName = "OpenAI (your key)";

  private readonly readOpenAiApiKey: () => string | null;
  private readonly fetchImplementation: FetchLike;
  private readonly requestTimeoutMilliseconds: number;

  constructor(
    /** Reads the user's stored OpenAI key, or null when there is none. */
    readOpenAiApiKey: () => string | null,
    fetchImplementation: FetchLike = globalThis.fetch as unknown as FetchLike,
    /** The per-call deadline; the default bounds the one wait that used to be
     *  unbounded. A test passes a tiny value to prove the bound fires. */
    requestTimeoutMilliseconds: number = DEFAULT_MAINTAIN_MODEL_REQUEST_TIMEOUT_MS
  ) {
    this.readOpenAiApiKey = readOpenAiApiKey;
    this.fetchImplementation = fetchImplementation;
    this.requestTimeoutMilliseconds = requestTimeoutMilliseconds;
  }

  isAvailable(): boolean {
    const key = this.readOpenAiApiKey();
    return key !== null && key.length > 0;
  }

  async respond(options: MaintainModelRespondOptions): Promise<string> {
    const openAiApiKey = this.readOpenAiApiKey();
    if (openAiApiKey === null || openAiApiKey.length === 0) {
      throw new MaintainModelProviderFailure({ kind: "noCredential" });
    }

    const messages: Array<{ role: string; content: string }> = [
      { role: "system", content: options.systemPrompt },
      ...options.conversation.map((turn) => ({ role: turn.role, content: turn.text })),
    ];

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await withRequestTimeout(
        this.fetchImplementation(OPENAI_CHAT_COMPLETIONS_URL, {
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
        }),
        this.requestTimeoutMilliseconds
      );
    } catch (error) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: requestFailureReason(error),
      });
    }

    const rawResponseBody = await response.text();
    if (!response.ok) {
      throw new MaintainModelProviderFailure({
        kind: "requestFailed",
        reason: `HTTP ${response.status}`,
      });
    }

    let parsedResponseBody: OpenAiChatCompletionResponseBody;
    try {
      parsedResponseBody = JSON.parse(rawResponseBody) as OpenAiChatCompletionResponseBody;
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

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/**
 * The provider to use for Tier C (and Tier B's adapter), preferring Anthropic
 * when both keys are present — its BYO isolation is already proven and
 * tested via `assistant-transport.ts`. `undefined` when the user brought no
 * key at all — the honest funded-tier ceiling, matching Swift's
 * `MaintainModelProviderResolver.firstAvailable() -> MaintainModelProviding?`.
 *
 * NEVER the funded proxy: notice this function has no `AssistantTransport`
 * `"funded"` branch to fall back to, and cannot grow one without changing the
 * signature — there is no Supabase session or access-token callback in scope
 * here at all, structurally, the same isolation property `AnthropicMaintainProvider`
 * inherits from `assistant-transport.ts`'s BYO-only construction above.
 */
export function firstAvailableMaintainProvider(options: {
  readonly readAnthropicApiKey: () => string | null;
  readonly readOpenAiApiKey: () => string | null;
  readonly fetchImplementation?: FetchLike;
  /** The per-call deadline for whichever provider is chosen; defaults to
   *  `DEFAULT_MAINTAIN_MODEL_REQUEST_TIMEOUT_MS`. */
  readonly requestTimeoutMilliseconds?: number;
}): MaintainModelProviding | undefined {
  const anthropicProvider = new AnthropicMaintainProvider(
    options.readAnthropicApiKey,
    options.fetchImplementation,
    options.requestTimeoutMilliseconds
  );
  if (anthropicProvider.isAvailable()) {
    return anthropicProvider;
  }

  const openAiProvider = new OpenAIMaintainProvider(
    options.readOpenAiApiKey,
    options.fetchImplementation,
    options.requestTimeoutMilliseconds
  );
  if (openAiProvider.isAvailable()) {
    return openAiProvider;
  }

  return undefined;
}
