//
//  GuidePointingTests.swift
//  leanring-buddyTests
//
//  Covers the ladder that decides where the eye goes during a guide step.
//
//  All of it is pure, so none of this needs a screen, an accessibility tree or
//  a model. What is being tested is the judgement: which source wins, when Iris
//  refuses to point at all, and that a refusal says the right thing.
//

import Foundation
import Testing
@testable import Iris

struct GuidePointingLadderTests {

    private func step(
        kind: IrisStepKind,
        command: String? = nil,
        point: IrisStepPointTarget? = nil,
        title: String = "Add your own AI key"
    ) -> IrisGuideStep {
        IrisGuideStep(
            id: "a-step",
            kind: kind,
            title: title,
            body: "Open Settings from the ••• button, pick a provider, paste the key.",
            command: command,
            point: point
        )
    }

    // MARK: Which source wins

    /// Somebody looked at this step and wrote down the answer. That beats
    /// anything worked out at runtime, including the shell shortcut below.
    @Test func anAuthoredTargetBeatsEverythingElse() throws {
        let target = try #require(
            GuidePointingLadder.target(
                for: step(
                    kind: .terminal,
                    command: "npm start",
                    point: IrisStepPointTarget(descriptor: "the ••• more button", inApp: "com.cue.overlay")
                ),
                shell: .terminal,
                modelFallbackIsAvailable: true
            )
        )
        #expect(target.descriptor == "the ••• more button")
        #expect(target.inApp == "com.cue.overlay")
        #expect(target.provenance == .authoredAndFound)
        #expect(target.isCertain)
    }

    /// The case that covers most steps in most guides, without authoring
    /// anything and without paying for a model call.
    @Test func aCommandStepAimsAtTheWindowTheCommandGoesInto() throws {
        let target = try #require(
            GuidePointingLadder.target(
                for: step(kind: .terminal, command: "git --version"),
                shell: .terminal,
                modelFallbackIsAvailable: true
            )
        )
        #expect(target.descriptor == "the Terminal window")
        #expect(target.inApp == "com.apple.Terminal")
        #expect(target.isWindow)
        #expect(target.provenance == .shellWindow)
        #expect(target.isCertain)
    }

    @Test func aPowershellBranchAimsAtPowershell() throws {
        let target = try #require(
            GuidePointingLadder.target(
                for: step(kind: .terminal, command: "node --version"),
                shell: .powershell,
                modelFallbackIsAvailable: true
            )
        )
        #expect(target.descriptor == "the PowerShell window")
        #expect(target.inApp == "com.microsoft.powershell")
    }

    /// The fallback the user asked for: no authoring, still points.
    @Test func aStepWithNothingAuthoredAsksTheModel() throws {
        let target = try #require(
            GuidePointingLadder.target(
                for: step(kind: .permission),
                shell: .terminal,
                modelFallbackIsAvailable: true
            )
        )
        #expect(target.provenance == .inferred)
        #expect(!target.isCertain, "an inferred point must not present itself as a fact")
    }

    @Test func nothingIsInferredWhenTheModelIsUnavailable() {
        #expect(
            GuidePointingLadder.target(
                for: step(kind: .permission),
                shell: .terminal,
                modelFallbackIsAvailable: false
            ) == nil
        )
    }

    /// An empty descriptor is an authoring mistake, not an instruction to point
    /// at nothing named.
    @Test func anEmptyAuthoredDescriptorFallsThroughRatherThanPointingNowhere() throws {
        let target = try #require(
            GuidePointingLadder.target(
                for: step(kind: .terminal, command: "npm ci", point: IrisStepPointTarget(descriptor: "   ")),
                shell: .terminal,
                modelFallbackIsAvailable: true
            )
        )
        #expect(target.provenance == .shellWindow)
    }

    // MARK: Which kinds are worth a model call

    @Test func onlyKindsThatAreAboutClickingSomethingAreInferred() {
        #expect(GuidePointingLadder.stepKindIsWorthInferring(.open))
        #expect(GuidePointingLadder.stepKindIsWorthInferring(.permission))
        #expect(GuidePointingLadder.stepKindIsWorthInferring(.web))
        #expect(GuidePointingLadder.stepKindIsWorthInferring(.paste))

        // `verify` asks the reader to look at output they are already reading,
        // and `check`/`terminal` are answered before the model is ever reached.
        #expect(!GuidePointingLadder.stepKindIsWorthInferring(.verify))
        #expect(!GuidePointingLadder.stepKindIsWorthInferring(.check))
        #expect(!GuidePointingLadder.stepKindIsWorthInferring(.terminal))
    }

    // MARK: When Iris refuses

    private var anyTarget: GuidePointTarget {
        GuidePointTarget(descriptor: "the Copy button", inApp: nil, isWindow: false, provenance: .authoredAndFound)
    }

    /// The promise that lets Iris walk somebody through creating a key it never
    /// sees. It comes before every other consideration, because a promise that
    /// yields to a convenience is not a promise.
    @Test func aSensitiveStepIsNeverPointedAtEvenWithAnAuthoredTarget() {
        let decision = GuidePointingLadder.decide(
            target: anyTarget,
            stepIsSensitive: true,
            irisMayLookAtTheScreen: true,
            frontmostBundleIdentifier: nil,
            frontmostAppName: nil
        )
        #expect(decision == .doNotPoint(.theStepIsSensitive))
        #expect(GuidePointRefusal.theStepIsSensitive.userFacingMessage == nil, "explaining this every time would be noise")
    }

    /// An arrow hovering over a window nobody can see is worse than no arrow.
    @Test func irisWillNotPointIntoAnAppThatIsNotInFront() {
        let decision = GuidePointingLadder.decide(
            target: GuidePointTarget(descriptor: "the ••• button", inApp: "com.cue.overlay", isWindow: false, provenance: .authoredAndFound),
            stepIsSensitive: false,
            irisMayLookAtTheScreen: true,
            frontmostBundleIdentifier: "com.apple.Safari",
            frontmostAppName: "Safari"
        )
        #expect(decision == .doNotPoint(.targetAppIsNotInFront(bundleId: "com.cue.overlay", appName: "Safari")))
    }

    @Test func tellsTheReaderWhichWayToGoRatherThanFailingSilently() {
        let refusal = GuidePointRefusal.targetAppIsNotInFront(bundleId: "com.apple.Terminal", appName: "Terminal")
        #expect(refusal.userFacingMessage == "Switch to Terminal and I'll show you where.")
    }

    /// The accessibility tree needs no screenshot, so an authored descriptor
    /// still resolves with capture switched off. Only the guess needs pixels.
    @Test func anAuthoredTargetStillWorksWithoutScreenRecording() {
        let decision = GuidePointingLadder.decide(
            target: anyTarget,
            stepIsSensitive: false,
            irisMayLookAtTheScreen: false,
            frontmostBundleIdentifier: nil,
            frontmostAppName: nil
        )
        #expect(decision == .pointAt(anyTarget))
    }

    @Test func aGuessNeedsPixelsAndSaysSoWhenItCannotHaveThem() {
        let inferred = GuidePointTarget(descriptor: "Add your own AI key", inApp: nil, isWindow: false, provenance: .inferred)
        let decision = GuidePointingLadder.decide(
            target: inferred,
            stepIsSensitive: false,
            irisMayLookAtTheScreen: false,
            frontmostBundleIdentifier: nil,
            frontmostAppName: nil
        )
        #expect(decision == .doNotPoint(.irisMayNotLookAtTheScreen))
        #expect(GuidePointRefusal.irisMayNotLookAtTheScreen.userFacingMessage?.contains("Screen Recording") == true)
    }

    /// "Open this link in your browser" is not improved by an arrow, and
    /// saying nothing is the correct output rather than an error.
    @Test func havingNothingToPointAtIsNormalAndSilent() {
        let decision = GuidePointingLadder.decide(
            target: nil,
            stepIsSensitive: false,
            irisMayLookAtTheScreen: true,
            frontmostBundleIdentifier: nil,
            frontmostAppName: nil
        )
        #expect(decision == .doNotPoint(.stepHasNothingToPointAt))
        #expect(GuidePointRefusal.stepHasNothingToPointAt.userFacingMessage == nil)
    }
}
