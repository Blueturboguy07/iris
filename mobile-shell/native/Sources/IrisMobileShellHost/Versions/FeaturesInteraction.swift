import Foundation

/// The Features page's state machine (mobile-versions SPEC.md section 1.3):
/// "Mirrors the desktop reducer `FeatureVersionHistoryInteraction.reduce`
/// ... plus two phone-only states: `downloading(row, percent)` and
/// `explainingMacRemoval`." Pure: no file I/O, no coordinator, no `Task`.
/// The rules kept exactly, each with the test that exercises it in
/// `FeaturesInteractionTests`:
///
/// - A double tap never starts a second operation (`isBusy` gates every
///   tap-triggered action while `removing`/`downloading`).
/// - Return and tap-outside never remove (the confirmation sheet's default
///   button is always "Keep it"/cancel; only an explicit `.confirm` action
///   can move past `confirming`).
/// - Every state except `removing` has a way out (`confirming` has cancel,
///   `done`/`failed` clear on the next tap, `paused` offers "Check again",
///   `downloading` can be cancelled, `explainingMacRemoval` has "OK").
/// - Reopening the page during a live operation shows the running row, not
///   a paused banner (D2 A.7.3): this reducer has no separate "paused
///   banner vs. live row" distinction to begin with -- `removing`/
///   `downloading` themselves ARE what the row shows, so there is nothing
///   to get out of sync on reopen. `paused`/`pausedStuck` only ever come
///   from `recoverIfNeeded` reporting an unsettled journal, never from
///   simply closing and reopening a live operation.
/// - The 200 ms rule for every tap: this reducer has no timer of its own
///   (SPEC's 200 ms is a debounce the view's button action applies before
///   ever dispatching; nothing here needs to know about it).
public enum FeaturesPhase: Equatable, Sendable {
    case gettingReady
    case checkingStoredFiles
    case puttingInPlace
    case finishingUp

    /// The exact sentence shown under the row (SPEC 1.3), `<name>` filled
    /// in by the caller since this type carries no app identity.
    public func sentence(appName: String) -> String {
        switch self {
        case .gettingReady: return "Getting ready."
        case .checkingStoredFiles: return "Checking the stored files."
        case .puttingInPlace: return "Putting \(appName) in place."
        case .finishingUp: return "Finishing up."
        }
    }
}

/// SPEC 1.2's "Undo" row: the pair a successful Go back or Remove offers,
/// until the next swap clears it.
public struct FeaturesUndoOffer: Equatable, Sendable {
    public let fromRevisionId: String
    public let toRevisionId: String
    public let label: String

    public init(fromRevisionId: String, toRevisionId: String, label: String) {
        self.fromRevisionId = fromRevisionId
        self.toRevisionId = toRevisionId
        self.label = label
    }
}

public enum FeaturesOperationKind: Equatable, Sendable {
    case goBack
    /// "Remove (the newest feature)" (SPEC 1.2): mechanically the same
    /// swap as `goBack`, to the row's own `baseRevisionId`, but the
    /// confirmation copy and the ledger kind differ.
    case removeNewest
    case activate
    case undo
}

public enum FeaturesConfirmation: Equatable, Sendable {
    case goBack(revisionId: String, title: String)
    case removeNewest(revisionId: String, title: String)
    case removeApp

    public var revisionId: String? {
        switch self {
        case .goBack(let id, _), .removeNewest(let id, _): return id
        case .removeApp: return nil
        }
    }
}

public enum FeaturesState: Equatable, Sendable {
    case idle
    case confirming(FeaturesConfirmation)
    /// Also used for Go back (SPEC 1.3: "`removing` on the phone is under
    /// 1 s"); `kind` distinguishes the two only for the done/undo copy.
    case removing(revisionId: String, kind: FeaturesOperationKind, phase: FeaturesPhase)
    case downloading(revisionId: String, percent: Int)
    case done(message: String, undo: FeaturesUndoOffer?)
    case failed(reason: String, nextStep: String?)
    case paused
    case pausedStuck
    case explainingMacRemoval(title: String)
    case removingApp(alsoDeletingData: Bool)

    /// SPEC 1.3: a double tap never starts a second operation. The view's
    /// button action checks this before dispatching a starting action, and
    /// the reducer itself refuses to leave `idle`/`done`/`failed`/`paused`
    /// a second time for a starting action while already busy (defense in
    /// depth: correct even if the view forgets to check).
    public var isBusy: Bool {
        switch self {
        case .removing, .downloading, .removingApp: return true
        case .idle, .confirming, .done, .failed, .paused, .pausedStuck, .explainingMacRemoval: return false
        }
    }
}

public enum FeaturesAction: Equatable, Sendable {
    case tappedGoBack(revisionId: String, title: String)
    case tappedSwitchOn(revisionId: String)
    case tappedRemove(revisionId: String, title: String, isNewest: Bool)
    case tappedRemoveOlderOnPhone(title: String)
    case tappedDownload(revisionId: String)
    case cancelDownload
    case downloadProgressed(percent: Int)
    case tappedFreeUpSpace
    case tappedRemoveApp
    case setRemoveAppDeleteData(Bool)
    case tappedUndo
    case confirm
    case cancelConfirmation
    case dismissMacRemovalSheet
    case checkAgain
    case dismissBanner
    /// Effect completions: the model (I/O) reports these; the reducer only
    /// decides the next state.
    case operationSucceeded(kind: FeaturesOperationKind, message: String, undo: FeaturesUndoOffer?)
    case operationFailed(reason: String, nextStep: String?)
    case recoveryReportedClean
    case recoveryReportedPaused(stuck: Bool)
}

public enum FeaturesInteraction {
    /// One step of the reducer. Pure: given the same `(state, action)` this
    /// always returns the same next state, and never performs I/O itself
    /// -- the model dispatches `operationSucceeded`/`operationFailed` back
    /// in once its own `Task` finishes, exactly like the desktop reducer's
    /// own split between "what state means" and "what runs it".
    public static func reduce(_ state: FeaturesState, _ action: FeaturesAction) -> FeaturesState {
        switch action {
        case .tappedGoBack(let revisionId, let title):
            guard !state.isBusy else { return state }
            return .confirming(.goBack(revisionId: revisionId, title: title))

        case .tappedRemove(let revisionId, let title, let isNewest):
            guard !state.isBusy else { return state }
            return .confirming(.removeNewest(revisionId: revisionId, title: title))

        case .tappedRemoveOlderOnPhone(let title):
            guard !state.isBusy else { return state }
            return .explainingMacRemoval(title: title)

        case .tappedSwitchOn(let revisionId):
            // SPEC 1.1: "Switch on" (pending, `iris.activate.<rev>`, kept) --
            // the existing kept flow has no confirmation step, matching
            // today's `NativeShellAppView` "Activate" button.
            guard !state.isBusy else { return state }
            return .removing(revisionId: revisionId, kind: .activate, phase: .gettingReady)

        case .tappedDownload(let revisionId):
            guard !state.isBusy else { return state }
            return .downloading(revisionId: revisionId, percent: 0)

        case .cancelDownload:
            guard case .downloading = state else { return state }
            return .idle

        case .downloadProgressed(let percent):
            guard case .downloading(let revisionId, _) = state else { return state }
            return .downloading(revisionId: revisionId, percent: percent)

        case .tappedFreeUpSpace:
            guard !state.isBusy else { return state }
            return .removing(revisionId: "", kind: .goBack, phase: .gettingReady)

        case .tappedRemoveApp:
            guard !state.isBusy else { return state }
            return .confirming(.removeApp)

        case .setRemoveAppDeleteData:
            // Only meaningful mid-confirmation; the view keeps the toggle's
            // own boolean, this reducer does not need a case for it beyond
            // staying in `.confirming(.removeApp)`.
            return state

        case .tappedUndo:
            guard !state.isBusy else { return state }
            guard case .done(_, .some(let offer)) = state else { return state }
            return .removing(revisionId: offer.toRevisionId, kind: .undo, phase: .gettingReady)

        case .confirm:
            switch state {
            case .confirming(.goBack(let revisionId, _)):
                return .removing(revisionId: revisionId, kind: .goBack, phase: .gettingReady)
            case .confirming(.removeNewest(let revisionId, _)):
                return .removing(revisionId: revisionId, kind: .removeNewest, phase: .gettingReady)
            case .confirming(.removeApp):
                return .removingApp(alsoDeletingData: false)
            default:
                return state
            }

        case .cancelConfirmation:
            // SPEC 1.3: Return and tap-outside never remove -- this is the
            // ONLY path back to `idle` from `confirming`, and it never
            // performs the operation.
            guard case .confirming = state else { return state }
            return .idle

        case .dismissMacRemovalSheet:
            guard case .explainingMacRemoval = state else { return state }
            return .idle

        case .checkAgain:
            // SPEC 2.4: "Check again" finishes or rolls back the journal;
            // the model's recovery call reports back via
            // `.recoveryReportedClean`/`.recoveryReportedPaused`.
            guard case .paused = state else { return state }
            return .paused

        case .dismissBanner:
            switch state {
            case .done, .failed: return .idle
            default: return state
            }

        case .operationSucceeded(let kind, let message, let undo):
            guard case .removing = state else { return state }
            _ = kind
            return .done(message: message, undo: undo)

        case .operationFailed(let reason, let nextStep):
            guard state.isBusy else { return state }
            return .failed(reason: reason, nextStep: nextStep)

        case .recoveryReportedClean:
            guard state == .paused || state == .pausedStuck else { return state }
            return .idle

        case .recoveryReportedPaused(let stuck):
            // SPEC 2.4: "after two unsettled checks" the honest failure
            // sentence appears -- `stuck` is the model's own count, kept
            // outside this pure reducer (it survives only for the process's
            // lifetime, matching a real relaunch resetting it).
            return stuck ? .pausedStuck : .paused
        }
    }
}
