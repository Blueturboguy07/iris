import Foundation
@testable import IrisHarnessNative

private enum SpatialGuidanceCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Headless, linked checks for the narrow spatial-guidance seams.
///
/// The locator is a deterministic seam, not a screen or application. These
/// checks prove resolver ordering and refusal behavior without launching or
/// observing any GUI application.
@main
struct SpatialGuidanceChecks {
    @MainActor
    static func main() async {
        do {
            try await run()
            print("SPATIAL GUIDANCE CHECKS PASS: sanitizer, focused-window ordering, bounded fallback, refusal and disabled model rung")
        } catch {
            print("SPATIAL GUIDANCE CHECKS FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        try checkSanitizer()
        try await checkFocusedWindowWins()
        try await checkWindowListIsOneBoundedFallback()
        try await checkMissingAllRefuses()
        try await checkDisabledInferredTargetDoesNotAskTheModel()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SpatialGuidanceCheckError.failed(message) }
    }

    private static func checkSanitizer() throws {
        try require(
            CompanionManager.sanitizedPointingBubbleText(from: "  Save\n settings  ")
                == "Save settings",
            "label whitespace was not collapsed to one line"
        )
        try require(
            CompanionManager.sanitizedPointingBubbleText(
                from: String(repeating: "x", count: 41)
            ) == String(repeating: "x", count: 40),
            "label was not bounded to 40 characters"
        )
        try require(
            CompanionManager.sanitizedPointingBubbleText(from: "save\u{0007}now") == nil,
            "control-bearing label was not rejected"
        )
        try require(
            CompanionManager.sanitizedPointingBubbleText(from: "   ") == nil
                && CompanionManager.sanitizedPointingBubbleText(from: nil) == nil,
            "empty label was not cleared"
        )
        print("PASS sanitizer")
    }

    @MainActor
    private static func checkFocusedWindowWins() async throws {
        let focused = CGRect(x: 100, y: 120, width: 600, height: 400)
        let other = CGRect(x: 800, y: 160, width: 600, height: 400)
        let locator = Locator(focusedWindow: focused, windowList: other)
        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(windowTarget),
            stepTitle: "Open Terminal",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        try require(locator.focusedWindowLookups == 1, "focused-window seam was not consulted once")
        try require(locator.windowListLookups == 0, "window-list fallback ran despite a focused window")
        try require(locator.accessibilityLookups == 0, "accessibility walk ran after focused-window success")
        try require(locator.modelLookups == 0 && !outcome.theModelWasAsked,
                    "focused-window resolution spent the model rung")
        print("PASS focused-window ordering")
    }

    @MainActor
    private static func checkWindowListIsOneBoundedFallback() async throws {
        let fallback = CGRect(x: 100, y: 120, width: 600, height: 400)
        let locator = Locator(focusedWindow: nil, windowList: fallback)
        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(windowTarget),
            stepTitle: "Open Terminal",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        try require(locator.focusedWindowLookups == 1, "focused-window miss was not observed")
        try require(locator.windowListLookups == 1, "compatibility fallback did not run exactly once")
        try require(locator.accessibilityLookups == 0, "accessibility walk ran after fallback success")
        try require(locator.modelLookups == 0 && !outcome.theModelWasAsked,
                    "window-list fallback spent the model rung")
        print("PASS bounded window-list fallback")
    }

    @MainActor
    private static func checkMissingAllRefuses() async throws {
        let locator = Locator(focusedWindow: nil, windowList: nil)
        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(windowTarget),
            stepTitle: "Open Terminal",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        try require(locator.focusedWindowLookups == 1 && locator.windowListLookups == 1,
                    "missing window evidence did not exhaust the bounded window seams")
        try require(locator.accessibilityLookups == 1, "missing window evidence did not check accessibility")
        try require(locator.modelLookups == 0 && !outcome.theModelWasAsked,
                    "missing target asked the model despite a disabled model rung")
        guard case .doNotPoint(.couldNotFindIt(descriptor: windowTarget.descriptor)) = outcome.decision else {
            throw SpatialGuidanceCheckError.failed("missing target did not return couldNotFindIt")
        }
        try require(outcome.screenLocation == nil, "missing target invented a screen coordinate")
        print("PASS missing-all refusal")
    }

    @MainActor
    private static func checkDisabledInferredTargetDoesNotAskTheModel() async throws {
        let target = GuidePointTarget(
            descriptor: "the Save button",
            inApp: nil,
            isWindow: false,
            provenance: .inferred
        )
        let locator = Locator(focusedWindow: nil, windowList: nil)
        let outcome = await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(target),
            stepTitle: "Save the file",
            stepBody: "",
            mayAskTheModel: false,
            using: locator
        )

        try require(locator.focusedWindowLookups == 0 && locator.windowListLookups == 0,
                    "non-window inferred target entered a window seam")
        try require(locator.accessibilityLookups == 1, "inferred target did not try the free accessibility rung")
        try require(locator.modelLookups == 0 && !outcome.theModelWasAsked,
                    "disabled inferred target still asked the model")
        guard case .doNotPoint(.couldNotFindIt(descriptor: target.descriptor)) = outcome.decision else {
            throw SpatialGuidanceCheckError.failed("disabled inferred target did not refuse honestly")
        }
        try require(outcome.screenLocation == nil, "disabled inferred target invented a coordinate")
        print("PASS disabled inferred model rung")
    }

    private static let windowTarget = GuidePointTarget(
        descriptor: "the Terminal window",
        inApp: "com.apple.Terminal",
        isWindow: true,
        provenance: .shellWindow
    )

    @MainActor
    private final class Locator: GuideTargetLocating {
        let focusedWindow: CGRect?
        let windowList: CGRect?
        private(set) var focusedWindowLookups = 0
        private(set) var windowListLookups = 0
        private(set) var accessibilityLookups = 0
        private(set) var modelLookups = 0

        init(focusedWindow: CGRect?, windowList: CGRect?) {
            self.focusedWindow = focusedWindow
            self.windowList = windowList
        }

        func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
            accessibilityLookups += 1
            return nil
        }

        func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
            windowListLookups += 1
            return windowList
        }

        func locateFocusedWindow(ofApp bundleIdentifier: String) -> CGRect? {
            focusedWindowLookups += 1
            return focusedWindow
        }

        func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
            modelLookups += 1
            return nil
        }
    }
}
