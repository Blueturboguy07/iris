//
//  ScreenLayoutComplianceTests.swift
//  leanring-buddyTests
//
//  The decision that keeps Iris's overlays on the displays that exist. The
//  first suite replays the Sep 2 2026 incident with its real numbers; the
//  rest pin every other verdict the check can reach.
//

import CoreGraphics
import Foundation
import Testing

@testable import Iris

/// The two displays involved in the incident, in AppKit screen coordinates.
private let builtInDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let ultrawideDisplay = CGRect(x: 0, y: 0, width: 3440, height: 1440)

@Suite("Screen layout compliance — the unplugged-monitor incident")
struct ScreenLayoutComplianceIncidentTests {

    @Test("an overlay built for a display that was unplugged is rebuilt for the display that remains")
    func rebuildsAfterTheExternalDisplayIsUnplugged() {
        // Iris was launched with the ultrawide as the primary display, and the
        // window server later moved the orphaned overlay to (0, 0) on the
        // built-in — same size, wrong screen.
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [ultrawideDisplay],
            currentScreenFrames: [builtInDisplay],
            liveOverlayWindowFrames: [ultrawideDisplay]
        )
        #expect(verdict == .rebuildTheOverlaysForTheCurrentScreens)
    }

    @Test("the eye's remembered home lands in view once the overlay is rebuilt for the smaller display")
    func theEyeIsBackInViewAfterTheRebuild() {
        // The remembered place on this Mac at the time: (77.9, 109.2) in
        // SwiftUI coordinates. On the stale 1440pt-tall window whose top sat
        // 458pt above the display, that was ~349pt above the visible screen.
        // Re-seeded for the built-in display it is exactly where it was left
        // — and inside the screen.
        let rememberedPlace = CGPoint(x: 77.909299945431, y: 109.20703125)
        let placeOnTheBuiltIn = OverlayEyeRestingPlace.clamped(
            rememberedPlace, toScreenOfSize: builtInDisplay.size
        )
        #expect(placeOnTheBuiltIn == rememberedPlace)
        #expect(placeOnTheBuiltIn.x >= 0 && placeOnTheBuiltIn.x <= builtInDisplay.width)
        #expect(placeOnTheBuiltIn.y >= 0 && placeOnTheBuiltIn.y <= builtInDisplay.height)
    }

    @Test("a home remembered far out on the ultrawide is pulled onto the built-in display")
    func aHomeOffTheSmallerDisplayIsClampedOntoIt() {
        let homeNearTheUltrawidesRightEdge = CGPoint(x: 3300, y: 1300)
        let placeOnTheBuiltIn = OverlayEyeRestingPlace.clamped(
            homeNearTheUltrawidesRightEdge, toScreenOfSize: builtInDisplay.size
        )
        let inset = OverlayEyeRestingPlace.smallestDistanceFromAnyEdge
        #expect(placeOnTheBuiltIn == CGPoint(x: builtInDisplay.width - inset, y: builtInDisplay.height - inset))
    }
}

@Suite("Screen layout compliance — every verdict")
struct ScreenLayoutComplianceVerdictTests {

    @Test("a layout that matches, with every window where it should be, needs nothing")
    func nothingToDoWhenEverythingMatches() {
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [builtInDisplay],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .everyOverlayFitsItsScreen)
    }

    @Test("plugging a display in rebuilds, so the new screen gets its own eye")
    func rebuildsWhenADisplayIsAdded() {
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [builtInDisplay, CGRect(x: 1512, y: 0, width: 3440, height: 1440)],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .rebuildTheOverlaysForTheCurrentScreens)
    }

    @Test("a resolution change on the same display rebuilds")
    func rebuildsWhenADisplayChangesSize() {
        let scaledBuiltIn = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [scaledBuiltIn],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .rebuildTheOverlaysForTheCurrentScreens)
    }

    @Test("rearranging displays rebuilds, because each overlay's content bakes in its origin")
    func rebuildsWhenDisplaysAreRearranged() {
        let externalOnTheRight = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let externalOnTheLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay, externalOnTheRight],
            currentScreenFrames: [builtInDisplay, externalOnTheLeft],
            liveOverlayWindowFrames: [builtInDisplay, externalOnTheRight]
        )
        #expect(verdict == .rebuildTheOverlaysForTheCurrentScreens)
    }

    @Test("a window the window server moved, on an unchanged layout, is put back without a rebuild")
    func reframesADriftedWindow() {
        let externalDisplay = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let whereTheWindowServerLeftIt = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay, externalDisplay],
            currentScreenFrames: [builtInDisplay, externalDisplay],
            liveOverlayWindowFrames: [builtInDisplay, whereTheWindowServerLeftIt]
        )
        #expect(verdict == .putTheseOverlaysBackOnTheirScreens([1: externalDisplay]))
    }

    @Test("sub-point differences are not drift — re-setting the frame for those would be churn")
    func toleratesRetinaRounding() {
        let aHairOff = CGRect(x: 0.25, y: 0, width: 1512, height: 981.75)
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [builtInDisplay],
            liveOverlayWindowFrames: [aHairOff]
        )
        #expect(verdict == .everyOverlayFitsItsScreen)
    }

    @Test("a missing window on an unchanged layout is a rebuild, not a reframe of nothing")
    func rebuildsWhenAWindowWentMissing() {
        let externalDisplay = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay, externalDisplay],
            currentScreenFrames: [builtInDisplay, externalDisplay],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .rebuildTheOverlaysForTheCurrentScreens)
    }

    @Test("no connected display at all is left alone rather than rebuilt to nothing")
    func holdsWhenThereIsNoScreen() {
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .noScreenToShowOn)
    }

    @Test("a Dock resize changes visibleFrame but not frame, and must not tear the overlays down")
    func aDockResizeIsNotALayoutChange() {
        // Modelled as: the screen frames the check compares are identical. The
        // manager only ever hands it `NSScreen.frame`, never `visibleFrame`,
        // so the Dock growing cannot reach this decision at all.
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: [builtInDisplay],
            currentScreenFrames: [builtInDisplay],
            liveOverlayWindowFrames: [builtInDisplay]
        )
        #expect(verdict == .everyOverlayFitsItsScreen)
    }
}

@Suite("Screen layout compliance — is a floating window on any screen at all")
struct ScreenLayoutComplianceFloatingWindowTests {

    @Test("a window whose centre is on a connected display counts as on screen")
    func centreOnADisplayIsOnScreen() {
        let terminalInTheMiddle = CGRect(x: 376, y: 251, width: 760, height: 480)
        #expect(ScreenLayoutCompliance.frameIsOnSomeScreen(terminalInTheMiddle, screenFrames: [builtInDisplay]))
    }

    @Test("a window left on an unplugged display is not on any screen")
    func windowOnAGoneDisplayIsNotOnScreen() {
        let terminalOnTheUltrawide = CGRect(x: 2200, y: 600, width: 760, height: 480)
        #expect(!ScreenLayoutCompliance.frameIsOnSomeScreen(terminalOnTheUltrawide, screenFrames: [builtInDisplay]))
    }

    @Test("a window the reader tucked mostly off an edge still counts as on screen, so a Dock resize cannot yank it back")
    func windowMostlyOffAnEdgeIsStillOnScreen() {
        // 760 wide at x=1200 on a 1512-wide display: 312pt visible, centre off
        // the screen. Deliberate placement, not an orphan.
        let terminalMostlyOffTheRight = CGRect(x: 1200, y: 251, width: 760, height: 480)
        #expect(ScreenLayoutCompliance.frameIsOnSomeScreen(terminalMostlyOffTheRight, screenFrames: [builtInDisplay]))
    }

    @Test("a window that only touches a screen's edge is not on it")
    func windowTouchingOnlyTheEdgeIsNotOnScreen() {
        let terminalJustPastTheRightEdge = CGRect(x: 1512, y: 251, width: 760, height: 480)
        #expect(!ScreenLayoutCompliance.frameIsOnSomeScreen(terminalJustPastTheRightEdge, screenFrames: [builtInDisplay]))
    }
}
