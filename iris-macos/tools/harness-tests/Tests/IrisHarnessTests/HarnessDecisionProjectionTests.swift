import Foundation
import Testing
@testable import IrisHarness

@Test
func selectedDecisionProjectionUsesRecordedAnswersInQuestionOrder() throws {
    let brief = try HarnessTaskBrief(
        userRequest: "I want my notes on my other computer too.",
        desiredOutcome: "Move a confirmed copy of my notes to another computer.",
        acceptanceCriteria: [
            .init(id: "preserve", statement: "Existing notes remain on this computer.")
        ],
        targetedQuestions: [
            .init(
                id: "transfer-method",
                prompt: "How should you start the transfer?",
                options: [
                    .init(id: "manual", label: "Transfer it myself"),
                    .init(id: "automatic", label: "Keep the computers in sync automatically")
                ]
            ),
            .init(
                id: "data-scope",
                prompt: "What should be included?",
                options: [
                    .init(id: "content", label: "Just titles and content"),
                    .init(id: "all", label: "Everything")
                ]
            ),
            .init(
                id: "duplicates",
                prompt: "What should happen to copies already there?",
                options: [
                    .init(id: "keep-both", label: "Keep both"),
                    .init(id: "replace", label: "Replace the existing copy")
                ]
            ),
            .init(
                id: "storage-api",
                prompt: "Which storage API should be used?",
                options: [
                    .init(id: "sqlite", label: "Use SQLite"),
                    .init(id: "json", label: "Use JSON files")
                ],
                kind: .implementationDetail
            )
        ]
    )
    let state = try HarnessTaskState(
        brief: brief,
        activeRevisionID: "request-1",
        userDecisions: [
            .init(
                id: "data-scope",
                questionID: "data-scope",
                optionID: "content",
                answer: "Just titles and content"
            ),
            .init(
                id: "duplicates",
                questionID: "duplicates",
                optionID: "keep-both",
                answer: "Keep both"
            ),
            .init(
                id: "transfer-method",
                questionID: "transfer-method",
                optionID: "manual",
                answer: "Transfer it myself"
            ),
            .init(
                id: "storage-api",
                questionID: "storage-api",
                optionID: "sqlite",
                answer: "Use SQLite"
            )
        ]
    )

    let summaries = HarnessContextProjector.selectedDecisionSummaries(for: state)

    #expect(summaries.map(\.id) == ["transfer-method", "data-scope", "duplicates"])
    #expect(summaries.map(\.question) == [
        "How should you start the transfer?",
        "What should be included?",
        "What should happen to copies already there?"
    ])
    #expect(summaries.map(\.answer) == [
        "Transfer it myself",
        "Just titles and content",
        "Keep both"
    ])
    #expect(summaries.map(\.optionID) == ["manual", "content", "keep-both"])

    let replacedState = try state.applyingUserDecision(.init(
        id: "data-scope",
        questionID: "data-scope",
        optionID: "all",
        answer: "Everything"
    ))
    let replacedSummaries = HarnessContextProjector.selectedDecisionSummaries(for: replacedState)
    #expect(replacedSummaries.first(where: { $0.id == "data-scope" })?.answer == "Everything")
    #expect(replacedSummaries.allSatisfy { $0.id != "storage-api" })
}

@Test @MainActor
func workflowExposesOnlyCurrentChoicesWithoutAnotherModelCall() async throws {
    let brief = try HarnessTaskBrief(
        userRequest: "Move notes to another computer.",
        desiredOutcome: "Move a copy of the notes.",
        acceptanceCriteria: [
            .init(id: "copy", statement: "The notes are copied without deleting the originals.")
        ],
        targetedQuestions: [
            .init(
                id: "scope",
                prompt: "What should move?",
                options: [
                    .init(id: "content", label: "Just titles and content"),
                    .init(id: "all", label: "Everything")
                ]
            )
        ]
    )
    let reply = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    var calls = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 2, maxInputBytes: 80_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        calls += 1
        return HarnessModelReply(text: reply)
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)

    _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "local notes")
    #expect(workflow.selectedDecisionSummaries.isEmpty)
    try workflow.recordAnswer(
        questionID: "scope",
        optionID: "content",
        answer: "Just titles and content"
    )

    let summaries = workflow.selectedDecisionSummaries
    #expect(calls == 1)
    #expect(summaries.count == 1)
    #expect(summaries[0].question == "What should move?")
    #expect(summaries[0].answer == "Just titles and content")
    #expect(summaries[0].optionID == "content")
}

@Suite("Explicit choice coverage")
struct HarnessExplicitChoiceCoverageTests {
    private func state(request: String = "Move my notes to another computer.",
                       question: String = "What happens to uncertain matches?",
                       answer: String = "Keep differing or uncertain matches as separate copies.",
                       criterionID: String = "transfer") throws -> HarnessTaskState {
        let brief = try HarnessTaskBrief(userRequest: request, desiredOutcome: request,
            acceptanceCriteria: [.init(id: criterionID, statement: "The requested action completes.")],
            targetedQuestions: [.init(id: "choice", prompt: question, options: [
                .init(id: "chosen", label: answer), .init(id: "other", label: "Use the other behavior")
            ])])
        return try HarnessTaskState(brief: brief, activeRevisionID: "request-1",
            userDecisions: [.init(id: "choice", questionID: "choice", optionID: "chosen", answer: answer)])
    }

    @Test func broadCoverageCannotReplaceTheSelectedPreservationChoice() throws {
        let state = try state()
        let reply = "COVERED: transfer | tests/transfer.test.ts | transfer completes"
        let files = ["tests/transfer.test.ts": "test('transfer completes', () => {}); test('distinct matches remain separate', () => {});"]
        func assessment(_ criteria: [HarnessAcceptanceCriterion], reply: String) -> HarnessBehaviorAssessment {
            .assess(reply: reply, criteria: criteria, revision: "diff-1", suitePassed: true,
                reviewWasClean: true, suppliedTestFiles: files)
        }
        // Reproduces the old coverage seam, not a claim that these inert test
        // strings establish actual behavior. The independent reviewer owns that.
        #expect(assessment(state.brief.acceptanceCriteria, reply: reply).permitsAutomaticDelivery)
        let criteria = try HarnessContextProjector.verificationCriteria(for: state)
        let missingChoice = assessment(criteria, reply: reply)
        #expect(!missingChoice.permitsAutomaticDelivery)
        #expect(missingChoice.pending.map(\.id) == ["user-decision-Y2hvaWNl"])
        #expect(missingChoice.pending[0].statement.contains("uncertain matches as separate copies"))
        let complete = assessment(criteria, reply: reply + "\nCOVERED: user-decision-Y2hvaWNl | tests/transfer.test.ts | distinct matches remain separate")
        #expect(complete.permitsAutomaticDelivery)
        #expect(state.brief.acceptanceCriteria.count == 1)
    }

    @Test func identicalObligationsReachImplementationProjectionAndReview() throws {
        let state = try state()
        guard case .ready(let projection) = try HarnessContextProjector.project(state) else {
            Issue.record("Expected bounded projection"); return
        }
        let reviewCriteria = try HarnessContextProjector.verificationCriteria(for: state)
        #expect(projection.unresolvedAcceptanceCriteria == reviewCriteria)
        #expect(projection.currentUserDecisions == state.userDecisions)
        #expect(projection.encodedUTF8ByteCount <= HarnessTaskStateLimits.default.maxProjectionBytes)
    }

    @Test func changedAnswerReplacesTheChoiceWithoutKeepingItsOldMeaning() throws {
        let original = try state()
        let changed = try original.advancingRevision(to: "request-2").applyingUserDecision(
            .init(id: "choice", questionID: "choice", optionID: "other", answer: "Use the other behavior"))
        let current = try HarnessContextProjector.verificationCriteria(for: changed)
        #expect(current.count == 2)
        #expect(current.last?.statement.contains("Use the other behavior") == true)
        #expect(current.last?.statement.contains("uncertain matches as separate copies") == false)
        let prior = try HarnessContextProjector.verificationCriteria(for: original)
        #expect(current.last?.id == prior.last?.id)
        #expect(changed.activeRevisionID != original.activeRevisionID)
    }

    @Test func generatedIDsCannotCollideWithPlannerCriteria() throws {
        let state = try state(criterionID: "user-decision-Y2hvaWNl")
        #expect(throws: HarnessTaskStateError.duplicateID(scope: "verificationCriteria", id: "user-decision-Y2hvaWNl")) {
            try HarnessContextProjector.verificationCriteria(for: state)
        }
        #expect(throws: HarnessTaskStateError.duplicateID(scope: "verificationCriteria", id: "user-decision-Y2hvaWNl")) {
            try HarnessContextProjector.project(state)
        }
    }

    @Test func questionIdentitySurvivesOutOfOrderAnswersAndReorderedQuestions() throws {
        let questions = ["first", "second"].map { identifier in
            HarnessTargetedQuestion(id: identifier, prompt: "Choose \(identifier)", options: [
                .init(id: "yes", label: "Keep it"), .init(id: "no", label: "Change it")])
        }
        func makeState(_ questions: [HarnessTargetedQuestion], answers: [HarnessUserDecision]) throws -> HarnessTaskState {
            try .init(brief: .init(userRequest: "Organize items", desiredOutcome: "Organize items",
                acceptanceCriteria: [.init(id: "base", statement: "Items are organized")],
                targetedQuestions: questions), activeRevisionID: "r1", userDecisions: answers)
        }
        let second = HarnessUserDecision(id: "answer-second", questionID: "second", optionID: "yes", answer: "Keep it")
        let first = HarnessUserDecision(id: "answer-first", questionID: "first", optionID: "no", answer: "Change it")
        let one = try HarnessContextProjector.verificationCriteria(for: makeState(questions, answers: [second]))
        let two = try HarnessContextProjector.verificationCriteria(for: makeState(questions, answers: [second, first]))
        let reordered = try HarnessContextProjector.verificationCriteria(for: makeState(questions.reversed(), answers: [second, first]))
        let secondID = "user-decision-c2Vjb25k"
        #expect(one.last?.id == secondID)
        #expect(two.first(where: { $0.id == secondID }) == one.last)
        #expect(reordered.first(where: { $0.id == secondID }) == one.last)
        #expect(Set(two.map(\.id)) == Set(reordered.map(\.id)))
    }

    @Test func unansweredChoicesAndSimpleTasksDoNotInventObligations() throws {
        let answered = try state()
        let unanswered = try HarnessTaskState(brief: answered.brief, activeRevisionID: "request-1")
        #expect(try HarnessContextProjector.verificationCriteria(for: unanswered) == unanswered.brief.acceptanceCriteria)
        let simple = try HarnessTaskState(brief: .init(userRequest: "Rename this button.",
            desiredOutcome: "The new label appears.", acceptanceCriteria: [.init(id: "label", statement: "The new label appears.")]),
            activeRevisionID: "simple-1")
        #expect(try HarnessContextProjector.verificationCriteria(for: simple) == simple.brief.acceptanceCriteria)
    }

    @Test func unrelatedDestinationChoiceUsesTheSameGeneralCoveragePath() throws {
        let state = try state(request: "Paste my dictation into the right tab.",
            question: "What should happen when several tabs match?",
            answer: "Ask me to choose; do not paste into a guessed tab.")
        let criteria = try HarnessContextProjector.verificationCriteria(for: state)
        #expect(criteria.last?.statement == "Honor the user's exact choice for What should happen when several tabs match? Answer: Ask me to choose; do not paste into a guessed tab.")
        #expect(!criteria.contains { $0.statement.contains("notes") || $0.statement.contains("folder") })
        var limits = HarnessTaskStateLimits.default
        limits.maxProjectionBytes = 64
        guard case .overflow = try HarnessContextProjector.project(state, limits: limits) else {
            Issue.record("Choice obligations must not bypass the existing context limit"); return
        }
    }
}
