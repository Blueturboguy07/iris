/**
 * claude.ts
 *
 * The Anthropic Messages API client. It never decides where a request goes or
 * what credential it carries — `assistant-transport.ts` owns both — so this file
 * can be read as "what Iris says to the model" and nothing else.
 *
 * Both tiers speak the identical wire format, so one client serves both. The
 * only difference in the body is `model`, which the funded route pins
 * server-side and therefore is not sent.
 */

import {
  AssistantTransport,
  AssistantTransportFailure,
  ANTHROPIC_API_VERSION,
  failureForStatusCode,
  makeChatRequest,
  serverErrorCodeInFailureBody,
  shouldSendModelInRequestBody,
} from "./assistant-transport";

/** Protocol section 1: at most 50 messages per request. */
const MAX_MESSAGES_PER_REQUEST = 50;

/** Protocol section 1: the funded tier caps `max_tokens` at 2048. */
const MAX_TOKENS = 2048;

export interface ConversationEntry {
  role: "user" | "assistant";
  content: string;
}

export interface CapturedScreen {
  /** Base64 JPEG, long edge already clamped to the model's max input edge. */
  data: string;
  imageDimensions: { width: number; height: number };
  bounds: { x: number; y: number; width: number; height: number };
}

export interface ChatQueryParams {
  userMessage: string;
  screenshots: CapturedScreen[];
  cursorPosition: { x: number; y: number };
  conversationHistory: ConversationEntry[];
  /** Extra system content appended after any server-owned block. */
  additionalSystemContext?: string;
}

const SYSTEM_PROMPT = `You are Iris, publik's desktop companion. You can see the user's screen via screenshots (one per display) and read what they type.

## CRITICAL: Visual pointing protocol

You are NOT a regular chat assistant. Your defining feature is that you POINT at things on the user's screen with an animated cursor overlay. Whenever the user asks "where", "how do I", "show me", "click", "find", or otherwise asks for visual guidance, you MUST emit at least one POINT tag for every UI element you reference.

POINT tag format (embed inline in your text):
[POINT:x,y:label:screenN]

- **x,y MUST be in IMAGE pixel coordinates of the screenshot you see**, NOT the user's actual screen resolution. The "Screens:" list in the user message tells you the IMAGE dimensions for each screen — use those.
- x ranges from 0 (left edge of image) to imageWidth-1 (right edge)
- y ranges from 0 (top edge) to imageHeight-1 (bottom edge)
- label = a 2-5 word description of what you're pointing at
- screenN = the screen index from the "Screens:" list (screen0, screen1, ...)
- The system automatically scales your image coordinates to the user's actual screen pixels, so just use what you see.

## How to find accurate coordinates

Look at the screenshot carefully. For each UI element you want to point at:
1. Identify it visually
2. Estimate its center pixel in the image (image origin = top-left = 0,0)
3. Be precise — better to look twice than guess
4. Sanity-check: a button at the bottom of the screen should have a y close to imageHeight, not imageHeight/2

## Examples

User says: "How do I add this video to a playlist on YouTube?"
(Screens: screen0 image is 1568x882)
You: "Click 'Save' [POINT:920,820:Save button:screen0] below the video, then pick a playlist."

User says: "Where's the back button?"
(Screens: screen0 image is 1568x882)
You: "Here [POINT:30,75:Back arrow:screen0]."

## Multi-monitor

When the user has more than one screen, you receive one image per display (screen0, screen1, ...). Before you answer:

1. Scan ALL provided screenshots, not just screen0. The element the user is asking about may be on any of them.
2. If the user hints at a specific screen ("my other monitor", "on the left screen"), use that screen.
3. If no hint is given and the element appears on only one screen, use that screen.
4. If the element is visible on multiple screens, prefer the one where it's clearest/largest.
5. The screenN index in your POINT tag MUST match the screen where you actually found the element.

## Disambiguating visually similar elements

Many UI layouts contain rows or columns of visually similar elements (list rows, tabs, toolbar buttons, like/dislike pairs). When the user references one specific item in such a group:

1. Read the user's description carefully (title, position, adjacent text, icon type).
2. Match against the VISIBLE text or unique marker of each candidate — do NOT just pick the first or geometrically nearest one.
3. If the description is ambiguous, pick the one whose visible text matches most literally, and mention the chosen title so the user can confirm.
4. For vertical lists, double-check that your y coordinate lands on the intended ROW, not the one above or below.

## Rules

1. When the user asks visual/spatial questions, ALWAYS include POINT tags. Do not just describe — POINT.
2. Use IMAGE pixel coordinates (the dimensions given in the "Screens:" list).
3. One POINT tag per UI element you reference. Multiple steps → multiple tags.
4. Tags can appear inline anywhere in the text. The cursor overlay reads them and animates.
5. Be concise — short sentences, real-time conversation.
6. Match the user's language.
7. Only skip POINT tags if the user is asking a non-visual question.

## PRE-SEND CHECKLIST (verify before every response)

- [ ] Does my response mention a UI element the user should click, press, look at, find, or interact with?
- [ ] For each such element, is there a \`[POINT:x,y:label:screenN]\` tag in my message?
- [ ] Do the screenN values match the screen where I actually located each element?

**If the answer to 1 is YES and any tag is missing, REWRITE your response with the tags before sending.** A response that says "click the Y button" but contains zero POINT tags is a BUG.`;

const REFINEMENT_SYSTEM_PROMPT =
  "You are a precise UI pointing tool. You receive a zoomed crop of a screenshot and a description of a UI element. " +
  'Return ONLY "x,y" — integer pixel coordinates of the exact visual center of the element matching the description. ' +
  "CRITICAL: the crop may contain visually similar neighboring elements (e.g. a Like button next to a Dislike button, " +
  "or several tabs side by side). Return the EXACT element described, NOT an adjacent look-alike. " +
  "Aim for the center of the element's icon or main hit target. " +
  'If the element is not visible in the crop, return "none". No other text, no prose, no units.';

/** Injected so the client is testable without a network. */
export type FetchLike = (
  url: string,
  init: { method: string; headers: Record<string, string>; body: string }
) => Promise<{
  ok: boolean;
  status: number;
  text: () => Promise<string>;
  headers: { get: (name: string) => string | null };
}>;

export class ClaudeService {
  private readonly transport: AssistantTransport;
  private readonly model: string;
  private readonly fetchImplementation: FetchLike;

  constructor(options: {
    transport: AssistantTransport;
    model: string;
    fetchImplementation?: FetchLike;
  }) {
    this.transport = options.transport;
    this.model = options.model;
    this.fetchImplementation =
      options.fetchImplementation ?? (globalThis.fetch as unknown as FetchLike);
  }

  async query(params: ChatQueryParams): Promise<{ text: string }> {
    const userContent: Array<Record<string, unknown>> = [];

    for (const screenshot of params.screenshots) {
      userContent.push({
        type: "image",
        source: { type: "base64", media_type: "image/jpeg", data: screenshot.data },
      });
    }

    userContent.push({
      type: "text",
      text: [
        `User says: "${params.userMessage}"`,
        `Cursor position: (${params.cursorPosition.x}, ${params.cursorPosition.y})`,
        "Screens (give POINT coordinates in IMAGE pixels — use the image dimensions below, NOT the actual screen resolution):",
        ...params.screenshots.map(
          (screen, index) =>
            `  screen${index}: image is ${screen.imageDimensions.width}x${screen.imageDimensions.height} px ` +
            `(actual display ${screen.bounds.width}x${screen.bounds.height} at ${screen.bounds.x},${screen.bounds.y})`
        ),
      ].join("\n"),
    });

    const trimmedHistory = params.conversationHistory.slice(-MAX_MESSAGES_PER_REQUEST);
    const messages = trimmedHistory.map((entry, index) => ({
      role: entry.role,
      content:
        index === trimmedHistory.length - 1 && entry.role === "user" ? userContent : entry.content,
    }));

    // The stable prompt goes first so prompt caching has something to hold on
    // to; the funded route prepends its own block ahead of all of it.
    const systemContent = params.additionalSystemContext
      ? `${SYSTEM_PROMPT}\n\n${params.additionalSystemContext}`
      : SYSTEM_PROMPT;

    const responseText = await this.send({
      system: systemContent,
      messages,
      maxTokens: MAX_TOKENS,
    });
    return { text: responseText };
  }

  /**
   * Second-pass pointing refinement. Given a cropped patch and a label, ask the
   * model for the precise pixel center within that crop. Returns null if it
   * cannot find the element — the caller then keeps the first-pass estimate,
   * which is less precise but never wrong in a new way.
   */
  async refinePoint(options: {
    cropBase64: string;
    cropWidth: number;
    cropHeight: number;
    label: string;
  }): Promise<{ x: number; y: number } | null> {
    try {
      const responseText = await this.send({
        system: REFINEMENT_SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: "image/jpeg", data: options.cropBase64 },
              },
              {
                type: "text",
                text:
                  `Crop image size: ${options.cropWidth}x${options.cropHeight} pixels (origin 0,0 = top-left).\n` +
                  `Target element: "${options.label}"\n` +
                  `Return the pixel center as "x,y" only.`,
              },
            ],
          },
        ],
        maxTokens: 32,
      });

      const match = responseText.match(/(\d+)\s*,\s*(\d+)/);
      if (!match) return null;
      return { x: Number.parseInt(match[1], 10), y: Number.parseInt(match[2], 10) };
    } catch {
      return null;
    }
  }

  /** The one place a request actually leaves. */
  private async send(options: {
    system: string;
    messages: Array<{ role: string; content: unknown }>;
    maxTokens: number;
  }): Promise<string> {
    const preparedRequest = await makeChatRequest(this.transport);

    const body: Record<string, unknown> = {
      max_tokens: options.maxTokens,
      system: options.system,
      messages: options.messages,
    };
    if (shouldSendModelInRequestBody(this.transport)) {
      body.model = this.model;
    }
    if (this.transport.tier === "byo" && !preparedRequest.headers["anthropic-version"]) {
      preparedRequest.headers["anthropic-version"] = ANTHROPIC_API_VERSION;
    }

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await this.fetchImplementation(preparedRequest.url, {
        method: preparedRequest.method,
        headers: preparedRequest.headers,
        body: JSON.stringify(body),
      });
    } catch (error) {
      throw new AssistantTransportFailure({
        kind: "transportFailure",
        reason: error instanceof Error ? error.message : String(error),
      });
    }

    const rawBody = await response.text();

    if (!response.ok) {
      throw new AssistantTransportFailure(
        failureForStatusCode({
          statusCode: response.status,
          serverErrorCode: serverErrorCodeInFailureBody(rawBody),
          retryAfterHeaderValue: response.headers.get("Retry-After"),
          isFundedTier: this.transport.tier === "funded",
        })
      );
    }

    let parsed: { content?: Array<{ type: string; text?: string }> };
    try {
      parsed = JSON.parse(rawBody);
    } catch {
      throw new AssistantTransportFailure({
        kind: "transportFailure",
        reason: "the assistant returned something Iris could not read",
      });
    }

    return (parsed.content ?? [])
      .filter((block) => block.type === "text")
      .map((block) => block.text ?? "")
      .join("");
  }
}
