//
//  ScreenLayoutCompliance.swift
//  leanring-buddy
//
//  Whether Iris's full-screen overlays still fit the displays that are
//  actually connected, and what to do about it when they do not.
//
//  THE BUG THIS EXISTS FOR (Sep 2 2026). Iris was launched with a 3440x1440
//  external display attached, so `OverlayWindowManager` built one overlay per
//  display — including one sized 3440x1440 for the external one. That display
//  was then unplugged. macOS moved the orphaned overlay onto the only screen
//  left, the 1512x982 built-in, but kept its 3440x1440 SIZE — and nothing in
//  Iris noticed, because no observer of
//  `NSApplication.didChangeScreenParametersNotification` existed anywhere in
//  the app. Measured live: the relocated window's top edge sat 458pt above the
//  top of the built-in display, the eye rests ~109pt below the top of its
//  window, so the eye was being drawn ~350pt above the visible screen.
//  Reported as "I can't see Iris on my screen and I think it's because it's
//  out of bounds", which is exactly what it was.
//
//  Two mechanisms answer it, deliberately redundant:
//
//  1. The notification. AppKit posts it on every display connect, disconnect,
//     resolution or arrangement change. It also posts it for Dock and
//     menu-bar changes, which move a screen's `visibleFrame` but not its
//     `frame` — those are filtered out here by comparing frames, so an open
//     exchange is never torn down because the Dock resized.
//
//  2. A periodic audit, every `auditInterval`. The notification is reliable
//     when it fires, but the app cannot prove it was not missed (a blocked main
//     thread, a window the window server moved on its own), and the cost of
//     checking is one small array of rects compared every couple of seconds.
//     The reader asked for "a compliance check every time the screen
//     re-renders"; this is that check, at a cadence that costs nothing.
//
//  Both paths feed the same pure verdict below, so the decision is testable
//  without a display and identical whichever path asked for it.
//

import CoreGraphics
import Foundation

enum ScreenLayoutCompliance {

    /// How often the overlay manager re-checks its windows against the
    /// connected displays even when no notification has arrived.
    static let auditInterval: TimeInterval = 2

    /// How far a window's frame may differ from its screen's before it counts
    /// as having drifted. AppKit can report a frame a fraction of a point off
    /// (Retina rounding), and re-setting it every two seconds for that would
    /// be churn for nothing.
    static let frameDriftTolerance: CGFloat = 0.5

    /// What the overlay manager should do, given what it built its windows
    /// for and what is connected now.
    enum Verdict: Equatable {
        /// Every overlay window matches a connected display. Nothing to do.
        case everyOverlayFitsItsScreen

        /// The set of displays changed — one was added, removed, resized or
        /// rearranged — or a window went missing. The per-screen overlays have
        /// to be rebuilt, because each one bakes its screen's frame into its
        /// SwiftUI content at creation and cannot be resized in place.
        case rebuildTheOverlaysForTheCurrentScreens

        /// The displays are unchanged but one or more overlay windows sit at a
        /// different frame from the one they were given — the window server
        /// moved them. Put each listed window (by index) back at the frame it
        /// should have. No rebuild: the content is still right, only the
        /// window moved.
        case putTheseOverlaysBackOnTheirScreens([Int: CGRect])

        /// There is no display to show anything on — a clamshell Mac with
        /// nothing plugged in, or the middle of a reconfiguration. Leave
        /// everything alone; the next change brings a screen back and the
        /// check runs again.
        case noScreenToShowOn
    }

    /// The decision, from three facts: the screen frames the overlays were
    /// built for (one per overlay, in `NSScreen.screens` order), the screen
    /// frames connected right now (same order), and where each overlay window
    /// actually is.
    static func verdict(
        overlaysWereBuiltForScreenFrames builtForScreenFrames: [CGRect],
        currentScreenFrames: [CGRect],
        liveOverlayWindowFrames: [CGRect]
    ) -> Verdict {
        guard !currentScreenFrames.isEmpty else { return .noScreenToShowOn }

        guard currentScreenFrames == builtForScreenFrames else {
            return .rebuildTheOverlaysForTheCurrentScreens
        }

        // Fewer windows than screens means the manager lost one somewhere; a
        // rebuild is the only way to get the missing screen its eye back.
        guard liveOverlayWindowFrames.count >= builtForScreenFrames.count else {
            return .rebuildTheOverlaysForTheCurrentScreens
        }

        var overlaysThatDrifted: [Int: CGRect] = [:]
        for (overlayIndex, frameTheOverlayShouldHave) in builtForScreenFrames.enumerated() {
            let frameTheOverlayActuallyHas = liveOverlayWindowFrames[overlayIndex]
            if !framesMatch(frameTheOverlayActuallyHas, frameTheOverlayShouldHave) {
                overlaysThatDrifted[overlayIndex] = frameTheOverlayShouldHave
            }
        }

        if overlaysThatDrifted.isEmpty {
            return .everyOverlayFitsItsScreen
        }
        return .putTheseOverlaysBackOnTheirScreens(overlaysThatDrifted)
    }

    /// Whether two frames are the same frame for this purpose, allowing
    /// `frameDriftTolerance` on every edge.
    static func framesMatch(_ firstFrame: CGRect, _ secondFrame: CGRect) -> Bool {
        abs(firstFrame.minX - secondFrame.minX) <= frameDriftTolerance
            && abs(firstFrame.minY - secondFrame.minY) <= frameDriftTolerance
            && abs(firstFrame.width - secondFrame.width) <= frameDriftTolerance
            && abs(firstFrame.height - secondFrame.height) <= frameDriftTolerance
    }

    /// Whether a floating window's frame is on ANY of the given screens at
    /// all — some part of it overlaps one of them. A window that fails this is
    /// not slightly off an edge; it is on a display that is gone, and pulling
    /// it to the nearest edge would leave a sliver. The right answer for that
    /// window is to re-place it from scratch on a screen that exists.
    ///
    /// Overlap, deliberately, rather than "its centre is on a screen": the
    /// reader may have tucked the takeover terminal mostly off an edge on
    /// purpose (the drag clamp allows it, keeping the title strip reachable),
    /// and `didChangeScreenParametersNotification` also fires for a Dock
    /// resize. Judging that window by its centre would yank it back to the
    /// middle of the screen because the Dock grew.
    static func frameIsOnSomeScreen(_ frame: CGRect, screenFrames: [CGRect]) -> Bool {
        screenFrames.contains { screenFrame in
            !screenFrame.intersection(frame).isEmpty
        }
    }
}
