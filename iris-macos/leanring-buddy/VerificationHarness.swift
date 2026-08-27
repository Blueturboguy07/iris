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
//  Two additive final steps run AFTER every leg above passes (Feature Engine
//  plan §9), never in place of them:
//
//    cheat   scan the applied diff for the tamper signatures a self-grading
//            agent reaches for (FeatureEditVerificationAudit) — tautological
//            asserts, swallowed catches, focused/skipped tests, re-recorded
//            snapshots, a test mocking the module under test, a test/assert
//            count drop. A hit blocks exactly as hard as the weakens-tests
//            check it generalizes.
//    ladder  translate the signals the legs ALREADY collected into an honest
//            evidence log + the highest rung that evidence earns
//            (FeatureEditVerificationLadder). The rung is OBSERVED facts, never
//            a self-rated number, and is attached only after the cheat scan is
//            clean so a blocked run can never carry a rung implying it wasn't.
//
//  The binary earnsVerifiedFix/earnsCleanApply verdicts are untouched — the
//  rung and evidence log are added ALONGSIDE them, never in their place.
//

import Foundation

/// What became of one verification stage. Three states, because a stage has
/// three fates and any two-valued encoding has to conflate two of them:
///
///     .notRun   the stack has no such command, so nothing was attempted
///     .passed   the command ran and exited 0
///     .failed   the command ran and did not
///
/// The build stage used to be a `Bool` that was set to `true` for BOTH
/// "passed" and "did not exist" — the comment at the assignment said, in as
/// many words, "the stage is absent, not green" — and every downstream reader
/// of that `true` was then reading a value that had two meanings and no way to
/// tell them apart. Measured over an edit battery: four of five committed runs
/// collected no evidence at all, because their stacks resolved neither a build
/// nor a test command, and "no build" plus "no suite" added up to a clean
/// apply. Making the absent case its own value is what stops the seventh
/// instance of that being written next month — the compiler now asks about it
/// at every site.
enum VerificationStageResult: Sendable, Equatable {
    case notRun
    case passed
    case failed
}

/// What one verification run proved. Serialized into the recipe pointer's
/// `verification` jsonb and into the commit trailer block.
struct VerificationOutcome: Sendable {
    var reproFailedBeforePatch: Bool?
    var reproPassedAfterPatch: Bool?
    var reproFailedOnRevert: Bool?

    /// Whether the build command ran, and how it went. `.notRun` when the
    /// stack has no build command — which is a real and common case
    /// (`.swiftMacOS` and `.other` both resolve to no vocabulary at all), and
    /// is emphatically not the same thing as a green build.
    var build: VerificationStageResult = .notRun

    /// Whether the app's own full test suite ran, and how it went. `.notRun`
    /// when the stack has no test command — honestly skipped, never a silent
    /// green.
    var suite: VerificationStageResult = .notRun

    /// COMPATIBILITY ACCESSOR. "The build stage did not fail" — which is what
    /// this field has always meant, absent and green alike. Every reader that
    /// wants to know whether something actually COMPILED must ask
    /// `build == .passed` instead; that ambiguity is precisely the defect
    /// `VerificationStageResult` exists to remove, and this stays only so the
    /// serialized shape and the existing readers keep their meaning.
    var buildSucceeded: Bool { build != .failed }

    /// COMPATIBILITY ACCESSOR, and an exact one: nil when the suite did not
    /// run, true/false when it did. Unlike `buildSucceeded` this was never
    /// ambiguous, because it was already three-valued.
    var suitePassed: Bool? {
        switch suite {
        case .notRun: return nil
        case .passed: return true
        case .failed: return false
        }
    }
    /// The failing stage's output tail when the gate blocked, for the
    /// diagnosis record — never shown raw to the user.
    var blockedStage: String?
    var blockedOutputTail: String?

    // ── Feature Engine verification ladder (plan §9), additive ─────────────
    // These are populated by the final ladder step, only after every gate
    // above passes. They stand ALONGSIDE the binary verdicts below — nothing
    // here changes what earnsVerifiedFix / earnsCleanApply mean.

    /// The per-signal evidence the run collected, translated from the legs'
    /// own results. nil until the ladder step runs (i.e. nil on any blocked
    /// run), so a rung is never implied where the gates did not all pass.
    var verificationEvidence: VerificationEvidence?

    /// The highest rung the collected evidence honestly earns. nil on a
    /// blocked run for the same reason as `verificationEvidence`.
    var verificationRung: VerificationRung?

    /// The honest evidence-log rows (`VerificationEvidence.evidenceLogLines()`)
    /// for the reader-facing card and the commit trailer. Empty until the
    /// ladder step runs — never a confidence number, only observed facts.
    var evidenceLog: [String] = []

    /// The rung this change must reach to auto-commit, scaled by blast radius
    /// (ratified decision 5a). Set only when the caller supplied a runtime
    /// shape. Data only — this harness never gates on it; the coordinator that
    /// owns the commit does, exactly as it already gates on earnsCleanApply.
    var requiredRungForAutoCommit: VerificationRung?

    /// Cheat signatures the applied diff tripped (plan §9 anti-gaming). Empty
    /// means the diff was scanned and carried none; a non-empty list also
    /// BLOCKS the run (blockedStage == "cheat-signature"), mirroring the
    /// weakens-tests check inside enforceDiffScope.
    var cheatSignatureFindings: [String] = []

    /// The full three-legged standard: every leg present and correct.
    var earnsVerifiedFix: Bool {
        reproFailedBeforePatch == true
            && reproPassedAfterPatch == true
            && reproFailedOnRevert == true
            && build != .failed
            && suite != .failed
    }

    /// The replay standard: applied cleanly, builds, suite green — honest
    /// but weaker, and counted separately by the pool.
    ///
    /// DELIBERATELY UNCHANGED, and this is worth stating plainly: with both
    /// stages `.notRun` this is still true, so a change on a stack that
    /// resolves neither a build nor a test command still auto-commits on no
    /// evidence whatsoever. Requiring at least one stage to have actually run
    /// is the obviously correct gate and it is NOT applied here, because it
    /// would refuse to auto-commit for every `.swiftMacOS` and `.other` repo —
    /// a behaviour change a reader would feel immediately, and a product
    /// decision that has not been made. `atLeastOneVerificationStageActuallyRan`
    /// is the honest predicate that decision would turn on; until then the loop
    /// records when it commits without evidence rather than refusing to.
    var earnsCleanApply: Bool {
        build != .failed && suite != .failed && blockedStage == nil
    }

    /// Whether ANY verification stage actually executed. False means this run
    /// proved nothing: no build, no suite, no repro — an edit was made and
    /// nothing ran it.
    var atLeastOneVerificationStageActuallyRan: Bool {
        build != .notRun || suite != .notRun || reproPassedAfterPatch != nil
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
    /// The most files a single fix may touch before it stops looking like a
    /// fix and starts looking like a refactor (or a mistake). Google's
    /// small-CL guidance is the reference; a maintain-mode fix should be far
    /// under it.
    static let maximumFilesTouched = 12

    static func verifyAppliedPatch(
        runner: MaintainShellRunner,
        commands: VerificationCommands,
        reproCommand: String?,
        // Optional and defaulted so every existing caller is untouched. When a
        // caller knows how this app runs, the ladder step also records the rung
        // required to auto-commit (ratified decision 5a) — data only.
        runtimeShape: RecipeRuntimeShape? = nil,
        // Whether the change under verification is expected to be sitting in the
        // working tree UNCOMMITTED. True for every path that just applied a
        // patch — a Tier C run, a recipe replay — where an empty diff means
        // there is nothing to vouch for and the run must not sail through.
        //
        // FALSE for `IncomingFixReviewer`, which verifies somebody else's fix
        // inside `git worktree add --detach FETCH_HEAD`: there the change is
        // COMMITTED, so `git diff HEAD` is empty by construction and always
        // will be. Treating that as "nothing to verify" refused every incoming
        // PR before a single build ran. The scope limits still apply — an empty
        // diff simply stops being an error for a caller that never expected one.
        expectsAnUncommittedDiff: Bool = true
    ) async -> VerificationOutcome {
        var outcome = VerificationOutcome()

        // Diff-scope gate, FIRST — before a single build or test runs. A fix
        // that passes the suite can still be wrong in ways the suite cannot
        // see: it deletes the failing test to go green, or it sprawls across
        // the codebase. The suite is necessary, not sufficient; this is the
        // other half. A block here is as hard as a failed leg.
        let scope = await enforceDiffScope(
            runner: runner, expectsAnUncommittedDiff: expectsAnUncommittedDiff
        )
        guard scope.ok else {
            return blocked(&outcome, stage: "diff-scope", tail: scope.reason ?? "diff-scope violation")
        }

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
            outcome.build = (buildResult?.succeeded ?? false) ? .passed : .failed
            guard outcome.build == .passed else {
                return blocked(&outcome, stage: "build", tail: buildResult?.outputTail ?? "")
            }
        }
        // No build vocabulary for this stack: `outcome.build` stays `.notRun`,
        // which is now a value in its own right rather than a `true` that has
        // to be explained in a comment.

        // Full suite — PASS_TO_PASS, the touched files are never enough.
        if let testCommand = commands.testCommand {
            let suiteResult = try? await runner.run(testCommand, inSubdirectory: commands.commandSubdirectory)
            outcome.suite = (suiteResult?.succeeded ?? false) ? .passed : .failed
            guard outcome.suite == .passed else {
                return blocked(&outcome, stage: "suite", tail: suiteResult?.outputTail ?? "")
            }
        }

        // ── Feature Engine verification ladder (plan §9) ───────────────────
        // Every leg above has passed. Two additive steps run now, both hard.
        //
        // Step 1 — cheat-signature scan of the applied diff. enforceDiffScope
        // already blocked the crudest tamper (a test file that deletes more
        // than it adds); this generalizes that to the named cheat signatures a
        // self-grading agent reaches for. A hit blocks exactly as hard as the
        // weakens-tests check it extends — the findings are recorded on the
        // outcome first so a blocked run still carries WHY it was blocked.
        let appliedUnifiedDiff = await readAppliedUnifiedDiff(runner: runner)
        let cheatSignatureFindings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: appliedUnifiedDiff)
        outcome.cheatSignatureFindings = cheatSignatureFindings
        guard cheatSignatureFindings.isEmpty else {
            return blocked(
                &outcome,
                stage: "cheat-signature",
                tail: "applied diff trips cheat signatures: "
                    + cheatSignatureFindings.joined(separator: "; ")
            )
        }

        // Step 2 — translate the signals the legs ALREADY collected into an
        // honest evidence log + the highest rung that evidence earns. Attached
        // only after the cheat scan came back clean, so a blocked run never
        // carries a rung implying it was honest. Never a self-rated number —
        // FeatureEditVerificationLadder climbs strictly and stops at the first
        // missing signal, so no rung is ever claimed above its evidence.
        let collectedEvidence = evidenceFromCollectedSignals(outcome: outcome)
        outcome.verificationEvidence = collectedEvidence
        outcome.verificationRung = FeatureEditVerificationLadder.highestEarnedRung(from: collectedEvidence)
        outcome.evidenceLog = collectedEvidence.evidenceLogLines()
        // When the caller told us how this app runs, also record the rung it
        // must reach to auto-commit (ratified decision 5a). Data only — this
        // harness does not gate on it; the caller does.
        if let runtimeShape {
            outcome.requiredRungForAutoCommit =
                FeatureEditVerificationLadder.requiredRung(forRuntimeShape: runtimeShape)
        }

        return outcome
    }

    /// Translate the signals the verification legs already collected into the
    /// ladder's per-signal evidence. Deliberately conservative and honest:
    ///
    ///   - L1 `compileClean` is earned ONLY when a real build command existed
    ///     AND succeeded — which is now just `build == .passed`, because the
    ///     stage result says so itself. It used to require cross-checking
    ///     `commands.buildCommand != nil` against a `buildSucceeded` that meant
    ///     "absent OR green", i.e. two sources that could disagree.
    ///   - L2 `existingSuiteGreen` is earned only when the full suite actually
    ///     ran and was green (`suite == .passed`); a skipped suite is no
    ///     evidence, never a silent green.
    ///   - L3 `newTestPasses` is earned only when the three-leg repro proved a
    ///     targeted test that failed before the patch, passed after, and failed
    ///     again on revert — a test shown to actually see the change. A replay
    ///     or feature edit carries no repro (legs skipped), so this stays false
    ///     and the change honestly caps below L3, exactly as the plan intends.
    ///
    /// L4–L6 (mutation, live smoke, adversarial review) are not signals this
    /// harness collects, so they remain unearned — the run reports the honest
    /// floor rather than a fabricated ceiling.
    private static func evidenceFromCollectedSignals(
        outcome: VerificationOutcome
    ) -> VerificationEvidence {
        var evidence = VerificationEvidence()

        if outcome.build == .passed {
            evidence.compileClean = true
            evidence.compileCleanEvidence = "build command exited 0"
        }

        if outcome.suite == .passed {
            evidence.existingSuiteGreen = true
            evidence.existingSuiteGreenEvidence = "existing suite exited 0"
        }

        let reproProvedTheChange = outcome.reproFailedBeforePatch == true
            && outcome.reproPassedAfterPatch == true
            && outcome.reproFailedOnRevert == true
        if reproProvedTheChange {
            evidence.newTestPasses = true
            evidence.newTestPassesEvidence =
                "repro failed before the patch, passed after it, and failed again on revert (3-leg)"
        }

        return evidence
    }

    /// Reads the applied patch as a unified diff for the cheat-signature scan.
    /// Best-effort by design — a diff we cannot read must never fabricate a
    /// clean scan, but it also must not crash a run whose gates already passed;
    /// the scan is an ADDED net, not a load-bearing gate on its own.
    ///
    ///   • `git diff HEAD` captures every TRACKED modification the patch made
    ///     (an edited test that gained a tautological assert, a swallowed
    ///     catch, a re-recorded snapshot). It exits 0 with changes present.
    ///   • Untracked NEW files are invisible to `git diff HEAD`, yet a brand-
    ///     new all-green tautological test file is precisely a cheat — so each
    ///     new file is rendered as an add-diff via `git diff --no-index` and
    ///     appended. `--exclude-standard` drops gitignored build output; a cap
    ///     guards against a misconfigured repo spewing artifacts here (scope was
    ///     already vetted pre-build by enforceDiffScope).
    private static func readAppliedUnifiedDiff(runner: MaintainShellRunner) async -> String {
        var combinedUnifiedDiff = ""

        if let trackedDiff = try? await runner.run("git diff HEAD", deadline: 120),
           trackedDiff.succeeded {
            combinedUnifiedDiff += trackedDiff.outputTail
        }

        let untrackedNewFiles = (try? await runner.run("git ls-files --others --exclude-standard", deadline: 60))?
            .outputTail
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        // More new files than a single fix could plausibly add means this is
        // post-build artifact spew, not the patch — scan the tracked diff only.
        if untrackedNewFiles.count <= maximumFilesTouched {
            for newFilePath in untrackedNewFiles {
                // `git diff --no-index` exits non-zero BY DESIGN when the two
                // sides differ (they always do here — /dev/null vs a real
                // file), so read its output regardless of the exit code.
                if let addDiff = try? await runner.run(
                    "git diff --no-index -- /dev/null \(shellSingleQuoted(newFilePath))",
                    deadline: 60
                ) {
                    if !combinedUnifiedDiff.isEmpty { combinedUnifiedDiff += "\n" }
                    combinedUnifiedDiff += addDiff.outputTail
                }
            }
        }

        return combinedUnifiedDiff
    }

    /// Single-quote a path for safe use in a POSIX shell command, so a filename
    /// with spaces or metacharacters cannot alter the diff command. Embedded
    /// single quotes are closed, escaped, and reopened — the standard `'\''`
    /// trick, matching FeatureEditVerificationAudit's own quoting.
    private static func shellSingleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reads the applied (uncommitted) diff and blocks a fix that touches too
    /// many files or weakens tests. Uses `git diff --numstat HEAD`, so it
    /// sees exactly what the patch changed against the last commit.
    private static func enforceDiffScope(
        runner: MaintainShellRunner,
        expectsAnUncommittedDiff: Bool
    ) async -> (ok: Bool, reason: String?) {
        guard let result = try? await runner.run("git diff --numstat HEAD", deadline: 60),
              result.succeeded else {
            // Can't read the diff → can't vouch for its scope → fail closed.
            return (false, "could not read the diff to check its scope")
        }
        let lines = result.outputTail
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // `git diff` only sees TRACKED changes — a fix that ADDS new files
        // (whole new modules, or a pile of junk) is invisible to it. Count
        // untracked files too, or the file-count limit is trivially evaded.
        let untracked = (try? await runner.run("git ls-files --others --exclude-standard", deadline: 60))?
            .outputTail
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        let totalFiles = lines.count + untracked.count
        // An EMPTY diff is not a clean scope — it is nothing to verify. The
        // gate used to answer "ok" here, so a run whose tree turned out to hold
        // no change at all sailed through the scope check and on into a build
        // and suite that were, correctly, green about the unmodified code. A
        // gate that reports on a diff must not report "clean" about a diff that
        // is not there.
        //
        // But only for a caller that EXPECTED an uncommitted diff. Reviewing a
        // committed change in a detached worktree legitimately has none, and
        // failing that closed refused every incoming PR outright — a whole
        // feature broken by a check meant to protect a different one.
        if expectsAnUncommittedDiff {
            guard totalFiles > 0 else {
                return (false, "the working tree has no changes to verify")
            }
        }

        if totalFiles > maximumFilesTouched {
            return (false, "touches \(totalFiles) files (\(lines.count) changed, \(untracked.count) new), over the \(maximumFilesTouched)-file limit for one fix")
        }

        for line in lines {
            // numstat: "<added>\t<deleted>\t<path>". A binary file shows "-".
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { continue }
            let added = Int(fields[0]) ?? 0
            let deleted = Int(fields[1]) ?? 0
            let path = fields[2].lowercased()
            let looksLikeATest = path.contains("test") || path.contains("spec")
                || path.contains("__tests__")
            // A fix that removes more test lines than it adds is weakening the
            // very thing that would catch a regression — the classic "delete
            // the failing test to go green". Blocked outright.
            if looksLikeATest && deleted > added {
                return (false, "weakens tests in \(fields[2]) (-\(deleted)/+\(added))")
            }
        }
        return (true, nil)
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
