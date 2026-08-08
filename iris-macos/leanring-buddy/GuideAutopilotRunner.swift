//
//  GuideAutopilotRunner.swift
//  leanring-buddy
//
//  The state machine: execute a step's command → risk gate → outcome → on
//  failure the ladder (fix from the material → fix with web search →
//  surface to the reader) → retry → advance. It owns the budgets, the
//  transcript, and the published state, and it reaches the world only
//  through three injected collaborators, so the whole thing is testable
//  without a pty or a network.
//
//  Who advances a step is settled elsewhere and stated here for the reader:
//  for a command Iris executed, the exit code is the verdict and the runner
//  returns `.succeeded`; the WatchLoop is stood down for that step. Manual,
//  open, permission, and dev-server steps stay the WatchLoop's to advance.
//

import Combine
import Foundation

/// What running one step's command produced, for the controller to act on.
enum GuideAutopilotStepResult: Equatable {
    /// The command exited zero. The controller advances the guide.
    case succeeded
    /// A sensitive step, handed back to the reader's copy-by-hand card.
    case handedBackAsSensitive
    /// A dev-server step is now running in its own session; the WatchLoop
    /// owns completion from here.
    case longRunningStarted
    /// The reader skipped this step (declined a risky command, or the ladder
    /// asked them to do something).
    case skippedByReader
    /// The ladder is spent; the reader sees the diagnosis and the buttons.
    case surfacedToReader
    /// The session or the runner stopped.
    case stopped
}

/// Everything the runner needs to know about the guide, injected once so the
/// failure context and the host guard are always populated.
struct GuideAutopilotGuideContext {
    let slug: String
    let version: Int
    let appName: String
    let platformLabel: String
    /// Hosts named across every command in this branch — the closed set a
    /// proposed fix may reach.
    let hostsReachedByTheGuide: Set<String>
}

@MainActor
final class GuideAutopilotRunner: ObservableObject {

    // MARK: - Budgets (see docs/iris-assistant-protocol.md §8)

    /// Two fix attempts per step: rung (a) and rung (b). A third is rung (c),
    /// which surfaces rather than spends.
    static let maximumFixAttemptsPerStep = 2
    static let maximumFixAttemptsPerGuide = 6
    /// Latched. The funded tier is 20 requests / 300s and 150k tokens / day,
    /// shared with chat and the WatchLoop's up-to-8 visual calls per step —
    /// so a runaway ladder must not be able to drain the day on one install.
    static let maximumModelCallsPerGuide = 8

    // MARK: - Published state

    @Published private(set) var state: GuideAutopilotState = .notStarted
    @Published private(set) var transcript: [GuideAutopilotTranscriptEntry] = []

    // MARK: - Collaborators

    private let shellSession: GuideAutopilotShellSessionDriving
    private let longRunningSession: GuideAutopilotShellSessionDriving
    private let fixProposer: GuideAutopilotFixProposing
    private let guideContext: GuideAutopilotGuideContext

    // MARK: - Budget counters

    private var modelCallsUsedThisGuide = 0
    private var fixAttemptsUsedThisGuide = 0

    // MARK: - The pending-confirmation continuation

    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    init(
        shellSession: GuideAutopilotShellSessionDriving,
        longRunningSession: GuideAutopilotShellSessionDriving,
        fixProposer: GuideAutopilotFixProposing,
        guideContext: GuideAutopilotGuideContext
    ) {
        self.shellSession = shellSession
        self.longRunningSession = longRunningSession
        self.fixProposer = fixProposer
        self.guideContext = guideContext
        shellSession.onOutputLine = { [weak self] line in
            self?.transcript.append(.output(line: line))
        }
    }

    // MARK: - Session lifecycle

    func startSession() async -> Bool {
        await shellSession.start()
    }

    func endSession() async {
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
        await shellSession.endSession()
        await longRunningSession.endSession()
        state = .stopped
    }

    /// The scrubbed tail of the terminal, for grounding a chat answer during a
    /// guide — so "i'm stuck" is answered from what the command actually
    /// printed rather than from a screenshot the model reasons at.
    func currentTerminalTail() -> String {
        shellSession.tailForTheModel()
    }

    // MARK: - Running one step

    func executeStepCommand(
        step: IrisGuideStep,
        stepIndex: Int,
        totalSteps: Int
    ) async -> GuideAutopilotStepResult {
        guard let command = step.command else { return .succeeded }

        // A sensitive step is never typed into a shell — an API key would
        // land in scrollback and shell history. Hand it back.
        if step.watch?.sensitive == true {
            transcript.append(.explanation(
                text: "This step involves something private, so Iris won't type it — you take this one."
            ))
            return .handedBackAsSensitive
        }

        transcript.append(.stepHeading(
            stepTitle: step.title, stepNumber: stepIndex + 1, totalSteps: totalSteps
        ))
        state = .running(stepIndex: stepIndex)

        // Dev servers never return; run in the side session and let the
        // WatchLoop decide "done" from the step's watch block.
        if GuideAutopilotCommandShape.holdsTheShellOpen(command) {
            return await startLongRunning(command: command)
        }

        transcript.append(.commandFromTheGuide(text: command))
        let outcome = await runGuideCommand(command)
        switch outcome {
        case .succeeded:
            return .succeeded
        case .skippedByReader:
            return .skippedByReader
        case .stopped:
            return .stopped
        case .failed(let workingDirectory):
            return await runFailureLadder(
                step: step, command: command, workingDirectory: workingDirectory
            )
        }
    }

    // MARK: - Running a guide command through the gate

    private enum GuideCommandOutcome {
        case succeeded
        case failed(workingDirectory: String)
        case skippedByReader
        case stopped
    }

    private func runGuideCommand(_ command: String) async -> GuideCommandOutcome {
        switch GuideAutopilotRiskAssessment.assess(command) {
        case .runsWithoutAsking:
            guard let approved = GuideAutopilotRiskAssessment.approve(command) else {
                return .stopped
            }
            return await runApproved(approved)
        case .needsAConfirmTap(let reason):
            let approvedToRun = await askTheReaderToConfirm(
                command: command, reason: reason, isFromAFix: false
            )
            guard approvedToRun,
                  let approved = GuideAutopilotRiskAssessment.approveAfterAReaderTap(command) else {
                return .skippedByReader
            }
            return await runApproved(approved)
        case .refusedOutright(let reason):
            // A published guide command should never reach here; if one does,
            // the guide regressed past the web tests. Refuse and surface.
            transcript.append(.explanation(
                text: "Iris won't run this command automatically: \(reason.plainLanguageSummary)"
            ))
            return .skippedByReader
        }
    }

    private func runApproved(_ command: GuideAutopilotApprovedCommand) async -> GuideCommandOutcome {
        let startedAt = Date()
        let outcome = await shellSession.run(command, deadline: GuideAutopilotShellSession.defaultCommandDeadline)
        let duration = Date().timeIntervalSince(startedAt)
        switch outcome {
        case .succeeded(let workingDirectory):
            transcript.append(.exitStatus(code: 0, duration: duration))
            _ = workingDirectory
            return .succeeded
        case .failed(let exitStatus, let workingDirectory):
            transcript.append(.exitStatus(code: exitStatus, duration: duration))
            return .failed(workingDirectory: workingDirectory)
        case .cancelled:
            return .skippedByReader
        case .timedOut:
            transcript.append(.explanation(
                text: "That command took too long and Iris stopped it."
            ))
            return .failed(workingDirectory: shellSession.currentWorkingDirectory)
        case .seemsToBeAskingAQuestion(let tail):
            state = .awaitingReaderAtAPrompt(tail: tail)
            transcript.append(.explanation(
                text: "This command is asking you something — take a look at the terminal."
            ))
            return .skippedByReader
        case .sessionFailed:
            return .stopped
        }
    }

    // MARK: - The failure ladder

    private func runFailureLadder(
        step: IrisGuideStep,
        command: String,
        workingDirectory: String
    ) async -> GuideAutopilotStepResult {
        var priorAttempts: [String] = []

        for rung in 0..<Self.maximumFixAttemptsPerStep {
            guard fixAttemptsUsedThisGuide < Self.maximumFixAttemptsPerGuide,
                  modelCallsUsedThisGuide < Self.maximumModelCallsPerGuide else {
                return surfaceBudgetExhausted(command: command)
            }
            fixAttemptsUsedThisGuide += 1
            modelCallsUsedThisGuide += 1

            let context = failureContext(
                step: step, command: command,
                workingDirectory: workingDirectory, priorAttempts: priorAttempts
            )
            let useWebSearch = rung >= 1
            let fix: GuideAutopilotProposedFix?
            do {
                fix = useWebSearch
                    ? try await fixProposer.proposeFixWithWebSearch(for: context)
                    : try await fixProposer.proposeFix(for: context)
            } catch {
                // A transport failure is not a diagnosis; try the next rung
                // or surface, never fabricate.
                priorAttempts.append("a repair attempt could not reach the model")
                continue
            }

            guard let fix else {
                priorAttempts.append("the model had no fix to offer")
                continue
            }
            transcript.append(.explanation(text: fix.diagnosis))

            switch fix.action {
            case .cannotFixThis(let reason):
                priorAttempts.append("model could not fix it: \(reason)")
                continue

            case .askTheReaderToDoSomething(let instruction):
                transcript.append(.explanation(text: instruction))
                state = .surfacedToReader(diagnosis: fix.diagnosis, failingCommand: command)
                return .skippedByReader

            case .runACommand(let fixCommand, let whatItDoes):
                let applied = await applyFixCommand(
                    fixCommand, whatItDoes: whatItDoes,
                    attempt: rung + 1, searchedTheWeb: fix.cameFromWebSearch
                )
                switch applied {
                case .stopped:
                    return .stopped
                case .skippedByReader:
                    priorAttempts.append("reader declined the fix: \(fixCommand)")
                    continue
                case .ran(let fixSucceeded):
                    priorAttempts.append(
                        "\(fixCommand) → \(fixSucceeded ? "ran" : "also failed")"
                    )
                    guard fix.retryTheOriginalCommandAfterwards else { continue }
                    transcript.append(.commandFromTheGuide(text: command))
                    let retry = await runGuideCommand(command)
                    switch retry {
                    case .succeeded: return .succeeded
                    case .stopped: return .stopped
                    case .skippedByReader: return .skippedByReader
                    case .failed: continue   // next rung
                    }
                }
            }
        }
        return surface(diagnosis: transcript.lastExplanation, command: command)
    }

    private enum FixApplication {
        case ran(fixSucceeded: Bool)
        case skippedByReader
        case stopped
    }

    private func applyFixCommand(
        _ fixCommand: String,
        whatItDoes: String,
        attempt: Int,
        searchedTheWeb: Bool
    ) async -> FixApplication {
        transcript.append(.commandFromAFix(
            text: fixCommand, attempt: attempt,
            searchedTheWeb: searchedTheWeb, whatItDoes: whatItDoes
        ))
        switch GuideAutopilotRiskAssessment.assess(fixCommand) {
        case .runsWithoutAsking:
            guard let approved = GuideAutopilotRiskAssessment.approve(fixCommand) else {
                return .stopped
            }
            return .ran(fixSucceeded: await runFixApproved(approved))
        case .needsAConfirmTap(let reason):
            let approvedToRun = await askTheReaderToConfirm(
                command: fixCommand, reason: reason, isFromAFix: true
            )
            guard approvedToRun,
                  let approved = GuideAutopilotRiskAssessment.approveAfterAReaderTap(fixCommand) else {
                return .skippedByReader
            }
            return .ran(fixSucceeded: await runFixApproved(approved))
        case .refusedOutright(let reason):
            transcript.append(.explanation(
                text: "Iris won't run that repair automatically: \(reason.plainLanguageSummary)"
            ))
            return .skippedByReader
        }
    }

    private func runFixApproved(_ command: GuideAutopilotApprovedCommand) async -> Bool {
        let startedAt = Date()
        let outcome = await shellSession.run(command, deadline: GuideAutopilotShellSession.defaultCommandDeadline)
        let duration = Date().timeIntervalSince(startedAt)
        if case .succeeded = outcome {
            transcript.append(.exitStatus(code: 0, duration: duration))
            return true
        }
        if case .failed(let code, _) = outcome {
            transcript.append(.exitStatus(code: code, duration: duration))
        }
        // A fix's own failure does not consume a rung — it fails this rung
        // and the loop moves on.
        return false
    }

    // MARK: - Surfacing

    private func surface(diagnosis: String?, command: String) -> GuideAutopilotStepResult {
        let text = diagnosis ?? "Iris couldn't get this step working on its own."
        state = .surfacedToReader(diagnosis: text, failingCommand: command)
        return .surfacedToReader
    }

    private func surfaceBudgetExhausted(command: String) -> GuideAutopilotStepResult {
        let honest = "I've used up what I can spend on this install for now — here's the "
            + "command that failed, and you can take it from here."
        transcript.append(.explanation(text: honest))
        state = .surfacedToReader(diagnosis: honest, failingCommand: command)
        return .surfacedToReader
    }

    // MARK: - Dev servers

    private func startLongRunning(command: String) async -> GuideAutopilotStepResult {
        guard GuideAutopilotRiskAssessment.approve(command) != nil,
              let approved = GuideAutopilotRiskAssessment.approve(command) else {
            transcript.append(.explanation(
                text: "Iris won't start this one automatically — run it yourself when you're ready."
            ))
            return .skippedByReader
        }
        transcript.append(.commandFromTheGuide(text: command))
        if !(await longRunningSession.start()) {
            return .stopped
        }
        // Fire and don't await: a dev server never returns. If it dies within
        // ~10s that is a real failure, but v1 lets the WatchLoop and the
        // reader notice; the transcript shows it running.
        Task { [longRunningSession] in
            _ = await longRunningSession.run(approved, deadline: GuideAutopilotShellSession.defaultCommandDeadline)
        }
        transcript.append(.explanation(
            text: "\(guideContext.appName) is starting in Iris's terminal. Quitting Iris stops it."
        ))
        return .longRunningStarted
    }

    // MARK: - The confirm handshake

    private func askTheReaderToConfirm(
        command: String,
        reason: GuideAutopilotRiskReason,
        isFromAFix: Bool
    ) async -> Bool {
        let request = GuideAutopilotApprovalRequest(
            id: UUID().uuidString,
            commandText: command,
            reason: reason.plainLanguageSummary,
            trippingSubstring: reason.trippingSubstring,
            isFromAFix: isFromAFix
        )
        transcript.append(.awaitingConfirmation(request: request))
        state = .awaitingConfirmation(request)
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    /// The reader tapped Run it.
    func approvePendingCommand() {
        confirmationContinuation?.resume(returning: true)
        confirmationContinuation = nil
    }

    /// The reader tapped Skip, or dismissed the guide with a request pending.
    func skipPendingCommand() {
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
    }

    // MARK: - Failure context assembly

    private func failureContext(
        step: IrisGuideStep,
        command: String,
        workingDirectory: String,
        priorAttempts: [String]
    ) -> GuideAutopilotFailureContext {
        GuideAutopilotFailureContext(
            guideSlug: guideContext.slug,
            guideVersion: guideContext.version,
            appName: guideContext.appName,
            platformLabel: guideContext.platformLabel,
            stepIdentifier: step.id,
            stepTitle: step.title,
            stepBody: step.body,
            verifierLabel: step.verifierLabel,
            commandAsRun: command,
            exitStatus: 1,
            scrubbedOutputTail: shellSession.tailForTheModel(),
            shellPath: GuideAutopilotShellSession.loginShellPath(),
            workingDirectory: workingDirectory,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.machineArchitecture(),
            knownToolVersions: [],
            priorAttempts: priorAttempts,
            hostsTheGuideAlreadyReaches: guideContext.hostsReachedByTheGuide
        )
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}

private extension Array where Element == GuideAutopilotTranscriptEntry {
    /// The most recent explanation, for the surface message when the ladder
    /// runs out.
    var lastExplanation: String? {
        for entry in reversed() {
            if case .explanation(let text) = entry { return text }
        }
        return nil
    }
}
