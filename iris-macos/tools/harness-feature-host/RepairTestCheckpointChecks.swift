import Foundation
@testable import IrisHarnessNative

/// Exercises the repair loop with an inert model transport. The fixture is
/// disposable and the declared suite is a shell canary, not a product test.
@MainActor
func runRepairTestCheckpointChecks() async throws {
#if CHECKPOINT_EXPECT_OLD
    try await runRepairTestCheckpointScenario("repair")
#else
    for scenario in ["repair", "cancel-after-write", "review-reserve", "no-suite"] {
        try await runRepairTestCheckpointScenario(scenario)
    }
#endif
}

@MainActor
private func runRepairTestCheckpointScenario(_ scenario: String) async throws {
    enum CheckError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError.failed(message) }
    }

    let fileManager = FileManager.default
    let container = fileManager.temporaryDirectory
        .appendingPathComponent("iris-repair-test-checkpoint-" + UUID().uuidString)
    let workRoot = container.appendingPathComponent("work")
    let scratchRoot = container.appendingPathComponent("scratch")
    try fileManager.createDirectory(at: workRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: workRoot.appendingPathComponent("tests"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: container) }

    let previousScratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"]
    setenv("IRIS_HARNESS_SCRATCH", scratchRoot.path, 1)
    defer {
        if let previousScratch {
            setenv("IRIS_HARNESS_SCRATCH", previousScratch, 1)
        } else {
            unsetenv("IRIS_HARNESS_SCRATCH")
        }
    }

    let sourceURL = workRoot.appendingPathComponent("src/feature.js")
    let testURL = workRoot.appendingPathComponent("tests/feature.test.js")
    try Data("export const featureValue = 1;\n".utf8).write(to: sourceURL)
    try Data("test('feature value');\n".utf8).write(to: testURL)

    func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    let runner = try MaintainShellRunner(repoRootPath: workRoot.path)
    let initialized = try await runner.run(
        "git init -q && git add src/feature.js tests/feature.test.js && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm baseline",
        deadline: 20
    )
    try require(initialized.succeeded, "could not initialize the disposable fixture")

    let brief = try HarnessTaskBrief(
        userRequest: "Change the fixture value",
        desiredOutcome: "The fixture exports the requested value",
        acceptanceCriteria: [
            .init(id: "value", statement: "The source exports featureValue equal to 2")
        ]
    )
    let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    var editCount = 0
    var repairCount = 0
    var reviewCount = 0
    var requests: [HarnessModelRequest] = []
    var readerStopped = false

    let buildMarker = scratchRoot.appendingPathComponent("build-checkpoint.log")
    let suiteMarker = scratchRoot.appendingPathComponent("suite-checkpoint.log")
    let buildCommand = "printf 'build\\n' >> \(shellQuoted(buildMarker.path))"
    let testCommand = "if grep -Eq 'featureValue = (1|2)' src/feature.js; then printf 'suite-pass\\n' >> \(shellQuoted(suiteMarker.path)); else printf 'CHECKPOINT_SUITE_FAILURE\\n' >> \(shellQuoted(suiteMarker.path)); printf 'CHECKPOINT_SUITE_FAILURE: expected featureValue 1 or 2\\n'; exit 17; fi"

    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: scenario == "review-reserve" ? 16 : 18, maxInputBytes: 2_000_000),
        maximumDurationNanoseconds: 180_000_000_000
    ) { request in
        requests.append(request)
        switch request.phase {
        case .intake:
            return HarnessModelReply(text: briefJSON)
        case .edit:
            editCount += 1
            if editCount <= 10 {
                return HarnessModelReply(text: """
                Keep the requested export.
                ```write src/feature.js
                export const featureValue = 2; // edit-\(editCount)
                ```
                """)
            }
            return HarnessModelReply(text: "DONE")
        case .review:
            reviewCount += 1
            if reviewCount == 1 {
                return HarnessModelReply(text: "ISSUE: the repair must retain the existing test path\nVERDICT: DISQUALIFYING")
            }
            return HarnessModelReply(text: "VERDICT: CLEAN")
        case .repair:
            repairCount += 1
            if repairCount == 1 {
                return HarnessModelReply(text: "Inspecting the changed source.\n```bash\nsed -n '1,10p' src/feature.js\n```")
            }
            // The first-review window now preserves correction capacity.
            // Spend that remaining capacity on another observation so this
            // countercase still tests a write at the final review boundary,
            // not the old initial-draft scheduling accident.
            if scenario == "review-reserve", repairCount == 2 {
                return HarnessModelReply(text: "Inspecting the declared suite.\n```bash\ncat tests/feature.test.js\n```")
            }
            if scenario == "review-reserve", repairCount == 3 {
                return HarnessModelReply(text: "The final repair write is incomplete.\n```write src/feature.js\nexport const featureValue = 3; // reserve-mutation\n```")
            }
            if repairCount == 2 {
                return HarnessModelReply(text: "The first repair write is intentionally incomplete.\n```write src/feature.js\nexport const featureValue = 3; // repair-mutation\n```")
            }
            let sawCheckpoint = requests
                .last(where: { $0.phase == .repair })?.conversation
                .contains(where: { $0.text.contains("EARLY TEST CHECKPOINT") }) == true
            if sawCheckpoint && repairCount == 3 {
                return HarnessModelReply(text: "The suite checkpoint identified the regression.\n```write src/feature.js\nexport const featureValue = 2; // repaired-after-checkpoint\n```")
            }
            return HarnessModelReply(text: "DONE")
        case .recheck:
            return HarnessModelReply(text: "DONE")
        }
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)
    _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "src/feature.js tests/feature.test.js")
    let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
    var events: [MaintainTierCProgressEvent] = []
    let result = await MaintainTierCFixer(provider: provider).attemptOnDemandEdit(
        clonePath: workRoot.path,
        appSlug: "repair-test-checkpoint-fixture",
        appStack: .electron,
        changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        request: brief.userRequest,
        kind: .feature,
        progressHandler: { event in
            events.append(event)
            if scenario == "cancel-after-write", repairCount == 2,
               case .editedFiles = event { readerStopped = true }
        },
        cancellationCheck: { readerStopped },
        manifestChangeApproval: { _ in false },
        verificationCommandsOverride: VerificationCommands(
            buildCommand: buildCommand,
            testCommand: scenario == "no-suite" ? nil : testCommand,
            commandSubdirectory: nil
        ),
        runsAnIndependentReview: true
    )

    let repairRequests = requests.filter { $0.phase == .repair }
    let editorRequests = requests.filter { $0.phase == .edit }
    let conversationText = requests.flatMap { $0.conversation.map(\.text) }.joined(separator: "\n")
    let sawEarlyBuild = conversationText.contains("EARLY BUILD CHECKPOINT")
    let sawEarlyTest = conversationText.contains("EARLY TEST CHECKPOINT")

#if CHECKPOINT_EXPECT_OLD
    try require(!sawEarlyTest, "pre-fix fixture unexpectedly received an early suite checkpoint")
    try require(repairRequests.count >= 3, "pre-fix fixture did not reach the final repair failure")
    guard case .couldNotComplete = result else {
        throw CheckError.failed("pre-fix fixture unexpectedly completed despite its unresolved suite failure")
    }
    let buildCheckpointState = sawEarlyBuild ? "observed" : "not observed"
    print("PRE-FIX REPRO PASS: early build was \(buildCheckpointState), no early test checkpoint, repair ended at suite failure, no commit")
#else
    if scenario != "repair" {
        try require(!sawEarlyTest, "\(scenario) unexpectedly ran the early suite checkpoint")
        if scenario == "no-suite" {
            try require(!fileManager.fileExists(atPath: suiteMarker.path),
                        "an undeclared suite command was invented")
        } else {
            guard case .couldNotComplete = result else {
                throw CheckError.failed("\(scenario) unexpectedly completed")
            }
            let status = try await runner.run("git status --porcelain", deadline: 10)
            try require(status.succeeded && status.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(scenario) failed to restore the private source fixture")
        }
        try require(workflow.modelSession.ledger.snapshot.admittedCallCount <= 18,
                    "\(scenario) exceeded the call limit")
        print("PASS repair test checkpoint guard: \(scenario)")
        return
    }
    try require(sawEarlyBuild, "the fixture did not exercise the existing one-shot build checkpoint")
    try require(sawEarlyTest, "the first successful repair write did not receive the early suite checkpoint")
    try require(repairRequests.count == 4, "the diagnostic checkpoint changed the bounded repair call sequence")
    try require(editorRequests.count == 11, "the initial editor call sequence changed")
    guard case .appliedAndRebuilt(_, _, _, let suitePassed, _) = result, suitePassed == true else {
        throw CheckError.failed("the checkpoint-assisted repair did not reach normal suite-green completion")
    }
    let suiteRuns = (try? String(contentsOf: suiteMarker, encoding: .utf8)) ?? ""
    try require(suiteRuns.contains("CHECKPOINT_SUITE_FAILURE"), "the diagnostic fixture did not observe its failing suite case")
    try require(suiteRuns.components(separatedBy: "\n").filter { !$0.isEmpty }.count >= 3,
                "the starting, diagnostic and final suite observations were not all recorded")
    try require(workflow.modelSession.ledger.snapshot.admittedCallCount == 18,
                "the local checkpoint consumed or created a model call")
    print("PASS repair test checkpoint: post-write confined suite failure reached the next repair without changing call caps")
#endif
}

#if CHECKPOINT_STANDALONE
@main
struct RepairTestCheckpointStandalone {
    @MainActor static func main() async throws {
        try await runRepairTestCheckpointChecks()
    }
}
#endif
