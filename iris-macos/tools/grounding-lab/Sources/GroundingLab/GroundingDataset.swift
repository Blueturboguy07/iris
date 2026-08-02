//
//  GroundingDataset.swift
//  grounding-lab
//
//  The on-disk shapes: `dataset.json` produced by `capture`, and `results.json`
//  produced by `run`.
//

import Foundation

// MARK: - Dataset

struct CapturedDisplayDescription: Codable {
    /// CoreGraphics display identifier of the display that was screenshotted.
    var displayIdentifier: UInt32
    /// The display's rectangle in GLOBAL ACCESSIBILITY POINTS (top-left origin).
    /// Subtracting this origin is what turns an accessibility rect into a
    /// display-local rect.
    var boundsInGlobalPoints: RectInPoints
    /// Points-to-pixels ratio. 2.0 on Retina. The PNG is this many times larger
    /// than `boundsInGlobalPoints` in each dimension.
    var backingScaleFactor: Double
    var screenshotWidthInPixels: Int
    var screenshotHeightInPixels: Int
}

struct GroundingTarget: Codable {
    var identifier: String
    /// The human-readable label the accessibility tree already knows.
    var label: String
    /// Raw accessibility role, e.g. `AXButton`.
    var role: String
    /// Ground truth, in DISPLAY-LOCAL POINTS (top-left origin).
    var rectInDisplayLocalPoints: RectInPoints
    /// The question posed to an arm, e.g. `Click the "New Folder" button`.
    var instruction: String
}

struct GroundingDataset: Codable {
    var formatVersion: Int
    var createdAtISO8601: String
    var bundleIdentifier: String
    var applicationName: String
    /// Relative to the directory holding `dataset.json`.
    var screenshotFileName: String
    var display: CapturedDisplayDescription
    /// A note carried in the file itself so nobody has to guess later.
    var coordinateSpaceNote: String
    var targets: [GroundingTarget]

    static let coordinateSpaceNoteText = """
        Every rect and point in this file is in DISPLAY-LOCAL POINTS: origin at \
        the TOP-LEFT of display.boundsInGlobalPoints, Y growing downward, units \
        of points (not pixels). Multiply by display.backingScaleFactor to index \
        into the PNG, which is stored in pixels. Add \
        display.boundsInGlobalPoints.origin to get back to the global \
        accessibility coordinates that AXPosition reports.
        """
}

// MARK: - Results

struct TargetOutcome: Codable {
    var targetIdentifier: String
    var instruction: String
    /// nil when the arm could not produce an answer at all (no match in the AX
    /// tree, API failure, unparseable response). Counted against coverage, not
    /// against accuracy.
    var predictedPointInDisplayLocalPoints: PointInPoints?
    var targetRectInDisplayLocalPoints: RectInPoints
    var isHit: Bool
    /// Euclidean distance from the prediction to the CENTER of the target rect,
    /// in points. nil when unresolved.
    var errorDistanceInPoints: Double?
    var latencySeconds: Double
    var apiCallCount: Int
    var failureReason: String?

    /// Kept so a coordinate-space hypothesis can be re-tested offline without
    /// spending another API call. Raw answer in the model's declared pixel
    /// space, plus the resolution it was declared at.
    var rawModelCoordinate: PointInPoints?
    var modelResolutionWidth: Int?
    var modelResolutionHeight: Int?

    /// Only populated by the claude-verify arm.
    var verificationProbes: [VerificationProbeOutcome]?
}

struct VerificationProbeOutcome: Codable {
    var probeKind: String          // "on-target" or "decoy"
    var probePointInDisplayLocalPoints: PointInPoints
    var expectedAnswerIsYes: Bool
    var modelAnsweredYes: Bool?
    var isCorrect: Bool
}

struct ArmResults: Codable {
    var armName: String
    var modelIdentifier: String?
    var targetsAttempted: Int
    var targetsResolved: Int
    var coverageFraction: Double
    var hits: Int
    /// Hit rate over RESOLVED targets. Reported separately from coverage
    /// because they answer different questions.
    var hitRateOverResolved: Double
    /// Hit rate over ALL attempted targets, counting unresolved as misses.
    var hitRateOverAttempted: Double
    var medianErrorDistanceInPoints: Double?
    var p95ErrorDistanceInPoints: Double?
    var p50LatencySeconds: Double
    var p95LatencySeconds: Double
    var apiCallCount: Int
    var estimatedCostUSD: Double
    var actualCostUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    /// claude-verify only.
    var verificationAccuracy: Double?
    var verificationTruePositiveRate: Double?
    var verificationFalsePositiveRate: Double?
    var outcomes: [TargetOutcome]
}

struct RunResults: Codable {
    var formatVersion: Int
    var createdAtISO8601: String
    var datasetPath: String
    var bundleIdentifier: String
    var hitPaddingInPoints: Double
    var arms: [ArmResults]
}
