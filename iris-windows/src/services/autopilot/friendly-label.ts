//
// Turns a raw shell command into one plain-English line for the reader watching
// an install run in the autopilot terminal. The audience is non-technical:
// "Getting the app's code…" reads, `git clone https://github.com/…` does not.
// The real command still shows underneath, de-emphasised, so the terminal still
// reads as technical work — but the friendly line is what carries the meaning.
//
// The Windows/TS port of macOS `GuideAutopilotFriendlyLabel.swift`, widened for
// the Windows package managers (winget/choco/scoop) and PowerShell shapes. A
// heuristic with an honest catch-all: it never claims a different action than the
// command performs; the worst case is the generic "Running a setup step…", never
// a wrong specific one. Pure, so `runner.ts` can call it and vitest can pin it.
//

/// Whether a command launches an interactive GUI installer and blocks until the
/// reader dismisses its window — a `Start-Process … -Wait` on a freshly-built or
/// downloaded installer (the `install-app` shape shared by cue, hickeyfield,
/// nitroai, plantgpt, publikclip, simplicity, whimprflow). Iris still runs the
/// command (it launches the wizard), but the reader must click through the window
/// for the `-Wait` to return — so the reader needs a cue that a wizard is waiting
/// on them, not a silent spinner. Pure and directly tested. macOS never hits this
/// (its equivalent step is a plain `ditto` copy), so this is a Windows-idiomatic
/// addition rather than a straight port.
export function commandLaunchesAGuiInstaller(command: string): boolean {
  const lowercased = command.toLowerCase();
  return /\bstart-process\b/.test(lowercased) && /\s-wait\b/.test(lowercased);
}

export function friendlyLabel(command: string): string {
  const lowercased = command.toLowerCase();
  const mentions = (needle: string): boolean => lowercased.includes(needle);

  // An interactive installer wizard is the one shape where the plain-English line
  // must ask the reader to DO something (click through the window) rather than
  // just narrate — checked first so its cue is never masked by a more generic
  // match (a `Start-Process … -Wait` on `Foo-setup.exe` reads as nothing else).
  if (commandLaunchesAGuiInstaller(command)) {
    return "An installer window is opening — click through it, then Iris carries on…";
  }

  // Order matters: the most specific shapes first, the catch-all last.
  if (mentions("git clone")) {
    return "Getting the app's code…";
  }
  if (mentions("git checkout") || mentions("git switch")) {
    return "Getting the right version…";
  }
  if (
    mentions("cargo tauri build") ||
    mentions("tauri build") ||
    mentions("cargo build") ||
    mentions("msbuild") ||
    (mentions("npm run") && mentions("build")) ||
    mentions("npm run pack")
  ) {
    return "Building the app…";
  }
  if (mentions("npm run dev") || mentions("tauri dev") || mentions("npm start")) {
    return "Starting the app…";
  }
  if (
    mentions("npm install") ||
    mentions("npm ci") ||
    mentions("pnpm install") ||
    mentions("yarn install") ||
    mentions("bun install") ||
    (mentions("pip") && mentions("install"))
  ) {
    return "Installing the pieces it needs…";
  }
  if (
    mentions("winget install") ||
    mentions("choco install") ||
    mentions("scoop install") ||
    mentions("rustup") ||
    mentions("nvm install") ||
    mentions("install.ps1") ||
    (mentions("irm") && mentions("iex")) ||
    (mentions("curl") && (mentions("| sh") || mentions("|sh") || mentions("| bash")))
  ) {
    return "Installing a tool it needs…";
  }
  if (
    lowercased.startsWith("cd ") ||
    mentions("mkdir") ||
    mentions("new-item") ||
    mentions("copy-item") ||
    mentions("move-item") ||
    mentions("set-location")
  ) {
    return "Setting things up…";
  }
  return "Running a setup step…";
}
