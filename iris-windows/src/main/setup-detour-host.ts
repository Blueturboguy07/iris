//
// The real seams the setup-recovery detour runs against — the `main/` side of
// `services/autopilot/setup-detour.ts`, which is pure and only knows the
// `ToolProbe`/`DetourClock` interfaces.
//
// The one thing that matters here that a plain version check does not do: the
// probe re-reads the machine+user PATH from the registry before it looks for the
// tool, so a tool the autopilot installed moments ago (whose PATH entry a fresh
// `powershell.exe` would otherwise not inherit until Iris restarts) is found.
// This is why the detour can install git with winget and then, on the very next
// poll, see it. Mirrors the PATH refresh `wrapCommandScript` does per command.
//
// This module spawns processes, so it lives in `main/`. Its behaviour on
// windows-latest is exercised by the packaged app on CI; the pure decision logic
// it serves is unit-tested with fakes.
//

import { execFile, spawn } from "node:child_process";

import { isAllowlistedTool, toolSpecFor } from "../services/tool-versions";
import type { DetourClock, ToolProbe } from "../services/autopilot/setup-detour";
import { REFRESH_PATH_FROM_REGISTRY, encodeForPowerShell } from "./powershell-session";

const POWERSHELL_ARGS = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"];
const PROBE_TIMEOUT_MS = 10_000;

/// Whether a `Get-Command <tool>`, run in a PowerShell whose PATH was just
/// refreshed from the registry, finds the tool. The tool name is only ever an
/// allowlisted one (guarded by the caller and again here), so it is safe to
/// interpolate — there is no guide text in this path.
function findsToolWithFreshPath(tool: string): Promise<boolean> {
  return new Promise((resolve) => {
    const script = [
      REFRESH_PATH_FROM_REGISTRY,
      `if (Get-Command ${tool} -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }`,
      "",
    ].join("\n");
    const child = spawn(
      "powershell.exe",
      [...POWERSHELL_ARGS, "-EncodedCommand", encodeForPowerShell(script)],
      { windowsHide: true },
    );
    let settled = false;
    const finish = (found: boolean): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(found);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(false);
    }, PROBE_TIMEOUT_MS);
    child.on("error", () => finish(false));
    child.on("exit", (code) => finish(code === 0));
  });
}

/// Whether the tool answers its allowlisted `--version` probe — the check used
/// when Iris runs on a Mac to exercise the flow (the login shell the POSIX
/// session drives already carries the developer's PATH, so no registry refresh
/// applies). Runs the exact executable+args `tool-versions.ts` sanctions, never
/// anything built from recipe text.
function answersItsVersionProbe(tool: string): Promise<boolean> {
  const spec = toolSpecFor(tool);
  if (spec === null) return Promise.resolve(false);
  const [executable, args] = spec;
  return new Promise((resolve) => {
    execFile(executable, [...args], { windowsHide: true, timeout: PROBE_TIMEOUT_MS, shell: false }, (error) => {
      resolve(!error);
    });
  });
}

/// The production `ToolProbe`: a PowerShell `Get-Command` with a
/// freshly-refreshed PATH on Windows (so an install the detour just ran is seen),
/// and a plain version probe on macOS/Linux (the dev-testing host).
export class RegistryRefreshingToolProbe implements ToolProbe {
  async isInstalled(tool: string): Promise<boolean> {
    if (!isAllowlistedTool(tool)) return false;
    return process.platform === "win32" ? findsToolWithFreshPath(tool) : answersItsVersionProbe(tool);
  }

  async isWingetAvailable(): Promise<boolean> {
    return this.isInstalled("winget");
  }
}

/// The production `DetourClock`: the wall clock and a real sleep.
export class RealDetourClock implements DetourClock {
  now(): number {
    return Date.now();
  }

  sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
