import { ipcMain } from "electron";

/**
 * Audio capture is handled in the renderer process via Web Audio API
 * (getUserMedia + AudioWorklet). This module coordinates between
 * main process hotkey events and renderer audio capture.
 *
 * Flow:
 * 1. Main process detects hotkey → sends "hotkey:recording-changed" to renderer
 * 2. Renderer starts/stops mic capture via getUserMedia
 * 3. Renderer sends audio chunks to transcription service
 * 4. Renderer sends final transcript back to main via IPC
 */

export class AudioCapture {
  private isCapturing = false;

  constructor() {
    this.setupIPC();
  }

  private setupIPC(): void {
    ipcMain.handle("audio:status", () => ({
      isCapturing: this.isCapturing,
    }));

    ipcMain.on("audio:transcript-ready", (_event, transcript: string) => {
      console.log("Transcript received:", transcript);
      // Forward to CompanionManager for Claude processing
    });
  }

  start(): void {
    this.isCapturing = true;
  }

  stop(): void {
    this.isCapturing = false;
  }
}
