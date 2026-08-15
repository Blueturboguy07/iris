//
// The shell seam maintain mode runs its own commands through — `git diff`,
// `git stash`, a build, a test suite, a patch replay. Distinct from
// `autopilot/shell.ts`'s `ShellSession` on purpose (see the maintain-mode
// porting spec, decision 3, and `autopilot/risk.ts`'s header): the commands
// that reach this runner are code-authored constants ("git diff --numstat
// HEAD", "npm run build"), never guide or model text, so they must never be
// minted through `risk.ts`'s `ApprovedCommand` gate — that gate exists to
// police untrusted text, and nothing that reaches this runner is untrusted
// text. Mirrors Swift's `MaintainShellRunner`, kept deliberately separate from
// `GuideAutopilotShellSession`: verification is machinery, not theater — it
// wants exit codes and captured output, runs many commands back to back, and
// has no interactive pty to keep alive between them.
//
// `MaintainShellRunner` is the interface `verification-harness.ts` and
// `patch-queue.ts` are written against, so they are driven by
// `MockMaintainShellRunner` in the vitest suite and by a real process runner at
// runtime. This module stays pure (no `child_process`), so it lives in
// `services/` and runs in the suite on any host; the real runner — a one-shot
// `powershell.exe -EncodedCommand` per call — lives in `main/maintain/`.
//

/// What running one maintain-mode command produced. Mirrors Swift's
/// `MaintainCommandResult`: `succeeded` folds a non-zero exit code and a
/// timeout together, because every caller in this layer only ever asks "did
/// that work", never "why not" beyond the tail it already captured.
export interface MaintainCommandResult {
  readonly succeeded: boolean;
  readonly exitCode: number;
  /// Combined stdout+stderr, tail-bounded — verification wants the error, not
  /// a gigabyte of build progress.
  readonly outputTail: string;
}

/// Where a command runs, and how long it may take, relative to the runner's
/// own repo root.
export interface MaintainRunOptions {
  /// A path relative to `repoRootPath` (Tauri keeps its JS in `ui/`, its Rust
  /// at the root). Absent runs at the repo root.
  readonly inSubdirectory?: string;
  readonly deadlineMs?: number;
}

/// One runner per repo. Everything it touches lives under `repoRootPath` — the
/// real implementation refuses to run outside it, the last line of "writes
/// stay inside the app's repo" enforced where the process actually spawns.
export interface MaintainShellRunner {
  readonly repoRootPath: string;
  run(command: string, opts?: MaintainRunOptions): Promise<MaintainCommandResult>;
}

/// A scripted runner for the suite: returns queued outcomes in order and
/// records every command it was asked to run — the maintain-layer twin of
/// `autopilot/shell.ts`'s `MockShell`.
export class MockMaintainShellRunner implements MaintainShellRunner {
  readonly commandsRun: string[] = [];
  private next = 0;

  constructor(
    private readonly outcomes: readonly MaintainCommandResult[] = [],
    readonly repoRootPath: string = "/repo",
  ) {}

  /// A runner where every command succeeds with empty output.
  static alwaysSucceeds(repoRootPath = "/repo"): MockMaintainShellRunner {
    return new MockMaintainShellRunner([], repoRootPath);
  }

  async run(command: string, _opts?: MaintainRunOptions): Promise<MaintainCommandResult> {
    this.commandsRun.push(command);
    const outcome = this.outcomes[this.next] ?? { succeeded: true, exitCode: 0, outputTail: "" };
    this.next += 1;
    return outcome;
  }
}

/// Runs a command and swallows a thrown error into `undefined`, mirroring
/// Swift's ubiquitous `try? await runner.run(...)`. Every caller here treats a
/// runner failure the same way Swift's callers do — as "could not learn
/// anything from this step", not as a crash.
export async function tryRun(
  runner: MaintainShellRunner,
  command: string,
  opts?: MaintainRunOptions,
): Promise<MaintainCommandResult | undefined> {
  try {
    return await runner.run(command, opts);
  } catch {
    return undefined;
  }
}
