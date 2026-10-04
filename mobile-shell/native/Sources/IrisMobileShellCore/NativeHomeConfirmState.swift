import Foundation

/// Identifies one app-open episode for the Home confirmation dialog. Callers
/// pass the same value the Host already keys a presentation on (for example
/// `NativeShellAppModel.launchPresentationID`); a new value means a
/// different app is now showing, even if the reader never closed anything.
public struct NativeHomeConfirmToken: Equatable, Hashable, Sendable {
    public let presentationID: UUID

    public init(presentationID: UUID) {
        self.presentationID = presentationID
    }
}

/// Decides whether a tap on the floating Home button should open the "Go
/// back to Iris home?" confirmation, and whether a later action on that
/// confirmation should actually do anything. Pure value type: every rule
/// here is testable with `swift test`, with no SwiftUI, no gesture, no
/// timer involved.
///
/// The three behaviors this exists to guarantee:
/// - a double tap on Home opens exactly one dialog, never two;
/// - "Stay" and "Go" only take effect for the exact confirmation that is
///   currently open, so a stale/duplicate callback is a no-op;
/// - when the app's presentation changes or closes while the dialog is up,
///   the dialog is dropped and nothing it would have done fires.
public struct NativeHomeConfirmState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case confirming
    }

    public private(set) var phase: Phase = .idle
    public private(set) var token: NativeHomeConfirmToken?

    public init() {}

    /// A tap on the floating Home button while `token`'s app is showing.
    /// Returns `true` exactly when a new dialog should be shown. A second
    /// tap while the dialog for the same token is already open (a hurried
    /// double tap) returns `false`: the existing dialog stands, no second
    /// one opens. A tap for a different token (the presentation changed
    /// since the state last saw it) starts a fresh confirmation instead of
    /// reusing a stale one.
    @discardableResult
    public mutating func requestConfirm(for token: NativeHomeConfirmToken) -> Bool {
        if phase == .confirming, self.token == token { return false }
        self.token = token
        phase = .confirming
        return true
    }

    /// The reader tapped "Stay in <app>". Returns `true` when that actually
    /// dismissed an open confirmation for this exact token; `false` for a
    /// stale call (the dialog already closed, or a different token is now
    /// current) so the caller never treats it as a real cancellation twice.
    @discardableResult
    public mutating func cancel(for token: NativeHomeConfirmToken) -> Bool {
        guard phase == .confirming, self.token == token else { return false }
        phase = .idle
        return true
    }

    /// The reader tapped "Go to Iris home". Returns `true` exactly once for
    /// a given open confirmation, telling the caller it is now safe to run
    /// the real close; a repeated or stale activation (for example two
    /// nearly-simultaneous taps on the confirm button) returns `false` and
    /// must not close a second time.
    @discardableResult
    public mutating func confirm(for token: NativeHomeConfirmToken) -> Bool {
        guard phase == .confirming, self.token == token else { return false }
        phase = .idle
        return true
    }

    /// The app's presentation changed underneath the dialog (a different
    /// app opened reusing the same view, or this one closed by some other
    /// path while the dialog was up). Any open confirmation for the old
    /// token is dropped without acting; a later `requestConfirm` for the
    /// new token starts clean.
    public mutating func presentationChanged(to newToken: NativeHomeConfirmToken?) {
        guard token != newToken else { return }
        token = newToken
        phase = .idle
    }
}
