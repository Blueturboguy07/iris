import Foundation
import Testing
@testable import IrisHarness

private func harnessBriefJSON(
    _ brief: HarnessTaskBrief,
    resolvedQuestionIDs: [String]? = nil
) throws -> String {
    let encoded = try JSONEncoder().encode(brief)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw NSError(domain: "HarnessClarificationWorkflowTests", code: 1)
    }
    if let resolvedQuestionIDs {
        object["resolvedQuestionIDs"] = resolvedQuestionIDs
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@Test @MainActor
func freeTextAnswersStaySynchronousUntilExplicitRefinement() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once in the selected field")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ],
        milestones: [.init(id: "target", title: "Identify the destination")]
    )
    let refinedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the named tab without sending them",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once in the selected field"),
            .init(id: "no-send", statement: "Inserting a note never presses Send")
        ],
        targetedQuestions: [
            .init(
                id: "ambiguity",
                prompt: "If two tabs match, what should Iris do?",
                options: [
                    .init(id: "ask", label: "Ask me which tab"),
                    .init(id: "cancel", label: "Leave the note ready and stop")
                ]
            )
        ],
        milestones: [
            .init(id: "target", title: "Identify the current destination"),
            .init(id: "insert", title: "Insert without sending", dependencies: ["target"])
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let refinedJSON = try harnessBriefJSON(refinedBrief, resolvedQuestionIDs: ["destination"])
    var replies = [initialJSON, refinedJSON]
    var captured: [HarnessModelRequest] = []
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 4, maxInputBytes: 100_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { input in
        captured.append(input)
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs and editable fields")
    try workflow.recordFreeTextAnswer(
        questionID: "destination",
        answer: "Find the tab whose title contains my Iris bug report"
    )
    #expect(captured.count == 1)
    #expect(workflow.state?.userDecisions.first?.optionID == nil)
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.unansweredQuestions) {
        try workflow.implementationContext()
    }

    let refined = try await workflow.refineBrief(repositoryEvidence: "The browser exposes stable tab IDs.")

    #expect(captured.count == 2)
    #expect(captured[1].route == .planner)
    #expect(captured[1].conversation[0].text.contains(request))
    #expect(captured[1].conversation[0].text.contains("Find the tab whose title contains my Iris bug report"))
    #expect(captured[1].conversation[0].text.contains("The browser exposes stable tab IDs."))
    #expect(captured[1].conversation[0].text.contains("priorExplicitAnswersAndCorrections"))
    #expect(refined.userRequest == request)
    #expect(refined.desiredOutcome == refinedBrief.desiredOutcome)
    #expect(refined.acceptanceCriteria.map(\.id) == ["insert-once", "no-send"])
    #expect(refined.targetedQuestions.map(\.id) == ["ambiguity"])
    let proposal = try #require(workflow.pendingScopeReconciliation)
    #expect(proposal.addedCriteria.map(\.id) == ["no-send"])
    #expect(workflow.state?.brief.acceptanceCriteria.map(\.id) == ["insert-once"])
    #expect(workflow.state?.brief.targetedQuestions.map(\.id) == ["destination"])
    #expect(workflow.state?.userDecisions.first?.answer == "Find the tab whose title contains my Iris bug report")
    #expect(workflow.clarificationRoundCount == 2)

    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        try workflow.implementationContext()
    }
    let approved = try workflow.approveScopeReconciliation(id: proposal.id)
    #expect(approved.brief.acceptanceCriteria.map(\.id) == ["insert-once", "no-send"])
    #expect(approved.brief.targetedQuestions.map(\.id) == ["destination", "ambiguity"])
    #expect(workflow.pendingScopeReconciliation == nil)
    try workflow.recordAnswer(
        questionID: "ambiguity",
        optionID: "ask",
        answer: "Ask me which tab"
    )
    #expect(try workflow.implementationContext().contains("no-send"))
    #expect(captured.count == 2)
}

@Test @MainActor
func refinementCannotSilentlyReplaceReaderOutcomeWhenCriteriaAreUnchanged() async throws {
    let request = "Keep my notes visible after saving."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Keep my notes visible after saving",
        acceptanceCriteria: [
            .init(id: "visible", statement: "The saved note remains visible")
        ],
        milestones: [
            .init(id: "save", title: "Keep the saved note visible")
        ]
    )
    let rewrittenBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Delete my notes after saving",
        acceptanceCriteria: [
            .init(id: "visible", statement: "The saved note remains visible")
        ],
        milestones: [
            .init(id: "save", title: "Keep the saved note visible")
        ]
    )
    var replies = [
        String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(rewrittenBrief), as: UTF8.self)
    ]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "notes list")
    let refined = try await workflow.refineBrief(repositorySummary: "notes list")

    #expect(refined.desiredOutcome == initialBrief.desiredOutcome)
    #expect(workflow.pendingScopeReconciliation == nil)
    #expect(workflow.state?.brief.desiredOutcome == initialBrief.desiredOutcome)
    #expect(workflow.state?.brief.acceptanceCriteria == initialBrief.acceptanceCriteria)
}

@Test @MainActor
func unknownAndPartialFreeTextAnswersRemainPending() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let briefJSON = try harnessBriefJSON(brief)
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: briefJSON) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    for answer in [
        "I don't know",
        "Use the Notes tab, but I don't know which field"
    ] {
        try workflow.recordFreeTextAnswer(questionID: "destination", answer: answer)
        #expect(workflow.state?.userDecisions.first?.answer == answer)
        #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
        #expect(throws: HarnessFeatureWorkflow.WorkflowError.unansweredQuestions) {
            try workflow.implementationContext()
        }
    }
    #expect(session.ledger.snapshot.admittedCallCount == 1)
}

@Test @MainActor
func echoedRefinementDoesNotResolveUnknownFreeText() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let briefJSON = try harnessBriefJSON(brief)
    let emptyResolutionJSON = try harnessBriefJSON(brief, resolvedQuestionIDs: [])
    var replies = [briefJSON, briefJSON, emptyResolutionJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    try workflow.recordFreeTextAnswer(questionID: "destination", answer: "I don't know")
    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")

    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.unansweredQuestions) {
        try workflow.implementationContext()
    }
    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.unansweredQuestions) {
        try workflow.implementationContext()
    }
    #expect(workflow.state?.userDecisions.first?.answer == "I don't know")
    #expect(session.ledger.snapshot.admittedCallCount == 3)
}

@Test @MainActor
func explicitResolutionAllowsFreeTextToPassWithoutAnotherCall() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let initialJSON = try harnessBriefJSON(brief)
    let resolvedJSON = try harnessBriefJSON(brief, resolvedQuestionIDs: ["destination"])
    var replies = [initialJSON, resolvedJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    try workflow.recordFreeTextAnswer(
        questionID: "destination",
        answer: "Find the tab whose title contains my Iris bug report"
    )
    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")

    #expect(workflow.unansweredQuestionIDs.isEmpty)
    #expect(try workflow.implementationContext().contains("Iris bug report"))
    #expect(session.ledger.snapshot.admittedCallCount == 2)
}

@Test @MainActor
func selectedOptionRemainsASynchronousLocalFastPath() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let briefJSON = try harnessBriefJSON(brief)
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: briefJSON) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    try workflow.recordAnswer(
        questionID: "destination",
        optionID: "selected",
        answer: "Use the tab I selected"
    )

    #expect(workflow.unansweredQuestionIDs.isEmpty)
    #expect(try workflow.implementationContext().contains("Use the tab I selected"))
    #expect(session.ledger.snapshot.admittedCallCount == 1)
}

@Test @MainActor
func unresolvedQuestionIDCanBeRephrasedWithoutLosingFreeText() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let rephrasedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "When no tab is an exact match, what should Iris do?",
                options: [
                    .init(id: "ask", label: "Ask me to choose a tab"),
                    .init(id: "stop", label: "Leave the note ready and stop")
                ]
            )
        ]
    )
    var replies = [
        try harnessBriefJSON(initialBrief),
        try harnessBriefJSON(rephrasedBrief)
    ]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    let answer = "I am not sure which tab is intended"
    try workflow.recordFreeTextAnswer(questionID: "destination", answer: answer)
    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")

    #expect(workflow.state?.brief.targetedQuestions.first?.prompt == rephrasedBrief.targetedQuestions[0].prompt)
    #expect(workflow.state?.brief.targetedQuestions.first?.options == rephrasedBrief.targetedQuestions[0].options)
    #expect(workflow.state?.userDecisions.first?.answer == answer)
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
}

@Test @MainActor
func changedAnswerStartsNewRevisionAndInvalidatesCurrentEvidence() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let briefJSON = try harnessBriefJSON(brief)
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: briefJSON) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    try workflow.recordAnswer(
        questionID: "destination",
        optionID: "named",
        answer: "Find the tab I name"
    )
    let oldRevision = try #require(workflow.state?.activeRevisionID)
    let evidence = HarnessEvidenceRecord(
        key: HarnessEvidenceKey(revisionID: oldRevision, checkID: "insert-once"),
        result: .passed,
        summary: "The fixture inserted the note once"
    )
    try workflow.recordEvidence(evidence)
    try workflow.resolveAcceptanceCriterion("insert-once", using: evidence.key)

    try workflow.recordAnswer(
        questionID: "destination",
        optionID: "selected",
        answer: "Use the tab I selected"
    )

    let updatedState = try #require(workflow.state)
    #expect(updatedState.activeRevisionID != oldRevision)
    #expect(updatedState.currentEvidence.isEmpty)
    #expect(updatedState.resolvedAcceptanceCriterionIDs.isEmpty)
    #expect(updatedState.evidence == [evidence])
    #expect(updatedState.userDecisions.first?.optionID == "selected")
    #expect(session.ledger.snapshot.admittedCallCount == 1)
}

@Test @MainActor
func invalidResolutionIDsAreRejected() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )

    func expectInvalidResolution(
        _ resolvedQuestionIDs: [String],
        recordFreeText: Bool
    ) async throws {
        let initialJSON = try harnessBriefJSON(brief)
        let refinementJSON = try harnessBriefJSON(brief, resolvedQuestionIDs: resolvedQuestionIDs)
        var replies = [initialJSON, refinementJSON]
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in HarnessModelReply(text: replies.removeFirst()) }
        let workflow = HarnessFeatureWorkflow(modelSession: session)

        _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
        if recordFreeText {
            try workflow.recordFreeTextAnswer(questionID: "destination", answer: "The tab with my notes")
        }
        await #expect(throws: HarnessFeatureWorkflow.WorkflowError.invalidQuestions) {
            _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")
        }
        #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    }

    try await expectInvalidResolution(["unknown"], recordFreeText: true)
    try await expectInvalidResolution(["destination", "destination"], recordFreeText: true)
    try await expectInvalidResolution(["destination"], recordFreeText: false)
}

@Test @MainActor
func scopeResolutionDoesNotClearPendingQuestionBeforeApproval() async throws {
    let request = "Put my spoken notes in the right browser tab."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once")
        ],
        targetedQuestions: [
            .init(
                id: "destination",
                prompt: "How should Iris choose the tab?",
                options: [
                    .init(id: "named", label: "Find the tab I name"),
                    .init(id: "selected", label: "Use the tab I selected")
                ]
            )
        ]
    )
    let proposedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Put notes in the intended tab without sending them",
        acceptanceCriteria: [
            .init(id: "insert-once", statement: "The note is inserted exactly once and never sent")
        ],
        targetedQuestions: initialBrief.targetedQuestions
    )
    let initialJSON = try harnessBriefJSON(initialBrief)
    let proposedJSON = try harnessBriefJSON(proposedBrief, resolvedQuestionIDs: ["destination"])
    var replies = [initialJSON, proposedJSON, proposedJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 4, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "browser tabs")
    try workflow.recordFreeTextAnswer(questionID: "destination", answer: "The tab with my notes")

    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")
    let firstProposal = try #require(workflow.pendingScopeReconciliation)
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    try workflow.rejectScopeReconciliation(id: firstProposal.id)
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.unansweredQuestions) {
        try workflow.implementationContext()
    }

    _ = try await workflow.refineBrief(repositorySummary: "The browser exposes stable tab IDs.")
    let secondProposal = try #require(workflow.pendingScopeReconciliation)
    #expect(workflow.unansweredQuestionIDs == Set(["destination"]))
    let approved = try workflow.approveScopeReconciliation(id: secondProposal.id)
    #expect(approved.brief.acceptanceCriteria.map(\.id) == ["insert-once"])
    #expect(workflow.unansweredQuestionIDs.isEmpty)
    #expect(try workflow.implementationContext().contains("The tab with my notes"))
}

@Test @MainActor
func threeAnsweredQuestionsCanReceiveTwoNewBatchesWithinTheHistoricalBound() async throws {
    let request = "Help me organize the records I review every day."
    func question(_ index: Int) -> HarnessTargetedQuestion {
        .init(
            id: "q\(index)",
            prompt: "Which choice applies to item \(index)?",
            options: [
                .init(id: "yes\(index)", label: "Use the first choice"),
                .init(id: "no\(index)", label: "Use the second choice")
            ]
        )
    }
    func brief(questions: [HarnessTargetedQuestion]) throws -> HarnessTaskBrief {
        try HarnessTaskBrief(
            userRequest: request,
            desiredOutcome: "Organize the records with my choices",
            acceptanceCriteria: [
                .init(id: "organize", statement: "The records are organized according to the accepted choices")
            ],
            targetedQuestions: questions
        )
    }
    let initialJSON = String(decoding: try JSONEncoder().encode(brief(questions: (1...3).map(question))), as: UTF8.self)
    let firstFollowUpJSON = String(decoding: try JSONEncoder().encode(brief(questions: (4...6).map(question))), as: UTF8.self)
    let secondFollowUpJSON = String(decoding: try JSONEncoder().encode(brief(questions: (7...9).map(question))), as: UTF8.self)
    var replies = [initialJSON, firstFollowUpJSON, secondFollowUpJSON]
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 5, maxInputBytes: 150_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "records repository")
    for index in 1...3 {
        try workflow.recordAnswer(
            questionID: "q\(index)",
            optionID: "yes\(index)",
            answer: "Use the first choice"
        )
    }
    #expect(try workflow.implementationContext().contains("q3"))

    _ = try await workflow.refineBrief(repositorySummary: "The records repository exposes stable IDs.")
    #expect(workflow.state?.brief.targetedQuestions.map(\.id) == (1...6).map { "q\($0)" })
    #expect(workflow.state?.userDecisions.count == 3)

    _ = try await workflow.refineBrief(repositorySummary: "The records repository exposes stable IDs.")
    #expect(workflow.state?.brief.targetedQuestions.map(\.id) == (1...9).map { "q\($0)" })
    #expect(workflow.clarificationRoundCount == 3)
    #expect(callCount == 3)

    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.clarificationRoundLimitReached) {
        _ = try await workflow.refineBrief(repositorySummary: "The records repository exposes stable IDs.")
    }
    #expect(callCount == 3)
}

@Test @MainActor
func refinementStagesRemovedCriteriaUntilTheReaderApproves() async throws {
    let request = "Make the importer safer for me."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Import records safely",
        acceptanceCriteria: [
            .init(id: "keep-data", statement: "Existing records are not overwritten")
        ],
        targetedQuestions: [
            .init(
                id: "duplicates",
                prompt: "What should happen to a duplicate?",
                options: [
                    .init(id: "keep", label: "Keep the existing record"),
                    .init(id: "replace", label: "Use the imported record")
                ]
            )
        ],
        milestones: [.init(id: "import", title: "Import records")]
    )
    let responseBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Import records with an explicit duplicate policy",
        acceptanceCriteria: [
            .init(id: "report", statement: "The import reports records it could not merge")
        ],
        targetedQuestions: [],
        milestones: [.init(id: "report", title: "Report unresolved records")]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let responseJSON = String(decoding: try JSONEncoder().encode(responseBrief), as: UTF8.self)
    var replies = [initialJSON, responseJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "importer and database adapter")
    try workflow.recordAnswer(questionID: "duplicates", optionID: "keep", answer: "Keep the existing record")
    try workflow.recordCorrection(
        id: "scope-correction",
        answer: "Do not change how records are displayed.",
        revision: "request-2"
    )
    let proposed = try await workflow.refineBrief(repositorySummary: "The adapter already reports rejected rows.")

    #expect(proposed.acceptanceCriteria.map(\.id) == ["report"])
    #expect(workflow.pendingScopeReconciliation?.removedCriteria.map(\.id) == ["keep-data"])
    #expect(workflow.pendingScopeReconciliation?.addedCriteria.map(\.id) == ["report"])
    #expect(workflow.state?.brief.acceptanceCriteria.map(\.id) == ["keep-data"])
    #expect(workflow.state?.brief.targetedQuestions.map(\.id) == ["duplicates"])
    #expect(workflow.state?.activeRevisionID == "request-2")
    #expect(workflow.state?.userDecisions.map(\.id) == ["duplicates", "scope-correction"])
    #expect(workflow.state?.userDecisions.last?.answer == "Do not change how records are displayed.")
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        try workflow.implementationContext()
    }

    let proposal = try #require(workflow.pendingScopeReconciliation)
    let approved = try workflow.approveScopeReconciliation(id: proposal.id)
    #expect(approved.brief.acceptanceCriteria.map(\.id) == ["report"])
    #expect(approved.activeRevisionID == "request-2-clarification-2")
    #expect(approved.brief.targetedQuestions.map(\.id) == ["duplicates"])
    #expect(approved.userDecisions.map(\.id) == [
        "duplicates",
        "scope-correction",
        proposal.id + "-decision"
    ])
    #expect(approved.userDecisions.last?.answer == "Approved the proposed scope for request-2-clarification-2.")
    #expect(workflow.pendingScopeReconciliation == nil)
}

@Test @MainActor
func refinementStagesChangedCriteriaAndApprovalInvalidatesOldEvidence() async throws {
    let request = "Keep the selected record visible after I save it."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Keep the saved record visible",
        acceptanceCriteria: [
            .init(id: "visible", statement: "Saving keeps the selected record visible")
        ],
        milestones: [
            .init(id: "legacy-step", title: "Use the old navigation path")
        ],
        modelAssumptions: [
            .init(id: "legacy-default", statement: "Assume the old navigation path is available")
        ]
    )
    let changedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Keep the saved record visible without navigating away",
        acceptanceCriteria: [
            .init(id: "visible", statement: "Saving keeps the selected record visible and does not navigate away")
        ],
        milestones: [
            .init(id: "replacement-step", title: "Check navigation stays put")
        ],
        modelAssumptions: [
            .init(id: "replacement-default", statement: "Assume the save action reports navigation state")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let changedJSON = String(decoding: try JSONEncoder().encode(changedBrief), as: UTF8.self)
    var replies = [initialJSON, changedJSON]
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "records screen")
    let oldRevision = try #require(workflow.state?.activeRevisionID)
    let oldEvidence = HarnessEvidenceRecord(
        key: HarnessEvidenceKey(revisionID: oldRevision, checkID: "visible"),
        result: .passed,
        summary: "The fixture kept the record visible"
    )
    try workflow.recordEvidence(oldEvidence)
    try workflow.resolveAcceptanceCriterion("visible", using: oldEvidence.key)

    _ = try await workflow.refineBrief(repositorySummary: "The save action now exposes navigation state.")
    let proposal = try #require(workflow.pendingScopeReconciliation)
    #expect(proposal.baseRevisionID == oldRevision)
    #expect(proposal.changedCriteria.map(\.id) == ["visible"])
    #expect(proposal.changedCriteria.first?.previousStatement == "Saving keeps the selected record visible")
    #expect(proposal.changedCriteria.first?.proposedStatement == "Saving keeps the selected record visible and does not navigate away")
    #expect(workflow.pendingScopeChanges.map(\.kind) == [.changed])
    #expect(workflow.state?.brief == initialBrief)
    #expect(workflow.state?.currentEvidence == [oldEvidence])
    #expect(workflow.state?.resolvedAcceptanceCriterionIDs == ["visible"])
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        try workflow.implementationContext()
    }

    let approved = try workflow.approveScopeReconciliation(id: proposal.id)
    #expect(callCount == 2)
    #expect(approved.activeRevisionID == proposal.proposedRevisionID)
    #expect(approved.brief.desiredOutcome == initialBrief.desiredOutcome)
    #expect(approved.brief.milestones.map(\.id) == ["replacement-step"])
    #expect(approved.brief.modelAssumptions.map(\.id) == ["replacement-default"])
    #expect(approved.currentEvidence.isEmpty)
    #expect(approved.resolvedAcceptanceCriterionIDs.isEmpty)
    #expect(approved.evidence == [oldEvidence])

    do {
        try workflow.recordEvidence(oldEvidence)
        Issue.record("Evidence from the previous revision must be rejected after approval")
    } catch let error as HarnessTaskStateError {
        #expect(error == .staleEvidence(expectedRevisionID: approved.activeRevisionID, actualRevisionID: oldRevision))
    }
}

@Test @MainActor
func scopeProposalIncludesExplicitNonGoalDelta() async throws {
    let request = "Prepare the report for me."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Prepare the report",
        explicitNonGoals: [],
        acceptanceCriteria: [
            .init(id: "prepare", statement: "The report is prepared for review")
        ]
    )
    let proposedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Prepare the report without publishing it",
        explicitNonGoals: ["Do not publish the report"],
        acceptanceCriteria: [
            .init(id: "prepare", statement: "The report is prepared for review")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let proposedJSON = String(decoding: try JSONEncoder().encode(proposedBrief), as: UTF8.self)
    var replies = [initialJSON, proposedJSON]
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "report editor")
    _ = try await workflow.refineBrief(repositorySummary: "The report editor has a publish button.")
    let proposal = try #require(workflow.pendingScopeReconciliation)
    #expect(proposal.changedCriteria.isEmpty)
    #expect(proposal.removedCriteria.isEmpty)
    #expect(proposal.nonGoalChanges == [
        .init(kind: .added, statement: "Do not publish the report")
    ])
    #expect(proposal.originalNonGoals.isEmpty)
    #expect(proposal.proposedNonGoals == ["Do not publish the report"])
    #expect(workflow.state?.brief == initialBrief)
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        try workflow.implementationContext()
    }

    let approved = try workflow.approveScopeReconciliation(id: proposal.id)
    #expect(callCount == 2)
    #expect(approved.brief.explicitNonGoals == ["Do not publish the report"])
    #expect(approved.activeRevisionID == proposal.proposedRevisionID)
    #expect(approved.userDecisions.last?.answer == "Approved the proposed scope for \(proposal.proposedRevisionID).")
}

@Test @MainActor
func rejectingScopeProposalKeepsTheOldPlanAndMakesNoApprovalCall() async throws {
    let request = "Keep my filter when I reopen the list."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Reopen the list with the filter",
        acceptanceCriteria: [
            .init(id: "filter", statement: "Reopening restores the saved filter")
        ]
    )
    let changedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Reopen the list with the filter",
        acceptanceCriteria: [
            .init(id: "filter", statement: "Reopening restores the saved filter and clears no other choices")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let changedJSON = String(decoding: try JSONEncoder().encode(changedBrief), as: UTF8.self)
    var replies = [initialJSON, changedJSON]
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 4, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "list screen")
    _ = try await workflow.refineBrief(repositorySummary: "list screen")
    let beforeReject = try #require(workflow.state)
    let proposalID = try #require(workflow.pendingScopeReconciliationID)

    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationNotFound) {
        try workflow.rejectScopeReconciliation(id: "stale-proposal")
    }
    #expect(workflow.pendingScopeReconciliationID == proposalID)
    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        _ = try await workflow.refineBrief(repositorySummary: "list screen")
    }
    #expect(callCount == 2)

    try workflow.rejectScopeReconciliation(id: proposalID)
    #expect(workflow.pendingScopeReconciliation == nil)
    #expect(workflow.state?.brief == beforeReject.brief)
    #expect(workflow.state?.activeRevisionID == beforeReject.activeRevisionID)
    #expect(workflow.state?.evidence == beforeReject.evidence)
    #expect(Array(workflow.state?.userDecisions.dropLast() ?? []) == beforeReject.userDecisions)
    #expect(workflow.state?.userDecisions.last?.answer == "Kept the previous scope for request-1-clarification-2.")
    #expect(try workflow.implementationContext().contains("saved filter"))
    #expect(callCount == 2)
}

@Test @MainActor
func malformedScopeResponseDoesNotCreateOrCommitAProposal() async throws {
    let request = "Show the selected item."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Show the selected item",
        acceptanceCriteria: [
            .init(id: "show", statement: "The selected item is shown")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let malformedJSON = """
    {
      "userRequest": "\(request)",
      "desiredOutcome": "Show the selected item differently",
      "explicitNonGoals": [],
      "acceptanceCriteria": [
        {"id": "show", "statement": "The selected item is shown differently", "unexpected": true}
      ],
      "targetedQuestions": [],
      "milestones": [],
      "modelAssumptions": []
    }
    """
    var replies = [initialJSON, malformedJSON]
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: replies.removeFirst())
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "list screen")
    let before = try #require(workflow.state)
    await #expect(throws: HarnessTaskStateError.self) {
        _ = try await workflow.refineBrief(repositorySummary: "list screen")
    }
    #expect(workflow.state == before)
    #expect(workflow.pendingScopeReconciliation == nil)
    #expect(workflow.clarificationRoundCount == 1)
    #expect(callCount == 2)
}

@Test @MainActor
func proposalIDCannotBeReusedAfterStartingANewPlan() async throws {
    let firstRequest = "Show the first item."
    let firstInitial = try HarnessTaskBrief(
        userRequest: firstRequest,
        desiredOutcome: "Show the first item",
        acceptanceCriteria: [
            .init(id: "show", statement: "The first item is shown")
        ]
    )
    let firstChanged = try HarnessTaskBrief(
        userRequest: firstRequest,
        desiredOutcome: "Show the first item clearly",
        acceptanceCriteria: [
            .init(id: "show", statement: "The first item is shown clearly")
        ]
    )
    let secondRequest = "Show the second item."
    let secondInitial = try HarnessTaskBrief(
        userRequest: secondRequest,
        desiredOutcome: "Show the second item",
        acceptanceCriteria: [
            .init(id: "show", statement: "The second item is shown")
        ]
    )
    let secondChanged = try HarnessTaskBrief(
        userRequest: secondRequest,
        desiredOutcome: "Show the second item clearly",
        acceptanceCriteria: [
            .init(id: "show", statement: "The second item is shown clearly")
        ]
    )
    var replies = [
        String(decoding: try JSONEncoder().encode(firstInitial), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(firstChanged), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(secondInitial), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(secondChanged), as: UTF8.self)
    ]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 5, maxInputBytes: 100_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: firstRequest, repositorySummary: "list screen")
    _ = try await workflow.refineBrief(repositorySummary: "list screen")
    let oldProposalID = try #require(workflow.pendingScopeReconciliationID)

    _ = try await workflow.plan(request: secondRequest, repositorySummary: "list screen")
    _ = try await workflow.refineBrief(repositorySummary: "list screen")
    let newProposal = try #require(workflow.pendingScopeReconciliation)
    #expect(newProposal.id != oldProposalID)
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationNotFound) {
        try workflow.approveScopeReconciliation(id: oldProposalID)
    }
    let approved = try workflow.approveScopeReconciliation(id: newProposal.id)
    #expect(approved.brief.userRequest == secondRequest)
    #expect(approved.activeRevisionID == newProposal.proposedRevisionID)
}

@Test @MainActor
func cancelledScopeRefinementCannotPublishAProposal() async throws {
    let request = "Show the selected item."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Show the selected item",
        acceptanceCriteria: [
            .init(id: "show", statement: "The selected item is shown")
        ]
    )
    let changedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Show the selected item without changing its selection",
        acceptanceCriteria: [
            .init(id: "show", statement: "The selected item is shown without changing its selection")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let changedJSON = String(decoding: try JSONEncoder().encode(changedBrief), as: UTF8.self)
    var releaseRefinement: CheckedContinuation<HarnessModelReply, Never>?
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 2_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        if callCount == 2 {
            return await withCheckedContinuation { continuation in
                releaseRefinement = continuation
            }
        }
        return HarnessModelReply(text: callCount == 1 ? initialJSON : changedJSON)
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "list screen")
    let before = try #require(workflow.state)
    let refinementTask = Task { try await workflow.refineBrief(repositorySummary: "list screen") }
    while releaseRefinement == nil {
        await Task.yield()
    }
    refinementTask.cancel()
    releaseRefinement?.resume(returning: HarnessModelReply(text: changedJSON))

    await #expect(throws: CancellationError.self) {
        _ = try await refinementTask.value
    }
    #expect(workflow.state == before)
    #expect(workflow.pendingScopeReconciliation == nil)
    #expect(workflow.clarificationRoundCount == 1)
    #expect(callCount == 2)
}

@Test @MainActor
func clarificationFollowUpHasTwoBoundedFollowUps() async throws {
    let request = "Remember my preferred export format."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Remember the export format",
        acceptanceCriteria: [.init(id: "remember", statement: "The next export uses the chosen format")]
    )
    let encodedBrief = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 4, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        return HarnessModelReply(text: encodedBrief)
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "settings store")
    _ = try await workflow.refineBrief(repositorySummary: "settings store")
    #expect(workflow.clarificationRoundCount == 2)
    _ = try await workflow.refineBrief(repositorySummary: "settings store")
    #expect(workflow.clarificationRoundCount == 3)
    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.clarificationRoundLimitReached) {
        _ = try await workflow.refineBrief(repositorySummary: "settings store")
    }
    #expect(callCount == 3)
    #expect(session.ledger.snapshot.admittedCallCount == 3)
}

@Test @MainActor
func refinementStartsANewRevisionAndLeavesOldEvidenceNonCurrent() async throws {
    let request = "Keep my saved view when I reopen the records screen."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Reopen the saved view",
        acceptanceCriteria: [
            .init(id: "saved-view", statement: "Reopening the screen restores the saved view")
        ]
    )
    let refinedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Reopen the saved view without changing other filters",
        acceptanceCriteria: [
            .init(id: "saved-view", statement: "Reopening the screen restores the saved view")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let refinedJSON = String(decoding: try JSONEncoder().encode(refinedBrief), as: UTF8.self)
    var replies = [initialJSON, refinedJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "records screen")
    let oldRevision = try #require(workflow.state?.activeRevisionID)
    let oldEvidence = HarnessEvidenceRecord(
        key: HarnessEvidenceKey(revisionID: oldRevision, checkID: "saved-view"),
        result: .passed,
        summary: "The fixture restored the saved view"
    )
    try workflow.recordEvidence(oldEvidence)
    try workflow.resolveAcceptanceCriterion("saved-view", using: oldEvidence.key)
    #expect(workflow.state?.currentEvidence == [oldEvidence])
    #expect(workflow.state?.resolvedAcceptanceCriterionIDs == ["saved-view"])

    _ = try await workflow.refineBrief(repositorySummary: "The records screen has a stable saved-view identifier.")
    let newState = try #require(workflow.state)
    #expect(newState.activeRevisionID != oldRevision)
    #expect(newState.currentEvidence.isEmpty)
    #expect(newState.resolvedAcceptanceCriterionIDs.isEmpty)
    #expect(newState.unresolvedAcceptanceCriteria.map(\.id) == ["saved-view"])
    #expect(newState.evidence == [oldEvidence])

    do {
        try workflow.recordEvidence(oldEvidence)
        Issue.record("Old-revision evidence must not be accepted for the refined brief")
    } catch let error as HarnessTaskStateError {
        #expect(error == .staleEvidence(expectedRevisionID: newState.activeRevisionID, actualRevisionID: oldRevision))
    }
}

@Test @MainActor
func anAnswerRecordedDuringRefinementMakesTheReplyStale() async throws {
    let request = "Let me find a note by the title I say aloud."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Find the spoken title",
        acceptanceCriteria: [.init(id: "find", statement: "The matching note is identified")],
        targetedQuestions: [
            .init(
                id: "match",
                prompt: "How close must the title match?",
                options: [
                    .init(id: "exact", label: "Match the whole title"),
                    .init(id: "contains", label: "Match words within the title")
                ]
            )
        ]
    )
    let replyBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Find the title after checking the user's words",
        acceptanceCriteria: [.init(id: "find", statement: "The matching note is identified")]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let replyJSON = String(decoding: try JSONEncoder().encode(replyBrief), as: UTF8.self)
    var releaseRefinement: CheckedContinuation<HarnessModelReply, Never>?
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 2_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        if callCount == 2 {
            return await withCheckedContinuation { continuation in
                releaseRefinement = continuation
            }
        }
        return HarnessModelReply(text: callCount == 1 ? initialJSON : replyJSON)
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "notes database")
    let refinementTask = Task { try await workflow.refineBrief(repositorySummary: "notes database") }
    while releaseRefinement == nil {
        await Task.yield()
    }
    try workflow.recordFreeTextAnswer(questionID: "match", answer: "Use the words I said, even if the title has extra words")
    releaseRefinement?.resume(returning: HarnessModelReply(text: replyJSON))

    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.stalePlan) {
        _ = try await refinementTask.value
    }
    #expect(callCount == 2)
    #expect(workflow.state?.brief.desiredOutcome == initialBrief.desiredOutcome)
    #expect(workflow.state?.userDecisions.first?.answer == "Use the words I said, even if the title has extra words")
}

@Test @MainActor
func contradictoryOptionTextCannotBeRecordedUnderAnotherOptionID() async throws {
    let request = "Find the note I name."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Find the named note",
        acceptanceCriteria: [.init(id: "find", statement: "The named note is shown")],
        targetedQuestions: [
            .init(
                id: "match",
                prompt: "How should the title match?",
                options: [
                    .init(id: "exact", label: "Match the whole title"),
                    .init(id: "contains", label: "Match words within the title")
                ]
            )
        ]
    )
    let json = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: json) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "notes repository")
    let before = try #require(workflow.state)
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.contradictoryAnswer(questionID: "match")) {
        try workflow.recordAnswer(
            questionID: "match",
            optionID: "contains",
            answer: "Match the whole title"
        )
    }
    #expect(workflow.state == before)
    #expect(workflow.unansweredQuestionIDs == Set(["match"]))
}

@Test @MainActor
func duplicateAnswerStillInvalidatesAStaleRefinementReply() async throws {
    let request = "Find the note I name."
    let brief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Find the named note",
        acceptanceCriteria: [.init(id: "find", statement: "The named note is shown")],
        targetedQuestions: [
            .init(
                id: "match",
                prompt: "How should the title match?",
                options: [
                    .init(id: "exact", label: "Match the whole title"),
                    .init(id: "contains", label: "Match words within the title")
                ]
            )
        ]
    )
    let json = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    var releaseRefinement: CheckedContinuation<HarnessModelReply, Never>?
    var callCount = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 2_000_000_000,
        now: { 100 }
    ) { _ in
        callCount += 1
        if callCount == 2 {
            return await withCheckedContinuation { continuation in
                releaseRefinement = continuation
            }
        }
        return HarnessModelReply(text: json)
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "notes repository")
    try workflow.recordAnswer(
        questionID: "match",
        optionID: "exact",
        answer: "Match the whole title"
    )
    let before = try #require(workflow.state)
    let refinementTask = Task { try await workflow.refineBrief(repositorySummary: "notes repository") }
    while releaseRefinement == nil {
        await Task.yield()
    }
    try workflow.recordAnswer(
        questionID: "match",
        optionID: "exact",
        answer: "Match the whole title"
    )
    releaseRefinement?.resume(returning: HarnessModelReply(text: json))

    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.stalePlan) {
        _ = try await refinementTask.value
    }
    #expect(workflow.state == before)
    #expect(workflow.state?.activeRevisionID == before.activeRevisionID)
}

@Test @MainActor
func addedAcceptanceCriteriaWaitForAnExplicitScopeDecision() async throws {
    let request = "Keep the selected item visible."
    let initialBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Keep the selected item visible",
        acceptanceCriteria: [.init(id: "visible", statement: "The selected item remains visible")]
    )
    let proposedBrief = try HarnessTaskBrief(
        userRequest: request,
        desiredOutcome: "Keep the selected item visible",
        acceptanceCriteria: [
            .init(id: "visible", statement: "The selected item remains visible"),
            .init(id: "unchanged", statement: "Other selected items remain unchanged")
        ]
    )
    let initialJSON = String(decoding: try JSONEncoder().encode(initialBrief), as: UTF8.self)
    let proposedJSON = String(decoding: try JSONEncoder().encode(proposedBrief), as: UTF8.self)
    var replies = [initialJSON, proposedJSON]
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in HarnessModelReply(text: replies.removeFirst()) }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: request, repositorySummary: "selection view")
    _ = try await workflow.refineBrief(repositorySummary: "selection view")

    let proposal = try #require(workflow.pendingScopeReconciliation)
    #expect(proposal.addedCriteria.map(\.id) == ["unchanged"])
    #expect(workflow.state?.brief == initialBrief)
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.scopeReconciliationPending) {
        try workflow.implementationContext()
    }

    let approved = try workflow.approveScopeReconciliation(id: proposal.id)
    #expect(approved.brief.acceptanceCriteria == proposedBrief.acceptanceCriteria)
    #expect(workflow.pendingScopeReconciliation == nil)
}
