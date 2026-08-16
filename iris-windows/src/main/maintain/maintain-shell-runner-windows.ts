/**
 * maintain-shell-runner-windows.ts
 *
 * The real, Windows-side implementation of
 * `services/maintain/maintain-shell-runner.ts`'s `MaintainShellRunner`
 * interface — the porting spec's `main/maintain/` module of the same name.
 *
 * Deliberately separate from `main/powershell-session.ts`'s `PowerShellSession`
 * (the autopilot's shell) — see `maintain-shell-runner.ts`'s own header and
 * the porting spec's decision 3: verification/replay/patch-queue commands are
 * code-authored constants (`"git diff --numstat HEAD"`, `"npm run build"`),
 * never guide/model text, and this runner is simpler than the autopilot's
 * because of it. `PowerShellSession` threads a persistent working directory
 * across calls because an install sequence's `cd repo` has to be felt by the
 * next step; every caller of `MaintainShellRunner` already passes an explicit
 * `inSubdirectory` (or runs at the repo root) instead, so each call is a
 * clean one-shot `powershell.exe -EncodedCommand` with no state carried
 * between them — reusing `wrapCommandScript`/`encodeForPowerShell` exported
 * from `powershell-session.ts` rather than re-deriving the marker-line parsing
 * convention, per the porting spec.
 *
 * This module spawns a process, so it lives in `main/`, not `services/` —
 * `services/maintain/*.ts` files must never import `child_process`. It is
 * exercised for real only on `windows-latest` CI; the pure logic layered on
 * top of `MaintainShellRunner` (`replay-engine.ts`, `verification-harness.ts`,
 * `patch-queue.ts`, `tier-c-fixer.ts`) is already proven against
 * `MockMaintainShellRunner` on any host — this file's own correctness, that
 * `powershell.exe -EncodedCommand` really runs the wrapped script and really
 * reports the exit code, can only be proven on real Windows.
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import { encodeForPowerShell, wrapCommandScript } from "../powershell-session";
import type { MaintainCommandResult, MaintainRunOptions, MaintainShellRunner } from "../../services/maintain/maintain-shell-runner";

const DEFAULT_DEADLINE_MS = 300_000;
const MAX_OUTPUT_TAIL = 16 * 1024;
const POWERSHELL_ARGS = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"];

const CODE_MARKER = "__IRIS_CODE__:";
const CWD_MARKER = "__IRIS_CWD__:";

/** One-shot `powershell.exe -EncodedCommand` per `run()` call, rooted at
 *  `repoRootPath`. No state survives between calls other than what git itself
 *  persisted to the working tree — see the file header for why this is a
 *  different shape than the autopilot's persistent pty-backed session. */
export class WindowsMaintainShellRunner implements MaintainShellRunner {
  constructor(public readonly repoRootPath: string) {}

  async run(command: string, opts?: MaintainRunOptions): Promise<MaintainCommandResult> {
    const cwd = opts?.inSubdirectory !== undefined ? path.join(this.repoRootPath, opts.inSubdirectory) : this.repoRootPath;
    const script = wrapCommandScript(command, cwd);
    const deadlineMs = opts?.deadlineMs ?? DEFAULT_DEADLINE_MS;

    const collected = await spawnEncodedScript(script, deadlineMs);
    if (collected === "timed_out") {
      return { succeeded: false, exitCode: -1, outputTail: "(timed out)" };
    }
    if (collected.spawnFailed) {
      return { succeeded: false, exitCode: -1, outputTail: "(could not start powershell.exe)" };
    }

    const parsed = parseMarkerLines(collected.stdout, collected.stderr);
    const exitCode = parsed.exitCode ?? 1;
    return {
      succeeded: exitCode === 0,
      exitCode,
      outputTail: parsed.output.slice(-MAX_OUTPUT_TAIL),
    };
  }
}

/** Builds a `WindowsMaintainShellRunner` rooted at `repoRootPath`, or
 *  `undefined` when the path is not usable — the real implementation of the
 *  `createShellRunner` seam `replay-engine.ts`/`tier-c-fixer.ts` take,
 *  mirroring Swift's `try? MaintainShellRunner(repoRootPath:)`. A relative or
 *  empty path is refused up front rather than failing confusingly on the
 *  first `run()` call. */
export function createWindowsMaintainShellRunner(repoRootPath: string): WindowsMaintainShellRunner | undefined {
  if (repoRootPath.trim().length === 0 || !path.isAbsolute(repoRootPath)) {
    return undefined;
  }
  return new WindowsMaintainShellRunner(repoRootPath);
}

// ---------------------------------------------------------------------------
// Small local helpers — deliberately duplicated rather than reaching into
// `PowerShellSession`'s private `spawnEncoded`/`parseRun` bodies (only the
// exported pure functions are reused, per the module header).
// ---------------------------------------------------------------------------

/** Strips the marker lines `wrapCommandScript` writes and reads the exit code
 *  back out — the same parsing convention `powershell-session.ts`'s own
 *  `parseRun` uses, duplicated narrowly here because this runner has no use
 *  for `parseRun`'s `cwd` tracking (every call already gets an explicit
 *  working directory; nothing here persists it forward). */
function parseMarkerLines(stdout: string, stderr: string): { exitCode: number | undefined; output: string } {
  let exitCode: number | undefined;
  const outputLines: string[] = [];

  for (const rawLine of stdout.split(/\r?\n/)) {
    if (rawLine.startsWith(CODE_MARKER)) {
      const parsed = Number.parseInt(rawLine.slice(CODE_MARKER.length).trim(), 10);
      exitCode = Number.isNaN(parsed) ? 1 : parsed;
    } else if (rawLine.startsWith(CWD_MARKER)) {
      // Emitted by `wrapCommandScript` but not tracked here — see the header.
      continue;
    } else {
      outputLines.push(rawLine);
    }
  }

  const combined = `${outputLines.join("\n")}\n${stderr}`.trim();
  return { exitCode, output: combined };
}

type SpawnCollected = "timed_out" | { readonly stdout: string; readonly stderr: string; readonly spawnFailed: boolean };

function spawnEncodedScript(script: string, deadlineMs: number): Promise<SpawnCollected> {
  return new Promise((resolve) => {
    const child = spawn("powershell.exe", [...POWERSHELL_ARGS, "-EncodedCommand", encodeForPowerShell(script)], {
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;

    const finish = (value: SpawnCollected): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    const timer = setTimeout(() => {
      child.kill();
      finish("timed_out");
    }, deadlineMs);

    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", () => finish({ stdout, stderr, spawnFailed: true }));
    child.on("close", () => finish({ stdout, stderr, spawnFailed: false }));
  });
}
