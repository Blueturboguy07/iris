#if os(iOS)
import Foundation
import IrisMobileShellCore
import SwiftUI

/// The Features page's live model (mobile-versions SPEC.md section 1):
/// wires `FeaturesInteraction`'s pure reducer to real
/// `NativeShellLibraryCoordinator` calls, the same split
/// `NativeStorageAppUsageModel` already uses (state lives in `@Published`
/// properties, every I/O path runs inside a `Task` that reports its result
/// back through `dispatch(.operationSucceeded/.operationFailed)`).
///
/// Honest backend note (see FeaturesRows.swift's own doc comment): this
/// model is built against TODAY's `NativeRevisionStore`
/// (`NativeShellLibraryCoordinator.activate`/`revert`/`pin`/`unpin`/
/// `pruneStorage`), not the new-but-unwired MV1 content-addressed
/// `NativeVersionStore`. Two actions the phone genuinely cannot do against
/// that backend yet are modeled honestly rather than faked:
/// - `tappedDownload` / a `.notOnThisPhone` row: never produced today
///   (`FeaturesRows` never emits that state pre-MV2's storage-engine swap),
///   so `download(_:)` is unreachable from the real UI; it is still wired
///   (throws `.unsupported`) so `FeaturesInteraction`'s `.downloading` path
///   has a real, testable implementation once a future unit turns on
///   partial-eviction.
/// - Undo: `NativeShellLibraryCoordinator` has no separate "undo the last
///   swap" call; `undo()` re-issues the coordinator call for the offer's
///   `toRevisionId` (a second, ordinary `revert`/`activate`), which is
///   observably identical to a real undo for every state this reducer can
///   reach (the offer only ever names a revision this same session just
///   moved away from).
@MainActor
final class FeaturesModel: ObservableObject {
    enum ModelError: Error, LocalizedError {
        case unsupported
        var errorDescription: String? {
            "This phone cannot do that yet. It needs Iris on the Mac."
        }
    }

    @Published private(set) var state: FeaturesState = .idle
    @Published private(set) var entry: NativeShellLibraryEntry?
    @Published private(set) var pinnedRevisionIds: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadErrorMessage: String?
    /// Bumped after every settled operation so a container view can re-run
    /// `pruneStorage`-derived space-used text without this model owning
    /// byte-formatting itself (SPEC 1.1's "space used" line reads storage
    /// usage the same way `NativeStorageAppUsageModel` already does; MV4
    /// intentionally does not duplicate that formatting here).
    @Published private(set) var lastSettledAt: Date?

    let identity: NativeShellAppIdentity
    private let coordinator: NativeShellLibraryCoordinator
    /// SPEC 2.4: "after two unsettled checks" the honest stuck sentence
    /// shows. Kept outside the pure reducer (it is a count across calls,
    /// not a state), reset whenever recovery reports clean.
    private var unsettledCheckCount = 0

    init(coordinator: NativeShellLibraryCoordinator, identity: NativeShellAppIdentity) {
        self.coordinator = coordinator
        self.identity = identity
    }

    var rows: [FeaturesRow] {
        guard let entry else { return [] }
        return FeaturesRows.rows(for: entry, pinnedRevisionIds: pinnedRevisionIds)
    }

    func dispatch(_ action: FeaturesAction) {
        // `.setRemoveAppDeleteData` is a no-op in the reducer on purpose
        // (the toggle's own boolean lives in the view's `@State`); every
        // other action that leaves `state` unchanged is a guard the reducer
        // itself already enforced (busy-gating, wrong-phase taps), so there
        // is nothing for this model to run either.
        let next = FeaturesInteraction.reduce(state, action)
        guard next != state else { return }
        state = next
        runEffect(for: action, enteringState: next)
    }

    func load() {
        isLoading = true
        loadErrorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                entry = try await coordinator.libraryEntry(identity: identity)
                pinnedRevisionIds = Set(try await coordinator.pinnedRevisionIds(identity: identity))
            } catch {
                loadErrorMessage = "This app's features could not be read right now."
            }
        }
    }

    // MARK: - Effects

    private func runEffect(for action: FeaturesAction, enteringState: FeaturesState) {
        switch action {
        case .confirm:
            switch enteringState {
            case .removing(let revisionId, let kind, _):
                runSwap(revisionId: revisionId, kind: kind)
            case .removingApp:
                break // waits for the view's own confirm/cancel on the toggle sheet.
            default:
                break
            }

        case .tappedSwitchOn(let revisionId):
            if case .removing(let revisionId, let kind, _) = enteringState {
                runSwap(revisionId: revisionId, kind: kind)
            }
            _ = revisionId

        case .tappedFreeUpSpace:
            runFreeUpSpace()

        case .tappedUndo:
            if case .removing(let revisionId, let kind, _) = enteringState {
                runSwap(revisionId: revisionId, kind: kind)
            }

        case .tappedDownload:
            if case .downloading = enteringState {
                Task {
                    // SPEC honesty note above: unreachable from real rows
                    // today; fails closed rather than pretending to work.
                    dispatch(.operationFailed(
                        reason: ModelError.unsupported.errorDescription ?? "Not supported yet.",
                        nextStep: nil
                    ))
                }
            }

        case .checkAgain:
            runRecoveryCheck()

        default:
            break
        }
    }

    private func runSwap(revisionId: String, kind: FeaturesOperationKind) {
        let fromRevisionId = entry?.currentRevisionId
        Task {
            do {
                switch kind {
                case .goBack, .removeNewest, .undo:
                    try await coordinator.revert(identity: identity, to: revisionId)
                case .activate:
                    try await coordinator.activate(identity: identity, revisionId: revisionId)
                }
                entry = try await coordinator.libraryEntry(identity: identity)
                lastSettledAt = Date()
                let message = doneMessage(for: kind)
                let undo: FeaturesUndoOffer? = {
                    guard kind != .undo, let fromRevisionId, fromRevisionId != revisionId else { return nil }
                    return FeaturesUndoOffer(fromRevisionId: revisionId, toRevisionId: fromRevisionId, label: "Undo")
                }()
                dispatch(.operationSucceeded(kind: kind, message: message, undo: undo))
            } catch {
                dispatch(.operationFailed(
                    reason: "That could not be finished. Nothing was changed.",
                    nextStep: "Try again"
                ))
            }
        }
    }

    private func runFreeUpSpace() {
        Task {
            do {
                _ = try await coordinator.pruneStorage(identity: identity)
                entry = try await coordinator.libraryEntry(identity: identity)
                lastSettledAt = Date()
                dispatch(.operationSucceeded(kind: .goBack, message: "Freed up space.", undo: nil))
            } catch {
                dispatch(.operationFailed(reason: "Could not free up space right now.", nextStep: "Try again"))
            }
        }
    }

    private func runRecoveryCheck() {
        Task {
            do {
                entry = try await coordinator.libraryEntry(identity: identity)
                unsettledCheckCount = 0
                dispatch(.recoveryReportedClean)
            } catch {
                unsettledCheckCount += 1
                dispatch(.recoveryReportedPaused(stuck: unsettledCheckCount >= 2))
            }
        }
    }

    func pin(_ revisionId: String) {
        Task {
            do {
                try await coordinator.pin(identity: identity, revisionId: revisionId)
                pinnedRevisionIds = Set(try await coordinator.pinnedRevisionIds(identity: identity))
            } catch {
                loadErrorMessage = "That version could not be pinned right now."
            }
        }
    }

    func unpin(_ revisionId: String) {
        Task {
            do {
                try await coordinator.unpin(identity: identity, revisionId: revisionId)
                pinnedRevisionIds = Set(try await coordinator.pinnedRevisionIds(identity: identity))
            } catch {
                loadErrorMessage = "That version could not be unpinned right now."
            }
        }
    }

    private func doneMessage(for kind: FeaturesOperationKind) -> String {
        switch kind {
        case .goBack: return "Went back."
        case .removeNewest: return "Removed."
        case .activate: return "Switched on."
        case .undo: return "Undone."
        }
    }
}

/// One model per installed app, same lifetime and reasoning as
/// `NativeStorageAppUsageModelCache`: the Features page and (later) any
/// other surface that needs this app's live swap state observe the same
/// `@Published` values.
@MainActor
enum FeaturesModelCache {
    private static var models: [NativeShellAppIdentity: FeaturesModel] = [:]

    static func model(coordinator: NativeShellLibraryCoordinator, identity: NativeShellAppIdentity) -> FeaturesModel {
        if let existing = models[identity] { return existing }
        let created = FeaturesModel(coordinator: coordinator, identity: identity)
        models[identity] = created
        return created
    }

    /// Test-only: a fresh process-wide cache.
    static func resetForTesting() { models = [:] }
}
#endif
