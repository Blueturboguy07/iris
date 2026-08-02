import { TTSProvider } from "./interface";
import { exec } from "child_process";

/**
 * Local TTS using Windows SAPI (Speech API) via PowerShell.
 * No data leaves the device — required for HIPAA mode.
 */
export class LocalTTS implements TTSProvider {
  private currentProcess: ReturnType<typeof exec> | null = null;

  async speak(text: string): Promise<void> {
    this.stop();

    // Use Windows SAPI via PowerShell
    const escaped = text.replace(/'/g, "''").replace(/"/g, '`"');
    const cmd = `powershell -Command "Add-Type -AssemblyName System.Speech; $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer; $synth.Speak('${escaped}')"`;

    return new Promise((resolve, reject) => {
      this.currentProcess = exec(cmd, (error) => {
        this.currentProcess = null;
        if (error) {
          // Ignore abort errors
          if (error.killed) {
            resolve();
          } else {
            reject(error);
          }
        } else {
          resolve();
        }
      });
    });
  }

  stop(): void {
    if (this.currentProcess) {
      this.currentProcess.kill();
      this.currentProcess = null;
    }
  }
}
