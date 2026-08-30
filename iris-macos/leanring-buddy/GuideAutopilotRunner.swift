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

/// Who is paying for the model calls this install's fix ladder makes — and,
/// when publik is paying, what Iris may carry on with once publik's own budget
/// for this install is gone.
///
/// The per-guide budgets below were hardcoded `static let`s applied to every
/// reader identically. They exist to protect PUBLIK'S funded tier — 20 requests
/// / 300s and 150k tokens / day, shared with chat and the watch loop — and a
/// reader running their own Codex CLI subscription or their own pasted key costs
/// publik nothing. So the cap was stopping installs to protect money nobody was
/// spending. The reader who reported it put it plainly: "I have the codex CLI?
/// The usage shouldn't be a problem." He was right — Iris had told him "I've
/// used up what I can spend on this install for now" at step 7 of a 17-step
/// install and then left him a "Try again" button that could attempt nothing
/// new, because the latch was already spent and re-entering the same runner
/// walked straight back into it.
///
/// The runner cannot work out who is paying on its own: it has no account
/// service, no transport, and no credential — by design, so it stays testable
/// without a network. So whoever builds it says. The default is
/// `.publiksFundedTier`, which is today's behavior exactly: a caller that has
/// not been told anything keeps the cap, which is the safe direction to be
/// wrong in.
struct GuideAutopilotFixLadderFunding {

    /// Whether the calls the INJECTED proposer makes are billed to publik —
    /// asked FRESH before every single spend, never latched at construction.
    ///
    /// THIS USED TO BE A `Bool` AND THAT WAS THE BUG. The runner is built once,
    /// at the moment the reader taps "Let Iris run it"
    /// (`CompanionManager.guideSessionController`'s factory), and an install
    /// runs for tens of minutes. The credential ROUTE, meanwhile, is resolved
    /// per request by the shared `ClaudeAPI` — its own note says so: "the
    /// transport is resolved per request rather than captured once, because the
    /// user can sign in, sign out, or paste a key between two messages and the
    /// very next request has to respect that." So a reader who started signed
    /// OUT with their own key (uncapped, correctly — publik pays nothing) and
    /// then signed into publik mid-install had every later ladder call routed to
    /// `.funded` by `AssistantTransport.selectTransport` while the runner still
    /// believed publik was not paying. Measured before the fix, on one runner:
    /// 17 ladder model calls against publik's 6-attempt / 8-call ceiling, with
    /// `selectTransport(isSignedIn: true, …)` returning FUNDED for every one of
    /// them. That is publik paying without limit.
    ///
    /// A closure, asked at the gate, means the answer can only ever be as stale
    /// as the call it is about to authorise.
    let whetherPublikIsPayingForTheseCalls: @MainActor () -> Bool

    /// Builds a fix proposer that runs on the READER's own credential, for the
    /// moment publik's budget runs out mid-install. Nil when there is nothing to
    /// fall back to — and the closure returning nil means the same thing. It is
    /// asked at the moment of the fallback rather than at init, so a credential
    /// the reader connects *during* an install still counts.
    let makeAProposerOnTheReadersOwnCredential: (@MainActor () -> GuideAutopilotFixProposing?)?

    /// publik pays and there is nothing to fall back to: the latched cap applies
    /// exactly as it always has, and running out is honestly surfaced.
    static let publiksFundedTier = GuideAutopilotFixLadderFunding(
        whetherPublikIsPayingForTheseCalls: { true },
        makeAProposerOnTheReadersOwnCredential: nil
    )

    /// The reader pays for every call from the first one. publik's cap has
    /// nothing to protect here, so it does not apply at all — the only ceiling
    /// left is the progress guard in the runner, which is about a ladder going
    /// in circles rather than about spend.
    static let theReadersOwnCredential = GuideAutopilotFixLadderFunding(
        whetherPublikIsPayingForTheseCalls: { false },
        makeAProposerOnTheReadersOwnCredential: nil
    )

    /// publik pays until its cap and then, rather than stopping an install the
    /// reader could finish, Iris carries on with the reader's own credential.
    /// The founder's decision, verbatim: "just fall back when obviously when our
    /// own usage is burned through then they can use their own usage and they
    /// should be allowed."
    static func publiksFundedTierThenTheReadersOwnCredential(
        _ makeAProposerOnTheReadersOwnCredential: @escaping @MainActor () -> GuideAutopilotFixProposing?
    ) -> GuideAutopilotFixLadderFunding {
        GuideAutopilotFixLadderFunding(
            whetherPublikIsPayingForTheseCalls: { true },
            makeAProposerOnTheReadersOwnCredential: makeAProposerOnTheReadersOwnCredential
        )
    }

    /// What a real install on this Mac is funded by, given whether the reader is
    /// signed into publik. One call, so the app's runner factory is a one-line
    /// change rather than a second copy of this reasoning.
    ///
    /// THE CREDENTIAL IRIS CAN FALL BACK TO IS AN ANTHROPIC ONE — a pasted key
    /// or a connected Claude Code login. That is not a preference. The ladder
    /// asks for a forced `propose_fix` tool_use over the Anthropic Messages API,
    /// and `codex exec` cannot serve that wire format; it powers Tier C only
    /// (CLAUDE.md, "Assistant transports"). So a reader whose ONLY credential is
    /// the Codex CLI — which is the reader who reported this — still gets
    /// publik's cap and still gets the honest message, and giving him the
    /// fallback needs a Codex-backed `GuideAutopilotFixProposing` that runs
    /// `codex exec` and parses a fix out of the last message, the way
    /// `CodexMaintainProvider` does for Tier C text turns. That is a real
    /// component, not a wiring detail, so it is deliberately NOT smuggled in
    /// here; this seam takes any proposer, so it is one argument away the day it
    /// exists.
    ///
    /// TAKES A CLOSURE, NOT A BOOL. Sign-in state is not a property of the
    /// moment an install starts; it is a property of the moment a call is
    /// made, and the two are tens of minutes apart. See
    /// `whetherPublikIsPayingForTheseCalls` for what a latched Bool cost.
    @MainActor
    static func forThisReader(
        whetherTheReaderIsSignedIntoPublikRightNow: @escaping @MainActor () -> Bool
    ) -> GuideAutopilotFixLadderFunding {
        GuideAutopilotFixLadderFunding(
            whetherPublikIsPayingForTheseCalls: {
                // Signed in: `AssistantTransport.selectTransport` returns
                // `.funded` for ANY signed-in reader — even one with a BYO key
                // stored — so publik really is paying for this call and the cap
                // it protects applies.
                if whetherTheReaderIsSignedIntoPublikRightNow() { return true }
                // Signed out with their own credential connected: every ladder
                // call goes straight to Anthropic on the reader's key, publik
                // pays nothing, and the cap has nothing to protect.
                //
                // Signed out with NO credential: the ladder cannot reach a model
                // at all, so keep the funded shape and let the honest "I've used
                // up what I can spend" message be the one that fires. That is
                // also the safe direction to be wrong in.
                return !AnthropicBringYourOwnCredential.isAvailable
            },
            makeAProposerOnTheReadersOwnCredential: {
                guard AnthropicBringYourOwnCredential.isAvailable else { return nil }
                // The same BYO-only shape `MaintainFixAdapter` and
                // `AnthropicMaintainProvider` use: no account service, no funded
                // fallback, so a call made here can never land on publik's tier.
                return GuideAutopilotFixProposer(claudeAPI: ClaudeAPI(resolveTransport: {
                    guard let transport = AnthropicBringYourOwnCredential.currentTransport() else {
                        return .failure(.noCredentialsAvailable)
                    }
                    return .success(transport)
                }))
            }
        )
    }
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
    /// which surfaces rather than spends. This one is not about money — it is
    /// how many different things Iris tries on one command — so it applies to
    /// every reader on every credential, and is unchanged.
    static let maximumFixAttemptsPerStep = 2

    /// The two per-guide ceilings on PUBLIK'S OWN SPEND. The funded tier is 20
    /// requests / 300s and 150k tokens / day, shared with chat and the
    /// WatchLoop's up-to-8 visual calls per step, so a runaway ladder must not
    /// be able to drain the day on one install. They are latched to exactly the
    /// numbers they have always had — but they now apply ONLY while the ladder
    /// is spending publik's money — which is now asked fresh at every spend,
    /// never latched at construction (`publikIsPayingForTheCallAboutToBeMade`).
    ///
    /// The binding one is `maximumFixAttemptsPerGuide`: the gate increments both
    /// counters on every rung, so 6 always trips first and 8 is unreachable
    /// through the ladder. Both are gated for that reason — making only the
    /// model-call cap provider-aware would have changed nothing observable.
    static let maximumFixAttemptsPerGuide = 6
    static let maximumModelCallsPerGuide = 8

    /// The ceiling that stands in for the spend cap once the reader is the one
    /// paying. Uncapped must not mean unbounded-forever, but the thing worth
    /// bounding on someone else's credential is a ladder going in CIRCLES, not
    /// a ladder doing a lot of useful work — a 17-step install where every
    /// repair lands is exactly the case the spend cap was wrongly killing.
    ///
    /// So the rule is `MaintainTierCFixer.noProgressStepThreshold`'s (5
    /// consecutive steps with an unchanged working tree), transposed to what
    /// this ladder can observe: five consecutive steps that Iris SPENT model
    /// calls on and still could not get running. A step that runs — with or
    /// without a repair — resets it, and a step the ladder never got to spend
    /// anything on (publik's budget already gone) does not count, because "Iris
    /// could not even try" is not evidence of spinning. Worst case that is ten
    /// model calls with nothing to show for them, and then Iris stops asking.
    static let maximumConsecutiveStepsTheLadderMaySpendOnWithoutGettingOneRunning = 5

    // MARK: - Published state

    @Published private(set) var state: GuideAutopilotState = .notStarted
    @Published private(set) var transcript: [GuideAutopilotTranscriptEntry] = []
    /// True while a command is actually in the shell (through the pacing hold),
    /// so the terminal can show a live cursor rather than a dead prompt.
    @Published private(set) var isExecutingACommand: Bool = false

    // MARK: - Collaborators

    private let shellSession: GuideAutopilotShellSessionDriving
    private let longRunningSession: GuideAutopilotShellSessionDriving
    /// Not a `let` any more: when publik's budget for this install runs out and
    /// the reader has their own credential, the ladder MOVES onto a proposer
    /// that spends theirs and carries on. The alternative — a second runner, or
    /// a proposer that decides internally which credential to bill — would have
    /// hidden the switch from the transcript and from the budget counters, which
    /// are the only two places a reader or a test can see it happen.
    private var fixProposer: GuideAutopilotFixProposing
    /// Who is paying, and what Iris may fall back to. See the type's own notes.
    private let fixLadderFunding: GuideAutopilotFixLadderFunding
    private let guideContext: GuideAutopilotGuideContext
    /// The perceived-pace floor. Real execution is untouched; this only holds a
    /// fast command's result line so the install reads as deliberate work.
    private let pacing: GuideAutopilotPacing

    // MARK: - Budget counters

    private var modelCallsUsedThisGuide = 0
    private var fixAttemptsUsedThisGuide = 0
    /// True once the ladder has MOVED onto a proposer pinned to the reader's
    /// own credential. This is the one thing here that is genuinely latched,
    /// and it is latched because the PROPOSER was swapped: those calls are
    /// pinned to a BYO transport, so no later sign-in can put them back on
    /// publik's tier. Everything else about who is paying is re-asked at the
    /// gate — see `GuideAutopilotFixLadderFunding.whetherPublikIsPayingForTheseCalls`.
    private var theLadderHasMovedOntoTheReadersOwnCredential = false
    /// The progress guard's counter (see
    /// `maximumConsecutiveStepsTheLadderMaySpendOnWithoutGettingOneRunning`):
    /// consecutive steps Iris spent model calls on and still handed back.
    private var consecutiveStepsTheLadderSpentOnWithoutGettingThemRunning = 0

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
        pacing: GuideAutopilotPacing = .humanPaced,
        fixLadderFunding: GuideAutopilotFixLadderFunding = .publiksFundedTier
    ) {
        self.shellSession = shellSession
        self.longRunningSession = longRunningSession
        self.fixProposer = fixProposer
        self.fixLadderFunding = fixLadderFunding
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
            return await startLongRunning(step: step, command: command)
        }

        // Put the shell where the step says it runs, before it runs. A step
        // that declares nothing is left exactly where the shell already is —
        // that is every already-published guide, and it must not change.
        if let folder = step.workingDirectory,
           !(await moveInto(folder, using: shellSession)) {
            return surface(diagnosis: Self.folderRefusalDiagnosis(folder), command: command)
        }

        transcript.append(.commandFromTheGuide(text: command))
        let outcome = await runGuideCommand(
            command, inWorkingDirectory: step.workingDirectory ?? shellSession.currentWorkingDirectory
        )
        switch outcome {
        case .succeeded:
            // A step that ran is progress, whether or not the ladder was
            // involved, so it clears the no-progress guard's count.
            consecutiveStepsTheLadderSpentOnWithoutGettingThemRunning = 0
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

    /// `workingDirectory` is where this command will really run — the folder
    /// the step declared, or the one the shell is already in. The gate needs
    /// it: every rule it applies is a pattern over command text, and text does
    /// not say where it runs, so `cp -R ./Evil.app .` is a system-folder write
    /// or a harmless copy depending entirely on this argument.
    private func runGuideCommand(
        _ command: String,
        inWorkingDirectory workingDirectory: String
    ) async -> GuideCommandOutcome {
        switch GuideAutopilotRiskAssessment.assess(command, inWorkingDirectory: workingDirectory) {
        case .runsWithoutAsking:
            guard let approved = GuideAutopilotRiskAssessment.approve(
                command, inWorkingDirectory: workingDirectory
            ) else {
                return .stopped
            }
            return await runApproved(approved)
        case .needsAConfirmTap(let reason):
            let approvedToRun = await askTheReaderToConfirm(
                command: command, reason: reason, isFromAFix: false
            )
            guard approvedToRun,
                  let approved = GuideAutopilotRiskAssessment.approveAfterAReaderTap(
                      command, inWorkingDirectory: workingDirectory
                  ) else {
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

    /// Wraps the ladder so every one of its exits is scored for PROGRESS. The
    /// climb itself has a dozen return points, and the runaway guard needs one
    /// place that sees them all — hence the split rather than a counter nudged
    /// at each `return`, which is exactly the shape that rots.
    private func runFailureLadder(
        step: IrisGuideStep,
        command: String,
        exitStatus: Int32,
        workingDirectory: String
    ) async -> GuideAutopilotStepResult {
        let modelCallsBeforeThisStepsLadder = modelCallsUsedThisGuide
        let result = await climbTheFixLadder(
            step: step, command: command,
            exitStatus: exitStatus, workingDirectory: workingDirectory
        )
        let theLadderSpentSomethingOnThisStep = modelCallsUsedThisGuide > modelCallsBeforeThisStepsLadder
        if result == .succeeded {
            consecutiveStepsTheLadderSpentOnWithoutGettingThemRunning = 0
        } else if theLadderSpentSomethingOnThisStep, result == .surfacedToReader {
            // Iris asked the model, tried what it said, and the step still is
            // not running. Only this counts as spinning: a reader stopping or
            // skipping is their decision, and a step the budget never let Iris
            // try is not the ladder's failure to report.
            consecutiveStepsTheLadderSpentOnWithoutGettingThemRunning += 1
        }
        return result
    }

    private func climbTheFixLadder(
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
            // The runaway guard, before the spend gate because it applies to
            // both payers: a ladder that has spent calls on five steps in a row
            // without getting one of them running is going in circles, and that
            // is true whoever is paying for the circles.
            if consecutiveStepsTheLadderSpentOnWithoutGettingThemRunning
                >= Self.maximumConsecutiveStepsTheLadderMaySpendOnWithoutGettingOneRunning {
                return surfaceTheLadderIsGettingNowhere(command: command)
            }
            guard theLadderMayAskTheModelAgain() else {
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
                    let retry = await runGuideCommand(
                        command,
                        inWorkingDirectory: step.workingDirectory ?? shellSession.currentWorkingDirectory
                    )
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
        // A repair runs in the shell as the step left it, which is the step's
        // declared folder. A model-proposed `cp ./x .` is judged against that
        // folder for the same reason a guide's is.
        let folder = shellSession.currentWorkingDirectory
        switch GuideAutopilotRiskAssessment.assess(fixCommand, inWorkingDirectory: folder) {
        case .runsWithoutAsking:
            guard let approved = GuideAutopilotRiskAssessment.approve(
                fixCommand, inWorkingDirectory: folder
            ) else {
                return .stopped
            }
            return .ran(fixSucceeded: await runFixApproved(approved))
        case .needsAConfirmTap(let reason):
            let approvedToRun = await askTheReaderToConfirm(
                command: fixCommand, reason: reason, isFromAFix: true
            )
            guard approvedToRun,
                  let approved = GuideAutopilotRiskAssessment.approveAfterAReaderTap(
                      fixCommand, inWorkingDirectory: folder
                  ) else {
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

    // MARK: - The folder a step says it runs in

    /// A folder a guide may send the shell to: a plain path under home or the
    /// root, with nothing in it that a shell would expand, split or run.
    ///
    /// The web side holds every published step to the same shape
    /// (`WORKING_DIRECTORY` in lib/guide-invariants.ts) and this repeats the
    /// check rather than trusting it, because the value arrives over the wire
    /// from a guide table and is about to become the argument of a real `cd` in
    /// the reader's login shell. `~` is deliberately left unquoted and
    /// unexpanded here so the shell resolves it against its own HOME — the one
    /// place that always knows the right answer.
    private static func isAPlainFolder(_ folder: String) -> Bool {
        guard !folder.isEmpty, folder.hasPrefix("~") || folder.hasPrefix("/") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~@+-/")
        guard folder.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !folder.split(separator: "/").contains("..")
    }

    /// The folders a guide step may never put the shell into, spelled from the
    /// same list as the gate's own "writes into a system folder" rule
    /// (`GuideAutopilotRiskAssessment.confirmRules`), plus the root itself.
    ///
    /// This is the belt to `commandAsItWillRun`'s braces. That resolution makes
    /// the gate judge `cp -R ./Evil.app .` as the `/Applications` write it
    /// really is; this makes the shell refuse to stand in `/Applications` in the
    /// first place, so a relative write there is unreachable rather than merely
    /// caught. Both are cheap and they fail in different ways, and publik has
    /// open publishing — a submission goes live instantly, so the folder in a
    /// guide is attacker-controlled text.
    ///
    /// No shipped guide is affected: every `workingDirectory` published today
    /// is `~` or `~/<checkout>` (lib/guides/*.ts), and a step that genuinely
    /// needs to touch a system folder still can — by naming it in the command,
    /// where the gate can read it and ask.
    private static let systemFoldersAStepMayNotRunIn = [
        "/usr", "/etc", "/Library", "/System", "/Applications",
    ]

    private static func isASystemFolder(_ folder: String) -> Bool {
        var trimmed = folder
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return true }
        return systemFoldersAStepMayNotRunIn.contains {
            trimmed == $0 || trimmed.hasPrefix($0 + "/")
        }
    }

    /// The sentence the reader is shown when the step's folder is refused —
    /// which of the two reasons it was.
    private static func folderRefusalDiagnosis(_ folder: String) -> String {
        isASystemFolder(folder) ? systemFolderDiagnosis(folder) : wrongFolderDiagnosis(folder)
    }

    private static func systemFolderDiagnosis(_ folder: String) -> String {
        "This step asks Iris to work inside \(folder), which is a system folder. "
            + "Iris won't put a terminal there — a command written for the folder "
            + "it is standing in would change files in \(folder) without ever "
            + "naming them, and nothing would have asked you first. Run this step "
            + "yourself if you meant it."
    }

    private static func wrongFolderDiagnosis(_ folder: String) -> String {
        "Iris couldn't move into \(folder), so it didn't run the command — "
            + "running it in the wrong folder is how this step failed before. "
            + "Check that the folder is there; the step that copies the code "
            + "onto this computer is the one to go back to."
    }

    /// Moves `session` into the folder the step declared, and reports whether
    /// it landed there.
    ///
    /// Two things this deliberately does NOT do. It does not prefix the
    /// command with `cd … && `: guide commands are routinely several lines
    /// (`cd ui`, `pnpm install`, `cd ..`) and the `&&` would bind to the first
    /// line only, which is the same silent wrong-folder run in a new disguise.
    /// And it does not run through `runApproved`, because that one holds every
    /// command on screen for the pacing floor — a hidden `cd` is not work the
    /// reader is waiting to watch, and paying 1.2s for it on every step of
    /// every install would be a real cost for no signal.
    ///
    /// A `cd` that fails stops the step. The alternative — carrying on in
    /// whatever folder the shell is in — is precisely the reported defect.
    private func moveInto(
        _ folder: String,
        using session: GuideAutopilotShellSessionDriving
    ) async -> Bool {
        guard !Self.isASystemFolder(folder) else {
            transcript.append(.explanation(text: Self.systemFolderDiagnosis(folder)))
            return false
        }
        guard Self.isAPlainFolder(folder),
              let approved = GuideAutopilotRiskAssessment.approve("cd \(folder)") else {
            transcript.append(.explanation(text: Self.wrongFolderDiagnosis(folder)))
            return false
        }
        switch await session.run(approved, deadline: Self.folderMoveDeadline) {
        case .succeeded:
            return true
        default:
            // zsh has already printed its own "cd: no such file or directory:
            // …" into the transcript, which is the sentence a reader can act
            // on; this adds the part zsh cannot know — which step to go back to.
            transcript.append(.explanation(text: Self.wrongFolderDiagnosis(folder)))
            return false
        }
    }

    /// A `cd` is instant; anything longer means the shell is wedged, and
    /// waiting the full command deadline for one would just hide that.
    private static let folderMoveDeadline: TimeInterval = 30

    // MARK: - Surfacing

    private func surface(diagnosis: String?, command: String) -> GuideAutopilotStepResult {
        let text = diagnosis ?? "Iris couldn't get this step working on its own."
        state = .surfacedToReader(diagnosis: text, failingCommand: command)
        return .surfacedToReader
    }

    /// Whether the call the ladder is ABOUT TO MAKE is billed to publik, asked
    /// fresh every time rather than read off a flag set when the install began.
    ///
    /// A reader can sign into publik at any point during an install, and the
    /// shared `ClaudeAPI` re-resolves its transport per request, so the answer
    /// really does change underneath a running ladder. Asking here is what
    /// keeps publik's cap attached to publik's spending.
    private func publikIsPayingForTheCallAboutToBeMade() -> Bool {
        // The proposer is pinned to the reader's own credential; nothing this
        // ladder does from here can reach publik's tier, whoever signs in.
        if theLadderHasMovedOntoTheReadersOwnCredential { return false }
        return fixLadderFunding.whetherPublikIsPayingForTheseCalls()
    }

    /// Whether the ladder may make one more model call — and, when publik's own
    /// budget is what ran out, whether Iris can carry on at the reader's expense
    /// instead of stopping an install they are perfectly able to finish.
    private func theLadderMayAskTheModelAgain() -> Bool {
        // Not publik's money: the funded tier's cap has nothing to protect, and
        // the only ceiling is the progress guard checked by the caller.
        guard publikIsPayingForTheCallAboutToBeMade() else { return true }
        if fixAttemptsUsedThisGuide < Self.maximumFixAttemptsPerGuide,
           modelCallsUsedThisGuide < Self.maximumModelCallsPerGuide {
            return true
        }
        return carryOnWithTheReadersOwnCredentialIfTheyHaveOne()
    }

    /// publik's budget for this install is gone. If the reader brought their own
    /// credential, the install continues on it — the fallback the founder asked
    /// for — and the transcript says so, because a switch that costs the reader
    /// money must not be silent.
    private func carryOnWithTheReadersOwnCredentialIfTheyHaveOne() -> Bool {
        guard let makeAProposerOnTheReadersOwnCredential
                = fixLadderFunding.makeAProposerOnTheReadersOwnCredential,
              let theReadersOwnProposer = makeAProposerOnTheReadersOwnCredential() else {
            return false
        }
        fixProposer = theReadersOwnProposer
        theLadderHasMovedOntoTheReadersOwnCredential = true
        transcript.append(.explanation(text: Self.carryingOnWithTheReadersOwnCredential))
        return true
    }

    private static let carryingOnWithTheReadersOwnCredential =
        "That's as far as publik's own model budget goes for this install — Iris is "
        + "carrying on with the credential you connected, so the install doesn't stop here."

    /// Only ever fires when PUBLIK is the one paying and there is nothing to fall
    /// back to. It used to fire for every reader, including one on his own Codex
    /// subscription, which is what made it a lie; the second sentence is the way
    /// out, because "I can't spend any more" with no route forward is what left
    /// the reporting reader with two buttons that could do nothing.
    private func surfaceBudgetExhausted(command: String) -> GuideAutopilotStepResult {
        let honest = "I've used up what I can spend on this install for now — here's the "
            + "command that failed, and you can take it from here. Connect your own "
            + "Anthropic key or Claude Code login in Iris's settings and it can keep going."
        transcript.append(.explanation(text: honest))
        state = .surfacedToReader(diagnosis: honest, failingCommand: command)
        return .surfacedToReader
    }

    /// The other way the ladder can stop: not out of money, out of ideas. Said
    /// separately because "I've used up what I can spend" would be false here —
    /// on the reader's own credential Iris can always spend more, it just has no
    /// reason to believe more spending would help.
    private func surfaceTheLadderIsGettingNowhere(command: String) -> GuideAutopilotStepResult {
        let honest = "Iris has repaired and re-run the last few steps and none of them came "
            + "up — it's going in circles rather than getting closer, so it's stopping "
            + "rather than burning more of your model usage. Here's the command that failed."
        transcript.append(.explanation(text: honest))
        state = .surfacedToReader(diagnosis: honest, failingCommand: command)
        return .surfacedToReader
    }

    // MARK: - Dev servers

    private func startLongRunning(step: IrisGuideStep, command: String) async -> GuideAutopilotStepResult {
        // The side session is about to be moved into the step's folder, so
        // that is the folder this command will run in — assess it there.
        let folder = step.workingDirectory ?? longRunningSession.currentWorkingDirectory
        guard let approved = GuideAutopilotRiskAssessment.approve(
            command, inWorkingDirectory: folder
        ) else {
            transcript.append(.explanation(
                text: "Iris won't start this one automatically — run it yourself when you're ready."
            ))
            return .skippedByReader
        }
        transcript.append(.commandFromTheGuide(text: command))
        if !(await longRunningSession.start()) {
            return .stopped
        }
        // The side session is its own shell and has never seen the guide's
        // `cd` steps, so a dev server is the case where an undeclared folder
        // hurt most: `pnpm dev` in the home folder, every time. It gets the
        // same move the main session gets.
        if let folder = step.workingDirectory,
           !(await moveInto(folder, using: longRunningSession)) {
            return surface(diagnosis: Self.folderRefusalDiagnosis(folder), command: command)
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
