/**
 * launch-arguments.ts
 *
 * What a launch of `iris.exe` is being asked to do, decided from its argv
 * alone. Two callers:
 *
 * 1. **Squirrel.Windows install hooks.** Electron's own `iris.exe` carries the
 *    `SquirrelAwareVersion` resource, so Squirrel treats Iris as an app that
 *    manages its own shortcuts: it creates NONE itself, and instead runs
 *    `iris.exe --squirrel-install <version>` (and `--squirrel-updated`,
 *    `--squirrel-uninstall`, `--squirrel-obsolete`) and waits for it. Until
 *    0.9.15 nothing handled those, so every install left no Desktop or Start
 *    Menu shortcut, and the install hook booted the whole app — tray, chat,
 *    overlays and the single-instance lock — in the middle of the installer.
 *    A reader who closed that window had no icon to open Iris again. The fix
 *    is the standard one (what `electron-squirrel-startup` does): on
 *    install/update ask Squirrel's own `Update.exe` to create the shortcuts,
 *    on uninstall to remove them, then quit before any of the app starts.
 *    `--squirrel-firstrun` is different: it is the real first launch Squirrel
 *    makes after installing, so the app starts normally and only adds a
 *    one-time "here is where Iris lives" notice.
 *
 * 2. **A second launch while Iris is already running.** The single-instance
 *    lock turns it into a `second-instance` event carrying the new argv. An
 *    `iris://` link there is a deep link and keeps its own handling. Anything
 *    else is a person opening Iris again from the Desktop or Start Menu
 *    shortcut, and the one useful answer is the chat window, in front — the
 *    old handler "focused" whatever window it found first, which after the
 *    chat was closed was a transparent click-through overlay, so the launch
 *    visibly did nothing.
 *
 * Pure: no Electron import and no I/O, so the suite can pin every branch. The
 * main process owns spawning `Update.exe` and quitting.
 */
import path from "node:path";

import { IRIS_URL_SCHEME } from "./deep-link-parser";

/** The five hooks Squirrel.Windows runs an app's exe with. */
export type SquirrelEvent = "install" | "updated" | "uninstall" | "obsolete" | "firstrun";

const SQUIRREL_FLAG_TO_EVENT: Readonly<Record<string, SquirrelEvent>> = {
  "--squirrel-install": "install",
  "--squirrel-updated": "updated",
  "--squirrel-uninstall": "uninstall",
  "--squirrel-obsolete": "obsolete",
  "--squirrel-firstrun": "firstrun",
};

/**
 * Where Squirrel puts the shortcuts. Named explicitly rather than left to
 * `Update.exe`'s default (which is the same pair today) so the promise the
 * first-run notice makes — "on your desktop and in the Start menu" — cannot
 * drift away from what the installer actually does.
 */
export const SQUIRREL_SHORTCUT_LOCATIONS = "Desktop,StartMenu";

/**
 * The Squirrel hook this launch was started for, or null for an ordinary
 * launch. Squirrel always passes the flag as the first argument after the exe
 * (`iris.exe --squirrel-install 0.9.15`), but every position after the exe is
 * checked so a development launch (`electron . --squirrel-…`), where the app
 * path sits in between, behaves the same. Only an exact flag counts: a deep
 * link can never contain one, and a near-miss is not a hook.
 */
export function squirrelEventFromArgv(argv: readonly string[]): SquirrelEvent | null {
  for (const argument of argv.slice(1)) {
    const event = SQUIRREL_FLAG_TO_EVENT[argument];
    if (event) return event;
  }
  return null;
}

/** What the process does for a Squirrel hook. */
export type SquirrelStartupPlan =
  /** Run `Update.exe` with these arguments, wait for it, then quit. */
  | { kind: "runUpdateExeThenQuit"; updateExeArguments: string[] }
  /** Quit at once — nothing to do (an old version being cleaned up). */
  | { kind: "quitImmediately" }
  /** Start the app normally, and tell the reader where Iris lives. */
  | { kind: "startAsFirstRun" };

/**
 * `exeName` is the running executable's file name (`iris.exe`), which is how
 * `Update.exe` names the app whose shortcuts it manages.
 */
export function squirrelStartupPlan(event: SquirrelEvent, exeName: string): SquirrelStartupPlan {
  switch (event) {
    case "install":
    case "updated":
      // `updated` gets the same treatment as `install`, which is the standard
      // Squirrel handling: an update also restores a shortcut that is
      // missing. (Running a newer Iris-Setup.exe over an old copy is a fresh
      // `install` — Squirrel removes the old folder first — and that is how
      // every reader from before 0.9.15, who never had shortcuts, gets them.)
      return {
        kind: "runUpdateExeThenQuit",
        updateExeArguments: [
          `--createShortcut=${exeName}`,
          `--shortcut-locations=${SQUIRREL_SHORTCUT_LOCATIONS}`,
        ],
      };
    case "uninstall":
      return {
        kind: "runUpdateExeThenQuit",
        updateExeArguments: [
          `--removeShortcut=${exeName}`,
          `--shortcut-locations=${SQUIRREL_SHORTCUT_LOCATIONS}`,
        ],
      };
    case "obsolete":
      return { kind: "quitImmediately" };
    case "firstrun":
      return { kind: "startAsFirstRun" };
  }
}

/**
 * Squirrel's layout is `<root>\Update.exe` beside `<root>\app-<version>\iris.exe`,
 * so `Update.exe` is one folder up from the running exe. Always a Windows path —
 * this only ever runs on Windows, and `path.win32` keeps the suite on a Mac
 * computing the same answer the installed app does.
 */
export function squirrelUpdateExePath(executablePath: string): string {
  return path.win32.resolve(path.win32.dirname(executablePath), "..", "Update.exe");
}

/**
 * How long a hook waits for `Update.exe` before quitting anyway. Squirrel gives
 * each hook 15 seconds and then moves on without it; creating two shortcuts
 * takes well under one, so this only matters when `Update.exe` hangs or is
 * missing, and then quitting is the right outcome either way.
 */
export const SQUIRREL_HOOK_TIMEOUT_MS = 10_000;

/** What a second launch of Iris, while it is already running, is asking for. */
export type RelaunchIntent =
  | { kind: "deepLinks"; urls: string[] }
  | { kind: "openChat" };

/**
 * An `iris://` argument means a link (guide or sign-in callback) and keeps the
 * deep-link path. Everything else — a Desktop or Start Menu shortcut, the exe
 * double-clicked, a Squirrel first-run launch arriving second — is a person
 * opening Iris, which means the chat window.
 */
export function relaunchIntentFromArgv(argv: readonly string[]): RelaunchIntent {
  const urls = argv.filter((argument) => argument.startsWith(`${IRIS_URL_SCHEME}://`));
  if (urls.length > 0) return { kind: "deepLinks", urls };
  return { kind: "openChat" };
}
