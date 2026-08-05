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
        """
        if !hintsTheStepAuthorWrote.isEmpty {
            systemPrompt += "\n\nThe guide's author suggested these hints for somebody who is stuck:\n"
            for hint in hintsTheStepAuthorWrote {
                systemPrompt += "- \(hint)\n"
            }
        }
        return systemPrompt
    }

    static func userPrompt(stepTitle: String, visualPrompt: String) -> String {
        """
        The step is titled "\(stepTitle)".
        The question to answer about the screenshot is: \(visualPrompt)
        """
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
