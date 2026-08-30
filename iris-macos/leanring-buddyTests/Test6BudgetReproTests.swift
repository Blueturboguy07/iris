//
//  Test6BudgetReproTests.swift
//  leanring-buddyTests
//
//  ROOT CAUSE D — the fix ladder's budget is PROVIDER-BLIND.
//
//  `GuideAutopilotRunner.maximumFixAttemptsPerGuide = 6` and
//  `maximumModelCallsPerGuide = 8` are hardcoded `static let`s, and the comment
//  above them says exactly who they protect: "the funded tier is 20 requests /
//  300s and 150k tokens / day … so a runaway ladder must not be able to drain
//  the day on one install." That is publik's money. The gate at the top of
//  `runFailureLadder` applies it identically to a reader running their OWN
//  Codex CLI subscription or their OWN API key, where publik pays nothing and
//  there is nothing to protect.
//
//  WHAT THE READER SAW, in his own words:
//
//    Iris:   "I've used up what I can spend on this install for now — here's
//             the command that failed, and you can take it from here."
//    Reader: "I have the codex CLI? The usage shouldn't be a problem."
//    Reader: "the only two options are try again, where iris tries again, and
//             continue, where continue leads to failure bc of it doesn't work
//             it doesn't try anything new so there's no point of having that."
//
//  He is right on both counts. Eight fix attempts across a 17-step install is
//  nothing when he is the one paying — and because the counters are latched for
//  the whole guide on the one runner instance, "Try again"
//  (`GuideSessionController.retryTheSurfacedStep()` re-enters
//  `executeStepCommand` on that same runner) walks straight back into the spent
//  gate and attempts NOTHING new. That is why the button was useless.
//
//  THE FOUNDER'S DECISION, verbatim: "uncapped the fix ladder when the reader's
//  on their own credential because yeah, like just fall back when obviously
//  when our own usage is burned through then they can use their own usage and
//  they should be allowed."
//
//  These cases are deliberately built so that EVERY repair WORKS and every
//  repaired step then passes — real, measurable progress on every single step.
//  That matters: the fix is required to keep a runaway guard that is about
//  PROGRESS rather than spend (the `MaintainTierCFixer.noProgressStepThreshold`
//  precedent), and no progress-based guard may fire on an install where all 17
//  steps were actually repaired and actually succeeded. The only thing that can
//  stop this install is the funded-tier spend cap — which is the defect.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite("Root cause D — the fix ladder's budget is provider-blind")
struct Test6BudgetReproTests {

    // MARK: - The install, as the reader's machine behaved

    /// A shell where each guide command fails the way a real install fails —
    /// and then genuinely works once its own repair has run. No queue of
    /// scripted outcomes: the answer is a function of what has actually been
    /// run, so the fake stays honest however many times the ladder re-enters.
    final class RepairableFakeShell: GuideAutopilotShellSessionDriving {
        static let guideCommandPrefix = "pnpm run build-step-"
        static let repairCommandPrefix = "pnpm approve-builds-step-"

        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/akrit/whimprflow"
        var resolvedSearchPath: String? = "/usr/bin:/bin"

        private(set) var commandsRun: [String] = []
        private var stepsWhoseRepairHasRun: Set<String> = []

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async {}
        func tailForTheModel() -> String {
            "ERR_PNPM_BUILD_BLOCKED  the dependency's build script was not approved"
        }

        func run(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            if command.text.hasPrefix(Self.repairCommandPrefix) {
                stepsWhoseRepairHasRun.insert(
                    String(command.text.dropFirst(Self.repairCommandPrefix.count))
                )
                return .succeeded(workingDirectory: currentWorkingDirectory)
            }
            guard command.text.hasPrefix(Self.guideCommandPrefix) else {
                return .succeeded(workingDirectory: currentWorkingDirectory)
            }
            let step = String(command.text.dropFirst(Self.guideCommandPrefix.count))
            return stepsWhoseRepairHasRun.contains(step)
                ? .succeeded(workingDirectory: currentWorkingDirectory)
                : .failed(exitStatus: 1, workingDirectory: currentWorkingDirectory)
        }
    }

    /// A model that diagnoses every one of these failures correctly and hands
    /// back a repair that works. It counts how many times the ladder was
    /// actually allowed to ask it anything — the number the budget gate caps.
    final class CorrectlyDiagnosingProposer: GuideAutopilotFixProposing {
        private(set) var timesTheLadderAskedTheModel = 0

        /// The one step this model gets WRONG the first two times it is asked —
        /// both of that step's rungs propose a repair that runs cleanly and
        /// fixes nothing, so Iris spends its per-step ladder and hands the step
        /// back. Asked a third time (the reader tapping "Try again") it has the
        /// right answer. This is the ONLY way the reader's own complaint about
        /// that button can be reached at all: a step Iris has already repaired
        /// is not a step "Try again" can do anything new on.
        var theStepThisModelGetsWrongTwiceFirst: String?
        private var wrongAnswersAlreadyGivenForThatStep = 0

        /// Every repair runs and fixes nothing, for every step — the "going in
        /// circles" shape the progress guard exists to stop.
        var everyRepairThisModelProposesIsWrong = false

        func proposeFix(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? {
            timesTheLadderAskedTheModel += 1
            return repair(forStepIdentifier: context.stepIdentifier)
        }

        func proposeFixWithWebSearch(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? {
            timesTheLadderAskedTheModel += 1
            return repair(forStepIdentifier: context.stepIdentifier)
        }

        private func repair(forStepIdentifier identifier: String) -> GuideAutopilotProposedFix {
            if everyRepairThisModelProposesIsWrong {
                return Self.aRepairThatRunsAndFixesNothing
            }
            if identifier == theStepThisModelGetsWrongTwiceFirst,
               wrongAnswersAlreadyGivenForThatStep < 2 {
                wrongAnswersAlreadyGivenForThatStep += 1
                return Self.aRepairThatRunsAndFixesNothing
            }
            return GuideAutopilotProposedFix(
                diagnosis: "pnpm blocked that dependency's build script.",
                confidence: "high",
                action: .runACommand(
                    command: RepairableFakeShell.repairCommandPrefix + identifier,
                    whatItDoes: "Approves the build script pnpm blocked."
                ),
                retryTheOriginalCommandAfterwards: true,
                cameFromWebSearch: false
            )
        }

        /// Runs fine, changes nothing the guide command depends on — the shell
        /// above only counts a repair that carries `repairCommandPrefix`.
        private static let aRepairThatRunsAndFixesNothing = GuideAutopilotProposedFix(
            diagnosis: "That looks like a stale pnpm store.",
            confidence: "medium",
            action: .runACommand(
                command: "pnpm rebuild-store",
                whatItDoes: "Rebuilds pnpm's store index."
            ),
            retryTheOriginalCommandAfterwards: true,
            cameFromWebSearch: false
        )
    }

    // MARK: - The two runners

    /// THE SEAM. This was the thing that did not exist: the runner took no
    /// credential, no transport and no account service, so every reader got
    /// publik's funded-tier cap whether or not publik was paying for anything.
    /// It is now `GuideAutopilotFixLadderFunding`, an argument on the
    /// initializer, and this is the install the READER is paying for — his own
    /// pasted key, his own Claude Code login. The assertions below are unchanged.
    private static func runnerOnTheReadersOwnCredential(
        shell: RepairableFakeShell,
        proposer: CorrectlyDiagnosingProposer
    ) -> GuideAutopilotRunner {
        makeRunner(shell: shell, proposer: proposer, funding: .theReadersOwnCredential)
    }

    /// A runner on publik's funded tier, where the cap is publik's own money and
    /// must stay exactly as it is today.
    private static func runnerOnThePublikFundedTier(
        shell: RepairableFakeShell,
        proposer: CorrectlyDiagnosingProposer
    ) -> GuideAutopilotRunner {
        makeRunner(shell: shell, proposer: proposer, funding: .publiksFundedTier)
    }

    private static func makeRunner(
        shell: RepairableFakeShell,
        proposer: CorrectlyDiagnosingProposer,
        funding: GuideAutopilotFixLadderFunding
    ) -> GuideAutopilotRunner {
        GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: RepairableFakeShell(),
            fixProposer: proposer,
            guideContext: GuideAutopilotGuideContext(
                slug: "whimprflow", version: 3, appName: "WhimprFlow",
                platformLabel: "macOS",
                hostsReachedByTheGuide: ["github.com"]
            ),
            pacing: .instant,
            fixLadderFunding: funding
        )
    }

    private static let stepsInTheInstall = 17

    private static func step(number: Int) -> IrisGuideStep {
        IrisGuideStep(
            id: "\(number)",
            kind: .terminal,
            title: "Step \(number)",
            body: "…",
            command: RepairableFakeShell.guideCommandPrefix + "\(number)",
            watch: nil
        )
    }

    /// The exact sentence the reader was shown, as `surfaceBudgetExhausted`
    /// writes it. Matched on its distinctive middle so a reworded fix that
    /// still says "I've used up what I can spend" is still caught.
    private static let budgetExhaustedSentenceFragment = "used up what I can spend"

    private static func explanations(in runner: GuideAutopilotRunner) -> [String] {
        runner.transcript.compactMap { entry in
            if case .explanation(let text) = entry { return text }
            return nil
        }
    }

    // MARK: - The defect

    @Test("a 17-step install on the reader's OWN credential is not stopped by publik's funded-tier cap")
    func theInstallIsNotStoppedByAFundedTierCapTheReaderIsNotUsing() async {
        // "I have the codex CLI? The usage shouldn't be a problem."
        let shell = RepairableFakeShell()
        let proposer = CorrectlyDiagnosingProposer()
        let runner = Self.runnerOnTheReadersOwnCredential(shell: shell, proposer: proposer)

        var resultOfStep: [Int: GuideAutopilotStepResult] = [:]
        for index in 0..<Self.stepsInTheInstall {
            resultOfStep[index + 1] = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }

        let stepsIrisGaveUpOn = resultOfStep
            .filter { $0.value == .surfacedToReader }
            .keys.sorted()
        let stepsThatFinished = resultOfStep.filter { $0.value == .succeeded }.keys.count
        let budgetMessages = Self.explanations(in: runner)
            .filter { $0.contains(Self.budgetExhaustedSentenceFragment) }

        // What the reader actually watched happen, printed so the failure is
        // readable as a timeline rather than as a count.
        print("""
        [repro] steps that finished: \(stepsThatFinished)/\(Self.stepsInTheInstall)
        [repro] steps Iris gave up on: \(stepsIrisGaveUpOn)
        [repro] times the ladder was allowed to ask the model: \
        \(proposer.timesTheLadderAskedTheModel)
        [repro] what Iris said: \(budgetMessages.first ?? "(nothing)")
        """)

        // Every repair here works and every repaired step then passes, so there
        // is real progress on every step and nothing legitimate can stop this
        // install. The reader is paying. It must run to the end.
        #expect(
            budgetMessages.isEmpty,
            """
            Iris told a reader paying for his own model calls: \
            "\(budgetMessages.first ?? "")" — publik's funded-tier cap fired on \
            a credential publik is not paying for.
            """
        )
        #expect(
            stepsIrisGaveUpOn.isEmpty,
            "Iris gave up on steps \(stepsIrisGaveUpOn) of \(Self.stepsInTheInstall) even though every repair it proposed worked."
        )
        #expect(
            stepsThatFinished == Self.stepsInTheInstall,
            "only \(stepsThatFinished) of \(Self.stepsInTheInstall) steps finished"
        )
        // 17 failing steps, one repair each: the ladder must be allowed to ask
        // the model on every one of them, which is more than the funded tier's
        // latched ceiling of 8.
        #expect(
            proposer.timesTheLadderAskedTheModel == Self.stepsInTheInstall,
            "the ladder asked the model \(proposer.timesTheLadderAskedTheModel) times for \(Self.stepsInTheInstall) repairable failures"
        )
    }

    @Test("\"Try again\" actually tries something new when the reader is paying")
    func tryAgainTriesSomethingNewInsteadOfWalkingBackIntoASpentGate() async {
        // "the only two options are try again, where iris tries again, and
        //  continue, where continue leads to failure bc of it doesn't work it
        //  doesn't try anything new so there's no point of having that."
        let shell = RepairableFakeShell()
        let proposer = CorrectlyDiagnosingProposer()
        let seventhStepIdentifier = "\(GuideAutopilotRunner.maximumFixAttemptsPerGuide + 1)"
        // SHARPENED AFTER THE FIX LANDED, and here is exactly what changed and
        // why. As first written, this test spent the budget and then re-entered
        // a step Iris had ALREADY repaired — which today returns
        // `.surfacedToReader` with zero calls (the defect) but, once the ladder
        // is uncapped, is a step whose command simply passes, so "Try again"
        // correctly attempts nothing and `callsAfter > callsBefore` could never
        // hold for ANY correct fix. The reader's complaint is about a step that
        // is STILL BROKEN when he taps the button, so that is what is built
        // here: the model gets this one step wrong twice, Iris spends its
        // per-step ladder on it and hands it back, and the tap must then try
        // something new. Both assertions are unchanged, and this scenario is
        // strictly harder — it needs the ladder to work past the funded ceiling
        // AND across a re-entry into the same runner.
        proposer.theStepThisModelGetsWrongTwiceFirst = seventhStepIdentifier
        let runner = Self.runnerOnTheReadersOwnCredential(shell: shell, proposer: proposer)

        // Spend what the funded tier would allow: six repairable steps, six
        // repairs, six successes.
        for index in 0..<GuideAutopilotRunner.maximumFixAttemptsPerGuide {
            _ = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }
        let seventhStep = Self.step(number: GuideAutopilotRunner.maximumFixAttemptsPerGuide + 1)
        _ = await runner.executeStepCommand(
            step: seventhStep,
            stepIndex: GuideAutopilotRunner.maximumFixAttemptsPerGuide,
            totalSteps: Self.stepsInTheInstall
        )
        let callsBeforeTheReaderTappedTryAgain = proposer.timesTheLadderAskedTheModel

        // The reader taps "Try again" — GuideSessionController.retryTheSurfacedStep()
        // re-enters the SAME runner with the SAME step.
        let resultOfTryAgain = await runner.executeStepCommand(
            step: seventhStep,
            stepIndex: GuideAutopilotRunner.maximumFixAttemptsPerGuide,
            totalSteps: Self.stepsInTheInstall
        )
        let callsAfter = proposer.timesTheLadderAskedTheModel

        print("""
        [repro] model calls before "Try again": \(callsBeforeTheReaderTappedTryAgain)
        [repro] model calls after  "Try again": \(callsAfter)
        [repro] "Try again" returned: \(resultOfTryAgain)
        """)

        #expect(
            callsAfter > callsBeforeTheReaderTappedTryAgain,
            "Try again attempted nothing new — the ladder was already spent, so the button cannot do anything the reader can see"
        )
        #expect(
            resultOfTryAgain == .succeeded,
            "the repair for this step works; Try again should have gotten the step running, and instead returned \(resultOfTryAgain)"
        )
    }

    // MARK: - The line the fix must not cross

    @Test("publik's funded tier is still capped — uncapping the reader must not uncap publik")
    func thePublikFundedTierIsStillCapped() async {
        // This one passes today and must keep passing. The cap exists to protect
        // publik's own 20-requests/300s, 150k-tokens/day tier; making the ladder
        // provider-aware must not turn into making it free for everyone.
        let shell = RepairableFakeShell()
        let proposer = CorrectlyDiagnosingProposer()
        let runner = Self.runnerOnThePublikFundedTier(shell: shell, proposer: proposer)

        for index in 0..<Self.stepsInTheInstall {
            _ = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }

        #expect(
            proposer.timesTheLadderAskedTheModel <= GuideAutopilotRunner.maximumModelCallsPerGuide,
            "the funded tier must not spend more than its latched cap"
        )
        #expect(
            Self.explanations(in: runner).contains {
                $0.contains(Self.budgetExhaustedSentenceFragment)
            },
            "the funded tier really does run out, and must still say so"
        )
    }

    // MARK: - The fallback the founder actually asked for

    /// "just fall back when obviously when our own usage is burned through then
    /// they can use their own usage and they should be allowed."
    ///
    /// This is the case a signed-in reader is in: `AssistantTransport.selectTransport`
    /// prefers the funded route while they are signed in, so the ladder really
    /// does start on publik's money — and when that runs out the install must
    /// continue on the credential the reader connected, not stop.
    @Test("when publik's budget runs out mid-install, Iris carries on with the reader's own credential")
    func theFundedTierFallsBackToTheReadersOwnCredential() async {
        let shell = RepairableFakeShell()
        let proposerPublikPaysFor = CorrectlyDiagnosingProposer()
        let proposerOnTheReadersOwnCredential = CorrectlyDiagnosingProposer()
        let runner = Self.makeRunner(
            shell: shell,
            proposer: proposerPublikPaysFor,
            funding: .publiksFundedTierThenTheReadersOwnCredential {
                proposerOnTheReadersOwnCredential
            }
        )

        var resultOfStep: [Int: GuideAutopilotStepResult] = [:]
        for index in 0..<Self.stepsInTheInstall {
            resultOfStep[index + 1] = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }
        let stepsThatFinished = resultOfStep.filter { $0.value == .succeeded }.keys.count

        print("""
        [fallback] calls billed to publik: \(proposerPublikPaysFor.timesTheLadderAskedTheModel)
        [fallback] calls on the reader's own credential: \
        \(proposerOnTheReadersOwnCredential.timesTheLadderAskedTheModel)
        [fallback] steps that finished: \(stepsThatFinished)/\(Self.stepsInTheInstall)
        """)

        #expect(
            proposerPublikPaysFor.timesTheLadderAskedTheModel
                <= GuideAutopilotRunner.maximumFixAttemptsPerGuide,
            "publik paid for more than its own cap allows"
        )
        #expect(
            proposerOnTheReadersOwnCredential.timesTheLadderAskedTheModel > 0,
            "the install stopped instead of carrying on with the credential the reader connected"
        )
        #expect(
            stepsThatFinished == Self.stepsInTheInstall,
            "only \(stepsThatFinished) of \(Self.stepsInTheInstall) steps finished"
        )
        #expect(
            !Self.explanations(in: runner).contains {
                $0.contains(Self.budgetExhaustedSentenceFragment)
            },
            "Iris said it had run out when it had somewhere to carry on"
        )
        // The switch spends the reader's money, so it is said out loud rather
        // than happening quietly behind the terminal.
        #expect(
            Self.explanations(in: runner).contains {
                $0.contains("carrying on with the credential you connected")
            },
            "nothing in the transcript told the reader Iris had moved onto their credential"
        )
    }

    // MARK: - Uncapped is not unbounded

    /// The other half of the founder's decision: taking publik's spend cap off
    /// the reader's own credential must not turn the ladder into something that
    /// runs forever. The guard is about PROGRESS, not spend — the
    /// `MaintainTierCFixer.noProgressStepThreshold` precedent — so here every
    /// repair runs cleanly and fixes nothing, which is the real "going in
    /// circles" shape, and Iris must stop asking.
    @Test("on the reader's own credential the ladder still stops when it is getting nowhere")
    func aLadderThatIsGettingNowhereStillStops() async {
        let shell = RepairableFakeShell()
        let proposer = CorrectlyDiagnosingProposer()
        proposer.everyRepairThisModelProposesIsWrong = true
        let runner = Self.runnerOnTheReadersOwnCredential(shell: shell, proposer: proposer)

        for index in 0..<Self.stepsInTheInstall {
            _ = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }

        // Five steps spent on, two rungs each, and then the guard: no more
        // model calls for the remaining twelve steps of the install.
        let mostCallsAGoingNowhereLadderMaySpend =
            GuideAutopilotRunner.maximumConsecutiveStepsTheLadderMaySpendOnWithoutGettingOneRunning
            * GuideAutopilotRunner.maximumFixAttemptsPerStep
        print("[guard] model calls before Iris stopped: \(proposer.timesTheLadderAskedTheModel)")

        #expect(
            proposer.timesTheLadderAskedTheModel <= mostCallsAGoingNowhereLadderMaySpend,
            "the ladder kept spending the reader's money on an install it was getting nowhere with"
        )
        #expect(
            Self.explanations(in: runner).contains { $0.contains("going in circles") },
            "Iris stopped without telling the reader why it stopped"
        )
        // And it must not have reached for publik's sentence: nothing about
        // publik's budget is true on the reader's own credential.
        #expect(
            !Self.explanations(in: runner).contains {
                $0.contains(Self.budgetExhaustedSentenceFragment)
            },
            "the progress guard fired but Iris blamed publik's budget"
        )
    }
}
