import { TranscriptionProvider } from "./interface";
import WebSocket from "ws";

/**
 * AssemblyAI real-time streaming transcription via WebSocket.
 * Matches the macOS version's AssemblyAIStreamingTranscriptionProvider.
 */
export class AssemblyAIProvider implements TranscriptionProvider {
  private apiKey: string;
  private ws: WebSocket | null = null;
  private partialCallback: ((text: string) => void) | null = null;
  private finalCallback: ((text: string) => void) | null = null;
  private finalTranscript = "";

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  async start(): Promise<void> {
    // Get temporary auth token
    const tokenResponse = await fetch(
      "https://api.assemblyai.com/v2/realtime/token",
      {
        method: "POST",
        headers: {
          Authorization: this.apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expires_in: 480 }),
      }
    );

    if (!tokenResponse.ok) {
      throw new Error(`AssemblyAI token error: ${tokenResponse.status}`);
    }

    const { token } = (await tokenResponse.json()) as { token: string };

    // Connect WebSocket
    this.ws = new WebSocket(
      `wss://api.assemblyai.com/v2/realtime/ws?sample_rate=16000&token=${token}`
    );

    this.ws.on("message", (data: WebSocket.Data) => {
      const msg = JSON.parse(data.toString()) as {
        message_type: string;
        text: string;
      };

      if (msg.message_type === "PartialTranscript" && msg.text) {
        this.partialCallback?.(msg.text);
      } else if (msg.message_type === "FinalTranscript" && msg.text) {
        this.finalTranscript += " " + msg.text;
        this.finalCallback?.(msg.text);
      }
    });

    return new Promise((resolve, reject) => {
      this.ws!.on("open", () => resolve());
      this.ws!.on("error", (err) => reject(err));
    });
  }

  sendAudio(chunk: Buffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      const base64 = chunk.toString("base64");
      this.ws.send(JSON.stringify({ audio_data: base64 }));
    }
  }

  async stop(): Promise<string> {
    if (this.ws) {
      this.ws.send(JSON.stringify({ terminate_session: true }));
      this.ws.close();
      this.ws = null;
    }
    const result = this.finalTranscript.trim();
    this.finalTranscript = "";
    return result;
  }

  onPartialTranscript(callback: (text: string) => void): void {
    this.partialCallback = callback;
  }

  onFinalTranscript(callback: (text: string) => void): void {
    this.finalCallback = callback;
  }
}
