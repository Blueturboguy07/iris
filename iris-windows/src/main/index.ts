import { app, BrowserWindow, ipcMain, screen, shell } from "electron";
import { execFile } from "node:child_process";
import path from "node:path";
import { createTray } from "./tray";
import { SettingsStore } from "./settings";
import { CompanionManager } from "./companion";
import { AccountSession, configuredSupabaseProject } from "./account-session";
import {
  GuideDeepLink,
  IRIS_URL_SCHEME,
  parseIrisDeepLink,
} from "../services/deep-link-parser";
import { classifyExternalLink, refusalMessage } from "../services/external-links";
import { boundedCommandOutput, toolSpecFor } from "../services/tool-versions";
import { secretStorageIsAvailable } from "./secrets";

/**
 * index.ts
 *
 * Windows shell for Iris: windows, tray, IPC, and the `iris://` scheme.
 *
 * The command names handled here (`check_tool_version`, `take_pending_guide`,
 * `open_external`, ...) are the ones `src/renderer/guide/app.js` already
 * invokes — that file is the Tauri panel transplanted verbatim, so this process
 * answers the same vocabulary its Rust counterpart does.
 */

let chatWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let overlayWindows: BrowserWindow[] = [];

const settings = new SettingsStore();
const account = new AccountSession(settings);
let companion: CompanionManager;
let cursorBuddyInterval: ReturnType<typeof setInterval> | null = null;

/** A guide link that arrived before the panel was ready to receive it. */
let pendingGuideDeepLink: GuideDeepLink | null = null;

// MARK: - Deep links

/**
 * Windows delivers a custom-scheme link by launching the app again with the URL
 * in argv, so a single-instance lock is what turns that second launch into a
 * message to the running app rather than a second Iris.
 */
const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on("second-instance", (_event, argv) => {
    receiveDeepLinksFromArgv(argv);
    focusExistingWindow();
  });
  // macOS/Linux dev convenience; on Windows the argv path above is the real one.
  app.on("open-url", (event, url) => {
    event.preventDefault();
    receiveDeepLink(url);
  });
}

function registerIrisScheme(): void {
  if (process.defaultApp && process.argv.length >= 2) {
    // In development the executable is Electron itself, so the registration has
    // to name the script too or Windows launches a bare Electron.
    app.setAsDefaultProtocolClient(IRIS_URL_SCHEME, process.execPath, [
      path.resolve(process.argv[1]),
    ]);
  } else {
    app.setAsDefaultProtocolClient(IRIS_URL_SCHEME);
  }
}

function receiveDeepLinksFromArgv(argv: string[]): void {
  for (const argument of argv) {
    if (argument.startsWith(`${IRIS_URL_SCHEME}://`)) receiveDeepLink(argument);
  }
}

function receiveDeepLink(url: string): void {
  const result = parseIrisDeepLink(url);
  if (!result.ok) {
    broadcast("iris-deep-link-rejected", result.rejection);
    return;
  }

  if (result.link.kind === "guide") {
    pendingGuideDeepLink = result.link.guide;
    openGuideWindow();
    broadcast("iris-guide-opened", result.link.guide);
    return;
  }

  account
    .completeSignIn(result.link.authCallback)
    .then(() => broadcast("iris-account-changed", { signedIn: true }))
    .catch((error: unknown) => {
      broadcast("iris-account-error", error instanceof Error ? error.message : String(error));
    });
}

function broadcast(channel: string, payload: unknown): void {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed()) window.webContents.send(channel, payload);
  }
}

function focusExistingWindow(): void {
  const window = chatWindow ?? BrowserWindow.getAllWindows().find((each) => !each.isDestroyed());
  if (!window || window.isDestroyed()) return;
  if (window.isMinimized()) window.restore();
  window.show();
  window.focus();
}

// MARK: - Cursor buddy

function startCursorBuddy(): void {
  if (cursorBuddyInterval) return;
  cursorBuddyInterval = setInterval(() => {
    if (overlayWindows.length === 0) return;
    const point = screen.getCursorScreenPoint();
    // Route the buddy to the overlay for the display that contains the cursor and
    // hide it on every other one. Coordinates are translated into that display's
    // local space, exactly as POINT tags are.
    const targetDisplay = screen.getDisplayNearestPoint(point);
    const displays = screen.getAllDisplays();
    const targetIndex = displays.findIndex((display) => display.id === targetDisplay.id);
    for (let index = 0; index < overlayWindows.length; index++) {
      const window = overlayWindows[index];
      if (!window || window.isDestroyed()) continue;
      if (index === targetIndex) {
        window.webContents.send(
          "overlay:cursor-buddy",
          point.x - targetDisplay.bounds.x,
          point.y - targetDisplay.bounds.y
        );
      } else {
        window.webContents.send("overlay:cursor-buddy-visible", false);
      }
    }
  }, 16);
}

function stopCursorBuddy(): void {
  if (cursorBuddyInterval) {
    clearInterval(cursorBuddyInterval);
    cursorBuddyInterval = null;
  }
  for (const window of overlayWindows) {
    if (window && !window.isDestroyed()) {
      window.webContents.send("overlay:cursor-buddy-visible", false);
    }
  }
}

// MARK: - Windows

const preloadPath = () => path.join(__dirname, "..", "preload", "index.js");
const rendererPath = (...segments: string[]) =>
  path.join(__dirname, "..", "..", "src", "renderer", ...segments);

/**
 * One transparent click-through overlay per display. The array index matches
 * `screen.getAllDisplays()`, which is also the order `ScreenCapture` uses, so a
 * POINT tag's `screen` field indexes into this array directly.
 */
function createOverlayWindows(): BrowserWindow[] {
  return screen.getAllDisplays().map((display, index) => createOverlayWindow(display, index));
}

function createOverlayWindow(display: Electron.Display, displayIndex: number): BrowserWindow {
  const { x, y, width, height } = display.bounds;

  const window = new BrowserWindow({
    x,
    y,
    width,
    height,
    transparent: true,
    frame: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    closable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: false,
    hasShadow: false,
    show: false,
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  window.setIgnoreMouseEvents(true, { forward: true });
  window.setAlwaysOnTop(true, "screen-saver");
  void window.loadFile(rendererPath("overlay", "index.html"));

  // Windows sometimes drops always-on-top at show time, and `ready-to-show` does
  // not always fire for transparent windows — hence both paths.
  window.once("ready-to-show", () => {
    window.showInactive();
    window.setAlwaysOnTop(true, "screen-saver");
  });
  window.webContents.once("did-finish-load", () => {
    if (!window.isVisible()) {
      window.showInactive();
      window.setAlwaysOnTop(true, "screen-saver");
    }
  });
  window.webContents.on("console-message", (_event, level, message, line) => {
    console.log(`[overlay${displayIndex}:${level}] ${message} (line ${line})`);
  });

  return window;
}

function createChatWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 420,
    height: 550,
    resizable: true,
    show: false,
    frame: false,
    alwaysOnTop: settings.get("alwaysOnTop"),
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  void window.loadFile(rendererPath("chat", "index.html"));
  window.once("ready-to-show", () => {
    window.show();
    if (settings.get("alwaysOnTop")) {
      // More reliable after show than as a constructor option, and Windows can
      // still reset it a moment later.
      window.setAlwaysOnTop(true, "screen-saver");
      setTimeout(() => {
        if (!window.isDestroyed()) window.setAlwaysOnTop(true, "screen-saver");
      }, 500);
    }
  });
  return window;
}

let guideWindow: BrowserWindow | null = null;

function openGuideWindow(): BrowserWindow {
  if (guideWindow && !guideWindow.isDestroyed()) {
    guideWindow.show();
    guideWindow.focus();
    return guideWindow;
  }

  guideWindow = new BrowserWindow({
    width: 420,
    height: 620,
    resizable: true,
    show: false,
    frame: false,
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  void guideWindow.loadFile(rendererPath("guide", "index.html"));
  guideWindow.once("ready-to-show", () => guideWindow?.show());
  guideWindow.on("closed", () => {
    guideWindow = null;
  });
  return guideWindow;
}

function createSettingsWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 500,
    height: 600,
    resizable: false,
    show: false,
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  void window.loadFile(rendererPath("settings", "index.html"));
  window.once("ready-to-show", () => window.show());
  return window;
}

// MARK: - The guide panel's native commands

async function checkToolVersion(tool: string): Promise<{
  tool: string;
  available: boolean;
  version: string;
}> {
  const spec = toolSpecFor(tool);
  if (!spec) throw new Error(`tool '${tool}' is not allowlisted`);
  const [executable, args] = spec;

  return new Promise((resolve) => {
    execFile(
      executable,
      [...args],
      { windowsHide: true, timeout: 10_000, shell: false },
      (error, stdout, stderr) => {
        const version = boundedCommandOutput(String(stdout), String(stderr));
        if (error && !version) {
          resolve({ tool, available: false, version: "" });
          return;
        }
        resolve({ tool, available: !error, version });
      }
    );
  });
}

function handleGuideCommand(command: string, args: Record<string, unknown>): unknown {
  switch (command) {
    case "take_pending_guide": {
      // Taken, not read: a pending link is delivered exactly once, so reopening
      // the panel later does not silently reset the reader's place.
      const guide = pendingGuideDeepLink;
      pendingGuideDeepLink = null;
      return guide;
    }

    case "check_tool_version":
      return checkToolVersion(String(args.tool ?? ""));

    case "open_external": {
      const classification = classifyExternalLink(args.url);
      if (!classification.allowed) {
        // Refuse loudly. The panel turns this into a disabled control naming the
        // host rather than a button that appears to do nothing.
        throw new Error(refusalMessage(classification) ?? "Iris blocked that link.");
      }
      return shell.openExternal(classification.url);
    }

    case "quit_iris":
      app.quit();
      return null;

    case "hide_iris":
      guideWindow?.hide();
      return null;

    case "resize_iris": {
      const presetSizes: Record<string, { width: number; height: number }> = {
        collapsed: { width: 420, height: 220 },
        menu: { width: 420, height: 520 },
        guide: { width: 420, height: 620 },
      };
      const size = presetSizes[String(args.preset ?? "guide")] ?? presetSizes.guide;
      if (guideWindow && !guideWindow.isDestroyed()) {
        guideWindow.setSize(size.width, size.height, true);
      }
      return null;
    }

    case "glide_iris": {
      if (!guideWindow || guideWindow.isDestroyed()) return null;
      const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
      const [windowWidth, windowHeight] = guideWindow.getSize();
      const margin = 24;
      const anchor = String(args.anchor ?? "bottom-right");
      const isRight = anchor.includes("right");
      const isBottom = anchor.includes("bottom");
      guideWindow.setPosition(
        isRight
          ? display.bounds.x + display.bounds.width - windowWidth - margin
          : display.bounds.x + margin,
        isBottom
          ? display.bounds.y + display.bounds.height - windowHeight - margin
          : display.bounds.y + margin,
        true
      );
      return null;
    }

    case "foreground_app_identity":
      // Windows has no cross-process foreground-app API without a native module.
      // Returning null keeps the guide panel's watch strip honest instead of
      // inventing an answer; `app.js` already renders that case.
      return null;

    default:
      throw new Error(`unknown Iris command '${command}'`);
  }
}

// MARK: - IPC

function setupIPC(): void {
  ipcMain.handle("chat:query", async (_event, text: string) => companion.processQuery(text));

  ipcMain.handle("settings:getAll", () => ({
    ...settings.getAll(),
    // Never the key itself — only whether one is stored.
    hasAnthropicApiKey: Boolean(settings.getAnthropicApiKey()),
    secretStorageAvailable: secretStorageIsAvailable(),
    signedIn: account.isSignedIn(),
    signedInEmail: account.signedInEmail(),
    supabaseConfigured: configuredSupabaseProject() !== null,
  }));

  ipcMain.handle("settings:set", (_event, key: string, value: unknown) => {
    if (key === "anthropicApiKey") {
      return settings.setAnthropicApiKey(String(value ?? ""));
    }
    settings.set(key as never, value as never);
    if (key === "alwaysOnTop" && chatWindow && !chatWindow.isDestroyed()) {
      chatWindow.setAlwaysOnTop(Boolean(value), "screen-saver");
    }
    if (key === "cursorBuddyEnabled") {
      if (value) startCursorBuddy();
      else stopCursorBuddy();
    }
    return true;
  });

  ipcMain.handle("account:signIn", (_event, provider: string) =>
    account.beginSignIn(provider === "github" ? "github" : "google")
  );
  ipcMain.handle("account:signOut", () => {
    account.signOut();
    broadcast("iris-account-changed", { signedIn: false });
  });

  ipcMain.handle("guide:open", () => {
    openGuideWindow();
  });

  // The single entry point the transplanted guide panel uses.
  ipcMain.handle("iris:invoke", (_event, command: string, args: Record<string, unknown>) =>
    handleGuideCommand(command, args ?? {})
  );

  ipcMain.handle("shell:openExternal", (_event, url: string) => {
    const classification = classifyExternalLink(url);
    if (!classification.allowed) {
      throw new Error(refusalMessage(classification) ?? "Iris blocked that link.");
    }
    return shell.openExternal(classification.url);
  });

  ipcMain.handle("window:minimize", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.minimize();
  });
  ipcMain.handle("window:close", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.close();
  });
}

// MARK: - Bootstrap

if (gotSingleInstanceLock) {
  void app.whenReady().then(() => {
    registerIrisScheme();

    overlayWindows = createOverlayWindows();
    companion = new CompanionManager(settings, account, overlayWindows);

    setupIPC();

    createTray({
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
      onGuide: () => openGuideWindow(),
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

    chatWindow = createChatWindow();
    chatWindow.on("closed", () => {
      chatWindow = null;
    });

    if (settings.get("cursorBuddyEnabled")) startCursorBuddy();

    // A link that launched the app is sitting in this process's own argv.
    receiveDeepLinksFromArgv(process.argv);

    console.log("Iris for Windows started — running in the system tray");
  });
}

// Tray app: closing every window must not quit.
app.on("window-all-closed", () => {
  // Deliberately empty.
});
