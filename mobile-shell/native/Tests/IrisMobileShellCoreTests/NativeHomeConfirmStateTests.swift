import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Behavior tests for `NativeHomeConfirmState`, the pure decision logic
/// behind the floating Home button's "Go back to Iris home?" confirmation.
/// Every assertion here is about what the reader would actually see (one
/// dialog open or none, whether "Go" is allowed to fire a close), never an
/// internal counter this test set up itself.
///
/// Personas: P2 hurried reader who double-taps Home, then taps Stay, then
/// taps Home again and confirms; P3 edge case where the app's presentation
/// changes (or the app closes some other way) while the dialog is open.
final class NativeHomeConfirmStateTests: XCTestCase {
    private func token(_ id: UUID = UUID()) -> NativeHomeConfirmToken {
        NativeHomeConfirmToken(presentationID: id)
    }

    // MARK: - P2: hurried double tap opens exactly one dialog

    func testADoubleTapOnHomeOpensOnlyOneDialog() {
        var state = NativeHomeConfirmState()
        let app = token()

        XCTAssertTrue(state.requestConfirm(for: app), "the first tap opens the dialog")
        XCTAssertEqual(state.phase, .confirming)

        XCTAssertFalse(state.requestConfirm(for: app), "a second, hurried tap must not open a second dialog")
        XCTAssertEqual(state.phase, .confirming, "the one dialog from the first tap is still the one showing")
    }

    // MARK: - P2: Stay leaves the reader in the app

    func testTappingStayClosesTheDialogAndDoesNothingElse() {
        var state = NativeHomeConfirmState()
        let app = token()
        state.requestConfirm(for: app)

        XCTAssertTrue(state.cancel(for: app), "Stay dismisses the open dialog")
        XCTAssertEqual(state.phase, .idle, "the reader is back to seeing the app with no dialog up")

        // A stray second delivery of the same Stay tap (for example a
        // double-tap on the button itself) must not report a fresh
        // cancellation, since there is nothing open to cancel any more.
        XCTAssertFalse(state.cancel(for: app))
    }

    // MARK: - P2: Home, then Go, closes exactly once

    func testTappingHomeThenGoAuthorizesExactlyOneClose() {
        var state = NativeHomeConfirmState()
        let app = token()
        state.requestConfirm(for: app)

        XCTAssertTrue(state.confirm(for: app), "Go authorizes the real close for this exact dialog")
        XCTAssertEqual(state.phase, .idle)

        // Two swift taps on "Go" (or a duplicate delivery) must never
        // authorize a second close.
        XCTAssertFalse(state.confirm(for: app), "a second activation of Go must not fire a second close")
    }

    func testGoWithoutAnOpenDialogNeverAuthorizesAClose() {
        // A stale or out-of-order call: nothing was ever confirmed, so Go
        // must refuse rather than silently authorizing a close no dialog
        // ever asked for.
        var state = NativeHomeConfirmState()
        XCTAssertFalse(state.confirm(for: token()))
    }

    // MARK: - P3: presentation changes (or the app closes) while the dialog is open

    func testWhenTheAppsPresentationChangesWhileTheDialogIsOpenItGoesAwayAndDoesNothing() {
        var state = NativeHomeConfirmState()
        let firstApp = token()
        state.requestConfirm(for: firstApp)
        XCTAssertEqual(state.phase, .confirming)

        // A different app now occupies the same on-screen slot (or this one
        // closed through some other path) before the reader answered.
        let secondApp = token()
        state.presentationChanged(to: secondApp)
        XCTAssertEqual(state.phase, .idle, "the stale dialog is dropped, not carried into the new app")

        // Whatever button the reader's finger was already moving toward
        // must not still be able to act on the app that is gone.
        XCTAssertFalse(state.confirm(for: firstApp), "Go for the old app must not fire once it is gone")
        XCTAssertFalse(state.cancel(for: firstApp), "Stay for the old app is likewise inert")

        // The new app's own Home tap starts a completely fresh dialog.
        XCTAssertTrue(state.requestConfirm(for: secondApp))
    }

    func testPresentationChangedToTheSameTokenIsANoOpAndLeavesAnOpenDialogAlone() {
        var state = NativeHomeConfirmState()
        let app = token()
        state.requestConfirm(for: app)
        state.presentationChanged(to: app)
        XCTAssertEqual(state.phase, .confirming, "nothing actually changed, so the open dialog must stand")
    }

    func testPresentationClosingEntirelyWhileTheDialogIsOpenAlsoDropsIt() {
        var state = NativeHomeConfirmState()
        let app = token()
        state.requestConfirm(for: app)

        state.presentationChanged(to: nil)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.confirm(for: app))
    }

    // MARK: - A tap on Home for a genuinely new episode always gets a fresh dialog

    func testANewTokenAfterAPriorConfirmationFinishedStartsCleanRatherThanBeingBlocked() {
        var state = NativeHomeConfirmState()
        let firstApp = token()
        state.requestConfirm(for: firstApp)
        state.cancel(for: firstApp)

        let secondApp = token()
        XCTAssertTrue(state.requestConfirm(for: secondApp), "opening a fresh app must always be able to open its own dialog")
    }
}
