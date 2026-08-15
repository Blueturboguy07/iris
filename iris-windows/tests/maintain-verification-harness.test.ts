import { exec, execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { describe, expect, it } from "vitest";

import {
  MockMaintainShellRunner,
  type MaintainCommandResult,
  type MaintainRunOptions,
  type MaintainShellRunner,
} from "../src/services/maintain/maintain-shell-runner";
import {
  MAXIMUM_FILES_TOUCHED,
  earnsCleanApply,
  earnsVerifiedFix,
  verifyAppliedPatch,
  type VerificationOutcome,
} from "../src/services/maintain/verification-harness";

/**
 * Two tiers of coverage, matching how the porting spec asks for this file to
 * be validated:
 *
 *  - Against a REAL git repository in a temp directory. `git` is a
 *    cross-platform CLI (unlike PowerShell/Win32 primitives), so this runs
 *    identically on the Mac dev machine and on windows-latest CI, and it is
 *    what actually proves the diff-scope gate and the stash choreography work
 *    against real `git diff --numstat` / `git stash` output, not a guess at
 *    its shape.
 *  - Against `MockMaintainShellRunner`, for the blocked-stage branches a real
 *    repo cannot deterministically provoke (a git-stash failure, a
 *    self-verifying repro that also "passes" on revert), and for a byte-exact
 *    assertion on the command ceremony `verifyAppliedPatch` issues — the
 *    literal strings are code-authored constants, so their order and spelling
 *    is part of the contract, not an implementation detail.
 */

// MARK: - A real, non-PowerShell shell runner, built only for this test file.
// `services/maintain/` stays free of `child_process` (see
// `maintain-shell-runner.ts`'s header); this class is what a *test* is allowed
// to do that a pure module is not.

class RealGitMaintainShellRunner implements MaintainShellRunner {
  constructor(readonly repoRootPath: string) {}

  run(command: string, opts?: MaintainRunOptions): Promise<MaintainCommandResult> {
    const cwd = opts?.inSubdirectory ? path.join(this.repoRootPath, opts.inSubdirectory) : this.repoRootPath;
    const timeout = opts?.deadlineMs ?? 60_000;
    return new Promise((resolve) => {
      exec(command, { cwd, timeout, maxBuffer: 10 * 1024 * 1024 }, (error, stdout, stderr) => {
        const outputTail = `${stdout}${stderr}`.slice(-16_384);
        if (error === null) {
          resolve({ succeeded: true, exitCode: 0, outputTail });
          return;
        }
        const exitCode = typeof error.code === "number" ? error.code : 1;
        resolve({ succeeded: false, exitCode, outputTail });
      });
    });
  }
}

function makeTempGitRepo(files: Record<string, string>): string {
  const repoRootPath = fs.mkdtempSync(path.join(os.tmpdir(), "iris-maintain-vh-"));
  execSync("git init -q", { cwd: repoRootPath });
  execSync('git config user.email "iris-test@publikhq.com"', { cwd: repoRootPath });
  execSync('git config user.name "Iris Test"', { cwd: repoRootPath });
  for (const [relativePath, contents] of Object.entries(files)) {
    fs.writeFileSync(path.join(repoRootPath, relativePath), contents, "utf-8");
  }
  execSync("git add -A", { cwd: repoRootPath });
  execSync('git commit -q -m "initial"', { cwd: repoRootPath });
  return repoRootPath;
}

// A repro command that is honest: it fails until `feature.txt` contains
// "FIXED", so leg 1 (pre-patch) fails, leg 2 (post-patch) passes, and leg 3
// (reverted again) fails — exactly the shape `earnsVerifiedFix` requires.
const HONEST_REPRO_SCRIPT = [
  'const fs = require("fs");',
  'process.exit(fs.readFileSync("feature.txt", "utf8").includes("FIXED") ? 0 : 1);',
].join("\n");

describe("verifyAppliedPatch against a real git repository", () => {
  it(
    "earns a verified fix when the repro fails pre-patch, passes post-patch, and fails again on revert",
    async () => {
      const repoRootPath = makeTempGitRepo({
        "feature.txt": "before\n",
        "check.js": HONEST_REPRO_SCRIPT,
        "build.js": "process.exit(0);",
        "test.js": "process.exit(0);",
      });
      // The patch, already applied to the working tree — uncommitted, exactly
      // how `verifyAppliedPatch` expects to find it.
      fs.writeFileSync(path.join(repoRootPath, "feature.txt"), "before\nFIXED\n", "utf-8");

      const runner = new RealGitMaintainShellRunner(repoRootPath);
      const outcome = await verifyAppliedPatch(
        runner,
        { buildCommand: "node build.js", testCommand: "node test.js" },
        "node check.js",
      );

      expect(outcome.blockedStage).toBeUndefined();
      expect(earnsVerifiedFix(outcome)).toBe(true);
      expect(earnsCleanApply(outcome)).toBe(true);

      // The tree is left in the applied state — the caller owns committing.
      const finalContent = fs.readFileSync(path.join(repoRootPath, "feature.txt"), "utf-8");
      expect(finalContent).toBe("before\nFIXED\n");
      const status = execSync("git status --porcelain", { cwd: repoRootPath, encoding: "utf-8" });
      expect(status).toContain("feature.txt");
    },
    30_000,
  );

  it(
    "earns only a clean apply in replay mode, with no repro command",
    async () => {
      const repoRootPath = makeTempGitRepo({
        "feature.txt": "before\n",
        "build.js": "process.exit(0);",
        "test.js": "process.exit(0);",
      });
      fs.writeFileSync(path.join(repoRootPath, "feature.txt"), "before\nFIXED\n", "utf-8");

      const runner = new RealGitMaintainShellRunner(repoRootPath);
      const outcome = await verifyAppliedPatch(
        runner,
        { buildCommand: "node build.js", testCommand: "node test.js" },
        undefined,
      );

      expect(outcome.reproFailedBeforePatch).toBeUndefined();
      expect(earnsCleanApply(outcome)).toBe(true);
      // No repro test ran, so the full three-legged standard is never earned —
      // that distinction is the entire point of the two outcome vocabularies.
      expect(earnsVerifiedFix(outcome)).toBe(false);
    },
    30_000,
  );

  it(
    "blocks on the diff-scope gate before any build or test runs, over the file-count limit",
    async () => {
      const repoRootPath = makeTempGitRepo({ "README.md": "placeholder\n" });
      for (let index = 0; index < MAXIMUM_FILES_TOUCHED + 1; index += 1) {
        fs.writeFileSync(path.join(repoRootPath, `new-file-${index}.txt`), "junk\n", "utf-8");
      }

      const runner = new RealGitMaintainShellRunner(repoRootPath);
      const outcome = await verifyAppliedPatch(runner, {}, undefined);

      expect(outcome.blockedStage).toBe("diff-scope");
      expect(outcome.blockedOutputTail).toContain(`over the ${MAXIMUM_FILES_TOUCHED}-file limit`);
      expect(earnsCleanApply(outcome)).toBe(false);
      expect(earnsVerifiedFix(outcome)).toBe(false);
    },
    30_000,
  );

  it(
    "blocks a fix that removes more test lines than it adds",
    async () => {
      const repoRootPath = makeTempGitRepo({
        "math.test.js": "line-a\nline-b\nline-c\nline-d\nline-e\n",
      });
      // Deletes three lines (b, c, d), adds none — a classic "delete the
      // failing test to go green".
      fs.writeFileSync(path.join(repoRootPath, "math.test.js"), "line-a\nline-e\n", "utf-8");

      const runner = new RealGitMaintainShellRunner(repoRootPath);
      const outcome = await verifyAppliedPatch(runner, {}, undefined);

      expect(outcome.blockedStage).toBe("diff-scope");
      expect(outcome.blockedOutputTail).toContain("weakens tests in math.test.js");
    },
    30_000,
  );
});

describe("verifyAppliedPatch against a scripted runner", () => {
  const REPRO_COMMAND = "npm run repro";
  const NO_CHANGES: MaintainCommandResult = { succeeded: true, exitCode: 0, outputTail: "" };
  const succeeded = (outputTail = ""): MaintainCommandResult => ({ succeeded: true, exitCode: 0, outputTail });
  const failed = (outputTail = ""): MaintainCommandResult => ({ succeeded: false, exitCode: 1, outputTail });

  it("issues the exact git ceremony in order for a full verified-fix run", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES, // git diff --numstat HEAD
      NO_CHANGES, // git ls-files --others --exclude-standard
      succeeded(), // git stash push (leg 1)
      failed(), // repro, pre-patch — must fail
      succeeded(), // git stash pop (leg 1)
      succeeded(), // repro, post-patch — must pass
      succeeded(), // git stash push (leg 3)
      failed(), // repro, on revert — must fail again
      succeeded(), // git stash pop (leg 3)
      succeeded(), // build
      succeeded(), // suite
    ]);

    const outcome = await verifyAppliedPatch(
      runner,
      { buildCommand: "npm run build", testCommand: "npm test" },
      REPRO_COMMAND,
    );

    expect(earnsVerifiedFix(outcome)).toBe(true);
    expect(runner.commandsRun).toEqual([
      "git diff --numstat HEAD",
      "git ls-files --others --exclude-standard",
      "git stash push --include-untracked --quiet",
      REPRO_COMMAND,
      "git stash pop --quiet",
      REPRO_COMMAND,
      "git stash push --include-untracked --quiet",
      REPRO_COMMAND,
      "git stash pop --quiet",
      "npm run build",
      "npm test",
    ]);
  });

  it("blocks when the diff itself cannot be read, failing closed", async () => {
    const runner = new MockMaintainShellRunner([failed("permission denied")]);
    const outcome = await verifyAppliedPatch(runner, {}, undefined);
    expect(outcome.blockedStage).toBe("diff-scope");
    expect(outcome.blockedOutputTail).toBe("could not read the diff to check its scope");
    // Failing closed means it never even asks about untracked files.
    expect(runner.commandsRun).toEqual(["git diff --numstat HEAD"]);
  });

  it("blocks at git-stash when the pre-patch stash cannot be taken", async () => {
    const runner = new MockMaintainShellRunner([NO_CHANGES, NO_CHANGES, failed()]);
    const outcome = await verifyAppliedPatch(runner, {}, REPRO_COMMAND);
    expect(outcome.blockedStage).toBe("git-stash");
  });

  it("blocks at leg1 when the repro also passes before the patch (a tautological test)", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES,
      NO_CHANGES,
      succeeded(), // stash
      succeeded("passed even without the fix"), // repro pre-patch — should have failed
      succeeded(), // stash pop
    ]);
    const outcome = await verifyAppliedPatch(runner, {}, REPRO_COMMAND);
    expect(outcome.reproFailedBeforePatch).toBe(false);
    expect(outcome.blockedStage).toBe("leg1-repro-passed-prepatch");
    expect(outcome.blockedOutputTail).toBe("passed even without the fix");
  });

  it("blocks at leg2 when the repro still fails after the patch is applied", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES,
      NO_CHANGES,
      succeeded(),
      failed(), // repro pre-patch — correctly fails
      succeeded(),
      failed("still red"), // repro post-patch — should have passed
    ]);
    const outcome = await verifyAppliedPatch(runner, {}, REPRO_COMMAND);
    expect(outcome.reproFailedBeforePatch).toBe(true);
    expect(outcome.reproPassedAfterPatch).toBe(false);
    expect(outcome.blockedStage).toBe("leg2-repro-failed-postpatch");
    expect(outcome.blockedOutputTail).toBe("still red");
  });

  it("blocks at leg3 when the repro still passes after the fix is reverted", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES,
      NO_CHANGES,
      succeeded(),
      failed(),
      succeeded(),
      succeeded(), // repro post-patch — correctly passes
      succeeded(), // stash (leg 3)
      succeeded("still green without the fix"), // repro on revert — should have failed
      succeeded(), // stash pop (leg 3)
    ]);
    const outcome = await verifyAppliedPatch(runner, {}, REPRO_COMMAND);
    expect(outcome.reproFailedOnRevert).toBe(false);
    expect(outcome.blockedStage).toBe("leg3-repro-passed-on-revert");
  });

  it("blocks at build when the build command fails", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES,
      NO_CHANGES,
      succeeded(),
      failed(),
      succeeded(),
      succeeded(),
      succeeded(),
      failed(),
      succeeded(),
      failed("compile error"), // build
    ]);
    const outcome = await verifyAppliedPatch(runner, { buildCommand: "npm run build" }, REPRO_COMMAND);
    expect(outcome.blockedStage).toBe("build");
    expect(outcome.blockedOutputTail).toBe("compile error");
  });

  it("blocks at suite when the full test suite fails", async () => {
    const runner = new MockMaintainShellRunner([
      NO_CHANGES,
      NO_CHANGES,
      succeeded(),
      failed(),
      succeeded(),
      succeeded(),
      succeeded(),
      failed(),
      succeeded(),
      succeeded(), // build
      failed("a different test broke"), // suite
    ]);
    const outcome = await verifyAppliedPatch(
      runner,
      { buildCommand: "npm run build", testCommand: "npm test" },
      REPRO_COMMAND,
    );
    expect(outcome.blockedStage).toBe("suite");
    expect(outcome.blockedOutputTail).toBe("a different test broke");
  });

  it("treats an absent build/test vocabulary as skipped, not green, and never runs either command", async () => {
    const runner = new MockMaintainShellRunner([NO_CHANGES, NO_CHANGES]);
    const outcome = await verifyAppliedPatch(runner, {}, undefined);
    expect(outcome.buildSucceeded).toBe(true);
    expect(outcome.suitePassed).toBeUndefined();
    expect(outcome.blockedStage).toBeUndefined();
    expect(earnsCleanApply(outcome)).toBe(true);
    expect(runner.commandsRun).toEqual(["git diff --numstat HEAD", "git ls-files --others --exclude-standard"]);
  });
});

describe("earnsVerifiedFix / earnsCleanApply", () => {
  const fullyVerified: VerificationOutcome = {
    reproFailedBeforePatch: true,
    reproPassedAfterPatch: true,
    reproFailedOnRevert: true,
    buildSucceeded: true,
    suitePassed: true,
  };

  it("requires every leg plus a green build for a verified fix", () => {
    expect(earnsVerifiedFix(fullyVerified)).toBe(true);
    expect(earnsVerifiedFix({ ...fullyVerified, reproFailedOnRevert: false })).toBe(false);
    expect(earnsVerifiedFix({ ...fullyVerified, buildSucceeded: false })).toBe(false);
    expect(earnsVerifiedFix({ ...fullyVerified, suitePassed: false })).toBe(false);
  });

  it("treats an absent (skipped) suite as fine for a verified fix, but not a false one", () => {
    const { suitePassed: _suitePassed, ...withoutSuiteResult } = fullyVerified;
    expect(earnsVerifiedFix(withoutSuiteResult)).toBe(true);
  });

  it("earns a clean apply on build+suite alone, with no repro legs at all", () => {
    expect(earnsCleanApply({ buildSucceeded: true })).toBe(true);
    expect(earnsCleanApply({ buildSucceeded: true, suitePassed: true })).toBe(true);
    expect(earnsCleanApply({ buildSucceeded: false })).toBe(false);
    expect(earnsCleanApply({ buildSucceeded: true, suitePassed: false })).toBe(false);
  });

  it("refuses a clean apply once anything blocked, even if build and suite both look green", () => {
    expect(earnsCleanApply({ buildSucceeded: true, suitePassed: true, blockedStage: "diff-scope" })).toBe(false);
  });
});
