//
// The gate between "a patch applied" and "a fix is real". Iris is both
// prosecutor and defendant here — it authors the test AND the fix — and the
// agentic-coding literature is unambiguous about how that ends without hard
// checks: patches that pass their own test while breaking six others, tests
// quietly rewritten to match the patch, "fixes" that are the answer key
// retrieved rather than derived.
//
// So the harness runs legs, and every leg is a hard block:
//
//   leg 1   the repro fails BEFORE the patch        (proves the test sees the bug)
//   leg 2   the repro passes AFTER the patch         (proves the patch does something)
//   leg 3   revert the patch, repro fails again      (proves the test wasn't tautological)
//           — then re-apply. One extra build; the only defense there is
//           against a self-verifying agent when nobody else wrote an oracle.
//   build   the app still builds at all
//   suite   the app's own full test suite stays green (PASS_TO_PASS)
//
// A replayed recipe arrives with no repro test — its evidence came from other
// machines — so legs 1-3 are skipped and it earns only `applied` + build +
// suite, never a `verified` outcome without the full gate. `earnsVerifiedFix`
// and `earnsCleanApply` keep those two standards separate on purpose.
//
// Ported verbatim from `VerificationHarness.swift`, including the diff-scope
// gate running FIRST, before a single build or test — a fix that passes the
// suite can still be wrong in ways the suite cannot see: it deletes the
// failing test to go green, or it sprawls across the codebase. The suite is
// necessary, not sufficient; the diff-scope gate is the other half, and a
// block there is as hard as a failed leg.
//

import { maintainTrace } from "./trace";
import { tryRun, type MaintainShellRunner } from "./maintain-shell-runner";

/// What one verification run proved. Serialized into the recipe pointer's
/// `verification` jsonb and into the commit trailer block. `buildSucceeded`
/// is the one field with a real default (`false`) rather than "unknown" —
/// every other leg starts genuinely undetermined until its stage runs.
export interface VerificationOutcome {
  reproFailedBeforePatch?: boolean;
  reproPassedAfterPatch?: boolean;
  reproFailedOnRevert?: boolean;
  buildSucceeded: boolean;
  suitePassed?: boolean;
  /// The failing stage's output tail when the gate blocked, for the
  /// diagnosis record — never shown raw to the user.
  blockedStage?: string;
  blockedOutputTail?: string;
}

/// The per-stack command vocabulary. Code-authored, never model-authored —
/// which is why these strings never pass through the risk gate. The table
/// that builds one of these per app stack (Swift's `VerificationCommands
/// .defaults(for:repoRootPath:)`) lives in `incoming-fix-reviewer.ts` as
/// `defaultVerificationCommandsForStack`, not here — this file only consumes
/// the shape, so a fix ladder step that doesn't need the defaults table
/// doesn't have to import it.
export interface VerificationCommands {
  readonly buildCommand?: string;
  readonly testCommand?: string;
  /// Where inside the repo the build/test commands run (Tauri keeps its JS
  /// in `ui/`, its Rust at the root).
  readonly commandSubdirectory?: string;
}

/// The most files a single fix may touch before it stops looking like a fix
/// and starts looking like a refactor (or a mistake). Google's small-CL
/// guidance is the reference; a maintain-mode fix should be far under it.
export const MAXIMUM_FILES_TOUCHED = 12;

/// The full three-legged standard: every leg present and correct.
export function earnsVerifiedFix(outcome: VerificationOutcome): boolean {
  return (
    outcome.reproFailedBeforePatch === true &&
    outcome.reproPassedAfterPatch === true &&
    outcome.reproFailedOnRevert === true &&
    outcome.buildSucceeded &&
    outcome.suitePassed !== false
  );
}

/// The replay standard: applied cleanly, builds, suite green — honest but
/// weaker, and counted separately by the pool.
export function earnsCleanApply(outcome: VerificationOutcome): boolean {
  return outcome.buildSucceeded && outcome.suitePassed !== false && outcome.blockedStage === undefined;
}

/// Verify a patch that is ALREADY APPLIED to the working tree, with git as the
/// revert mechanism for leg 3. `reproCommand` undefined = replay mode (legs
/// skipped, weaker outcome by design).
///
/// The tree is left in the applied state on success, and restored to the
/// applied state after leg 3's revert — the caller owns committing.
export async function verifyAppliedPatch(
  runner: MaintainShellRunner,
  commands: VerificationCommands,
  reproCommand: string | undefined,
): Promise<VerificationOutcome> {
  let outcome: VerificationOutcome = { buildSucceeded: false };

  // Diff-scope gate, FIRST — before a single build or test runs.
  const scope = await enforceDiffScope(runner);
  if (!scope.ok) {
    return blocked(outcome, "diff-scope", scope.reason ?? "diff-scope violation");
  }

  // Legs 1-3 only exist when a repro command does.
  if (reproCommand !== undefined) {
    // Leg 1 needs the PRE-patch tree: stash the patch, run, restore.
    if (!(await gitStash(runner))) {
      return blocked(outcome, "git-stash", "could not stash the applied patch for leg 1");
    }
    const preResult = await tryRun(runner, reproCommand, {
      inSubdirectory: commands.commandSubdirectory,
      deadlineMs: 300_000,
    });
    outcome = {
      ...outcome,
      reproFailedBeforePatch: preResult !== undefined ? !preResult.succeeded : false,
    };
    if (!(await gitStashPop(runner))) {
      return blocked(outcome, "git-stash-pop", "could not restore the patch after leg 1");
    }
    if (outcome.reproFailedBeforePatch !== true) {
      return blocked(outcome, "leg1-repro-passed-prepatch", preResult?.outputTail ?? "");
    }

    // Leg 2: the applied tree.
    const postResult = await tryRun(runner, reproCommand, {
      inSubdirectory: commands.commandSubdirectory,
      deadlineMs: 300_000,
    });
    outcome = { ...outcome, reproPassedAfterPatch: postResult?.succeeded ?? false };
    if (outcome.reproPassedAfterPatch !== true) {
      return blocked(outcome, "leg2-repro-failed-postpatch", postResult?.outputTail ?? "");
    }

    // Leg 3: revert, expect red, re-apply. The cheapest available defense
    // against a tautological or over-mocked test.
    if (!(await gitStash(runner))) {
      return blocked(outcome, "git-stash-leg3", "could not revert for leg 3");
    }
    const revertResult = await tryRun(runner, reproCommand, {
      inSubdirectory: commands.commandSubdirectory,
      deadlineMs: 300_000,
    });
    outcome = {
      ...outcome,
      reproFailedOnRevert: revertResult !== undefined ? !revertResult.succeeded : false,
    };
    if (!(await gitStashPop(runner))) {
      return blocked(outcome, "git-stash-pop-leg3", "could not re-apply after leg 3");
    }
    if (outcome.reproFailedOnRevert !== true) {
      return blocked(outcome, "leg3-repro-passed-on-revert", revertResult?.outputTail ?? "");
    }
  }

  // Build — always, when the stack has one.
  if (commands.buildCommand !== undefined) {
    const buildResult = await tryRun(runner, commands.buildCommand, {
      inSubdirectory: commands.commandSubdirectory,
    });
    outcome = { ...outcome, buildSucceeded: buildResult?.succeeded ?? false };
    if (!outcome.buildSucceeded) {
      return blocked(outcome, "build", buildResult?.outputTail ?? "");
    }
  } else {
    // No build vocabulary for this stack: the stage is absent, not green.
    // `earnsCleanApply` still requires `blockedStage === undefined`.
    outcome = { ...outcome, buildSucceeded: true };
  }

  // Full suite — PASS_TO_PASS, the touched files are never enough.
  if (commands.testCommand !== undefined) {
    const suiteResult = await tryRun(runner, commands.testCommand, {
      inSubdirectory: commands.commandSubdirectory,
    });
    outcome = { ...outcome, suitePassed: suiteResult?.succeeded ?? false };
    if (outcome.suitePassed !== true) {
      return blocked(outcome, "suite", suiteResult?.outputTail ?? "");
    }
  }

  return outcome;
}

/// What `enforceDiffScope` decided. Not exported — a diff-scope violation
/// only ever surfaces through `verifyAppliedPatch`'s `blockedStage`/
/// `blockedOutputTail`, never as its own return type.
interface DiffScopeCheck {
  readonly ok: boolean;
  readonly reason?: string;
}

/// Reads the applied (uncommitted) diff and blocks a fix that touches too many
/// files or weakens tests. Uses `git diff --numstat HEAD`, so it sees exactly
/// what the patch changed against the last commit.
async function enforceDiffScope(runner: MaintainShellRunner): Promise<DiffScopeCheck> {
  const diffResult = await tryRun(runner, "git diff --numstat HEAD", { deadlineMs: 60_000 });
  if (diffResult === undefined || !diffResult.succeeded) {
    // Can't read the diff -> can't vouch for its scope -> fail closed.
    return { ok: false, reason: "could not read the diff to check its scope" };
  }
  const numstatLines = diffResult.outputTail.split("\n").filter((line) => line.trim().length > 0);

  // `git diff` only sees TRACKED changes — a fix that ADDS new files (whole
  // new modules, or a pile of junk) is invisible to it. Count untracked files
  // too, or the file-count limit is trivially evaded.
  const untrackedResult = await tryRun(runner, "git ls-files --others --exclude-standard", {
    deadlineMs: 60_000,
  });
  const untrackedFiles = (untrackedResult?.outputTail ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  const totalFiles = numstatLines.length + untrackedFiles.length;
  if (totalFiles === 0) {
    return { ok: true }; // nothing changed
  }

  if (totalFiles > MAXIMUM_FILES_TOUCHED) {
    return {
      ok: false,
      reason:
        `touches ${totalFiles} files (${numstatLines.length} changed, ${untrackedFiles.length} new), ` +
        `over the ${MAXIMUM_FILES_TOUCHED}-file limit for one fix`,
    };
  }

  for (const line of numstatLines) {
    const fields = splitNumstatLine(line);
    if (fields === undefined) continue;
    const [addedField, deletedField, path] = fields;
    const added = Number.parseInt(addedField, 10) || 0;
    const deleted = Number.parseInt(deletedField, 10) || 0;
    const lowercasedPath = path.toLowerCase();
    const looksLikeATest =
      lowercasedPath.includes("test") || lowercasedPath.includes("spec") || lowercasedPath.includes("__tests__");
    // A fix that removes more test lines than it adds is weakening the very
    // thing that would catch a regression — the classic "delete the failing
    // test to go green". Blocked outright.
    if (looksLikeATest && deleted > added) {
      return { ok: false, reason: `weakens tests in ${path} (-${deleted}/+${added})` };
    }
  }
  return { ok: true };
}

/// Splits one `git diff --numstat` line ("<added>\t<deleted>\t<path>") into its
/// three fields, keeping any further tabs inside the path intact — mirrors
/// Swift's `split(separator: "\t", maxSplits: 2)`. A binary file reports "-"
/// for both counts; `enforceDiffScope` parses that as 0 via `Number.parseInt`.
function splitNumstatLine(line: string): readonly [string, string, string] | undefined {
  const firstTab = line.indexOf("\t");
  if (firstTab === -1) return undefined;
  const secondTab = line.indexOf("\t", firstTab + 1);
  if (secondTab === -1) return undefined;
  return [line.slice(0, firstTab), line.slice(firstTab + 1, secondTab), line.slice(secondTab + 1)];
}

function blocked(outcome: VerificationOutcome, stage: string, tail: string): VerificationOutcome {
  maintainTrace(`verification BLOCKED at ${stage}`);
  return {
    ...outcome,
    blockedStage: stage,
    blockedOutputTail: tail.slice(-2000),
  };
}

// Stash both directions through the runner so the boundary (never write
// outside the repo root) applies to the harness's own git use too.
async function gitStash(runner: MaintainShellRunner): Promise<boolean> {
  const result = await tryRun(runner, "git stash push --include-untracked --quiet", { deadlineMs: 60_000 });
  return result?.succeeded ?? false;
}

async function gitStashPop(runner: MaintainShellRunner): Promise<boolean> {
  const result = await tryRun(runner, "git stash pop --quiet", { deadlineMs: 60_000 });
  return result?.succeeded ?? false;
}
