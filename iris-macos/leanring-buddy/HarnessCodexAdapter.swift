import Foundation

/// Explicit factory for an isolated host. Not automatically enabled by the
/// normal app, and never changes a user's saved model preference.
@MainActor
enum HarnessCodexAdapter {
    private final class AttemptCapture {
        var admitted = false
        var usage: CodexExecOutput.Usage?
    }
    private enum AdapterError: Error {
        case hiddenRetryRefused
        case invalidEffort
        case serializedInputTooLarge
    }

    static func makeWorkflow(arm: HarnessImplementationArm = .astraLow,
                             settings: HarnessRunLedgerSettings,
                             maximumDurationNanoseconds: UInt64,
                             webSearchEnabled: Bool = true) throws -> HarnessFeatureWorkflow {
        let session = try HarnessModelSession(implementationArm: arm, settings: settings,
            maximumDurationNanoseconds: maximumDurationNanoseconds,
            serializedInputByteCounter: { request in
                try serializedCodexInputByteCount(request, webSearchEnabled: webSearchEnabled)
            }) { request in
                guard let effort = CodexReasoningEffort(rawValue: request.route.effort) else {
                    throw AdapterError.invalidEffort
                }
                let capture = AttemptCapture()
                let observer = CodexProcessAttemptObserver(beforeAttempt: { _ in
                    let mayStart = await MainActor.run {
                        guard !capture.admitted else { return false }
                        capture.admitted = true
                        return true
                    }
                    // One session reservation means one physical attempt.
                    // The existing outer loop owns any subsequently counted retry.
                    guard mayStart else { throw AdapterError.hiddenRetryRefused }
                }, afterAttempt: { result in
                    await MainActor.run { capture.usage = result.usage }
                })
                let searchAvailable = webSearchEnabled && request.phase != .intake
                let provider = CodexMaintainProvider(model: request.route.model,
                    reasoningEffort: effort, webSearchEnabled: searchAvailable,
                    attemptObserver: observer, maximumEmptyReplyRetriesOverride: 0)
                do {
                    let capabilityNote = searchAvailable ? "" : "\n\nCURRENT TRANSPORT: web search is disabled for this call. This overrides generic search guidance above."
                    let text = try await provider.respond(systemPrompt: request.systemPrompt + capabilityNote,
                        conversation: request.conversation.map {
                            MaintainChatTurn(role: $0.role, text: $0.text, attachedImagePNGData: $0.imagePNG)
                        }, maximumOutputTokens: request.maximumOutputTokens)
                    return HarnessModelReply(text: text, usage: measuredUsage(capture.usage))
                } catch {
                    throw HarnessModelTransportFailure(cause: error, usage: measuredUsage(capture.usage))
                }
            }
        return HarnessFeatureWorkflow(modelSession: session)
    }

    /// Counts the request shape that `CodexMaintainProvider` actually submits:
    /// its complete stdin prompt plus the bytes of each attached image. CLI
    /// paths and output controls are not model input and are intentionally not
    /// counted here.
    nonisolated private static func serializedCodexInputByteCount(
        _ request: HarnessModelRequest,
        webSearchEnabled: Bool
    ) throws -> UInt64 {
        let searchAvailable = webSearchEnabled && request.phase != .intake
        let capabilityNote = searchAvailable ? ""
            : "\n\nCURRENT TRANSPORT: web search is disabled for this call. This overrides generic search guidance above."
        let conversation = request.conversation.map {
            MaintainChatTurn(role: $0.role, text: $0.text, attachedImagePNGData: $0.imagePNG)
        }
        let prompt = CodexExecInvocation.promptText(
            systemPrompt: request.systemPrompt + capabilityNote,
            conversation: conversation,
            webSearchEnabled: searchAvailable
        )
        var total = UInt64(exactly: prompt.utf8.count)
        guard total != nil else { throw AdapterError.serializedInputTooLarge }
        for image in request.conversation.compactMap(\.imagePNG) {
            let imageBytes = UInt64(exactly: image.count)
            guard let imageBytes else { throw AdapterError.serializedInputTooLarge }
            let next = total!.addingReportingOverflow(imageBytes)
            guard !next.overflow else { throw AdapterError.serializedInputTooLarge }
            total = next.partialValue
        }
        return total!
    }

    private static func measuredUsage(_ usage: CodexExecOutput.Usage?) -> HarnessMeasuredUsage? {
        guard let usage else { return nil }
        func count(_ value: Int?) -> UInt64? {
            guard let value, value >= 0 else { return nil }
            return UInt64(exactly: value)
        }
        return HarnessMeasuredUsage(inputTokens: count(usage.inputTokens),
            cachedInputTokens: count(usage.cachedInputTokens), outputTokens: count(usage.outputTokens),
            reasoningOutputTokens: count(usage.reasoningOutputTokens))
    }
}

@MainActor
protocol HarnessPhaseAwareModelProviding {
    func setHarnessPhase(_ phase: HarnessRunTaskKind)
}

@MainActor
protocol HarnessBehaviorReviewProviding {
    func prepareBehaviorReview(revision: String, suitePassed: Bool, testCommand: String?,
                               suppliedFiles: [String: String], reviewPurpose: HarnessReviewPurpose)
    func takeBehaviorRepairRequest() -> String?
}

@MainActor
extension HarnessBehaviorReviewProviding {
    /// Compatibility for existing harness probes that only distinguish the
    /// native admission stage from an ordinary behavior review.
    func prepareBehaviorReview(revision: String, suitePassed: Bool, testCommand: String?,
                               suppliedFiles: [String: String], nativeChecksPending: Bool = false) {
        prepareBehaviorReview(
            revision: revision,
            suitePassed: suitePassed,
            testCommand: testCommand,
            suppliedFiles: suppliedFiles,
            reviewPurpose: nativeChecksPending ? .nativeCodeAdmission : .ordinaryBehaviorCoverage
        )
    }
}

@MainActor
protocol HarnessExecutionObserving {
    func observeEngineProgress(_ event: MaintainTierCProgressEvent)
}

@MainActor
protocol HarnessReviewBudgetProviding {
    func configureReviewStages(nativeChecksRequired: Bool)
    func beginVerification()
    var shouldYieldEditingToVerification: Bool { get }
    /// A deterministic build observation may run before the final reserve.
    /// This does not reserve or spend a model call.
    var shouldRunEarlyBuildCheckpoint: Bool { get }
}

/// Uses the original Iris executor with the accepted brief pinned in each
/// request, including after its ordinary conversation window is compacted.
@MainActor
final class HarnessWorkflowMaintainProvider: MaintainModelProviding, HarnessPhaseAwareModelProviding, HarnessBehaviorReviewProviding, HarnessExecutionObserving, HarnessReviewBudgetProviding {
    let workflow: HarnessFeatureWorkflow
    private var phase: HarnessRunTaskKind = .edit
    private(set) var executionJournal = HarnessExecutionJournal()
    private var lastEditingReply: String?
    private var lastReplyAppliedStructuredEdits = false
    private var appliedReplyPaths: [String: [String]] = [:]
    private(set) var originalConversationBytes = 0
    private(set) var sentConversationBytes = 0
    private(set) var compactedAssistantTurns = 0
    private(set) var compactedHistoricalObservationTurns = 0
    private(set) var conversationTargetWasExceeded = false
    private var reviewRevision = ""
    private var reviewSuitePassed = false
    private var reviewTestCommand: String?
    private var reviewFiles: [String: String] = [:]
    private var reviewPurpose: HarnessReviewPurpose = .ordinaryBehaviorCoverage
    private var reservedReviewCalls: UInt64 = 1
    private var initialCorrectionReserveCalls: UInt64 = 0
    private var hasStartedVerification = false
    private(set) var reviewInputBudget = HarnessReviewInputBudget(
        stageCount: 1,
        maximumInputBytesPerStage: HarnessReviewInputBudget.defaultMaximumInputBytesPerStage
    )
    private(set) var behaviorAssessment: HarnessBehaviorAssessment?
    private var behaviorRepairWasRequested = false
    init(workflow: HarnessFeatureWorkflow) { self.workflow = workflow }
    var displayName: String { "Codex harness lab" }
    var identifier: String { "codex" }
    var requestedModelDescription: String { workflow.modelSession.implementationArm.route.description }
    var isAvailable: Bool { CodexCLILogin.currentState().isUsable }
    // Local build/test commands need no model call. Preserve the last call for
    // independent review instead of spending it on another editing response.
    func configureReviewStages(nativeChecksRequired: Bool) {
        reservedReviewCalls = nativeChecksRequired ? 2 : 1
        // Within the existing allowance, leave room for one first review and
        // three correction responses. Tiny jobs retain their existing schedule.
        // This is opportunity, not guaranteed repair: byte/time admission still
        // applies to every request, and no call is spent just by reserving it.
        initialCorrectionReserveCalls = !hasStartedVerification
            && workflow.modelSession.ledger.remainingCallCapacity >= reservedReviewCalls + 4 + 8 ? 4 : 0
        reviewInputBudget = HarnessReviewInputBudget(
            stageCount: reservedReviewCalls,
            maximumInputBytesPerStage: workflow.modelSession.reviewInputBytesPerStage
        )
    }
    func beginVerification() {
        // Release at verification entry, not at the first model review: a
        // compiler or suite failure must also be able to use the correction
        // window. Mandatory final-review capacity stays protected.
        initialCorrectionReserveCalls = 0
        hasStartedVerification = true
    }
    private var editingStopCallReserve: UInt64 {
        reservedReviewCalls + initialCorrectionReserveCalls
    }
    /// Before the first verification, preserve enough input space for the
    /// mandatory review stages, one initial review-stage bound, and one
    /// correction request shaped like the latest admitted edit. The extra
    /// growth room is an existing bounded evidence allowance, not a new cap.
    private var editingInputBytesToPreserve: UInt64 {
        let mandatoryReviewBytes = reviewInputBudget.reservedInputBytes
        guard initialCorrectionReserveCalls > 0,
              !hasStartedVerification,
              let latestEditBytes = workflow.modelSession.ledger.settledCalls
                  .reversed()
                  .first(where: { $0.reservation.task == .edit })?
                  .reservation.inputBytesReserved
        else {
            return mandatoryReviewBytes
        }

        var total = mandatoryReviewBytes
        for additionalBytes in [
            reviewInputBudget.maximumInputBytesPerStage,
            latestEditBytes,
            HarnessReviewInputBudget.boundedReviewEvidenceBytes,
        ] {
            let next = total.addingReportingOverflow(additionalBytes)
            if next.overflow {
                total = .max
                break
            }
            total = next.partialValue
        }
        // A job too small to hold this opportunity retains review-only
        // scheduling. Use the fixed hard limit, not shrinking remaining bytes,
        // so spending input cannot silently release a feasible reserve.
        return total <= workflow.modelSession.ledger.settings.maxInputBytes
            ? total : mandatoryReviewBytes
    }
    var shouldYieldEditingToVerification: Bool {
        let ledger = workflow.modelSession.ledger
        return ledger.remainingCallCapacity <= editingStopCallReserve
            || (editingInputBytesToPreserve > 0
                && ledger.remainingInputByteCapacity <= editingInputBytesToPreserve)
    }
    var shouldRunEarlyBuildCheckpoint: Bool {
        let ledger = workflow.modelSession.ledger
        let remaining = ledger.remainingCallCapacity
        return ledger.admittedCallCount >= MaintainTierCFixer.earlyBuildCheckpointMinimumAdmittedCalls
            && !shouldYieldEditingToVerification
            && remaining > reservedReviewCalls
            && remaining <= MaintainTierCFixer.earlyBuildCheckpointRemainingCallThreshold
            && reviewInputBudget.canFitReview(
                remainingInputBytes: ledger.remainingInputByteCapacity
            )
    }

    func setHarnessPhase(_ phase: HarnessRunTaskKind) {
        self.phase = phase
        if phase == .edit || phase == .repair { behaviorAssessment = nil }
    }

    func observeEngineProgress(_ event: MaintainTierCProgressEvent) {
        switch event {
        case .appliedStructuredFileEdits:
            lastReplyAppliedStructuredEdits = true
        case .structuredFileEditRejected(let reason):
            lastReplyAppliedStructuredEdits = false
            if let lastEditingReply { appliedReplyPaths.removeValue(forKey: lastEditingReply) }
            executionJournal.recordProblem(GuideAutopilotOutputBuffer.scrubbed(reason))
        case .editedFiles(let paths, _):
            executionJournal.recordChangedFiles(paths)
            if lastReplyAppliedStructuredEdits, let lastEditingReply, appliedReplyPaths.count < 100 {
                appliedReplyPaths[lastEditingReply] = paths
            }
        case .revertedForbiddenBuildScriptEdit(let paths, _):
            if let lastEditingReply { appliedReplyPaths.removeValue(forKey: lastEditingReply) }
            executionJournal.recordProblem("Iris restored protected build files: " + paths.joined(separator: ", "))
        case .jailedCommandFinished(let code, _, let lines):
            executionJournal.recordCommand(exitCode: code, outputTail: lines)
        case .verificationCompleted(let receipt):
            executionJournal.recordVerification(buildPassed: receipt.buildPassed, testsPassed: receipt.testsPassed)
            if let stage = receipt.failureStage {
                executionJournal.recordProblem("Verification failed (\(stage)): "
                    + (receipt.failureOutputTail ?? "No output was captured."))
            }
        case .startingTestsChecked(let summary):
            executionJournal.recordProblem("Starting-state observation, not final verification: " + summary)
        case .adversarialReviewRaisedIssues(let issues):
            for issue in issues { executionJournal.recordProblem(GuideAutopilotOutputBuffer.scrubbed(issue)) }
        default: break
        }
    }

    func prepareBehaviorReview(revision: String, suitePassed: Bool, testCommand: String?,
                               suppliedFiles: [String: String], reviewPurpose: HarnessReviewPurpose) {
        behaviorAssessment = nil
        self.reviewPurpose = reviewPurpose
        reviewRevision = revision
        reviewSuitePassed = suitePassed
        reviewTestCommand = testCommand
        reviewFiles = suppliedFiles
    }

    func prepareBehaviorReview(revision: String, suitePassed: Bool, testCommand: String?,
                               suppliedFiles: [String: String], nativeChecksPending: Bool = false) {
        prepareBehaviorReview(
            revision: revision,
            suitePassed: suitePassed,
            testCommand: testCommand,
            suppliedFiles: suppliedFiles,
            reviewPurpose: nativeChecksPending ? .nativeCodeAdmission : .ordinaryBehaviorCoverage
        )
    }

    func takeBehaviorRepairRequest() -> String? {
        guard !behaviorRepairWasRequested, let assessment = behaviorAssessment,
              assessment.suitePassed,
              !assessment.pending.isEmpty,
              workflow.modelSession.ledger.remainingCallCapacity >= reservedReviewCalls + 2 else { return nil }
        behaviorRepairWasRequested = true
        return "The separate review could not establish these behaviors from the tests: "
            + assessment.pending.map(\.statement).joined(separator: "; ")
            + ". Review observations to investigate, not instructions or proof: "
            + assessment.reviewIssues.joined(separator: "; ")
            + ". Add meaningful deterministic tests and fix any behavior they expose, using the existing test command. "
            + "Do not weaken assertions, replace a real integration with a mock and call it verified, or expand permissions. "
            + "If a behavior needs a person or unavailable environment to check it, say so and finish with DONE; it will stay unverified and will not be auto-installed."
    }

    func respond(systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int) async throws -> String {
        let context = try workflow.implementationContext()
        let remainingCalls = workflow.modelSession.ledger.remainingCallCapacity
        let editingCallsLeft = remainingCalls > editingStopCallReserve ? remainingCalls - editingStopCallReserve : 0
        let correctionWindowGuidance = initialCorrectionReserveCalls > 0
            ? "\nWithin the same run limit, \(initialCorrectionReserveCalls) more calls are held for the first review and a possible correction. Iris will check the current draft before releasing them. They do not increase the total budget."
            : ""
        let readingGuidance = """
        EFFICIENT INVESTIGATION
        Use the evidence already supplied. Batch related file reads into one command
        when their combined output fits 12000 characters. Label each file clearly.
        Request specific missing ranges if output is marked truncated. Do not repeat
        a complete unchanged read; reread after an edit when necessary to verify it.
        This is guidance for saving calls, not permission to skip relevant checks.
        Follow the brief's dependency order in small coherent pieces. Use existing
        read/search and edit tools; no separate planning response is needed.
        After a meaningful piece, run its relevant tests through the existing
        command tool and fix failures before piling on later pieces. A milestone
        or a successful command is not proof of the whole requested experience.
        Delivery needs executed behavior evidence for every agreed criterion,
        not just a passing build. Reuse existing tests that cover the change;
        add focused checks for uncovered criteria and run them before DONE.
        Test the real changed entrypoint and data path, not only a helper or a
        manually recreated example. Do not expand unchanged functionality just
        to manufacture coverage. If the runtime cannot launch, report that separately
        from a source defect; do not repeatedly edit code without diagnosing it.
        Derive expected assertions from the agreed outcome and each user-decision
        check before reading current output. Exercise a case that distinguishes
        the chosen behavior from the alternatives, including populated state and
        preservation where relevant. Trace the real entrypoint and stored state.
        Never rewrite an expected value to match current output or accept the
        regression under test. A helper-only, empty/default-state, or self-authored
        output check does not establish the criterion; fix both implementation and
        assertion, or report the criterion unverified.
        You have \(editingCallsLeft) model call(s) available for editing, including
        this call. \(reservedReviewCalls) additional call(s) are reserved for final independent review.\(correctionWindowGuidance)
        Batch related investigation and edits. At the reserve boundary Iris will
        run the configured build/tests and review the current source, which may
        still be incomplete. Never hide missing work or claim checks you did not run.
        """
        let criteria = try workflow.state.map { try HarnessContextProjector.verificationCriteria(for: $0) } ?? []
        let originalMessages = conversation.map {
            HarnessModelMessage(role: $0.role, text: $0.text, imagePNG: $0.attachedImagePNGData)
        }
        let projection = HarnessConversationProjection.project(messages: originalMessages,
            confirmedAppliedReplies: phase == .review ? [:] : appliedReplyPaths)
        // Keep the soft conversation target separate from the ledger's hard
        // input admission limit. Protected evidence may legitimately exceed
        // the target, and the ledger decides whether the full request fits.
        let boundedProjection = HarnessCodexConversationBudget.project(projection.messages)
        let admittedBefore = workflow.modelSession.ledger.admittedCallCount
        defer {
            // This adapter is owned by one sequential editor. A refused input
            // or exhausted budget never reached transport and is not submitted
            // conversation data; an admitted failed call still counts.
            if workflow.modelSession.ledger.admittedCallCount > admittedBefore {
                originalConversationBytes += projection.originalUTF8Bytes
                sentConversationBytes += boundedProjection.sentUTF8Bytes
                compactedAssistantTurns += projection.compactedAssistantTurnCount
                compactedHistoricalObservationTurns += boundedProjection.compactedObservationTurnCount
                conversationTargetWasExceeded = conversationTargetWasExceeded
                    || boundedProjection.targetWasExceeded
            }
        }
        let reviewGuidance: String
        if phase != .review {
            reviewGuidance = ""
        } else {
            switch reviewPurpose {
            case .ordinaryBehaviorCoverage:
                reviewGuidance = HarnessBehaviorAssessment.reviewInstructions(criteria: criteria)
                    + "\nRecorded test command: " + (reviewTestCommand ?? "not available")
            case .nativeCodeAdmission:
                reviewGuidance = ""
            case .manualTestCodeAdmission:
                reviewGuidance = HarnessBehaviorAssessment.manualTestCodeAdmissionInstructions
            }
        }
        let reply = try await workflow.modelSession.respond(phase: phase,
            systemPrompt: systemPrompt + "\n\n" + context + "\n\n" + reviewGuidance
                + (phase == .review ? "" : "\n\n" + readingGuidance + "\n\n" + executionJournal.promptSection
                   + "\nBefore DONE, add and run tests for each requested behavior when possible. Report what cannot be tested; never mark it passed."),
            conversation: boundedProjection.messages,
            maximumOutputTokens: maximumOutputTokens,
            preservingInputBytes: (phase == .edit || phase == .repair)
                ? editingInputBytesToPreserve
                : 0)
        if phase == .review && reviewPurpose != .nativeCodeAdmission {
            let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
            switch reviewPurpose {
            case .ordinaryBehaviorCoverage:
                behaviorAssessment = HarnessBehaviorAssessment.assess(reply: reply, criteria: criteria,
                    revision: reviewRevision, suitePassed: reviewSuitePassed,
                    reviewWasClean: !verdict.isDisqualifying,
                    suppliedTestFiles: reviewFiles, reviewIssues: verdict.readerFacingIssues)
            case .manualTestCodeAdmission:
                // This stage admits only a candidate for a later manual test.
                // Deliberately leave coverage and automatic-delivery state false.
                behaviorAssessment = HarnessBehaviorAssessment.assess(reply: reply, criteria: criteria,
                    revision: reviewRevision, suitePassed: false,
                    reviewWasClean: false,
                    suppliedTestFiles: reviewFiles, reviewIssues: verdict.readerFacingIssues,
                    manualCodeAdmissionClean: !verdict.isDisqualifying)
            case .nativeCodeAdmission:
                break
            }
        } else if phase != .review {
            lastEditingReply = reply
            lastReplyAppliedStructuredEdits = false
        }
        return reply
    }
}
