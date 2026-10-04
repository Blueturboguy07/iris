import Foundation
import IrisMobileShellCore

/// SPEC.md R8.9: "a global cap... with 'Free up space' reclaiming at least
/// the reclaimable bytes it displays (oracle: `st_blocks` before and
/// after)."
///
/// Real production code exercised: `NativeShellLibraryCoordinator.pruneStorage`,
/// which delegates to `NativeRevisionStore.pruneStorage()` and
/// `NativeStorageRetentionPolicy.retainedSet` (current/previous/pending/pinned),
/// and `storageUsage(identity:)`, which is itself backed by
/// `NativeStorageBlockMeasurement.allocatedBytes` (real `lstat`, `st_blocks`,
/// not `Data(contentsOf:).count`). The oracle in this scenario is
/// deliberately a SECOND, independent measurement: a plain recursive walk of
/// every regular file actually on disk under the run's library root,
/// measured with that same real `st_blocks` primitive but computed by this
/// scenario itself rather than read back from the coordinator's own report,
/// so a coordinator that reports a reclaim without actually deleting bytes
/// (or that deletes the wrong bytes) is caught.
public final class StorageReclaimScenario: MobileScenario {
    public let id = "storage-reclaim-frees-real-blocks"
    public let title = "Pruning storage frees real st_blocks, at least the promised amount"
    public let seedString = "storage-reclaim-frees-real-blocks"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p3EdgeUser]

    private let appId = "publik.storagereclaimapp"
    private let projectId = "publik.storagereclaimapp.mobile"
    private let revisionCount = 5
    private let packages: [GeneratedPackage]

    public init(scratchRoot: URL) throws {
        let root = scratchRoot.appendingPathComponent("storage-reclaim", isDirectory: true)
        var generated: [GeneratedPackage] = []
        var previousRevisionId: String?
        for index in 0..<revisionCount {
            // Distinct, appreciably sized content per revision (repeated
            // marker text) so each stored revision occupies multiple real
            // disk blocks, not just a handful of bytes that might round to
            // the same `st_blocks` value as its neighbor.
            let content = TestContent.html(
                "storage-reclaim-v\(index)-" + String(repeating: "x", count: 2000 + index * 137)
            )
            let package = try PackageFixture.generate(
                content: content,
                baseRevisionId: previousRevisionId,
                nonce: String(repeating: "8", count: 62) + String(format: "%02d", index),
                appId: appId,
                projectId: projectId,
                displayName: "Storage Reclaim App",
                workDirectory: root.appendingPathComponent("gen-\(index)", isDirectory: true)
            )
            generated.append(package)
            previousRevisionId = package.revisionId
        }
        packages = generated
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        // Independent-verifier fix (2026-09-28): `NativeShellLibraryCoordinator
        // .activateAndCaptureSelection` runs `store.pruneStorage()` itself right
        // after every successful activate ("Bounded storage... runs after a
        // successful activate", see that method's own comment), so a plain
        // sequence of stage+activate calls never accumulates more than
        // current+previous on disk -- there is no "N revisions before an
        // explicit Free-up-space tap" state to observe that way, and the
        // original version of this scenario asserted one anyway (a confirmed
        // defect: `storage-reclaim-all-revisions-stored: expected 6, got 2`,
        // caught by an independent verifier's real `swift test` run, not by
        // this scenario's author, who never got a compile+test confirmation).
        //
        // The real way a person accumulates more than current+previous is a
        // pin (`NativeStorageRetentionPolicy.pinLimit == 2`): pinning an old
        // revision (for example to keep a known-good version around) protects
        // it from the coordinator's automatic post-activate prune. This
        // scenario now pins the two oldest revisions right after staging
        // them, keeps installing and activating past them so they age out of
        // current/previous, confirms they are still on disk (protected only
        // by the pin), then unpins both and calls `pruneStorage` explicitly:
        // that unpin-then-"Free up space" sequence is the real user action
        // SPEC R8.9 describes, and is exactly what should reclaim real bytes.
        for (index, package) in packages.enumerated() {
            let review = try await env.coordinator.reviewImport(packageBytes: package.bytes, expectedIdentity: identity)
            _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
            )
            try await env.coordinator.activate(identity: identity, revisionId: package.revisionId)
            // Pin the two oldest revisions right after each becomes current,
            // before the next activation would otherwise let the coordinator's
            // auto-prune remove it. `pinLimit` is 2, so this is the most this
            // scenario (or a real person) could pin at once.
            if index == 0 || index == 1 {
                try await env.coordinator.pin(identity: identity, revisionId: package.revisionId)
            }
        }

        let pinnedIds = Set([packages[0].revisionId, packages[1].revisionId])
        let currentAndPrevious = Set([packages[revisionCount - 1].revisionId, packages[revisionCount - 2].revisionId])
        let expectedStoredBeforeUnpin = pinnedIds.union(currentAndPrevious)

        let usageBefore = try await env.coordinator.storageUsage(identity: identity)
        try Oracle.requireEqual(
            usageBefore.storedRevisionCount, expectedStoredBeforeUnpin.count,
            "storage-reclaim-pinned-and-recent-revisions-stored", failureClass: .setupPackaging
        )
        try Oracle.require(
            usageBefore.codeAllocatedBytes > 0, "storage-reclaim-before-bytes-positive",
            "expected positive allocated bytes before pruning, got \(usageBefore.codeAllocatedBytes)",
            failureClass: .hostSide
        )

        // Independent ground truth #1: walk the real filesystem ourselves.
        let independentBeforeBytes = try Self.independentAllocatedBytes(under: env.libraryRootURL)
        try Oracle.require(
            independentBeforeBytes > 0, "storage-reclaim-independent-before-bytes-positive",
            "independent disk walk found 0 allocated bytes before pruning under \(env.libraryRootURL.path)",
            failureClass: .hostSide
        )

        // The person decides they no longer need the pinned old versions and
        // unpins both, then taps "Free up space".
        try await env.coordinator.unpin(identity: identity, revisionId: packages[0].revisionId)
        try await env.coordinator.unpin(identity: identity, revisionId: packages[1].revisionId)

        let pruneReport = try await env.coordinator.pruneStorage(identity: identity)
        try Oracle.requireEqual(
            pruneReport.removedRevisionIds.count, pinnedIds.count,
            "storage-reclaim-removes-expected-count", failureClass: .hostSide
        )
        try Oracle.requireEqual(
            pruneReport.removedRevisionIds, pinnedIds,
            "storage-reclaim-removes-exactly-the-unpinned-old-revisions", failureClass: .hostSide
        )
        try Oracle.requireEqual(pruneReport.retainedRevisionIds.count, 2, "storage-reclaim-retains-current-and-previous", failureClass: .hostSide)
        try Oracle.requireEqual(
            pruneReport.retainedRevisionIds, currentAndPrevious,
            "storage-reclaim-retained-set-is-current-and-previous", failureClass: .hostSide
        )

        let usageAfter = try await env.coordinator.storageUsage(identity: identity)
        try Oracle.requireEqual(usageAfter.storedRevisionCount, 2, "storage-reclaim-after-revision-count", failureClass: .hostSide)
        let promisedReclaimedBytes = usageBefore.codeAllocatedBytes - usageAfter.codeAllocatedBytes
        try Oracle.require(
            promisedReclaimedBytes > 0, "storage-reclaim-promised-bytes-positive",
            "coordinator's own before/after codeAllocatedBytes shows no reclaim: before=\(usageBefore.codeAllocatedBytes) after=\(usageAfter.codeAllocatedBytes)",
            failureClass: .hostSide
        )

        // Independent ground truth #2: walk the real filesystem again.
        let independentAfterBytes = try Self.independentAllocatedBytes(under: env.libraryRootURL)
        let independentReclaimedBytes = independentBeforeBytes - independentAfterBytes
        try Oracle.require(
            independentReclaimedBytes >= promisedReclaimedBytes,
            "storage-reclaim-actual-blocks-freed-at-least-promised",
            "independent st_blocks walk freed \(independentReclaimedBytes) bytes, less than the \(promisedReclaimedBytes) bytes the coordinator promised",
            failureClass: .hostSide
        )

        // The app must still open on its current version after pruning.
        let launch = try await env.coordinator.launchActive(identity: identity)
        let content = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(content, "storage-reclaim-v\(revisionCount - 1)"),
            "storage-reclaim-app-still-opens-after-prune", "current version did not open correctly after pruning",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Freeing up space removed \(pruneReport.removedRevisionIds.count) old revisions and actually freed \(independentReclaimedBytes) real disk bytes (promised at least \(promisedReclaimedBytes)).",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Storage Reclaim App freed up space.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "promisedReclaimedBytes": String(promisedReclaimedBytes),
                "independentReclaimedBytes": String(independentReclaimedBytes),
                "removedRevisionCount": String(pruneReport.removedRevisionIds.count),
            ]
        )
    }

    /// Sums real allocated bytes (`st_blocks * 512`, via
    /// `NativeStorageBlockMeasurement`) over every regular file under `root`,
    /// walked directly with `FileManager`, independent of any accounting
    /// `NativeRevisionStore`/`NativeShellLibraryCoordinator` do internally.
    private static func independentAllocatedBytes(under root: URL) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            total += try NativeStorageBlockMeasurement.allocatedBytes(atPath: url.path)
        }
        return total
    }
}
