import Foundation
import Testing
@testable import IrisHarness

@Test(arguments: ["imports", "search", "background-job"])
func parsesGenericIntakeForIndependentWorkflows(domain: String) throws {
    let brief = try makeBrief(domain: domain)
    let encoded = try JSONEncoder().encode(brief)
    let parsed = try HarnessTaskBriefParser.parse(encoded)

    #expect(parsed == brief)
    #expect(parsed.acceptanceCriteria.map(\.id) == ["\(domain)-works"])
    #expect(parsed.targetedQuestions.map(\.id) == ["\(domain)-choice"])
    #expect(parsed.milestones.map(\.id) == ["\(domain)-plan", "\(domain)-check"])
}

@Test
func rejectsMalformedAndUnknownIntakeFields() {
    expectHarnessError(.malformedJSON) {
        _ = try HarnessTaskBriefParser.parse(Data("not json".utf8))
    }

    let unknownField = #"{"userRequest":"request","desiredOutcome":"outcome","explicitNonGoals":[],"acceptanceCriteria":[],"targetedQuestions":[],"milestones":[],"modelAssumptions":[],"unexpected":true}"#
    expectHarnessError(.unknownField(path: "root.unexpected")) {
        _ = try HarnessTaskBriefParser.parse(unknownField)
    }
}

@Test
func rejectsDuplicateIDsInvalidReferencesAndCycles() {
    let duplicateIDs = #"{"userRequest":"request","desiredOutcome":"outcome","explicitNonGoals":[],"acceptanceCriteria":[{"id":"same","statement":"one"},{"id":"same","statement":"two"}],"targetedQuestions":[],"milestones":[],"modelAssumptions":[]}"#
    expectHarnessError(.duplicateID(scope: "acceptanceCriteria", id: "same")) {
        _ = try HarnessTaskBriefParser.parse(duplicateIDs)
    }

    let invalidDependency = #"{"userRequest":"request","desiredOutcome":"outcome","explicitNonGoals":[],"acceptanceCriteria":[],"targetedQuestions":[],"milestones":[{"id":"build","title":"Build","dependencies":["missing"]}],"modelAssumptions":[]}"#
    expectHarnessError(.invalidReference(scope: "milestones.build.dependencies", id: "missing")) {
        _ = try HarnessTaskBriefParser.parse(invalidDependency)
    }

    let cyclic = #"{"userRequest":"request","desiredOutcome":"outcome","explicitNonGoals":[],"acceptanceCriteria":[],"targetedQuestions":[],"milestones":[{"id":"first","title":"First","dependencies":["second"]},{"id":"second","title":"Second","dependencies":["first"]}],"modelAssumptions":[]}"#
    expectHarnessError(.cyclicMilestoneDependencies(["first", "second", "first"])) {
        _ = try HarnessTaskBriefParser.parse(cyclic)
    }
}

@Test
func rejectsOversizedRecordsWithoutTruncatingThem() throws {
    let brief = try makeBrief(domain: "imports")
    let encoded = try JSONEncoder().encode(brief)

    var byteLimits = HarnessTaskStateLimits.default
    byteLimits.maxJSONBytes = encoded.count - 1
    expectHarnessError(.oversizedRecord(actualBytes: encoded.count, maximumBytes: encoded.count - 1)) {
        _ = try HarnessTaskBriefParser.parse(encoded, limits: byteLimits)
    }

    var stringLimits = HarnessTaskStateLimits.default
    stringLimits.maxStringUTF8Bytes = 4
    expectHarnessError(.fieldTooLong(name: "userRequest", actualBytes: brief.userRequest.utf8.count, maximumBytes: 4)) {
        _ = try HarnessTaskBriefParser.parse(encoded, limits: stringLimits)
    }
}

@Test
func userCorrectionsReplaceOnlyUserDecisionsAndResetCurrentAcceptance() throws {
    let state = try makeState(domain: "imports")
    let initialAnswer = HarnessUserDecision(
        id: "imports-destination",
        questionID: "imports-choice",
        optionID: "existing",
        answer: "Use the existing import",
        kind: .answer
    )
    let answered = try state.applyingUserDecision(initialAnswer)

    let correction = HarnessUserDecision(
        id: initialAnswer.id,
        questionID: initialAnswer.questionID,
        optionID: "new",
        answer: "Use the new import",
        kind: .correction
    )
    let corrected = try answered.applyingUserCorrection(correction, advancingTo: "revision-2")

    #expect(corrected.activeRevisionID == "revision-2")
    #expect(corrected.userDecisions == [correction])
    #expect(corrected.currentEvidence.isEmpty)
    #expect(corrected.unresolvedAcceptanceCriteria.map(\.id) == ["imports-works"])
}

@Test
func modelAssumptionsCannotOverwriteUserDecisions() throws {
    let state = try makeState(domain: "search")
    let decision = HarnessUserDecision(
        id: "same-id",
        questionID: "search-choice",
        optionID: "existing",
        answer: "The user chose the existing index",
        kind: .answer
    )
    let answered = try state.applyingUserDecision(decision)
    let guessed = try answered.applyingModelAssumption(
        HarnessModelAssumption(id: decision.id, statement: "The model guessed a different index")
    )

    #expect(guessed.userDecisions == [decision])
    #expect(guessed.modelAssumptions.contains {
        $0.id == decision.id && $0.statement == "The model guessed a different index"
    })
}

@Test
func evidenceIsRevisionAndCheckKeyedAndRejectsStaleOrDuplicateResults() throws {
    let state = try makeState(domain: "background-job")
    let key = HarnessEvidenceKey(revisionID: "revision-1", checkID: "background-job-works")
    let evidence = HarnessEvidenceRecord(key: key, result: .passed, summary: "Fixture check passed")
    let recorded = try state.recordingEvidence(evidence)

    #expect(recorded.currentEvidence == [evidence])
    let resolved = try recorded.resolvingAcceptanceCriterion("background-job-works", using: key)
    #expect(resolved.unresolvedAcceptanceCriteria.isEmpty)

    expectHarnessError(.duplicateEvidence(revisionID: key.revisionID, checkID: key.checkID)) {
        _ = try recorded.recordingEvidence(evidence)
    }

    let stale = HarnessEvidenceRecord(
        key: HarnessEvidenceKey(revisionID: "revision-0", checkID: key.checkID),
        result: .passed,
        summary: "Old result"
    )
    expectHarnessError(.staleEvidence(expectedRevisionID: "revision-1", actualRevisionID: "revision-0")) {
        _ = try recorded.recordingEvidence(stale)
    }
}

@Test
func projectionRetainsAnswersAndUnresolvedAcceptanceOrReturnsExplicitOverflow() throws {
    let state = try makeState(domain: "search")
    let decision = HarnessUserDecision(
        id: "search-destination",
        questionID: "search-choice",
        optionID: "existing",
        answer: "Keep the existing search index",
        kind: .answer
    )
    let answered = try state.applyingUserDecision(decision)

    var generousLimits = HarnessTaskStateLimits.default
    generousLimits.maxProjectionBytes = 32_000
    let ready = try HarnessContextProjector.project(answered, limits: generousLimits)
    guard case .ready(let projection) = ready else {
        Issue.record("The normal fixture should fit the projection budget")
        return
    }
    #expect(projection.currentUserDecisions == [decision])
    #expect(projection.unresolvedAcceptanceCriteria.map(\.id) == ["search-works", "user-decision-" + Data("search-choice".utf8).base64EncodedString()])
    #expect(projection.currentEvidence.isEmpty)

    var tinyLimits = HarnessTaskStateLimits.default
    tinyLimits.maxProjectionBytes = 128
    let overflow = try HarnessContextProjector.project(answered, limits: tinyLimits)
    guard case .overflow(let details) = overflow else {
        Issue.record("The deliberately tiny budget must return overflow")
        return
    }
    #expect(details.userDecisionIDs == [decision.id])
    #expect(details.unresolvedAcceptanceCriterionIDs == ["search-works", "user-decision-" + Data("search-choice".utf8).base64EncodedString()])
    #expect(details.requiredBytes > details.maximumBytes)
}

@Test
func projectionExcludesEvidenceFromAnOlderRevisionAfterCorrection() throws {
    let state = try makeState(domain: "imports")
    let oldKey = HarnessEvidenceKey(revisionID: "revision-1", checkID: "imports-works")
    let recorded = try state.recordingEvidence(
        HarnessEvidenceRecord(key: oldKey, result: .passed, summary: "Old revision passed")
    )
    let correction = HarnessUserDecision(
        id: "imports-correction",
        questionID: "imports-choice",
        optionID: "new",
        answer: "Use the new import",
        kind: .correction
    )
    let revised = try recorded.applyingUserCorrection(correction, advancingTo: "revision-2")
    let result = try HarnessContextProjector.project(revised)

    guard case .ready(let projection) = result else {
        Issue.record("The revised fixture should fit the default budget")
        return
    }
    #expect(projection.currentEvidence.isEmpty)
    #expect(projection.currentUserDecisions == [correction])
    #expect(projection.unresolvedAcceptanceCriteria.map(\.id) == ["imports-works", "user-decision-" + Data("imports-choice".utf8).base64EncodedString()])
}

private func makeBrief(domain: String) throws -> HarnessTaskBrief {
    try HarnessTaskBrief(
        userRequest: "Improve the \(domain) workflow",
        desiredOutcome: "The \(domain) workflow completes with observable evidence",
        explicitNonGoals: ["Do not change unrelated workflows"],
        acceptanceCriteria: [
            HarnessAcceptanceCriterion(
                id: "\(domain)-works",
                statement: "The \(domain) fixture passes its user-visible check"
            )
        ],
        targetedQuestions: [
            HarnessTargetedQuestion(
                id: "\(domain)-choice",
                prompt: "Which supported path should this task use?",
                options: [
                    HarnessQuestionOption(id: "existing", label: "Use the existing path"),
                    HarnessQuestionOption(id: "new", label: "Use the new path")
                ]
            )
        ],
        milestones: [
            HarnessMilestone(id: "\(domain)-plan", title: "Record the plan"),
            HarnessMilestone(
                id: "\(domain)-check",
                title: "Run the fixture check",
                dependencies: ["\(domain)-plan"]
            )
        ],
        modelAssumptions: [
            HarnessModelAssumption(id: "\(domain)-assumption", statement: "The fixture is available")
        ]
    )
}

private func makeState(domain: String) throws -> HarnessTaskState {
    try HarnessTaskState(brief: makeBrief(domain: domain), activeRevisionID: "revision-1")
}

private func expectHarnessError(
    _ expected: HarnessTaskStateError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected harness error \(expected), but the operation succeeded")
    } catch let error as HarnessTaskStateError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected a HarnessTaskStateError, received \(error)")
    }
}
