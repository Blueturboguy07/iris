//
//  WatchVisualCheckTests.swift
//  leanring-buddyTests
//
//  Pins the question the watch loop asks about a screenshot.
//
//  Nothing pinned it before, and that is most of why the two failures below
//  survived into ten shipped guides: the prompts were only ever exercised by
//  running a real install against a real screen, which nobody does in CI. These
//  tests cannot prove a model answers well — only a rehearsal can — but they can
//  prove the model is told the things it needs in order to have a chance, which
//  is exactly what was missing.
//
//  Both cases come from rehearsing cue's macOS guide on a real desktop. See
//  `docs/guide-rehearsal-spec.md`.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct WatchVisualCheckTests {

    // MARK: - Which window

    /// The failure: five terminal windows open, four busy with unrelated work.
    /// Asked "in the terminal, has npm finished", the model answered about a
    /// different terminal and the step never fired.
    @Test func theQuestionNamesTheWindowToJudge() {
        let prompt = WatchVisualCheck.userPrompt(
            stepTitle: "Install dependencies",
            visualPrompt: "has npm finished?",
            context: WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: "cue — -zsh — 80×24",
                commandTheStepAsksFor: nil
            )
        )

        #expect(prompt.contains("Terminal"))
        #expect(prompt.contains("cue — -zsh — 80×24"))
    }

    /// Words describe the window only when the picture could not show it.
    ///
    /// Naming it *as well* as cropping to it is one instruction too many. Five
    /// samples at a time against a real frame of a finished `npm ci`: the window
    /// block alone 5/5, the command block alone 5/5, both together 0/5.
    @Test func aCroppedFrameIsNotAlsoDescribedInWords() {
        let cropped = WatchVisualCheck.userPrompt(
            stepTitle: "Install dependencies",
            visualPrompt: "has npm finished?",
            context: WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: "cue — -zsh — 80×24",
                commandTheStepAsksFor: "npm ci",
                frameIsCroppedToThatWindow: true
            )
        )
        #expect(!cropped.contains("Application:"))
        #expect(!cropped.contains("Window title:"))
        // The command block is the one that survives, because it is what stops
        // a step firing on the previous step's output.
        #expect(cropped.contains("npm ci"))
    }

    @Test func anUncroppedFrameStillNamesTheWindow() {
        let uncropped = WatchVisualCheck.userPrompt(
            stepTitle: "Install dependencies",
            visualPrompt: "has npm finished?",
            context: WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: "cue — -zsh — 80×24",
                commandTheStepAsksFor: "npm ci",
                frameIsCroppedToThatWindow: false
            )
        )
        #expect(uncropped.contains("Terminal"))
        #expect(uncropped.contains("cue — -zsh — 80×24"))
    }

    /// The surroundings still have a job: a dialog sitting on top of the
    /// reader's work is what a `STUCK` verdict is read from. An instruction that
    /// said "ignore everything else" flatly would cost that.
    @Test func aStepWithNoWindowInformationStillAsksACleanQuestion() {
        let prompt = WatchVisualCheck.userPrompt(
            stepTitle: "Allow screen recording",
            visualPrompt: "is the checkbox ticked?",
            context: .none
        )
        #expect(prompt.contains("is the checkbox ticked?"))
        #expect(!prompt.contains("Judge this window"))
        #expect(!prompt.contains("Application:"))
    }

    @Test func theStuckRouteSurvivesCroppingToOneWindow() {
        // Cropping costs the rest of the desktop, so the instruction that earns
        // a STUCK verdict has to keep working on what is left — which it does,
        // because a dialog that interrupts somebody takes focus and lands
        // inside the crop.
        let systemPrompt = WatchVisualCheck.systemPrompt(hintsTheStepAuthorWrote: [])
        #expect(systemPrompt.contains(WatchVisualCheck.stuckAnswerPrefix))
        #expect(systemPrompt.lowercased().contains("dialog"))
    }

    @Test func blankWindowFactsAreTreatedAsAbsentRatherThanPrinted() {
        let prompt = WatchVisualCheck.userPrompt(
            stepTitle: "Build the app",
            visualPrompt: "has it finished?",
            context: WatchScreenContext(
                frontmostApplicationName: "",
                focusedWindowTitle: "",
                commandTheStepAsksFor: ""
            )
        )
        #expect(!prompt.contains("Application:"))
        #expect(!prompt.contains("Window title:"))
        #expect(!prompt.contains("run this command"))
    }

    // MARK: - Which moment

    /// The failure: asked "has git checkout succeeded", the model saw the
    /// previous step's finished `git clone` at a fresh prompt and said yes. The
    /// step fired before its own command had run.
    @Test func theQuestionCarriesTheCommandThisStepAsksFor() {
        let prompt = WatchVisualCheck.userPrompt(
            stepTitle: "Use the reviewed version",
            visualPrompt: "has git checkout succeeded?",
            context: WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: "cue — -zsh — 80×24",
                commandTheStepAsksFor: "git checkout 36fa2b41"
            )
        )
        #expect(prompt.contains("git checkout 36fa2b41"))
    }

    /// The command rule rejects *contradicting* evidence, not *absent* evidence.
    ///
    /// The first attempt at this said "unless you can see the command, answer
    /// NOT_YET", and replaying a real frame of a successful `npm ci` showed what
    /// that costs: a long install scrolls its own command off the top of an
    /// 80×24 window, so the rule guaranteed that every command with more output
    /// than fits could never be seen to finish. It traded a step that fires too
    /// early for a step that never fires.
    @Test func aCommandScrolledOutOfViewIsNotTreatedAsUnstarted() {
        let prompt = WatchVisualCheck.userPrompt(
            stepTitle: "Install dependencies",
            visualPrompt: "has npm finished?",
            context: WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: "cue — -zsh",
                commandTheStepAsksFor: "npm ci"
            )
        )
        #expect(prompt.contains("scrolled out of view"))
        #expect(!prompt.contains("this step has not started"))

        let systemPrompt = WatchVisualCheck.systemPrompt(hintsTheStepAuthorWrote: [])
        #expect(systemPrompt.contains("terminals scroll"))
    }

    @Test func outputBelongingToAnEarlierCommandIsRejected() {
        let systemPrompt = WatchVisualCheck.systemPrompt(hintsTheStepAuthorWrote: [])
        #expect(systemPrompt.contains("different"))
        #expect(systemPrompt.contains(WatchVisualCheck.notYetAnswer))
    }

    // MARK: - The answer contract is unchanged

    @Test func theAnswerShapeStillParsesExactlyAsBefore() {
        let hints = ["Check you are in the cue folder."]
        #expect(
            WatchVisualCheck.verdict(fromModelAnswer: "COMPLETED", hintsTheStepAuthorWrote: hints)
                == .completed
        )
        #expect(
            WatchVisualCheck.verdict(fromModelAnswer: "NOT_YET", hintsTheStepAuthorWrote: hints)
                == .notYet
        )
        #expect(
            WatchVisualCheck.verdict(
                fromModelAnswer: "STUCK: Terminal is showing a permission error.",
                hintsTheStepAuthorWrote: hints
            ) == .userStuck(hint: "Terminal is showing a permission error.")
        )
        // Unrecognized stays nil: "the loop learned nothing" must not collapse
        // into "the step is not done".
        #expect(
            WatchVisualCheck.verdict(fromModelAnswer: "I think so?", hintsTheStepAuthorWrote: hints)
                == nil
        )
    }

    @Test func theAuthorsHintsStillReachTheModel() {
        let systemPrompt = WatchVisualCheck.systemPrompt(
            hintsTheStepAuthorWrote: ["Make sure Terminal is the front window."]
        )
        #expect(systemPrompt.contains("Make sure Terminal is the front window."))
    }

    // MARK: - The context type itself

    @Test func aContextWithNothingInItDescribesNoWindow() {
        #expect(WatchScreenContext.none.describesAWindow == false)
        #expect(
            WatchScreenContext(
                frontmostApplicationName: nil,
                focusedWindowTitle: nil,
                commandTheStepAsksFor: "npm ci"
            ).describesAWindow == false
        )
        #expect(
            WatchScreenContext(
                frontmostApplicationName: "Terminal",
                focusedWindowTitle: nil,
                commandTheStepAsksFor: nil
            ).describesAWindow
        )
    }
}
