import IrisMobileShellCore

/// Pure data shaping for the Features page (SPEC.md section 1.1): turns a
/// `NativeShellLibraryEntry` plus pin/usage facts into the rows the view
/// renders, newest first. No file I/O, no coordinator -- everything here is
/// a plain function over already-fetched facts, so it is exercised the same
/// way `NativeRevisionHistoryRow.rows(for:)` already is (unit tests, no
/// fixture root on disk).
///
/// Backend note (see FeaturesModel.swift's own doc comment for the honest
/// version): `NativeRevisionStore` today (pre the full MV2 object-store
/// delegation) never partially frees a staged revision's content, so this
/// mapping can only ever produce `.current`, `.previousSelection`,
/// `.pinned` and `.keptWhileThereIsRoom` -- never `.notOnThisPhone`,
/// `.noLongerAvailable` or `.stoppedBeforeFinishing`. Those detail-line
/// states are modeled here anyway (SPEC 1.1's full vocabulary) so the view
/// and its accessibility labels are already correct once a real object
/// store can report them; `FeaturesRow.State.detailLine` is the single
/// place that would need new inputs, not a rewrite.
public enum FeaturesRowState: Equatable, Sendable {
    case current
    case previousSelection
    case pinned
    case keptWhileThereIsRoom
    case pending
    case notOnThisPhone(downloadBytes: Int?)
    case noLongerAvailable
    case stoppedBeforeFinishing(date: String)

    /// SPEC 1.1: "Detail line, words never color."
    public func detailLine() -> String {
        switch self {
        case .current: return "On this iPhone now"
        case .previousSelection: return "Kept as backup"
        case .pinned: return "Pinned: kept until you unpin it"
        case .keptWhileThereIsRoom: return "Kept while there is room"
        case .pending: return "Downloaded, not switched on yet"
        case .notOnThisPhone(let bytes):
            guard let bytes else { return "Not on this iPhone. Download to go back." }
            let mb = max(1, bytes / (1024 * 1024))
            return "Not on this iPhone. Download to go back (\(mb) MB)"
        case .noLongerAvailable: return "No longer available"
        case .stoppedBeforeFinishing(let date):
            return "Stopped before it finished \(date) · nothing was changed"
        }
    }
}

public struct FeaturesRow: Identifiable, Equatable, Sendable {
    public let revisionId: String
    public let baseRevisionId: String?
    public let title: String
    public let createdAt: String
    public let state: FeaturesRowState
    public let isPinned: Bool
    public let canGoBack: Bool
    public let canActivate: Bool
    public let canDownload: Bool
    public let canRemove: Bool
    /// SPEC 1.2: removing an OLDER feature (keeping newer ones) cannot
    /// happen on the phone at all; its Remove opens the Mac-only sheet
    /// instead of a phone confirmation.
    public let removalNeedsMac: Bool

    public var id: String { revisionId }

    /// SPEC 1.1: "<state word>: <title>, <date>" (voiceOverRowLabel).
    public var accessibilityLabel: String {
        "\(state.detailLine()): \(title), \(String(createdAt.prefix(10)))"
    }
}

public enum FeaturesRows {
    /// `isFirst` is computed from `createdAt` ordering (the oldest
    /// revision in this app's history), matching SPEC 1.1 ("The first
    /// version reads 'First version'") without needing a separate
    /// "is-genesis" flag from the store.
    public static func rows(
        for entry: NativeShellLibraryEntry,
        pinnedRevisionIds: Set<String>
    ) -> [FeaturesRow] {
        guard !entry.revisions.isEmpty else { return [] }
        let oldestId = entry.revisions.min { $0.createdAt < $1.createdAt }?.revisionId
        let currentId = entry.currentRevisionId
        let fallbackId = entry.fallbackRevisionId

        return entry.revisions
            .sorted { left, right in
                if left.revisionId == currentId { return right.revisionId != currentId }
                if right.revisionId == currentId { return false }
                if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
                return left.revisionId < right.revisionId
            }
            .map { revision in
                let isCurrent = revision.revisionId == currentId
                let isFallback = revision.revisionId == fallbackId
                let isPinned = pinnedRevisionIds.contains(revision.revisionId)
                let isPending = !isCurrent && revision.baseRevisionId == currentId
                let isFirst = revision.revisionId == oldestId

                let title = revision.changes?.first?.title
                    ?? (isFirst ? "First version" : "Update from \(String(revision.createdAt.prefix(10)))")

                let state: FeaturesRowState = isCurrent ? .current
                    : isFallback ? .previousSelection
                    : isPinned ? .pinned
                    : isPending ? .pending
                    : .keptWhileThereIsRoom

                // SPEC 1.1: Go back on "any earlier version that is on the
                // iPhone". The legacy store keeps every staged revision's
                // full content, so "on the iPhone" is simply "not current".
                let canGoBack = !isCurrent && !isPending
                let canActivate = isPending

                return FeaturesRow(
                    revisionId: revision.revisionId,
                    baseRevisionId: revision.baseRevisionId,
                    title: title,
                    createdAt: revision.createdAt,
                    state: state,
                    isPinned: isPinned,
                    canGoBack: canGoBack,
                    canActivate: canActivate,
                    canDownload: false,
                    // SPEC 1.1: every row shows a Remove control.
                    canRemove: true,
                    // SPEC 1.2: "Remove (the newest feature)" == going back
                    // one step, and applies only to the CURRENT row (the
                    // newest feature the person has switched on). Remove on
                    // any other row is "an older feature, keeping the newer
                    // ones", which the phone cannot rebuild -- only Iris on
                    // the Mac can -- so it opens the Mac-only sheet.
                    removalNeedsMac: !isCurrent
                )
            }
    }

    /// SPEC 1.1: "8 shown then 'Show all N'".
    public static let collapsedRowCount = 8
}
