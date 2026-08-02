//
//  AnthropicClient.swift
//  grounding-lab
//
//  Talks to the Anthropic Messages API for the `claude` and `claude-verify`
//  arms, and owns the image work both of them need.
//
//  The prompting and the aspect-ratio-matched downscaling are mirrored
//  deliberately from `iris-macos/leanring-buddy/ElementLocationDetector.swift`,
//  which is the battle-tested upstream implementation. Where this file diverges
//  from it, the divergence is commented.
//
//  The API key is read from ANTHROPIC_API_KEY and is never logged, echoed, or
//  written into any output file.
//

import AppKit
import CoreGraphics
import Foundation

struct AnthropicUsage {
    var inputTokens: Int
    var outputTokens: Int
}

struct ComputerUseResolution {
    var width: Int
    var height: Int
}

enum AnthropicClient {

    // MARK: - Configuration

    private static let messagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersionHeaderValue = "2023-06-01"

    /// The Computer Use tool version and the beta header that unlocks it, which
    /// together activate the pixel-counting behaviour that makes coordinate
    /// answers usable at all.
    struct ComputerUseToolVariant {
        var toolType: String
        var betaHeaderValue: String
    }

    /// The tool version is MODEL-SPECIFIC and the API rejects a mismatch with a
    /// 400, so this cannot be a single constant.
    ///
    /// The shipping detector hardcodes `computer_20251124` +
    /// `computer-use-2025-11-24` because it runs on Sonnet/Opus. Haiku 4.5 does
    /// not accept that version — it only accepts `computer_20250124`, which in
    /// turn needs the older `computer-use-2025-01-24` beta. Verified against the
    /// live API: sending the new tool type to Haiku 4.5 returns
    /// "does not support tool types: computer_20251124".
    static let newestComputerUseVariant = ComputerUseToolVariant(
        toolType: "computer_20251124",
        betaHeaderValue: "computer-use-2025-11-24"
    )
    static let legacyComputerUseVariant = ComputerUseToolVariant(
        toolType: "computer_20250124",
        betaHeaderValue: "computer-use-2025-01-24"
    )

    /// Computer-tool actions whose `coordinate` genuinely means "the element is
    /// here". Everything else (`scroll`, `left_click_drag`, `key`, `screenshot`)
    /// either has no coordinate or has one that means something else.
    static let pointingActions: Set<String> = [
        "left_click",
        "double_click",
        "triple_click",
        "right_click",
        "middle_click",
        "mouse_move"
    ]

    static func computerUseVariant(forModel model: String) -> ComputerUseToolVariant {
        if model.contains("haiku") {
            return legacyComputerUseVariant
        }
        return newestComputerUseVariant
    }

    /// Mirrored from ElementLocationDetector: the Anthropic-recommended Computer
    /// Use resolutions with their aspect ratios. Picking the closest ratio to the
    /// real display avoids stretching the screenshot, which measurably degrades
    /// X-axis accuracy.
    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768, 1024.0 / 768.0),    // 4:3
        (1280, 800, 1280.0 / 800.0),    // 16:10 — most Macs
        (1366, 768, 1366.0 / 768.0)     // ~16:9
    ]

    enum ClientError: LocalizedError {
        case missingAPIKey
        case imageResizeFailed
        case httpFailure(statusCode: Int, bodyPrefix: String)
        case noCoordinateInResponse(detail: String)
        case unparseableResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ANTHROPIC_API_KEY is not set. Source your .env.local first."
            case .imageResizeFailed:
                return "Failed to resize the screenshot for the model."
            case .httpFailure(let statusCode, let bodyPrefix):
                return "Anthropic API returned \(statusCode): \(bodyPrefix)"
            case .noCoordinateInResponse(let detail):
                return "Model returned no computer-tool coordinate — \(detail)"
            case .unparseableResponse:
                return "Could not parse the Anthropic response body."
            }
        }
    }

    static func apiKeyFromEnvironment() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.missingAPIKey
        }
        return key
    }

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - Resolution choice (mirrored from ElementLocationDetector)

    static func bestComputerUseResolution(
        displayWidthInPoints: Double,
        displayHeightInPoints: Double
    ) -> ComputerUseResolution {
        let displayAspectRatio = displayWidthInPoints / max(1.0, displayHeightInPoints)
        var best = ComputerUseResolution(width: 1280, height: 800)
        var smallestDifference = Double.greatestFiniteMagnitude
        for candidate in supportedComputerUseResolutions {
            let difference = abs(displayAspectRatio - candidate.aspectRatio)
            if difference < smallestDifference {
                smallestDifference = difference
                best = ComputerUseResolution(width: candidate.width, height: candidate.height)
            }
        }
        return best
    }

    // MARK: - Image work

    /// Mirrored from ElementLocationDetector, including the Retina fix: build an
    /// `NSBitmapImageRep` at exact pixel dimensions instead of using
    /// `NSImage.lockFocus()`, which would silently produce a 2x-larger bitmap on
    /// a Retina display. If the JPEG were 2x the resolution declared in the tool
    /// definition, every coordinate would come back at the wrong scale.
    static func resizeScreenshotForComputerUse(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Draws a crosshair for the verification arm.
    ///
    /// COORDINATE TRAP: an `NSBitmapImageRep`-backed graphics context is NOT
    /// flipped — its origin is bottom-left. The crosshair position arrives in
    /// the resized image's top-left-origin pixel space (the same space Computer
    /// Use answers in), so the Y coordinate must be flipped once, here, before
    /// any drawing. Everything else in this tool stays top-left.
    static func imageWithCrosshair(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int,
        crosshairTopLeftOriginPoint: CGPoint
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )

        let drawX = crosshairTopLeftOriginPoint.x
        let drawY = CGFloat(targetHeight) - crosshairTopLeftOriginPoint.y  // the one flip

        NSColor.systemRed.setStroke()
        let armLength: CGFloat = 26
        let strokeWidth: CGFloat = 2.5

        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: drawX - armLength, y: drawY))
        horizontal.line(to: NSPoint(x: drawX + armLength, y: drawY))
        horizontal.lineWidth = strokeWidth
        horizontal.stroke()

        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: drawX, y: drawY - armLength))
        vertical.line(to: NSPoint(x: drawX, y: drawY + armLength))
        vertical.lineWidth = strokeWidth
        vertical.stroke()

        let circle = NSBezierPath(ovalIn: NSRect(x: drawX - 9, y: drawY - 9, width: 18, height: 18))
        circle.lineWidth = strokeWidth
        circle.stroke()

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Computer Use grounding call

    struct GroundingAnswer {
        /// Raw coordinate in the DECLARED MODEL RESOLUTION pixel space,
        /// top-left origin. Kept unconverted so a coordinate-space hypothesis
        /// can be re-tested offline without spending another API call.
        var rawModelCoordinate: CGPoint
        var resolution: ComputerUseResolution
        var usage: AnthropicUsage
    }

    static func locateElement(
        apiKey: String,
        model: String,
        resizedScreenshotJPEG: Data,
        declaredResolution: ComputerUseResolution,
        instruction: String
    ) async throws -> GroundingAnswer {
        // Mirrored in spirit from ElementLocationDetector's user prompt: describe
        // what the user wants and ask for a click, so the same pixel-counting
        // behaviour is exercised.
        //
        // Two deliberate additions over upstream, both found empirically against
        // the live API. Upstream runs on Sonnet, which answers with a
        // `left_click` straight away; Haiku 4.5 instead opens with the
        // `screenshot` action ("let me first take a screenshot to see the
        // current state"), because a computer-use tool normally implies an agent
        // loop. Seven of ten calls returned no coordinate until the prompt said
        // the screenshot is already attached. That is a harness artefact, not
        // the model failing to ground, so it is fixed in the prompt rather than
        // counted as a miss.
        let userPrompt = """
            The image is a screenshot of the user's screen that has ALREADY been taken. \
            Do not call the screenshot action — you already have the screenshot.

            Task: \(instruction)

            Respond with exactly one computer tool call: a left_click whose coordinate is \
            the centre of that element. If the element is genuinely not visible anywhere in \
            the image, reply with the plain text "not found" and make no tool call.
            """

        let variant = computerUseVariant(forModel: model)
        let requestBody: [String: Any] = [
            "model": model,
            // 1024, not the shipping detector's 256. Haiku 4.5 writes a long
            // preamble before its tool call and was hitting `stop_reason:
            // "max_tokens"` mid-sentence, which the harness would otherwise
            // score as "the model could not find the element". Verified against
            // the live API: the same instruction that truncates at 256 returns a
            // tool call at 1024.
            "max_tokens": 1024,
            "tools": [[
                "type": variant.toolType,
                "name": "computer",
                "display_width_px": declaredResolution.width,
                "display_height_px": declaredResolution.height
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": resizedScreenshotJPEG.base64EncodedString()
                        ]
                    ],
                    ["type": "text", "text": userPrompt]
                ]
            ]]
        ]

        let json = try await postMessages(
            apiKey: apiKey,
            body: requestBody,
            betaHeaderValue: variant.betaHeaderValue
        )
        let usage = parseUsage(json)

        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw ClientError.unparseableResponse
        }
        var observedActions: [String] = []
        var observedText = ""
        for block in contentBlocks {
            let blockType = block["type"] as? String
            if blockType == "text", let text = block["text"] as? String {
                observedText += text
            }
            guard blockType == "tool_use",
                  let input = block["input"] as? [String: Any] else {
                continue
            }
            let action = (input["action"] as? String) ?? "(no action)"
            observedActions.append(action)
            // A `coordinate` alone is NOT an answer to "where is this element".
            // `scroll` also carries one — it is where to put the pointer before
            // spinning the wheel, and Haiku genuinely returns it when it decides
            // the element is below the fold. Accepting it would have scored a
            // scroll anchor as a grounding prediction, inflating both coverage
            // and error. Only pointing actions count.
            guard pointingActions.contains(action) else { continue }
            guard let coordinate = input["coordinate"] as? [NSNumber], coordinate.count == 2 else {
                continue
            }
            return GroundingAnswer(
                rawModelCoordinate: CGPoint(
                    x: CGFloat(coordinate[0].doubleValue),
                    y: CGFloat(coordinate[1].doubleValue)
                ),
                resolution: declaredResolution,
                usage: usage
            )
        }
        // Say WHY there was no coordinate: a bare "no coordinate" cannot be told
        // apart from the model abstaining, which is a completely different
        // finding.
        let summary = observedActions.isEmpty
            ? "text only: \(observedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))"
            : "tool actions without a coordinate: \(observedActions.joined(separator: ", "))"
        throw ClientError.noCoordinateInResponse(detail: String(summary))
    }

    // MARK: - Verification call

    struct VerificationAnswer {
        var modelAnsweredYes: Bool?
        var usage: AnthropicUsage
    }

    static func verifyCrosshair(
        apiKey: String,
        model: String,
        annotatedScreenshotJPEG: Data,
        targetDescription: String
    ) async throws -> VerificationAnswer {
        // No computer tool here — verification is plain vision, which is the
        // whole point: checking an answer is cheaper than producing one.
        let userPrompt = """
            A red crosshair has been drawn on this screenshot of a macOS screen.

            Is the crosshair positioned on the \(targetDescription)?

            Answer with exactly one word: yes or no.
            """

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": annotatedScreenshotJPEG.base64EncodedString()
                        ]
                    ],
                    ["type": "text", "text": userPrompt]
                ]
            ]]
        ]

        let json = try await postMessages(apiKey: apiKey, body: requestBody, betaHeaderValue: nil)
        let usage = parseUsage(json)

        var answeredYes: Bool?
        if let contentBlocks = json["content"] as? [[String: Any]] {
            for block in contentBlocks where (block["type"] as? String) == "text" {
                let text = ((block["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if text.hasPrefix("yes") {
                    answeredYes = true
                } else if text.hasPrefix("no") {
                    answeredYes = false
                }
                if answeredYes != nil { break }
            }
        }
        return VerificationAnswer(modelAnsweredYes: answeredYes, usage: usage)
    }

    // MARK: - Transport

    private static func postMessages(
        apiKey: String,
        body: [String: Any],
        betaHeaderValue: String?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: messagesEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersionHeaderValue, forHTTPHeaderField: "anthropic-version")
        if let betaHeaderValue {
            request.setValue(betaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.unparseableResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            // The body can echo request fields but never the key — the key only
            // ever lives in a request header.
            let bodyPrefix = String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
            throw ClientError.httpFailure(statusCode: httpResponse.statusCode, bodyPrefix: bodyPrefix)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.unparseableResponse
        }
        return json
    }

    private static func parseUsage(_ json: [String: Any]) -> AnthropicUsage {
        let usage = json["usage"] as? [String: Any]
        return AnthropicUsage(
            inputTokens: (usage?["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage?["output_tokens"] as? Int) ?? 0
        )
    }
}

// MARK: - Pricing

struct ModelPricing {
    var inputUSDPerMillionTokens: Double
    var outputUSDPerMillionTokens: Double
}

enum AnthropicPricing {
    /// Public list prices, USD per million tokens.
    static let pricingByModel: [String: ModelPricing] = [
        "claude-haiku-4-5": ModelPricing(inputUSDPerMillionTokens: 1.00, outputUSDPerMillionTokens: 5.00),
        "claude-sonnet-4-6": ModelPricing(inputUSDPerMillionTokens: 3.00, outputUSDPerMillionTokens: 15.00),
        "claude-sonnet-5": ModelPricing(inputUSDPerMillionTokens: 3.00, outputUSDPerMillionTokens: 15.00),
        "claude-opus-4-8": ModelPricing(inputUSDPerMillionTokens: 5.00, outputUSDPerMillionTokens: 25.00),
        "claude-opus-5": ModelPricing(inputUSDPerMillionTokens: 5.00, outputUSDPerMillionTokens: 25.00)
    ]

    /// Falls back to the most expensive current tier so an unknown model is
    /// over-estimated rather than under-estimated.
    static func pricing(forModel model: String) -> ModelPricing {
        pricingByModel[model]
            ?? ModelPricing(inputUSDPerMillionTokens: 5.00, outputUSDPerMillionTokens: 25.00)
    }

    /// Declaring the computer tool injects its own sizeable system prompt on top
    /// of the caller's message. Measured against the live API: a grounding call
    /// bills ~2,930 input tokens where image + prompt alone account for ~1,565,
    /// so the tool definition costs roughly this much. Leaving it out made the
    /// pre-flight estimate 40% low, which defeats the point of printing one.
    static let computerToolDefinitionOverheadTokens = 1_400.0

    /// A JPEG costs roughly (width * height) / 750 input tokens, plus the
    /// prompt, plus any tool-definition overhead. Output is one short tool call.
    static func estimatedCostUSD(
        model: String,
        callCount: Int,
        imageWidth: Int,
        imageHeight: Int,
        toolDefinitionOverheadTokens: Double
    ) -> Double {
        let imageTokens = Double(imageWidth * imageHeight) / 750.0
        let promptTokens = 200.0
        let outputTokens = 100.0
        let pricing = pricing(forModel: model)
        let inputTokens = imageTokens + promptTokens + toolDefinitionOverheadTokens
        let perCall = (inputTokens / 1_000_000.0) * pricing.inputUSDPerMillionTokens
            + (outputTokens / 1_000_000.0) * pricing.outputUSDPerMillionTokens
        return perCall * Double(callCount)
    }

    static func actualCostUSD(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let pricing = pricing(forModel: model)
        return (Double(inputTokens) / 1_000_000.0) * pricing.inputUSDPerMillionTokens
            + (Double(outputTokens) / 1_000_000.0) * pricing.outputUSDPerMillionTokens
    }
}
