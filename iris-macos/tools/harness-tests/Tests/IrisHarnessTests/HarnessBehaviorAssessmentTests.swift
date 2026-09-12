import Testing
@testable import IrisHarness

@Suite struct HarnessBehaviorAssessmentTests {
    let criteria = [HarnessAcceptanceCriterion(id: "queue", statement: "Jobs wait their turn"),
                    HarnessAcceptanceCriterion(id: "cancel", statement: "Cancel stops the selected job")]
    let tests = ["test/queue.test.js": "test('jobs wait'); test('cancel stops');"]
    let complete = "COVERED: queue | test/queue.test.js | jobs wait\nCOVERED: cancel | test/queue.test.js | cancel stops"

    func assess(_ reply: String, suite: Bool = true, clean: Bool = true,
                files: [String: String]? = nil, revision: String = "diff-1") -> HarnessBehaviorAssessment {
        HarnessBehaviorAssessment.assess(reply: reply, criteria: criteria, revision: revision,
            suitePassed: suite, reviewWasClean: clean, suppliedTestFiles: files ?? tests)
    }

    @Test func completeCoverageRequiresActualPassingSuiteAndSeparateCleanReview() {
        #expect(assess(complete).permitsAutomaticDelivery)
        #expect(!assess(complete, suite: false).permitsAutomaticDelivery)
        #expect(!assess(complete, clean: false).permitsAutomaticDelivery)
        #expect(!assess(complete, revision: "").permitsAutomaticDelivery)
    }

    @Test func buildOrDoneAloneCannotPassAndPendingBehaviorIsReadable() {
        let result = assess("Build passed. DONE. VERDICT: CLEAN")
        #expect(!result.permitsAutomaticDelivery)
        #expect(result.pending == criteria)
        #expect(result.readerSummary.contains("Jobs wait their turn"))
        #expect(result.readerSummary.contains("has not been replaced"))
    }

    @Test func partialCoverageKeepsOtherRequirementPending() {
        let result = assess("COVERED: queue | test/queue.test.js | jobs wait")
        #expect(result.supported.count == 1)
        #expect(result.pending.map(\.id) == ["cancel"])
        #expect(!result.permitsAutomaticDelivery)
    }

    @Test func unknownDuplicateMalformedOrUnseenReferencesFailClosed() {
        for extra in ["COVERED: invented | test/queue.test.js | jobs wait",
                      "COVERED: queue | test/queue.test.js | jobs wait",
                      "COVERED:", "COVERED: queue | unseen.js | jobs wait"] {
            let result = assess(complete + "\n" + extra)
            #expect(!result.permitsAutomaticDelivery)
            #expect(result.protocolIssue != nil)
        }
    }

    @Test func codeFunctionOrDocumentationCannotMasqueradeAsTestCoverage() {
        #expect(!assess("COVERED: queue | src/queue.js | jobs wait",
                       files: ["src/queue.js": "jobs wait"]).permitsAutomaticDelivery)
        let result = assess("COVERED: queue | test/README.md | jobs wait",
                            files: ["test/README.md": "jobs wait"])
        #expect(result.supported.isEmpty)
    }

    @Test func renamedOrRemovedTestInvalidatesCoverage() {
        #expect(!assess(complete, files: ["test/queue.test.js": "unrelated test"]).permitsAutomaticDelivery)
    }

    @Test func emptyContractCannotPassVacuously() {
        let result = HarnessBehaviorAssessment.assess(reply: "", criteria: [], revision: "r1",
            suitePassed: true, reviewWasClean: true, suppliedTestFiles: [:])
        #expect(!result.permitsAutomaticDelivery)
    }

    @Test func cleanReviewOnlyAllowsTheExactReviewedRevision() {
        let result = assess(complete)
        #expect(result.permitsAutomaticDelivery(forRevision: "diff-1"))
        #expect(!result.permitsAutomaticDelivery(forRevision: "diff-2"))
        #expect(!result.permitsAutomaticDelivery(forRevision: nil))
    }
}
