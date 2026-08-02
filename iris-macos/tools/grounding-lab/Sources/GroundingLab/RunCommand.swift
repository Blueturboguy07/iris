//
//  RunCommand.swift
//  grounding-lab
//
//  `grounding-lab run` — score one or more arms against a dataset, print a
//  comparison table, and write results.json.
//

import CoreGraphics
import Foundation

enum RunCommand {

    enum RunCommandError: LocalizedError {
        case datasetNotFound(String)
        case screenshotNotFound(String)
        case unknownArm(String)
        case noTargets

        var errorDescription: String? {
            switch self {
            case .datasetNotFound(let path):
                return "No dataset at \(path). Run `grounding-lab capture` first."
            case .screenshotNotFound(let path):
                return "Dataset references a screenshot that is missing: \(path)"
            case .unknownArm(let name):
                return "Unknown arm '\(name)'. Valid arms: ax, claude, claude-verify."
            case .noTargets:
                return "The dataset contains no targets."
            }
        }
    }

    static func run(options: CommandLineOptions) async throws {
        let datasetURL = URL(fileURLWithPath: options.datasetPath ?? "dataset.json")
        guard FileManager.default.fileExists(atPath: datasetURL.path) else {
            throw RunCommandError.datasetNotFound(datasetURL.path)
        }
        let dataset = try JSONDecoder().decode(
            GroundingDataset.self,
            from: Data(contentsOf: datasetURL)
        )
        guard !dataset.targets.isEmpty else { throw RunCommandError.noTargets }

        let screenshotURL = datasetURL
            .deletingLastPathComponent()
            .appendingPathComponent(dataset.screenshotFileName)
        guard FileManager.default.fileExists(atPath: screenshotURL.path) else {
            throw RunCommandError.screenshotNotFound(screenshotURL.path)
        }
        let screenshotData = try Data(contentsOf: screenshotURL)

        let selectedTargets = Scoring.evenlySpacedSubset(dataset.targets, limit: options.limit)
        print("Dataset: \(dataset.applicationName) (\(dataset.bundleIdentifier)) — \(dataset.targets.count) targets")
        print("Scoring \(selectedTargets.count) of them (--limit \(options.limit == 0 ? "off" : String(options.limit)))")
        print("Hit rule: predicted point inside the target rect padded by \(Int(options.hitPaddingInPoints))pt")
        print("")

        var armResults: [ArmResults] = []
        for armName in options.arms {
            switch armName {
            case "ax":
                armResults.append(try await AccessibilityArm.run(
                    dataset: dataset,
                    targets: selectedTargets,
                    hitPaddingInPoints: options.hitPaddingInPoints,
                    settleSeconds: options.settleSeconds
                ))
            case "claude":
                armResults.append(try await runClaudeGroundingArm(
                    dataset: dataset,
                    targets: selectedTargets,
                    screenshotData: screenshotData,
                    options: options
                ))
            case "claude-verify":
                armResults.append(try await runClaudeVerificationArm(
                    dataset: dataset,
                    targets: selectedTargets,
                    screenshotData: screenshotData,
                    options: options
                ))
            default:
                throw RunCommandError.unknownArm(armName)
            }
        }

        printComparisonTable(armResults)

        let results = RunResults(
            formatVersion: 1,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            datasetPath: datasetURL.path,
            bundleIdentifier: dataset.bundleIdentifier,
            hitPaddingInPoints: options.hitPaddingInPoints,
            arms: armResults
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let resultsURL = options.resultsPath.map { URL(fileURLWithPath: $0) }
            ?? datasetURL.deletingLastPathComponent().appendingPathComponent("results.json")
        try encoder.encode(results).write(to: resultsURL)
        print("")
        print("Wrote \(resultsURL.path)")
    }

    // MARK: - claude arm

    private static func runClaudeGroundingArm(
        dataset: GroundingDataset,
        targets: [GroundingTarget],
        screenshotData: Data,
        options: CommandLineOptions
    ) async throws -> ArmResults {
        let apiKey = try AnthropicClient.apiKeyFromEnvironment()
        let displayWidthInPoints = dataset.display.boundsInGlobalPoints.width
        let displayHeightInPoints = dataset.display.boundsInGlobalPoints.height

        let resolution = AnthropicClient.bestComputerUseResolution(
            displayWidthInPoints: displayWidthInPoints,
            displayHeightInPoints: displayHeightInPoints
        )
        guard let resizedJPEG = AnthropicClient.resizeScreenshotForComputerUse(
            originalImageData: screenshotData,
            targetWidth: resolution.width,
            targetHeight: resolution.height
        ) else {
            throw AnthropicClient.ClientError.imageResizeFailed
        }

        let estimatedCost = AnthropicPricing.estimatedCostUSD(
            model: options.model,
            callCount: targets.count,
            imageWidth: resolution.width,
            imageHeight: resolution.height,
            toolDefinitionOverheadTokens: AnthropicPricing.computerToolDefinitionOverheadTokens
        )
        print("--- arm: claude (\(options.model)) ---")
        print(String(
            format: "Display %.0fx%.0f pt (ratio %.3f) -> declaring %dx%d to the computer tool",
            displayWidthInPoints, displayHeightInPoints,
            displayWidthInPoints / displayHeightInPoints,
            resolution.width, resolution.height
        ))
        // Required cost control: the estimate is printed BEFORE the first call.
        print(String(format: "Estimated cost for %d API calls: $%.4f", targets.count, estimatedCost))

        var outcomes: [TargetOutcome] = []
        var totalInputTokens = 0
        var totalOutputTokens = 0

        for (index, target) in targets.enumerated() {
            let start = Date()
            do {
                let answer = try await AnthropicClient.locateElement(
                    apiKey: apiKey,
                    model: options.model,
                    resizedScreenshotJPEG: resizedJPEG,
                    declaredResolution: resolution,
                    instruction: target.instruction
                )
                let latency = Date().timeIntervalSince(start)
                totalInputTokens += answer.usage.inputTokens
                totalOutputTokens += answer.usage.outputTokens

                // The one conversion that matters. See CoordinateSpaces.
                let predicted = CoordinateSpaces.modelResolutionPointToDisplayLocalPoint(
                    modelPoint: answer.rawModelCoordinate,
                    modelResolutionWidth: resolution.width,
                    modelResolutionHeight: resolution.height,
                    displayWidthInPoints: displayWidthInPoints,
                    displayHeightInPoints: displayHeightInPoints
                )

                let outcome = Scoring.outcome(
                    target: target,
                    predictedPoint: predicted,
                    latencySeconds: latency,
                    apiCallCount: 1,
                    hitPaddingInPoints: options.hitPaddingInPoints,
                    rawModelCoordinate: PointInPoints(
                        x: Double(answer.rawModelCoordinate.x),
                        y: Double(answer.rawModelCoordinate.y)
                    ),
                    resolution: resolution
                )
                outcomes.append(outcome)
                print(String(
                    format: "  %2d/%d %@  %@  err %.0fpt  %.2fs",
                    index + 1, targets.count,
                    outcome.isHit ? "HIT " : "miss",
                    target.instruction,
                    outcome.errorDistanceInPoints ?? -1,
                    latency
                ))
            } catch {
                let latency = Date().timeIntervalSince(start)
                outcomes.append(TargetOutcome(
                    targetIdentifier: target.identifier,
                    instruction: target.instruction,
                    predictedPointInDisplayLocalPoints: nil,
                    targetRectInDisplayLocalPoints: target.rectInDisplayLocalPoints,
                    isHit: false,
                    errorDistanceInPoints: nil,
                    latencySeconds: latency,
                    apiCallCount: 1,
                    failureReason: error.localizedDescription,
                    rawModelCoordinate: nil,
                    modelResolutionWidth: resolution.width,
                    modelResolutionHeight: resolution.height,
                    verificationProbes: nil
                ))
                print("  \(index + 1)/\(targets.count) FAIL \(target.instruction) — \(error.localizedDescription)")
            }
        }

        let actualCost = AnthropicPricing.actualCostUSD(
            model: options.model,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens
        )
        print(String(format: "Actual cost: $%.4f (%d in / %d out tokens)", actualCost, totalInputTokens, totalOutputTokens))

        return Scoring.summarise(
            armName: "claude",
            modelIdentifier: options.model,
            outcomes: outcomes,
            estimatedCostUSD: estimatedCost,
            actualCostUSD: actualCost,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens
        )
    }

    // MARK: - claude-verify arm

    /// Verification is scored as a two-way discrimination, not as pointing:
    /// each target gets one probe at its true centre (correct answer: yes) and
    /// one at a decoy — another target's centre (correct answer: no). A model
    /// that always says "yes" therefore scores 50%, not 100%, which is the whole
    /// reason the decoy exists.
    private static func runClaudeVerificationArm(
        dataset: GroundingDataset,
        targets: [GroundingTarget],
        screenshotData: Data,
        options: CommandLineOptions
    ) async throws -> ArmResults {
        let apiKey = try AnthropicClient.apiKeyFromEnvironment()
        let displayWidthInPoints = dataset.display.boundsInGlobalPoints.width
        let displayHeightInPoints = dataset.display.boundsInGlobalPoints.height
        let resolution = AnthropicClient.bestComputerUseResolution(
            displayWidthInPoints: displayWidthInPoints,
            displayHeightInPoints: displayHeightInPoints
        )

        let callCount = targets.count * 2
        let estimatedCost = AnthropicPricing.estimatedCostUSD(
            model: options.model,
            callCount: callCount,
            imageWidth: resolution.width,
            imageHeight: resolution.height,
            // Verification declares no tools, so there is no tool-definition
            // overhead — measured at ~1,390 input tokens per call.
            toolDefinitionOverheadTokens: 0
        )
        print("--- arm: claude-verify (\(options.model)) ---")
        print("Two probes per target: one on the real element, one on a decoy element.")
        print(String(format: "Estimated cost for %d API calls: $%.4f", callCount, estimatedCost))

        var outcomes: [TargetOutcome] = []
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var correctProbes = 0
        var totalProbes = 0
        var truePositives = 0
        var positiveProbes = 0
        var falsePositives = 0
        var negativeProbes = 0

        for (index, target) in targets.enumerated() {
            let decoy = targets[(index + targets.count / 2) % targets.count]
            let probeSpecifications: [(kind: String, point: PointInPoints, expectedYes: Bool)] = [
                (
                    "on-target",
                    PointInPoints(
                        x: target.rectInDisplayLocalPoints.centerX,
                        y: target.rectInDisplayLocalPoints.centerY
                    ),
                    true
                ),
                (
                    "decoy",
                    PointInPoints(
                        x: decoy.rectInDisplayLocalPoints.centerX,
                        y: decoy.rectInDisplayLocalPoints.centerY
                    ),
                    decoy.identifier == target.identifier
                )
            ]

            let start = Date()
            var probeOutcomes: [VerificationProbeOutcome] = []
            var apiCalls = 0

            for specification in probeSpecifications {
                // Display-local points -> the resized image's pixel space. Both
                // are top-left origin, so this is a uniform rescale; the single
                // Y flip needed for drawing happens inside imageWithCrosshair.
                let crosshairInModelPixels = CGPoint(
                    x: (specification.point.x / displayWidthInPoints) * Double(resolution.width),
                    y: (specification.point.y / displayHeightInPoints) * Double(resolution.height)
                )
                guard let annotatedJPEG = AnthropicClient.imageWithCrosshair(
                    originalImageData: screenshotData,
                    targetWidth: resolution.width,
                    targetHeight: resolution.height,
                    crosshairTopLeftOriginPoint: crosshairInModelPixels
                ) else {
                    throw AnthropicClient.ClientError.imageResizeFailed
                }

                let description = "\"\(target.label)\" \(nounFragment(from: target.instruction))"
                var answeredYes: Bool?
                do {
                    let answer = try await AnthropicClient.verifyCrosshair(
                        apiKey: apiKey,
                        model: options.model,
                        annotatedScreenshotJPEG: annotatedJPEG,
                        targetDescription: description
                    )
                    answeredYes = answer.modelAnsweredYes
                    totalInputTokens += answer.usage.inputTokens
                    totalOutputTokens += answer.usage.outputTokens
                } catch {
                    answeredYes = nil
                }
                apiCalls += 1

                let isCorrect = (answeredYes == specification.expectedYes)
                probeOutcomes.append(VerificationProbeOutcome(
                    probeKind: specification.kind,
                    probePointInDisplayLocalPoints: specification.point,
                    expectedAnswerIsYes: specification.expectedYes,
                    modelAnsweredYes: answeredYes,
                    isCorrect: isCorrect
                ))

                totalProbes += 1
                if isCorrect { correctProbes += 1 }
                if specification.expectedYes {
                    positiveProbes += 1
                    if answeredYes == true { truePositives += 1 }
                } else {
                    negativeProbes += 1
                    if answeredYes == true { falsePositives += 1 }
                }
            }

            let latency = Date().timeIntervalSince(start)
            let allProbesCorrect = probeOutcomes.allSatisfy(\.isCorrect)
            // The verify arm produces no coordinate, so it has no predicted point
            // and no error distance. "isHit" here means "got both probes right".
            outcomes.append(TargetOutcome(
                targetIdentifier: target.identifier,
                instruction: target.instruction,
                predictedPointInDisplayLocalPoints: nil,
                targetRectInDisplayLocalPoints: target.rectInDisplayLocalPoints,
                isHit: allProbesCorrect,
                errorDistanceInPoints: nil,
                latencySeconds: latency,
                apiCallCount: apiCalls,
                failureReason: allProbesCorrect ? nil : "at least one probe answered incorrectly",
                rawModelCoordinate: nil,
                modelResolutionWidth: resolution.width,
                modelResolutionHeight: resolution.height,
                verificationProbes: probeOutcomes
            ))

            print(String(
                format: "  %2d/%d %@  %@  %.2fs",
                index + 1, targets.count,
                allProbesCorrect ? "BOTH" : "part",
                target.instruction,
                latency
            ))
        }

        let actualCost = AnthropicPricing.actualCostUSD(
            model: options.model,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens
        )
        print(String(format: "Actual cost: $%.4f (%d in / %d out tokens)", actualCost, totalInputTokens, totalOutputTokens))

        var summary = Scoring.summarise(
            armName: "claude-verify",
            modelIdentifier: options.model,
            outcomes: outcomes,
            estimatedCostUSD: estimatedCost,
            actualCostUSD: actualCost,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            verificationAccuracy: totalProbes == 0 ? 0 : Double(correctProbes) / Double(totalProbes),
            verificationTruePositiveRate: positiveProbes == 0 ? nil : Double(truePositives) / Double(positiveProbes),
            verificationFalsePositiveRate: negativeProbes == 0 ? nil : Double(falsePositives) / Double(negativeProbes)
        )
        // Coverage is not a meaningful concept for this arm; it answers every
        // probe or fails outright.
        summary.coverageFraction = totalProbes == 0 ? 0 : Double(correctProbes) / Double(totalProbes)
        return summary
    }

    /// `Click the "Reload" button` -> `button`, for a natural verification question.
    private static func nounFragment(from instruction: String) -> String {
        guard let lastQuote = instruction.lastIndex(of: "\"") else { return "element" }
        let remainder = instruction[instruction.index(after: lastQuote)...]
            .trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? "element" : remainder
    }

    // MARK: - Comparison table

    private static func printComparisonTable(_ arms: [ArmResults]) {
        print("")
        print("========================================================================================")
        print("arm            model              cover   hit    med.err  p95.err  p50 lat  p95 lat  calls   cost")
        print("----------------------------------------------------------------------------------------")
        for arm in arms {
            let model = (arm.modelIdentifier ?? "—").padding(toLength: 18, withPad: " ", startingAt: 0)
            let name = arm.armName.padding(toLength: 14, withPad: " ", startingAt: 0)
            let medianError = arm.medianErrorDistanceInPoints.map { String(format: "%6.0f", $0) } ?? "     —"
            let p95Error = arm.p95ErrorDistanceInPoints.map { String(format: "%6.0f", $0) } ?? "     —"
            let cost = arm.actualCostUSD ?? arm.estimatedCostUSD
            // claude-verify never produces a coordinate, so "over resolved" has
            // no denominator for it; its hit column is the fraction of targets
            // where BOTH probes were answered correctly.
            let hitRate = arm.targetsResolved > 0 ? arm.hitRateOverResolved : arm.hitRateOverAttempted
            print(String(
                format: "%@ %@ %5.0f%% %5.0f%% %@pt %@pt %7.2fs %7.2fs %5d  $%.4f",
                name, model,
                arm.coverageFraction * 100,
                hitRate * 100,
                medianError, p95Error,
                arm.p50LatencySeconds, arm.p95LatencySeconds,
                arm.apiCallCount, cost
            ))
        }
        print("========================================================================================")
        print("cover = fraction of instructions the arm could answer at all (for claude-verify: probe accuracy)")
        print("hit   = fraction of ANSWERED instructions landing inside the padded target rect")
        for arm in arms where arm.verificationAccuracy != nil {
            print(String(
                format: "claude-verify: probe accuracy %.0f%%, true-positive rate %.0f%%, false-positive rate %.0f%%",
                (arm.verificationAccuracy ?? 0) * 100,
                (arm.verificationTruePositiveRate ?? 0) * 100,
                (arm.verificationFalsePositiveRate ?? 0) * 100
            ))
        }
    }
}
