//
//  PublikTest2CertifyFreezeReproTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "when certifying the fix it like froze my Mac, couldn't
//  interact with anything with the beeping sound every time I tried to interact
//  with something, so I restarted."
//
//  ROOT CAUSE (Iris 0.9.8): the on-demand edit's delivery step rebuilds the app
//  with a STABLE signing identity so its TCC grants survive — and on the first
//  such delivery on a Mac with no Developer ID, that means prompting the reader
//  to create a local signing certificate. That prompt is an `NSAlert.runModal()`
//  on the main actor. The two sibling consent alerts in `CompanionManager` lift
//  their window above Iris's full-screen `.screenSaver`-level eye overlay and
//  make it key; the certificate alert did NOT. So it opened BEHIND the overlay:
//  the nested modal run loop ran against a window the reader could not see or
//  reach, every click and keystroke beeped, and the whole Mac read as frozen
//  until a hard restart. The rebuild that "certifies" a fix is exactly when this
//  fires — which is why the reader hit it "when certifying the fix".
//
//  THE FIX collapses the lift the working alerts did by hand into one helper,
//  `IrisOverlayModalAlert.liftAboveTheEyeOverlay(_:)`, and routes all three
//  alerts — including the certificate one that forgot — through it, so a modal
//  Iris raises is always visible and answerable.
//
//  WHAT THIS FILE CAN AND CANNOT PROVE. The freeze itself is a window-server
//  layering behaviour that only a live modal over the live overlay exercises —
//  the same "only a live run caught it" shape as the bar's drag-drop window
//  level. What is unit-testable, and what these tests pin, is the CONTRACT the
//  fix rests on: the lift helper applies the exact treatment the sibling alerts
//  use, deterministically, so no alert site can be one forgotten line away from
//  freezing a Mac again.
//

import AppKit
import Testing
@testable import Iris

@Suite(.serialized)
@MainActor
struct PublikTest2CertifyFreezeReproTests {

    /// The lift raises the alert to `.modalPanel` and asks the window server to
    /// bring it to the active Space — the same two properties the working
    /// consent alerts set. The certificate alert set neither, which is why it
    /// opened behind the overlay.
    @Test func theLiftPutsAnAlertAtModalPanelLevelOnTheActiveSpace() {
        let alert = NSAlert()
        alert.messageText = "Create a local signing certificate on this Mac?"
        alert.addButton(withTitle: "Create certificate")
        alert.addButton(withTitle: "Not now")

        IrisOverlayModalAlert.liftAboveTheEyeOverlay(alert)

        #expect(
            alert.window.level == .modalPanel,
            "a lifted alert must sit at .modalPanel like the sibling consent alerts; the certificate alert used to sit at the default level, behind the overlay"
        )
        #expect(
            alert.window.collectionBehavior.contains(.moveToActiveSpace),
            "a lifted alert must be brought to the reader's active Space, or it can open on a Space they are not looking at"
        )
    }

    /// The lift is above an ordinary window's level, so it is never left drawing
    /// beneath normal app windows. (It is a proxy for "reachable over Iris's own
    /// panels", which the working alerts demonstrate in the field; the freeze was
    /// precisely the certificate alert sitting at the un-lifted default.)
    @Test func aLiftedAlertOutranksAnOrdinaryWindow() {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        IrisOverlayModalAlert.liftAboveTheEyeOverlay(alert)

        #expect(
            alert.window.level.rawValue > NSWindow.Level.normal.rawValue,
            "the lifted alert sits at or below an ordinary window, so it can be buried the way the certificate alert was"
        )
    }
}
