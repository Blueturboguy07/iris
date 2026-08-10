//
// The shell the autopilot runs approved commands in.
//
// `ShellSession` is the seam: the runner is written against this interface, so it
// is driven by a `MockShell` in the vitest suite and by a real persistent
// PowerShell (src/main/powershell-session.ts) at runtime. A session is
// *persistent* — working directory and environment carry from one step to the
// next — because an install is a sequence (`git clone`, then `cd repo`, then
// `pnpm install`) that falls apart if each step starts fresh.
//
// This module is pure (no `child_process`), so it stays in `services/` and runs
// in the suite on any host. The real handle lives in `main/`.
//

import type { ApprovedCommand } from "./risk";

/// The default per-command ceiling (ms). A real install command can be slow
/// (a large `winget install`, a `pnpm install`), so this is generous; it exists
/// to stop a hung command wedging the autopilot, not to hurry anything.
export const DEFAULT_COMMAND_TIMEOUT_MS = 15 * 60 * 1000;

/// How long to wait for a dev server to announce itself before treating it as
/// started (ms). Generous: a first `pnpm dev` compiles before it serves.
export const LONG_RUNNING_GRACE_MS = 90 * 1000;

/// What running one command produced. A long-running (dev-server) command may
/// also report the URL it is actually serving on, so the "open" step can land on
/// the real port even when the default one was already taken.
export type CommandOutcome =
  | { readonly kind: "succeeded"; readonly output: string; readonly servedUrl?: string }
  | { readonly kind: "failed"; readonly exitCode: number; readonly output: string }
  | { readonly kind: "timed_out" }
  | { readonly kind: "session_failed" };

export function succeeded(outcome: CommandOutcome): boolean {
  return outcome.kind === "succeeded";
}

/// Pulls the first localhost URL a dev server prints out of its output (Vite's
/// "Local: http://localhost:5174/"), so the install opens the app that is really
/// there rather than whatever was squatting on the default port.
export function detectServedUrl(output: string): string | undefined {
  const match = output.match(/https?:\/\/(?:localhost|127\.0\.0\.1):\d+/i);
  return match ? match[0] : undefined;
}

/// A persistent shell the runner drives.
export interface ShellSession {
  /// Runs an approved command to completion in the persistent session.
  run(command: ApprovedCommand, deadlineMs: number): Promise<CommandOutcome>;

  /// Starts a command that is not expected to exit — a dev server. Resolves once
  /// the readiness marker appears in its output, or once `graceMs` elapses,
  /// whichever comes first; the command keeps running afterward. `succeeded`
  /// means "started" here, not "finished".
  runLongRunning(
    command: ApprovedCommand,
    readyMarker: string | undefined,
    graceMs: number,
  ): Promise<CommandOutcome>;

  /// Where the session currently is, for surfacing on failure.
  currentDirectory(): string;

  /// Shuts the session down.
  dispose(): void;
}

/// A scripted shell for the suite: returns queued outcomes in order and records
/// every command it was asked to run.
export class MockShell implements ShellSession {
  readonly commandsRun: string[] = [];
  private next = 0;

  constructor(
    private readonly outcomes: readonly CommandOutcome[] = [],
    public cwd = "C:\\Users\\test",
  ) {}

  /// A shell where every command succeeds.
  static alwaysSucceeds(): MockShell {
    return new MockShell();
  }

  async run(command: ApprovedCommand, _deadlineMs: number): Promise<CommandOutcome> {
    this.commandsRun.push(command.text);
    const outcome = this.outcomes[this.next] ?? { kind: "succeeded", output: "" };
    this.next += 1;
    return outcome;
  }

  async runLongRunning(
    command: ApprovedCommand,
    _readyMarker: string | undefined,
    _graceMs: number,
  ): Promise<CommandOutcome> {
    // A started server counts as run; tests assert on `commandsRun`.
    return this.run(command, DEFAULT_COMMAND_TIMEOUT_MS);
  }

  currentDirectory(): string {
    return this.cwd;
  }

  dispose(): void {
    // Nothing to tear down.
  }
}
