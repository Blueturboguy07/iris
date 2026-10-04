import Foundation

public final class NativeUsageService: @unchecked Sendable {
    private struct State {
        var consentState: NativeUsageConsentState
        var consentEpoch: UInt64
        var leaseToken: UUID
        var storeHealth: NativeUsageStoreHealth
        var acceptingRecords: Bool
        var generation: UInt64 = 0

        var pendingEvents: [NativeUsagePendingEvent] = []
        var pendingBytes: Int = 0
        var pendingCounters = NativeUsageCounters()
        var volatileCounters = NativeUsageCounters()

        var persistedStore: NativeUsageStoreEnvelope
        var persistedRawBytes: Int
        var persistedSummaryBytes: Int
        var knownIdentities: Set<NativeUsageIdentity>

        var rateMinuteUTC: Int64?
        var perIdentityRate: [NativeUsageIdentity: Int] = [:]
        var globalRate: Int = 0

        var scheduledFlush: DispatchWorkItem?
        var scheduledFlushToken: UInt64 = 0
    }

    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private let commitLock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.publikhq.iris.mobile-usage-v1", qos: .utility)
    private let issuerToken = UUID()
    private let persistence: NativeUsagePersistence
    private let limits: NativeUsageLimits
    private let now: () -> Date
    private let flushDelay: DispatchTimeInterval
    private let beforeStoreCommit: (() -> Void)?
    private var state: State

    public convenience init(rootURL: URL, fileManager: FileManager = .default) {
        self.init(
            rootURL: rootURL,
            fileManager: fileManager,
            limits: .production,
            now: Date.init,
            flushDelay: .seconds(5),
            beforeStoreCommit: nil
        )
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        limits: NativeUsageLimits,
        now: @escaping () -> Date = Date.init,
        flushDelay: DispatchTimeInterval = .seconds(5),
        beforeStoreCommit: (() -> Void)? = nil
    ) {
        self.persistence = NativeUsagePersistence(rootURL: rootURL, fileManager: fileManager)
        self.limits = limits
        self.now = now
        self.flushDelay = flushDelay
        self.beforeStoreCommit = beforeStoreCommit

        let loaded = self.persistence.load(limits: limits)
        let consent: NativeUsageConsentState
        if loaded.health == .corruptConfiguration {
            consent = .unknown
        } else {
            switch loaded.configuration.mode {
            case .disabled: consent = .disabled
            case .enabled: consent = .enabled
            case .paused: consent = .paused
            }
        }
        let identities = Self.identities(in: loaded.store)
        self.state = State(
            consentState: consent,
            consentEpoch: loaded.configuration.consentEpoch,
            leaseToken: UUID(),
            storeHealth: loaded.health,
            acceptingRecords: loaded.health == .healthy && consent == .enabled,
            persistedStore: loaded.store,
            persistedRawBytes: loaded.rawEncodedBytes,
            persistedSummaryBytes: loaded.summaryEncodedBytes,
            knownIdentities: identities
        )
    }

    public func grantConsent() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        guard state.storeHealth == .healthy, state.consentState != .unknown else {
            lock.unlock()
            throw NativeUsageError.corruptLocalState
        }
        if state.consentState == .enabled {
            lock.unlock()
            return
        }
        let newEpoch = Self.nextEpoch(after: state.consentEpoch)
        state.acceptingRecords = false
        lock.unlock()

        let configuration = NativeUsageConfiguration(schemaVersion: 1, mode: .enabled, consentEpoch: newEpoch)
        do {
            try persistence.writeConfiguration(configuration)
        } catch {
            markPersistenceFailure()
            throw NativeUsageError.persistenceFailed
        }

        lock.lock()
        state.consentState = .enabled
        state.consentEpoch = newEpoch
        state.leaseToken = UUID()
        state.acceptingRecords = true
        state.volatileCounters = NativeUsageCounters()
        state.rateMinuteUTC = nil
        state.perIdentityRate.removeAll(keepingCapacity: false)
        state.globalRate = 0
        lock.unlock()
    }

    public func pause() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        commitLock.lock()
        lock.lock()
        guard state.storeHealth == .healthy, state.consentState != .unknown else {
            lock.unlock()
            commitLock.unlock()
            throw NativeUsageError.corruptLocalState
        }
        guard state.consentState == .enabled else {
            lock.unlock()
            commitLock.unlock()
            return
        }
        let newEpoch = Self.nextEpoch(after: state.consentEpoch)
        state.acceptingRecords = false
        state.consentState = .paused
        state.consentEpoch = newEpoch
        state.leaseToken = UUID()
        state.generation &+= 1
        let cleared = state.pendingEvents.count
        state.pendingEvents.removeAll(keepingCapacity: false)
        state.pendingBytes = 0
        state.pendingCounters = NativeUsageCounters()
        state.volatileCounters.pendingClearedOnPause &+= UInt64(cleared)
        cancelScheduledFlushLocked()
        state.rateMinuteUTC = nil
        state.perIdentityRate.removeAll(keepingCapacity: false)
        state.globalRate = 0
        state.knownIdentities = Self.identities(in: state.persistedStore)
        lock.unlock()
        commitLock.unlock()

        writerQueue.sync {}
        let configuration = NativeUsageConfiguration(schemaVersion: 1, mode: .paused, consentEpoch: newEpoch)
        do {
            try persistence.writeConfiguration(configuration)
        } catch {
            markPersistenceFailure()
            throw NativeUsageError.persistenceFailed
        }
    }

    public func resume() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        guard state.storeHealth == .healthy, state.consentState != .unknown else {
            lock.unlock()
            throw NativeUsageError.corruptLocalState
        }
        guard state.consentState == .paused else {
            lock.unlock()
            return
        }
        let newEpoch = Self.nextEpoch(after: state.consentEpoch)
        state.acceptingRecords = false
        lock.unlock()

        let configuration = NativeUsageConfiguration(schemaVersion: 1, mode: .enabled, consentEpoch: newEpoch)
        do {
            try persistence.writeConfiguration(configuration)
        } catch {
            markPersistenceFailure()
            throw NativeUsageError.persistenceFailed
        }

        lock.lock()
        state.consentState = .enabled
        state.consentEpoch = newEpoch
        state.leaseToken = UUID()
        state.acceptingRecords = true
        state.volatileCounters = NativeUsageCounters()
        state.rateMinuteUTC = nil
        state.perIdentityRate.removeAll(keepingCapacity: false)
        state.globalRate = 0
        lock.unlock()
    }

    public func revokeAndDelete() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        commitLock.lock()
        lock.lock()
        state.acceptingRecords = false
        state.consentState = .disabled
        state.consentEpoch = Self.nextEpoch(after: state.consentEpoch)
        state.leaseToken = UUID()
        state.generation &+= 1
        state.pendingEvents.removeAll(keepingCapacity: false)
        state.pendingBytes = 0
        state.pendingCounters = NativeUsageCounters()
        state.volatileCounters = NativeUsageCounters()
        cancelScheduledFlushLocked()
        state.rateMinuteUTC = nil
        state.perIdentityRate.removeAll(keepingCapacity: false)
        state.globalRate = 0
        lock.unlock()
        commitLock.unlock()

        writerQueue.sync {}
        do {
            try persistence.deleteAllUsageFiles()
        } catch {
            markPersistenceFailure()
            throw NativeUsageError.persistenceFailed
        }

        lock.lock()
        state.storeHealth = .healthy
        state.persistedStore = .empty
        state.persistedRawBytes = 0
        state.persistedSummaryBytes = 0
        state.knownIdentities.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    public func deleteLocalData() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        commitLock.lock()
        lock.lock()
        let priorConsent = state.consentState
        let configurationWasCorrupt = state.storeHealth == .corruptConfiguration || priorConsent == .unknown
        state.acceptingRecords = false
        state.generation &+= 1
        state.pendingEvents.removeAll(keepingCapacity: false)
        state.pendingBytes = 0
        state.pendingCounters = NativeUsageCounters()
        state.volatileCounters = NativeUsageCounters()
        cancelScheduledFlushLocked()
        state.rateMinuteUTC = nil
        state.perIdentityRate.removeAll(keepingCapacity: false)
        state.globalRate = 0
        let newEpoch = Self.nextEpoch(after: state.consentEpoch)
        state.leaseToken = UUID()
        lock.unlock()
        commitLock.unlock()

        writerQueue.sync {}
        do {
            if configurationWasCorrupt {
                try persistence.deleteAllUsageFiles()
            } else {
                try persistence.deleteStore()
                let mode: NativeUsageDiskMode
                switch priorConsent {
                case .enabled: mode = .enabled
                case .paused: mode = .paused
                case .disabled, .unknown: mode = .disabled
                }
                try persistence.writeConfiguration(
                    NativeUsageConfiguration(schemaVersion: 1, mode: mode, consentEpoch: newEpoch)
                )
            }
        } catch {
            markPersistenceFailure()
            throw NativeUsageError.persistenceFailed
        }

        lock.lock()
        state.persistedStore = .empty
        state.persistedRawBytes = 0
        state.persistedSummaryBytes = 0
        state.knownIdentities.removeAll(keepingCapacity: false)
        state.storeHealth = .healthy
        if configurationWasCorrupt {
            state.consentState = .disabled
            state.consentEpoch = 0
            state.leaseToken = UUID()
            state.acceptingRecords = false
        } else {
            state.consentEpoch = newEpoch
            state.acceptingRecords = priorConsent == .enabled
        }
        lock.unlock()
    }

    public func binding(for identity: NativeUsageIdentity) -> NativeUsageBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard state.acceptingRecords,
              state.storeHealth == .healthy,
              state.consentState == .enabled else {
            return nil
        }
        return NativeUsageBinding(
            identity: identity,
            consentEpoch: state.consentEpoch,
            issuerToken: issuerToken,
            leaseToken: state.leaseToken
        )
    }

    /// Continue an already-started operation once its verified app identity is
    /// known. Never borrow consent granted or renewed after that operation began.
    public func binding(for identity: NativeUsageIdentity, continuing original: NativeUsageBinding) -> NativeUsageBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard state.acceptingRecords, state.storeHealth == .healthy, state.consentState == .enabled,
              original.issuerToken == issuerToken, original.leaseToken == state.leaseToken,
              original.consentEpoch == state.consentEpoch else { return nil }
        return NativeUsageBinding(identity: identity, consentEpoch: original.consentEpoch,
                                  issuerToken: original.issuerToken, leaseToken: original.leaseToken)
    }

    @discardableResult
    public func record(_ event: NativeUsageEvent, binding: NativeUsageBinding) -> NativeUsageRecordDisposition {
        let minute = Self.minuteBucket(for: now())

        lock.lock()
        defer { lock.unlock() }

        guard state.consentState != .disabled else {
            return .disabled
        }
        guard state.consentState != .paused else {
            return .paused
        }
        guard state.storeHealth == .healthy else {
            state.volatileCounters.droppedStoreUnavailable &+= 1
            return .storeUnavailable
        }
        guard state.acceptingRecords else {
            state.volatileCounters.droppedStoreUnavailable &+= 1
            return .storeUnavailable
        }
        guard binding.issuerToken == issuerToken,
              binding.leaseToken == state.leaseToken,
              binding.consentEpoch == state.consentEpoch else {
            state.pendingCounters.droppedStaleConsentEpoch &+= 1
            scheduleFlushLocked(immediate: false)
            return .staleConsentEpoch
        }

        resetRateWindowIfNeededLocked(minute: minute)
        if state.globalRate >= limits.maximumGlobalEventsPerMinute
            || state.perIdentityRate[binding.identity, default: 0] >= limits.maximumIdentityEventsPerMinute {
            state.pendingCounters.droppedRateLimited &+= 1
            scheduleFlushLocked(immediate: false)
            return .rateLimited
        }

        if !state.knownIdentities.contains(binding.identity)
            && state.knownIdentities.count >= limits.maximumDistinctIdentities {
            state.pendingCounters.droppedCardinalityLimit &+= 1
            scheduleFlushLocked(immediate: false)
            return .cardinalityLimit
        }

        let eventKind = event.storedKind
        let outcome = event.storedOutcome
        guard let encodedBytes = NativeUsagePersistence.encodedEventBytes(
            minuteBucketUTC: minute,
            consentEpoch: binding.consentEpoch,
            identity: binding.identity,
            eventKind: eventKind,
            outcome: outcome
        ), encodedBytes <= limits.maximumEventBytes else {
            state.pendingCounters.droppedOversize &+= 1
            scheduleFlushLocked(immediate: false)
            return .oversize
        }

        guard state.pendingEvents.count < limits.maximumPendingEvents,
              state.pendingBytes + encodedBytes <= limits.maximumPendingBytes else {
            state.pendingCounters.droppedQueueFull &+= 1
            scheduleFlushLocked(immediate: true)
            return .queueFull
        }

        state.pendingEvents.append(
            NativeUsagePendingEvent(
                minuteBucketUTC: minute,
                consentEpoch: binding.consentEpoch,
                identity: binding.identity,
                eventKind: eventKind,
                outcome: outcome,
                encodedBytes: encodedBytes
            )
        )
        state.pendingBytes += encodedBytes
        state.pendingCounters.accepted &+= 1
        state.knownIdentities.insert(binding.identity)
        state.perIdentityRate[binding.identity, default: 0] += 1
        state.globalRate += 1

        let shouldFlushImmediately = state.pendingEvents.count >= limits.maximumBatchEvents
            || state.pendingBytes >= limits.maximumBatchBytes
        scheduleFlushLocked(immediate: shouldFlushImmediately)
        return .accepted
    }

    public func snapshot() -> NativeUsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var counters = Self.persistedCounters(in: state.persistedStore)
        counters.add(state.pendingCounters)
        counters.add(state.volatileCounters)
        return NativeUsageSnapshot(
            consentState: state.consentState,
            consentEpoch: state.consentEpoch,
            storeHealth: state.storeHealth,
            source: .shellHost,
            pendingEventCount: state.pendingEvents.count,
            pendingBytes: state.pendingBytes,
            retainedRawEventCount: state.persistedStore.rawEvents.count,
            retainedRawBytes: state.persistedRawBytes,
            retainedSummaryDayCount: state.persistedStore.dailySummaries.count,
            retainedSummaryBytes: state.persistedSummaryBytes,
            counters: counters,
            dailySummaries: state.persistedStore.dailySummaries
        )
    }

    func flushForTesting() {
        lock.lock()
        state.scheduledFlush?.cancel()
        state.scheduledFlush = nil
        state.scheduledFlushToken &+= 1
        let token = state.scheduledFlushToken
        let generation = state.generation
        lock.unlock()
        writerQueue.sync {
            self.flush(expectedGeneration: generation, token: token)
        }
    }

    private func scheduleFlushLocked(immediate: Bool) {
        guard state.storeHealth == .healthy,
              state.consentState == .enabled,
              state.acceptingRecords,
              !state.pendingEvents.isEmpty || !state.pendingCounters.isZero else {
            return
        }
        if !immediate, state.scheduledFlush != nil {
            return
        }
        state.scheduledFlush?.cancel()
        state.scheduledFlushToken &+= 1
        let token = state.scheduledFlushToken
        let generation = state.generation
        let item = DispatchWorkItem { [weak self] in
            self?.flush(expectedGeneration: generation, token: token)
        }
        state.scheduledFlush = item
        if immediate {
            writerQueue.async(execute: item)
        } else {
            writerQueue.asyncAfter(deadline: .now() + flushDelay, execute: item)
        }
    }

    private func cancelScheduledFlushLocked() {
        state.scheduledFlush?.cancel()
        state.scheduledFlush = nil
        state.scheduledFlushToken &+= 1
    }

    private func flush(expectedGeneration: UInt64, token: UInt64) {
        lock.lock()
        guard token == state.scheduledFlushToken,
              expectedGeneration == state.generation,
              state.storeHealth == .healthy,
              state.consentState == .enabled,
              state.acceptingRecords else {
            lock.unlock()
            return
        }
        state.scheduledFlush = nil

        var batch: [NativeUsagePendingEvent] = []
        var batchBytes = 0
        for event in state.pendingEvents {
            guard batch.count < limits.maximumBatchEvents else { break }
            if !batch.isEmpty, batchBytes + event.encodedBytes > limits.maximumBatchBytes { break }
            batch.append(event)
            batchBytes += event.encodedBytes
        }
        var counters = state.pendingCounters
        // `accepted` corresponds one-for-one with queued observations. A flush
        // can commit only the first bounded batch, so persist/subtract only the
        // accepted count represented by that batch. Loss counters are not tied
        // to queued records and may be committed with this transaction.
        counters.accepted = UInt64(batch.count)
        guard !batch.isEmpty || !counters.isZero else {
            lock.unlock()
            return
        }
        let baseStore = state.persistedStore
        let nowMinute = Self.minuteBucket(for: now())
        lock.unlock()

        let reduction: NativeUsageReductionResult
        do {
            reduction = try NativeUsagePersistence.reduce(
                store: baseStore,
                events: batch,
                counters: counters,
                nowMinuteUTC: nowMinute,
                limits: limits
            )
        } catch {
            markPersistenceFailure()
            return
        }

        beforeStoreCommit?()
        commitLock.lock()
        lock.lock()
        let stillAuthorized = state.generation == expectedGeneration
            && state.scheduledFlushToken == token
            && state.storeHealth == .healthy
            && state.consentState == .enabled
            && state.acceptingRecords
        lock.unlock()
        guard stillAuthorized else {
            commitLock.unlock()
            return
        }
        do {
            try persistence.writeStore(reduction.store, limits: limits)
        } catch {
            commitLock.unlock()
            markPersistenceFailure()
            return
        }

        lock.lock()
        state.persistedStore = reduction.store
        state.persistedRawBytes = reduction.rawEncodedBytes
        state.persistedSummaryBytes = reduction.summaryEncodedBytes
        if state.generation == expectedGeneration {
            if batch.count <= state.pendingEvents.count {
                state.pendingEvents.removeFirst(batch.count)
                state.pendingBytes = max(0, state.pendingBytes - batchBytes)
            }
            state.pendingCounters.subtractFlooringAtZero(counters)
            state.knownIdentities = Self.identities(in: state.persistedStore).union(state.pendingEvents.map(\.identity))
            if !state.pendingEvents.isEmpty || !state.pendingCounters.isZero {
                scheduleFlushLocked(immediate: false)
            }
        }
        lock.unlock()
        commitLock.unlock()
    }

    private func resetRateWindowIfNeededLocked(minute: Int64) {
        guard state.rateMinuteUTC != minute else { return }
        state.rateMinuteUTC = minute
        state.perIdentityRate.removeAll(keepingCapacity: true)
        state.globalRate = 0
    }

    private func markPersistenceFailure() {
        lock.lock()
        state.storeHealth = .ioFailure
        state.acceptingRecords = false
        cancelScheduledFlushLocked()
        lock.unlock()
    }

    private static func persistedCounters(in store: NativeUsageStoreEnvelope) -> NativeUsageCounters {
        var total = NativeUsageCounters()
        for summary in store.dailySummaries {
            total.add(summary.counters)
        }
        return total
    }

    private static func identities(in store: NativeUsageStoreEnvelope) -> Set<NativeUsageIdentity> {
        var identities = Set(store.rawEvents.map(\.identity))
        for summary in store.dailySummaries {
            identities.formUnion(summary.eventCounts.map(\.identity))
        }
        return identities
    }

    private static func nextEpoch(after value: UInt64) -> UInt64 {
        value == UInt64.max ? 1 : value + 1
    }

    private static func minuteBucket(for date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        let minute = floor(seconds / 60.0)
        guard minute > 0 else { return 0 }
        let upperBound = Double(Int64.max - 1_440)
        return minute >= upperBound ? Int64.max - 1_440 : Int64(minute)
    }
}
