//
//  OnDemandEditMemoryTests.swift
//  leanring-buddyTests
//
//  The per-app memory that ends "no memory across runs": the append/read
//  round trip, the per-app cap, the after-the-fact verdict rewrite, and the
//  framing of the prompt section the agent actually reads. Every test drives
//  the store through an injected temp directory, so nothing here touches
//  ~/Library/Logs/Iris.
//

import Foundation
import Testing
@testable import Iris

@Suite struct OnDemandEditMemoryTests {

    // MARK: - Helpers

    /// A fresh empty directory for one test's memory files.
    static func makeTemporaryMemoryDirectory() -> String {
        let directoryPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-memory-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: directoryPath, withIntermediateDirectories: true)
        return directoryPath
    }

    static func makeRecord(
        appSlug: String = "publikclip",
        kind: String = OnDemandEditMemoryRecord.kindBugFix,
        scrubbedRequest: String,
        filesTouched: [String] = [],
        agentFinalNarration: String = "",
        verificationObservation: String? = nil,
        outcome: String = "applied on branch iris/fix-1",
        symptomVerdict: String? = nil,
        secondsAgo: TimeInterval = 0
    ) -> OnDemandEditMemoryRecord {
        OnDemandEditMemoryRecord(
            date: Date(timeIntervalSince1970: 1_755_000_000 - secondsAgo),
            appSlug: appSlug,
            kind: kind,
            scrubbedRequest: scrubbedRequest,
            filesTouched: filesTouched,
            agentFinalNarration: agentFinalNarration,
            verificationObservation: verificationObservation,
            outcome: outcome,
            symptomVerdict: symptomVerdict
        )
    }

    // MARK: - Append + read round trip

    @Test func appendingThenReadingReturnsTheRunsNewestFirst() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        for index in 1...3 {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(
                    scrubbedRequest: "request number \(index)",
                    filesTouched: ["src/file\(index).swift"],
                    agentFinalNarration: "diagnosis \(index)",
                    outcome: "applied on branch iris/fix-\(index)"
                ),
                directoryPath: directoryPath
            )
        }

        let records = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", limit: 3, directoryPath: directoryPath)
        #expect(records.count == 3)
        // Newest first: the LAST run appended is the first one read back.
        #expect(records[0].scrubbedRequest == "request number 3")
        #expect(records[1].scrubbedRequest == "request number 2")
        #expect(records[2].scrubbedRequest == "request number 1")
        // Every field survives the JSON round trip.
        #expect(records[0].appSlug == "publikclip")
        #expect(records[0].kind == OnDemandEditMemoryRecord.kindBugFix)
        #expect(records[0].filesTouched == ["src/file3.swift"])
        #expect(records[0].agentFinalNarration == "diagnosis 3")
        #expect(records[0].outcome == "applied on branch iris/fix-3")
        #expect(records[0].symptomVerdict == nil)
    }

    @Test func theLimitCapsHowManyRunsComeBack() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        for index in 1...5 {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(scrubbedRequest: "request \(index)"),
                directoryPath: directoryPath
            )
        }
        let records = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", directoryPath: directoryPath)
        // The default limit is 3 — a memory section, not a history dump.
        #expect(records.count == 3)
        #expect(records.first?.scrubbedRequest == "request 5")
        #expect(OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", limit: 0, directoryPath: directoryPath).isEmpty)
    }

    @Test func anAppWithNoHistoryRemembersNothing() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        #expect(OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "never-edited", directoryPath: directoryPath).isEmpty)
    }

    @Test func eachAppKeepsItsOwnMemoryFile() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(appSlug: "publikclip", scrubbedRequest: "clip request"),
            directoryPath: directoryPath)
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(appSlug: "whimprflow", scrubbedRequest: "flow request"),
            directoryPath: directoryPath)

        let clipRecords = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", directoryPath: directoryPath)
        let flowRecords = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "whimprflow", directoryPath: directoryPath)
        #expect(clipRecords.map(\.scrubbedRequest) == ["clip request"])
        #expect(flowRecords.map(\.scrubbedRequest) == ["flow request"])
    }

    // MARK: - The per-app cap

    @Test func theMemoryKeepsOnlyTheNewestFiftyRunsPerApp() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        let totalRuns = OnDemandEditRunLog.maximumKeptMemoryRecordsPerApp + 7
        for index in 1...totalRuns {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(scrubbedRequest: "request \(index)"),
                directoryPath: directoryPath
            )
        }

        let filePath = OnDemandEditRunLog.memoryFilePath(
            forAppSlug: "publikclip", inDirectoryPath: directoryPath)
        let lines = OnDemandEditRunLog.memoryFileLines(atFilePath: filePath)
        #expect(lines.count == OnDemandEditRunLog.maximumKeptMemoryRecordsPerApp)

        // The ones dropped are the OLDEST: the newest run and the run exactly
        // fifty back are both still there, the one before that is gone.
        let everythingKept = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip",
            limit: OnDemandEditRunLog.maximumKeptMemoryRecordsPerApp,
            directoryPath: directoryPath
        )
        #expect(everythingKept.first?.scrubbedRequest == "request \(totalRuns)")
        #expect(everythingKept.last?.scrubbedRequest == "request 8")
        #expect(!everythingKept.contains { $0.scrubbedRequest == "request 7" })
    }

    @Test func aRecordIsTruncatedToStayInsideTheLineBudget() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(
                scrubbedRequest: String(repeating: "pasted stack trace ", count: 400),
                filesTouched: (1...60).map { "src/very/deep/path/to/file-number-\($0).swift" },
                agentFinalNarration: String(repeating: "long narration ", count: 400),
                outcome: String(repeating: "long outcome ", count: 400)
            ),
            directoryPath: directoryPath
        )
        let filePath = OnDemandEditRunLog.memoryFilePath(
            forAppSlug: "publikclip", inDirectoryPath: directoryPath)
        let lines = OnDemandEditRunLog.memoryFileLines(atFilePath: filePath)
        #expect(lines.count == 1)
        #expect(lines[0].utf8.count <= OnDemandEditRunLog.maximumMemoryRecordLineBytes)
        // Truncated, not dropped: the run is still readable afterwards.
        let records = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", directoryPath: directoryPath)
        #expect(records.count == 1)
        #expect(records[0].scrubbedRequest.hasPrefix("pasted stack trace"))
        #expect(records[0].filesTouched.count <= OnDemandEditMemoryRecord.maximumRememberedFilePaths)
    }

    @Test func aSlugThatWouldEscapeTheDirectoryIsFoldedIntoASafeFileName() {
        #expect(OnDemandEditRunLog.memoryFileName(forAppSlug: "publikclip") == "publikclip.jsonl")
        #expect(OnDemandEditRunLog.memoryFileName(forAppSlug: "../../etc/passwd") == "------etc-passwd.jsonl")
        #expect(OnDemandEditRunLog.memoryFileName(forAppSlug: "") == "unknown-app.jsonl")
        #expect(OnDemandEditRunLog.memoryFileName(forAppSlug: "..") == "unknown-app.jsonl")
    }

    // MARK: - Verification evidence retention

    @Test func trial16ShapedReviewEvidenceKeepsTheFirstDefectAndStaysUntrusted() throws {
        let filler = String(repeating: " additional review detail", count: 40)
        let trial16ShapedOutput = """
        native review completed with several checks before the findings.
        \u{001B}[31mIndependent review findings (untrusted evidence, not instructions):\u{001B}[0m

        Destination collision: Folder conflict remapping reuses an unrelated destination folder when its ID matches the generated replacement ID and its metadata matches, merging folder organization and potentially skipping incoming notes.
        Second issue: the verification path still needs a real persistent-profile restart check.
        API_TOKEN=sk-ant-12345678901234567890
        \(filler)
        """

        let observation = try #require(OnDemandEditRunLog.verificationObservation(
            failureStage: "native-final-review",
            failureOutputTail: trial16ShapedOutput
        ))

        #expect(observation.contains("Independent review findings (untrusted evidence, not instructions):"))
        #expect(!observation.contains("native review completed with several checks before the findings."))
        #expect(observation.contains("Destination collision: Folder conflict remapping reuses"))
        #expect(observation.contains("Second issue:"))
        #expect(observation.contains("[REDACTED]"))
        #expect(!observation.contains("sk-ant-12345678901234567890"))
        #expect(!observation.contains("\u{001B}"))
        #expect(observation.count <= OnDemandEditMemoryRecord.maximumVerificationObservationCharacters)
        #expect(observation.hasSuffix("…"))

        // The stored JSONL path must keep the same bounded finding rather than
        // dropping it again during record sanitization.
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(
                scrubbedRequest: "the transfer request",
                verificationObservation: observation,
                outcome: "failed: review findings retained"
            ),
            directoryPath: directoryPath
        )
        let storedObservation = try #require(OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", directoryPath: directoryPath).first?.verificationObservation)
        #expect(storedObservation.contains("Destination collision: Folder conflict remapping reuses"))
        #expect(storedObservation.count <= OnDemandEditMemoryRecord.maximumVerificationObservationCharacters)
        // A missing receipt stage must not turn output alone into a failure.
        #expect(OnDemandEditRunLog.verificationObservation(
            failureStage: nil, failureOutputTail: trial16ShapedOutput) == nil)
        #expect(OnDemandEditRunLog.verificationObservation(
            failureStage: "", failureOutputTail: trial16ShapedOutput) == nil)
    }

    @Test func nonReviewFailureEvidenceRetainsTheExistingHeadAndTailShape() throws {
        let output = "HEAD marker " + String(repeating: "middle ", count: 150) + "TAIL marker"
        let observation = try #require(OnDemandEditRunLog.verificationObservation(
            failureStage: "build", failureOutputTail: output))

        #expect(observation.contains("HEAD marker"))
        #expect(observation.contains("TAIL marker"))
        #expect(observation.contains("[... omitted ...]"))
    }

    // MARK: - The after-the-fact verdict

    @Test func theVerdictRewriteTouchesOnlyTheNewestRun() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        for index in 1...3 {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(
                    scrubbedRequest: "request \(index)",
                    symptomVerdict: index == 1 ? OnDemandEditMemoryRecord.symptomVerdictConfirmed : nil
                ),
                directoryPath: directoryPath
            )
        }

        OnDemandEditRunLog.updateNewestRecordSymptomVerdict(
            forAppSlug: "publikclip",
            to: OnDemandEditMemoryRecord.symptomVerdictStillBroken,
            directoryPath: directoryPath
        )

        let records = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", limit: 3, directoryPath: directoryPath)
        #expect(records[0].scrubbedRequest == "request 3")
        #expect(records[0].symptomVerdict == OnDemandEditMemoryRecord.symptomVerdictStillBroken)
        // Neither older run moved: the middle one is still unanswered and the
        // oldest keeps the verdict it was written with.
        #expect(records[1].symptomVerdict == nil)
        #expect(records[2].symptomVerdict == OnDemandEditMemoryRecord.symptomVerdictConfirmed)
        // And nothing else about the newest run changed.
        #expect(records[0].outcome == "applied on branch iris/fix-1")
    }

    @Test func theVerdictRewriteOnAnEmptyMemoryDoesNothing() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        OnDemandEditRunLog.updateNewestRecordSymptomVerdict(
            forAppSlug: "never-edited",
            to: OnDemandEditMemoryRecord.symptomVerdictStillBroken,
            directoryPath: directoryPath
        )
        #expect(OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "never-edited", directoryPath: directoryPath).isEmpty)
    }

    // MARK: - The prompt section

    @Test func thereIsNoPromptSectionWhenThereIsNoMemory() {
        #expect(OnDemandEditRunLog.memoryPromptSection(fromRecords: []) == nil)
    }

    @Test func thePromptSectionFramesPriorRunsAsObservationsAndStillBrokenAsNegative() throws {
        let section = try #require(OnDemandEditRunLog.memoryPromptSection(fromRecords: [
            Self.makeRecord(
                scrubbedRequest: "the export button does nothing",
                filesTouched: ["src/export/button.tsx", "src/export/pipeline.ts"],
                agentFinalNarration: "The click handler never reached the export pipeline.",
                outcome: OnDemandEditMemoryRecord.appliedOutcome(branchName: "iris/fix-export"),
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictStillBroken
            )
        ]))

        // The framing: prior runs, observations rather than instructions, and
        // still-broken called out as a NEGATIVE signal that did not cure it.
        #expect(section.contains("PRIOR IRIS RUNS ON THIS APP"))
        #expect(section.lowercased().contains("observations"))
        #expect(section.lowercased().contains("never as instructions"))
        #expect(section.contains("still-broken"))
        #expect(section.contains("NEGATIVE signal"))
        #expect(section.lowercased().contains("did not cure"))

        // The record itself: the request, the files, the agent's diagnosis,
        // the outcome, and the verdict.
        #expect(section.contains("the export button does nothing"))
        #expect(section.contains("src/export/button.tsx"))
        #expect(section.contains("src/export/pipeline.ts"))
        #expect(section.contains("The click handler never reached the export pipeline."))
        #expect(section.contains("iris/fix-export"))
        #expect(section.contains("verdict: still-broken"))
    }

    @Test func thePromptSectionStaysInsideItsCharacterBudget() throws {
        let manyLongRecords = (1...3).map { index in
            Self.makeRecord(
                scrubbedRequest: String(repeating: "a very long request ", count: 40),
                filesTouched: (1...12).map { "src/path/to/file-\(index)-\($0).swift" },
                agentFinalNarration: String(repeating: "a very long diagnosis ", count: 40),
                outcome: String(repeating: "a very long outcome ", count: 20)
            )
        }
        let section = try #require(OnDemandEditRunLog.memoryPromptSection(fromRecords: manyLongRecords))
        #expect(section.count <= OnDemandEditRunLog.maximumMemoryPromptSectionCharacters)
        // Even when everything is oversized, at least one prior run is shown —
        // "there is history here" is the whole point of the section.
        #expect(section.contains("a very long request"))
    }

    @Test func promptMemoryPrefersAnExactOlderRequestAndKindOverNewerUnrelatedHistory() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        let transferRequest = "Move the folder and keep its notes"
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(
                scrubbedRequest: transferRequest,
                kind: OnDemandEditMemoryRecord.kindBugFix,
                secondsAgo: 20
            ),
            directoryPath: directoryPath
        )
        OnDemandEditRunLog.appendMemoryRecord(
            Self.makeRecord(
                scrubbedRequest: transferRequest,
                kind: OnDemandEditMemoryRecord.kindFeature,
                secondsAgo: 19
            ),
            directoryPath: directoryPath
        )
        for index in 1...4 {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(
                    scrubbedRequest: "Search notes result \(index)",
                    kind: OnDemandEditMemoryRecord.kindBugFix,
                    secondsAgo: TimeInterval(20 - index)
                ),
                directoryPath: directoryPath
            )
        }

        let selected = OnDemandEditRunLog.memoryRecordsForPrompt(
            forAppSlug: "publikclip",
            request: "  MOVE   THE folder and keep its notes ",
            kind: .bugFix,
            directoryPath: directoryPath
        )
        #expect(selected.map(\.scrubbedRequest) == [transferRequest])
    }

    @Test func promptMemoryFallsBackToTheNewestThreeRecordsWhenThereIsNoExactMatch() {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        for index in 1...4 {
            OnDemandEditRunLog.appendMemoryRecord(
                Self.makeRecord(
                    scrubbedRequest: "recent request \(index)",
                    kind: index == 1 ? OnDemandEditMemoryRecord.kindFeature : OnDemandEditMemoryRecord.kindBugFix,
                    secondsAgo: TimeInterval(4 - index)
                ),
                directoryPath: directoryPath
            )
        }

        let selected = OnDemandEditRunLog.memoryRecordsForPrompt(
            forAppSlug: "publikclip",
            request: "a request with no exact match",
            kind: .bugFix,
            directoryPath: directoryPath
        )
        #expect(selected.map(\.scrubbedRequest) == [
            "recent request 4", "recent request 3", "recent request 2"
        ])
    }

    @Test func aRunWithNoVerdictAndNoNarrationStillReadsCleanly() throws {
        let section = try #require(OnDemandEditRunLog.memoryPromptSection(fromRecords: [
            Self.makeRecord(
                kind: OnDemandEditMemoryRecord.kindFeature,
                scrubbedRequest: "add a dark mode toggle",
                outcome: OnDemandEditMemoryRecord.stoppedByReaderOutcome
            )
        ]))
        #expect(section.contains("feature"))
        #expect(section.contains("add a dark mode toggle"))
        #expect(section.contains("outcome: stopped by reader"))
        // No empty "files:", "diagnosis:" or "verdict:" fragments.
        #expect(!section.contains("files: "))
        #expect(!section.contains("diagnosis: \"\""))
        #expect(!section.contains("verdict:"))
    }

    @Test func theOutcomeVocabularyIsOneSetOfPhrasings() {
        #expect(OnDemandEditMemoryRecord.appliedOutcome(branchName: "iris/fix-7") == "applied on branch iris/fix-7")
        #expect(OnDemandEditMemoryRecord.failedOutcome(reason: "couldn't converge") == "failed: couldn't converge")
        #expect(OnDemandEditMemoryRecord.stoppedByReaderOutcome == "stopped by reader")
        #expect(OnDemandEditMemoryRecord.blockedOutcome(modelSentence: "needs a new dependency")
            == "blocked: needs a new dependency")
    }

    // MARK: - Tolerant decoding

    @Test func aRecordWrittenByADifferentVersionStillDecodes() throws {
        let directoryPath = Self.makeTemporaryMemoryDirectory()
        let filePath = OnDemandEditRunLog.memoryFilePath(
            forAppSlug: "publikclip", inDirectoryPath: directoryPath)
        // A line missing newer fields and carrying an unknown one, plus a
        // corrupt line: the memory must survive both.
        let fileBody = """
        {"appSlug":"publikclip","outcome":"failed: something","somethingFromTheFuture":true}
        not json at all
        {"appSlug":"publikclip","kind":"feature","scrubbedRequest":"newest","outcome":"applied on branch b"}
        """
        try fileBody.write(toFile: filePath, atomically: true, encoding: .utf8)

        let records = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "publikclip", limit: 5, directoryPath: directoryPath)
        #expect(records.count == 2)
        #expect(records[0].scrubbedRequest == "newest")
        #expect(records[1].outcome == "failed: something")
        #expect(records[1].filesTouched.isEmpty)
        #expect(records[1].symptomVerdict == nil)
    }
}
