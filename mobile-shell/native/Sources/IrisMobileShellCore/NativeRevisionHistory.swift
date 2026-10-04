import Foundation

/// Presentation of verified stored revisions, not a fabricated installation log.
/// `createdAt` is the package author's creation timestamp, not a local install time.
public struct NativeRevisionHistoryRow: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable {
        case current
        case previousSelection
        case readyToActivate
        case stored

        public var label: String {
            switch self {
            case .current: return "Current version"
            case .previousSelection: return "Previous selection"
            case .readyToActivate: return "Ready to activate"
            case .stored: return "Stored version · not active"
            }
        }
    }

    public let revision: NativeRevisionSummary
    public let state: State
    public let canRevert: Bool
    public let canActivate: Bool
    public let selectionActionLabel: String
    public let isOnThisPhone: Bool
    public let storageStateLabel: String
    public let canDownload: Bool
    public var id: String { revision.revisionId }

    public init(revision: NativeRevisionSummary, state: State, canRevert: Bool,
                canActivate: Bool, selectionActionLabel: String,
                isOnThisPhone: Bool = true, storageStateLabel: String? = nil,
                canDownload: Bool = false) {
        self.revision = revision
        self.state = state
        self.canRevert = canRevert && isOnThisPhone
        self.canActivate = canActivate && isOnThisPhone
        self.selectionActionLabel = selectionActionLabel
        self.isOnThisPhone = isOnThisPhone
        self.storageStateLabel = storageStateLabel ?? state.label
        self.canDownload = canDownload
    }

    public static func rows(for entry: NativeShellLibraryEntry) -> [NativeRevisionHistoryRow] {
        // Public value types may be assembled by callers. Do not trap on a
        // duplicate, or follow a cycle forever, even though the store validates
        // the actual immutable revision metadata before it reaches this layer.
        var byID: [String: NativeRevisionSummary] = [:]
        for revision in entry.revisions where byID[revision.revisionId] == nil {
            byID[revision.revisionId] = revision
        }
        var ancestors = Set<String>()
        var cursor = entry.currentRevisionId.flatMap { byID[$0]?.baseRevisionId }
        while let id = cursor, ancestors.insert(id).inserted {
            cursor = byID[id]?.baseRevisionId
        }

        return byID.values.sorted { left, right in
            if left.revisionId == entry.currentRevisionId { return right.revisionId != entry.currentRevisionId }
            if right.revisionId == entry.currentRevisionId { return false }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.revisionId < right.revisionId
        }.map { revision in
            let isCurrent = revision.revisionId == entry.currentRevisionId
            let isPrevious = revision.revisionId == entry.fallbackRevisionId
            let canActivate = !isCurrent && revision.baseRevisionId == entry.currentRevisionId
            let canRevert = !isCurrent && (isPrevious || ancestors.contains(revision.revisionId))
            let state: State = isCurrent ? .current
                : isPrevious ? .previousSelection
                : canActivate ? .readyToActivate : .stored
            return NativeRevisionHistoryRow(
                revision: revision,
                state: state,
                canRevert: canRevert,
                canActivate: canActivate,
                selectionActionLabel: canRevert && !ancestors.contains(revision.revisionId)
                    ? "Restore" : "Revert"
            )
        }
    }
}
