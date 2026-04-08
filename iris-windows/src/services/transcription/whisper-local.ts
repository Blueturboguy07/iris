import { TranscriptionProvider } from "./interface";

/**
 * Local Whisper transcription — no audio leaves the device.
 * Required for HIPAA mode.
 *
 * TODO: Integrate whisper.cpp via node native addon or spawn whisper CLI.
 * For now, this is a stub that collects audio and transcribes on stop().
 */
export class WhisperLocalProvider implements TranscriptionProvider {
  private audioChunks: Buffer[] = [];
  private partialCallback: ((text: string) => void) | null = null;
  private finalCallback: ((text: string) => void) | null = null;

  async start(): Promise<void> {
    this.audioChunks = [];
    console.log("Whisper local: session started (collecting audio)");
  }

  sendAudio(chunk: Buffer): void {
    this.audioChunks.push(chunk);
  }

  async stop(): Promise<string> {
    // TODO: Run whisper.cpp on collected audio
    // const audioBuffer = Buffer.concat(this.audioChunks);
    // const transcript = await whisperCpp.transcribe(audioBuffer);

    const transcript = "[whisper-local not yet implemented]";
    this.finalCallback?.(transcript);
    this.audioChunks = [];
    return transcript;
  }

  onPartialTranscript(callback: (text: string) => void): void {
    this.partialCallback = callback;
  }

  onFinalTranscript(callback: (text: string) => void): void {
    this.finalCallback = callback;
  }
}
