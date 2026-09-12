import AppKit
import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

@MainActor
struct SpatialGuidanceRegressionTests {

    @Test("a chat point uses the model label as a bounded one-line cue")
    func modelLabelsAreSanitizedBeforeTheyReachTheOverlay() {
        #expect(
            CompanionManager.sanitizedPointingBubbleText(
                from: "  Save\n settings  "
            ) == "Save settings"
        )
        #expect(
            CompanionManager.sanitizedPointingBubbleText(
                from: String(repeating: "x", count: 41)
            ) == String(repeating: "x", count: 40)
        )
        #expect(
            CompanionManager.sanitizedPointingBubbleText(from: "save\u{0007}now") == nil
        )
        #expect(CompanionManager.sanitizedPointingBubbleText(from: "   ") == nil)
        #expect(CompanionManager.sanitizedPointingBubbleText(from: nil) == nil)
    }

    @Test("a guide window target prefers the focused non-minimized window")
    func focusedWindowWinsOverTheAppWindowList() async throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        let focusedWindow = CGRect(
            x: visible.midX - 120,
            y: visible.midY - 70,
            width: 240,
            height: 140
        )
        let otherWindow = CGRect(
            x: visible.minX + 40,
            y: visible.minY + 40,
            width: 240,
            height: 140
        )
        let locator = WindowTargetLocator(
            focusedWindow: focusedWindow,
            windowListResult: otherWindow
        )

        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(
                GuidePointTarget(
                    descriptor: "the Terminal window",
                    inApp: "com.apple.Terminal",
                    isWindow: true,
                    provenance: .shellWindow
                )
            ),
            stepTitle: "Open Terminal",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        #expect(locator.focusedWindowLookups == 1)
        #expect(locator.windowListLookups == 0)
        #expect(locator.accessibilityLookups == 0)
        #expect(
            outcome.screenLocation
                == GuideStepPointingCoordinator.aimPoint(in: focusedWindow, isWindow: true)
        )
        #expect(outcome.displayFrame == screen.frame)
    }

    @Test("a missing focused-window attribute gets one bounded compatibility fallback")
    func windowListFallbackRunsOnlyAfterFocusedLookupMisses() async throws {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        let fallbackWindow = CGRect(
            x: visible.midX - 120,
            y: visible.midY - 70,
            width: 240,
            height: 140
        )
        let locator = WindowTargetLocator(
            focusedWindow: nil,
            windowListResult: fallbackWindow
        )

        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(
                GuidePointTarget(
                    descriptor: "the Terminal window",
                    inApp: "com.apple.Terminal",
                    isWindow: true,
                    provenance: .shellWindow
                )
            ),
            stepTitle: "Open Terminal",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        #expect(locator.focusedWindowLookups == 1)
        #expect(locator.windowListLookups == 1)
        #expect(outcome.screenLocation != nil)
    }

    @MainActor
    final class WindowTargetLocator: GuideTargetLocating {
        let focusedWindow: CGRect?
        let windowListResult: CGRect?
        private(set) var focusedWindowLookups = 0
        private(set) var windowListLookups = 0
        private(set) var accessibilityLookups = 0

        init(focusedWindow: CGRect?, windowListResult: CGRect?) {
            self.focusedWindow = focusedWindow
            self.windowListResult = windowListResult
        }

        func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
            accessibilityLookups += 1
            return nil
        }

        func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
            windowListLookups += 1
            return windowListResult
        }

        func locateFocusedWindow(ofApp bundleIdentifier: String) -> CGRect? {
            focusedWindowLookups += 1
            return focusedWindow
        }

        func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
            nil
        }
    }
}
