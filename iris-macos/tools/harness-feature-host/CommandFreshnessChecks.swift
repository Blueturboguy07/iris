import Foundation
@testable import IrisHarnessNative

private enum CommandFreshnessCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Exercises command deduplication against the real edit loop with an inert
/// model transport and disposable Git fixtures.
@MainActor
func runCommandFreshnessChecks() async throws {
    try runCommandFreshnessByteChecks()
    try await runCommandFreshnessEditScenario()
    try await runCommandFreshnessInvestigationScenario()
    print("PASS command freshness checks: source-change invalidation, no-op/rejected edits and lifetime investigation history")
}

@MainActor
private func runCommandFreshnessByteChecks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-command-freshness-bytes-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.txt")
    let decomposed = "e\u{301}"
    let composed = "\u{e9}"
    try Data(decomposed.utf8).write(to: file)
    let result = MaintainFileEditApplier.applyToRepo(
        .replaceInFile(filePath: "note.txt", search: decomposed, replace: composed),
        repoRootPath: root.path)
    guard case .success = result, try Data(contentsOf: file) == Data(composed.utf8) else {
        throw CommandFreshnessCheckError.failed("normalization-only byte change was incorrectly skipped")
    }
    let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    let unchanged = MaintainFileEditApplier.applyToRepo(
        .replaceInFile(filePath: "note.txt", search: composed, replace: composed),
        repoRootPath: root.path)
    let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    guard case .success(let description) = unchanged,
          description.hasPrefix("unchanged"), before == after else {
        throw CommandFreshnessCheckError.failed("identical replacement altered source metadata")
    }
}

@MainActor
private func runCommandFreshnessEditScenario() async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CommandFreshnessCheckError.failed(message) }
    }

    func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    let fileManager = FileManager.default
    let container = fileManager.temporaryDirectory
        .appendingPathComponent("iris-command-freshness-" + UUID().uuidString)
    let workRoot = container.appendingPathComponent("work")
    let scratchRoot = container.appendingPathComponent("scratch")
    try fileManager.createDirectory(
        at: workRoot.appendingPathComponent("src"), withIntermediateDirectories: true
    )
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
    try Data("export const featureValue = 1;\n".utf8).write(to: sourceURL)
    let runner = try MaintainShellRunner(repoRootPath: workRoot.path)
    let initialized = try await runner.run(
        "git init -q && git add src/feature.js && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm baseline",
        deadline: 20
    )
    try require(initialized.succeeded, "could not initialize the disposable freshness fixture")

    let brief = try HarnessTaskBrief(
        userRequest: "Change the fixture value",
        desiredOutcome: "The fixture exports the requested value",
        acceptanceCriteria: [
            .init(id: "value", statement: "The source exports featureValue equal to 2")
        ]
    )
    let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    let exactCommand = "printf 'COMMAND_FRESHNESS_CANARY\\n'"
    let noOpStructuredEdit = """
    ```write src/feature.js
    export const featureValue = 2;
    ```
    """
    let rejectedStructuredEdit = """
    ```edit src/feature.js
    <<<<<<< SEARCH
    this text is not in the fixture
    =======
    export const featureValue = 99;
    >>>>>>> REPLACE
    ```
    """
    var editReplyNumber = 0
    var executedCommands: [String] = []
    var events: [MaintainTierCProgressEvent] = []

    let buildMarker = scratchRoot.appendingPathComponent("build-ran")
    let suiteMarker = scratchRoot.appendingPathComponent("suite-ran")
    let buildCommand = "printf 'build\\n' >> \(shellQuoted(buildMarker.path))"
    let testCommand = "printf 'suite\\n' >> \(shellQuoted(suiteMarker.path))"
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 20, maxInputBytes: 2_000_000),
        maximumDurationNanoseconds: 120_000_000_000
    ) { request in
        switch request.phase {
        case .intake:
            return HarnessModelReply(text: briefJSON)
        case .edit:
            editReplyNumber += 1
            switch editReplyNumber {
            case 1, 3, 4, 6, 8:
                return HarnessModelReply(text: "Read-only check.\n```bash\n\(exactCommand)\n```")
            case 2:
                return HarnessModelReply(text: "Apply the requested source change.\n"
                    + "```write src/feature.js\nexport const featureValue = 2;\n```")
            case 5:
                return HarnessModelReply(text: noOpStructuredEdit)
            case 7:
                return HarnessModelReply(text: rejectedStructuredEdit)
            case 9:
                return HarnessModelReply(text: "DONE")
            default:
                throw CommandFreshnessCheckError.failed("the freshness fixture requested an unexpected edit response")
            }
        case .review:
            return HarnessModelReply(text: "VERDICT: CLEAN")
        case .repair, .recheck:
            throw CommandFreshnessCheckError.failed("the freshness fixture unexpectedly entered a repair or recheck phase")
        }
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)
    _ = try await workflow.plan(
        request: brief.userRequest,
        repositorySummary: "src/feature.js"
    )
    let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
    let result = await MaintainTierCFixer(provider: provider).attemptOnDemandEdit(
        clonePath: workRoot.path,
        appSlug: "command-freshness-fixture",
        appStack: .electron,
        changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        request: brief.userRequest,
        kind: .feature,
        progressHandler: { event in
            events.append(event)
            if case .runningJailedCommand(let command, _) = event {
                executedCommands.append(command)
            }
        },
        cancellationCheck: { false },
        manifestChangeApproval: { _ in false },
        verificationCommandsOverride: VerificationCommands(
            buildCommand: buildCommand,
            testCommand: testCommand,
            commandSubdirectory: nil
        ),
        runsAnIndependentReview: false
    )

    try require(executedCommands == [exactCommand, exactCommand],
                "a duplicate command was not suppressed after an unchanged, no-op or rejected edit")
    let appliedStructuredEditCount = events.reduce(into: 0) { count, event in
        if case .appliedStructuredFileEdits = event { count += 1 }
    }
    let rejectedStructuredEditCount = events.reduce(into: 0) { count, event in
        if case .structuredFileEditRejected = event { count += 1 }
    }
    try require(appliedStructuredEditCount == 2,
                "the real source write and no-op structured edit were not both exercised")
    try require(rejectedStructuredEditCount == 1,
                "the rejected structured edit was not exercised")
    try require(editReplyNumber == 9,
                "the unchanged command sequence did not reach DONE at its expected step")
    guard case .appliedAndRebuilt(_, _, .feature, let suitePassed, false) = result else {
        throw CommandFreshnessCheckError.failed("the command freshness fixture did not complete through the normal edit result")
    }
    try require(suitePassed == true, "the command freshness fixture did not run its declared suite")
    try require(fileManager.fileExists(atPath: buildMarker.path),
                "the final build command did not execute")
    try require(fileManager.fileExists(atPath: suiteMarker.path),
                "the final suite command did not execute")
}

@MainActor
private func runCommandFreshnessInvestigationScenario() async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CommandFreshnessCheckError.failed(message) }
    }

    let fileManager = FileManager.default
    let container = fileManager.temporaryDirectory
        .appendingPathComponent("iris-command-history-" + UUID().uuidString)
    let workRoot = container.appendingPathComponent("work")
    let scratchRoot = container.appendingPathComponent("scratch")
    try fileManager.createDirectory(
        at: workRoot.appendingPathComponent("src"), withIntermediateDirectories: true
    )
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
    try Data("export const featureValue = 1;\n".utf8).write(to: sourceURL)
    let runner = try MaintainShellRunner(repoRootPath: workRoot.path)
    let initialized = try await runner.run(
        "git init -q && git add src/feature.js && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm baseline",
        deadline: 20
    )
    try require(initialized.succeeded, "could not initialize the disposable history fixture")

    let brief = try HarnessTaskBrief(
        userRequest: "Change the fixture value",
        desiredOutcome: "The fixture exports the requested value",
        acceptanceCriteria: [
            .init(id: "value", statement: "The source exports featureValue equal to 2")
        ]
    )
    let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    let exactCommand = "printf 'COMMAND_HISTORY_CANARY\\n'"
    var editReplyNumber = 0
    var executedCommands: [String] = []
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 12, maxInputBytes: 1_000_000),
        maximumDurationNanoseconds: 120_000_000_000
    ) { request in
        switch request.phase {
        case .intake:
            return HarnessModelReply(text: briefJSON)
        case .edit:
            editReplyNumber += 1
            switch editReplyNumber {
            case 1:
                return HarnessModelReply(text: "Inspect the current state.\n```bash\n\(exactCommand)\n```")
            case 2:
                return HarnessModelReply(text: "Apply the source change.\n"
                    + "```write src/feature.js\nexport const featureValue = 2;\n```")
            case 3:
                return HarnessModelReply(text: "BLOCKED: the remaining cause is outside this repository.\n"
                    + "QUESTION: Should the machine-side setting be checked?")
            default:
                throw CommandFreshnessCheckError.failed("the history fixture requested an unexpected edit response")
            }
        case .review:
            throw CommandFreshnessCheckError.failed("the history fixture unexpectedly entered review")
        case .repair, .recheck:
            throw CommandFreshnessCheckError.failed("the history fixture unexpectedly entered repair or recheck")
        }
    }
    let workflow = HarnessFeatureWorkflow(modelSession: session)
    _ = try await workflow.plan(
        request: brief.userRequest,
        repositorySummary: "src/feature.js"
    )
    let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
    let result = await MaintainTierCFixer(provider: provider).attemptOnDemandEdit(
        clonePath: workRoot.path,
        appSlug: "command-history-fixture",
        appStack: .electron,
        changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        request: brief.userRequest,
        kind: .feature,
        progressHandler: { event in
            if case .runningJailedCommand(let command, _) = event {
                executedCommands.append(command)
            }
        },
        cancellationCheck: { false },
        manifestChangeApproval: { _ in false },
        verificationCommandsOverride: VerificationCommands(
            buildCommand: nil, testCommand: nil, commandSubdirectory: nil
        ),
        runsAnIndependentReview: false
    )

    guard case .blockedByModel(let explanation, let question) = result else {
        throw CommandFreshnessCheckError.failed("commandsAlreadyRun history did not permit a post-edit BLOCKED declaration")
    }
    try require(explanation.contains("outside this repository") && question?.contains("machine-side") == true,
                "the lifetime investigation gate did not preserve the model's blocked explanation")
    try require(executedCommands == [exactCommand],
                "the lifetime investigation command did not execute exactly once")
    try require(editReplyNumber == 3,
                "the lifetime investigation gate consumed an unexpected edit response")
    let status = try await runner.run("git status --porcelain", deadline: 10)
    try require(status.succeeded
                    && status.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the post-edit blocked outcome did not restore the disposable fixture")
    try require(fileManager.fileExists(atPath: sourceURL.path),
                "the post-edit blocked outcome removed the baseline source")
    let restoredSource = try String(contentsOf: sourceURL, encoding: .utf8)
    try require(restoredSource == "export const featureValue = 1;\n",
                "the post-edit blocked outcome did not restore source content")
}
