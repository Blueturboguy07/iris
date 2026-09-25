//
//  AppRelaunchInstalledDeliveryTests.swift
//  leanring-buddyTests
//
//  The pure decision logic behind the founder's Sep 2 2026 override: after a
//  green build, the fresh copy is installed OVER the reader's installed app
//  rather than launched from the clone's build dir. The two things worth
//  pinning here are which copy counts as "the installed app to replace"
//  (never the clone's own build output; /Applications wins) and where the
//  pre-delivery snapshot for undo is kept. The ditto/replace filesystem work
//  itself has no unit coverage for the same reason the rest of this service
//  does not — the harness cannot copy real app bundles — so it stays a
//  supervised dogfood, like the relaunch mechanics above it.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite struct AppRelaunchInstalledDeliveryTests {

    @Test func filesystemResolutionPrefersEligibleRunningCopyAndRefusesAmbiguity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-target-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let bundleId = "com.iris.test.resolution"
        let active = root.appendingPathComponent("active/Demo.app").path
        let stale = root.appendingPathComponent("stale/Demo.app").path
        let applications = root.appendingPathComponent("Applications/Demo.app").path
        let build = clone.appendingPathComponent("Demo.app").path
        let wrong = root.appendingPathComponent("wrong/Demo.app").path
        for path in [active, stale, applications, build] {
            Self.makeFakeBundle(at: path, marker: "bundle", bundleIdentifier: bundleId)
        }
        Self.makeFakeBundle(at: wrong, marker: "wrong", bundleIdentifier: "com.iris.test.other")

        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        func resolve(_ running: [String?], _ app: String? = nil, _ registered: String? = nil,
                     _ cloneOverride: String? = nil) -> AppRelaunchService.InstalledDeliveryTargetResolution {
            AppRelaunchService.resolveInstalledDeliveryTarget(
                bundleId: bundleId,
                registeredPath: registered,
                applicationsPath: app,
                runningPaths: running,
                clonePath: cloneOverride ?? clone.path
            )
        }
        func isRejected(_ value: AppRelaunchService.InstalledDeliveryTargetResolution) -> Bool {
            if case .rejected = value { return true }
            return false
        }

        #expect(resolve([active], nil, stale) == .selected(path: canonical(active)))
        #expect(resolve([], nil, stale) == .selected(path: canonical(stale)))
        #expect(resolve([build], build, build) == .absent)
        #expect(resolve([build], nil, stale) == .selected(path: canonical(stale)))
        #expect(isRejected(resolve([active, stale])))
        #expect(isRejected(resolve([active], applications)))
        #expect(isRejected(resolve([wrong])))
        #expect(isRejected(resolve([nil])))
        #expect(isRejected(resolve([nil], applications, stale)))
        #expect(isRejected(resolve([active, nil], nil, stale)))
        #expect(resolve([], applications, stale) == .selected(path: canonical(applications)))
        #expect(resolve([applications], applications, stale) == .selected(path: canonical(applications)))
        #expect(isRejected(resolve([], wrong)))
        #expect(isRejected(resolve([], nil, wrong)))
        #expect(resolve([], wrong, stale) == .selected(path: canonical(stale)))
        #expect(resolve([], applications, wrong) == .selected(path: canonical(applications)))

        let missingRegistered = root.appendingPathComponent("stale-missing/Demo.app").path
        #expect(resolve([], nil, missingRegistered) == .absent)
        let danglingRegistered = root.appendingPathComponent("Dangling.app")
        try FileManager.default.createSymbolicLink(
            atPath: danglingRegistered.path,
            withDestinationPath: root.appendingPathComponent("missing-target/Demo.app").path
        )
        #expect(isRejected(resolve([], nil, danglingRegistered.path)))

        let alias = root.appendingPathComponent("active-alias")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: root.appendingPathComponent("active")
        )
        #expect(resolve([active, alias.appendingPathComponent("Demo.app").path])
                == .selected(path: canonical(active)))
        let bundleSymlink = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(atPath: bundleSymlink.path, withDestinationPath: active)
        #expect(isRejected(resolve([bundleSymlink.path])))
        #expect(isRejected(resolve([bundleSymlink.path], applications, stale)))
        #expect(isRejected(resolve([active, bundleSymlink.path], nil, stale)))
        let cloneAlias = root.appendingPathComponent("clone-alias")
        try FileManager.default.createSymbolicLink(at: cloneAlias, withDestinationURL: clone)
        #expect(resolve([cloneAlias.appendingPathComponent("Demo.app").path]) == .absent)
        #expect(isRejected(resolve([active], nil, nil, cloneAlias.path)))

        let cloneRootApp = root.appendingPathComponent("clone-root-app/Demo.app")
        Self.makeFakeBundle(at: cloneRootApp.path, marker: "clone-root", bundleIdentifier: bundleId)
        #expect(AppRelaunchService.resolveInstalledDeliveryTarget(
            bundleId: bundleId,
            registeredPath: cloneRootApp.path,
            applicationsPath: cloneRootApp.path,
            runningPaths: [cloneRootApp.path],
            clonePath: cloneRootApp.path
        ) == .absent)
    }

    @Test func installRejectsFreshBundleWhoseIdentifierDoesNotMatchRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delivery-rejected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clonePath = root.appendingPathComponent("clone").path
        let freshBuildPath = root.appendingPathComponent("clone/build/Demo.app").path
        try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
        Self.makeFakeBundle(
            at: freshBuildPath,
            marker: "fresh",
            bundleIdentifier: "com.iris.test.actual"
        )

        let result = await AppRelaunchService().installFreshBuildOverInstalledApp(
            macBundleId: "com.iris.test.requested",
            freshBuildArtifactPath: freshBuildPath,
            clonePath: clonePath
        )
        if case .deliveryRejected = result { return }
        Issue.record("A mismatched bundle must be rejected before any installed-copy fallback")
    }

    @Test func blockedRebuildEntryPointRejectsWithoutRelaunchAndAllowsSuccessfulControl() async throws {
        let rejected = try await Self.exerciseDeliveryCaller(
            deliveryResult: .deliveryRejected(reason: "the fixture was not an eligible delivery target")
        )
        #expect(rejected.deliveryCallCount == 1)
        #expect(rejected.relaunchCalls.isEmpty)
        #expect(rejected.statusLine?.contains("delivery was refused") == true)

        // Control: the same public caller must reach the relaunch callback
        // when delivery approves the build artifact.
        let successful = try await Self.exerciseDeliveryCaller(
            deliveryResult: .noInstalledCopyToReplace
        )
        #expect(successful.deliveryCallCount == 1)
        #expect(successful.relaunchCalls.count == 1)
        #expect(successful.relaunchCalls.first?.appSlug == "resolver-fixture")
        #expect(successful.relaunchCalls.first?.path == successful.artifactPath)
        #expect(successful.relaunchCalls.first?.allowForceQuit == false)
    }

    @Test func automaticDeliveryCallerRejectsWithoutRelaunchAndAllowsSuccessfulControl() async throws {
        let rejected = try await Self.exerciseDeliveryCaller(
            deliveryResult: .deliveryRejected(reason: "the fixture was not an eligible delivery target"),
            automaticallyApplyEdit: true
        )
        #expect(rejected.deliveryCallCount == 1)
        #expect(rejected.relaunchCalls.isEmpty)
        #expect(rejected.statusLine?.contains("delivery was refused") == true)

        // The same ordinary edit path must reach its injected launch callback
        // when delivery returns a valid no-installed-copy outcome.
        let successful = try await Self.exerciseDeliveryCaller(
            deliveryResult: .noInstalledCopyToReplace,
            automaticallyApplyEdit: true
        )
        #expect(successful.deliveryCallCount == 1)
        #expect(successful.relaunchCalls.count == 1)
        #expect(successful.relaunchCalls.first?.appSlug == "resolver-fixture")
        #expect(successful.relaunchCalls.first?.path == successful.artifactPath)
        #expect(successful.relaunchCalls.first?.allowForceQuit == false)
    }

    /// The undo snapshot lives under Application Support, keyed by a
    /// filesystem-safe form of the bundle id, and keeps the app's own bundle
    /// name so the restored copy is recognizably itself.
    @Test func deliveryBackupPathIsKeyedByBundleIdUnderApplicationSupport() {
        let backupPath = AppRelaunchService.deliveryBackupPath(
            forBundleId: "com.whimpr.whimprflow", appBundleName: "WhimprFlow.app"
        )
        #expect(backupPath.contains("Application Support/Iris/edit-delivery-backups"))
        #expect(backupPath.contains("com.whimpr.whimprflow"))
        #expect(backupPath.hasSuffix("WhimprFlow.app"))
    }

    // MARK: - Live filesystem round-trip (the real ditto + replaceItemAt swap)

    private struct RelaunchCall {
        let appSlug: String
        let path: String
        let allowForceQuit: Bool
    }

    private struct DeliveryObservation {
        let artifactPath: String
        let deliveryCallCount: Int
        let relaunchCalls: [RelaunchCall]
        let statusLine: String?
    }

    /// Drives public app selection, description, plan approval, and either the
    /// injected blocked-rebuild entrypoint or ordinary automatic-delivery path.
    /// The source clone, defaults, queue, run log, memory, and recovery record
    /// are isolated under a disposable cache directory.
    private static func exerciseDeliveryCaller(
        deliveryResult: AppRelaunchService.InstalledDeliveryResult,
        automaticallyApplyEdit: Bool = false
    ) async throws -> DeliveryObservation {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/IrisResolverCoordinatorTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = root.appendingPathComponent("clone")
        let artifactPath = root.appendingPathComponent("Build/ResolverFixture.app").path
        let defaultsSuite = "iris.resolver.coordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try Self.initializeCleanGitRepository(at: clone)

        let provenance = InstallProvenanceStore(userDefaults: defaults)
        provenance.recordGuideSourceClone(
            appSlug: "resolver-fixture", clonePath: clone.path,
            pinnedCommit: nil, canonicalRepo: nil
        )
        let coordinator = OnDemandEditCoordinator(
            installProvenanceStore: provenance,
            patchQueue: PatchQueue(baseDirectoryURL: root.appendingPathComponent("patch-queue")),
            clonePathLock: MaintainClonePathLock(),
            probeRequestTriggers: { _, _ in .allQuiet },
            modelProviderIsAvailable: { true },
            editSandboxIsAvailable: { true },
            runLogDirectoryPath: root.appendingPathComponent("run-logs").path,
            memoryIndexDirectoryPath: root.appendingPathComponent("run-memory").path,
            interruptedRunRecordPath: root.appendingPathComponent("in-flight.json").path,
            performOnDemandEdit: { _, _, _, _, _, _, _, _, _, _, _ in
                if automaticallyApplyEdit {
                    return .appliedAndRebuilt(
                        branchName: "codex/resolver-test",
                        changeId: "resolver-test",
                        kind: .bugFix,
                        suitePassed: nil
                    )
                }
                return .blockedByModel(explanation: "the fixture edit is blocked", questionForUser: nil)
            }
        )
        coordinator.relaunchIsAvailableForApp = { _ in true }
        coordinator.packageEditedAppFromClone = { _ in
            .artifactReady(artifactPath: artifactPath, signingSummary: "isolated test artifact")
        }
        var deliveryCallCount = 0
        coordinator.deliverEditedAppOverInstalledApp = { _, _ in
            deliveryCallCount += 1
            return deliveryResult
        }
        var relaunchCalls: [RelaunchCall] = []
        coordinator.terminateAndRelaunchEditedApp = { appSlug, path, allowForceQuit in
            relaunchCalls.append(RelaunchCall(
                appSlug: appSlug, path: path, allowForceQuit: allowForceQuit
            ))
            // Stop the production flow at the injected callback; no actual app
            // lookup, termination, or launch occurs in this test.
            return .ineligible(reason: "isolated test callback")
        }

        coordinator.pickApp(slug: "resolver-fixture", name: "Fixture", stack: .tauri)
        #expect(coordinator.phase == .describe)
        #expect(coordinator.describeRequest("the fixture is blocked", kind: .bugFix))

        let reachedDescribeDecision = await Self.waitUntil {
            switch coordinator.phase {
            case .clarifying, .presentingPlan:
                return true
            default:
                return false
            }
        }
        #expect(reachedDescribeDecision)
        guard reachedDescribeDecision else {
            return DeliveryObservation(
                artifactPath: artifactPath, deliveryCallCount: deliveryCallCount,
                relaunchCalls: relaunchCalls, statusLine: coordinator.statusLine
            )
        }

        if case .clarifying = coordinator.phase {
            var answers: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                let choice: String?
                switch question.trigger {
                case .requiredInfoAbsentFromRepo:
                    choice = question.options.first {
                        $0.hasPrefix("Make the edit anyway — I accept a lower verification level")
                    }
                case .runtimeShapeDecision:
                    choice = question.options.first
                case .ambiguousAmongImplementations, .irreversibleOrCostlyAction:
                    choice = question.options.first {
                        !$0.lowercased().hasPrefix("stop")
                    }
                }
                if let choice { answers[question.id] = choice }
            }
            #expect(answers.count == coordinator.clarificationQuestions.count)
            coordinator.submitClarificationAnswers(answers)
        }

        let reachedPlan = await Self.waitUntil {
            if case .presentingPlan = coordinator.phase { return true }
            return false
        }
        #expect(reachedPlan)
        guard reachedPlan else {
            return DeliveryObservation(
                artifactPath: artifactPath, deliveryCallCount: deliveryCallCount,
                relaunchCalls: relaunchCalls, statusLine: coordinator.statusLine
            )
        }

        coordinator.confirmPlanAndStart()
        if automaticallyApplyEdit {
            // `.appliedAndRebuilt` enters the real automatic delivery path from
            // `confirmStartAndRun`; delivery rejection/success both terminate
            // at `.done` with the relaunch callback fully injected.
        } else {
            let reachedBlock = await Self.waitUntil {
                if case .blockedByModel = coordinator.phase { return true }
                return false
            }
            #expect(reachedBlock)
            guard reachedBlock else {
                return DeliveryObservation(
                    artifactPath: artifactPath, deliveryCallCount: deliveryCallCount,
                    relaunchCalls: relaunchCalls, statusLine: coordinator.statusLine
                )
            }
            coordinator.rebuildAndRelaunchTheBlockedApp()
        }

        let finished = await Self.waitUntil { coordinator.phase == .done }
        #expect(finished)
        return DeliveryObservation(
            artifactPath: artifactPath, deliveryCallCount: deliveryCallCount,
            relaunchCalls: relaunchCalls, statusLine: coordinator.statusLine
        )
    }

    private static func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    private static func initializeCleanGitRepository(at path: URL) throws {
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = path
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ResolverCoordinatorTestGit", code: Int(process.terminationStatus))
            }
        }

        try git(["init", "-q"])
        try git(["config", "user.email", "resolver-test@example.invalid"])
        try git(["config", "user.name", "Resolver Test"])
        try git(["config", "commit.gpgsign", "false"])
        try "fixture\n".write(
            to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try git(["add", "README.md"])
        try git(["commit", "-qm", "fixture base"])
    }

    /// Build a minimal `.app`-shaped directory whose Info.plist marker records a
    /// version, so a swap can be proven by reading which version is at a path.
    private static func makeFakeBundle(
        at path: String, marker: String, bundleIdentifier: String? = nil
    ) {
        let contents = (path as NSString).appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: (contents as NSString).appendingPathComponent("marker.txt"),
            contents: Data(marker.utf8)
        )
        if let bundleIdentifier {
            try? writeInfoPlist(at: path, bundleIdentifier: bundleIdentifier)
        }
    }

    private static func writeInfoPlist(at path: String, bundleIdentifier: String) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
    }

    private static func markerOfBundle(at path: String) -> String? {
        let markerPath = (path as NSString)
            .appendingPathComponent("Contents/marker.txt")
        return (try? String(contentsOfFile: markerPath, encoding: .utf8))
    }

    /// The core the whole delivery rests on, exercised for real: snapshot the
    /// installed bundle, swap the fresh one into its exact path, and prove the
    /// installed path now holds the FRESH build while the snapshot holds the OLD
    /// one — then run the same primitive in reverse (the undo) and prove the
    /// original is back. Real `ditto`, real `replaceItemAt`, real temp bundles;
    /// no model, no network. This is the one corruption-risking primitive, so it
    /// earns a real round trip rather than a mocked one.
    @Test func swappingABundleReplacesItInPlaceAndTheSnapshotRestoresIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delivery-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let installedPath = root.appendingPathComponent("Applications/Demo.app").path
        let freshBuildPath = root.appendingPathComponent("clone/build/Demo.app").path
        let snapshotPath = root.appendingPathComponent("backups/Demo.app").path
        Self.makeFakeBundle(at: installedPath, marker: "installed-v1")
        Self.makeFakeBundle(at: freshBuildPath, marker: "fresh-v2")

        // Deliver: the installed copy becomes the fresh build; the old one is
        // preserved at the snapshot path for undo.
        let delivered = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installedPath, withBundleAt: freshBuildPath, snapshotTo: snapshotPath
        )
        #expect(delivered.isSuccess)
        #expect(Self.markerOfBundle(at: installedPath) == "fresh-v2")
        #expect(Self.markerOfBundle(at: snapshotPath) == "installed-v1")
        // The fresh build the swap consumed is still where it was built — it was
        // ditto-copied, not moved, so verification/other steps can still read it.
        #expect(Self.markerOfBundle(at: freshBuildPath) == "fresh-v2")

        // Undo: the snapshot goes back into the installed path.
        let undone = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installedPath, withBundleAt: snapshotPath, snapshotTo: nil
        )
        #expect(undone.isSuccess)
        #expect(Self.markerOfBundle(at: installedPath) == "installed-v1")
    }

    /// The delivery entry point, run for real against a bundle id that no app on
    /// this machine claims: there is nothing installed to replace, so it reports
    /// that honestly (the caller then launches the build-dir artifact) rather
    /// than inventing a target or failing. Uses a real fresh build on disk so
    /// the early "is the build there" guard is not what returns.
    @Test func installOverInstalledAppReportsNoInstalledCopyForAnUnknownBundleId() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delivery-none-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clonePath = root.appendingPathComponent("clone").path
        let freshBuildPath = root.appendingPathComponent("clone/build/Nope.app").path
        try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
        let unknownBundleId = "com.iris.test.definitely-not-installed-\(UUID().uuidString)"
        Self.makeFakeBundle(
            at: freshBuildPath,
            marker: "fresh",
            bundleIdentifier: unknownBundleId
        )

        let result = await AppRelaunchService().installFreshBuildOverInstalledApp(
            macBundleId: unknownBundleId,
            freshBuildArtifactPath: freshBuildPath,
            clonePath: clonePath
        )
        #expect(result == .noInstalledCopyToReplace)
    }
}
