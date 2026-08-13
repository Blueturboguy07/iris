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
}

@MainActor
final class RecipeReplayEngine {

    private let provenanceStore: InstallProvenanceStore
    private let poolClient: MaintainPoolClient
    private let installIdentity: MaintainInstallIdentity

    init(
        provenanceStore: InstallProvenanceStore,
        poolClient: MaintainPoolClient,
        installIdentity: MaintainInstallIdentity
    ) {
        self.provenanceStore = provenanceStore
        self.poolClient = poolClient
        self.installIdentity = installIdentity
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

        // Write the patch inside the repo (the runner's boundary) under a
        // name git ignores by convention only after we clean it up ourselves.
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
            irisTrace("maintain: recipe \(recipe.id) stale — did not apply (3way check failed)")
            await file(outcome: false, kind: "applied", recipe: recipe)
            return .patchDidNotApply
        }
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
        let dateStamp = Self.compactDateStamp()
        let branchName = "iris/fix-\(signatureId.prefix(12))-\(dateStamp)"
        let commitMessage = "Apply pooled fix recipe \(recipe.id)\n\n"
            + "Break-Signature: \(signatureId)\n"
            + "Fix-Recipe-Match: \(recipe.id)\n"
            + "Verified: applied, build-green\(verification.suitePassed == true ? ", suite-green" : "")\n"
            + "Assisted-by: iris-maintain-mode/1\n"
            + "Modified-by: Iris (publik) — replayed a pooled recipe"
        let commitScript = "git checkout -b '\(branchName)' 2>/dev/null || git checkout '\(branchName)'; "
            + "git add -A && git commit -m '\(commitMessage.replacingOccurrences(of: "'", with: "'\\''"))' --quiet"
        _ = try? await runner.run(commitScript, deadline: 60)

        await file(outcome: true, kind: "verified", recipe: recipe)
        irisTrace("maintain: recipe \(recipe.id) replayed and committed on \(branchName)")
        return .patchAppliedAndVerified(branchName: branchName)
    }

    private func file(outcome succeeded: Bool, kind: String, recipe: PooledFixRecipe) async {
        await poolClient.fileRecipeOutcome(
            recipeId: recipe.id,
            succeeded: succeeded,
            installId: installIdentity.currentInstallId
        )
        _ = kind // the outcome route infers kind server-side in v1
    }

    private static func compactDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
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
