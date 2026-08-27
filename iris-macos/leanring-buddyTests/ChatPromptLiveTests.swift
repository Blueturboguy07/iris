//
//  ChatPromptLiveTests.swift
//  leanring-buddyTests
//
//  A SIMULATED FRESH ENVIRONMENT for the chat prompt.
//
//  Three things were reported from a second Mac on 2026-08-27, and two of them
//  are prompt-shaped: the cursor "pointing at random stuff", and the model
//  "not aware of its own app" — walking the reader through installs by hand
//  instead of handing off to the button that would do it for them. Neither is
//  reachable by a unit test, because both are properties of what a real model
//  does with the real prompt.
//
//  So this drives the REAL prompt (`CompanionManager.companionResponseSystemPrompt`,
//  imported, never copied — a copy would let a test pass against a prompt the
//  app does not send) against a REAL model, over screens this file draws itself.
//  Drawing them is the point: every control sits at a rectangle known to the
//  test, so "did it point at the right thing" has a ground truth instead of a
//  human squinting at a screenshot.
//
//  Real, billed calls. Off unless asked for:
//
//      IRIS_CHAT_PROMPT_LIVE=1 TEST_RUNNER_IRIS_CHAT_PROMPT_LIVE=1 \
//      xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy \
//        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-check \
//        -parallel-testing-enabled NO \
//        -only-testing:leanring-buddyTests/ChatPromptLiveTests
//
//  Knobs: IRIS_CHAT_PROMPT_OUT (report directory), IRIS_CHAT_PROMPT_SAMPLES.
//

import Foundation
import AppKit
import Testing
@testable import Iris

nonisolated enum ChatPromptGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IRIS_CHAT_PROMPT_LIVE"] == "1"
    }
    static var samples: Int {
        guard let raw = ProcessInfo.processInfo.environment["IRIS_CHAT_PROMPT_SAMPLES"],
              let parsed = Int(raw), parsed > 0 else { return 1 }
        return parsed
    }
    static var outputDirectory: String {
        ProcessInfo.processInfo.environment["IRIS_CHAT_PROMPT_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("iris-chat-prompt")
    }
}

/// A drawn screen, plus where everything on it actually is.
nonisolated struct SimulatedScreen {
    let pngData: Data
    let width: Int
    let height: Int
    /// Label → the rectangle that label occupies, in image pixels with the
    /// origin at the TOP-LEFT, which is the space the prompt tells the model to
    /// answer in.
    let controls: [String: CGRect]

    func rect(named name: String) -> CGRect? { controls[name] }
}

nonisolated enum SimulatedScreenFactory {

    /// A reader partway through an install guide, with Iris's own "Let Iris run
    /// it" button on screen. This is the exact situation the report describes:
    /// the model should hand off to that button, and point at it.
    static func guideInProgress() -> SimulatedScreen {
        let width = 1440, height = 900
        var controls: [String: CGRect] = [:]

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // Desktop
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // A terminal window on the left.
        drawPanel(NSRect(x: 60, y: 180, width: 680, height: 560),
                  fill: NSColor(calibratedWhite: 0.06, alpha: 1))
        drawText("Terminal", at: NSPoint(x: 80, y: 700), size: 15, color: .white)
        drawText("$ ", at: NSPoint(x: 80, y: 660), size: 13, color: .green)

        // Iris's guide card, bottom right, with the button the reader is meant
        // to press. Coordinates are recorded TOP-LEFT origin for the model's space.
        let cardX = 860.0, cardBottomY = 120.0, cardW = 500.0, cardH = 260.0
        drawPanel(NSRect(x: cardX, y: cardBottomY, width: cardW, height: cardH),
                  fill: NSColor(calibratedWhite: 0.16, alpha: 1))
        drawText("Install Hickeyfield", at: NSPoint(x: cardX + 24, y: cardBottomY + cardH - 46),
                 size: 17, color: .white)
        drawText("Step 3 of 15 — install dependencies",
                 at: NSPoint(x: cardX + 24, y: cardBottomY + cardH - 78), size: 13,
                 color: NSColor(calibratedWhite: 0.7, alpha: 1))

        let buttonRect = NSRect(x: cardX + 24, y: cardBottomY + 36, width: cardW - 48, height: 44)
        drawPanel(buttonRect, fill: NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.95, alpha: 1))
        drawText("Let Iris run it", at: NSPoint(x: buttonRect.minX + 168, y: buttonRect.minY + 13),
                 size: 15, color: .white)
        image.unlockFocus()

        // Flip to top-left origin for the model's coordinate space.
        controls["let iris run it"] = CGRect(
            x: buttonRect.minX, y: CGFloat(height) - buttonRect.maxY,
            width: buttonRect.width, height: buttonRect.height
        )
        controls["terminal"] = CGRect(x: 60, y: CGFloat(height) - 740, width: 680, height: 560)

        return SimulatedScreen(
            pngData: pngData(from: image, width: width, height: height),
            width: width, height: height, controls: controls
        )
    }

    // MARK: drawing helpers

    private static func drawPanel(_ rect: NSRect, fill: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        fill.setFill()
        path.fill()
    }

    private static func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private static func pngData(from image: NSImage, width: Int, height: Int) -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return Data()
        }
        _ = (width, height)
        return png
    }
}

/// What the model said, reduced to the things this harness grades.
nonisolated struct GradedReply {
    let text: String

    /// The [POINT:x,y:label] tag, if the reply carried one.
    var pointCoordinate: CGPoint? {
        guard let range = text.range(of: #"\[POINT:\s*(\d+)\s*,\s*(\d+)"#, options: .regularExpression)
        else { return nil }
        let numbers = text[range].components(separatedBy: CharacterSet(charactersIn: ":,"))
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    var declinedToPoint: Bool { text.contains("[POINT:none]") }

    /// Whether the reply hands off to Iris's own install path rather than
    /// walking the reader through it by hand. The reported failure is the
    /// opposite: a wall of manual steps in an app whose whole purpose is to
    /// not need them.
    var namesTheIrisInstallPath: Bool {
        let lowered = text.lowercased()
        return lowered.contains("let iris run it") || lowered.contains("let iris run")
    }

    var namesTheIrisEditPath: Bool {
        let lowered = text.lowercased()
        return lowered.contains("fix a bug") || lowered.contains("add a feature")
    }
}

// Gated the way the other live suites are: ABSENT from an ordinary run, not
// red in it. `try #require(gate)` records an issue when the gate is off, which
// makes the default suite fail for a test that was never meant to run.
@Suite(
    .serialized,
    .enabled(if: ChatPromptGate.isEnabled, "set IRIS_CHAT_PROMPT_LIVE=1 to make real, billed model calls")
)
struct ChatPromptLiveTests {

    /// One real call with the real prompt over a drawn screen.
    @MainActor
    private func ask(_ question: String, screen: SimulatedScreen) async throws -> GradedReply {
        let accountService = AccountService()
        let api = ClaudeAPI(
            resolveTransport: {
                await accountService.currentAssistantTransport(
                    publikBaseURL: URL(string: "https://publikhq.com")!
                )
            }
        )
        let (text, _) = try await api.analyzeImageStreaming(
            images: [(
                data: screen.pngData,
                label: "primary focus — \(screen.width)x\(screen.height) pixels"
            )],
            systemPrompt: CompanionManager.companionResponseSystemPrompt,
            conversationHistory: [],
            userPrompt: question,
            onTextChunk: { _ in }
        )
        return GradedReply(text: text)
    }

    private func record(_ lines: [String]) {
        let directory = ChatPromptGate.outputDirectory
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let path = (directory as NSString).appendingPathComponent("chat-prompt-report.txt")
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        for line in lines { print(line) }
    }

    /// THE "not aware of its own app" REPORT. A reader mid-install asks how to
    /// finish. Iris has a button on screen that runs the whole thing. Walking
    /// them through it by hand is the failure — the reader is inside Iris
    /// precisely so they do not have to.
    @Test("mid-install, it hands off to Iris instead of dictating manual steps")
    @MainActor
    func itHandsOffToTheInstallButton() async throws {
        let screen = SimulatedScreenFactory.guideInProgress()
        var handoffs = 0, pointsOnTarget = 0
        var lines = ["=== hands off to Iris (mid-install) ==="]

        for sample in 1...ChatPromptGate.samples {
            let reply = try await ask(
                "how do i finish installing this? what do i type",
                screen: screen
            )
            if reply.namesTheIrisInstallPath { handoffs += 1 }
            let target = screen.rect(named: "let iris run it")!
            // Generous: anywhere in the button's row counts. The report is
            // "random stuff", not "a few pixels off".
            let forgiving = target.insetBy(dx: -40, dy: -40)
            if let point = reply.pointCoordinate, forgiving.contains(point) { pointsOnTarget += 1 }
            lines.append("  sample \(sample): handoff=\(reply.namesTheIrisInstallPath) "
                + "point=\(reply.pointCoordinate.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none") "
                + "target=\(Int(target.midX)),\(Int(target.midY))")
            lines.append("    " + reply.text.replacingOccurrences(of: "\n", with: " ").prefix(220))
        }
        lines.append("  handoff \(handoffs)/\(ChatPromptGate.samples)  "
            + "point-on-target \(pointsOnTarget)/\(ChatPromptGate.samples)")
        record(lines)

        #expect(handoffs >= 1, "never mentioned Iris's own install path")
        #expect(pointsOnTarget >= 1, "never pointed at the button that does the work")
    }

    /// THE "pointing at random stuff" REPORT, with a ground truth. The reader
    /// names the thing they want pointed at, so there is exactly one right
    /// answer and it is a rectangle this file drew.
    @Test("asked where a control is, the point lands on it")
    @MainActor
    func pointingLandsOnTheNamedControl() async throws {
        let screen = SimulatedScreenFactory.guideInProgress()
        let target = screen.rect(named: "let iris run it")!
        var onTarget = 0
        var lines = ["=== pointing accuracy (ground truth) ==="]

        for sample in 1...ChatPromptGate.samples {
            let reply = try await ask("where's the button to let iris do it for me?", screen: screen)
            let forgiving = target.insetBy(dx: -40, dy: -40)
            let hit = reply.pointCoordinate.map { forgiving.contains($0) } ?? false
            if hit { onTarget += 1 }
            lines.append("  sample \(sample): point="
                + (reply.pointCoordinate.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none")
                + " target=\(Int(target.minX))..\(Int(target.maxX)) x \(Int(target.minY))..\(Int(target.maxY))"
                + " hit=\(hit)")
        }
        lines.append("  on-target \(onTarget)/\(ChatPromptGate.samples)")
        record(lines)
        #expect(onTarget >= 1, "the cursor never landed on the control the reader named")
    }

    /// The other half: a question with nothing to do with the screen must NOT
    /// point. Pointing at something irrelevant is exactly what "pointing at
    /// random stuff" looks like from the reader's chair.
    @Test("a general question does not drag the cursor somewhere irrelevant")
    @MainActor
    func aGeneralQuestionDeclinesToPoint() async throws {
        let screen = SimulatedScreenFactory.guideInProgress()
        var declined = 0
        var lines = ["=== declines to point when pointing is noise ==="]
        for sample in 1...ChatPromptGate.samples {
            let reply = try await ask("what does the rust borrow checker actually do?", screen: screen)
            if reply.declinedToPoint || reply.pointCoordinate == nil { declined += 1 }
            lines.append("  sample \(sample): declined=\(reply.declinedToPoint) "
                + "point=\(reply.pointCoordinate.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none")")
        }
        lines.append("  declined \(declined)/\(ChatPromptGate.samples)")
        record(lines)
        #expect(declined >= 1, "pointed at the screen for a question that had nothing to do with it")
    }
}
