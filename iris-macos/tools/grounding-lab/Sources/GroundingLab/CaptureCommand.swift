//
//  CaptureCommand.swift
//  grounding-lab
//
//  `grounding-lab capture` — build a labelled grounding dataset with no human
//  in the loop: bring an app forward, screenshot its display, walk its
//  accessibility tree, and write out the questions plus their correct answers.
//

import AppKit
import CoreGraphics
import Foundation

enum CaptureCommand {

    enum CaptureCommandError: LocalizedError {
        case applicationNotRunning(String)
        case noFrontmostApplication
        case noUsableTargets

        var errorDescription: String? {
            switch self {
            case .applicationNotRunning(let bundleIdentifier):
                return "No running application with bundle id \(bundleIdentifier). Launch it first."
            case .noFrontmostApplication:
                return "Could not determine the frontmost application."
            case .noUsableTargets:
                return """
                    Walked the accessibility tree and found zero usable targets. \
                    That is a bug in the walker or an app with no open window — \
                    it is not a valid measurement. Try an app with a visible \
                    window, e.g. --bundle-id com.apple.Safari.
                    """
            }
        }
    }

    /// A control whose rect is more than half the display in both axes is not a
    /// meaningful pointing target — hitting it says nothing about grounding.
    private static let maximumTargetExtentAsFractionOfDisplay = 0.5

    /// Two elements sharing a label are the same target when their rects
    /// overlap this much (relative to the smaller rect).
    private static let sameTargetOverlapThreshold = 0.5

    static func run(options: CommandLineOptions) async throws {
        let application = try resolveApplication(options: options)
        let applicationName = application.localizedName ?? application.bundleIdentifier ?? "unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown"

        print("Target application: \(applicationName) (\(bundleIdentifier), pid \(application.processIdentifier))")

        // 1. Bring it forward and let it settle. Without the wait, a window that
        //    is still animating in reports rects that no longer match the pixels.
        application.activate()
        try await Task.sleep(nanoseconds: UInt64(options.settleSeconds * 1_000_000_000))

        // 2. Decide which display it is on, then screenshot that display.
        let windowRect = AccessibilityTreeWalker.firstWindowGlobalRect(
            forProcessIdentifier: application.processIdentifier
        )
        let pointOfInterest = windowRect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let displayIdentifier = DisplayScreenshotCapture.displayIdentifierContaining(globalPoint: pointOfInterest)
        let captured = try await DisplayScreenshotCapture.capture(displayIdentifier: displayIdentifier)

        print(String(
            format: "Display %u: %.0fx%.0f points at %.1fx scale -> %dx%d pixel screenshot",
            captured.displayIdentifier,
            captured.boundsInGlobalPoints.width,
            captured.boundsInGlobalPoints.height,
            captured.backingScaleFactor,
            captured.widthInPixels,
            captured.heightInPixels
        ))

        // 3. Walk the accessibility tree.
        let discovered = AccessibilityTreeWalker.discoverElements(
            forProcessIdentifier: application.processIdentifier
        )
        print("Accessibility walk: \(discovered.count) elements passed role / label / geometry filters")

        // 4. Keep only what is actually on the captured display, then dedupe.
        let onDisplay = elementsInsideDisplay(discovered, displayBounds: captured.boundsInGlobalPoints)
        print("On the captured display: \(onDisplay.count)")

        let targets = deduplicatedTargets(onDisplay, displayBounds: captured.boundsInGlobalPoints)
        guard !targets.isEmpty else { throw CaptureCommandError.noUsableTargets }
        print("Unambiguous targets after deduplication: \(targets.count)")

        // 5. Write the dataset.
        let outputDirectory = options.outputDirectory ?? defaultOutputDirectory(bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let screenshotFileName = "screenshot.png"
        try captured.pngData.write(to: outputDirectory.appendingPathComponent(screenshotFileName))

        let dataset = GroundingDataset(
            formatVersion: 1,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            screenshotFileName: screenshotFileName,
            display: CapturedDisplayDescription(
                displayIdentifier: captured.displayIdentifier,
                boundsInGlobalPoints: RectInPoints(cgRect: captured.boundsInGlobalPoints),
                backingScaleFactor: captured.backingScaleFactor,
                screenshotWidthInPixels: captured.widthInPixels,
                screenshotHeightInPixels: captured.heightInPixels
            ),
            coordinateSpaceNote: GroundingDataset.coordinateSpaceNoteText,
            targets: targets
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let datasetURL = outputDirectory.appendingPathComponent("dataset.json")
        try encoder.encode(dataset).write(to: datasetURL)

        print("")
        print("Wrote \(datasetURL.path)")
        print("Wrote \(outputDirectory.appendingPathComponent(screenshotFileName).path)")
        print("")
        print("Sample instructions:")
        for target in targets.prefix(8) {
            print(String(
                format: "  [%@] %@   ->  rect (%.0f, %.0f) %.0fx%.0f",
                target.role,
                target.instruction,
                target.rectInDisplayLocalPoints.x,
                target.rectInDisplayLocalPoints.y,
                target.rectInDisplayLocalPoints.width,
                target.rectInDisplayLocalPoints.height
            ))
        }
    }

    // MARK: - Filtering

    private static func elementsInsideDisplay(
        _ elements: [DiscoveredAccessibilityElement],
        displayBounds: CGRect
    ) -> [DiscoveredAccessibilityElement] {
        let maximumWidth = displayBounds.width * maximumTargetExtentAsFractionOfDisplay
        let maximumHeight = displayBounds.height * maximumTargetExtentAsFractionOfDisplay

        return elements.filter { element in
            // (d) The rect must lie entirely within the captured display.
            // Accessibility happily reports elements that are scrolled out of
            // view or parked on another monitor; those are not in the PNG.
            guard displayBounds.contains(element.globalRect) else { return false }
            guard element.globalRect.width <= maximumWidth,
                  element.globalRect.height <= maximumHeight else { return false }
            return true
        }
    }

    /// Elements sharing a label AND overlapping are one target. Elements sharing
    /// a label in different places are ambiguous and get dropped entirely — a
    /// "Close" that appears five times is not a question with one right answer,
    /// and scoring against an arbitrary one of them would punish a model for
    /// being reasonable.
    private static func deduplicatedTargets(
        _ elements: [DiscoveredAccessibilityElement],
        displayBounds: CGRect
    ) -> [GroundingTarget] {
        var elementsByLabel: [String: [DiscoveredAccessibilityElement]] = [:]
        for element in elements {
            elementsByLabel[element.label, default: []].append(element)
        }

        var targets: [GroundingTarget] = []
        var droppedAmbiguousLabels: [String] = []

        for (label, group) in elementsByLabel {
            var clusters: [[DiscoveredAccessibilityElement]] = []
            for element in group {
                let rect = RectInPoints(cgRect: element.globalRect)
                let matchingClusterIndex = clusters.firstIndex { cluster in
                    cluster.contains { member in
                        RectInPoints(cgRect: member.globalRect)
                            .overlapFraction(with: rect) >= sameTargetOverlapThreshold
                    }
                }
                if let matchingClusterIndex {
                    clusters[matchingClusterIndex].append(element)
                } else {
                    clusters.append([element])
                }
            }

            guard clusters.count == 1, let cluster = clusters.first else {
                droppedAmbiguousLabels.append(label)
                continue
            }

            // Within one cluster, prefer the smallest rect: nested duplicates
            // (a button and its inner cell) should be scored against the tighter
            // of the two.
            guard let representative = cluster.min(by: {
                ($0.globalRect.width * $0.globalRect.height) < ($1.globalRect.width * $1.globalRect.height)
            }) else { continue }

            targets.append(GroundingTarget(
                identifier: "",
                label: representative.label,
                role: representative.role,
                rectInDisplayLocalPoints: CoordinateSpaces.displayLocalRect(
                    fromGlobalAccessibilityRect: representative.globalRect,
                    displayBoundsInGlobalPoints: displayBounds
                ),
                instruction: instruction(forLabel: representative.label, role: representative.role)
            ))
        }

        if !droppedAmbiguousLabels.isEmpty {
            let preview = droppedAmbiguousLabels.sorted().prefix(6).joined(separator: ", ")
            print("Dropped \(droppedAmbiguousLabels.count) ambiguous label(s) (same name, different places): \(preview)")
        }

        targets = removingTargetsThatShareAPlace(targets)

        // Stable, reading order: top to bottom, then left to right.
        targets.sort { lhs, rhs in
            let lhsRect = lhs.rectInDisplayLocalPoints
            let rhsRect = rhs.rectInDisplayLocalPoints
            if abs(lhsRect.y - rhsRect.y) > 4 { return lhsRect.y < rhsRect.y }
            return lhsRect.x < rhsRect.x
        }
        for index in targets.indices {
            targets[index].identifier = "t\(index)"
        }
        return targets
    }

    /// The mirror image of the ambiguous-label rule: different labels sitting on
    /// the SAME pixels. At most one of them can really be there, so all of them
    /// are unusable ground truth.
    ///
    /// This is not hypothetical — it is how hidden controls show up. A Finder
    /// list view instantiates seven tag radio buttons ("Add “Red” label", "Add
    /// “Blue” label", ...) per row inside a closed popover, and accessibility
    /// reports every one of them at the same placeholder rect (0, 960, 24x22).
    /// One capture produced 1,543 such elements. Their labels are all distinct,
    /// so the ambiguous-label rule never fires, and without this pass the
    /// dataset would ask a model to tell seven invisible controls apart at one
    /// 24x22 spot.
    private static func removingTargetsThatShareAPlace(_ targets: [GroundingTarget]) -> [GroundingTarget] {
        let sharedPlaceOverlapThreshold = 0.9
        var indicesToDrop = Set<Int>()

        for outerIndex in targets.indices {
            for innerIndex in targets.indices where innerIndex > outerIndex {
                let overlap = targets[outerIndex].rectInDisplayLocalPoints
                    .overlapFraction(with: targets[innerIndex].rectInDisplayLocalPoints)
                if overlap >= sharedPlaceOverlapThreshold {
                    indicesToDrop.insert(outerIndex)
                    indicesToDrop.insert(innerIndex)
                }
            }
        }

        guard !indicesToDrop.isEmpty else { return targets }
        let droppedLabels = indicesToDrop.sorted().prefix(6).map { targets[$0].label }
        print("Dropped \(indicesToDrop.count) target(s) whose rects coincide with a differently-labelled target "
              + "(hidden or placeholder geometry): \(droppedLabels.joined(separator: ", "))")
        return targets.enumerated()
            .filter { !indicesToDrop.contains($0.offset) }
            .map(\.element)
    }

    // MARK: - Instruction wording

    private static func instruction(forLabel label: String, role: String) -> String {
        let noun: String
        switch role {
        case "AXButton", "AXToolbarButton":
            noun = "button"
        case "AXMenuButton":
            noun = "menu button"
        case "AXPopUpButton":
            noun = "pop-up button"
        case "AXCheckBox":
            noun = "checkbox"
        case "AXRadioButton":
            noun = "radio button"
        case "AXLink":
            noun = "link"
        case "AXMenuItem":
            noun = "menu item"
        case "AXMenuBarItem":
            noun = "menu bar item"
        case "AXTextField":
            noun = "text field"
        case "AXSearchField":
            noun = "search field"
        case "AXTextArea":
            noun = "text area"
        case "AXSlider":
            noun = "slider"
        case "AXIncrementor":
            noun = "stepper"
        case "AXDisclosureTriangle":
            noun = "disclosure triangle"
        case "AXTab":
            noun = "tab"
        default:
            noun = "control"
        }
        return "Click the \"\(label)\" \(noun)"
    }

    // MARK: - Application resolution

    private static func resolveApplication(options: CommandLineOptions) throws -> NSRunningApplication {
        if options.useFrontmostApplication {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                throw CaptureCommandError.noFrontmostApplication
            }
            return frontmost
        }
        let bundleIdentifier = options.bundleIdentifier ?? ""
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            throw CaptureCommandError.applicationNotRunning(bundleIdentifier)
        }
        return application
    }

    private static func defaultOutputDirectory(bundleIdentifier: String) -> URL {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(bundleIdentifier)-\(timestamp)"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("grounding-lab-runs")
            .appendingPathComponent(name)
    }
}
