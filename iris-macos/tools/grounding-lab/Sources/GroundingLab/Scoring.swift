//
//  Scoring.swift
//  grounding-lab
//
//  One definition of "hit" and one definition of "error", used by every arm.
//

import Foundation

enum Scoring {

    /// A hit is the predicted point landing inside the target rect, padded.
    static let defaultHitPaddingInPoints: Double = 8.0

    static func outcome(
        target: GroundingTarget,
        predictedPoint: PointInPoints,
        latencySeconds: Double,
        apiCallCount: Int,
        hitPaddingInPoints: Double,
        rawModelCoordinate: PointInPoints?,
        resolution: ComputerUseResolution?
    ) -> TargetOutcome {
        let rect = target.rectInDisplayLocalPoints
        let isHit = rect.containsPoint(
            x: predictedPoint.x,
            y: predictedPoint.y,
            paddedBy: hitPaddingInPoints
        )
        // Error is distance to the target's CENTRE. Paired with hit rate this
        // separates "near miss on a small control" from "pointed at the wrong
        // half of the screen".
        let centre = PointInPoints(x: rect.centerX, y: rect.centerY)

        return TargetOutcome(
            targetIdentifier: target.identifier,
            instruction: target.instruction,
            predictedPointInDisplayLocalPoints: predictedPoint,
            targetRectInDisplayLocalPoints: rect,
            isHit: isHit,
            errorDistanceInPoints: predictedPoint.distance(to: centre),
            latencySeconds: latencySeconds,
            apiCallCount: apiCallCount,
            failureReason: nil,
            rawModelCoordinate: rawModelCoordinate,
            modelResolutionWidth: resolution?.width,
            modelResolutionHeight: resolution?.height,
            verificationProbes: nil
        )
    }

    static func summarise(
        armName: String,
        modelIdentifier: String?,
        outcomes: [TargetOutcome],
        estimatedCostUSD: Double,
        actualCostUSD: Double?,
        inputTokens: Int?,
        outputTokens: Int?,
        verificationAccuracy: Double? = nil,
        verificationTruePositiveRate: Double? = nil,
        verificationFalsePositiveRate: Double? = nil
    ) -> ArmResults {
        let attempted = outcomes.count
        let resolved = outcomes.filter { $0.predictedPointInDisplayLocalPoints != nil }.count
        let hits = outcomes.filter(\.isHit).count
        let errors = outcomes.compactMap(\.errorDistanceInPoints).sorted()
        let latencies = outcomes.map(\.latencySeconds).sorted()

        return ArmResults(
            armName: armName,
            modelIdentifier: modelIdentifier,
            targetsAttempted: attempted,
            targetsResolved: resolved,
            coverageFraction: attempted == 0 ? 0 : Double(resolved) / Double(attempted),
            hits: hits,
            hitRateOverResolved: resolved == 0 ? 0 : Double(hits) / Double(resolved),
            hitRateOverAttempted: attempted == 0 ? 0 : Double(hits) / Double(attempted),
            medianErrorDistanceInPoints: percentile(errors, 0.50),
            p95ErrorDistanceInPoints: percentile(errors, 0.95),
            p50LatencySeconds: percentile(latencies, 0.50) ?? 0,
            p95LatencySeconds: percentile(latencies, 0.95) ?? 0,
            apiCallCount: outcomes.reduce(0) { $0 + $1.apiCallCount },
            estimatedCostUSD: estimatedCostUSD,
            actualCostUSD: actualCostUSD,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            verificationAccuracy: verificationAccuracy,
            verificationTruePositiveRate: verificationTruePositiveRate,
            verificationFalsePositiveRate: verificationFalsePositiveRate,
            outcomes: outcomes
        )
    }

    /// Nearest-rank percentile over an already-sorted array.
    static func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let rank = Int((fraction * Double(sortedValues.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sortedValues.count - 1)
        return sortedValues[index]
    }

    /// Evenly spaced subsample, so a `--limit` does not score only the menu bar.
    static func evenlySpacedSubset<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0, items.count > limit else { return items }
        let stride = Double(items.count) / Double(limit)
        return (0..<limit).map { items[min(items.count - 1, Int(Double($0) * stride))] }
    }
}
