//
//  AccessibilityTreeWalker.swift
//  grounding-lab
//
//  The self-labelling trick lives here. macOS already knows the exact rect and
//  human label of most controls, so the walker can emit both the question and
//  the correct answer with nobody drawing a box by hand.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// One element the walker accepted, before deduplication.
struct DiscoveredAccessibilityElement {
    var label: String
    var role: String
    /// GLOBAL ACCESSIBILITY POINTS, top-left origin. Converted to display-local
    /// exactly once, in `CaptureCommand`.
    var globalRect: CGRect
}

enum AccessibilityTreeWalker {

    /// Roles a person can actually click, tap or type into. Written out
    /// explicitly rather than inferred, because "is this interactive" is the
    /// filter that decides what the benchmark is even measuring.
    ///
    /// Group / container / static roles (AXGroup, AXScrollArea, AXWindow,
    /// AXStaticText, AXImage, AXSplitter, ...) are excluded: they either have no
    /// natural "click the X" instruction or are so large that hitting them is
    /// not evidence of anything.
    static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXMenuButton",
        "AXPopUpButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXLink",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXSlider",
        "AXIncrementor",
        "AXDisclosureTriangle",
        "AXTab",
        "AXToolbarButton"
    ]

    /// Roles whose human label is carried by `AXValue` rather than `AXTitle` or
    /// `AXDescription`. A pop-up button reads out its current selection; a text
    /// field reads out its contents. For every other role `AXValue` is state
    /// (a checkbox's 0/1, a slider's number) and is never used as a label.
    static let rolesWhoseValueIsTheLabel: Set<String> = [
        "AXPopUpButton",
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXStaticText"
    ]

    /// Defensive limits — the accessibility tree of a browser can be enormous
    /// and, with a badly behaved app, cyclic.
    private static let maximumTreeDepth = 40
    private static let maximumVisitedNodeCount = 40_000
    private static let accessibilityMessagingTimeoutSeconds: Float = 2.0

    /// Walks the app's MENU BAR and its FRONTMOST WINDOW only — deliberately not
    /// the whole application element.
    ///
    /// Accessibility happily reports every window an app has open, including
    /// ones completely buried behind others. Walking the app element wholesale
    /// on a five-window Finder produced a dataset where controls from four
    /// invisible windows sat at the same coordinates as visible ones: ground
    /// truth that contradicts the pixels, which would punish a model for being
    /// right. Scoping to the frontmost window makes the tree describe roughly
    /// what is actually on screen.
    ///
    /// This is scoping, not occlusion handling. Occlusion by another
    /// application's window, or by a sheet/popover inside the same window, is
    /// still unhandled — see the README's limitations section.
    static func discoverElements(forProcessIdentifier processIdentifier: pid_t) -> [DiscoveredAccessibilityElement] {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        // Without a timeout a hung app hangs the walker forever.
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)

        var roots: [AXUIElement] = []
        if let menuBar = copyElementAttribute(applicationElement, kAXMenuBarAttribute as String) {
            roots.append(menuBar)
        }
        if let frontmostWindow = frontmostWindowElement(of: applicationElement) {
            roots.append(frontmostWindow)
        }
        // An app with neither (rare, but not worth failing over) falls back to
        // the whole tree so the tool still produces something.
        if roots.isEmpty {
            roots = [applicationElement]
        }

        var discovered: [DiscoveredAccessibilityElement] = []
        var visitedNodeCount = 0
        for root in roots {
            visit(
                element: root,
                depth: 0,
                discovered: &discovered,
                visitedNodeCount: &visitedNodeCount
            )
        }
        return discovered
    }

    private static func frontmostWindowElement(of applicationElement: AXUIElement) -> AXUIElement? {
        if let main = copyElementAttribute(applicationElement, kAXMainWindowAttribute as String) {
            return main
        }
        if let focused = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute as String) {
            return focused
        }
        // AXWindows is ordered front to back.
        guard let windowsValue = copyAttribute(applicationElement, kAXWindowsAttribute as String),
              let windows = windowsValue as? [AnyObject] else {
            return nil
        }
        for candidate in windows where CFGetTypeID(candidate) == AXUIElementGetTypeID() {
            return (candidate as! AXUIElement)
        }
        return nil
    }

    private static func visit(
        element: AXUIElement,
        depth: Int,
        discovered: inout [DiscoveredAccessibilityElement],
        visitedNodeCount: inout Int
    ) {
        guard depth <= maximumTreeDepth, visitedNodeCount < maximumVisitedNodeCount else { return }
        visitedNodeCount += 1

        if let accepted = acceptedElement(element) {
            discovered.append(accepted)
        }

        for child in children(of: element) {
            visit(
                element: child,
                depth: depth + 1,
                discovered: &discovered,
                visitedNodeCount: &visitedNodeCount
            )
        }
    }

    /// Applies filters (a) usable label, (b) non-degenerate geometry and
    /// (c) interactive role. Filter (d) — inside the captured display — needs
    /// the display bounds and is applied by the caller.
    private static func acceptedElement(_ element: AXUIElement) -> DiscoveredAccessibilityElement? {
        guard let role = copyStringAttribute(element, kAXRoleAttribute as String),
              interactiveRoles.contains(role) else {
            return nil
        }

        guard let label = humanLabel(of: element, role: role) else { return nil }

        guard let position = copyPointAttribute(element, kAXPositionAttribute as String),
              let size = copySizeAttribute(element, kAXSizeAttribute as String) else {
            return nil
        }

        // Degenerate geometry: zero-size, hairline, or non-finite. These exist
        // in the tree but a person cannot click them.
        guard size.width.isFinite, size.height.isFinite,
              position.x.isFinite, position.y.isFinite,
              size.width >= 8, size.height >= 8 else {
            return nil
        }

        return DiscoveredAccessibilityElement(
            label: label,
            role: role,
            globalRect: CGRect(origin: position, size: size)
        )
    }

    /// (a) A usable human label: AXTitle, then AXDescription, then AXValue for
    /// the roles whose value IS their label.
    static func humanLabel(of element: AXUIElement, role: String) -> String? {
        let candidates: [String?] = [
            copyStringAttribute(element, kAXTitleAttribute as String),
            copyStringAttribute(element, kAXDescriptionAttribute as String),
            rolesWhoseValueIsTheLabel.contains(role)
                ? copyStringAttribute(element, kAXValueAttribute as String)
                : nil
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            // A one-character label is usually a glyph with no textual meaning;
            // an 80-character one is a paragraph, not a control name.
            guard trimmed.count >= 2, trimmed.count <= 80 else { continue }
            guard !trimmed.contains("\n") else { continue }
            return trimmed
        }
        return nil
    }

    // MARK: - Raw attribute access

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private static func copyPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    /// The rectangle of the application's first window, used to decide which
    /// display to screenshot. Returns nil for apps with no open window (Finder
    /// with everything closed, for example).
    static func firstWindowGlobalRect(forProcessIdentifier processIdentifier: pid_t) -> CGRect? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)

        guard let windowsValue = copyAttribute(applicationElement, kAXWindowsAttribute as String),
              let windows = windowsValue as? [AnyObject] else {
            return nil
        }
        for candidate in windows {
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { continue }
            let window = candidate as! AXUIElement
            guard let position = copyPointAttribute(window, kAXPositionAttribute as String),
                  let size = copySizeAttribute(window, kAXSizeAttribute as String),
                  size.width > 1, size.height > 1 else {
                continue
            }
            return CGRect(origin: position, size: size)
        }
        return nil
    }
}
