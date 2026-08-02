//
//  AccessibilityArm.swift
//  grounding-lab
//
//  The `ax` arm: resolve each instruction by searching the LIVE accessibility
//  tree for the target's label, and answer with that element's centre.
//
//  It is near-perfect by construction, so its accuracy number is close to
//  meaningless on its own. Its real output is COVERAGE — the fraction of
//  instructions it can answer at all. That is the number that decides whether an
//  accessibility-first pointing architecture is even viable, and it is reported
//  separately for exactly that reason.
//

import AppKit
import CoreGraphics
import Foundation

enum AccessibilityArm {

    enum ArmError: LocalizedError {
        case applicationNotRunning(String)

        var errorDescription: String? {
            switch self {
            case .applicationNotRunning(let bundleIdentifier):
                return """
                    The dataset's application (\(bundleIdentifier)) is not running. \
                    The ax arm reads the live accessibility tree, so the app has to \
                    be open and in roughly the state it was captured in.
                    """
            }
        }
    }

    static func run(
        dataset: GroundingDataset,
        targets: [GroundingTarget],
        hitPaddingInPoints: Double,
        settleSeconds: Double
    ) async throws -> ArmResults {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: dataset.bundleIdentifier)
            .first else {
            throw ArmError.applicationNotRunning(dataset.bundleIdentifier)
        }

        application.activate()
        try await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))

        let walkStart = Date()
        let discovered = AccessibilityTreeWalker.discoverElements(
            forProcessIdentifier: application.processIdentifier
        )
        let walkSeconds = Date().timeIntervalSince(walkStart)

        let displayBounds = dataset.display.boundsInGlobalPoints.asCGRect

        // Label+role -> display-local rects found live. A label that now resolves
        // to several disjoint places is treated as unresolvable, matching the
        // ambiguity rule the dataset itself was built with.
        var liveRectsByKey: [String: [RectInPoints]] = [:]
        for element in discovered {
            let localRect = CoordinateSpaces.displayLocalRect(
                fromGlobalAccessibilityRect: element.globalRect,
                displayBoundsInGlobalPoints: displayBounds
            )
            liveRectsByKey[key(label: element.label, role: element.role), default: []].append(localRect)
        }

        // The walk is one operation for the whole arm; charging each target an
        // equal share is the honest per-target latency.
        let perTargetLatencySeconds = targets.isEmpty ? walkSeconds : walkSeconds / Double(targets.count)

        var outcomes: [TargetOutcome] = []
        for target in targets {
            let candidates = liveRectsByKey[key(label: target.label, role: target.role)] ?? []

            // Collapse overlapping duplicates; anything left over is ambiguous.
            var distinctRects: [RectInPoints] = []
            for candidate in candidates {
                if distinctRects.contains(where: { $0.overlapFraction(with: candidate) >= 0.5 }) { continue }
                distinctRects.append(candidate)
            }

            guard distinctRects.count == 1, let resolvedRect = distinctRects.first else {
                outcomes.append(TargetOutcome(
                    targetIdentifier: target.identifier,
                    instruction: target.instruction,
                    predictedPointInDisplayLocalPoints: nil,
                    targetRectInDisplayLocalPoints: target.rectInDisplayLocalPoints,
                    isHit: false,
                    errorDistanceInPoints: nil,
                    latencySeconds: perTargetLatencySeconds,
                    apiCallCount: 0,
                    failureReason: candidates.isEmpty
                        ? "no live accessibility element with this label and role"
                        : "label now resolves to \(distinctRects.count) disjoint elements",
                    rawModelCoordinate: nil,
                    modelResolutionWidth: nil,
                    modelResolutionHeight: nil,
                    verificationProbes: nil
                ))
                continue
            }

            let predicted = PointInPoints(x: resolvedRect.centerX, y: resolvedRect.centerY)
            outcomes.append(Scoring.outcome(
                target: target,
                predictedPoint: predicted,
                latencySeconds: perTargetLatencySeconds,
                apiCallCount: 0,
                hitPaddingInPoints: hitPaddingInPoints,
                rawModelCoordinate: nil,
                resolution: nil
            ))
        }

        return Scoring.summarise(
            armName: "ax",
            modelIdentifier: nil,
            outcomes: outcomes,
            estimatedCostUSD: 0,
            actualCostUSD: 0,
            inputTokens: nil,
            outputTokens: nil
        )
    }

    private static func key(label: String, role: String) -> String {
        "\(role)\u{1F}\(label)"
    }
}
