import Foundation
@testable import IrisHarnessNative

@main
struct SavedEditDeliveryChecks {
    @MainActor
    static func main() async throws {
        let files = FileManager.default
        guard let scratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"] else {
            throw NSError(domain: "missing-fixture-scratch", code: 1)
        }
        try files.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let root = files.temporaryDirectory.appendingPathComponent("iris-saved-delivery-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let clone = root.appendingPathComponent("clone")
        try files.createDirectory(at: clone, withIntermediateDirectories: true)
        let runner = try MaintainShellRunner(repoRootPath: clone.path)
        func command(_ text: String) async throws {
            let result = try await runner.run(text, deadline: 20)
            guard result.succeeded else {
                throw NSError(domain: "fixture-command", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: result.outputTail])
            }
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: 1) }
        }
        let failedStatus = MaintainCommandResult(exitCode: 72, outputTail: "error: No developer tools were found", timedOut: false, bytesDroppedBeforeTail: 0)
        try require(!OnDemandEditCoordinator.repositoryStatusWasRead(failedStatus), "Git error was treated as repository changes")
        try require(!OnDemandEditCoordinator.repositoryStatusWasRead(nil), "missing Git status was treated as clean")
        try require(!OnDemandEditCoordinator.repositoryStatusWasRead(.init(exitCode: 0, outputTail: "", timedOut: false, bytesDroppedBeforeTail: 4)), "truncated status was accepted")
        print("PASS failed, unavailable and truncated repository status cannot enable editing or stashing")
        let reviewFailure = OnDemandEditCoordinator.mappedFailure(
            reason: "the fix failed verification (native-review-required)").userFacing
        try require(reviewFailure.contains("review") && reviewFailure.contains("did not install")
            && !reviewFailure.contains("didn't build") && !reviewFailure.contains("pass the tests"),
            "review rejection was mislabeled as a build or test failure")
        let unknownCheckFailure = OnDemandEditCoordinator.mappedFailure(
            reason: "the fix failed verification (cheat-signature)").userFacing
        try require(unknownCheckFailure.contains("required checks")
            && !unknownCheckFailure.contains("reverted everything"),
            "generic check failure invented a failed build or confirmed rollback")
        try require(OnDemandEditCoordinator.mappedFailure(
            reason: "the fix failed verification (native-final-review)").userFacing == reviewFailure,
            "final native review rejection did not retain its review-specific explanation")
        let warnedStatus = MaintainCommandResult(exitCode: 0,
            outputTail: "warning: unable to access '/etc/gitattributes': Operation not permitted\n",
            timedOut: false, bytesDroppedBeforeTail: 0)
        try require(!OnDemandEditCoordinator.repositoryStatusWasRead(warnedStatus), "successful Git warning was parsed as a dirty file")
        try require(!OnDemandEditCoordinator.repositoryStatusWasRead(.init(exitCode: 0,
            outputTail: " M source.txt\nwarning: missing attributes\n", timedOut: false, bytesDroppedBeforeTail: 0)), "mixed Git output was treated as authoritative status")
        let clean = MaintainCommandResult(exitCode: 0, outputTail: "", timedOut: false, bytesDroppedBeforeTail: 0)
        let dirty = MaintainCommandResult(exitCode: 0, outputTail: " M source.txt\n?? partial.txt\n", timedOut: false, bytesDroppedBeforeTail: 0)
        try require(OnDemandEditCoordinator.sourceAwareFailureMessage(mapped: "clean result", reason: "budget", status: clean) == "clean result", "clean failure mapping changed")
        try require(OnDemandEditCoordinator.sourceAwareFailureMessage(mapped: "nothing changed", reason: "budget", status: dirty).contains("Partial source changes remain"), "dirty failure falsely claimed unchanged")
        try require(OnDemandEditCoordinator.sourceAwareFailureMessage(mapped: "nothing changed", reason: "budget", status: failedStatus).contains("could not confirm"), "unreadable source falsely claimed unchanged")
        let stagedSaveFailure = MaintainCommandResult(exitCode: 0,
            outputTail: "M  source.txt\nA  source.test.mjs\n",
            timedOut: false, bytesDroppedBeforeTail: 0)
        let saveFailureReason = "Iris could not save the change as a version. Source changes remain for review; the installed app was not updated."
        let stagedMessage = OnDemandEditCoordinator.sourceAwareFailureMessage(
            mapped: "nothing changed", reason: saveFailureReason, status: stagedSaveFailure)
        try require(OnDemandEditCoordinator.repositoryStatusWasRead(stagedSaveFailure)
            && stagedMessage.contains("Source changes remain")
            && stagedMessage.contains("installed app was not updated")
            && !stagedMessage.contains("nothing was kept"),
            "staged commit failure lost source or installed-app truth")
        let recoveryPath = root.appendingPathComponent("held-recovery.json").path
        let held = OnDemandEditInFlightRecord(appSlug: "fixture", clonePath: clone.path,
            baseCommit: String(repeating: "a", count: 40), pathsIrisEdited: ["source.txt"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), runLogPath: nil, whatIrisWasWaitingFor: "review", requiresReviewBeforeRecovery: true)
        OnDemandEditInterruptedRunRecovery.remember(held, recordPath: recoveryPath)
        if case .leftAlone = OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: recoveryPath) {} else {
            throw NSError(domain: "held-failure-was-not-preserved", code: 1)
        }
        try require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: recoveryPath) == held, "failure record lost after restart check")
        OnDemandEditInterruptedRunRecovery.forgetUnlessReviewIsRequired(recordPath: recoveryPath)
        try require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: recoveryPath) == held, "Done/reset lost held review")
        try OnDemandEditInterruptedRunRecovery.archiveHeldReviewBeforeNewRun(recordPath: recoveryPath)
        try require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: recoveryPath) == nil, "old review contaminated next run")
        let archives = try files.contentsOfDirectory(at: root.appendingPathComponent("failed-edit-reviews"), includingPropertiesForKeys: nil)
        try require(archives.count == 1 && OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: archives[0].path) == held, "held review was not archived exactly")
        print("PASS failed edits report dirty or unknown source and retain review-held recovery across reload")
        var turns = [MaintainChatTurn(role: "user", text: "runtime observation", attachedImagePNGData: Data([1])),
            MaintainChatTurn(role: "assistant", text: "Observed the Settings panel"),
            MaintainChatTurn(role: "user", text: "explicit later attachment", attachedImagePNGData: Data([2]))]
        MaintainTierCFixer.retireOpeningRuntimeScreenshot(in: &turns)
        try require(turns[0].attachedImagePNGData == nil && turns[1].text == "Observed the Settings panel"
            && turns[2].attachedImagePNGData == Data([2]), "runtime screenshot retirement damaged other evidence")
        MaintainTierCFixer.retireOpeningRuntimeScreenshot(in: &turns)
        var empty: [MaintainChatTurn] = []
        MaintainTierCFixer.retireOpeningRuntimeScreenshot(in: &empty)
        print("PASS one-shot runtime image retirement preserves written observations and later attachments")
        let reviewDiff = String(repeating: "x", count: 30_000) + "new transfer tests"
        try require(MaintainTierCFixer.boundedReviewDiff(reviewDiff) == reviewDiff, "review silently omitted a medium change")
        try require(MaintainTierCFixer.boundedReviewDiff(String(repeating: "x", count: 70_000)).contains("DIFF TRUNCATED"), "oversized review did not disclose truncation")
        try await command("git init -b saved && git config user.email fixture@example.invalid && git config user.name Fixture")
        for scenario in ["command-failed", "still-dirty", "status-warning", "clean"] {
            var active = held
            active.requiresReviewBeforeRecovery = false
            OnDemandEditInterruptedRunRecovery.remember(active, recordPath: recoveryPath)
            var statusCalls = 0
            let outcome = OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: recoveryPath, gitRunner: { arguments, _ in
                if arguments.first == "rev-parse" { return .init(exitCode: 0, output: active.baseCommit) }
                if arguments.first == "status" {
                    statusCalls += 1
                    if statusCalls == 1 || scenario == "still-dirty" { return .init(exitCode: 0, output: " M source.txt\n") }
                    return .init(exitCode: 0, output: scenario == "status-warning" ? "warning: status unavailable" : "")
                }
                return .init(exitCode: scenario == "command-failed" ? 1 : 0, output: "")
            })
            if scenario == "clean" {
                if case .revertedIrisOwnEdits = outcome {} else { throw NSError(domain: "clean-recovery-refused", code: 1) }
                try require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: recoveryPath) == nil, "completed recovery record not cleared")
            } else {
                if case .leftAlone = outcome {} else { throw NSError(domain: "incomplete-recovery-reported-success", code: 1) }
                try require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: recoveryPath) != nil, "incomplete recovery lost record")
            }
        }
        print("PASS recovery requires successful path commands and confirmed clean source before clearing record")
        let source = clone.appendingPathComponent("source.txt")
        try Data("saved version".utf8).write(to: source)
        try await command("git add source.txt && git commit -m saved")
        guard let identity = await SavedEditDeliveryIdentity.capture(clonePath: clone.path, expectedBranch: "saved") else {
            throw NSError(domain: "clean-source-not-captured", code: 1)
        }
        try require(await identity.stillMatchesSource(), "clean saved source rejected")
        print("PASS exact clean source can be retried")
        try Data("uncommitted".utf8).write(to: source)
        try require(await identity.stillMatchesSource() == false, "dirty source allowed")
        try Data("saved version".utf8).write(to: source)
        let untracked = clone.appendingPathComponent("reader.txt")
        try Data("reader-owned".utf8).write(to: untracked)
        try require(await identity.stillMatchesSource() == false, "untracked work allowed")
        try files.moveItem(at: untracked, to: root.appendingPathComponent("reader-preserved.txt"))
        print("PASS tracked and untracked changes block retry without deleting user work")
        try await command("git switch -c another")
        try require(await identity.stillMatchesSource() == false, "different branch allowed")
        try await command("git switch saved")
        try Data("new committed version".utf8).write(to: source)
        try await command("git add source.txt && git commit -m newer")
        try require(await identity.stillMatchesSource() == false, "newer commit allowed")
        print("PASS branch switches and newer commits block stale delivery")

        let queueURL = root.appendingPathComponent("queue")
        let patch = QueuedPatch(recipeId: "change", signatureId: "change", appSlug: "fixture",
                                branchName: "saved", patchText: "diff", baseCommit: identity.commit, appliedAt: Date())
        let queue = PatchQueue(baseDirectoryURL: queueURL)
        try queue.recordChecked(patch)
        try require(PatchQueue(baseDirectoryURL: queueURL).patches(forAppSlug: "fixture") == [patch], "queue did not survive reload")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        var failed = false
        do { try PatchQueue(baseDirectoryURL: blocked).recordChecked(patch) } catch { failed = true }
        try require(failed, "failed queue write was reported as saved")
        try require(try String(contentsOf: blocked, encoding: .utf8) == "keep", "failed queue write damaged blocking file")
        print("PASS checked queue save survives restart and reports failed storage")
    }
}
