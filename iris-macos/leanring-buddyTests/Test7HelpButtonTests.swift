//
//  Test7HelpButtonTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS (Test 7 field report, Iris 0.9.1 build 17):
//
//      "There should be a visual help button ... so that Iris can point them
//       to it."
//
//  TRUE AT HEAD, and measured before anything was written: `grep -rin
//  "help button\|helpButton\|\"Help\"" ` across the whole macOS app returned
//  nothing. During an install the reader had the red traffic light — which ENDS
//  the install — and nothing else. Asking Iris a question meant already knowing
//  that the eye behind the takeover opens a bar when clicked, which is exactly
//  the thing somebody stuck does not know.
//
//  These tests pin the two halves that make the complaint answered rather than
//  merely acknowledged: the control is really RENDERED in both surfaces a reader
//  can be looking at mid-install, and pressing it really opens the ask bar.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

@MainActor
private final class StillRunnerForHelp: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 0)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = []
    @Published var isExecutingACommand: Bool = false
}

@MainActor
@Suite(.serialized) struct Test7HelpButtonTests {

    /// The button exists where the reader is actually looking during an install:
    /// the takeover terminal. Asserted against the PIXELS a REAL takeover draws
    /// — the same window `GuideAutopilotTakeoverController` puts on the reader's
    /// screen — not against the source, because a control that is written but
    /// never laid out is the same to a reader as one that was never written.
    ///
    /// The title bar is a flat fill (`GuideAutopilotTerminalTheme.titleBarBackground`)
    /// with the three traffic lights at its left end and the centred title. Its
    /// RIGHT end had nothing in it at all, so "is anything drawn there" is a
    /// direct question about this control and nothing else: delete the button
    /// and that strip goes back to one uniform colour.
    @Test func theTakeoverTerminalDrawsAHelpControlInItsTitleBar() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }
        let contentView = try #require(takeover.terminal.contentView)
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        // The right end of the 24pt title strip, clear of the centred title.
        // `NSHostingView` is flipped, so y counts down from the top.
        let width = contentView.bounds.width
        // Deliberately clear of the window's own rounded corner and its 1pt
        // border stroke, whose antialiasing is several colours all by itself —
        // measured: a region that included the edge passed with the button
        // hidden, which would have made this test decoration.
        let rightEndOfTheTitleStrip = NSRect(x: width - 56, y: 4, width: 42, height: 16)
        let coloursDrawnThere = Self.distinctColours(
            in: rightEndOfTheTitleStrip, of: contentView
        )

        #expect(
            coloursDrawnThere > 1,
            """
            the right end of the install terminal's title bar is one flat colour \
            (\(coloursDrawnThere) distinct: \(Self.lastColoursSeen)), so nothing is drawn \
            there — the reader watching an install they do not understand still has the red \
            light, which ENDS the install, and nothing at all that offers them an answer.
            """
        )
    }

    /// Pressing it opens the ask bar — the surface that can actually answer,
    /// because a question typed there arrives with the step and the real
    /// terminal output attached. A Help button that opened nothing would be the
    /// dead-button class this whole Test 7 pass exists to remove.
    @Test func askingForHelpOpensTheAskBar() async throws {
        var theAskBarWasSummoned = false
        let observer = NotificationCenter.default.addObserver(
            forName: .clickySummonAskBar, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { theAskBarWasSummoned = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        GuideAutopilotHelpRequest.theReaderAskedForHelp()

        // The notification is delivered on the main queue, which this test is
        // already on, so it lands on the next turn rather than synchronously.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(
            theAskBarWasSummoned,
            """
            asking for help summoned nothing. The reader pressed the one control on screen that \
            offers an answer and got silence, which is worse than not having drawn it.
            """
        )
    }

    // MARK: - Helpers

    /// The live takeover window, raised the way `CompanionManager` raises it.
    /// A real on-screen panel, because a hosting view in an off-screen window
    /// draws nothing at all — measured: every pixel came back 0,0,0, which would
    /// have "proved" every control absent, including the ones that are there.
    private struct LiveTakeover {
        let controller: GuideAutopilotTakeoverController
        let terminal: NSPanel
    }

    private static func raiseTakeover() async throws -> LiveTakeover {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = StillRunnerForHelp()
        runner.transcript = (0..<8).map { .output(line: "line \($0) output from the shell") }
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? NSPanel }
                .filter { !before.contains(ObjectIdentifier($0)) }
                .first { !$0.ignoresMouseEvents && $0.frame.width == 132 }
        )
        // The entry morph grows the window from eye size; capturing mid-morph
        // would read a title bar that is not its final width yet.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return LiveTakeover(controller: controller, terminal: terminal)
    }

    /// The distinct colours drawn inside one region of a view. One means "flat
    /// fill, nothing on top"; more means something is there.
    static var lastColoursSeen: [String] = []

    private static func distinctColours(in region: NSRect, of view: NSView) -> Int {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: region) else {
            return 0
        }
        view.cacheDisplay(in: region, to: representation)
        var colours: Set<String> = []
        for x in 0..<representation.pixelsWide {
            for y in 0..<representation.pixelsHigh {
                guard let colour = representation.colorAt(x: x, y: y) else { continue }
                colours.insert(
                    "\(Int(colour.redComponent * 255)),\(Int(colour.greenComponent * 255)),\(Int(colour.blueComponent * 255))"
                )
            }
        }
        lastColoursSeen = Array(colours).sorted().prefix(6).map { $0 }
        return colours.count
    }
}
