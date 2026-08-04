//
//  GuideStepPointing.swift
//  leanring-buddy
//
//  Turns the decision in `GuidePointing.swift` into an eye actually flying
//  somewhere.
//
//  Kept out of `GuideSessionController` because that file is already the
//  largest in the app and because this half has to touch AppKit and the
//  accessibility tree, which the controller otherwise never does.
//

import AppKit
import ApplicationServices
import Foundation

/// Finds the rectangle a descriptor names.
///
/// A protocol so the controller can be tested without a screen, and because the
/// model fallback is a different collaborator from the accessibility walk.
@MainActor
protocol GuideTargetLocating {
    /// The accessibility tree first: exact, free, and about three quarters of
    /// controls. Returns nil when the tree has nothing matching, which is the
    /// signal to fall back.
    func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect?

    /// The frame of an app's frontmost window, for a command step aiming at a
    /// Terminal rather than at a control.
    func locateWindow(ofApp bundleIdentifier: String) -> CGRect?

    /// The paid path, used only when the two above come back empty and the
    /// step's target was never authored.
    func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect?
}

/// What the eye was told to do about the current step.
@MainActor
struct GuideStepPointingOutcome: Equatable {
    let decision: GuidePointingDecision
    /// Global AppKit coordinates, when there is somewhere to go.
    let screenLocation: CGPoint?
    let displayFrame: CGRect?
}

@MainActor
enum GuideStepPointingCoordinator {

    /// Where in a found rectangle the eye should aim.
    ///
    /// The centre for a control, because that is the thing to click. For a
    /// window it is the top edge rather than the middle: a window's centre is
    /// wherever the reader is working, and parking a 64pt eye on top of the
    /// text they are trying to read is worse than not pointing at all.
    static func aimPoint(in rectangle: CGRect, isWindow: Bool) -> CGPoint {
        if isWindow {
            return CGPoint(x: rectangle.midX, y: rectangle.maxY - min(28, rectangle.height * 0.12))
        }
        return CGPoint(x: rectangle.midX, y: rectangle.midY)
    }

    /// The display a point falls on, so the overlay animates on the right
    /// screen. Falls back to the main display rather than refusing to point.
    static func displayFrame(containing point: CGPoint) -> CGRect {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            return screen.frame
        }
        return NSScreen.main?.frame ?? .zero
    }

    /// Resolve a decision into a place, or explain why there is not one.
    static func resolve(
        decision: GuidePointingDecision,
        stepTitle: String,
        stepBody: String,
        using locator: any GuideTargetLocating
    ) async -> GuideStepPointingOutcome {
        guard case .pointAt(let target) = decision else {
            return GuideStepPointingOutcome(decision: decision, screenLocation: nil, displayFrame: nil)
        }

        var found: CGRect?
        if target.isWindow, let bundleIdentifier = target.inApp {
            found = locator.locateWindow(ofApp: bundleIdentifier)
        }
        if found == nil {
            found = locator.locateInAccessibilityTree(descriptor: target.descriptor, inApp: target.inApp)
        }
        // Only an inferred target is allowed to reach the model: an authored
        // descriptor the tree could not find is a stale guide, and guessing
        // over the top of it hides that rather than fixing it.
        if found == nil, target.provenance == .inferred {
            found = await locator.locateByAskingTheModel(stepTitle: stepTitle, stepBody: stepBody)
        }

        guard let rectangle = found else {
            return GuideStepPointingOutcome(
                decision: .doNotPoint(.couldNotFindIt(descriptor: target.descriptor)),
                screenLocation: nil,
                displayFrame: nil
            )
        }

        let point = aimPoint(in: rectangle, isWindow: target.isWindow)
        return GuideStepPointingOutcome(
            decision: decision,
            screenLocation: point,
            displayFrame: displayFrame(containing: point)
        )
    }
}

// MARK: - The real macOS answers

/// The accessibility tree and the window list, for real.
///
/// No screenshot is taken here at all. That is why an authored descriptor still
/// resolves for somebody who has never granted Screen Recording — and it is why
/// `GuidePointingLadder.decide` only blocks the *inferred* path on that grant.
@MainActor
struct SystemGuideTargetLocator: GuideTargetLocating {
    /// Asks the model. Injected because it goes through `AssistantTransport`
    /// like every other model call in this app, and this file must not build a
    /// second route to one.
    var askTheModel: ((String, String) async -> CGRect?)?

    func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let applications: [NSRunningApplication]
        if let bundleIdentifier {
            applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            applications = [frontmost]
        } else {
            applications = []
        }

        let wanted = normalize(descriptor)
        for application in applications {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            if let match = search(element: element, wanted: wanted, depth: 0) {
                return match
            }
        }
        return nil
    }

    func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
        guard
            AXIsProcessTrusted(),
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else {
            return nil
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement],
            let first = windows.first
        else {
            return nil
        }
        return frame(of: first)
    }

    func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
        guard let askTheModel else { return nil }
        return await askTheModel(stepTitle, stepBody)
    }

    // MARK: Walking the tree

    /// Bounded on purpose. An unbounded walk of a big app's tree takes long
    /// enough to be felt, and a control worth pointing at is never sixteen
    /// levels down inside a table cell.
    private static let maximumDepth = 16

    private func search(element: AXUIElement, wanted: String, depth: Int) -> CGRect? {
        guard depth <= Self.maximumDepth else { return nil }

        if let label = label(of: element), matches(label: normalize(label), wanted: wanted) {
            if let rectangle = frame(of: element), rectangle.width > 1, rectangle.height > 1 {
                return rectangle
            }
        }

        var childrenValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }
        for child in children {
            if let found = search(element: child, wanted: wanted, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Title, then description, then value — the three places a control's
    /// human-readable name actually lives, in the order they are most likely to
    /// be the name a guide author would have written down.
    private func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        // Accessibility reports a top-left origin on the primary display;
        // AppKit's global space is bottom-left. Flip through the main screen's
        // height, which is the same conversion `OverlayWindow` already does.
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? size.height
        return CGRect(x: origin.x, y: mainHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    /// Case, punctuation and the words a guide author adds for readability
    /// ("the ••• button in cue's toolbar") should not decide a match.
    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !Self.ignoredWords.contains($0) }
            .joined(separator: " ")
    }

    private static let ignoredWords: Set<String> = [
        "the", "a", "an", "in", "on", "at", "of", "button", "toolbar", "menu", "window", "icon",
    ]

    /// Containment either way, because a guide says "the more button" and the
    /// tree says "more options", and neither is wrong.
    private func matches(label: String, wanted: String) -> Bool {
        guard !label.isEmpty, !wanted.isEmpty else { return false }
        return label == wanted || label.contains(wanted) || wanted.contains(label)
    }
}
