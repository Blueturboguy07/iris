import Testing
@testable import IrisHarness

@Suite struct HarnessExecutionJournalTests {
    @Test func editsInvalidateEarlierChecksButPreserveTheirHistory() {
        var journal = HarnessExecutionJournal()
        journal.recordChangedFiles(["src/queue.js"])
        journal.recordVerification(buildPassed: true, testsPassed: true)
        #expect(journal.promptSection.contains("Latest checks: Build: passed"))
        journal.recordChangedFiles(["src/controller.js"])
        #expect(journal.promptSection.contains("now stale"))
        #expect(journal.changedPaths == ["src/queue.js", "src/controller.js"])
    }

    @Test func commandSuccessNeverBecomesBehaviorOrSuiteSuccess() {
        var journal = HarnessExecutionJournal()
        journal.recordCommand(exitCode: 0, outputTail: ["all done"])
        #expect(journal.latestVerification == nil)
        #expect(journal.promptSection.contains("Commands completed: 1"))
        #expect(journal.promptSection.contains("No milestone completion"))
        journal.recordVerification(buildPassed: true, testsPassed: nil)
        #expect(journal.promptSection.contains("configured tests: not run"))
    }

    @Test func failuresStayVisibleAsHistoricalObservations() {
        var journal = HarnessExecutionJournal()
        journal.recordCommand(exitCode: 1, outputTail: ["missing cancellation check"])
        journal.recordCommand(exitCode: 0, outputTail: [])
        #expect(journal.promptSection.contains("missing cancellation check"))
        #expect(journal.promptSection.contains("may since have been repaired"))
    }

    @Test func boundedHistoryReportsOmittedCoverage() {
        var journal = HarnessExecutionJournal()
        journal.recordChangedFiles((0..<80).map { "src/file-\($0).js" })
        for index in 0..<20 { journal.recordProblem("problem \(index)") }
        #expect(journal.changedPaths.count == 64)
        #expect(journal.pathsWereOmitted)
        #expect(journal.recentProblems.count == 4)
        #expect(journal.promptSection.contains("partial"))
        #expect(journal.promptSection.utf8.count < 4000)
    }
}
