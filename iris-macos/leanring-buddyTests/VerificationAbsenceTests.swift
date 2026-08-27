//
//  VerificationAbsenceTests.swift
//  leanring-buddyTests
//
//  The three places where "this stage did not happen" and "this stage happened
//  and passed" used to be the SAME value, so nothing downstream could tell
//  them apart and every missing signal read as a green one.
//
//    1. A build stage with no build command set `buildSucceeded = true`.
//    2. A zero-file diff answered the scope gate with "ok".
//    3. A commit script whose result was discarded returned a branch name.
//
//  Each test below fails against the code as it was and passes against the
//  code as it is. The first is pure; the second and third spawn real `git`
//  against throwaway repos, so they are serialized alongside the other
//  process-spawning suites.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized) struct VerificationAbsenceTests {

    // MARK: - 1. A stage that did not run is not a stage that passed

    /// The stack has no build command and no test command — `.swiftMacOS` and
    /// `.other` both resolve to exactly that — so neither stage runs. The
    /// outcome must SAY neither ran, and the evidence ladder must therefore
    /// earn nothing.
    ///
    /// NOT a regression test, despite its neighbours: there is no pre-fix state
    /// it could fail against, because the enum it asserts on did not exist
    /// before the change that added it. It pins the new API's meaning — that
    /// `.notRun` is the default and is distinguishable from `.passed`, and that
    /// the compatibility accessors keep their old values — so a later edit
    /// cannot quietly make "absent" read as "passed" again. Useful, but it is
    /// evidence about the type, not evidence that a defect was fixed.
    @Test("the not-run default is distinguishable from a stage that ran and passed")
    func absentStagesAreReportedAsNotRun() {
        var outcome = VerificationOutcome()
        #expect(outcome.build == .notRun)
        #expect(outcome.suite == .notRun)
        #expect(outcome.atLeastOneVerificationStageActuallyRan == false)

        // And the compatibility accessors keep their old meanings exactly, so
        // the serialized shape and the existing readers are untouched.
        #expect(outcome.suitePassed == nil)

        // A stage that ran and passed is distinguishable from one that did not
        // run — which is the whole point.
        outcome.build = .passed
        #expect(outcome.build == .passed)
        #expect(outcome.atLeastOneVerificationStageActuallyRan)
        #expect(outcome.buildSucceeded)

        outcome.build = .failed
        #expect(!outcome.buildSucceeded)
        #expect(!outcome.earnsCleanApply)
    }

    // MARK: - 2. An empty diff is nothing to verify, not a clean scope

    /// A tree with no changes in it must BLOCK at the scope gate. Before the
    /// fix `enforceDiffScope` returned "ok, nothing changed" for an empty diff,
    /// so verification ran a build and a suite against unmodified code and
    /// reported them green — evidence about the original repo, presented as
    /// evidence about a change.
    @Test("verifying an unchanged tree blocks at the diff-scope gate")
    func anEmptyDiffIsNotACleanScope() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)

        // `true` for both legs: if the gate lets this through, everything after
        // it passes, which is exactly how an empty diff used to earn a clean
        // apply.
        let outcome = await VerificationHarness.verifyAppliedPatch(
            runner: runner,
            commands: VerificationCommands(
                buildCommand: "true", testCommand: "true", commandSubdirectory: nil
            ),
            reproCommand: nil
        )

        #expect(outcome.blockedStage == "diff-scope")
        #expect(!outcome.earnsCleanApply)
    }

    /// The caller that legitimately has NO uncommitted diff, and must not be
    /// refused for it.
    ///
    /// `IncomingFixReviewer` verifies somebody else's fix inside
    /// `git worktree add --detach FETCH_HEAD`, where the change is COMMITTED —
    /// so `git diff HEAD` is empty by construction and always will be. The
    /// empty-diff refusal above, added to stop a Tier C run vouching for an
    /// unchanged tree, blocked every incoming PR before a single build ran: a
    /// whole feature broken by a check meant to protect a different one. It
    /// went unnoticed because `IncomingFixReviewer` had no tests at all, which
    /// is why this one exists.
    ///
    /// The scope LIMITS still apply on this path — only the absence stops being
    /// an error, and only for a caller that says it never expected a diff.
    @Test("a caller that expects no uncommitted diff is not blocked for having none")
    func aCommittedChangeUnderReviewIsNotBlockedForHavingNoWorkingTreeDiff() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)

        let outcome = await VerificationHarness.verifyAppliedPatch(
            runner: runner,
            commands: VerificationCommands(
                buildCommand: "true", testCommand: "true", commandSubdirectory: nil
            ),
            reproCommand: nil,
            expectsAnUncommittedDiff: false
        )

        #expect(outcome.blockedStage != "diff-scope")
        // And it got past the gate far enough to actually run the stages, which
        // is the whole point of reviewing an incoming fix.
        #expect(outcome.atLeastOneVerificationStageActuallyRan)
    }

    /// The other half of the same gate: a tree that DOES carry a change still
    /// passes it, so the new refusal is about absence and not about scope in
    /// general.
    @Test("verifying a tree with a real change still passes the scope gate")
    func arealChangeStillPassesTheScopeGate() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        try "changed\n".write(
            toFile: repositoryPath + "/app.txt", atomically: true, encoding: .utf8
        )
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)

        let outcome = await VerificationHarness.verifyAppliedPatch(
            runner: runner,
            commands: VerificationCommands(
                buildCommand: "true", testCommand: "true", commandSubdirectory: nil
            ),
            reproCommand: nil
        )

        #expect(outcome.blockedStage == nil)
        #expect(outcome.build == .passed)
        #expect(outcome.suite == .passed)
        #expect(outcome.earnsCleanApply)
    }

    // MARK: - 3. A commit that did not happen is not a branch name

    /// Nothing is staged, so `git commit` finds nothing to commit and HEAD does
    /// not move. Before the fix the commit script's result was discarded and
    /// the branch name was returned regardless — the reader was shown a branch
    /// that carries none of their change.
    @Test("a commit that creates nothing returns nil rather than a branch name")
    func aCommitThatDoesNotMoveHeadReturnsNil() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)
        let headBefore = Self.git(["rev-parse", "HEAD"], in: repositoryPath)

        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: "iris/edit-",
                changeId: "feedfacefeedfacefeedfacefeedface",
                subject: "A change that was never staged",
                trailerLines: ["Modified-by: Iris (publik)"]
            ),
            runner: runner
        )

        #expect(branchName == nil)
        // And HEAD really did not move, so the test is measuring what it says.
        #expect(Self.git(["rev-parse", "HEAD"], in: repositoryPath) == headBefore)
    }

    /// The other half: a tree with a real change commits, HEAD moves, and the
    /// branch name comes back — so the guard refuses only phantom commits.
    @Test("a commit with real staged content returns its branch name")
    func aRealCommitStillReturnsItsBranchName() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        try "changed\n".write(
            toFile: repositoryPath + "/app.txt", atomically: true, encoding: .utf8
        )
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)
        let headBefore = Self.git(["rev-parse", "HEAD"], in: repositoryPath)

        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: "iris/edit-",
                changeId: "0123456789abcdef0123456789abcdef",
                subject: "A change that really landed",
                trailerLines: ["Modified-by: Iris (publik)"]
            ),
            runner: runner
        )

        #expect(branchName == MaintainFixCommit.branchName(
            prefix: "iris/edit-", changeId: "0123456789abcdef0123456789abcdef"
        ))
        #expect(Self.git(["rev-parse", "HEAD"], in: repositoryPath) != headBefore)
    }

    /// THE WRONG-BRANCH CASE. `git checkout -b iris/edit-<id>` cannot create a
    /// branch under `iris/` when a branch literally named `iris` already exists
    /// — git refuses the directory/file ref conflict — and the fallback
    /// `git checkout iris/edit-<id>` fails too, because that branch does not
    /// exist. The checkout and the commit used to be one `;`-joined script, so
    /// `git commit` still ran, landing the change on whatever branch the clone
    /// was on. HEAD moved, the old "did HEAD move?" guard passed, and a branch
    /// name came back for a commit sitting on `master`.
    @Test("a failed checkout commits nothing and returns nil, not a branch name")
    func aFailedCheckoutCommitsNothingAnywhere() async throws {
        let repositoryPath = try Self.makeRepositoryWithOneCommit()
        defer { try? FileManager.default.removeItem(atPath: repositoryPath) }
        // The ref conflict: `iris` as a branch makes `iris/edit-…` uncreatable.
        _ = Self.git(["branch", "iris"], in: repositoryPath)
        try "changed\n".write(
            toFile: repositoryPath + "/app.txt", atomically: true, encoding: .utf8
        )
        let runner = try MaintainShellRunner(repoRootPath: repositoryPath)
        let headBefore = Self.git(["rev-parse", "HEAD"], in: repositoryPath)
        let branchBefore = Self.git(["symbolic-ref", "--short", "HEAD"], in: repositoryPath)

        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: "iris/edit-",
                changeId: "abcdef0123456789abcdef0123456789",
                subject: "A change with nowhere legal to land",
                trailerLines: ["Modified-by: Iris (publik)"]
            ),
            runner: runner
        )

        #expect(branchName == nil)
        // The real point: nothing was committed ANYWHERE. The old code left a
        // commit on the checked-out branch and reported a branch that has none.
        #expect(Self.git(["rev-parse", "HEAD"], in: repositoryPath) == headBefore)
        #expect(Self.git(["symbolic-ref", "--short", "HEAD"], in: repositoryPath) == branchBefore)
    }

    // MARK: - Throwaway repository helpers

    /// A repo with one committed file, a configured identity (so `git commit`
    /// can run at all), and nothing outstanding.
    static func makeRepositoryWithOneCommit() throws -> String {
        let repositoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-verification-absence-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: repositoryPath, withIntermediateDirectories: true
        )
        git(["init", "-q"], in: repositoryPath)
        git(["config", "user.email", "t@t"], in: repositoryPath)
        git(["config", "user.name", "t"], in: repositoryPath)
        try "original\n".write(
            toFile: repositoryPath + "/app.txt", atomically: true, encoding: .utf8
        )
        git(["add", "-A"], in: repositoryPath)
        git(["commit", "-qm", "base"], in: repositoryPath)
        return repositoryPath
    }

    /// Runs git synchronously and returns its trimmed stdout. Setup and
    /// inspection only — the code under test uses its own runner.
    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
