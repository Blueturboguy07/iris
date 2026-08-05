//
//  WatchVisualCheck.swift
//  leanring-buddy
//
//  The exact question the watch loop asks a model about a screenshot, and how
//  it reads the answer back.
//
//  This lives in its own file, importing nothing but Foundation, for one
//  reason: `iris-macos/tools/guide-rehearsal` compiles *this file* rather than
//  a copy of it. A rehearsal harness that asked a fair-sounding approximation
//  of this question would be testing a prompt the app does not send, and the
//  copy would rot silently the first time somebody improved the wording here.
//
//  If you change anything in this file, you are changing what every guide step
//  in every guide is judged against. The rehearsal harness is how you find out
//  whether that was an improvement.
//

import Foundation

/// What the loop concluded about a step from one frame.
///
/// Deliberately not an optional Bool: "the loop learned nothing" is a third
/// outcome and must not collapse into "not done", because one means wait and
/// the other means the model is not answering in the shape we asked for.
nonisolated enum WatchVerdict: Equatable, Sendable {
    case completed
    case notYet
    /// The reader looks stuck. This is what makes the loop adaptive rather than
    /// merely automatic: the hint is put in front of them straight away instead
    /// of Iris waiting silently for something that is not going to happen.
    case userStuck(hint: String)
}

/// What else was true about the screen when the frame was taken.
///
/// This exists because of two failures found by rehearsing cue's guide against
/// a real desktop, both of which came from the model being asked an ambiguous
/// question rather than from it answering badly:
///
/// - **Which window.** The reader had five terminal windows open, four of them
///   busy with unrelated work. Asked "in the terminal, has npm finished", the
///   model looked at a screen full of busy terminals and said no — correctly,
///   about the wrong window. The step never fired.
/// - **Which moment.** Asked "has git checkout succeeded", the model saw the
///   *previous* step's `git clone` sitting complete at a fresh prompt and said
///   yes. At the level the question was asked, a finished clone and a finished
///   checkout look identical, so the step fired before its command had run.
///
/// Iris already knows both answers — `frontmostApplicationName()`,
/// `frontmostWindowTitle()` and the step's own `command`. It simply never told
/// the model. Cropping the frame to the focused window would have fixed the
/// first failure and not the second, and would have thrown away the
/// surroundings that a `STUCK` verdict is read from.
nonisolated struct WatchScreenContext: Equatable, Sendable {
    /// The application in front, e.g. `Terminal`.
    var frontmostApplicationName: String?
    /// The focused window's title, e.g. `cue — -zsh — 80×24`. This is usually
    /// the single most distinguishing thing on a cluttered screen.
    var focusedWindowTitle: String?
    /// The command this step asked the reader to run, verbatim. A shell echoes
    /// what was typed, so this doubles as proof that *this* step ran rather
    /// than the one before it.
    var commandTheStepAsksFor: String?

    /// True when the image being sent has already been cut down to that window.
    ///
    /// This is the normal case and the one that works — see
    /// `WatchFrameAnnotation` for the numbers. When it is true the window does
    /// not need describing in words, because the model is looking at nothing
    /// else, and describing it anyway measurably hurts: every extra block of
    /// instruction pushed this model further towards saying no.
    var frameIsCroppedToThatWindow = false

    static let none = WatchScreenContext()

    var describesAWindow: Bool {
        frontmostApplicationName?.isEmpty == false || focusedWindowTitle?.isEmpty == false
    }
}

nonisolated enum WatchVisualCheck {

    /// The single line the model is asked for. `STUCK:` carries the hint.
    static let completedAnswer = "COMPLETED"
    static let notYetAnswer = "NOT_YET"
    static let stuckAnswerPrefix = "STUCK:"

    static func systemPrompt(hintsTheStepAuthorWrote: [String]) -> String {
        var systemPrompt = """
        You are helping somebody follow an install guide on their own computer. \
        You are shown one screenshot and asked whether the current step is done.

        Answer with exactly one line and nothing else:
        \(completedAnswer) — the step is visibly finished.
        \(notYetAnswer) — the step is not finished, and nothing looks wrong.
        \(stuckAnswerPrefix) <one short sentence> — the step is not finished AND \
        something on screen suggests they have gone off the rails: an error, a \
        dialog they did not expect, or the wrong window in front.

        Prefer \(notYetAnswer) when you are unsure. Saying a step is done when it \
        is not sends somebody on to a step that cannot work.

        The screenshot is usually one window from the reader's screen, and \
        sometimes their whole screen. If you can see more than one window, judge \
        only the one the question names: another window being busy, idle or full \
        of errors is not evidence about this step. A dialog or alert sitting on \
        top of the reader's work is the one thing worth looking away for, and is \
        worth a \(stuckAnswerPrefix) answer.

        When the question names a command, it is there to catch exactly one \
        mistake and nothing else. Guides run several commands in a row, so if \
        the window plainly shows a *different* command as the most recent thing \
        run, with its own output beneath it and no sign of the named one, this \
        step has not started — answer \(notYetAnswer).

        In every other case ignore the command and answer the question exactly \
        as it is asked. Terminals scroll, so a long install pushes its own \
        command off the top of the window; that is normal and means nothing. Do \
        not talk yourself out of evidence you can actually see.
        """
        if !hintsTheStepAuthorWrote.isEmpty {
            systemPrompt += "\n\nThe guide's author suggested these hints for somebody who is stuck:\n"
            for hint in hintsTheStepAuthorWrote {
                systemPrompt += "- \(hint)\n"
            }
        }
        return systemPrompt
    }

    static func userPrompt(
        stepTitle: String,
        visualPrompt: String,
        context: WatchScreenContext = .none
    ) -> String {
        var userPrompt = """
        The step is titled "\(stepTitle)".
        """

        // Described in words only when it could not be shown. Naming the window
        // *as well* as cropping to it is one instruction too many: measured
        // five samples at a time, either the window block or the command block
        // alone scored 5/5 on a frame of a finished install, and the two
        // together scored 0/5.
        if !context.frameIsCroppedToThatWindow, context.describesAWindow {
            userPrompt += "\n\nJudge this window and ignore every other window on the screen:"
            if let applicationName = context.frontmostApplicationName, !applicationName.isEmpty {
                userPrompt += "\n- Application: \(applicationName)"
            }
            if let windowTitle = context.focusedWindowTitle, !windowTitle.isEmpty {
                userPrompt += "\n- Window title: \(windowTitle)"
            }
        }

        if let command = context.commandTheStepAsksFor, !command.isEmpty {
            userPrompt += """


            This step asked the reader to run this command:
            \(command)

            If a different command is plainly the most recent thing run, this \
            step has not started. Otherwise answer the question as asked.
            """
        }

        userPrompt += "\n\nThe question to answer about the screenshot is: \(visualPrompt)"
        return userPrompt
    }

    /// Reads the one line back. Anything unrecognized is nil — "the loop learned
    /// nothing", which is very different from "the step is not done" and must
    /// not be collapsed into it.
    static func verdict(
        fromModelAnswer modelAnswer: String,
        hintsTheStepAuthorWrote: [String]
    ) -> WatchVerdict? {
        let firstLineOfTheAnswer = modelAnswer
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAnswer = firstLineOfTheAnswer.uppercased()

        if normalizedAnswer.hasPrefix(stuckAnswerPrefix) {
            let hintFromTheModel = firstLineOfTheAnswer
                .dropFirst(stuckAnswerPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !hintFromTheModel.isEmpty {
                return .userStuck(hint: hintFromTheModel)
            }
            // A stuck verdict with no hint is useless to the reader, so the
            // author's own first hint stands in rather than an empty banner.
            guard let authoredHint = hintsTheStepAuthorWrote.first else {
                return .notYet
            }
            return .userStuck(hint: authoredHint)
        }
        if normalizedAnswer.hasPrefix(completedAnswer) {
            return .completed
        }
        if normalizedAnswer.hasPrefix(notYetAnswer) || normalizedAnswer.hasPrefix("NOT YET") {
            return .notYet
        }
        return nil
    }
}
