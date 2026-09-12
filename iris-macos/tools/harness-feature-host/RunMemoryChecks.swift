import Foundation
@testable import IrisHarnessNative

private enum RunMemoryCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Focused, fixture-only checks for the per-app memory record seam. This is a
/// standalone host check: it never reads or writes Iris's default log folder.
@main
struct RunMemoryChecks {
    @MainActor static func main() {
        do {
            try run()
            print("RUN MEMORY CHECKS PASS: 13 groups")
        } catch {
            print("RUN MEMORY CHECKS FAIL: " + String(describing: error))
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        try checkOldRecordDecode()
        try checkCurrentFailureRoundTrip()
        try checkCredentialScrubbingBeforeCap()
        try checkHeadAndTailPreservation()
        try checkPromptLimitAndSerializedCount()
        try checkMissingFailureStageDropsObservation()
        try checkFeatureRecordCannotTriggerGate()
        try checkUnrelatedBugRecordCannotTriggerOrClearGate()
        try checkMatchedBugUnconfirmedTriggersGate()
        try checkMatchedConfirmedBugClearsGate()
        try checkBlankRequestDoesNotTriggerGate()
        try checkWhitespaceAndCaseNormalizationMatches()
        try checkLatestMatchedAppliedRecency()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RunMemoryCheckError.failed(message) }
    }

    private static func checkOldRecordDecode() throws {
        let oldLine = #"{"date":"2026-09-01T00:00:00Z","appSlug":"legacy-app","kind":"feature","scrubbedRequest":"Keep existing data","filesTouched":["Sources/Legacy.swift"],"agentFinalNarration":"done","outcome":"applied on branch legacy","futureField":"ignored"}"#
        guard let record = OnDemandEditRunLog.decodedMemoryRecord(fromLine: oldLine) else {
            throw RunMemoryCheckError.failed("an old memory record without verificationObservation did not decode")
        }
        try require(record.appSlug == "legacy-app" && record.outcome == "applied on branch legacy",
                    "old memory record changed its existing fields")
        try require(record.verificationObservation == nil,
                    "old memory record invented a verification observation")
        print("PASS old memory record decode")
    }

    private static func checkCurrentFailureRoundTrip() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("iris-run-memory-" + UUID().uuidString, isDirectory: true)
        let index = root.appendingPathComponent("index", isDirectory: true)
        try fileManager.createDirectory(at: index, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        guard let observation = OnDemandEditRunLog.verificationObservation(
            failureStage: "native-review-required",
            failureOutputTail: "REVIEW-FINDING: the requested action is still unreachable") else {
            throw RunMemoryCheckError.failed("current failed receipt did not produce an observation")
        }
        let record = OnDemandEditMemoryRecord(
            date: Date(timeIntervalSince1970: 1_788_206_400),
            appSlug: "fixture-memory-app",
            kind: OnDemandEditMemoryRecord.kindFeature,
            scrubbedRequest: "Make the action reachable",
            filesTouched: ["Sources/Feature.swift"],
            agentFinalNarration: "The edit stopped at independent review",
            verificationObservation: observation,
            outcome: OnDemandEditMemoryRecord.failedOutcome(reason: "review rejected")
        )
        OnDemandEditRunLog.appendMemoryRecord(record, directoryPath: index.path)
        let loaded = OnDemandEditRunLog.recentMemoryRecords(
            forAppSlug: "fixture-memory-app", limit: 1, directoryPath: index.path)
        try require(loaded.count == 1, "failed memory record did not round-trip from its fixture file")
        try require(loaded[0].outcome.hasPrefix("failed:"),
                    "failed memory record lost its failed outcome")
        try require(loaded[0].verificationObservation?.contains("REVIEW-FINDING") == true,
                    "current verification receipt finding did not round-trip")
        try require(loaded[0].verificationObservation?.contains("historical") == true,
                    "verification observation was not labeled historical")
        print("PASS current failure observation round-trip")
    }

    private static func checkCredentialScrubbingBeforeCap() throws {
        let credential = "FAKE_TEST_CREDENTIAL_123456789"
        let output = "failure head\nOPENAI_API_KEY=\(credential)\n"
            + String(repeating: "middle output ", count: 100)
            + "\nfinal failure tail"
        let rawRecord = OnDemandEditMemoryRecord(
            appSlug: "fixture-memory-app",
            kind: OnDemandEditMemoryRecord.kindBugFix,
            scrubbedRequest: "fixture request",
            verificationObservation: output,
            outcome: "failed: fixture")
        guard let observation = rawRecord.truncatedForStorage().verificationObservation else {
            throw RunMemoryCheckError.failed("credential fixture did not produce a stored observation")
        }
        try require(observation.count <= OnDemandEditMemoryRecord.maximumVerificationObservationCharacters,
                    "credential observation exceeded its 600-character cap")
        try require(!observation.contains(credential),
                    "credential survived because the cap ran before scrubbing")
        try require(observation.contains("[REDACTED]"),
                    "credential-shaped output was not visibly redacted")
        print("PASS credential scrubbing precedes observation cap")
    }

    private static func checkHeadAndTailPreservation() throws {
        let output = "HEAD-MARKER " + String(repeating: "middle output ", count: 100)
            + " TAIL-MARKER"
        guard let observation = OnDemandEditRunLog.verificationObservation(
            failureStage: "suite", failureOutputTail: output) else {
            throw RunMemoryCheckError.failed("head and tail fixture did not produce an observation")
        }
        try require(observation.count <= OnDemandEditMemoryRecord.maximumVerificationObservationCharacters,
                    "head and tail observation exceeded its 600-character cap")
        try require(observation.contains("HEAD-MARKER") && observation.contains("TAIL-MARKER"),
                    "bounded verification observation dropped either its head or tail")
        print("PASS bounded verification observation preserves head and tail")
    }

    private static func checkPromptLimitAndSerializedCount() throws {
        let longPaths = (1...12).map { _ in "Sources/" + String(repeating: "p", count: 160) }
        let newest = OnDemandEditMemoryRecord(
            date: Date(timeIntervalSince1970: 1_788_206_400),
            appSlug: "fixture-memory-app",
            kind: OnDemandEditMemoryRecord.kindBugFix,
            scrubbedRequest: String(repeating: "request context ", count: 80),
            filesTouched: longPaths,
            agentFinalNarration: "NEWEST-NARRATION " + String(repeating: "n", count: 500),
            verificationObservation: "NEWEST-FAILURE " + String(repeating: "f", count: 500),
            outcome: OnDemandEditMemoryRecord.failedOutcome(reason: "NEWEST-OUTCOME " + String(repeating: "o", count: 300))
        )
        let older = OnDemandEditMemoryRecord(
            date: Date(timeIntervalSince1970: 1_788_206_399),
            appSlug: "fixture-memory-app",
            kind: OnDemandEditMemoryRecord.kindBugFix,
            scrubbedRequest: "older request",
            filesTouched: [],
            agentFinalNarration: "OLDER-NARRATION",
            verificationObservation: "OLDER-FAILURE",
            outcome: "failed: older"
        )
        var serializedCount = 0
        guard let section = OnDemandEditRunLog.memoryPromptSection(
            fromRecords: [newest, older], serializedRecordCount: &serializedCount) else {
            throw RunMemoryCheckError.failed("memory prompt section was missing for nonempty records")
        }
        try require(section.count <= OnDemandEditRunLog.maximumMemoryPromptSectionCharacters,
                    "memory prompt section exceeded its 1500-character ceiling")
        try require(serializedCount == 1,
                    "serialized record count did not report the one record actually included: \(serializedCount)")
        try require(section.contains("NEWEST-FAILURE"),
                    "the bounded prompt omitted the newest failure observation")
        try require(!section.contains("OLDER-FAILURE"),
                    "the bounded prompt counted or rendered a record beyond its serialized count")
        print("PASS 1500-character prompt ceiling and actual serialized count")
    }

    private static func checkMissingFailureStageDropsObservation() throws {
        let observation = OnDemandEditRunLog.verificationObservation(
            failureStage: nil, failureOutputTail: "STALE-FAILURE-OUTPUT")
        try require(observation == nil,
                    "verification output without a current failure stage was remembered")
        print("PASS nil failure stage does not invent an observation")
    }

    private static func gateRecord(
        kind: OnDemandEditKind,
        request: String,
        outcome: String = OnDemandEditMemoryRecord.appliedOutcome(branchName: "iris/fixture"),
        symptomVerdict: String? = nil
    ) -> OnDemandEditMemoryRecord {
        OnDemandEditMemoryRecord(
            appSlug: "fixture-memory-app",
            kind: kind == .feature
                ? OnDemandEditMemoryRecord.kindFeature
                : OnDemandEditMemoryRecord.kindBugFix,
            scrubbedRequest: request,
            outcome: outcome,
            symptomVerdict: symptomVerdict
        )
    }

    private static func freshGateDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-gate-memory-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    private static func checkFeatureRecordCannotTriggerGate() throws {
        let directory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .feature, request: "same complaint"),
            directoryPath: directory
        )
        let escalates = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: directory
        )
        try require(!escalates, "a feature record triggered the bug-fix complaint gate")

        let featureDirectory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: featureDirectory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .bugFix, request: "same complaint"),
            directoryPath: featureDirectory
        )
        let featureRequest = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .feature,
            directoryPath: featureDirectory
        )
        try require(!featureRequest,
                    "a historical bug-fix record triggered a current feature request gate")
        print("PASS unrelated feature record cannot trigger complaint gate")
    }

    private static func checkUnrelatedBugRecordCannotTriggerOrClearGate() throws {
        let noMatchDirectory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: noMatchDirectory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .bugFix, request: "different complaint"),
            directoryPath: noMatchDirectory
        )
        let unrelatedOnly = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "current complaint", kind: .bugFix,
            directoryPath: noMatchDirectory
        )
        try require(!unrelatedOnly, "an unrelated bug record triggered the complaint gate")

        let confirmedDirectory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: confirmedDirectory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .bugFix, request: "current complaint"),
            directoryPath: confirmedDirectory
        )
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "different complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictConfirmed
            ),
            directoryPath: confirmedDirectory
        )
        let unrelatedConfirmation = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "current complaint", kind: .bugFix,
            directoryPath: confirmedDirectory
        )
        try require(unrelatedConfirmation,
                    "an unrelated confirmed bug record cleared the matching complaint gate")
        print("PASS unrelated bug record cannot trigger or clear complaint gate")
    }

    private static func checkMatchedBugUnconfirmedTriggersGate() throws {
        let directory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictUnverified
            ),
            directoryPath: directory
        )
        let escalates = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: directory
        )
        try require(escalates, "a matching unconfirmed bug-fix record did not trigger the gate")
        print("PASS matching unconfirmed bug record triggers complaint gate")
    }

    private static func checkMatchedConfirmedBugClearsGate() throws {
        let directory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictConfirmed
            ),
            directoryPath: directory
        )
        let escalates = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: directory
        )
        try require(!escalates, "a matching confirmed bug-fix record still triggered the gate")
        print("PASS matching confirmed bug record clears complaint gate")
    }

    private static func checkBlankRequestDoesNotTriggerGate() throws {
        let directory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .bugFix, request: "same complaint"),
            directoryPath: directory
        )
        let escalates = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: " \n\t ", kind: .bugFix,
            directoryPath: directory
        )
        try require(!escalates, "a blank request triggered the complaint gate")
        print("PASS blank complaint request does not trigger gate")
    }

    private static func checkWhitespaceAndCaseNormalizationMatches() throws {
        let directory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(kind: .bugFix, request: "  Same   COMPLAINT\n"),
            directoryPath: directory
        )
        let escalates = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: directory
        )
        try require(escalates, "normalized same-kind complaint did not match prior memory")
        print("PASS complaint matching normalizes whitespace and case")
    }

    private static func checkLatestMatchedAppliedRecency() throws {
        let olderConfirmedDirectory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: olderConfirmedDirectory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictConfirmed
            ),
            directoryPath: olderConfirmedDirectory
        )
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictUnverified
            ),
            directoryPath: olderConfirmedDirectory
        )
        let newerUnconfirmed = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: olderConfirmedDirectory
        )
        try require(newerUnconfirmed,
                    "an older confirmed attempt incorrectly cleared a newer unconfirmed attempt")

        let newerConfirmedDirectory = try freshGateDirectory()
        defer { try? FileManager.default.removeItem(atPath: newerConfirmedDirectory) }
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictUnverified
            ),
            directoryPath: newerConfirmedDirectory
        )
        OnDemandEditRunLog.appendMemoryRecord(
            gateRecord(
                kind: .bugFix, request: "same complaint",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictConfirmed
            ),
            directoryPath: newerConfirmedDirectory
        )
        let olderUnconfirmed = OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "fixture-memory-app", request: "same complaint", kind: .bugFix,
            directoryPath: newerConfirmedDirectory
        )
        try require(!olderUnconfirmed,
                    "an older unconfirmed attempt outlived a newer confirmed attempt")
        print("PASS latest matching attempt controls complaint gate")
    }
}
