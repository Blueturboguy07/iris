import { app, BrowserWindow, globalShortcut, ipcMain, screen, shell } from "electron";
import { createTray } from "./tray";
import { HotkeyManager } from "./hotkey";
import { AudioCapture } from "./audio";
import { SettingsStore } from "./settings";
import { CompanionManager } from "./companion";
import path from "path";

let chatWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let overlayWindow: BrowserWindow | null = null;

const settings = new SettingsStore();
let companion: CompanionManager;
let cursorBuddyInterval: ReturnType<typeof setInterval> | null = null;

function startCursorBuddy(): void {
  if (cursorBuddyInterval) return;
  cursorBuddyInterval = setInterval(() => {
    if (!overlayWindow || overlayWindow.isDestroyed()) return;
    const point = screen.getCursorScreenPoint();
    overlayWindow.webContents.send("overlay:cursor-buddy", point.x, point.y);
  }, 16);
}

function stopCursorBuddy(): void {
  if (cursorBuddyInterval) {
    clearInterval(cursorBuddyInterval);
    cursorBuddyInterval = null;
  }
  if (overlayWindow && !overlayWindow.isDestroyed()) {
    overlayWindow.webContents.send("overlay:cursor-buddy-visible", false);
  }
}

function createOverlayWindow(): BrowserWindow {
  const win = new BrowserWindow({
    fullscreen: true,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: false,
    webPreferences: {
      preload: path.join(__dirname, "..", "preload", "index.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.setIgnoreMouseEvents(true);
  win.loadFile(path.join(__dirname, "..", "..", "src", "renderer", "overlay", "index.html"));
  return win;
}

function createChatWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 420,
    height: 550,
    resizable: true,
    show: false,
    frame: false,
    transparent: false,
    alwaysOnTop: settings.get("alwaysOnTop"),
    webPreferences: {
      preload: path.join(__dirname, "..", "preload", "index.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadFile(path.join(__dirname, "..", "..", "src", "renderer", "chat", "index.html"));
  win.once("ready-to-show", () => {
    win.show();
    // setAlwaysOnTop after show — more reliable on Windows than constructor option
    if (settings.get("alwaysOnTop")) {
      win.setAlwaysOnTop(true, "screen-saver");
      // Re-apply after a short delay — Windows can reset it
      setTimeout(() => {
        if (!win.isDestroyed()) {
          win.setAlwaysOnTop(true, "screen-saver");
          // alwaysOnTop applied
        }
      }, 500);
    }
  });
  return win;
}

function createSettingsWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 500,
    height: 600,
    resizable: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "..", "preload", "index.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadFile(path.join(__dirname, "..", "..", "src", "renderer", "settings", "index.html"));
  win.once("ready-to-show", () => win.show());
  return win;
}

function setupIPC(): void {
  // Chat query — captures screen + sends to Claude
  ipcMain.handle("chat:query", async (_event, text: string) => {
    try {
      const response = await companion.processQuery(text);
      return response;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      throw new Error(msg);
    }
  });

  // Settings
  ipcMain.handle("settings:getAll", () => settings.getAll());
  ipcMain.handle("settings:set", (_event, key: string, value: unknown) => {
    settings.set(key as keyof ReturnType<typeof settings.getAll>, value as never);

    // Apply alwaysOnTop immediately
    if (key === "alwaysOnTop" && chatWindow && !chatWindow.isDestroyed()) {
      chatWindow.setAlwaysOnTop(!!value, "screen-saver");
    }

    // Toggle cursor buddy
    if (key === "cursorBuddyEnabled") {
      if (value) startCursorBuddy();
      else stopCursorBuddy();
    }
  });

  // Open URL in default browser
  ipcMain.handle("shell:openExternal", (_event, url: string) => {
    if (url.startsWith("https://")) {
      shell.openExternal(url);
    }
  });

  // Window controls
  ipcMain.handle("window:minimize", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.minimize();
  });

  ipcMain.handle("window:close", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.close();
  });
}

app.whenReady().then(() => {
  // Hide from taskbar — tray only
  app.dock?.hide?.();

  overlayWindow = createOverlayWindow();
  companion = new CompanionManager(settings, overlayWindow);

  const audioCapture = new AudioCapture(settings);
  audioCapture.setCompanion(companion);

  setupIPC();

  const tray = createTray({
    onChat: () => {
      if (chatWindow && !chatWindow.isDestroyed()) {
        chatWindow.focus();
      } else {
        chatWindow = createChatWindow();
        chatWindow.on("closed", () => {
          chatWindow = null;
        });
      }
    },
    onSettings: () => {
      if (settingsWindow && !settingsWindow.isDestroyed()) {
        settingsWindow.focus();
      } else {
        settingsWindow = createSettingsWindow();
        settingsWindow.on("closed", () => {
          settingsWindow = null;
        });
      }
    },
    onQuit: () => app.quit(),
  });

  const hotkeyManager = new HotkeyManager(settings);
  hotkeyManager.register();

  // Open chat on launch so there's something visible
  chatWindow = createChatWindow();
  chatWindow.on("closed", () => {
    chatWindow = null;
  });

  // Start cursor buddy if enabled
  if (settings.get("cursorBuddyEnabled")) {
    startCursorBuddy();
  }

  console.log("Clicky Windows started — running in system tray");
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();
});

// Prevent app from closing when all windows are closed (tray app)
app.on("window-all-closed", () => {
  // Do nothing — keep app running in tray
});
