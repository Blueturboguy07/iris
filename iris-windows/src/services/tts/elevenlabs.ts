import { TTSProvider } from "./interface";

/**
 * ElevenLabs TTS — matches macOS version's ElevenLabsTTSClient.
 * Uses eleven_flash_v2_5 for low-latency streaming.
 */
export class ElevenLabsTTS implements TTSProvider {
  private apiKey: string;
  private voiceId: string;
  private abortController: AbortController | null = null;

  constructor(apiKey: string, voiceId: string) {
    this.apiKey = apiKey;
    this.voiceId = voiceId;
  }

  async speak(text: string): Promise<void> {
    this.stop(); // Cancel any in-progress speech
    this.abortController = new AbortController();

    const response = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${this.voiceId}`,
      {
        method: "POST",
        headers: {
          "xi-api-key": this.apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          text,
          model_id: "eleven_flash_v2_5",
          voice_settings: {
            stability: 0.5,
            similarity_boost: 0.75,
          },
        }),
        signal: this.abortController.signal,
      }
    );

    if (!response.ok) {
      throw new Error(`ElevenLabs error: ${response.status}`);
    }

    // Audio playback will be handled by sending the audio data
    // to the renderer process via IPC for Web Audio API playback
    const audioBuffer = await response.arrayBuffer();

    // TODO: Send to renderer for playback
    // mainWindow.webContents.send('tts:play', Buffer.from(audioBuffer));
    console.log(`TTS: generated ${audioBuffer.byteLength} bytes of audio`);
  }

  stop(): void {
    if (this.abortController) {
      this.abortController.abort();
      this.abortController = null;
    }
  }
}
