import Foundation
import CoreGraphics
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct GuidePresentationRegressionTests {
    @Test func inventedScreenNumbersCannotFallBackToAnotherDisplay() {
        #expect(!GuidePointingFreshness.explicitScreenNumberIsValid(2, captureCount: 1))
        #expect(!GuidePointingFreshness.explicitScreenNumberIsValid(0, captureCount: 1))
        #expect(!GuidePointingFreshness.explicitScreenNumberIsValid(-1, captureCount: 1))
        #expect(!GuidePointingFreshness.explicitScreenNumberIsValid(nil, captureCount: 0))
        #expect(GuidePointingFreshness.explicitScreenNumberIsValid(nil, captureCount: 2))
        #expect(GuidePointingFreshness.explicitScreenNumberIsValid(2, captureCount: 2))
    }

    @Test func outOfBoundsCoordinatesAreRejectedRatherThanClampedToAnEdge() {
        for invalidPoint in [CGPoint(x: -1, y: 40), CGPoint(x: 1280, y: 40),
                             CGPoint(x: 40, y: 720), CGPoint(x: 40, y: -1),
                             CGPoint(x: CGFloat.nan, y: 40), CGPoint(x: 40, y: CGFloat.infinity)] {
            #expect(!GuidePointingFreshness.pointIsInsideScreenshot(invalidPoint, width: 1280, height: 720))
        }
        #expect(GuidePointingFreshness.pointIsInsideScreenshot(CGPoint(x: 1279, y: 719), width: 1280, height: 720))
        #expect(GuidePointingFreshness.pointIsInsideScreenshot(.zero, width: 1280, height: 720))
        #expect(!GuidePointingFreshness.pointIsInsideScreenshot(.zero, width: 0, height: 720))
    }

    @Test func manualDownloadGuideExplainsWhyRunIsAbsent() {
        let availability = availability(hasExecutableSteps: false)
        #expect(availability == .manualStepsOnly)
        #expect(availability.explanation?.contains("no commands for Iris to run") == true)
    }

    @Test func executableGuideStillOffersTheExplicitRunGesture() {
        #expect(availability() == .available)
        #expect(availability().explanation == nil)
    }

    @Test func setupAndUnsupportedGuidesDoNotOfferAnActionThatRefusesOnTap() {
        #expect(availability(isInSetupRecovery: true) == .setupRequired)
        #expect(availability(isSupportedBranch: false) == .unsupported)
        #expect(availability(hasRunner: false) == .runnerUnavailable)
    }

    @Test func inactiveAndRunningGuidesDoNotLookLikeManualOnlyGuides() {
        #expect(availability(isActivelyGuiding: false, hasExecutableSteps: false) == .inactive)
        #expect(availability(isRunning: true, hasExecutableSteps: false) == .running)
    }

    private func availability(
        isActivelyGuiding: Bool = true,
        isRunning: Bool = false,
        isSupportedBranch: Bool = true,
        isInSetupRecovery: Bool = false,
        hasRunner: Bool = true,
        hasExecutableSteps: Bool = true
    ) -> GuideAutopilotAvailability {
        .resolve(
            isActivelyGuiding: isActivelyGuiding,
            isRunning: isRunning,
            isSupportedBranch: isSupportedBranch,
            isInSetupRecovery: isInSetupRecovery,
            hasRunner: hasRunner,
            hasExecutableSteps: hasExecutableSteps
        )
    }

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let window = CGRect(x: 120, y: 140, width: 900, height: 620)
    private let target = CGRect(x: 280, y: 360, width: 44, height: 44)

    private func refreshedPoint(
        currentApplication: String? = "example.browser",
        currentWindow: CGRect?,
        currentDisplays: [CGRect]? = nil
    ) -> CGRect? {
        GuidePointingFreshness.rectangleIfStillUsable(
            target,
            capturedApplication: "example.browser",
            currentApplication: currentApplication,
            capturedWindow: window,
            currentWindow: currentWindow,
            capturedDisplays: [display],
            currentDisplays: currentDisplays ?? [display]
        )
    }

    @Test func unchangedWindowKeepsThePoint() {
        #expect(refreshedPoint(currentWindow: window) == target)
    }

    @Test func pureWindowMoveStillTranslatesThePoint() {
        #expect(refreshedPoint(currentWindow: window.offsetBy(dx: 80, dy: -30))
                == target.offsetBy(dx: 80, dy: -30))
    }

    @Test func windowResizeRejectsCoordinatesFromThePreviousLayout() {
        let resizedWindow = CGRect(x: window.minX, y: window.minY, width: 650, height: window.height)
        #expect(refreshedPoint(currentWindow: resizedWindow) == nil)
    }

    @Test func closedWindowDoesNotPointAtItsOldLocation() {
        #expect(refreshedPoint(currentWindow: nil) == nil)
    }

    @Test func switchingAppsDuringTheModelRequestInvalidatesThePoint() {
        #expect(refreshedPoint(currentApplication: "example.editor", currentWindow: window) == nil)
    }

    @Test func displayRearrangementInvalidatesThePoint() {
        #expect(refreshedPoint(currentWindow: window, currentDisplays: [display.offsetBy(dx: 1512, dy: 0)]) == nil)
    }

    @Test func missingAccessibilityGeometryDoesNotDisableUnchangedScreenPointing() {
        #expect(GuidePointingFreshness.rectangleIfStillUsable(
            target,
            capturedApplication: "example.browser", currentApplication: "example.browser",
            capturedWindow: nil, currentWindow: nil,
            capturedDisplays: [display], currentDisplays: [display]
        ) == target)
    }
}
