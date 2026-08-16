// Test-only `MaintainShellRunner` that actually spawns processes, instead of
// scripting outcomes the way `MockMaintainShellRunner` does. `verification-
// harness.ts`'s diff-scope gate and three-legged repro/build/suite cycle, and
// `patch-queue.ts`'s `git apply --reverse --check` / `--3way` replay logic,
// are git-behavior-dependent in ways a scripted mock can't honestly stand in
// for — a mock can assert "the code called git stash", not "the code's git
// stash actually restored the pre-patch file". A real git repository is
// available on the Mac dev machine AND on `windows-latest` CI (per
// `iris-windows/CLAUDE.md`, git ships on both runners), so this is the one
// place in `services/maintain/`'s test suite that shells out for real rather
// than injecting a fake — see the maintain-mode porting spec's task note:
// "a git repo works on Mac too so this is vitest-testable HERE".
//
// Deliberately platform-neutral: `child_process.exec` is called with NO
// `shell` override, so it runs under the OS's own default shell (`/bin/sh` on
// macOS/Linux, `cmd.exe` on Windows) rather than assuming bash exists. Every
// command this fixture is asked to run — `git` subcommands and `node
// <script>.js` — is written to work unmodified under both, so no test using
// this fixture needs an `if (process.platform === "win32")` branch of its
// own. Repro/build/test "commands" used against it are always a `node
// <file>.js` invocation against a fixture script written to disk, never an
// inline `node -e "..."` one-liner — inline shell quoting is exactly the kind
// of thing that is NOT portable between `cmd.exe` and a POSIX shell.
//
// Not a recovered `dist/` file — the porting spec's §0 recovery only covers
// `src/services/maintain/*.ts` and `src/main/maintain/*.ts`; every test file,
// this fixture included, is new work for this round.

import { exec } from "node:child_process";
import { promisify } from "node:util";
import * as path from "node:path";
import type { MaintainCommandResult, MaintainRunOptions, MaintainShellRunner } from "../../src/services/maintain/maintain-shell-runner";

const execAsync = promisify(exec);

/// The shape Node actually attaches to a rejected `exec` error: `stdout`/
/// `stderr` (captured even on failure) plus a numeric `code` when the child
/// exited non-zero rather than being killed by a signal.
interface ExecFailure {
  readonly stdout?: string;
  readonly stderr?: string;
  readonly code?: number;
}

function isExecFailure(value: unknown): value is ExecFailure {
  return typeof value === "object" && value !== null;
}

/// A `MaintainShellRunner` backed by real child processes, rooted at
/// `repoRootPath`. Every call is a fresh spawn — there is no persistent shell
/// state to leak between commands, matching the real
/// `WindowsMaintainShellRunner`'s one-shot-per-call contract.
export class RealGitShellRunner implements MaintainShellRunner {
  constructor(public readonly repoRootPath: string) {}

  async run(command: string, opts?: MaintainRunOptions): Promise<MaintainCommandResult> {
    const cwd = opts?.inSubdirectory !== undefined ? path.join(this.repoRootPath, opts.inSubdirectory) : this.repoRootPath;
    try {
      const { stdout, stderr } = await execAsync(command, { cwd });
      // Deliberately NOT trimmed — matches the real `WindowsMaintainShellRunner`
      // (`outputTail: parsed.output.slice(-MAX_OUTPUT_TAIL)`, no `.trim()`), and
      // callers that hand this text to `git apply` as patch content (this
      // fixture's own tests among them) depend on a trailing newline surviving
      // intact. Trimming here once silently corrupted a `git diff` capture into
      // an unparsable patch — the failure mode was `git apply`'s own "corrupt
      // patch" error, not a passthrough test bug, so it is worth this note.
      return { succeeded: true, exitCode: 0, outputTail: `${stdout}${stderr}` };
    } catch (error) {
      const failure = isExecFailure(error) ? error : {};
      const stdout = failure.stdout ?? "";
      const stderr = failure.stderr ?? "";
      return {
        succeeded: false,
        exitCode: typeof failure.code === "number" ? failure.code : 1,
        outputTail: `${stdout}${stderr}`,
      };
    }
  }
}

/// Initializes a throwaway git repository at `repoRootPath` (already an empty
/// directory the caller created, typically `fs.mkdtempSync`) with a local
/// identity — CI runners carry no global `user.name`/`user.email`, and a
/// commit fails without one.
export async function initRealGitRepo(repoRootPath: string): Promise<RealGitShellRunner> {
  const runner = new RealGitShellRunner(repoRootPath);
  await runner.run("git init --quiet");
  await runner.run('git config user.email "iris-maintain-tests@publikhq.com"');
  await runner.run('git config user.name "Iris Maintain Tests"');
  // Fixture files are written by Node with explicit "\n" endings and must
  // round-trip identically through `git stash`/`git apply --3way` on both a
  // POSIX runner and `windows-latest` CI — without this, git's default
  // Windows behavior (translate LF to CRLF on checkout) would make a patch
  // captured on one platform fail to apply cleanly on the other.
  await runner.run("git config core.autocrlf false");
  // A clean initial commit so `git diff --numstat HEAD` and `git stash` both
  // have a HEAD to compare against / stash relative to.
  await runner.run("git commit --quiet --allow-empty -m initial");
  return runner;
}
