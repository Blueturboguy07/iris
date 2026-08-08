//
//  GuideAutopilotTranscript.swift
//  leanring-buddy
//
//  What the terminal view renders, as pure values. The view at the bottom is
//  the only thing that is not — everything the runner produces is data,
//  which is what lets the runner be tested without a UI.
//
//  Three signals distinguish a fix from a guide command at a glance — rule
//  colour, a label row, and an indent — because on a small translucent card
//  one signal is not enough.
//

import Foundation

/// One row in the transcript. Ordering is append order.
enum GuideAutopilotTranscriptEntry: Equatable, Identifiable {
    case stepHeading(stepTitle: String, stepNumber: Int, totalSteps: Int)
    case commandFromTheGuide(text: String)
    case commandFromAFix(text: String, attempt: Int, searchedTheWeb: Bool, whatItDoes: String)
    case output(line: String)
    case exitStatus(code: Int32, duration: TimeInterval)
    /// A risky command is waiting for the reader's tap.
    case awaitingConfirmation(request: GuideAutopilotApprovalRequest)
    /// Iris talking to the reader, in prose — not mono, so it reads as Iris
    /// and not as the machine.
    case explanation(text: String)

    var id: String {
        switch self {
        case .stepHeading(let title, let number, _): return "heading-\(number)-\(title)"
        case .commandFromTheGuide(let text): return "guidecmd-\(text.hashValue)"
        case .commandFromAFix(let text, let attempt, _, _): return "fixcmd-\(attempt)-\(text.hashValue)"
        case .output(let line): return "out-\(line.hashValue)-\(UUID().uuidString)"
        case .exitStatus(let code, let duration): return "exit-\(code)-\(duration)"
        case .awaitingConfirmation(let request): return "confirm-\(request.id)"
        case .explanation(let text): return "explain-\(text.hashValue)"
        }
    }
}

/// A risky command the reader must approve before it runs. Immutable; the
/// runner holds the continuation that a tap or a skip resolves.
struct GuideAutopilotApprovalRequest: Equatable, Identifiable {
    let id: String
    let commandText: String
    /// One plain sentence: what makes this need a tap.
    let reason: String
    /// The exact substring that tripped the gate, for highlighting.
    let trippingSubstring: String
    /// True when this is an off-script fix rather than a guide command.
    let isFromAFix: Bool
}

/// The whole autopilot state the UI observes.
enum GuideAutopilotState: Equatable {
    case notStarted
    /// Executing the step at this index (0-based within the branch).
    case running(stepIndex: Int)
    /// A risky command is waiting for a tap.
    case awaitingConfirmation(GuideAutopilotApprovalRequest)
    /// A command is asking an interactive question the reader must handle.
    case awaitingReaderAtAPrompt(tail: String)
    /// The whole guide's terminal steps are done.
    case finishedAllSteps
    /// Iris gave up on the current step and handed it to the reader.
    case surfacedToReader(diagnosis: String, failingCommand: String)
    /// The runner stopped (guide closed, session died).
    case stopped
}
