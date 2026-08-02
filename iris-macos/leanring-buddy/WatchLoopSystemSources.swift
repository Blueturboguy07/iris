//
//  WatchLoopSystemSources.swift
//  leanring-buddy
//
//  The real macOS answers to `WatchLoop`'s four collaborator protocols: the
//  clock, the frames, the local signals, and the one model call.
//
//  They live apart from `WatchLoop.swift` for a reason worth stating: the loop
//  is the part with the rules — the budget, the privacy gates, the ladder — and
//  it is the part that has to be provable by a test with no screen and no
//  network. Everything that genuinely needs a Mac is here instead, behind
//  protocols the loop was written against rather than around.
//
//  Nothing in this file writes a frame anywhere. The fingerprint source hands
//  back 64 bits, the visual source hands back bytes that its one caller drops
//  immediately, and neither ever sees a file path.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - The clock

/// Wall-clock seconds and a real sleep. Monotonic on purpose: the budget is
/// about elapsed time, and a user changing their clock must not hand the loop a
/// free model call.
@MainActor
final class SystemWatchLoopClock: WatchLoopClock {
    var currentTimeInSeconds: Double {
        ProcessInfo.processInfo.systemUptime
    }

    func waitForSeconds(_ numberOfSecondsToWait: Double) async {
        guard numberOfSecondsToWait > 0 else {
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(numberOfSecondsToWait * 1_000_000_000))
    }
}

// MARK: - The frames

/// ScreenCaptureKit, twice over: a ~256 px grayscale thumbnail that becomes a
/// 64-bit hash and is then thrown away, and — only when the ladder has run out
/// of cheaper answers — one real screenshot for a single model call.
@MainActor
final class ScreenCaptureKitWatchLoopFrameSource: WatchLoopFrameSource {
    /// Small enough that capturing one every two seconds is invisible in
    /// Activity Monitor, and far more than the 9×8 grid the hash needs — the
    /// intermediate size is what stops a one-pixel caret from swinging a sample.
    static let fingerprintCaptureLongEdgeInPixels = 256

    func captureFingerprintOfTheCurrentScreen() async -> ScreenFrameFingerprint? {
        guard let capturedImage = await captureTheDisplayUnderTheCursor(
            longEdgeInPixels: Self.fingerprintCaptureLongEdgeInPixels
        ) else {
            return nil
        }

        let grayscaleSamples = Self.grayscaleSamples(
            downscaledFrom: capturedImage,
            gridWidth: PerceptualFrameHash.sampleGridWidth,
            gridHeight: PerceptualFrameHash.sampleGridHeight
        )
        guard !grayscaleSamples.isEmpty else {
            return nil
        }
        // The CGImage goes out of scope here. Only the 64 bits survive.
        return ScreenFrameFingerprint(
            differenceHash: PerceptualFrameHash.differenceHash(fromGrayscaleSamples: grayscaleSamples)
        )
    }

    func captureOneFrameForAVisualModelCheck() async -> Data? {
        // Reuses the capture the rest of the app already goes through, so there
        // is one place that decides how a screenshot of this user's screen is
        // taken and what it excludes.
        guard let capturedScreens = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() else {
            return nil
        }
        // Only the screen the reader is actually working on. Sending every
        // monitor would send strictly more of somebody's screen than the
        // question needs, and the question is about where their cursor is.
        let screenTheReaderIsWorkingOn = capturedScreens.first { capturedScreen in
            capturedScreen.isCursorScreen
        } ?? capturedScreens.first
        return screenTheReaderIsWorkingOn?.imageData
    }

    /// One display, small, with this app's own windows filtered out — otherwise
    /// the watch indicator repainting in Iris's own panel would read as the
    /// reader's screen changing, and the loop would chase itself.
    private func captureTheDisplayUnderTheCursor(longEdgeInPixels: Int) async -> CGImage? {
        guard let shareableContent = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else {
            return nil
        }
        guard !shareableContent.displays.isEmpty else {
            return nil
        }

        let mouseLocation = NSEvent.mouseLocation
        var appKitScreenByDisplayIdentifier: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID {
                appKitScreenByDisplayIdentifier[screenNumber] = screen
            }
        }
        let displayUnderTheCursor = shareableContent.displays.first { display in
            let displayFrame = appKitScreenByDisplayIdentifier[display.displayID]?.frame ?? display.frame
            return displayFrame.contains(mouseLocation)
        } ?? shareableContent.displays[0]

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let contentFilter = SCContentFilter(
            display: displayUnderTheCursor,
            excludingWindows: ownAppWindows
        )

        let streamConfiguration = SCStreamConfiguration()
        let displayAspectRatio = CGFloat(displayUnderTheCursor.width) / CGFloat(displayUnderTheCursor.height)
        if displayUnderTheCursor.width >= displayUnderTheCursor.height {
            streamConfiguration.width = longEdgeInPixels
            streamConfiguration.height = max(1, Int(CGFloat(longEdgeInPixels) / displayAspectRatio))
        } else {
            streamConfiguration.height = longEdgeInPixels
            streamConfiguration.width = max(1, Int(CGFloat(longEdgeInPixels) * displayAspectRatio))
        }

        return try? await SCScreenshotManager.captureImage(
            contentFilter: contentFilter,
            configuration: streamConfiguration
        )
    }

    /// Redraws the frame into a tiny grayscale bitmap. Core Graphics does the
    /// box-filtering on the way down, which is exactly the averaging a
    /// hand-rolled downscale would do and considerably faster.
    static func grayscaleSamples(
        downscaledFrom capturedImage: CGImage,
        gridWidth: Int,
        gridHeight: Int
    ) -> [UInt8] {
        var grayscaleSamples = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let drawSucceeded = grayscaleSamples.withUnsafeMutableBytes { sampleBuffer -> Bool in
            guard let bitmapContext = CGContext(
                data: sampleBuffer.baseAddress,
                width: gridWidth,
                height: gridHeight,
                bitsPerComponent: 8,
                bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            bitmapContext.interpolationQuality = .medium
            bitmapContext.draw(
                capturedImage,
                in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight)
            )
            return true
        }
        return drawSucceeded ? grayscaleSamples : []
    }
}

// MARK: - The local signals

/// Everything the loop can learn without looking at pixels, answered by the
/// services this app already has. Nothing here is new machinery:
/// `ToolVersionService` and `GitInspectionService` are the ported Tauri
/// commands, and the rest is AppKit and accessibility.
@MainActor
final class SystemWatchLoopLocalSignalSource: WatchLoopLocalSignalSource {

    /// How deep into an app's accessibility tree a search will go, and how many
    /// elements it will look at, before giving up. A modern web app's tree runs
    /// to tens of thousands of nodes; walking all of it every two seconds would
    /// be far more expensive than the model call this signal exists to avoid.
    private static let maximumAccessibilitySearchDepth = 8
    private static let maximumAccessibilityElementsToInspect = 400

    func frontmostApplicationBundleIdentifier() -> String? {
        (try? AppAwarenessService.currentForegroundApplicationIdentity())?.bundleIdentifier
    }

    func frontmostApplicationName() -> String? {
        (try? AppAwarenessService.currentForegroundApplicationIdentity())?.displayName
    }

    func frontmostWindowTitle() -> String? {
        guard let focusedWindow = focusedWindowOfTheFrontmostApplication() else {
            return nil
        }
        var windowTitleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXTitleAttribute as CFString,
            &windowTitleValue
        ) == .success else {
            return nil
        }
        return windowTitleValue as? String
    }

    /// Safari and Chrome both publish the page's address on the focused window's
    /// `AXDocument`. An app that publishes nothing simply answers nil, and the
    /// loop falls back to the window title.
    func hostOfTheURLInTheFrontmostWindow() -> String? {
        guard let focusedWindow = focusedWindowOfTheFrontmostApplication() else {
            return nil
        }
        var documentURLValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXDocumentAttribute as CFString,
            &documentURLValue
        ) == .success else {
            return nil
        }
        guard let documentURLString = documentURLValue as? String,
              let documentURL = URL(string: documentURLString),
              let host = documentURL.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    func isToolInstalled(named toolName: String) async -> Bool {
        guard let toolVersion = try? await ToolVersionService.checkToolVersion(tool: toolName) else {
            return false
        }
        return toolVersion.available
    }

    func gitWorkingTreeHasACommit(atRepositoryPath repositoryPath: String) async -> Bool {
        // `GitInspectionService` refuses anything outside the user's home and
        // anything that is not a working tree, so a path this loop guessed wrong
        // is a false answer rather than a command running somewhere unexpected.
        (try? await GitInspectionService.gitHead(repositoryPath: repositoryPath)) != nil
    }

    func isAccessibilityElementPresent(matchingRoleLabel roleLabel: String) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        let applicationElement = AXUIElementCreateApplication(
            frontmostApplication.processIdentifier
        )
        var numberOfElementsInspected = 0
        return Self.accessibilitySubtree(
            applicationElement,
            containsAnElementLabelled: roleLabel.lowercased(),
            remainingDepth: Self.maximumAccessibilitySearchDepth,
            numberOfElementsInspected: &numberOfElementsInspected
        )
    }

    /// The key CoreGraphics puts the secure-input owner's process id under. It
    /// is present and non-zero exactly while some process has secure keyboard
    /// entry on.
    private static let secureInputProcessIdentifierSessionKey = "kCGSSessionSecureInputPID"

    /// The system's own statement that somebody is typing something that must
    /// not be observed — a password field, a sudo prompt, the lock screen.
    ///
    /// The protocol names `IsSecureEventInputSet()`, and that is the same fact;
    /// its declaration was dropped from recent macOS SDK headers, so this reads
    /// it from the session dictionary instead rather than reaching for a symbol
    /// the SDK no longer publishes. Read fresh on every tick and never cached,
    /// because it goes on and off in the middle of a step and that is precisely
    /// when it matters.
    func isSecureEventInputActive() -> Bool {
        guard let sessionProperties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // Iris cannot prove secure input is off. The only safe reading of
            // "cannot prove" is to assume somebody is typing a password.
            return true
        }
        guard let secureInputProcessIdentifier = sessionProperties[
            Self.secureInputProcessIdentifierSessionKey
        ] as? Int else {
            return false
        }
        return secureInputProcessIdentifier != 0
    }

    // MARK: Accessibility plumbing

    private func focusedWindowOfTheFrontmostApplication() -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let applicationElement = AXUIElementCreateApplication(
            frontmostApplication.processIdentifier
        )
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success else {
            return nil
        }
        guard CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedWindowValue as! AXUIElement)
    }

    /// Depth-first, bounded on both depth and total nodes. Matches on title,
    /// description, or value, because "Create Key" is a title on a button, a
    /// description on an image button, and a value on a few web widgets — and a
    /// guide author should not have to know which.
    private static func accessibilitySubtree(
        _ element: AXUIElement,
        containsAnElementLabelled lowercasedRoleLabel: String,
        remainingDepth: Int,
        numberOfElementsInspected: inout Int
    ) -> Bool {
        guard remainingDepth > 0,
              numberOfElementsInspected < maximumAccessibilityElementsToInspect else {
            return false
        }
        numberOfElementsInspected += 1

        for labelAttribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var labelValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                labelAttribute as CFString,
                &labelValue
            ) == .success else {
                continue
            }
            if let label = labelValue as? String,
               label.lowercased().contains(lowercasedRoleLabel) {
                return true
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return false
        }
        for childElement in children {
            if accessibilitySubtree(
                childElement,
                containsAnElementLabelled: lowercasedRoleLabel,
                remainingDepth: remainingDepth - 1,
                numberOfElementsInspected: &numberOfElementsInspected
            ) {
                return true
            }
        }
        return false
    }
}

// MARK: - The one model call

/// Asks the model, through `AssistantTransport` like everything else in this
/// app, whether the step looks done.
///
/// The answer is constrained to one line from a closed set. A free-form reply
/// would have to be interpreted, and interpreting a paragraph into "the reader
/// finished" is how a guide advances past a step somebody has not done.
@MainActor
final class AssistantTransportWatchLoopVisualEvaluator: WatchLoopVisualEvaluator {

    /// The single line the model is asked for. `STUCK:` carries the hint.
    static let completedAnswer = "COMPLETED"
    static let notYetAnswer = "NOT_YET"
    static let stuckAnswerPrefix = "STUCK:"

    /// Installed at startup by whoever owns the account service. Until then
    /// there is no way for this evaluator to reach a model, which is deliberate:
    /// it has no URL of its own and no credential of its own.
    private var claudeAPI: ClaudeAPI?

    func useTransport(
        resolvedBy resolveTransport: @escaping @Sendable () async -> Result<AssistantTransport, AssistantTransportError>
    ) {
        // The funded route pins its own model, so the name here only matters on
        // the reader's own key — where a cheap model is the right default for a
        // yes/no question asked up to eight times per step.
        claudeAPI = ClaudeAPI(resolveTransport: resolveTransport, model: "claude-haiku-4-5")
    }

    func evaluateWhetherTheStepLooksDone(
        screenshotJPEGData: Data,
        visualPrompt: String,
        stepTitle: String,
        hintsTheStepAuthorWrote: [String]
    ) async -> WatchVerdict? {
        guard let claudeAPI else {
            return nil
        }

        let systemPrompt = Self.systemPrompt(hintsTheStepAuthorWrote: hintsTheStepAuthorWrote)
        let userPrompt = """
        The step is titled "\(stepTitle)".
        The question to answer about the screenshot is: \(visualPrompt)
        """

        // The image is passed straight through and never held: this call is the
        // only thing that ever sees it, and it is gone when this function
        // returns. Nothing about the response is logged either — a model's own
        // words about somebody's screen do not belong in a log file.
        guard let answer = try? await claudeAPI.analyzeImage(
            images: [(data: screenshotJPEGData, label: "the reader's screen right now")],
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        ) else {
            return nil
        }

        return Self.verdict(
            fromModelAnswer: answer.text,
            hintsTheStepAuthorWrote: hintsTheStepAuthorWrote
        )
    }

    static func systemPrompt(hintsTheStepAuthorWrote: [String]) -> String {
        var systemPrompt = """
        You are helping somebody follow an install guide on their own computer. \
        You are shown one screenshot and asked whether the current step is done.

        Answer with exactly one line and nothing else:
        \(completedAnswer) — the step is visibly finished.
        \(notYetAnswer) — the step is not finished, and nothing looks wrong.
        \(stuckAnswerPrefix) <one short sentence> — the step is not finished AND \
        something on screen suggests they have gone off the rails: an error, a \
        dialog they did not expect, or the wrong window in front.

        Prefer \(notYetAnswer) when you are unsure. Saying a step is done when it \
        is not sends somebody on to a step that cannot work.
        """
        if !hintsTheStepAuthorWrote.isEmpty {
            systemPrompt += "\n\nThe guide's author suggested these hints for somebody who is stuck:\n"
            for hint in hintsTheStepAuthorWrote {
                systemPrompt += "- \(hint)\n"
            }
        }
        return systemPrompt
    }

    /// Reads the one line back. Anything unrecognized is nil — "the loop learned
    /// nothing", which is very different from "the step is not done" and must
    /// not be collapsed into it.
    static func verdict(
        fromModelAnswer modelAnswer: String,
        hintsTheStepAuthorWrote: [String]
    ) -> WatchVerdict? {
        let firstLineOfTheAnswer = modelAnswer
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAnswer = firstLineOfTheAnswer.uppercased()

        if normalizedAnswer.hasPrefix(stuckAnswerPrefix) {
            let hintFromTheModel = firstLineOfTheAnswer
                .dropFirst(stuckAnswerPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !hintFromTheModel.isEmpty {
                return .userStuck(hint: hintFromTheModel)
            }
            // A stuck verdict with no hint is useless to the reader, so the
            // author's own first hint stands in rather than an empty banner.
            guard let authoredHint = hintsTheStepAuthorWrote.first else {
                return .notYet
            }
            return .userStuck(hint: authoredHint)
        }
        if normalizedAnswer.hasPrefix(completedAnswer) {
            return .completed
        }
        if normalizedAnswer.hasPrefix(notYetAnswer) || normalizedAnswer.hasPrefix("NOT YET") {
            return .notYet
        }
        return nil
    }
}
