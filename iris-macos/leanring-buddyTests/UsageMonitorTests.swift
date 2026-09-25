//
//  UsageMonitorTests.swift
//  leanring-buddyTests
//
//  The anonymous usage monitor's promises, each pinned: it counts rather than
//  logs, it sends at most one batch per tick, it drops a batch on ANY failure
//  instead of retrying or storing it, it never lets a send block the next
//  record, and with the switch off it holds and sends nothing.
//

import Foundation
import Testing
@testable import Iris

/// A sender that records what it was given and answers however the test says.
private final class RecordingUsageSender: UsageEventSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBatches: [Data] = []
    private var recordedErasures: [String] = []
    private var heldCompletions: [@Sendable (Bool) -> Void] = []
    /// When false, a batch's completion is held until `finishHeldSends`.
    var completesImmediately = true
    var reportsSuccess = true

    var batches: [Data] { lock.withLock { recordedBatches } }
    var erasures: [String] { lock.withLock { recordedErasures } }

    func sendBatch(_ jsonBody: Data, completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { recordedBatches.append(jsonBody) }
        if completesImmediately {
            completion(reportsSuccess)
        } else {
            lock.withLock { heldCompletions.append(completion) }
        }
    }

    func eraseEverythingSent(byInstallIdentifier installIdentifier: String) {
        lock.withLock { recordedErasures.append(installIdentifier) }
    }

    func finishHeldSends(succeeded: Bool) {
        let completions = lock.withLock { () -> [@Sendable (Bool) -> Void] in
            defer { heldCompletions.removeAll() }
            return heldCompletions
        }
        completions.forEach { $0(succeeded) }
    }
}

/// A switch the test can flip from any thread.
private final class SharingSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOnValue: Bool
    init(isOn: Bool) { isOnValue = isOn }
    var isOn: Bool {
        get { lock.withLock { isOnValue } }
        set { lock.withLock { isOnValue = newValue } }
    }
}

/// A clock the test can move.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowValue: Date
    init(_ start: Date) { nowValue = start }
    var now: Date {
        get { lock.withLock { nowValue } }
        set { lock.withLock { nowValue = newValue } }
    }
}

private let installIdentifierForTests = "3f1b2c4d-1111-2222-3333-abcdefabcdef"
/// 2026-09-25 14:37:12 UTC.
private let aMomentOnTheTwentyFifth = Date(timeIntervalSince1970: 1_790_347_032)

private func makeMonitor(
    sender: RecordingUsageSender,
    sharingSwitch: SharingSwitch = SharingSwitch(isOn: true),
    clock: TestClock = TestClock(aMomentOnTheTwentyFifth),
    irisVersion: String = "0.9.15",
    maximumDistinctCountsHeld: Int = 200
) -> UsageMonitor {
    let monitor = UsageMonitor(workQueue: DispatchQueue(label: "usage-monitor-tests.\(UUID().uuidString)"))
    monitor.configure(UsageMonitor.Configuration(
        isSharingEnabled: { sharingSwitch.isOn },
        installIdentifier: { installIdentifierForTests },
        irisVersion: irisVersion,
        operatingSystem: "macos",
        sender: sender,
        currentDate: { clock.now },
        // Never fires during a test; ticks are driven by sendNowAndWaitForTesting.
        flushInterval: 3600,
        maximumDistinctCountsHeld: maximumDistinctCountsHeld
    ))
    return monitor
}

private func decodedEvents(_ batch: Data) throws -> [[String: Any]] {
    let object = try #require(try JSONSerialization.jsonObject(with: batch) as? [String: Any])
    #expect(object["installId"] as? String == installIdentifierForTests)
    return try #require(object["events"] as? [[String: Any]])
}

@Suite("Usage monitor")
struct UsageMonitorTests {

    // MARK: - Counting and batching

    @Test func repeatsInTheSameHourBecomeOneCountedEntry() throws {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender)
        for _ in 0..<3 { monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue")) }
        monitor.record(UsageEvent(kind: .aiCall, appSlug: "cue", provider: .anthropicKey, modelTier: .smart))
        monitor.sendNowAndWaitForTesting()

        #expect(sender.batches.count == 1)
        let events = try decodedEvents(try #require(sender.batches.first))
        #expect(events.count == 2)
        let opened = try #require(events.first { $0["event"] as? String == "app_opened" })
        #expect(opened["count"] as? Int == 3)
        #expect(opened["appSlug"] as? String == "cue")
        #expect(opened["hourBucket"] as? String == "2026-09-25T14:00:00Z")
        let call = try #require(events.first { $0["event"] as? String == "ai_call" })
        #expect(call["provider"] as? String == "anthropic-key")
        #expect(call["modelTier"] as? String == "smart")
    }

    @Test func aNewHourIsANewCount() throws {
        let sender = RecordingUsageSender()
        let clock = TestClock(aMomentOnTheTwentyFifth)
        let monitor = makeMonitor(sender: sender, clock: clock)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.drainForTesting()
        clock.now = aMomentOnTheTwentyFifth.addingTimeInterval(3600)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()

        let buckets = try decodedEvents(try #require(sender.batches.first)).compactMap { $0["hourBucket"] as? String }
        #expect(Set(buckets) == ["2026-09-25T14:00:00Z", "2026-09-25T15:00:00Z"])
    }

    @Test func nothingIsSentUntilATickAndAnEmptyTickSendsNothing() {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender)
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.isEmpty, "an empty tick must not send an empty batch")

        monitor.record(UsageEvent(kind: .guideStarted, appSlug: "cue"))
        monitor.drainForTesting()
        #expect(sender.batches.isEmpty, "recording must never send by itself")
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 1)
    }

    /// The only fields an event may carry are the ones the server allows —
    /// no title, no path, no model name, no account.
    @Test func aBatchCarriesOnlyTheAllowedFields() throws {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender)
        monitor.record(UsageEvent(kind: .aiCall, appSlug: "cue", provider: .publikAPI, modelTier: .balanced))
        monitor.sendNowAndWaitForTesting()
        let allowedFields: Set<String> = ["event", "appSlug", "provider", "modelTier", "os", "irisVersion", "hourBucket", "count"]
        for event in try decodedEvents(try #require(sender.batches.first)) {
            #expect(Set(event.keys).isSubset(of: allowedFields))
            #expect(event["os"] as? String == "macos")
            #expect(event["irisVersion"] as? String == "0.9.15")
        }
    }

    @Test func aSlugThatIsNotSlugShapedIsNeverSent() throws {
        #expect(UsageEvent(kind: .appOpened, appSlug: "Inbox — someone@example.com").appSlug == nil)
        #expect(UsageEvent(kind: .appOpened, appSlug: "/Users/someone/Projects/secret").appSlug == nil)
        #expect(UsageEvent(kind: .appOpened, appSlug: "whimprflow").appSlug == "whimprflow")
    }

    // MARK: - Dropping

    /// "drops on any failure": a failed batch is not retried, re-queued, or
    /// kept anywhere.
    @Test func aFailedSendIsDroppedNotRetried() {
        let sender = RecordingUsageSender()
        sender.reportsSuccess = false
        let monitor = makeMonitor(sender: sender)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 1)
        monitor.drainForTesting()

        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 1, "the failed batch must not be sent again")
        #expect(monitor.heldCountsForTesting.isEmpty)
    }

    /// A slow send never blocks recording, and the next tick does not stack a
    /// second send on top of one still in flight.
    @Test func aSendInFlightNeverBlocksRecordingAndSkipsTheNextTick() {
        let sender = RecordingUsageSender()
        sender.completesImmediately = false
        let monitor = makeMonitor(sender: sender)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()
        #expect(monitor.aSendIsInFlightForTesting)

        monitor.record(UsageEvent(kind: .appOpened, appSlug: "whimprflow"))
        monitor.drainForTesting()
        #expect(monitor.heldCountsForTesting[UsageEvent(kind: .appOpened, appSlug: "whimprflow")] == 1)

        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 1, "no second send while the first is in flight")

        sender.finishHeldSends(succeeded: false)
        monitor.drainForTesting()
        #expect(!monitor.aSendIsInFlightForTesting)
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 2)
    }

    @Test func pastTheHoldingCapNewEntriesAreDropped() {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender, maximumDistinctCountsHeld: 2)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "one"))
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "two"))
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "three"))
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "one"))
        monitor.drainForTesting()
        let held = monitor.heldCountsForTesting
        #expect(held.count == 2)
        #expect(held[UsageEvent(kind: .appOpened, appSlug: "one")] == 2, "an existing entry still counts up")
        #expect(monitor.droppedEventCountForTesting == 1)
    }

    @Test func oneBatchNeverExceedsTheServerCapAndTheRestIsDropped() throws {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender)
        for index in 0..<(UsageMonitor.largestBatchTheServerAccepts + 5) {
            monitor.record(UsageEvent(kind: .appOpened, appSlug: "app-\(index)"))
        }
        monitor.sendNowAndWaitForTesting()
        #expect(try decodedEvents(try #require(sender.batches.first)).count == UsageMonitor.largestBatchTheServerAccepts)
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.count == 1, "the overflow is dropped, not carried into a backlog")
    }

    @Test func aCountStopsAtWhatTheServerAccepts() throws {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender)
        for _ in 0..<(UsageMonitor.largestCountTheServerAccepts + 20) {
            monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        }
        monitor.sendNowAndWaitForTesting()
        let events = try decodedEvents(try #require(sender.batches.first))
        #expect(events.first?["count"] as? Int == UsageMonitor.largestCountTheServerAccepts)
    }

    // MARK: - Off means off

    @Test func withTheSwitchOffNothingIsHeldOrSent() {
        let sender = RecordingUsageSender()
        let sharingSwitch = SharingSwitch(isOn: false)
        let monitor = makeMonitor(sender: sender, sharingSwitch: sharingSwitch)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()
        #expect(monitor.heldCountsForTesting.isEmpty)
        #expect(sender.batches.isEmpty)
    }

    @Test func turningTheSwitchOffThrowsAwayWhatIsHeldAndAsksTheServerToForget() {
        let sender = RecordingUsageSender()
        let sharingSwitch = SharingSwitch(isOn: true)
        let monitor = makeMonitor(sender: sender, sharingSwitch: sharingSwitch)
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.drainForTesting()

        sharingSwitch.isOn = false
        monitor.sharingWasTurnedOff()
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.isEmpty)
        #expect(monitor.heldCountsForTesting.isEmpty)
        #expect(sender.erasures == [installIdentifierForTests])
    }

    /// Before `configure` the shared monitor is inert: a call site that fires
    /// before launch finishes records nothing and crashes nothing.
    @Test func anUnconfiguredMonitorIgnoresEverything() {
        let monitor = UsageMonitor(workQueue: DispatchQueue(label: "unconfigured.\(UUID().uuidString)"))
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()
        #expect(monitor.heldCountsForTesting.isEmpty)
    }

    // MARK: - Wire helpers

    @Test func theHourBucketIsTheUTCHour() {
        #expect(UsageMonitor.hourBucket(for: aMomentOnTheTwentyFifth) == "2026-09-25T14:00:00Z")
    }

    @Test func theVersionIsAlwaysThreeNumbersOrNothing() {
        #expect(UsageMonitor.threePartVersion("0.9.15") == "0.9.15")
        #expect(UsageMonitor.threePartVersion("0.9") == "0.9.0")
        #expect(UsageMonitor.threePartVersion("1.2.3.4") == "1.2.3")
        #expect(UsageMonitor.threePartVersion("dev") == nil)
        #expect(UsageMonitor.threePartVersion("") == nil)
    }

    @Test func anUnreadableVersionSendsNothing() {
        let sender = RecordingUsageSender()
        let monitor = makeMonitor(sender: sender, irisVersion: "local build")
        monitor.record(UsageEvent(kind: .appOpened, appSlug: "cue"))
        monitor.sendNowAndWaitForTesting()
        #expect(sender.batches.isEmpty, "the server would refuse the whole batch")
    }

    @Test func theTierFollowsTheSameMappingAsTheGatewayAlias() {
        #expect(UsageModelTier.forIrisModelName("claude-haiku-4-5") == .fast)
        #expect(UsageModelTier.forIrisModelName("claude-sonnet-4-6") == .balanced)
        #expect(UsageModelTier.forIrisModelName("claude-opus-4-6") == .smart)
        #expect(UsageModelTier.forIrisModelName("something-new") == .balanced)
    }
}
