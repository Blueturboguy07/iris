//
//  IrisOverlayModalAlert.swift
//  leanring-buddy
//
//  ONE PLACE TO LIFT A MODAL ABOVE IRIS'S EYE OVERLAY — so the next alert
//  cannot repeat the freeze.
//
//  Iris lives in the menu bar with no dock icon, and it keeps a full-screen,
//  transparent, click-through eye overlay on screen at `.screenSaver` level at
//  all times. An `NSAlert` this app raises therefore opens UNDER its own
//  windows unless it is deliberately lifted and made key: the reader never sees
//  it, the nested `runModal()` loop runs against a window they cannot reach, and
//  every click and keystroke beeps while the whole Mac reads as frozen — the
//  reader's only way out is a hard restart.
//
//  Three consent alerts in `CompanionManager` (run a command, take control of
//  the Mac, create a local signing certificate) each did this lift by hand. Two
//  of them remembered; the certificate alert did not, and that single omission
//  was the "certifying the fix froze my Mac … the beeping sound every time I
//  tried to interact, so I restarted" report (Publik Test 2, 2026-09-03). It
//  fired on the FIRST edit-delivery on a Mac with no Developer ID — the rebuild
//  that "certifies" a fix is exactly when the stable-identity signing prompts.
//
//  Collapsing the incantation here means an alert is lifted the same way every
//  time, and a new alert site is one call away from being safe rather than one
//  forgotten line away from freezing someone's Mac.
//

import AppKit

enum IrisOverlayModalAlert {

    /// Lifts `alert` above Iris's floating eye overlay and makes it the key
    /// window, so a modal the app raises is actually visible and answerable.
    ///
    /// Call this AFTER the buttons are added and BEFORE `runModal()`, and pair
    /// it with `NSApp.activate(ignoringOtherApps:)` at the top of the alert (the
    /// app has no dock icon, so it must bring itself to the front first). The
    /// `.modalPanel` level and `.moveToActiveSpace` behaviour match the sibling
    /// consent alerts exactly — this is a consolidation of what already worked,
    /// not a new mechanism.
    @MainActor
    static func liftAboveTheEyeOverlay(_ alert: NSAlert) {
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        alert.window.makeKeyAndOrderFront(nil)
    }
}
