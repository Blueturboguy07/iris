import Foundation

/// Pure ownership-aware retention decision for stored revisions. Given plain
/// facts about a revision store's current state, decides which revisions
/// pruning must never remove. Takes no file handle, actor or store, so the
/// decision can be exercised directly against many realistic revision
/// graphs without touching disk.
///
/// The existing retained-role projection has four protective roles:
/// - `current`: the active pointer's current revision.
/// - `previous`: the active pointer's fallback (last-known-good) revision.
/// - `pending`: the single newest staged revision whose base is the current
///   revision, i.e. a downloaded update waiting on the reader to activate.
///   Only the newest such candidate is protected; an older, superseded
///   candidate staged against the same base is not "the" pending update.
/// - a user pin, capped at `pinLimit`.
///
/// Design note (docs/plans/20260926-feature-streams/s6-mobile/PLAN.md
/// section 6): "keep current, previous and pending, plus up to 2
/// user-pinned revisions, 5 per app at most" is exactly `1 + 1 + 1 + 2 = 5`;
/// `retainedSet` enforces the pin cap and lets the role slots be empty.
/// `retainedRevisionIds` additionally applies the saved count and catalog
/// protections without turning those roles into a maximum history size.
public enum VersionsKeptPerApp: String, Codable, CaseIterable, Equatable, Sendable {
    case keepTwo = "2"
    case keepThree = "3"
    case keepFive = "5"
    case keepAll = "all"

    public var count: Int? {
        switch self {
        case .keepTwo: return 2
        case .keepThree: return 3
        case .keepFive: return 5
        case .keepAll: return nil
        }
    }
}

public enum NativeStorageRetentionPolicy {
    public static let pinLimit = 2
    /// Maximum protected roles, not a cap on manifests or kept history.
    public static let maximumRetainedRevisionsPerApp = 5

    /// Section 4's Phase 1 device acceptance: "P3 fills storage to under
    /// 500 MB free and tries an app update: it is refused clearly and the
    /// old version still opens." 500 MB is that same threshold, not a
    /// number invented here.
    public static let defaultMinimumFreeBytesForStaging: Int64 = 500 * 1024 * 1024

    /// A minimal, storage-relevant fact about one stored revision. Deliberately
    /// independent of `NativeRevisionSummary` so this file has no dependency on
    /// delivery/package types.
    public struct RevisionFact: Equatable, Sendable {
        public let revisionId: String
        public let baseRevisionId: String?
        public let createdAt: String

        public init(revisionId: String, baseRevisionId: String?, createdAt: String) {
            self.revisionId = revisionId
            self.baseRevisionId = baseRevisionId
            self.createdAt = createdAt
        }
    }

    /// The revision ids pruning must never remove, and which door protects
    /// each one. `current`, `previous` and `pending` are nil exactly when no
    /// stored revision fills that role right now.
    public struct RetainedSet: Equatable, Sendable {
        public let current: String?
        public let previous: String?
        public let pending: String?
        public let pinned: [String]

        public init(current: String?, previous: String?, pending: String?, pinned: [String]) {
            self.current = current
            self.previous = previous
            self.pending = pending
            self.pinned = pinned
        }

        public var revisionIds: Set<String> {
            var ids = Set<String>()
            for value in [current, previous, pending] where value != nil {
                ids.insert(value!)
            }
            ids.formUnion(pinned)
            return ids
        }
    }

    /// `pinnedRevisionIds` is expected to already be capped at `pinLimit` by
    /// whatever persists pins (a second, defensive cap is applied here too).
    /// A pin or pointer id that names a revision outside `revisions` is
    /// silently ignored: a stale pin whose files are already gone must
    /// never resurrect anything.
    public static func retainedSet(
        revisions: [RevisionFact],
        currentRevisionId: String?,
        fallbackRevisionId: String?,
        pinnedRevisionIds: [String]
    ) -> RetainedSet {
        let knownIds = Set(revisions.map(\.revisionId))
        let current = currentRevisionId.flatMap { knownIds.contains($0) ? $0 : nil }
        let previous = fallbackRevisionId.flatMap { knownIds.contains($0) ? $0 : nil }
        let pending = revisions
            .filter { $0.baseRevisionId == currentRevisionId && $0.revisionId != currentRevisionId }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.revisionId > rhs.revisionId
            }
            .first?.revisionId
        var pinned: [String] = []
        for id in pinnedRevisionIds where knownIds.contains(id) {
            guard !pinned.contains(id) else { continue }
            pinned.append(id)
            if pinned.count == pinLimit { break }
        }
        return RetainedSet(current: current, previous: previous, pending: pending, pinned: pinned)
    }

    /// Every stored revision id that pruning should remove: everything not
    /// in the retained set.
    public static func prunableRevisionIds(
        revisions: [RevisionFact],
        currentRevisionId: String?,
        fallbackRevisionId: String?,
        pinnedRevisionIds: [String]
    ) -> Set<String> {
        let retained = retainedSet(
            revisions: revisions,
            currentRevisionId: currentRevisionId,
            fallbackRevisionId: fallbackRevisionId,
            pinnedRevisionIds: pinnedRevisionIds
        ).revisionIds
        return Set(revisions.map(\.revisionId)).subtracting(retained)
    }

    /// Count slots are current and fallback, followed by newest ordinary
    /// history. Every additional protected role is retained outside the slots.
    public static func retainedRevisionIds(
        revisions: [RevisionFact],
        currentRevisionId: String?,
        fallbackRevisionId: String?,
        pinnedRevisionIds: [String],
        localOnlyRevisionIds: Set<String>,
        downloadableRevisionIds: Set<String>,
        keepCount: Int?
    ) -> Set<String> {
        precondition(keepCount == nil || keepCount! > 0)
        let known = Set(revisions.map(\.revisionId))
        guard let keepCount else { return known }
        let roles = retainedSet(revisions: revisions, currentRevisionId: currentRevisionId,
            fallbackRevisionId: fallbackRevisionId, pinnedRevisionIds: pinnedRevisionIds)
        var retained = roles.revisionIds
        retained.formUnion(localOnlyRevisionIds.intersection(known))
        retained.formUnion(known.subtracting(downloadableRevisionIds))
        let ordinaryRoles = Set([roles.current, roles.previous].compactMap { $0 })
        let slots = max(0, keepCount - ordinaryRoles.count)
        let newest = revisions.sorted {
            $0.createdAt == $1.createdAt ? $0.revisionId > $1.revisionId : $0.createdAt > $1.createdAt
        }.map(\.revisionId).filter { !retained.contains($0) }
        retained.formUnion(newest.prefix(slots))
        return retained
    }

    // MARK: - Global (cross-app) code cap

    /// Owner decision, 2026-09-28 (this unit's brief, M4-mobile-storage-scale
    /// part 1): the global code cap defaults to 2 GB across every installed
    /// app's stored revisions combined, and is a setting the owner can raise
    /// or lower (`NativeShellLibraryCoordinator.setGlobalCodeCapBytes`). This
    /// constant is only the shipped default, not a hard limit the code
    /// enforces on the setting's value.
    public static let defaultGlobalCodeCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// One already-known-prunable revision (excluded from some app's
    /// `retainedSet`) offered as a candidate for cross-app reclaim. Callers
    /// build this list only from revisions their own per-app retention
    /// already agreed are safe to remove: this type carries no logic of its
    /// own to re-decide that, so a caller that (incorrectly) included a
    /// retained revision here would have it removed. `NativeRevisionStore`
    /// guards against exactly that mistake a second time
    /// (`removeSpecificRevisions` refuses any id it can prove is retained).
    public struct GlobalPrunableRevision: Equatable, Sendable {
        public let appId: String
        public let projectId: String
        public let revisionId: String
        public let allocatedBytes: Int
        public let createdAt: String

        public init(appId: String, projectId: String, revisionId: String, allocatedBytes: Int, createdAt: String) {
            self.appId = appId
            self.projectId = projectId
            self.revisionId = revisionId
            self.allocatedBytes = allocatedBytes
            self.createdAt = createdAt
        }
    }

    /// The outcome of `planGlobalReclaim`: what it would remove, and how
    /// much it would reclaim, without removing anything itself. A person
    /// sees `bytesReclaimed` before any deletion happens
    /// (`NativeShellLibraryCoordinator.planGlobalCapEnforcement`).
    public struct GlobalReclaimPlan: Equatable, Sendable {
        public let revisionsToRemove: [GlobalPrunableRevision]
        public let bytesReclaimed: Int64
        /// Greater than zero only when removing every offered candidate
        /// still leaves the store over the cap (every remaining byte
        /// belongs to a protected revision in some app, so the cap cannot
        /// be met without breaking a retention promise). Zero once the plan
        /// brings the total to at or under the cap, including when the
        /// store was already under the cap and nothing needs removing.
        public let bytesStillOverCapAfterRemoval: Int64

        public init(revisionsToRemove: [GlobalPrunableRevision], bytesReclaimed: Int64, bytesStillOverCapAfterRemoval: Int64) {
            self.revisionsToRemove = revisionsToRemove
            self.bytesReclaimed = bytesReclaimed
            self.bytesStillOverCapAfterRemoval = bytesStillOverCapAfterRemoval
        }
    }

    /// Pure planning: given the real total allocated bytes across every
    /// installed app and a flat list of candidates already known to be
    /// prunable (per-app retention already excluded current, previous,
    /// pending and pinned revisions from this list), decides the smallest
    /// oldest-first set of removals that brings the total to at or under
    /// `capBytes`. Deterministic: ties in `createdAt` break on `revisionId`
    /// so the same inputs always produce the same plan. Never mutates
    /// anything and touches no disk; `candidates` order does not matter.
    public static func planGlobalReclaim(
        currentTotalBytes: Int64,
        capBytes: Int64,
        prunableCandidates: [GlobalPrunableRevision]
    ) -> GlobalReclaimPlan {
        guard currentTotalBytes > capBytes else {
            return GlobalReclaimPlan(revisionsToRemove: [], bytesReclaimed: 0, bytesStillOverCapAfterRemoval: 0)
        }
        let ordered = prunableCandidates.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.revisionId != rhs.revisionId { return lhs.revisionId < rhs.revisionId }
            return lhs.appId != rhs.appId ? lhs.appId < rhs.appId : lhs.projectId < rhs.projectId
        }
        var remaining = currentTotalBytes
        var chosen: [GlobalPrunableRevision] = []
        var reclaimed: Int64 = 0
        for candidate in ordered where remaining > capBytes {
            chosen.append(candidate)
            let bytes = Int64(candidate.allocatedBytes)
            reclaimed += bytes
            remaining -= bytes
        }
        return GlobalReclaimPlan(
            revisionsToRemove: chosen,
            bytesReclaimed: reclaimed,
            bytesStillOverCapAfterRemoval: max(0, remaining - capBytes)
        )
    }
}

/// Errors raised by storage retention, pinning and low-storage guard logic.
/// Kept separate from `NativeShellError` (owned by the delivery-validation
/// unit) because storage bounding is this unit's own concern.
public enum NativeStorageError: Error, Equatable, CustomStringConvertible, Sendable {
    case pinLimitReached(limit: Int)
    case revisionNotAvailableToPin(String)
    case insufficientStorageForUpdate(availableBytes: Int64, thresholdBytes: Int64)
    case freeSpaceUnavailable
    /// `NativeRevisionStore.removeSpecificRevisions` refused because at
    /// least one requested id is current, previous, pending or pinned right
    /// now. Defense in depth: a caller building a removal set from a stale
    /// plan (the person pinned this exact revision after the plan was
    /// shown but before they confirmed) must never lose it.
    case cannotRemoveRetainedRevision(String)
    case recoveryRequired

    public var description: String {
        switch self {
        case .recoveryRequired:
            return "Iris must finish recovering this app before tidying storage."
        case .pinLimitReached(let limit):
            return "You can pin up to \(limit) versions of this app. Unpin one before pinning another."
        case .revisionNotAvailableToPin(let revisionId):
            return "That version is not stored, so it cannot be pinned: \(revisionId)"
        case .insufficientStorageForUpdate(let available, let threshold):
            return "Not enough free storage to install this update "
                + "(\(available) bytes free, \(threshold) bytes needed). "
                + "The app you already have keeps working."
        case .freeSpaceUnavailable:
            return "Iris could not check free storage before this update, so it was not installed."
        case .cannotRemoveRetainedRevision(let revisionId):
            return "That version is still in use, so it was kept: \(revisionId)"
        }
    }
}

/// The plain-language, per-app storage facts shown in Settings: code size,
/// versions kept and pins, kept separate from any measurement of the app's
/// own user data (which lives outside this store's root and, on iOS, is
/// measured by the Host layer through `WKWebsiteDataStore`).
public struct NativeStorageAppUsage: Equatable, Sendable {
    public let identity: NativeShellAppIdentity
    public let codeAllocatedBytes: Int
    public let storedRevisionCount: Int
    public let pinnedRevisionIds: [String]
    public let currentRevisionId: String?
    public let fallbackRevisionId: String?

    public init(
        identity: NativeShellAppIdentity,
        codeAllocatedBytes: Int,
        storedRevisionCount: Int,
        pinnedRevisionIds: [String],
        currentRevisionId: String?,
        fallbackRevisionId: String?
    ) {
        self.identity = identity
        self.codeAllocatedBytes = codeAllocatedBytes
        self.storedRevisionCount = storedRevisionCount
        self.pinnedRevisionIds = pinnedRevisionIds
        self.currentRevisionId = currentRevisionId
        self.fallbackRevisionId = fallbackRevisionId
    }
}
