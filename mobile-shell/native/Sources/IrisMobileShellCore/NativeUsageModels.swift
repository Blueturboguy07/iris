import Foundation

public struct NativeUsageIdentity: Codable, Equatable, Hashable, Sendable {
    public let appId: String
    public let projectId: String

    public init(appId: String, projectId: String) throws {
        guard NativeSecurity.isStableId(appId) else {
            throw NativeUsageError.invalidStableIdentifier
        }
        guard NativeSecurity.isStableId(projectId) else {
            throw NativeUsageError.invalidStableIdentifier
        }
        self.appId = appId
        self.projectId = projectId
    }

    private enum CodingKeys: String, CodingKey {
        case appId
        case projectId
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let appId = try values.decode(String.self, forKey: .appId)
        let projectId = try values.decode(String.self, forKey: .projectId)
        try self.init(appId: appId, projectId: projectId)
    }
}

public struct NativeUsageBinding: Equatable, Sendable {
    public let identity: NativeUsageIdentity
    public let consentEpoch: UInt64
    let issuerToken: UUID
    let leaseToken: UUID

    init(identity: NativeUsageIdentity, consentEpoch: UInt64, issuerToken: UUID, leaseToken: UUID) {
        self.identity = identity
        self.consentEpoch = consentEpoch
        self.issuerToken = issuerToken
        self.leaseToken = leaseToken
    }
}

public enum NativeUsageEventSource: String, Codable, CaseIterable, Sendable {
    case shellHost
}

public enum NativeUsageOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case failure
    case cancelled
    case rejected
    case unavailable
}

public enum NativeUsageNonSuccessOutcome: String, Codable, CaseIterable, Sendable {
    case failure
    case cancelled
    case rejected
    case unavailable

    var generalOutcome: NativeUsageOutcome {
        switch self {
        case .failure: return .failure
        case .cancelled: return .cancelled
        case .rejected: return .rejected
        case .unavailable: return .unavailable
        }
    }
}

/// The complete v0 event registry. There is intentionally no custom-event or
/// arbitrary-properties escape hatch. Every case describes a transition owned
/// by the mobile shell host itself.
public enum NativeUsageEvent: Sendable {
    case catalogLoadAttempt
    case catalogLoadOutcome(NativeUsageOutcome)
    case downloadAttempt
    case downloadOutcome(NativeUsageOutcome)
    case reviewAttempt
    case reviewOutcome(NativeUsageOutcome)
    case stageAttempt
    case stageOutcome(NativeUsageOutcome)
    case activateAttempt
    case activateOutcome(NativeUsageOutcome)
    case openRequest
    /// Emit only after the actual WebView navigation reports that it finished.
    /// Producing a verified launch descriptor is not enough to emit this case.
    case openLoaded
    case openLoadEnded(NativeUsageNonSuccessOutcome)
    case closeAttempt
    case closeOutcome(NativeUsageOutcome)
}

public enum NativeUsageEventKind: String, Codable, CaseIterable, Sendable {
    case catalogLoadAttempt
    case catalogLoadOutcome
    case downloadAttempt
    case downloadOutcome
    case reviewAttempt
    case reviewOutcome
    case stageAttempt
    case stageOutcome
    case activateAttempt
    case activateOutcome
    case openRequest
    case openLoaded
    case openLoadEnded
    case closeAttempt
    case closeOutcome
}

extension NativeUsageEvent {
    var storedKind: NativeUsageEventKind {
        switch self {
        case .catalogLoadAttempt: return .catalogLoadAttempt
        case .catalogLoadOutcome: return .catalogLoadOutcome
        case .downloadAttempt: return .downloadAttempt
        case .downloadOutcome: return .downloadOutcome
        case .reviewAttempt: return .reviewAttempt
        case .reviewOutcome: return .reviewOutcome
        case .stageAttempt: return .stageAttempt
        case .stageOutcome: return .stageOutcome
        case .activateAttempt: return .activateAttempt
        case .activateOutcome: return .activateOutcome
        case .openRequest: return .openRequest
        case .openLoaded: return .openLoaded
        case .openLoadEnded: return .openLoadEnded
        case .closeAttempt: return .closeAttempt
        case .closeOutcome: return .closeOutcome
        }
    }

    var storedOutcome: NativeUsageOutcome? {
        switch self {
        case .catalogLoadOutcome(let outcome),
             .downloadOutcome(let outcome),
             .reviewOutcome(let outcome),
             .stageOutcome(let outcome),
             .activateOutcome(let outcome),
             .closeOutcome(let outcome):
            return outcome
        case .openLoadEnded(let outcome):
            return outcome.generalOutcome
        case .catalogLoadAttempt,
             .downloadAttempt,
             .reviewAttempt,
             .stageAttempt,
             .activateAttempt,
             .openRequest,
             .openLoaded,
             .closeAttempt:
            return nil
        }
    }
}

public enum NativeUsageConsentState: String, Codable, Sendable {
    case disabled
    case enabled
    case paused
    /// The persisted consent file could not be decoded or validated. Recording
    /// remains disabled until an explicit delete/revoke action resets it.
    case unknown
}

public enum NativeUsageStoreHealth: String, Codable, Sendable {
    case healthy
    case corruptConfiguration
    case corruptStore
    case ioFailure
}

public enum NativeUsageRecordDisposition: String, Sendable {
    case accepted
    case disabled
    case paused
    case staleConsentEpoch
    case rateLimited
    case queueFull
    case cardinalityLimit
    case storeUnavailable
    case oversize
}

public enum NativeUsageError: Error, Equatable, Sendable {
    case invalidStableIdentifier
    case corruptLocalState
    case persistenceFailed
}

public struct NativeUsageCounters: Codable, Equatable, Sendable {
    public var accepted: UInt64 = 0
    public var droppedStaleConsentEpoch: UInt64 = 0
    public var droppedRateLimited: UInt64 = 0
    public var droppedQueueFull: UInt64 = 0
    public var droppedCardinalityLimit: UInt64 = 0
    public var droppedOversize: UInt64 = 0
    public var droppedStoreUnavailable: UInt64 = 0
    public var suppressedDisabled: UInt64 = 0
    public var suppressedPaused: UInt64 = 0
    public var pendingClearedOnPause: UInt64 = 0
    public var pendingDeleted: UInt64 = 0
    public var rawEventsExpired: UInt64 = 0
    public var rawEventsEvictedForStorage: UInt64 = 0
    public var summaryDaysExpired: UInt64 = 0
    public var summaryDaysEvictedForStorage: UInt64 = 0
    public var summaryDetailDropped: UInt64 = 0

    public init() {}

    mutating func add(_ other: NativeUsageCounters) {
        accepted &+= other.accepted
        droppedStaleConsentEpoch &+= other.droppedStaleConsentEpoch
        droppedRateLimited &+= other.droppedRateLimited
        droppedQueueFull &+= other.droppedQueueFull
        droppedCardinalityLimit &+= other.droppedCardinalityLimit
        droppedOversize &+= other.droppedOversize
        droppedStoreUnavailable &+= other.droppedStoreUnavailable
        suppressedDisabled &+= other.suppressedDisabled
        suppressedPaused &+= other.suppressedPaused
        pendingClearedOnPause &+= other.pendingClearedOnPause
        pendingDeleted &+= other.pendingDeleted
        rawEventsExpired &+= other.rawEventsExpired
        rawEventsEvictedForStorage &+= other.rawEventsEvictedForStorage
        summaryDaysExpired &+= other.summaryDaysExpired
        summaryDaysEvictedForStorage &+= other.summaryDaysEvictedForStorage
        summaryDetailDropped &+= other.summaryDetailDropped
    }

    mutating func subtractFlooringAtZero(_ other: NativeUsageCounters) {
        accepted = accepted >= other.accepted ? accepted - other.accepted : 0
        droppedStaleConsentEpoch = droppedStaleConsentEpoch >= other.droppedStaleConsentEpoch ? droppedStaleConsentEpoch - other.droppedStaleConsentEpoch : 0
        droppedRateLimited = droppedRateLimited >= other.droppedRateLimited ? droppedRateLimited - other.droppedRateLimited : 0
        droppedQueueFull = droppedQueueFull >= other.droppedQueueFull ? droppedQueueFull - other.droppedQueueFull : 0
        droppedCardinalityLimit = droppedCardinalityLimit >= other.droppedCardinalityLimit ? droppedCardinalityLimit - other.droppedCardinalityLimit : 0
        droppedOversize = droppedOversize >= other.droppedOversize ? droppedOversize - other.droppedOversize : 0
        droppedStoreUnavailable = droppedStoreUnavailable >= other.droppedStoreUnavailable ? droppedStoreUnavailable - other.droppedStoreUnavailable : 0
        suppressedDisabled = suppressedDisabled >= other.suppressedDisabled ? suppressedDisabled - other.suppressedDisabled : 0
        suppressedPaused = suppressedPaused >= other.suppressedPaused ? suppressedPaused - other.suppressedPaused : 0
        pendingClearedOnPause = pendingClearedOnPause >= other.pendingClearedOnPause ? pendingClearedOnPause - other.pendingClearedOnPause : 0
        pendingDeleted = pendingDeleted >= other.pendingDeleted ? pendingDeleted - other.pendingDeleted : 0
        rawEventsExpired = rawEventsExpired >= other.rawEventsExpired ? rawEventsExpired - other.rawEventsExpired : 0
        rawEventsEvictedForStorage = rawEventsEvictedForStorage >= other.rawEventsEvictedForStorage ? rawEventsEvictedForStorage - other.rawEventsEvictedForStorage : 0
        summaryDaysExpired = summaryDaysExpired >= other.summaryDaysExpired ? summaryDaysExpired - other.summaryDaysExpired : 0
        summaryDaysEvictedForStorage = summaryDaysEvictedForStorage >= other.summaryDaysEvictedForStorage ? summaryDaysEvictedForStorage - other.summaryDaysEvictedForStorage : 0
        summaryDetailDropped = summaryDetailDropped >= other.summaryDetailDropped ? summaryDetailDropped - other.summaryDetailDropped : 0
    }

    var isZero: Bool {
        self == NativeUsageCounters()
    }
}

public struct NativeUsageSummaryCount: Codable, Equatable, Sendable {
    public let identity: NativeUsageIdentity
    public let eventKind: NativeUsageEventKind
    public let outcome: NativeUsageOutcome?
    public let count: UInt64
}

public struct NativeUsageDailySummary: Codable, Equatable, Sendable {
    /// UTC day number since 1970-01-01. This avoids storing locale/time-zone or
    /// high-precision wall-clock data in the usage store.
    public let dayOrdinalUTC: Int64
    public let eventCounts: [NativeUsageSummaryCount]
    public let counters: NativeUsageCounters
}

public struct NativeUsageSnapshot: Equatable, Sendable {
    public let consentState: NativeUsageConsentState
    public let consentEpoch: UInt64
    public let storeHealth: NativeUsageStoreHealth
    public let source: NativeUsageEventSource
    public let pendingEventCount: Int
    public let pendingBytes: Int
    public let retainedRawEventCount: Int
    public let retainedRawBytes: Int
    public let retainedSummaryDayCount: Int
    public let retainedSummaryBytes: Int
    public let counters: NativeUsageCounters
    public let dailySummaries: [NativeUsageDailySummary]
}
