import Foundation

struct NativeUsageLimits: Equatable {
    var maximumEventBytes: Int
    var maximumPendingEvents: Int
    var maximumPendingBytes: Int
    var maximumBatchEvents: Int
    var maximumBatchBytes: Int
    var maximumIdentityEventsPerMinute: Int
    var maximumGlobalEventsPerMinute: Int
    var maximumDistinctIdentities: Int
    var maximumSummaryKeysPerDay: Int
    var rawRetentionMinutes: Int64
    var maximumRawBytes: Int
    var summaryRetentionDays: Int64
    var maximumSummaryDayBytes: Int
    var maximumSummaryBytes: Int

    static let production = NativeUsageLimits(
        maximumEventBytes: 2 * 1024,
        maximumPendingEvents: 2_048,
        maximumPendingBytes: 1 * 1024 * 1024,
        maximumBatchEvents: 256,
        maximumBatchBytes: 128 * 1024,
        maximumIdentityEventsPerMinute: 1_200,
        maximumGlobalEventsPerMinute: 4_800,
        maximumDistinctIdentities: 64,
        maximumSummaryKeysPerDay: 96,
        rawRetentionMinutes: 24 * 60,
        maximumRawBytes: 256 * 1024,
        summaryRetentionDays: 30,
        maximumSummaryDayBytes: 64 * 1024,
        maximumSummaryBytes: 256 * 1024
    )
}

struct NativeUsagePendingEvent: Equatable, Sendable {
    let minuteBucketUTC: Int64
    let consentEpoch: UInt64
    let identity: NativeUsageIdentity
    let eventKind: NativeUsageEventKind
    let outcome: NativeUsageOutcome?
    let encodedBytes: Int
}

struct NativeUsageStoredEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sequence: UInt64
    let minuteBucketUTC: Int64
    let consentEpoch: UInt64
    let source: NativeUsageEventSource
    let identity: NativeUsageIdentity
    let eventKind: NativeUsageEventKind
    let outcome: NativeUsageOutcome?
}

enum NativeUsageDiskMode: String, Codable {
    case disabled
    case enabled
    case paused
}

struct NativeUsageConfiguration: Codable, Equatable {
    let schemaVersion: Int
    let mode: NativeUsageDiskMode
    let consentEpoch: UInt64

    static let initial = NativeUsageConfiguration(schemaVersion: 1, mode: .disabled, consentEpoch: 0)
}

struct NativeUsageStoreEnvelope: Codable, Equatable {
    let schemaVersion: Int
    var nextSequence: UInt64
    var rawEvents: [NativeUsageStoredEvent]
    var dailySummaries: [NativeUsageDailySummary]

    static let empty = NativeUsageStoreEnvelope(
        schemaVersion: 1,
        nextSequence: 1,
        rawEvents: [],
        dailySummaries: []
    )
}

struct NativeUsageLoadResult {
    let configuration: NativeUsageConfiguration
    let store: NativeUsageStoreEnvelope
    let health: NativeUsageStoreHealth
    let rawEncodedBytes: Int
    let summaryEncodedBytes: Int
}

struct NativeUsageReductionResult {
    let store: NativeUsageStoreEnvelope
    let rawEncodedBytes: Int
    let summaryEncodedBytes: Int
}

private enum NativeUsagePersistenceFailure: Error {
    case invalidRoot
    case invalidConfiguration
    case invalidStore
    case sequenceExhausted
    case summaryDayOverflow
}

struct NativeUsagePersistence {
    let rootURL: URL
    let fileManager: FileManager

    private var configurationURL: URL {
        rootURL.appendingPathComponent("consent.json", isDirectory: false)
    }

    private var storeURL: URL {
        rootURL.appendingPathComponent("store.json", isDirectory: false)
    }

    private static let maximumConfigurationFileBytes = 4 * 1024
    private static let storeEnvelopeOverheadBytes = 64 * 1024

    init(rootURL: URL, fileManager: FileManager) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(limits: NativeUsageLimits) -> NativeUsageLoadResult {
        var configuration = NativeUsageConfiguration.initial
        var store = NativeUsageStoreEnvelope.empty
        var health: NativeUsageStoreHealth = .healthy

        if fileManager.fileExists(atPath: configurationURL.path) {
            do {
                try requirePlainRootIfPresent()
                let data = try boundedRead(
                    configurationURL,
                    maximumBytes: Self.maximumConfigurationFileBytes
                )
                guard Self.hasStrictConfigurationShape(data) else {
                    throw NativeUsagePersistenceFailure.invalidConfiguration
                }
                let decoded = try JSONDecoder().decode(NativeUsageConfiguration.self, from: data)
                guard Self.valid(decoded) else { throw NativeUsagePersistenceFailure.invalidConfiguration }
                configuration = decoded
            } catch {
                health = .corruptConfiguration
            }
        }

        if fileManager.fileExists(atPath: storeURL.path) {
            do {
                try requirePlainRootIfPresent()
                let data = try boundedRead(
                    storeURL,
                    maximumBytes: Self.maximumStoreFileBytes(limits: limits)
                )
                guard Self.hasStrictStoreShape(data) else {
                    throw NativeUsagePersistenceFailure.invalidStore
                }
                let decoded = try JSONDecoder().decode(NativeUsageStoreEnvelope.self, from: data)
                guard Self.valid(decoded, limits: limits) else { throw NativeUsagePersistenceFailure.invalidStore }
                store = decoded
            } catch {
                if health == .healthy {
                    health = .corruptStore
                }
            }
        }

        let rawBytes = (try? Self.encodedBytes(store.rawEvents)) ?? 0
        let summaryBytes = (try? Self.encodedBytes(store.dailySummaries)) ?? 0
        return NativeUsageLoadResult(
            configuration: configuration,
            store: store,
            health: health,
            rawEncodedBytes: rawBytes,
            summaryEncodedBytes: summaryBytes
        )
    }

    func writeConfiguration(_ configuration: NativeUsageConfiguration) throws {
        guard Self.valid(configuration) else { throw NativeUsagePersistenceFailure.invalidConfiguration }
        try ensurePlainRoot()
        try requirePlainRegularFileIfPresent(configurationURL)
        let data = try Self.makeEncoder().encode(configuration)
        guard data.count <= Self.maximumConfigurationFileBytes else {
            throw NativeUsagePersistenceFailure.invalidConfiguration
        }
        try data.write(to: configurationURL, options: [.atomic])
    }

    func writeStore(_ store: NativeUsageStoreEnvelope, limits: NativeUsageLimits) throws {
        guard Self.valid(store, limits: limits) else { throw NativeUsagePersistenceFailure.invalidStore }
        try ensurePlainRoot()
        try requirePlainRegularFileIfPresent(storeURL)
        let data = try Self.makeEncoder().encode(store)
        guard data.count <= Self.maximumStoreFileBytes(limits: limits) else {
            throw NativeUsagePersistenceFailure.invalidStore
        }
        try data.write(to: storeURL, options: [.atomic])
    }

    func deleteStore() throws {
        if fileManager.fileExists(atPath: storeURL.path) {
            try requirePlainRootIfPresent()
            try fileManager.removeItem(at: storeURL)
        }
    }

    func deleteAllUsageFiles() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try requirePlainRootIfPresent()
            for url in [configurationURL, storeURL] where fileManager.fileExists(atPath: url.path) {
                // Removing a leaf symbolic link removes only the link itself and
                // never follows it to a target outside this dedicated scope.
                try fileManager.removeItem(at: url)
            }
            let remaining = try fileManager.contentsOfDirectory(atPath: rootURL.path)
            if remaining.isEmpty {
                try fileManager.removeItem(at: rootURL)
            }
        }
    }

    static func maximumStoreFileBytes(limits: NativeUsageLimits) -> Int {
        limits.maximumRawBytes + limits.maximumSummaryBytes + storeEnvelopeOverheadBytes
    }

    static func reduce(
        store original: NativeUsageStoreEnvelope,
        events: [NativeUsagePendingEvent],
        counters pendingCounters: NativeUsageCounters,
        nowMinuteUTC: Int64,
        limits: NativeUsageLimits
    ) throws -> NativeUsageReductionResult {
        var store = original
        let currentDay = dayOrdinal(forMinute: nowMinuteUTC)
        let rawCutoff = nowMinuteUTC - limits.rawRetentionMinutes
        let beforeRawExpiry = store.rawEvents.count
        store.rawEvents.removeAll { $0.minuteBucketUTC < rawCutoff }
        let expiredRaw = beforeRawExpiry - store.rawEvents.count

        let summaryCutoff = currentDay - (limits.summaryRetentionDays - 1)
        let beforeSummaryExpiry = store.dailySummaries.count
        store.dailySummaries.removeAll { $0.dayOrdinalUTC < summaryCutoff }
        let expiredSummaryDays = beforeSummaryExpiry - store.dailySummaries.count

        var housekeeping = pendingCounters
        housekeeping.rawEventsExpired &+= UInt64(expiredRaw)
        housekeeping.summaryDaysExpired &+= UInt64(expiredSummaryDays)
        if !housekeeping.isZero {
            addCounters(housekeeping, toDay: currentDay, summaries: &store.dailySummaries)
        }

        for pending in events {
            guard store.nextSequence != UInt64.max else {
                throw NativeUsagePersistenceFailure.sequenceExhausted
            }
            let stored = NativeUsageStoredEvent(
                schemaVersion: 1,
                sequence: store.nextSequence,
                minuteBucketUTC: pending.minuteBucketUTC,
                consentEpoch: pending.consentEpoch,
                source: .shellHost,
                identity: pending.identity,
                eventKind: pending.eventKind,
                outcome: pending.outcome
            )
            store.nextSequence += 1
            store.rawEvents.append(stored)
            addEvent(stored, summaries: &store.dailySummaries, limits: limits)
        }

        store.dailySummaries.sort { $0.dayOrdinalUTC < $1.dayOrdinalUTC }

        var rawBytes = try encodedBytes(store.rawEvents)
        var evictedRaw = 0
        while rawBytes > limits.maximumRawBytes, !store.rawEvents.isEmpty {
            let removalCount = min(max(1, store.rawEvents.count / 8), store.rawEvents.count)
            store.rawEvents.removeFirst(removalCount)
            evictedRaw += removalCount
            rawBytes = try encodedBytes(store.rawEvents)
        }
        if evictedRaw > 0 {
            var delta = NativeUsageCounters()
            delta.rawEventsEvictedForStorage = UInt64(evictedRaw)
            addCounters(delta, toDay: currentDay, summaries: &store.dailySummaries)
        }

        try enforcePerDaySummaryCap(&store.dailySummaries, limits: limits)
        var summaryBytes = try encodedBytes(store.dailySummaries)
        var evictedSummaryDays = 0
        while summaryBytes > limits.maximumSummaryBytes, store.dailySummaries.count > 1 {
            store.dailySummaries.removeFirst()
            evictedSummaryDays += 1
            summaryBytes = try encodedBytes(store.dailySummaries)
        }
        if evictedSummaryDays > 0 {
            var delta = NativeUsageCounters()
            delta.summaryDaysEvictedForStorage = UInt64(evictedSummaryDays)
            addCounters(delta, toDay: currentDay, summaries: &store.dailySummaries)
            summaryBytes = try encodedBytes(store.dailySummaries)
        }
        guard summaryBytes <= limits.maximumSummaryBytes else {
            throw NativeUsagePersistenceFailure.summaryDayOverflow
        }

        rawBytes = try encodedBytes(store.rawEvents)
        return NativeUsageReductionResult(
            store: store,
            rawEncodedBytes: rawBytes,
            summaryEncodedBytes: summaryBytes
        )
    }

    static func encodedEventBytes(
        minuteBucketUTC: Int64,
        consentEpoch: UInt64,
        identity: NativeUsageIdentity,
        eventKind: NativeUsageEventKind,
        outcome: NativeUsageOutcome?
    ) -> Int? {
        let candidate = NativeUsageStoredEvent(
            schemaVersion: 1,
            sequence: UInt64.max - 1,
            minuteBucketUTC: minuteBucketUTC,
            consentEpoch: consentEpoch,
            source: .shellHost,
            identity: identity,
            eventKind: eventKind,
            outcome: outcome
        )
        return try? makeEncoder().encode(candidate).count
    }

    private func ensurePlainRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try requirePlainRootIfPresent()
            return
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func requirePlainRootIfPresent() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        if (try? fileManager.destinationOfSymbolicLink(atPath: rootURL.path)) != nil {
            throw NativeUsagePersistenceFailure.invalidRoot
        }
        let attributes = try fileManager.attributesOfItem(atPath: rootURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw NativeUsagePersistenceFailure.invalidRoot
        }
    }

    private func requirePlainRegularFileIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw NativeUsagePersistenceFailure.invalidStore
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NativeUsagePersistenceFailure.invalidStore
        }
    }

    private func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        try requirePlainRegularFileIfPresent(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value <= UInt64(maximumBytes) else {
            throw NativeUsagePersistenceFailure.invalidStore
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw NativeUsagePersistenceFailure.invalidStore
        }
        return data
    }

    private static func valid(_ configuration: NativeUsageConfiguration) -> Bool {
        guard configuration.schemaVersion == 1 else { return false }
        switch configuration.mode {
        case .disabled:
            return true
        case .enabled, .paused:
            return configuration.consentEpoch > 0
        }
    }

    /// Synthesized Codable decoding deliberately ignores unknown JSON keys. The
    /// local-usage format is a closed privacy schema, so accepting an extra
    /// persisted field (for example arbitrary `content`) and then reporting the
    /// store healthy would weaken that contract. Check the bounded bytes' object
    /// shape before Codable performs type decoding; never retain or log values.
    private static func hasStrictConfigurationShape(_ data: Data) -> Bool {
        guard let root = jsonObject(data) else { return false }
        return hasExactKeys(
            root,
            required: ["schemaVersion", "mode", "consentEpoch"]
        )
    }

    private static func hasStrictStoreShape(_ data: Data) -> Bool {
        guard let root = jsonObject(data),
              hasExactKeys(
                root,
                required: ["schemaVersion", "nextSequence", "rawEvents", "dailySummaries"]
              ),
              let rawEvents = root["rawEvents"] as? [Any],
              let summaries = root["dailySummaries"] as? [Any]
        else { return false }

        guard rawEvents.allSatisfy(strictStoredEventShape),
              summaries.allSatisfy(strictDailySummaryShape) else { return false }
        return true
    }

    private static func strictStoredEventShape(_ value: Any) -> Bool {
        guard let event = value as? [String: Any],
              hasExactKeys(
                event,
                required: [
                    "schemaVersion", "sequence", "minuteBucketUTC", "consentEpoch",
                    "source", "identity", "eventKind",
                ],
                optional: ["outcome"]
              ),
              strictIdentityShape(event["identity"] as Any)
        else { return false }
        return true
    }

    private static func strictIdentityShape(_ value: Any) -> Bool {
        guard let identity = value as? [String: Any] else { return false }
        return hasExactKeys(identity, required: ["appId", "projectId"])
    }

    private static func strictDailySummaryShape(_ value: Any) -> Bool {
        guard let summary = value as? [String: Any],
              hasExactKeys(
                summary,
                required: ["dayOrdinalUTC", "eventCounts", "counters"]
              ),
              let eventCounts = summary["eventCounts"] as? [Any],
              strictCountersShape(summary["counters"] as Any),
              eventCounts.allSatisfy(strictSummaryCountShape)
        else { return false }
        return true
    }

    private static func strictSummaryCountShape(_ value: Any) -> Bool {
        guard let count = value as? [String: Any],
              hasExactKeys(
                count,
                required: ["identity", "eventKind", "count"],
                optional: ["outcome"]
              ),
              strictIdentityShape(count["identity"] as Any)
        else { return false }
        return true
    }

    private static func strictCountersShape(_ value: Any) -> Bool {
        guard let counters = value as? [String: Any] else { return false }
        return hasExactKeys(
            counters,
            required: [
                "accepted",
                "droppedStaleConsentEpoch",
                "droppedRateLimited",
                "droppedQueueFull",
                "droppedCardinalityLimit",
                "droppedOversize",
                "droppedStoreUnavailable",
                "suppressedDisabled",
                "suppressedPaused",
                "pendingClearedOnPause",
                "pendingDeleted",
                "rawEventsExpired",
                "rawEventsEvictedForStorage",
                "summaryDaysExpired",
                "summaryDaysEvictedForStorage",
                "summaryDetailDropped",
            ]
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    private static func hasExactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) -> Bool {
        let actual = Set(object.keys)
        return required.isSubset(of: actual)
            && actual.isSubset(of: required.union(optional))
    }

    private static func valid(_ store: NativeUsageStoreEnvelope, limits: NativeUsageLimits) -> Bool {
        guard store.schemaVersion == 1 else { return false }
        guard store.dailySummaries.count <= Int(limits.summaryRetentionDays) else { return false }
        if let lastSequence = store.rawEvents.last?.sequence, store.nextSequence <= lastSequence {
            return false
        }
        var previousSequence: UInt64?
        for event in store.rawEvents {
            guard event.schemaVersion == 1,
                  event.source == .shellHost,
                  event.consentEpoch > 0,
                  event.minuteBucketUTC >= 0,
                  validOutcome(event.eventKind, event.outcome),
                  ((try? encodedBytes(event)) ?? Int.max) <= limits.maximumEventBytes else {
                return false
            }
            if let previousSequence, event.sequence <= previousSequence { return false }
            previousSequence = event.sequence
        }
        let sortedDays = store.dailySummaries.map(\.dayOrdinalUTC).sorted()
        guard sortedDays == store.dailySummaries.map(\.dayOrdinalUTC), Set(sortedDays).count == sortedDays.count else {
            return false
        }
        for summary in store.dailySummaries {
            guard summary.dayOrdinalUTC >= 0,
                  summary.eventCounts.count <= limits.maximumSummaryKeysPerDay else { return false }
            for count in summary.eventCounts {
                guard count.count > 0, validOutcome(count.eventKind, count.outcome) else { return false }
            }
            guard ((try? encodedBytes(summary)) ?? Int.max) <= limits.maximumSummaryDayBytes else {
                return false
            }
        }
        guard ((try? encodedBytes(store.rawEvents)) ?? Int.max) <= limits.maximumRawBytes else { return false }
        guard ((try? encodedBytes(store.dailySummaries)) ?? Int.max) <= limits.maximumSummaryBytes else { return false }
        return true
    }

    private static func validOutcome(_ kind: NativeUsageEventKind, _ outcome: NativeUsageOutcome?) -> Bool {
        switch kind {
        case .catalogLoadAttempt,
             .downloadAttempt,
             .reviewAttempt,
             .stageAttempt,
             .activateAttempt,
             .openRequest,
             .openLoaded,
             .closeAttempt:
            return outcome == nil
        case .openLoadEnded:
            return outcome != nil && outcome != .success
        case .catalogLoadOutcome,
             .downloadOutcome,
             .reviewOutcome,
             .stageOutcome,
             .activateOutcome,
             .closeOutcome:
            return outcome != nil
        }
    }

    private static func addEvent(
        _ event: NativeUsageStoredEvent,
        summaries: inout [NativeUsageDailySummary],
        limits: NativeUsageLimits
    ) {
        let day = dayOrdinal(forMinute: event.minuteBucketUTC)
        let index = summaryIndex(day: day, summaries: &summaries)
        var summary = summaries[index]
        if let existing = summary.eventCounts.firstIndex(where: {
            $0.identity == event.identity && $0.eventKind == event.eventKind && $0.outcome == event.outcome
        }) {
            var counts = summary.eventCounts
            let old = counts[existing]
            counts[existing] = NativeUsageSummaryCount(
                identity: old.identity,
                eventKind: old.eventKind,
                outcome: old.outcome,
                count: old.count &+ 1
            )
            summary = NativeUsageDailySummary(
                dayOrdinalUTC: summary.dayOrdinalUTC,
                eventCounts: counts,
                counters: summary.counters
            )
        } else if summary.eventCounts.count < limits.maximumSummaryKeysPerDay {
            var counts = summary.eventCounts
            counts.append(
                NativeUsageSummaryCount(
                    identity: event.identity,
                    eventKind: event.eventKind,
                    outcome: event.outcome,
                    count: 1
                )
            )
            counts.sort(by: summaryCountLessThan)
            summary = NativeUsageDailySummary(
                dayOrdinalUTC: summary.dayOrdinalUTC,
                eventCounts: counts,
                counters: summary.counters
            )
        } else {
            var counters = summary.counters
            counters.summaryDetailDropped &+= 1
            summary = NativeUsageDailySummary(
                dayOrdinalUTC: summary.dayOrdinalUTC,
                eventCounts: summary.eventCounts,
                counters: counters
            )
        }
        summaries[index] = summary
    }

    private static func addCounters(
        _ counters: NativeUsageCounters,
        toDay day: Int64,
        summaries: inout [NativeUsageDailySummary]
    ) {
        guard !counters.isZero else { return }
        let index = summaryIndex(day: day, summaries: &summaries)
        let existing = summaries[index]
        var merged = existing.counters
        merged.add(counters)
        summaries[index] = NativeUsageDailySummary(
            dayOrdinalUTC: existing.dayOrdinalUTC,
            eventCounts: existing.eventCounts,
            counters: merged
        )
    }

    private static func summaryIndex(
        day: Int64,
        summaries: inout [NativeUsageDailySummary]
    ) -> Int {
        if let index = summaries.firstIndex(where: { $0.dayOrdinalUTC == day }) {
            return index
        }
        summaries.append(
            NativeUsageDailySummary(
                dayOrdinalUTC: day,
                eventCounts: [],
                counters: NativeUsageCounters()
            )
        )
        return summaries.count - 1
    }

    private static func enforcePerDaySummaryCap(
        _ summaries: inout [NativeUsageDailySummary],
        limits: NativeUsageLimits
    ) throws {
        for index in summaries.indices {
            guard try encodedBytes(summaries[index]) <= limits.maximumSummaryDayBytes else {
                throw NativeUsagePersistenceFailure.summaryDayOverflow
            }
        }
    }

    private static func summaryCountLessThan(_ left: NativeUsageSummaryCount, _ right: NativeUsageSummaryCount) -> Bool {
        if left.identity.appId != right.identity.appId { return left.identity.appId < right.identity.appId }
        if left.identity.projectId != right.identity.projectId { return left.identity.projectId < right.identity.projectId }
        if left.eventKind.rawValue != right.eventKind.rawValue { return left.eventKind.rawValue < right.eventKind.rawValue }
        return (left.outcome?.rawValue ?? "") < (right.outcome?.rawValue ?? "")
    }

    private static func dayOrdinal(forMinute minute: Int64) -> Int64 {
        minute / 1_440
    }

    private static func encodedBytes<T: Encodable>(_ value: T) throws -> Int {
        try makeEncoder().encode(value).count
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
