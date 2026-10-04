import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeUsageServiceTests: XCTestCase {
    func testDefaultIsOffAndRecordPathCreatesNoFiles() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let identity = try NativeUsageIdentity(appId: "iris.usage-test", projectId: "iris.usage-test.mobile")

        XCTAssertEqual(service.snapshot().consentState, .disabled)
        XCTAssertNil(service.binding(for: identity))
        let beforeRecord = service.snapshot()
        let syntheticBinding = NativeUsageBinding(
            identity: identity,
            consentEpoch: 1,
            issuerToken: UUID(),
            leaseToken: UUID()
        )
        XCTAssertEqual(service.record(.catalogLoadAttempt, binding: syntheticBinding), .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.usageRoot.path))
        XCTAssertEqual(service.snapshot(), beforeRecord)
    }

    func testIdentityDecoderRevalidatesStableIdentifiers() throws {
        XCTAssertThrowsError(try NativeUsageIdentity(appId: "Not Allowed", projectId: "ok.project"))
        let invalidJSON = Data(#"{"appId":"../../escape","projectId":"ok.project"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeUsageIdentity.self, from: invalidJSON))
    }

    func testConsentTypedEventsPersistAndRestartWithoutRawErrorOrContentFields() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let identity = try NativeUsageIdentity(appId: "iris.usage-test", projectId: "iris.usage-test.mobile")

        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.catalogLoadAttempt, binding: binding), .accepted)
        XCTAssertEqual(service.record(.catalogLoadOutcome(.success), binding: binding), .accepted)
        XCTAssertEqual(service.record(.openRequest, binding: binding), .accepted)
        XCTAssertEqual(service.record(.openLoadEnded(.failure), binding: binding), .accepted)
        XCTAssertEqual(service.record(.openLoaded, binding: binding), .accepted)
        service.flushForTesting()

        let snapshot = service.snapshot()
        XCTAssertEqual(snapshot.source, .shellHost)
        XCTAssertEqual(snapshot.pendingEventCount, 0)
        XCTAssertEqual(snapshot.retainedRawEventCount, 5)
        XCTAssertEqual(snapshot.counters.accepted, 5)
        XCTAssertEqual(snapshot.dailySummaries.flatMap(\.eventCounts).reduce(0) { $0 + Int($1.count) }, 5)

        let rawStore = try String(contentsOf: fixture.usageRoot.appendingPathComponent("store.json"), encoding: .utf8)
        XCTAssertFalse(rawStore.contains("NSError"))
        XCTAssertFalse(rawStore.contains("properties"))
        XCTAssertFalse(rawStore.contains("path"))
        XCTAssertFalse(rawStore.contains("url"))

        let restarted = fixture.makeService()
        let restartedSnapshot = restarted.snapshot()
        XCTAssertEqual(restartedSnapshot.consentState, .enabled)
        XCTAssertEqual(restartedSnapshot.retainedRawEventCount, 5)
        XCTAssertEqual(restartedSnapshot.counters.accepted, 5)
    }

    func testBindingCannotCrossServiceIssuerEvenAtSameEpoch() throws {
        let first = try UsageFixture()
        let second = try UsageFixture()
        defer {
            first.cleanup()
            second.cleanup()
        }
        let identity = try NativeUsageIdentity(appId: "iris.binding-test", projectId: "iris.binding-test.mobile")
        let serviceA = first.makeService()
        let serviceB = second.makeService()
        try serviceA.grantConsent()
        try serviceB.grantConsent()
        let bindingA = try XCTUnwrap(serviceA.binding(for: identity))
        XCTAssertEqual(bindingA.consentEpoch, try XCTUnwrap(serviceB.binding(for: identity)).consentEpoch)

        XCTAssertEqual(serviceB.record(.downloadAttempt, binding: bindingA), .staleConsentEpoch)
        serviceB.flushForTesting()
        XCTAssertEqual(serviceB.snapshot().counters.droppedStaleConsentEpoch, 1)
    }

    func testRegrantAfterRevokeCannotABAOldBinding() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let identity = try NativeUsageIdentity(appId: "iris.aba-test", projectId: "iris.aba-test.mobile")
        try service.grantConsent()
        let original = try XCTUnwrap(service.binding(for: identity))
        try service.revokeAndDelete()
        try service.grantConsent()
        let replacement = try XCTUnwrap(service.binding(for: identity))

        XCTAssertNotEqual(original, replacement)
        XCTAssertEqual(service.record(.activateAttempt, binding: original), .staleConsentEpoch)
        XCTAssertEqual(service.record(.activateAttempt, binding: replacement), .accepted)
    }

    func testPauseClearsPendingAndResumeInvalidatesOldBindingWithoutDeferredOffCounts() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService(flushDelay: .milliseconds(50))
        let identity = try NativeUsageIdentity(appId: "iris.pause-test", projectId: "iris.pause-test.mobile")
        try service.grantConsent()
        let oldBinding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.stageAttempt, binding: oldBinding), .accepted)
        XCTAssertEqual(service.snapshot().pendingEventCount, 1)

        try service.pause()
        let pausedSnapshotBeforeRecord = service.snapshot()
        XCTAssertEqual(service.snapshot().consentState, .paused)
        XCTAssertEqual(service.snapshot().pendingEventCount, 0)
        XCTAssertEqual(service.record(.stageAttempt, binding: oldBinding), .paused)
        XCTAssertEqual(service.snapshot(), pausedSnapshotBeforeRecord)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(service.snapshot().retainedRawEventCount, 0)

        try service.resume()
        XCTAssertEqual(service.record(.stageAttempt, binding: oldBinding), .staleConsentEpoch)
        let newBinding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertNotEqual(newBinding.consentEpoch, oldBinding.consentEpoch)
        XCTAssertEqual(service.record(.stageAttempt, binding: newBinding), .accepted)
        service.flushForTesting()
        let resumed = service.snapshot()
        XCTAssertEqual(resumed.counters.suppressedPaused, 0)
        XCTAssertEqual(resumed.counters.pendingClearedOnPause, 0)
        XCTAssertEqual(resumed.counters.droppedStaleConsentEpoch, 1)
        XCTAssertEqual(resumed.retainedRawEventCount, 1)
    }

    func testGrantConsentWhilePausedActsAsResumeWithoutDeadlock() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let identity = try NativeUsageIdentity(appId: "iris.pause-grant", projectId: "iris.pause-grant.mobile")
        try service.grantConsent()
        let first = try XCTUnwrap(service.binding(for: identity))
        try service.pause()
        try service.grantConsent()
        let second = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.snapshot().consentState, .enabled)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(service.record(.reviewAttempt, binding: first), .staleConsentEpoch)
        XCTAssertEqual(service.record(.reviewAttempt, binding: second), .accepted)
    }

    func testRepeatedPauseDoesNotLeakCommitLock() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.grantConsent()
        try service.pause()
        try service.pause()
        try service.deleteLocalData()
        XCTAssertEqual(service.snapshot().consentState, .paused)
        try service.resume()
        XCTAssertEqual(service.snapshot().consentState, .enabled)
    }

    func testPauseWinsAgainstFlushThatHasReducedButNotCommitted() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let reachedPrecommit = DispatchSemaphore(value: 0)
        let releasePrecommit = DispatchSemaphore(value: 0)
        let service = fixture.makeService(
            flushDelay: .seconds(60),
            beforeStoreCommit: {
                reachedPrecommit.signal()
                _ = releasePrecommit.wait(timeout: .now() + 5)
            }
        )
        let identity = try NativeUsageIdentity(appId: "iris.pause-race", projectId: "iris.pause-race.mobile")
        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.stageAttempt, binding: binding), .accepted)

        let flushFinished = expectation(description: "flush finished")
        DispatchQueue.global().async {
            service.flushForTesting()
            flushFinished.fulfill()
        }
        XCTAssertEqual(reachedPrecommit.wait(timeout: .now() + 5), .success)

        let pauseFinished = expectation(description: "pause finished")
        DispatchQueue.global().async {
            do {
                try service.pause()
            } catch {
                XCTFail("pause failed: \(error)")
            }
            pauseFinished.fulfill()
        }
        let pausedVisible = expectation(description: "paused visible")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if service.snapshot().consentState == .paused {
                    pausedVisible.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        wait(for: [pausedVisible], timeout: 3)
        releasePrecommit.signal()
        wait(for: [flushFinished, pauseFinished], timeout: 5)

        XCTAssertEqual(service.snapshot().retainedRawEventCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.usageRoot.appendingPathComponent("store.json").path))
    }

    func testRevokeCancelsPendingWriterAndCannotRepopulateDeletedStore() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService(flushDelay: .milliseconds(30))
        let identity = try NativeUsageIdentity(appId: "iris.revoke-test", projectId: "iris.revoke-test.mobile")
        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.activateAttempt, binding: binding), .accepted)

        try service.revokeAndDelete()
        Thread.sleep(forTimeInterval: 0.08)
        let snapshot = service.snapshot()
        XCTAssertEqual(snapshot.consentState, .disabled)
        XCTAssertEqual(snapshot.retainedRawEventCount, 0)
        XCTAssertEqual(snapshot.retainedSummaryDayCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.usageRoot.path))

        let restarted = fixture.makeService()
        XCTAssertEqual(restarted.snapshot().consentState, .disabled)
        XCTAssertNil(restarted.binding(for: identity))
    }

    func testDeleteDataPreservesValidConsentButRotatesEpochAndClearsEvidence() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let identity = try NativeUsageIdentity(appId: "iris.delete-test", projectId: "iris.delete-test.mobile")
        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.reviewAttempt, binding: binding), .accepted)
        service.flushForTesting()
        XCTAssertEqual(service.snapshot().retainedRawEventCount, 1)

        try service.deleteLocalData()
        let afterDelete = service.snapshot()
        XCTAssertEqual(afterDelete.consentState, .enabled)
        XCTAssertEqual(afterDelete.retainedRawEventCount, 0)
        XCTAssertEqual(afterDelete.retainedSummaryDayCount, 0)
        XCTAssertEqual(afterDelete.counters, NativeUsageCounters())
        XCTAssertEqual(service.record(.reviewAttempt, binding: binding), .staleConsentEpoch)
        XCTAssertNotNil(service.binding(for: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.usageRoot.appendingPathComponent("store.json").path))
    }

    func testRateQueueCardinalityAndEncodedByteBoundsAreExplicit() throws {
        var limits = NativeUsageLimits.production
        limits.maximumIdentityEventsPerMinute = 2
        limits.maximumGlobalEventsPerMinute = 20
        limits.maximumPendingEvents = 10
        let rateFixture = try UsageFixture()
        defer { rateFixture.cleanup() }
        let rateService = rateFixture.makeService(limits: limits, flushDelay: .seconds(60))
        let identity = try NativeUsageIdentity(appId: "iris.rate-test", projectId: "iris.rate-test.mobile")
        try rateService.grantConsent()
        let rateBinding = try XCTUnwrap(rateService.binding(for: identity))
        XCTAssertEqual(rateService.record(.downloadAttempt, binding: rateBinding), .accepted)
        XCTAssertEqual(rateService.record(.downloadAttempt, binding: rateBinding), .accepted)
        XCTAssertEqual(rateService.record(.downloadAttempt, binding: rateBinding), .rateLimited)
        rateService.flushForTesting()
        XCTAssertEqual(rateService.snapshot().counters.droppedRateLimited, 1)

        var queueLimits = NativeUsageLimits.production
        queueLimits.maximumPendingEvents = 2
        queueLimits.maximumIdentityEventsPerMinute = 100
        let queueFixture = try UsageFixture()
        defer { queueFixture.cleanup() }
        let queueService = queueFixture.makeService(limits: queueLimits, flushDelay: .seconds(60))
        try queueService.grantConsent()
        let queueBinding = try XCTUnwrap(queueService.binding(for: identity))
        XCTAssertEqual(queueService.record(.downloadAttempt, binding: queueBinding), .accepted)
        XCTAssertEqual(queueService.record(.downloadAttempt, binding: queueBinding), .accepted)
        XCTAssertEqual(queueService.record(.downloadAttempt, binding: queueBinding), .queueFull)

        var cardinalityLimits = NativeUsageLimits.production
        cardinalityLimits.maximumDistinctIdentities = 1
        let cardinalityFixture = try UsageFixture()
        defer { cardinalityFixture.cleanup() }
        let cardinalityService = cardinalityFixture.makeService(limits: cardinalityLimits, flushDelay: .seconds(60))
        try cardinalityService.grantConsent()
        let firstIdentity = try NativeUsageIdentity(appId: "iris.one", projectId: "iris.one.mobile")
        let secondIdentity = try NativeUsageIdentity(appId: "iris.two", projectId: "iris.two.mobile")
        XCTAssertEqual(cardinalityService.record(.reviewAttempt, binding: try XCTUnwrap(cardinalityService.binding(for: firstIdentity))), .accepted)
        XCTAssertEqual(cardinalityService.record(.reviewAttempt, binding: try XCTUnwrap(cardinalityService.binding(for: secondIdentity))), .cardinalityLimit)

        var byteLimits = NativeUsageLimits.production
        byteLimits.maximumEventBytes = 32
        let byteFixture = try UsageFixture()
        defer { byteFixture.cleanup() }
        let byteService = byteFixture.makeService(limits: byteLimits, flushDelay: .seconds(60))
        try byteService.grantConsent()
        let byteBinding = try XCTUnwrap(byteService.binding(for: identity))
        XCTAssertEqual(byteService.record(.openRequest, binding: byteBinding), .oversize)
    }

    func testRawAgeAndByteEvictionKeepSummaryAndExposeLossCounters() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let clock = UsageClock(Date(timeIntervalSince1970: 1_800_000_000))
        var limits = NativeUsageLimits.production
        limits.maximumRawBytes = 420
        let service = fixture.makeService(limits: limits, now: { clock.value })
        let identity = try NativeUsageIdentity(appId: "iris.loss-test", projectId: "iris.loss-test.mobile")
        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))
        for _ in 0..<4 {
            XCTAssertEqual(service.record(.catalogLoadAttempt, binding: binding), .accepted)
        }
        service.flushForTesting()
        var snapshot = service.snapshot()
        XCTAssertLessThanOrEqual(snapshot.retainedRawBytes, limits.maximumRawBytes)
        XCTAssertGreaterThan(snapshot.counters.rawEventsEvictedForStorage, 0)
        XCTAssertEqual(snapshot.dailySummaries.flatMap(\.eventCounts).reduce(0) { $0 + Int($1.count) }, 4)

        clock.value = clock.value.addingTimeInterval(25 * 60 * 60)
        let currentBinding = try XCTUnwrap(service.binding(for: identity))
        XCTAssertEqual(service.record(.closeAttempt, binding: currentBinding), .accepted)
        service.flushForTesting()
        snapshot = service.snapshot()
        XCTAssertGreaterThan(snapshot.counters.rawEventsExpired + snapshot.counters.rawEventsEvictedForStorage, 0)
        XCTAssertLessThanOrEqual(snapshot.retainedRawBytes, limits.maximumRawBytes)
    }

    func testCorruptConfigurationIsUnknownAndNotSilentlyOverwritten() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.grantConsent()
        let configURL = fixture.usageRoot.appendingPathComponent("consent.json")
        try Data("{broken".utf8).write(to: configURL, options: [.atomic])

        let restarted = fixture.makeService()
        XCTAssertEqual(restarted.snapshot().consentState, .unknown)
        XCTAssertEqual(restarted.snapshot().storeHealth, .corruptConfiguration)
        XCTAssertThrowsError(try restarted.grantConsent()) { error in
            XCTAssertEqual(error as? NativeUsageError, .corruptLocalState)
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "{broken")

        try restarted.revokeAndDelete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.usageRoot.path))
        XCTAssertEqual(fixture.makeService().snapshot().consentState, .disabled)
    }

    func testOversizedStoreIsRejectedBeforeDecodeAndLeftUntouched() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.grantConsent()
        let storeURL = fixture.usageRoot.appendingPathComponent("store.json")
        let tooLarge = NativeUsagePersistence.maximumStoreFileBytes(limits: .production) + 1
        let oversized = Data(repeating: 0x61, count: tooLarge)
        try oversized.write(to: storeURL, options: [.atomic])

        let restarted = fixture.makeService()
        XCTAssertEqual(restarted.snapshot().storeHealth, .corruptStore)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.intValue, tooLarge)
        XCTAssertNil(restarted.binding(for: try NativeUsageIdentity(appId: "iris.big-store", projectId: "iris.big-store.mobile")))
    }

    func testCorruptRawAndSummaryClockEdgesAreRejectedWithoutArithmeticOverflow() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        try service.grantConsent()
        let storeURL = fixture.usageRoot.appendingPathComponent("store.json")

        let rawEdge: [String: Any] = [
            "schemaVersion": 1,
            "nextSequence": 2,
            "rawEvents": [[
                "schemaVersion": 1,
                "sequence": 1,
                "minuteBucketUTC": Int64.min,
                "consentEpoch": 1,
                "source": "shellHost",
                "identity": ["appId": "iris.clock-edge", "projectId": "iris.clock-edge.mobile"],
                "eventKind": "openRequest",
            ]],
            "dailySummaries": [],
        ]
        try JSONSerialization.data(withJSONObject: rawEdge, options: [.sortedKeys]).write(to: storeURL, options: [.atomic])
        XCTAssertEqual(fixture.makeService().snapshot().storeHealth, .corruptStore)

        let summaryEdge: [String: Any] = [
            "schemaVersion": 1,
            "nextSequence": 1,
            "rawEvents": [],
            "dailySummaries": [[
                "dayOrdinalUTC": Int64.min,
                "eventCounts": [],
                "counters": countersJSONObject(),
            ]],
        ]
        try JSONSerialization.data(withJSONObject: summaryEdge, options: [.sortedKeys]).write(to: storeURL, options: [.atomic])
        XCTAssertEqual(fixture.makeService().snapshot().storeHealth, .corruptStore)
    }

    func testPartialFlushPersistsAcceptedCountOnlyForCommittedBatch() throws {
        let fixture = try UsageFixture()
        defer { fixture.cleanup() }
        let reachedFirstPrecommit = DispatchSemaphore(value: 0)
        let releaseFirstPrecommit = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var hookCount = 0
        var limits = NativeUsageLimits.production
        limits.maximumIdentityEventsPerMinute = 1_000
        limits.maximumGlobalEventsPerMinute = 1_000
        let service = fixture.makeService(
            limits: limits,
            flushDelay: .seconds(60),
            beforeStoreCommit: {
                hookLock.lock()
                hookCount += 1
                let isFirst = hookCount == 1
                hookLock.unlock()
                if isFirst {
                    reachedFirstPrecommit.signal()
                    _ = releaseFirstPrecommit.wait(timeout: .now() + 5)
                }
            }
        )
        let identity = try NativeUsageIdentity(appId: "iris.partial-flush", projectId: "iris.partial-flush.mobile")
        try service.grantConsent()
        let binding = try XCTUnwrap(service.binding(for: identity))

        for _ in 0..<256 {
            XCTAssertEqual(service.record(.catalogLoadAttempt, binding: binding), .accepted)
        }
        XCTAssertEqual(reachedFirstPrecommit.wait(timeout: .now() + 5), .success)
        for _ in 0..<44 {
            XCTAssertEqual(service.record(.catalogLoadAttempt, binding: binding), .accepted)
        }
        releaseFirstPrecommit.signal()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, service.snapshot().retainedRawEventCount < 256 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let live = service.snapshot()
        XCTAssertEqual(live.retainedRawEventCount, 256)
        XCTAssertEqual(live.pendingEventCount, 44)
        XCTAssertEqual(live.counters.accepted, 300)

        // A fresh process would only recover the committed batch. It must not
        // claim the 44 still-memory-only observations were durably accepted.
        let restarted = fixture.makeService(flushDelay: .seconds(60))
        XCTAssertEqual(restarted.snapshot().retainedRawEventCount, 256)
        XCTAssertEqual(restarted.snapshot().counters.accepted, 256)
    }
}

private func countersJSONObject() -> [String: UInt64] {
    [
        "accepted": 0,
        "droppedStaleConsentEpoch": 0,
        "droppedRateLimited": 0,
        "droppedQueueFull": 0,
        "droppedCardinalityLimit": 0,
        "droppedOversize": 0,
        "droppedStoreUnavailable": 0,
        "suppressedDisabled": 0,
        "suppressedPaused": 0,
        "pendingClearedOnPause": 0,
        "pendingDeleted": 0,
        "rawEventsExpired": 0,
        "rawEventsEvictedForStorage": 0,
        "summaryDaysExpired": 0,
        "summaryDaysEvictedForStorage": 0,
        "summaryDetailDropped": 0,
    ]
}

private final class UsageClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private final class UsageFixture {
    let root: URL
    let usageRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-usage-tests-\(UUID().uuidString)", isDirectory: true)
        usageRoot = root.appendingPathComponent("usage-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeService(
        limits: NativeUsageLimits = .production,
        now: @escaping () -> Date = Date.init,
        flushDelay: DispatchTimeInterval = .seconds(5),
        beforeStoreCommit: (() -> Void)? = nil
    ) -> NativeUsageService {
        NativeUsageService(
            rootURL: usageRoot,
            limits: limits,
            now: now,
            flushDelay: flushDelay,
            beforeStoreCommit: beforeStoreCommit
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
