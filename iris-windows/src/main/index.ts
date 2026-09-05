import { app, BrowserWindow, dialog, ipcMain, screen, shell } from "electron";
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
import { AutopilotController, type FinishedInstall } from "./autopilot-controller";
import { RegistryRefreshingToolProbe, RealDetourClock } from "./setup-detour-host";
import { MaintainController, type MaintainHost } from "./maintain/controller";
import type { MaintainAskAnswer, MaintainIncidentSnapshot } from "../services/maintain/incident-coordinator";

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
let maintain: MaintainController;
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
  // Windows only. The dev machine is a Mac whose real iris:// handler is the
  // Swift /Applications/Iris.app, and setAsDefaultProtocolClient sets a *user
  // default handler override* that outranks that app — so running this Electron
  // build on the Mac (as CI-mirrored dev testing does) silently steals iris://,
  // and the website's "Open in Iris" then launches this shell instead of Iris.
  // On Windows this build IS the handler; there it must register. The open-url
  // handler above stays for the case where macOS still hands us a link.
  if (process.platform !== "win32") return;
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

/** Floats the guide panel to a screen corner. Shared by the `glide_iris` command
 *  and the autopilot's "float to a gate". */
function glideGuidePanel(anchor: string): void {
  if (!guideWindow || guideWindow.isDestroyed()) return;
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const [windowWidth, windowHeight] = guideWindow.getSize();
  const margin = 24;
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
}

/** Opens a link only if the external-link allowlist permits it, swallowing a
 *  refusal so a side effect (opening a sign-in page, opening the finished app)
 *  never throws out of the autopilot. */
function openExternalSafely(url: string): void {
  const classification = classifyExternalLink(url);
  if (classification.allowed) void shell.openExternal(classification.url);
}

let autopilotWindow: BrowserWindow | null = null;
let autopilot: AutopilotController | null = null;

interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

const EYE_SIZE = 108;
const TERMINAL_WIDTH = 600;
const TERMINAL_HEIGHT = 460;

/** The eye's resting spot: the top-left corner of the current display. */
function autopilotEyeRect(): Rect {
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const margin = 28;
  return { x: display.workArea.x + margin, y: display.workArea.y + margin, width: EYE_SIZE, height: EYE_SIZE };
}

/** The terminal's spot: centred on the current display. */
function autopilotTerminalRect(): Rect {
  const { x, y, width, height } = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  return {
    x: Math.round(x + (width - TERMINAL_WIDTH) / 2),
    y: Math.round(y + (height - TERMINAL_HEIGHT) / 2),
    width: TERMINAL_WIDTH,
    height: TERMINAL_HEIGHT,
  };
}

/** Animates a window's bounds to `to` with an ease-out, then runs `done`, so the
 *  window grows or shrinks in step with the renderer's eye<->terminal crossfade. */
function animateWindowBounds(window: BrowserWindow, to: Rect, durationMs: number, done?: () => void): void {
  const from = window.getBounds();
  const frames = Math.max(1, Math.round(durationMs / 16));
  let frame = 0;
  const timer = setInterval(() => {
    if (window.isDestroyed()) {
      clearInterval(timer);
      return;
    }
    frame += 1;
    const progress = Math.min(1, frame / frames);
    const eased = 1 - Math.pow(1 - progress, 3);
    window.setBounds({
      x: Math.round(from.x + (to.x - from.x) * eased),
      y: Math.round(from.y + (to.y - from.y) * eased),
      width: Math.round(from.width + (to.width - from.width) * eased),
      height: Math.round(from.height + (to.height - from.height) * eased),
    });
    if (progress >= 1) {
      clearInterval(timer);
      done?.();
    }
  }, 16);
}

/** Opens the autopilot as the Iris eye in the top-left, then glides it to centre
 *  and morphs it into the terminal (the renderer crossfades in step). Shown on
 *  `did-finish-load`, which — unlike `ready-to-show` — fires reliably for a
 *  transparent frameless window; the old code relied on `ready-to-show` and so
 *  the window opened but stayed invisible. */
function openAutopilotWindow(slug: string): BrowserWindow {
  if (autopilotWindow && !autopilotWindow.isDestroyed()) {
    autopilotWindow.show();
    autopilotWindow.focus();
    return autopilotWindow;
  }
  autopilotWindow = new BrowserWindow({
    ...autopilotEyeRect(),
    frame: false,
    transparent: true,
    resizable: false,
    show: false,
    hasShadow: false,
    alwaysOnTop: true,
    backgroundColor: "#00000000",
    webPreferences: { preload: preloadPath(), contextIsolation: true, nodeIntegration: false },
  });
  const win = autopilotWindow;
  void win.loadFile(rendererPath("autopilot", "index.html"), { query: { slug } });
  win.webContents.once("did-finish-load", () => {
    if (win.isDestroyed()) return;
    win.show();
    win.focus();
    // Let the eye sit a beat in the corner, then fly to centre and become the
    // terminal — the renderer crossfades on the same "morph" signal.
    setTimeout(() => {
      if (win.isDestroyed()) return;
      win.webContents.send("autopilot:morph", "terminal");
      animateWindowBounds(win, autopilotTerminalRect(), 520);
    }, 650);
  });
  win.on("closed", () => {
    autopilotWindow = null;
    autopilot?.dispose();
  });
  return win;
}

/** Morphs the terminal back into the eye, glides it to the top-left, then closes —
 *  the "turn back into the eye" finish. Called by the renderer once it is done. */
function collapseAutopilotWindow(): void {
  const win = autopilotWindow;
  if (!win || win.isDestroyed()) return;
  win.webContents.send("autopilot:morph", "eye");
  animateWindowBounds(win, autopilotEyeRect(), 460, () => {
    setTimeout(() => {
      if (!win.isDestroyed()) win.close();
    }, 550);
  });
}

// MARK: - Maintain mode's ask card
//
// The one piece of UI maintain mode has: a small always-on-top card, bottom-
// right of the display the cursor is on — the notification corner, distinct
// from the autopilot's top-left eye so an install and an ask can never
// contend for the same spot. It appears the moment the coordinator has
// something to show (a pending ask, or a fix-status line after one was
// answered) and disappears the moment it does not — mirrored from Swift's
// `MaintainAskCard`, whose body "renders nothing when there is nothing to
// ask... which is almost always, by design." Unlike the overlay windows, this
// one is NOT click-through: the three answer buttons need real clicks, so it
// stays a small ordinary (if frameless, transparent, and non-activating on
// first appearance) window rather than joining `overlayWindows`.

let maintainWindow: BrowserWindow | null = null;
let maintainWindowReady = false;
let pendingMaintainSnapshot: MaintainIncidentSnapshot | null = null;

const MAINTAIN_CARD_WIDTH = 340;
/** Just tall enough for nothing — the window still exists at this height for
 *  an instant between `showInactive()` and the renderer's first real
 *  `maintain:resize` call, which happens within one animation frame of the
 *  card's content actually painting. */
const MAINTAIN_CARD_COLLAPSED_HEIGHT = 40;
const MAINTAIN_CARD_MAX_HEIGHT = 440;

/** Bottom-right of whatever display the cursor is on, sized to `height` and
 *  clamped to a sane range — the renderer measures its own content and calls
 *  back through `maintain:resize` (mirrors Swift's `clickyResizePanelToContent`
 *  notification, posted from `MaintainAskCard`'s `onAppear`/`onDisappear`). */
function maintainCardRect(height: number): Rect {
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const margin = 24;
  const clampedHeight = Math.max(MAINTAIN_CARD_COLLAPSED_HEIGHT, Math.min(MAINTAIN_CARD_MAX_HEIGHT, Math.round(height)));
  return {
    x: display.workArea.x + display.workArea.width - MAINTAIN_CARD_WIDTH - margin,
    y: display.workArea.y + display.workArea.height - clampedHeight - margin,
    width: MAINTAIN_CARD_WIDTH,
    height: clampedHeight,
  };
}

function createMaintainWindow(): BrowserWindow {
  const window = new BrowserWindow({
    ...maintainCardRect(MAINTAIN_CARD_COLLAPSED_HEIGHT),
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    closable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    show: false,
    backgroundColor: "#00000000",
    webPreferences: {
      preload: preloadPath(),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  window.setAlwaysOnTop(true, "screen-saver");
  void window.loadFile(rendererPath("maintain", "index.html"));
  window.webContents.once("did-finish-load", () => {
    maintainWindowReady = true;
    if (pendingMaintainSnapshot) {
      window.webContents.send("maintain:snapshot", pendingMaintainSnapshot);
      pendingMaintainSnapshot = null;
    }
  });
  window.on("closed", () => {
    maintainWindow = null;
    maintainWindowReady = false;
  });
  return window;
}

function maintainWindowInstance(): BrowserWindow {
  if (maintainWindow && !maintainWindow.isDestroyed()) return maintainWindow;
  maintainWindow = createMaintainWindow();
  return maintainWindow;
}

/** True exactly when the coordinator has nothing to show — the same
 *  condition `incident-coordinator.ts`'s own `currentSnapshot()` collapses
 *  to `EMPTY_SNAPSHOT` on. */
function maintainSnapshotIsEmpty(snapshot: MaintainIncidentSnapshot): boolean {
  return snapshot.pendingAsk === null && snapshot.fixStatusLine === null && snapshot.fixGuidanceSteps.length === 0;
}

function showMaintainCard(snapshot: MaintainIncidentSnapshot): void {
  const window = maintainWindowInstance();
  const currentHeight = window.isVisible() ? window.getBounds().height : MAINTAIN_CARD_COLLAPSED_HEIGHT;
  window.setBounds(maintainCardRect(currentHeight));
  if (maintainWindowReady) {
    window.webContents.send("maintain:snapshot", snapshot);
  } else {
    pendingMaintainSnapshot = snapshot;
  }
  if (!window.isVisible()) {
    // Inactive, like the overlay windows: an ask card that steals focus the
    // instant it appears would yank the keyboard out from under whatever the
    // reader was doing when the app crashed.
    window.showInactive();
    window.setAlwaysOnTop(true, "screen-saver");
  }
}

function hideMaintainCard(): void {
  if (maintainWindow && !maintainWindow.isDestroyed() && maintainWindow.isVisible()) {
    maintainWindow.hide();
  }
}

/** The host `MaintainController` pushes every observable state change
 *  through — the main-process half of the push/pull pair
 *  `incident-coordinator.ts`'s header describes. */
function maintainHost(): MaintainHost {
  return {
    emitSnapshot: (snapshot) => {
      if (maintainSnapshotIsEmpty(snapshot)) {
        hideMaintainCard();
      } else {
        showMaintainCard(snapshot);
      }
    },
  };
}

/** The one autopilot controller, built lazily. Its host turns runner events into
 *  the app-only side effects: streaming to the terminal, opening links, floating
 *  to a gate, and opening the finished app. */
function autopilotController(): AutopilotController {
  if (autopilot) return autopilot;
  autopilot = new AutopilotController({
    // The one-time "Let Iris take control?" consent, remembered across installs
    // via the persisted `autopilotAutonomyGranted` setting (revocable from the
    // settings window). Once granted, the whole vetted install runs hands-off.
    ensureAutonomyGranted: async () => {
      // The headed GUI e2e drives the autopilot with no one to click a modal, so
      // it pre-grants via IRIS_E2E (the same flag that unlocks the e2e-only guide
      // hook). The real granted/declined logic is unit-tested in
      // autopilot-controller.test.ts; a modal cannot be exercised headlessly.
      if (process.env.IRIS_E2E === "1") return true;
      if (settings.get("autopilotAutonomyGranted")) return true;
      const options = {
        type: "question" as const,
        buttons: ["Let Iris take control", "Not now"],
        defaultId: 0,
        cancelId: 1,
        message: "Let Iris take control of your PC?",
        detail:
          "Iris will run this install itself — installing the tools it needs, building the app, and setting it up — without asking you to approve each step. It never runs anything that would erase your disk, and you can turn this off anytime in Iris's settings.",
      };
      const parent = autopilotWindow && !autopilotWindow.isDestroyed() ? autopilotWindow : null;
      const result = parent
        ? await dialog.showMessageBox(parent, options)
        : await dialog.showMessageBox(options);
      const granted = result.response === 0;
      if (granted) settings.set("autopilotAutonomyGranted", true);
      return granted;
    },
    emitEvent: (event) => broadcast("autopilot:event", event),
    openExternal: (url) => openExternalSafely(url),
    floatToGate: (instruction, href) => {
      // Bring the terminal to the reader and open the page a sign-in step points
      // at; the renderer shows the instruction next to the eye. A model-located
      // glow at the exact field is a later refinement.
      const surface =
        autopilotWindow && !autopilotWindow.isDestroyed()
          ? autopilotWindow
          : guideWindow && !guideWindow.isDestroyed()
            ? guideWindow
            : null;
      if (surface) {
        surface.show();
        surface.focus();
      }
      if (href) openExternalSafely(href);
      broadcast("autopilot:gate", { instruction, href });
      // Then float the eye to the actual control the reader must use. A sign-in
      // page needs a moment to render before it can be found; a permission
      // prompt is already up. Best-effort — pointAtGate swallows its own errors.
      const pointingTarget = href ? `sign in on the page that just opened — ${instruction}` : instruction;
      const settleDelayMs = href ? 2500 : 800;
      setTimeout(() => void companion.pointAtGate(pointingTarget), settleDelayMs);
    },
    onFinished: (finishedInstall: FinishedInstall) => {
      // The one moment provenance is knowable for certain — a guide-source
      // clone maintain mode may later patch, versus a signed download it never
      // may. Recorded before anything opens, mirroring macOS's
      // `onGuideCompleted` → `recordInstallProvenance` ordering.
      maintain.recordInstallProvenance(finishedInstall);
      // Once it's done, the app just opens. A local_web app opens its URL; a
      // desktop app is left for the reader/inventory to launch (opening an
      // arbitrary exe path is deliberately not an autopilot side effect).
      const output = finishedInstall.output;
      if (output.type === "local_web") openExternalSafely(output.url);
      broadcast("autopilot:finished", output);
    },
  },
  // Leave the shell factory and recipe registry at their defaults…
  undefined,
  undefined,
  // …and wire the setup-recovery detour's real seams: a tool probe that re-reads
  // the PATH from the registry (so a tool the detour just installed is seen) and
  // the wall clock. Wiring them is what turns the detour on in production; the
  // unit suite leaves them out and injects fakes.
  { probe: new RegistryRefreshingToolProbe(), clock: new RealDetourClock() });
  return autopilot;
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
      glideGuidePanel(String(args.anchor ?? "bottom-right"));
      return null;
    }

    // ── Autopilot (guided install) ──────────────────────────────────────────
    // The panel drives an install through these; the runner streams its progress
    // back on the `autopilot:event` channel (see `autopilotController`).
    case "autopilot_open":
      // Opens the animated terminal window, which then calls `autopilot_start`.
      openAutopilotWindow(String(args.slug ?? ""));
      return null;

    case "autopilot_collapse":
      // The renderer finished; morph the terminal back into the eye and close.
      collapseAutopilotWindow();
      return null;

    case "autopilot_can_install":
      return autopilotController().canInstall(String(args.slug ?? ""));

    case "autopilot_start":
      return autopilotController().start(String(args.slug ?? ""));

    case "autopilot_confirm":
      return autopilotController().confirm(Boolean(args.approved));

    case "autopilot_reader_done":
      return autopilotController().readerFinished();

    case "foreground_app_identity":
      // Windows has no cross-process foreground-app API without a native module.
      // Returning null keeps the guide panel's watch strip honest instead of
      // inventing an answer; `app.js` already renders that case.
      return null;

    case "e2e_open_settings": {
      // TEST-ONLY, gated behind `IRIS_E2E=1`, so it never affects shipped
      // behaviour: outside the e2e suite this command does not exist and falls
      // through to the same "unknown command" error as any other. The headed
      // GUI e2e suite (`tests/gui-e2e/`) needs to open the Settings window from
      // CDP — a native tray click is not reachable over the DevTools protocol —
      // and there is otherwise no renderer-facing way in. See
      // `tests/gui-e2e/README.md`.
      if (process.env.IRIS_E2E !== "1") {
        throw new Error(`unknown Iris command '${command}'`);
      }
      if (settingsWindow && !settingsWindow.isDestroyed()) {
        settingsWindow.focus();
      } else {
        settingsWindow = createSettingsWindow();
        settingsWindow.on("closed", () => {
          settingsWindow = null;
        });
      }
      return null;
    }

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
    // Maintain mode's Tier C BYO fixer key — optional, and separate from the
    // companion-chat Anthropic key above. Same "whether, never what" rule.
    hasOpenAiApiKey: Boolean(settings.getOpenAiApiKey()),
    secretStorageAvailable: secretStorageIsAvailable(),
    signedIn: account.isSignedIn(),
    signedInEmail: account.signedInEmail(),
    supabaseConfigured: configuredSupabaseProject() !== null,
  }));

  ipcMain.handle("settings:set", (_event, key: string, value: unknown) => {
    if (key === "anthropicApiKey") {
      return settings.setAnthropicApiKey(String(value ?? ""));
    }
    if (key === "openaiApiKey") {
      return settings.setOpenAiApiKey(String(value ?? ""));
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

  // ── Maintain mode ────────────────────────────────────────────────────────
  // The five calls the ask card drives, plus the resize callback described in
  // `showMaintainCard`'s comment. `maintain:snapshot` (the push half) is sent
  // directly to `maintainWindow`, not broadcast to every window, since the
  // card is the only renderer that ever needs it.
  ipcMain.handle("maintain:getSnapshot", () => maintain.currentSnapshot());
  ipcMain.handle("maintain:answerAsk", (_event, answer: MaintainAskAnswer) => maintain.answerAsk(answer));
  ipcMain.handle("maintain:clearFixStatus", () => maintain.clearFixStatus());
  ipcMain.handle("maintain:mutedApps", () => maintain.mutedApps());
  ipcMain.handle("maintain:unmuteApp", (_event, appSlug: string) => maintain.unmuteApp(appSlug));
  ipcMain.handle("maintain:resize", (_event, height: number) => {
    if (maintainWindow && !maintainWindow.isDestroyed()) {
      maintainWindow.setBounds(maintainCardRect(height));
    }
  });
}

// MARK: - Bootstrap

if (gotSingleInstanceLock) {
  void app.whenReady().then(() => {
    registerIrisScheme();

    overlayWindows = createOverlayWindows();
    companion = new CompanionManager(settings, account, overlayWindows);
    maintain = new MaintainController(maintainHost());

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

    // Test convenience: `IRIS_AUTOPILOT_DEMO=<slug>` opens the animated terminal
    // and starts installing that app straight away, so the whole autopilot can be
    // watched running an install end to end with no clicks.
    const demoSlug = process.env.IRIS_AUTOPILOT_DEMO;
    if (demoSlug && demoSlug.length > 0) {
      openAutopilotWindow(demoSlug);
    }

    // The always-on detection layer: the crash-artifact watch (event-driven,
    // free) and — on Windows — the 2s hang-probe tick over the frontmost
    // catalog app. Self-triggers a real ask when one of ours (publikclip,
    // today) crashes or hangs; see `maintain/controller.ts`'s `startDetection`.
    maintain.startDetection();

    // Same idiom, maintain mode's side: `IRIS_MAINTAIN_DEMO_CRASH=<slug>`
    // raises a synthetic ask a few seconds in, so the whole ladder — ask
    // card, pool round trip, fix status — is provable with no real crash.
    maintain.triggerDemoIncidentIfConfigured();

    console.log("Iris for Windows started — running in the system tray");
  });
}

// Tray app: closing every window must not quit.
app.on("window-all-closed", () => {
  // Deliberately empty.
});
