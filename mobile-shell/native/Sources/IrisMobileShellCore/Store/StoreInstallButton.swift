import Foundation

// Unit M2-store-layout-implementation. The one Get button (design section
// 6.2) as a pure state machine. Two inputs:
// - facts: what is true now (listed for iPhone, installed revision, blocked,
//   age, online), recomputed on every render;
// - activity: what this button is doing (a download in flight, a failure),
//   changed only by `reduce`.
// The button's label is a function of both. A tap is an event; the reducer
// returns the one effect the Host must run (or none). A second tap while a
// download or verification is running returns no effect: it only keeps
// showing progress.

public struct StoreInstallFacts: Equatable, Sendable {
    public enum Listing: Equatable, Sendable {
        /// The row is in the index but its descriptor has not been read yet
        /// (index v2 rows carry none). A tap still installs through the flow,
        /// which reads the descriptor itself.
        case notYetChecked
        /// An installable iPhone package is listed.
        case listed(revisionId: String, baseRevisionId: String?)
        /// The catalog has no iPhone package (or not for this OS).
        case unavailable(reason: String)
    }

    public enum Restriction: Equatable, Sendable {
        case none
        case blocked
        /// The rating is above the shell's rating and this phone has no
        /// declared age (or one that is too low), or no rating is published
        /// for an index v2 row (fails closed). `canCheckAge` is true when
        /// the age sheet can be opened (RC-02); false when there is no
        /// rating to check against.
        case age(rating: Int?, message: String, canCheckAge: Bool)
    }

    public var appName: String
    public var listing: Listing
    /// The current revision of the installed copy, if any.
    public var installedRevisionId: String?
    public var restriction: Restriction
    public var isOnline: Bool
    /// Set when the OS reports low storage and this would be an update.
    public var updateNeedsBytes: Int64?

    public init(
        appName: String,
        listing: Listing,
        installedRevisionId: String? = nil,
        restriction: Restriction = .none,
        isOnline: Bool = true,
        updateNeedsBytes: Int64? = nil
    ) {
        self.appName = appName
        self.listing = listing
        self.installedRevisionId = installedRevisionId
        self.restriction = restriction
        self.isOnline = isOnline
        self.updateNeedsBytes = updateNeedsBytes
    }
}

public enum StoreInstallActivity: Equatable, Sendable {
    case idle
    /// Percent is nil until the first byte count arrives.
    case downloading(percent: Int?)
    case verifying
    /// The install finished; shows Open until the library list catches up.
    case installed(revisionId: String)
    case failed(message: String)
    /// The package asks for something this iPhone cannot give. Nothing was installed.
    case unsupported(reason: String)
    /// A tap that could not start, with the one line that says why.
    case note(StoreInstallNote)
}

public enum StoreInstallNote: Equatable, Sendable {
    case offline
    case anotherInstallRunning
    case lowStorage(bytes: Int64)
}

public enum StoreInstallEvent: Equatable, Sendable {
    case tap
    case cancelTap
    case downloadProgress(percent: Int?)
    case verifying
    case finished(revisionId: String)
    case failed(message: String)
    case unsupported(reason: String)
    case cancelled
    case backOnline
}

public enum StoreInstallEffect: Equatable, Sendable {
    case none
    case startInstall
    case cancelInstall
    case open
    case unblock
    case checkAge
}

/// What the button shows. `label` is the visible text; `stateWord` is the
/// accessibility value tests and VoiceOver read; `note` is the one line under
/// the button (also part of the accessibility value).
public struct StoreInstallButtonState: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case get = "Get"
        case downloading = "Downloading"
        case verifying = "Verifying"
        case open = "Open"
        case update = "Update"
        case unavailable = "Unavailable"
        case restricted = "Restricted"
        case blocked = "Blocked"
        case failed = "Failed"
    }

    public let kind: Kind
    public let label: String
    public let note: String?
    /// True while a tap would do nothing but keep showing progress.
    public let isBusy: Bool
    /// Downloading progress, 0...100, for the fill.
    public let percent: Int?
    /// Whether the control is shown as a button at all (restricted with no
    /// approved age check and unavailable show text only).
    public let isActionable: Bool

    public var stateWord: String { kind.rawValue }

    public var accessibilityValue: String {
        guard let note, !note.isEmpty else { return stateWord }
        return stateWord + ", " + note
    }

    public func accessibilityLabel(appName: String) -> String {
        switch kind {
        case .get: return "Get \(appName)"
        case .downloading: return "Downloading \(appName)" + (percent.map { ", \($0) percent" } ?? "") + ", in progress"
        case .verifying: return "Verifying \(appName), in progress"
        case .open: return "Open \(appName)"
        case .update: return "Update \(appName)"
        case .unavailable: return "Unavailable on this iPhone"
        case .restricted: return label
        case .blocked: return "Unblock \(appName)"
        case .failed: return "Try again"
        }
    }
}

public enum StoreInstallMachine {
    public static func state(facts: StoreInstallFacts, activity: StoreInstallActivity) -> StoreInstallButtonState {
        switch facts.restriction {
        case .blocked:
            return StoreInstallButtonState(kind: .blocked, label: "Unblock", note: "You blocked this app on this iPhone.", isBusy: false, percent: nil, isActionable: true)
        case .age(let rating, let message, let canCheckAge):
            // RC-02: a rated app above the shell rating always offers the
            // age check (the sheet is wired); only an app whose rating is
            // not published at all has nothing to check against.
            let label: String
            if let rating {
                label = "Rated \(Self.ratingText(rating)) · Check your age"
            } else {
                label = "Age rating not published"
            }
            return StoreInstallButtonState(
                kind: .restricted, label: label,
                note: message,
                isBusy: false, percent: nil, isActionable: canCheckAge)
        case .none:
            break
        }
        switch activity {
        case .downloading(let percent):
            let clamped = percent.map { min(100, max(0, $0)) }
            return StoreInstallButtonState(kind: .downloading, label: clamped.map { "Downloading \($0)%" } ?? "Downloading", note: nil, isBusy: true, percent: clamped, isActionable: true)
        case .verifying:
            return StoreInstallButtonState(kind: .verifying, label: "Verifying", note: nil, isBusy: true, percent: 100, isActionable: true)
        case .failed(let message):
            return StoreInstallButtonState(kind: .failed, label: "Try again", note: message, isBusy: false, percent: nil, isActionable: true)
        case .unsupported(let reason):
            return unavailable(reason)
        case .installed:
            // `finished` only reaches this activity after a real, completed
            // install of this exact app (see StoreInstallController.finish).
            // The Host's `facts.installedRevisionId` is a separately
            // refreshed copy of the library list and can still name the
            // OLD revision for a moment (an update) or be nil (a fresh
            // install) right after this fires. Either way the button must
            // read Open until `settle(slug:)` clears this activity, or a tap
            // in that window falls through to `resting(facts)` and can
            // start a second install of the app that was just installed.
            return StoreInstallButtonState(kind: .open, label: "Open", note: nil, isBusy: false, percent: nil, isActionable: true)
        case .idle, .note:
            break
        }
        let base = resting(facts)
        guard case .note(let note) = activity, base.kind == .get || base.kind == .update else { return base }
        return StoreInstallButtonState(kind: base.kind, label: base.label, note: text(note, appName: facts.appName), isBusy: false, percent: nil, isActionable: true)
    }

    /// The label with nothing in flight.
    static func resting(_ facts: StoreInstallFacts) -> StoreInstallButtonState {
        switch facts.listing {
        case .unavailable(let reason):
            if facts.installedRevisionId != nil { return open }
            return unavailable(reason)
        case .notYetChecked:
            return facts.installedRevisionId != nil ? open : get
        case .listed(let revisionId, _):
            guard let installed = facts.installedRevisionId else { return get }
            if installed == revisionId { return open }
            if let needs = facts.updateNeedsBytes {
                return StoreInstallButtonState(kind: .update, label: "Update", note: text(.lowStorage(bytes: needs), appName: facts.appName), isBusy: false, percent: nil, isActionable: true)
            }
            return StoreInstallButtonState(kind: .update, label: "Update", note: nil, isBusy: false, percent: nil, isActionable: true)
        }
    }

    public static func reduce(
        activity: StoreInstallActivity,
        event: StoreInstallEvent,
        facts: StoreInstallFacts,
        anotherInstallRunning: Bool
    ) -> (StoreInstallActivity, StoreInstallEffect) {
        let shown = state(facts: facts, activity: activity)
        switch event {
        case .tap:
            switch shown.kind {
            case .downloading, .verifying, .unavailable:
                return (activity, .none)
            case .open:
                // Keep a just-finished install showing Open until the
                // library list catches up; opening changes nothing here.
                return (activity, .open)
            case .blocked:
                return (.idle, .unblock)
            case .restricted:
                return (activity, shown.isActionable ? .checkAge : .none)
            case .get, .update, .failed:
                if !facts.isOnline { return (.note(.offline), .none) }
                if anotherInstallRunning { return (.note(.anotherInstallRunning), .none) }
                if shown.kind == .update, let needs = facts.updateNeedsBytes { return (.note(.lowStorage(bytes: needs)), .none) }
                return (.downloading(percent: nil), .startInstall)
            }
        case .cancelTap:
            guard shown.kind == .downloading else { return (activity, .none) }
            return (activity, .cancelInstall)
        case .downloadProgress(let percent):
            guard case .downloading(let old) = activity else { return (activity, .none) }
            // Progress never runs backwards on screen.
            let next = [old, percent].compactMap { $0 }.max()
            return (.downloading(percent: next), .none)
        case .verifying:
            switch activity {
            case .downloading, .verifying: return (.verifying, .none)
            default: return (activity, .none)
            }
        case .finished(let revisionId):
            switch activity {
            case .downloading, .verifying: return (.installed(revisionId: revisionId), .none)
            default: return (activity, .none)
            }
        case .failed(let message):
            switch activity {
            case .downloading, .verifying: return (.failed(message: message), .none)
            default: return (activity, .none)
            }
        case .unsupported(let reason):
            switch activity {
            case .downloading, .verifying: return (.unsupported(reason: reason), .none)
            default: return (activity, .none)
            }
        case .cancelled:
            switch activity {
            case .downloading, .verifying: return (.idle, .none)
            default: return (activity, .none)
            }
        case .backOnline:
            if case .note(.offline) = activity { return (.idle, .none) }
            return (activity, .none)
        }
    }

    public static func text(_ note: StoreInstallNote, appName: String) -> String {
        switch note {
        case .offline: return "Connect to the internet to get \(appName)."
        case .anotherInstallRunning: return "Another app is still installing. Try again when it finishes."
        case .lowStorage(let bytes): return "Needs \(megabytes(bytes)) MB free."
        }
    }

    static func megabytes(_ bytes: Int64) -> Int64 { max(1, (bytes + 999_999) / 1_000_000) }

    static func ratingText(_ rating: Int) -> String { "\(rating)+" }

    private static let get = StoreInstallButtonState(kind: .get, label: "Get", note: nil, isBusy: false, percent: nil, isActionable: true)
    private static let open = StoreInstallButtonState(kind: .open, label: "Open", note: nil, isBusy: false, percent: nil, isActionable: true)

    private static func unavailable(_ reason: String) -> StoreInstallButtonState {
        StoreInstallButtonState(kind: .unavailable, label: "Unavailable on this iPhone", note: reason, isBusy: false, percent: nil, isActionable: false)
    }
}

/// Age and block rules for the store, on top of the existing Guideline 4.7
/// policy. Index v2 rows always carry `ageRating` (M3's validator requires it);
/// if one ever does not, the store fails closed (design section 15). Today's
/// v1 rows usually have no rating yet, so they keep the existing m3 rule
/// (no rating never restricts by itself) until Publik publishes ratings:
/// failing closed there would remove Get from every real app on the phone.
public enum StoreRestrictionPolicy {
    public static func restriction(
        app: StoreApp,
        isBlocked: Bool,
        declaredAge: Int?,
        ageCheckApproved: Bool = true
    ) -> StoreInstallFacts.Restriction {
        if isBlocked { return .blocked }
        let rating = app.ageRating
        if rating == nil, app.descriptor == nil, app.iconHash != nil {
            // No rating to check an age against: nothing a person can do here.
            return .age(rating: nil, message: "This app's age rating is not published yet.", canCheckAge: false)
        }
        if case .restricted(let appAgeRating, let declared) = Review47AgeGate.decide(appAgeRating: rating, declaredAge: declaredAge) {
            return .age(
                rating: appAgeRating,
                message: Review47AgeGateCopy.message(appAgeRating: appAgeRating, declaredAge: declared),
                canCheckAge: ageCheckApproved)
        }
        return .none
    }
}
