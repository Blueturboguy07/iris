import { globalShortcut, ipcMain, BrowserWindow } from "electron";
import { SettingsStore } from "./settings";

export class HotkeyManager {
  private settings: SettingsStore;
  private isRecording = false;

  constructor(settings: SettingsStore) {
    this.settings = settings;
  }

  register(): void {
    const hotkey = this.settings.get("pushToTalkHotkey", "Ctrl+Alt");

    // Register push-to-talk activation
    globalShortcut.register(`${hotkey}+Space`, () => {
      this.toggleRecording();
    });

    // IPC listeners for renderer
    ipcMain.handle("hotkey:isRecording", () => this.isRecording);
  }

  private toggleRecording(): void {
    this.isRecording = !this.isRecording;

    // Notify all renderer windows
    BrowserWindow.getAllWindows().forEach((win) => {
      win.webContents.send(
        "hotkey:recording-changed",
        this.isRecording
      );
    });

    if (this.isRecording) {
      console.log("Push-to-talk: recording started");
    } else {
      console.log("Push-to-talk: recording stopped");
    }
  }

  unregister(): void {
    globalShortcut.unregisterAll();
  }
}
