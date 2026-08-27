//
//  GuideActualPositionFinderTests.swift
//  leanring-buddyTests
//
//  The reported failure, in the reader's words: "It starts me at like step 11
//  when I type it into the Iris settings." Step 11 of the whimprflow guide
//  copies a bundle that step 10 builds. Resuming there on a machine that never
//  ran step 10 fails with exit 1, twice, and explains nothing.
//

import Foundation
import Testing
@testable import Iris

@Suite struct GuideActualPositionFinderTests {

    // MARK: - Reading the verdict

    @Test("a well-formed verdict is read")
    func aWellFormedVerdictIsRead() {
        let verdict = GuideActualPositionFinder.verdict(
            fromReply: "STEP: 10\nWHY: the built bundle is not on disk",
            numberOfSteps: 16
        )
        #expect(verdict?.stepIndex == 10)
        #expect(verdict?.reason == "the built bundle is not on disk")
    }

    /// "I cannot tell" has to be a real answer. A model forced to pick a number
    /// it does not believe sends the reader to a step that cannot work, which is
    /// strictly worse than leaving them where they already were.
    @Test("unknown is an answer, not a parse failure to route around")
    func unknownLeavesThePositionAlone() {
        #expect(GuideActualPositionFinder.verdict(
            fromReply: "STEP: unknown\nWHY: nothing on this machine settles it",
            numberOfSteps: 16
        ) == nil)
    }

    /// A number outside the guide is not a position. Clamping it to the nearest
    /// valid step would turn a model's confusion into a confident wrong move.
    @Test("an out-of-range step is refused rather than clamped")
    func anOutOfRangeStepIsRefused() {
        #expect(GuideActualPositionFinder.verdict(fromReply: "STEP: 99", numberOfSteps: 16) == nil)
        #expect(GuideActualPositionFinder.verdict(fromReply: "STEP: -1", numberOfSteps: 16) == nil)
        #expect(GuideActualPositionFinder.verdict(fromReply: "STEP: 3", numberOfSteps: 0) == nil)
    }

    @Test("prose instead of the format is refused")
    func proseIsRefused() {
        #expect(GuideActualPositionFinder.verdict(
            fromReply: "I think you should probably go back to step 10 or so.",
            numberOfSteps: 16
        ) == nil)
    }

    // MARK: - Which way it is allowed to move somebody

    /// Backward is the entire point: it is what stops a resume at `install-app`
    /// on a machine with no built bundle. Forward is a different risk — it skips
    /// steps nobody watched happen — so it is refused.
    @Test("it may move a reader back, never forward")
    func itOnlyEverMovesBackward() {
        #expect(GuideActualPositionFinder.shouldMove(from: 11, to: 10))
        #expect(GuideActualPositionFinder.shouldMove(from: 11, to: 0))
        #expect(!GuideActualPositionFinder.shouldMove(from: 11, to: 12))
        #expect(!GuideActualPositionFinder.shouldMove(from: 11, to: 11))
    }

    // MARK: - The evidence it reads

    /// The whimprflow case exactly: `install-app` consumes a path that
    /// `package` produces, and whether that path exists is the fact that
    /// decides the resume point.
    @Test("a repo-relative build output is picked out of a command")
    func aBuildOutputPathIsFound() {
        let paths = GuideActualPositionFinder.repositoryRelativePathsReferenced(
            byCommand: "ditto target/release/bundle/macos/WhimprFlow.app /Applications/WhimprFlow.app"
        )
        #expect(paths.contains("target/release/bundle/macos/WhimprFlow.app"))
        // An absolute destination is not a repo-relative fact.
        #expect(!paths.contains("/Applications/WhimprFlow.app"))
    }

    /// Guessing widely would produce facts that are WRONG rather than merely
    /// absent, and a confident wrong fact is worse input than no fact.
    @Test("anything a shell would expand is left alone")
    func shellShapesAreNotTreatedAsPaths() {
        for command in [
            "echo $HOME/thing",
            "ls foo/* | grep bar",
            "curl https://example.com/x",
            "cd ~/Projects/app",
            "run --flag=a/b",
        ] {
            let paths = GuideActualPositionFinder.repositoryRelativePathsReferenced(byCommand: command)
            #expect(paths.isEmpty, "\(command) yielded \(paths)")
        }
    }

    @Test("a commandless step contributes nothing")
    func aCommandlessStepIsSilent() {
        #expect(GuideActualPositionFinder.repositoryRelativePathsReferenced(byCommand: nil).isEmpty)
        #expect(GuideActualPositionFinder.repositoryRelativePathsReferenced(byCommand: "").isEmpty)
    }

    // MARK: - Not asking when there is nothing to ask about

    /// A branch where nothing could be checked would be asking the model to
    /// guess, and a guessed resume is worse than the remembered one.
    @Test("evidence that answers nothing is not worth a model call")
    func nothingCheckableIsNotWorthAsking() {
        let nothing = GuidePositionEvidence(facts: [
            GuidePositionFact(question: "does `cargo` respond", answer: GuidePositionEvidence.couldNotCheck),
        ])
        #expect(!nothing.isWorthInterpreting)

        let something = GuidePositionEvidence(facts: [
            GuidePositionFact(question: "does `cargo` respond", answer: GuidePositionEvidence.couldNotCheck),
            GuidePositionFact(question: "does the checkout exist", answer: GuidePositionEvidence.absent),
        ])
        #expect(something.isWorthInterpreting)
    }

    /// The condition that keeps this affordable. This check exists to move a
    /// reader BACK, so a machine where everything is present has nothing it
    /// could usefully say — and paying for a model call to be told "you are
    /// exactly where you thought" on every single guide open is a cost that
    /// scales with how often people resume, for no answer.
    @Test("a machine with nothing missing is never worth asking about")
    func everythingPresentIsNotWorthAsking() {
        let allPresent = GuidePositionEvidence(facts: [
            GuidePositionFact(question: "does `git` respond", answer: "yes (2.51.0)"),
            GuidePositionFact(question: "does the checkout exist", answer: "yes"),
            GuidePositionFact(question: "is the finished app installed", answer: "yes"),
        ])
        #expect(!allPresent.isWorthInterpreting)
    }

    // MARK: - The prompt

    @Test("the prompt carries the steps and the facts")
    func thePromptCarriesBothHalves() {
        let text = GuideActualPositionFinder.promptText(
            guideName: "WhimprFlow",
            steps: [
                (index: 10, id: "package", title: "Build the app", command: "pnpm tauri build"),
                (index: 11, id: "install-app", title: "Put it in Applications",
                 command: "ditto target/release/bundle/macos/WhimprFlow.app /Applications/WhimprFlow.app"),
            ],
            evidence: GuidePositionEvidence(facts: [
                GuidePositionFact(
                    question: "does target/release/bundle/macos/WhimprFlow.app exist in the checkout",
                    answer: "no"
                ),
            ])
        )
        #expect(text.contains("10. [package]"))
        #expect(text.contains("11. [install-app]"))
        #expect(text.contains("runs: pnpm tauri build"))
        #expect(text.contains("does target/release/bundle/macos/WhimprFlow.app exist in the checkout: no"))
    }

    /// A long guide must not blow the context; the head is what a resume check
    /// is about, and the truncation is stated rather than silent.
    @Test("a very long guide is truncated, and says so")
    func aLongGuideIsTruncatedVisibly() {
        let manySteps = (0..<80).map {
            (index: $0, id: "step\($0)", title: "Step \($0)", command: String?.none)
        }
        let text = GuideActualPositionFinder.promptText(
            guideName: "Long", steps: manySteps,
            evidence: GuidePositionEvidence(facts: [
                GuidePositionFact(question: "does git respond", answer: "yes"),
            ])
        )
        #expect(text.contains("more steps not listed"))
        #expect(!text.contains("[step79]"))
    }
}
