//
//  GuideActualPositionFinder.swift
//  leanring-buddy
//
//  WHERE IS THE READER ACTUALLY UP TO?
//
//  Saved progress records where somebody LEFT OFF, which is not the same thing
//  as where they are. Reported from the field, all one bug wearing three coats:
//
//    - "It starts me at like step 11 when I type it into the Iris settings."
//      Step 11 of the whimprflow guide is `install-app`, which copies a bundle
//      that step 10 builds. Resuming there on a machine that never ran step 10
//      fails with exit 1, twice, and the reader is told nothing useful.
//    - "I can only click back till step 5." Nothing stops at step 5; the reader
//      is PUSHED there. Steps 1-4 watch for git, node, pnpm and cargo, which
//      are all present by then, so each satisfies instantly and advances again.
//      Step 5 is the first with no watch block. (Fixed separately, by the
//      deliberate-back latch in `GuideSessionController`.)
//    - "It won't install homebrew if it is not already installed." A guide step
//      that runs `brew install gh` assumes a Homebrew that nothing installs.
//
//  The common mistake is that the guide asserts a state instead of checking it.
//  The founder's instruction was direct: "when iris runs it it should just check
//  where it is in the process, it can use an agent to do that."
//
//  So that is the split here, and it is deliberate: IRIS GATHERS FACTS, THE
//  MODEL INTERPRETS THEM. Everything a machine can answer for itself — does
//  this tool respond, does this clone exist, is this file on disk, is the app
//  installed — is gathered locally, cheaply, with no model in the loop. Then ONE
//  call asks the model to say which step those facts put the reader on, because
//  reading "the clone exists but the build output does not" against a list of
//  steps is judgement, and judgement is the part a model is actually good at.
//
//  Bounded on purpose: one model call, never a loop, and the whole thing is
//  advisory. A finder that fails, times out, or answers nonsense leaves saved
//  progress exactly as it was — a reader whose resume is merely imperfect must
//  never be worse off because the check itself broke.
//

import Foundation

// MARK: - What a machine can answer for itself

/// One fact about this machine, in the form the model reads it.
///
/// Deliberately flat strings rather than a rich type: this is evidence to be
/// interpreted, not a schema to be computed against, and every one of these
/// lines has to be legible to a person reading the log when the verdict is
/// surprising.
nonisolated struct GuidePositionFact: Equatable, Sendable {
    /// What was checked, in plain words ("cargo responds", "the clone exists").
    let question: String
    /// What this machine said. Never a guess — a check that could not run says
    /// so, because "unknown" and "no" lead to different steps.
    let answer: String
}

/// Everything gathered about one guide branch before the model is asked.
nonisolated struct GuidePositionEvidence: Equatable, Sendable {
    let facts: [GuidePositionFact]

    /// Whether these facts are worth a model call at all.
    ///
    /// Two conditions, and the second one is what keeps this cheap. Something
    /// must have been checkable — asking a model to interpret a page of "could
    /// not check" is asking it to guess, and a guessed resume is worse than the
    /// remembered one. And something must be MISSING: this check exists to move
    /// a reader BACK, so on a machine where every prerequisite, checkout and
    /// artifact is present there is nothing it could usefully say, and the
    /// remembered position stands without spending anything.
    ///
    /// That second condition is what makes this affordable on every guide open
    /// rather than a cost that scales with how often people resume.
    var isWorthInterpreting: Bool {
        let somethingWasCheckable = facts.contains { $0.answer != Self.couldNotCheck }
        let somethingIsMissing = facts.contains { $0.answer == Self.absent }
        return somethingWasCheckable && somethingIsMissing
    }

    static let couldNotCheck = "could not check"
    /// The exact word used for "this is not on the machine", so the
    /// worth-asking test can recognise it rather than string-matching prose.
    static let absent = "no"
}

// MARK: - The prompt and the answer

nonisolated enum GuideActualPositionFinder {

    /// The most steps ever described to the model. A guide longer than this has
    /// its list truncated rather than blowing the context — the early steps are
    /// what a resume check is about, so the head is what is kept.
    static let maximumStepsDescribed = 40

    /// The system prompt. Short on purpose: this is one judgement, not a task.
    static let systemPrompt = """
    You are told the steps of a software install guide and a list of facts about \
    the machine it is being installed on. Decide which step the person should \
    resume at.

    The right answer is the FIRST step whose work has not been done yet. A step \
    whose effect is already present on the machine is finished, however long ago \
    it happened. A step whose effect is missing is not finished, even if the \
    person got past it before — an earlier attempt may have failed, or the \
    machine may have been cleaned since.

    Be especially careful with steps that CONSUME what an earlier step \
    produces: if a step copies or installs a built artifact and that artifact is \
    not on disk, the step that builds it is not done, and the resume point is \
    the build, not the copy.

    Reply with exactly two lines and nothing else:
    STEP: <zero-based index>
    WHY: <one short sentence naming the fact that decided it>

    If the facts do not settle it, reply STEP: unknown and say why. Guessing is \
    worse than saying you cannot tell — an unknown leaves the person where they \
    already were, which is merely imperfect, while a wrong number sends them to \
    a step that cannot work.
    """

    /// The user message: the steps, then the facts.
    static func promptText(
        guideName: String,
        steps: [(index: Int, id: String, title: String, command: String?)],
        evidence: GuidePositionEvidence
    ) -> String {
        var lines: [String] = ["Guide: \(guideName)", "", "Steps:"]
        for step in steps.prefix(maximumStepsDescribed) {
            var line = "\(step.index). [\(step.id)] \(step.title)"
            if let command = step.command, !command.isEmpty {
                // One line only. A multi-line command's shape matters less here
                // than the list staying readable.
                let firstLine = command.components(separatedBy: .newlines).first ?? command
                line += "\n    runs: \(firstLine)"
            }
            lines.append(line)
        }
        if steps.count > maximumStepsDescribed {
            lines.append("… (\(steps.count - maximumStepsDescribed) more steps not listed)")
        }
        lines.append("")
        lines.append("Facts about this machine:")
        for fact in evidence.facts {
            lines.append("- \(fact.question): \(fact.answer)")
        }
        return lines.joined(separator: "\n")
    }

    /// What the model decided, if it decided anything.
    nonisolated struct Verdict: Equatable, Sendable {
        let stepIndex: Int
        let reason: String
    }

    /// Parse the two-line reply. Anything unexpected is nil, never a salvaged
    /// number — a resume position recovered from a malformed reply is exactly
    /// the kind of confident wrongness this whole file exists to remove.
    static func verdict(fromReply reply: String, numberOfSteps: Int) -> Verdict? {
        guard numberOfSteps > 0 else { return nil }
        var parsedIndex: Int?
        var parsedReason = ""
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("STEP:") {
                let value = trimmed.dropFirst("STEP:".count).trimmingCharacters(in: .whitespaces)
                if value.lowercased() == "unknown" { return nil }
                parsedIndex = Int(value)
            } else if trimmed.hasPrefix("WHY:") {
                parsedReason = trimmed.dropFirst("WHY:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let parsedIndex, parsedIndex >= 0, parsedIndex < numberOfSteps else {
            return nil
        }
        return Verdict(stepIndex: parsedIndex, reason: parsedReason)
    }

    /// Paths inside the checkout that a command reads or copies — the build
    /// outputs whose presence says whether an earlier step really ran.
    ///
    /// Deliberately narrow: a repo-relative path with a directory separator and
    /// no shell metacharacters. Guessing widely here would produce facts that
    /// are wrong rather than merely absent, and a confident wrong fact is worse
    /// input to the model than no fact at all.
    static func repositoryRelativePathsReferenced(byCommand command: String?) -> [String] {
        guard let command, !command.isEmpty else { return [] }
        var found: [String] = []
        for token in command.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard candidate.contains("/"),
                  !candidate.hasPrefix("/"),
                  !candidate.hasPrefix("-"),
                  !candidate.hasPrefix("~"),
                  !candidate.contains("://"),
                  candidate.rangeOfCharacter(from: CharacterSet(charactersIn: "$*?|&;<>()")) == nil,
                  !found.contains(candidate) else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Whether a proposed position is worth acting on, given where the reader
    /// was already going to land.
    ///
    /// Moving the reader BACKWARD is the point: it is what stops a resume at
    /// `install-app` on a machine with no built bundle. Moving them FORWARD on
    /// a model's say-so is a different and worse risk — it skips steps nobody
    /// watched happen — so it is refused, and the remembered position stands.
    static func shouldMove(from rememberedIndex: Int, to proposedIndex: Int) -> Bool {
        proposedIndex < rememberedIndex
    }
}
