import { Tray, Menu, nativeImage, Notification } from "electron";
import path from "node:path";

import type { AutopilotEvent } from "../services/autopilot/runner";
import { YourTurnTracker } from "../services/autopilot/your-turn";

interface TrayCallbacks {
  onChat: () => void;
  onGuide: () => void;
  onSettings: () => void;
  onQuit: () => void;
  /// Bring the autopilot window to the front — the "your turn" menu item and the
  /// toast both land the reader on the install that is waiting for them.
  onYourTurn: () => void;
  /// The red 'Stop' escape hatch, reachable from the tray as well as the
  /// autopilot window: abort the running install and fold its window away.
  onStopInstall: () => void;
}

const RESTING_TOOLTIP = "Iris — publik's desktop companion";
const YOUR_TURN_TOOLTIP = "Iris needs you — your turn";

let tray: Tray | null = null;
let callbacks: TrayCallbacks | null = null;
// The tracker turns the stream of autopilot events into "waiting on the reader"
// transitions; `installActive` is the separate fact of whether a run exists at
// all (so 'Stop the install' shows during a run even while a command is running,
// not only while waiting).
const tracker = new YourTurnTracker();
let waitingInstruction: string | undefined;
let installActive = false;

export function createTray(cb: TrayCallbacks): Tray {
  callbacks = cb;
  const icon = nativeImage.createFromPath(
    path.join(__dirname, "..", "..", "assets", "icon.ico")
  );
  tray = new Tray(icon);

  tray.setToolTip(RESTING_TOOLTIP);
  rebuildMenu();

  // Left-click opens the chat window directly — unless an install is waiting on
  // the reader, in which case it takes them to that instead.
  tray.on("click", () => {
    if (tracker.isWaiting) cb.onYourTurn();
    else cb.onChat();
  });

  return tray;
}

/// Rebuilds the context menu from the current state. Electron menus are
/// immutable once built, so a state change (a run starting, the reader's turn
/// arriving) rebuilds the whole template rather than toggling an item.
function rebuildMenu(): void {
  if (!tray || !callbacks) return;
  const cb = callbacks;

  const template: Electron.MenuItemConstructorOptions[] = [{ label: "Iris", enabled: false }];

  if (tracker.isWaiting) {
    template.push(
      { type: "separator" },
      {
        label: waitingInstruction ? `Your turn — ${trimForMenu(waitingInstruction)}` : "Your turn — bring Iris to front",
        click: cb.onYourTurn,
      },
    );
  }

  template.push(
    { type: "separator" },
    { label: "Ask Iris", click: cb.onChat },
    { label: "Install guide", click: cb.onGuide },
    { label: "Settings", click: cb.onSettings },
  );

  if (installActive) {
    template.push({ type: "separator" }, { label: "Stop the install", click: cb.onStopInstall });
  }

  template.push({ type: "separator" }, { label: "Quit", click: cb.onQuit });

  tray.setContextMenu(Menu.buildFromTemplate(template));
}

/// A menu label wants one short line; a multi-line instruction is squeezed to
/// its first sentence-ish chunk so the item stays readable.
function trimForMenu(instruction: string): string {
  const firstLine = instruction.split("\n")[0]!.trim();
  return firstLine.length > 48 ? `${firstLine.slice(0, 47)}…` : firstLine;
}

/// Feed one autopilot event to the tray. Raises the "your turn" state (with a
/// one-off toast) when the run stops for the reader, and clears it when the run
/// moves again. Called from the autopilot host's `emitEvent`.
export function observeAutopilotEventForTray(event: AutopilotEvent): void {
  // A run that ends — for any reason — is no longer active, so 'Stop the
  // install' should disappear even if the tracker treated the event as a
  // "moving again" clear.
  if (event.type === "finished" || event.type === "aborted") {
    installActive = false;
  }

  const update = tracker.observe(event);
  if (update.action === "raise") {
    waitingInstruction = update.instruction;
    tray?.setToolTip(YOUR_TURN_TOOLTIP);
    rebuildMenu();
    if (update.notify) showYourTurnToast(update.instruction);
  } else if (update.action === "clear") {
    waitingInstruction = undefined;
    tray?.setToolTip(RESTING_TOOLTIP);
    rebuildMenu();
  } else if (event.type === "finished" || event.type === "aborted") {
    // Not a waiting-state change, but the run ended: refresh so 'Stop the
    // install' is removed.
    rebuildMenu();
  }
}

/// Marks whether an install is running, so 'Stop the install' shows for its
/// whole duration. Set true when the autopilot window opens, false when it
/// closes or the run ends.
export function setTrayInstallActive(active: boolean): void {
  if (installActive === active) return;
  installActive = active;
  rebuildMenu();
}

/// Clears any pending "your turn" state — used when the autopilot window closes
/// so a stale tooltip/menu never outlives the run.
export function clearTrayYourTurn(): void {
  if (!tracker.isWaiting && waitingInstruction === undefined) return;
  // Feed a synthetic "moving again" so the tracker's own state clears too.
  tracker.observe({ type: "aborted" });
  waitingInstruction = undefined;
  tray?.setToolTip(RESTING_TOOLTIP);
  rebuildMenu();
}

function showYourTurnToast(instruction: string): void {
  if (!Notification.isSupported()) return;
  new Notification({
    title: "Iris needs you",
    body: trimForMenu(instruction),
  }).show();
}
