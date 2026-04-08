import { SettingsStore } from "../main/settings";
import { ScreenshotResult } from "../main/screenshot";

interface ClaudeQueryParams {
  transcript: string;
  screenshots: ScreenshotResult[];
  cursorPosition: { x: number; y: number };
  conversationHistory: Array<{ role: "user" | "assistant"; content: string }>;
}

interface ClaudeResponse {
  text: string;
}

const SYSTEM_PROMPT = `You are Clicky, a helpful AI screen companion. You can see the user's screen and hear their voice.

When you want to point at something on the user's screen, embed a coordinate tag in your response like this:
[POINT:x,y:label:screenN]

Where x,y are pixel coordinates on the screen, label is a short description, and N is the screen/display index (0-based).

Be concise and helpful. You're having a real-time conversation — keep responses short and actionable.`;

export class ClaudeService {
  private settings: SettingsStore;

  constructor(settings: SettingsStore) {
    this.settings = settings;
  }

  async query(params: ClaudeQueryParams): Promise<ClaudeResponse> {
    const apiKey = this.settings.get("anthropicApiKey");
    const useProxy = this.settings.get("useProxy");
    const proxyUrl = this.settings.get("proxyUrl");
    const model = this.settings.get("claudeModel");

    const baseUrl = useProxy && proxyUrl
      ? proxyUrl
      : "https://api.anthropic.com";

    // Build message content with images
    const userContent: Array<Record<string, unknown>> = [];

    // Add screenshots as images
    for (const screenshot of params.screenshots) {
      userContent.push({
        type: "image",
        source: {
          type: "base64",
          media_type: "image/jpeg",
          data: screenshot.data,
        },
      });
    }

    // Add screen context
    userContent.push({
      type: "text",
      text: [
        `User says: "${params.transcript}"`,
        `Cursor position: (${params.cursorPosition.x}, ${params.cursorPosition.y})`,
        `Screens: ${params.screenshots.map((s, i) =>
          `screen${i} ${s.bounds.width}x${s.bounds.height} at (${s.bounds.x},${s.bounds.y})`
        ).join(", ")}`,
      ].join("\n"),
    });

    // Build messages array from conversation history
    const messages = params.conversationHistory.map((entry) => ({
      role: entry.role,
      content: entry.role === "user" && entry.content === params.transcript
        ? userContent  // Latest user message gets the screenshots
        : entry.content,
    }));

    const response = await fetch(`${baseUrl}/v1/messages`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model,
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        messages,
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Claude API error (${response.status}): ${error}`);
    }

    const data = await response.json() as {
      content: Array<{ type: string; text?: string }>;
    };
    const text = data.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("");

    return { text };
  }
}
