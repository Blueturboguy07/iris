//
//  RecipeReplayEngine.swift
//  leanring-buddy
//
//  Tier A of the fix ladder: someone else already fixed this exact break,
//  and their recipe is in the pool. Replaying it costs zero tokens — which
//  is the entire economic argument for maintain mode, and the only fix path
//  the funded tier ever gets.
//
//  Three recipe families, three behaviors:
//
//    workaround / config_change / update_app
//        Steps for a person. The engine surfaces them; it runs nothing.
//
//    patch_pr (a diff against a recorded base)
//        For a source-clone install only (the D4 gate), the engine applies
//        it with `git apply --3way` — three-way merge against the recorded
//        base tolerates drift honestly, leaving conflict markers rather than
//        mis-applying — then hands the tree to the verification harness and
//        files the outcome either way. A clean apply that fails verification
//        is REVERTED and reported as a failure: leaving a half-working patch
//        in someone's tree because it merged cleanly is exactly the
//        "textual merge is not a working merge" trap.
//
//  Every outcome reaches the pool with this install's pseudonymous id, so
//  promotion counts distinct machines, not retries.
//

import Foundation

/// What replaying one recipe produced, for the coordinator to surface.
enum RecipeReplayResult: Sendable {
    /// Steps for the user to follow — workaround/config/update recipes.
    case guidanceToShow(steps: [String])
    /// The patch applied and passed the replay verification standard.
    case patchAppliedAndVerified(branchName: String)
    /// The patch applied but verification blocked; the tree was reverted.
    case patchRevertedAfterFailedVerification(blockedStage: String)
    /// The patch could not apply, even three-way. Stale for this version.
    case patchDidNotApply
    /// The D4 gate said no local patching for this install.
    case patchingNotPermittedForThisInstall
    /// The recipe's applicability range excludes this machine.
    case outsideApplicabilityRange
    /// The on-demand editor (or another replay) already holds this clone's
    /// lock. Both paths strip/restore `.git` and revert the tree, so they must
    /// never run on the same clone at once — see `MaintainClonePathLock`.
    case anotherEditInProgress
}

@MainActor
final class RecipeReplayEngine {

    private let provenanceStore: InstallProvenanceStore
    private let poolClient: MaintainPoolClient
    private let installIdentity: MaintainInstallIdentity
    private let patchQueue: PatchQueue
    /// Tier B, present only when the build wires it. Nil = stale recipes end
    /// at "didn't apply" (the funded tier's honest ceiling).
    private let fixAdapter: MaintainFixAdapting?

    init(
        provenanceStore: InstallProvenanceStore,
        poolClient: MaintainPoolClient,
        installIdentity: MaintainInstallIdentity,
        // No default: a default argument evaluates nonisolated, and the
        // queue's init is main-actor. Callers are @MainActor anyway.
        patchQueue: PatchQueue,
        fixAdapter: MaintainFixAdapting? = nil
    ) {
        self.provenanceStore = provenanceStore
        self.poolClient = poolClient
        self.installIdentity = installIdentity
        self.patchQueue = patchQueue
        self.fixAdapter = fixAdapter
    }

    func replay(
        recipe: PooledFixRecipe,
        appSlug: String,
        appStack: BreakAppStack,
        installedAppVersion: String?,
        signatureId: String
    ) async -> RecipeReplayResult {
        guard RecipeApplicability.matches(
            applicabilityJSON: recipe.applicability,
            appVersion: installedAppVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            architecture: MaintainInstallIdentity.machineArchitecture
        ) else {
            irisTrace("maintain: recipe \(recipe.id) refused — outside applicability range")
            return .outsideApplicabilityRange
        }

        // The non-patch families are guidance, never execution.
        if recipe.recipeType != "patch_pr" {
            return .guidanceToShow(steps: RecipeGuidanceSteps.extract(fromRecipeJSON: recipe.recipe))
        }

        guard provenanceStore.localPatchingIsPermitted(forAppSlug: appSlug),
              let record = provenanceStore.provenance(forAppSlug: appSlug),
              let clonePath = record.clonePath else {
            return .patchingNotPermittedForThisInstall
        }
        guard let patchText = recipe.patchSpecific, !patchText.isEmpty else {
            return .patchDidNotApply
        }

        guard let runner = try? MaintainShellRunner(repoRootPath: clonePath) else {
            return .patchingNotPermittedForThisInstall
        }

        // Concurrency rail: the on-demand editor and this replay both strip and
        // restore `.git` and revert the working tree. If a crash-driven replay
        // and a user-initiated edit landed on the SAME clone at once, their two
        // `.git` strips and reverts would race and corrupt the tree. The lock is
        // the same one `OnDemandEditCoordinator` takes; held across the whole
        // tree-touching span below and released on every exit via `defer`.
        guard MaintainClonePathLock.shared.tryAcquire(clonePath: clonePath, owner: "replay") else {
            return .anotherEditInProgress
        }
        defer { MaintainClonePathLock.shared.release(clonePath: clonePath) }

        // Tier A: the exact pooled diff.
        let exactResult = await applyVerifyAndCommit(
            patchText: patchText, recipe: recipe, appSlug: appSlug,
            appStack: appStack, signatureId: signatureId,
            runner: runner, clonePath: clonePath, wasAdapted: false
        )
        guard case .patchDidNotApply = exactResult else { return exactResult }

        // Tier B: the diff is stale for this version — one constrained BYO
        // model call re-anchors it, seeded with the pooled diagnosis. Absent
        // an adapter (or a key), stale is the honest end of the road.
        guard let fixAdapter else { return .patchDidNotApply }
        let excerpts = Self.localFileExcerpts(forPatch: patchText, clonePath: clonePath)
        let adaptation = await fixAdapter.adaptPatch(
            diagnosis: recipe.diagnosis,
            stalePatch: patchText,
            localFileExcerpts: excerpts,
            appSlug: appSlug
        )
        guard case .adaptedPatch(let adaptedDiff) = adaptation else {
            if case .modelCouldNotAdapt(let reason) = adaptation {
                irisTrace("maintain: adapt_patch declined — \(reason)")
            }
            return .patchDidNotApply
        }
        irisTrace("maintain: recipe \(recipe.id) adapted via BYO — retrying apply")
        return await applyVerifyAndCommit(
            patchText: adaptedDiff, recipe: recipe, appSlug: appSlug,
            appStack: appStack, signatureId: signatureId,
            runner: runner, clonePath: clonePath, wasAdapted: true
        )
    }

    /// The shared spine both tiers ride: dry-run, apply, verify (revert on
    /// failure), commit on a recipe-keyed branch, queue the patch, file the
    /// outcome. `wasAdapted` only changes the bookkeeping words.
    private func applyVerifyAndCommit(
        patchText: String,
        recipe: PooledFixRecipe,
        appSlug: String,
        appStack: BreakAppStack,
        signatureId: String,
        runner: MaintainShellRunner,
        clonePath: String,
        wasAdapted: Bool
    ) async -> RecipeReplayResult {
        // Write the patch inside the repo (the runner's boundary); cleaned up
        // whatever happens below.
        let patchFileName = ".iris-replay-\(recipe.id).patch"
        let patchFilePath = (clonePath as NSString).appendingPathComponent(patchFileName)
        defer { try? FileManager.default.removeItem(atPath: patchFilePath) }
        do {
            try patchText.write(toFile: patchFilePath, atomically: true, encoding: .utf8)
        } catch {
            return .patchDidNotApply
        }

        // Dry-run first: --check answers "would this apply" without touching
        // the tree, so a stale recipe never leaves half a patch behind.
        let dryRun = try? await runner.run("git apply --check --3way \(patchFileName)", deadline: 60)
        guard dryRun?.succeeded == true else {
            if !wasAdapted {
                irisTrace("maintain: recipe \(recipe.id) stale — did not apply (3way check failed)")
                await file(outcome: false, kind: "applied", recipe: recipe)
            }
            return .patchDidNotApply
        }
        let baseCommit = (try? await runner.run("git rev-parse HEAD", deadline: 30))?
            .outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let applied = try? await runner.run("git apply --3way \(patchFileName)", deadline: 60)
        guard applied?.succeeded == true else {
            await file(outcome: false, kind: "applied", recipe: recipe)
            return .patchDidNotApply
        }
        await file(outcome: true, kind: "applied", recipe: recipe)

        // Replay standard: build + suite. No repro test rode along, so the
        // three legs are structurally impossible here — and the outcome kind
        // stays 'applied', never 'verified', for exactly that reason.
        let commands = VerificationCommands.defaults(for: appStack, repoRootPath: clonePath)
        let verification = await VerificationHarness.verifyAppliedPatch(
            runner: runner, commands: commands, reproCommand: nil
        )

        guard verification.earnsCleanApply else {
            _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
            await file(outcome: false, kind: "verified", recipe: recipe)
            return .patchRevertedAfterFailedVerification(
                blockedStage: verification.blockedStage ?? "unknown"
            )
        }

        // Commit on a recipe-keyed branch — the fork service (M4) pushes it.
        // The branch naming, the commit script, and the trailer-block shape are
        // shared with the Tier C loop via MaintainFixCommit; only the trailer
        // VOCABULARY (a replayed/adapted recipe's honest claim) is ours.
        let provenanceWord = wasAdapted ? "adapted from" : "replayed"
        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: "iris/fix-",
                changeId: signatureId,
                subject: "Apply pooled fix recipe \(recipe.id)",
                trailerLines: [
                    "Break-Signature: \(signatureId)",
                    "Fix-Recipe-Match: \(recipe.id)\(wasAdapted ? " (adapted)" : "")",
                    "Verified: applied, build-green\(verification.suitePassed == true ? ", suite-green" : "")",
                    "Assisted-by: iris-maintain-mode/1",
                    "Modified-by: Iris (publik) — \(provenanceWord) a pooled recipe",
                ]
            ),
            runner: runner
        )

        patchQueue.record(QueuedPatch(
            recipeId: recipe.id,
            signatureId: signatureId,
            appSlug: appSlug,
            branchName: branchName,
            patchText: patchText,
            baseCommit: baseCommit,
            appliedAt: Date()
        ))

        await file(outcome: true, kind: "verified", recipe: recipe)
        irisTrace("maintain: recipe \(recipe.id) \(provenanceWord) and committed on \(branchName)")
        return .patchAppliedAndVerified(branchName: branchName)
    }

    /// The files a diff touches, as they look on THIS machine — the adapt
    /// call's grounding. Paths come from the diff's own +++ headers, resolved
    /// under the clone only; anything escaping the root is skipped.
    static func localFileExcerpts(forPatch patchText: String, clonePath: String) -> String {
        let root = (clonePath as NSString).standardizingPath
        var excerpts: [String] = []
        for line in patchText.split(separator: "\n") where line.hasPrefix("+++ ") {
            var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
            guard path != "/dev/null" else { continue }
            let fullPath = ((root as NSString).appendingPathComponent(path) as NSString).standardizingPath
            guard fullPath.hasPrefix(root + "/"),
                  let contents = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            excerpts.append("=== \(path) ===\n\(String(contents.prefix(6000)))")
        }
        return excerpts.joined(separator: "\n\n")
    }

    private func file(outcome succeeded: Bool, kind: String, recipe: PooledFixRecipe) async {
        await poolClient.fileRecipeOutcome(
            recipeId: recipe.id,
            succeeded: succeeded,
            installId: installIdentity.currentInstallId
        )
        _ = kind // the outcome route infers kind server-side in v1
    }
}

// MARK: - Applicability (OSV-shaped typed ranges)

enum RecipeApplicability {

    /// The pooled shape: {"app_version":[{"introduced":"1.0","fixed":"1.4"}],
    /// "os":["macos-15"], "arch":["arm64"]}. Absent field = no constraint.
    /// Malformed JSON = NO match — a recipe whose applicability cannot be
    /// read must not run, same fail-closed rule as unknown provenance.
    static func matches(
        applicabilityJSON: [String: AnyDecodableJSON]?,
        appVersion: String?,
        osVersion: OperatingSystemVersion,
        architecture: String
    ) -> Bool {
        guard let applicabilityJSON else { return true }

        if let archRanges = applicabilityJSON["arch"] {
            let allowed = decodeStringArray(archRanges)
            if let allowed, !allowed.isEmpty, !allowed.contains(architecture) { return false }
            if allowed == nil { return false }
        }
        if let versionRanges = applicabilityJSON["app_version"] {
            guard let appVersion else { return false }
            guard let ranges = decodeVersionRanges(versionRanges) else { return false }
            let inSomeRange = ranges.contains { range in
                // `cannotBeCompared` fails the range, not the guard above:
                // an unparseable version is outside every proven range.
                let afterIntroduced = range.introduced.map { introduced in
                    let ordering = ReleaseVersion.compare(appVersion, to: introduced)
                    return ordering == .newerThanTheOtherVersion || ordering == .theSameAsTheOtherVersion
                } ?? true
                let beforeFixed = range.fixed.map { fixed in
                    ReleaseVersion.compare(appVersion, to: fixed) == .olderThanTheOtherVersion
                } ?? true
                return afterIntroduced && beforeFixed
            }
            if !inSomeRange { return false }
        }
        _ = osVersion // os ranges land with real cross-version data; absent = unconstrained
        return true
    }

    private struct VersionRange {
        let introduced: String?
        let fixed: String?
    }

    private static func decodeStringArray(_ value: AnyDecodableJSON) -> [String]? {
        guard let data = value.value.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array
    }

    private static func decodeVersionRanges(_ value: AnyDecodableJSON) -> [VersionRange]? {
        guard let data = value.value.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.map {
            VersionRange(introduced: $0["introduced"] as? String, fixed: $0["fixed"] as? String)
        }
    }
}

// MARK: - Guidance extraction

enum RecipeGuidanceSteps {
    /// A guidance recipe's jsonb is guide-steps shaped: {"steps":[{"title":
    /// ..., "body": ..., "command": ...}]}. Extract readable lines; an
    /// unreadable recipe yields one honest line instead of nothing.
    static func extract(fromRecipeJSON recipeJSON: AnyDecodableJSON) -> [String] {
        guard let data = recipeJSON.value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]], !steps.isEmpty else {
            return ["A fix is known for this break, but its steps could not be read — check the app's page on publik."]
        }
        return steps.compactMap { step in
            let title = step["title"] as? String
            let command = step["command"] as? String
            switch (title, command) {
            case let (title?, command?): return "\(title): `\(command)`"
            case let (title?, nil): return title
            case let (nil, command?): return "Run `\(command)`"
            default: return nil
            }
        }
    }
}
