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

/// How long a fast command must stay visibly "running" before its result line
/// appears, so a command that finishes in a few milliseconds still reads as
/// work Iris did rather than a flash on screen. The shell is never slowed — the
/// command has already finished; only the moment the exit line is shown is held.
/// A slow command (an `npm ci`) already runs far longer than this, so nothing is
/// ever added to a real install; only the trivially fast commands get a floor.
struct GuideAutopilotPacing: Equatable {
    let minimumVisibleCommandDuration: TimeInterval

    /// The shipped feel: every command is on screen for at least this long, so
    /// a complex install reads as a sequence of deliberate steps rather than a
    /// flicker. Tuned up from 0.7s so a fast command still lands as visible work
    /// — the reader asked for the install to feel like it is actually doing
    /// something. The real shell is never slowed; this only holds the *display*
    /// of a command that already finished faster than the floor.
    static let humanPaced = GuideAutopilotPacing(minimumVisibleCommandDuration: 1.2)
    /// Tests and rehearsals run with no artificial hold, so a fake shell that
    /// returns instantly keeps the suite fast and deterministic.
    static let instant = GuideAutopilotPacing(minimumVisibleCommandDuration: 0)

    /// How much longer to hold the "running" state, given how long the command
    /// actually took. Zero once the real duration already meets the floor.
    func remainingHold(afterElapsed elapsed: TimeInterval) -> TimeInterval {
        max(0, minimumVisibleCommandDuration - elapsed)
    }
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

// The conformance to `AutopilotTerminalPresenting` (declared in
// OnDemandEditRunner.swift) is a no-op in behavior: this runner already
// publishes `state`, `transcript`, and `isExecutingACommand` exactly as the
// protocol requires. It exists so the terminal view and the takeover controller
// can be generic over ANY presenter — this one for a guide install, and
// `OnDemandEditRunner` for a user-initiated edit — and reuse the same renderer.
@MainActor
final class GuideAutopilotRunner: ObservableObject, AutopilotTerminalPresenting {

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
    /// True while a command is actually in the shell (through the pacing hold),
    /// so the terminal can show a live cursor rather than a dead prompt.
    @Published private(set) var isExecutingACommand: Bool = false

    // MARK: - Collaborators

    private let shellSession: GuideAutopilotShellSessionDriving
    private let longRunningSession: GuideAutopilotShellSessionDriving
    private let fixProposer: GuideAutopilotFixProposing
    private let guideContext: GuideAutopilotGuideContext
    /// The perceived-pace floor. Real execution is untouched; this only holds a
    /// fast command's result line so the install reads as deliberate work.
    private let pacing: GuideAutopilotPacing

    // MARK: - Budget counters

    private var modelCallsUsedThisGuide = 0
    private var fixAttemptsUsedThisGuide = 0

    // MARK: - The pending-confirmation continuation

    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - The escape hatch

    /// Set when the reader clicks the terminal's red close button while Iris is
    /// mid-step. The running command is interrupted immediately; this flag is
    /// what stops the *rest* of the step — the fix ladder must not propose or
    /// run anything further once the reader has said stop, and the step must
    /// land on the "Your turn" row rather than silently evaporating.
    private var theReaderAskedToStopThisStep = false

    /// What the surfaced state says when the stop came from the reader rather
    /// than from a failure Iris could not repair.
    private static let stoppedByTheReaderDiagnosis =
        "You stopped this step. Take it from here, or continue past it."

    init(
        shellSession: GuideAutopilotShellSessionDriving,
        longRunningSession: GuideAutopilotShellSessionDriving,
        fixProposer: GuideAutopilotFixProposing,
        guideContext: GuideAutopilotGuideContext,
        pacing: GuideAutopilotPacing = .humanPaced
    ) {
        self.shellSession = shellSession
        self.longRunningSession = longRunningSession
        self.fixProposer = fixProposer
        self.guideContext = guideContext
        self.pacing = pacing
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

        // A fresh step is fresh consent: a stop pressed on the previous step
        // must not silently kill this one.
        theReaderAskedToStopThisStep = false

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
        case .failed(let exitStatus, let workingDirectory):
            return await runFailureLadder(
                step: step, command: command,
                exitStatus: exitStatus, workingDirectory: workingDirectory
            )
        }
    }

    // MARK: - Running a guide command through the gate

    private enum GuideCommandOutcome {
        case succeeded
        case failed(exitStatus: Int32, workingDirectory: String)
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
        isExecutingACommand = true
        defer { isExecutingACommand = false }
        let startedAt = Date()
        let outcome = await shellSession.run(command, deadline: GuideAutopilotShellSession.defaultCommandDeadline)
        let duration = Date().timeIntervalSince(startedAt)
        switch outcome {
        case .succeeded(let workingDirectory):
            await holdSoTheCommandReadsAsWork(elapsed: duration)
            transcript.append(.exitStatus(code: 0, duration: duration))
            _ = workingDirectory
            return .succeeded
        case .failed(let exitStatus, let workingDirectory):
            await holdSoTheCommandReadsAsWork(elapsed: duration)
            transcript.append(.exitStatus(code: exitStatus, duration: duration))
            return .failed(exitStatus: exitStatus, workingDirectory: workingDirectory)
        case .cancelled:
            if theReaderAskedToStopThisStep {
                // The reader hit the red button. Show the standing offer
                // (Try again / Continue past it) so the install is stopped,
                // not stranded — this is the escape hatch's landing place.
                state = .surfacedToReader(
                    diagnosis: Self.stoppedByTheReaderDiagnosis,
                    failingCommand: command.text
                )
            }
            return .skippedByReader
        case .timedOut:
            transcript.append(.explanation(
                text: "That command took too long and Iris stopped it."
            ))
            // 124 is the conventional "killed by timeout" exit code, so the
            // fix proposer can tell a timeout apart from a real non-zero exit.
            return .failed(exitStatus: 124, workingDirectory: shellSession.currentWorkingDirectory)
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
        exitStatus: Int32,
        workingDirectory: String
    ) async -> GuideAutopilotStepResult {
        var priorAttempts: [String] = []

        for rung in 0..<Self.maximumFixAttemptsPerStep {
            // The reader pressed stop (the red button) somewhere in the
            // previous rung — a cancelled fix command, a declined tap. The
            // ladder is over; hand the step to them.
            if theReaderAskedToStopThisStep {
                return surface(diagnosis: Self.stoppedByTheReaderDiagnosis, command: command)
            }
            guard fixAttemptsUsedThisGuide < Self.maximumFixAttemptsPerGuide,
                  modelCallsUsedThisGuide < Self.maximumModelCallsPerGuide else {
                return surfaceBudgetExhausted(command: command)
            }
            fixAttemptsUsedThisGuide += 1
            modelCallsUsedThisGuide += 1

            let context = failureContext(
                step: step, command: command, exitStatus: exitStatus,
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

            // The stop can also land while the model call above was in flight
            // — there is nothing to interrupt then, so it is caught here,
            // before the proposed fix gets to run anything.
            if theReaderAskedToStopThisStep {
                return surface(diagnosis: Self.stoppedByTheReaderDiagnosis, command: command)
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
                    // A stop pressed while the fix ran cancels the retry too —
                    // the rung-top check turns it into the surfaced hand-back.
                    guard fix.retryTheOriginalCommandAfterwards,
                          !theReaderAskedToStopThisStep else { continue }
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
        isExecutingACommand = true
        defer { isExecutingACommand = false }
        let startedAt = Date()
        let outcome = await shellSession.run(command, deadline: GuideAutopilotShellSession.defaultCommandDeadline)
        let duration = Date().timeIntervalSince(startedAt)
        await holdSoTheCommandReadsAsWork(elapsed: duration)
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

    /// Holds the "running" state on screen for the pacing floor after a fast
    /// command has already returned, so it reads as work rather than a flash.
    /// The command is done; nothing real is being slowed.
    private func holdSoTheCommandReadsAsWork(elapsed: TimeInterval) async {
        let hold = pacing.remainingHold(afterElapsed: elapsed)
        guard hold > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
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
            text: "\(guideContext.appName) is starting from source. The red button stops it and hands the step to you."
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

    /// The escape hatch: the reader clicked the terminal's red close button
    /// while Iris was mid-step. Everything interruptible is interrupted right
    /// now — a pending "Run it?" resolves as a skip, a command in the shell
    /// gets Ctrl-C (escalating to a session rebuild if it will not die) — and
    /// `theReaderAskedToStopThisStep` stops the fix ladder from proposing or
    /// running anything more. The step lands on the surfaced "Your turn" row,
    /// so the install continues on the reader's terms rather than dying.
    func abortTheCurrentStepBecauseTheReaderAskedToStop() async {
        theReaderAskedToStopThisStep = true
        transcript.append(.explanation(
            text: "Stopping this step — you take it from here."
        ))
        // Surface right away, whatever Iris was doing — waiting on a confirm
        // tap, running a command, or off in a model call the cancel below
        // cannot reach. The reader pressed stop; the row that lets them
        // continue must not wait on the machinery to notice.
        state = .surfacedToReader(
            diagnosis: Self.stoppedByTheReaderDiagnosis,
            failingCommand: ""
        )
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
        // Kill the process group IMMEDIATELY and off the command queue, before
        // the async cancels below. A heavy build (electron-builder) floods that
        // queue with its output, so an enqueued cancel lands far too late — and
        // the Ctrl-C it would send is ignored by the build anyway. This direct
        // SIGKILL is what actually makes the red button stop the setup; the
        // `cancelTheRunningCommand` calls that follow then settle the bookkeeping
        // and rebuild a fresh shell for "Try again".
        shellSession.killTheRunningProcessGroupImmediately()
        longRunningSession.killTheRunningProcessGroupImmediately()
        await shellSession.cancelTheRunningCommand()
        // The step being stopped may be a run-from-source step (`npm run app`,
        // a dev server) that Iris started on the LONG-RUNNING session and never
        // awaited — `cancelTheRunningCommand()` above only reaches the main
        // session, so without this the red button could not kill a run-from-source
        // step and the reader was stuck (they had to quit Iris). Cancel the
        // long-running session too so the escape hatch really stops the setup.
        await longRunningSession.cancelTheRunningCommand()
    }

    // MARK: - Failure context assembly

    private func failureContext(
        step: IrisGuideStep,
        command: String,
        exitStatus: Int32,
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
            exitStatus: exitStatus,
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
