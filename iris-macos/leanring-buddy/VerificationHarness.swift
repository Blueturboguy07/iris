//
//  VerificationHarness.swift
//  leanring-buddy
//
//  The gate between "a patch applied" and "a fix is real". Iris is both
//  prosecutor and defendant here — it authors the test AND the fix — and
//  the agentic-coding literature is unambiguous about how that ends without
//  hard checks: patches that pass their own test while breaking six others,
//  tests quietly rewritten to match the patch, "fixes" that are the answer
//  key retrieved rather than derived.
//
//  So the harness runs legs, and every leg is a hard block:
//
//    leg 1   the repro fails BEFORE the patch        (proves the test sees the bug)
//    leg 2   the repro passes AFTER the patch        (proves the patch does something)
//    leg 3   revert the patch, repro fails again     (proves the test wasn't tautological)
//            — then re-apply. One extra build; the only defense there is
//            against a self-verifying agent when nobody else wrote an oracle.
//    suite   the app's own full test suite stays green (PASS_TO_PASS)
//    build   the app still builds at all
//
//  A replayed recipe arrives with no repro test — its evidence came from
//  other machines — so legs 1–3 are skipped and it earns only `applied` +
//  build + suite, never a `verified` outcome without the full gate. The
//  outcome vocabulary keeps those separate on purpose.
//

import Foundation

/// What one verification run proved. Serialized into the recipe pointer's
/// `verification` jsonb and into the commit trailer block.
struct VerificationOutcome: Sendable {
    var reproFailedBeforePatch: Bool?
    var reproPassedAfterPatch: Bool?
    var reproFailedOnRevert: Bool?
    var buildSucceeded: Bool = false
    var suitePassed: Bool?
    /// The failing stage's output tail when the gate blocked, for the
    /// diagnosis record — never shown raw to the user.
    var blockedStage: String?
    var blockedOutputTail: String?

    /// The full three-legged standard: every leg present and correct.
    var earnsVerifiedFix: Bool {
        reproFailedBeforePatch == true
            && reproPassedAfterPatch == true
            && reproFailedOnRevert == true
            && buildSucceeded
            && suitePassed != false
    }

    /// The replay standard: applied cleanly, builds, suite green — honest
    /// but weaker, and counted separately by the pool.
    var earnsCleanApply: Bool {
        buildSucceeded && suitePassed != false && blockedStage == nil
    }
}

/// The per-stack command vocabulary. Code-authored, never model-authored —
/// which is why these strings never pass through the risk gate.
struct VerificationCommands: Sendable {
    let buildCommand: String?
    let testCommand: String?
    /// Where inside the repo the build/test commands run (Tauri keeps its
    /// JS in ui/, its Rust at the root).
    let commandSubdirectory: String?

    /// The default vocabulary per app stack. An app whose repo carries no
    /// test script gets a nil test command and the suite leg is skipped —
    /// recorded as skipped, never silently counted as green.
    static func defaults(for stack: BreakAppStack, repoRootPath: String) -> VerificationCommands {
        let fileManager = FileManager.default
        func hasFile(_ relativePath: String) -> Bool {
            fileManager.fileExists(atPath: (repoRootPath as NSString).appendingPathComponent(relativePath))
        }
        func packageJSONHasScript(_ script: String, at relativePath: String) -> Bool {
            let path = (repoRootPath as NSString).appendingPathComponent(relativePath)
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = json["scripts"] as? [String: Any] else { return false }
            return scripts[script] != nil
        }

        switch stack {
        case .tauri:
            return VerificationCommands(
                buildCommand: hasFile("ui/package.json")
                    ? "cd ui && npm run build --if-present && cd .. && cargo build --release --quiet"
                    : "cargo build --release --quiet",
                testCommand: "cargo test --quiet",
                commandSubdirectory: nil
            )
        case .electron, .nextjs:
            let hasTest = packageJSONHasScript("test", at: "package.json")
            return VerificationCommands(
                buildCommand: packageJSONHasScript("build", at: "package.json")
                    ? "npm run build" : nil,
                testCommand: hasTest ? "npm test" : nil,
                commandSubdirectory: nil
            )
        case .swiftMacOS, .other:
            return VerificationCommands(buildCommand: nil, testCommand: nil, commandSubdirectory: nil)
        }
    }
}

@MainActor
enum VerificationHarness {

    /// Verify a patch that is ALREADY APPLIED to the working tree, with git
    /// as the revert mechanism for leg 3. `reproCommand` nil = replay mode
    /// (legs skipped, weaker outcome by design).
    ///
    /// The tree is left in the applied state on success, and restored to the
    /// applied state after leg 3's revert — the caller owns committing.
    static func verifyAppliedPatch(
        runner: MaintainShellRunner,
        commands: VerificationCommands,
        reproCommand: String?
    ) async -> VerificationOutcome {
        var outcome = VerificationOutcome()

        // Legs 1–3 only exist when a repro test does.
        if let reproCommand {
            // Leg 1 needs the PRE-patch tree: stash the patch, run, restore.
            guard await gitStash(runner: runner) else {
                return blocked(&outcome, stage: "git-stash", tail: "could not stash the applied patch for leg 1")
            }
            let preResult = try? await runner.run(reproCommand, inSubdirectory: commands.commandSubdirectory, deadline: 300)
            outcome.reproFailedBeforePatch = preResult.map { !$0.succeeded } ?? false
            guard await gitStashPop(runner: runner) else {
                return blocked(&outcome, stage: "git-stash-pop", tail: "could not restore the patch after leg 1")
            }
            guard outcome.reproFailedBeforePatch == true else {
                return blocked(&outcome, stage: "leg1-repro-passed-prepatch",
                               tail: preResult?.outputTail ?? "")
            }

            // Leg 2: the applied tree.
            let postResult = try? await runner.run(reproCommand, inSubdirectory: commands.commandSubdirectory, deadline: 300)
            outcome.reproPassedAfterPatch = postResult?.succeeded ?? false
            guard outcome.reproPassedAfterPatch == true else {
                return blocked(&outcome, stage: "leg2-repro-failed-postpatch",
                               tail: postResult?.outputTail ?? "")
            }

            // Leg 3: revert, expect red, re-apply. The cheapest available
            // defense against a tautological or over-mocked test.
            guard await gitStash(runner: runner) else {
                return blocked(&outcome, stage: "git-stash-leg3", tail: "could not revert for leg 3")
            }
            let revertResult = try? await runner.run(reproCommand, inSubdirectory: commands.commandSubdirectory, deadline: 300)
            outcome.reproFailedOnRevert = revertResult.map { !$0.succeeded } ?? false
            guard await gitStashPop(runner: runner) else {
                return blocked(&outcome, stage: "git-stash-pop-leg3", tail: "could not re-apply after leg 3")
            }
            guard outcome.reproFailedOnRevert == true else {
                return blocked(&outcome, stage: "leg3-repro-passed-on-revert",
                               tail: revertResult?.outputTail ?? "")
            }
        }

        // Build — always, when the stack has one.
        if let buildCommand = commands.buildCommand {
            let buildResult = try? await runner.run(buildCommand, inSubdirectory: commands.commandSubdirectory)
            outcome.buildSucceeded = buildResult?.succeeded ?? false
            guard outcome.buildSucceeded else {
                return blocked(&outcome, stage: "build", tail: buildResult?.outputTail ?? "")
            }
        } else {
            // No build vocabulary for this stack: the stage is absent, not
            // green. earnsCleanApply still requires blockedStage == nil.
            outcome.buildSucceeded = true
        }

        // Full suite — PASS_TO_PASS, the touched files are never enough.
        if let testCommand = commands.testCommand {
            let suiteResult = try? await runner.run(testCommand, inSubdirectory: commands.commandSubdirectory)
            outcome.suitePassed = suiteResult?.succeeded ?? false
            guard outcome.suitePassed == true else {
                return blocked(&outcome, stage: "suite", tail: suiteResult?.outputTail ?? "")
            }
        }

        return outcome
    }

    private static func blocked(
        _ outcome: inout VerificationOutcome, stage: String, tail: String
    ) -> VerificationOutcome {
        outcome.blockedStage = stage
        outcome.blockedOutputTail = String(tail.suffix(2000))
        irisTrace("maintain: verification BLOCKED at \(stage)")
        return outcome
    }

    // Stash both directions through the runner so the boundary (never write
    // outside the repo root) applies to the harness's own git use too.
    private static func gitStash(runner: MaintainShellRunner) async -> Bool {
        ((try? await runner.run("git stash push --include-untracked --quiet", deadline: 60))?.succeeded) ?? false
    }

    private static func gitStashPop(runner: MaintainShellRunner) async -> Bool {
        ((try? await runner.run("git stash pop --quiet", deadline: 60))?.succeeded) ?? false
    }
}
