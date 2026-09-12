import Foundation
@testable import IrisHarnessNative

/// Command-line fixture host, not an Iris application launch. No coordinator,
/// account service, recovery store, app inventory or publishing route is created.
@main
struct HarnessFeatureHost {
    enum HostError: Error { case invalidFixture, dirtyFixture, unusableSandbox, missingCLI, unsupportedMode }

    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do { try await run() }
        catch {
            print("HOST STOPPED: " + GuideAutopilotOutputBuffer.scrubbed(String(describing: error)))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        if CommandLine.arguments == [CommandLine.arguments[0], "--checks"] {
            try await checkOutputBudget()
            return
        }
        guard CommandLine.arguments.count == 3,
              ["--preflight", "--run"].contains(CommandLine.arguments[1]) else {
            throw HostError.unsupportedMode
        }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().standardizedFileURL
        let work = root.appendingPathComponent("work").resolvingSymlinksInPath()
        let scratch = root.appendingPathComponent("scratch").resolvingSymlinksInPath()
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("run.json"))) as? [String: Any]
        guard let taskID = marker?["task"] as? String,
              ["t5-js-filter-ops", "t7-js-export-queue"].contains(taskID) else {
            throw HostError.invalidFixture
        }
        let task = try fixtureTask(taskID)
        guard ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains(where: {
            root.path.hasPrefix($0)
        }) else {
            throw HostError.invalidFixture
        }
        guard root.lastPathComponent.hasPrefix("edit-battery-"), work.path == root.path + "/work",
              scratch.path == root.path + "/scratch",
              ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"] != nil,
              HarnessFixtureEnvironment.scratchDirectory.path == scratch.path,
              try fileManager.contentsOfDirectory(atPath: scratch.path).isEmpty,
              fileManager.fileExists(atPath: work.appendingPathComponent(".git").path) else {
            throw HostError.invalidFixture
        }
        guard let enumerator = fileManager.enumerator(at: work, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw HostError.invalidFixture
        }
        for case let entry as URL in enumerator {
            guard try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw HostError.invalidFixture
            }
        }
        let runner = try MaintainShellRunner(repoRootPath: work.path)
        let status = try await runner.run("git status --porcelain", deadline: 10)
        let remotes = try await runner.run("git remote", deadline: 10)
        let head = try await runner.run("git rev-parse HEAD", deadline: 10)
        guard status.succeeded, status.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              remotes.succeeded, remotes.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              head.succeeded, head.outputTail.trimmingCharacters(in: .whitespacesAndNewlines) == marker?["base"] as? String else {
            throw HostError.dirtyFixture
        }
        guard MaintainSandbox.isAvailable,
              let jailed = MaintainSandbox.jailedInvocation(forCommand: "printf ready", repoRootPath: work.path) else {
            throw HostError.unusableSandbox
        }
        let jailCheck = try await runner.run(jailed.invocation, deadline: 10)
        try? fileManager.removeItem(atPath: jailed.profilePath)
        guard jailCheck.succeeded, jailCheck.outputTail == "ready" else { throw HostError.unusableSandbox }
        guard CodexCLILogin.currentState().isUsable else { throw HostError.missingCLI }
        print("PREFLIGHT PASS: \(taskID), disposable clean Git fixture, no remote, fresh scratch, real sandbox, CLI login available")
        print("Route: requested Astra Medium planning, Astra Low implementation; max 10 calls, 1000000 input bytes, 10 minutes")
        guard CommandLine.arguments[1] == "--run" else { return }

        let workflow = try HarnessCodexAdapter.makeWorkflow(
            settings: HarnessRunLedgerSettings(maxCalls: 10, maxInputBytes: 1_000_000),
            maximumDurationNanoseconds: 600_000_000_000, webSearchEnabled: false)
        workflow.modelSession.ledgerDidChange = { snapshot in
            writeLedger(snapshot, root: root, printSummary: false)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let request = task.request
        let documentation = try String(contentsOf: work.appendingPathComponent(task.documentation), encoding: .utf8)
        guard documentation.utf8.count < 16_000 else { throw HostError.invalidFixture }
        let summary = FeatureEditRepoMap.summarize(repoRootPath: work.path, tokenBudget: 1800)
            + "\nRepository documentation:\n" + documentation
        do {
            print("PLANNING")
            let brief = try await workflow.plan(request: request, repositorySummary: summary)
            try encoder.encode(brief).write(to: root.appendingPathComponent("plan.json"), options: .atomic)
            guard brief.targetedQuestions.isEmpty else {
                print("NEEDS ANSWERS: plan.json contains the product questions. No edit started.")
                writeLedger(workflow.modelSession.ledger.snapshot, root: root)
                return
            }
            print("IMPLEMENTING: " + brief.desiredOutcome)
            let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
            let editor = MaintainTierCFixer(provider: provider)
            let changeID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let result = await editor.attemptOnDemandEdit(clonePath: work.path,
                appSlug: taskID, appStack: .electron, changeId: changeID,
                request: request, kind: .feature,
                progressHandler: { event in print("PROGRESS: " + String(describing: event)) },
                cancellationCheck: { Task.isCancelled }, manifestChangeApproval: { _ in false },
                verificationCommandsOverride: VerificationCommands(
                    buildCommand: task.buildCommand,
                    testCommand: task.testCommand, commandSubdirectory: nil),
                runsAnIndependentReview: true)
            let resultText = String(describing: result)
            try resultText.write(to: root.appendingPathComponent("engine-result.txt"), atomically: true, encoding: .utf8)
            print("ENGINE RESULT: " + resultText)
            let projectionStats: [String: Any] = ["originalConversationUTF8Bytes": provider.originalConversationBytes,
                                   "sentConversationUTF8Bytes": provider.sentConversationBytes,
                                   "compactedAssistantTurns": provider.compactedAssistantTurns,
                                   "compactedHistoricalObservationTurns": provider.compactedHistoricalObservationTurns,
                                   "conversationTargetWasExceeded": provider.conversationTargetWasExceeded]
            try JSONSerialization.data(withJSONObject: projectionStats, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("prompt-projection.json"), options: .atomic)
            if let assessment = provider.behaviorAssessment {
                try encoder.encode(assessment).write(to: root.appendingPathComponent("behavior-review.json"), options: .atomic)
                print("BEHAVIOR REVIEW: " + (assessment.permitsAutomaticDelivery ? "reviewed test coverage complete" : assessment.readerSummary))
            } else {
                print("BEHAVIOR REVIEW: incomplete; no review assessment was produced")
            }
            writeLedger(workflow.modelSession.ledger.snapshot, root: root)
        } catch {
            writeLedger(workflow.modelSession.ledger.snapshot, root: root)
            print("RUN FAILED: " + GuideAutopilotOutputBuffer.scrubbed(error.localizedDescription))
            throw error
        }
    }

    private struct FixtureTask {
        let request: String
        let documentation: String
        let buildCommand: String
        let testCommand: String
    }

    private static func fixtureTask(_ taskID: String) throws -> FixtureTask {
        let manifest = URL(fileURLWithPath: HarnessFixtureEnvironment.sourceRoot)
            .appendingPathComponent("iris-macos/tools/edit-battery/manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let tasks = object?["tasks"] as? [[String: Any]],
              let task = tasks.first(where: { $0["id"] as? String == taskID }),
              task["kind"] as? String == "feature",
              let request = task["request"] as? String, !request.isEmpty,
              let commands = task["verification_commands_override"] as? [String: Any],
              let build = commands["buildCommand"] as? String,
              let test = commands["testCommand"] as? String else { throw HostError.invalidFixture }
        let documentation = task["harness_documentation"] as? String ?? "docs/FILTERS.md"
        guard documentation.hasPrefix("docs/"), documentation.hasSuffix(".md"),
              !documentation.split(separator: "/").contains("..") else { throw HostError.invalidFixture }
        // Select only the public brief and reviewed verification commands.
        // Never forward the manifest's oracle, cause or reference metadata.
        return FixtureTask(request: request, documentation: documentation, buildCommand: build, testCommand: test)
    }

    @MainActor private static func checkOutputBudget() async throws {
        try await runUsageAttributionChecks()
        let complete = (1...120).map { "line \($0): " + String(repeating: "x", count: 50) }.joined(separator: "\n")
        guard MaintainTierCFixer.outputForModel(complete) != complete,
              MaintainTierCFixer.outputForModel(complete, maximumCharacters: 12_000) == complete,
              MaintainTierCFixer.outputForModel(complete, maximumCharacters: -1)
                == MaintainTierCFixer.outputForModel(complete),
              MaintainTierCFixer.outputForModel(String(repeating: complete, count: 4),
                maximumCharacters: Int.max).count < 14_000 else {
            throw HostError.invalidFixture
        }
        print("PASS output-budget checks: default preserved, related reads retained, limits clamped")
        let fixtureRoot = HarnessFixtureEnvironment.sourceRoot
            + "/iris-macos/tools/edit-battery/fixtures/t5-js-filter-ops/work"
        let context = FeatureEditRepositoryContext.collect(repoRootPath: fixtureRoot,
            relativePaths: ["src/operators.js", "src/filter.js"], maxBytes: 12_000)
        let prompt = MaintainTierCFixer.reviewPrompt(request: "Add numeric filters", kind: .feature,
            unifiedDiff: "diff omitted for this inert prompt check", evidenceLog: [], repositoryContext: context)
        let insufficient = FeatureEditAdversarialReviewer.parse(reply: "INSUFFICIENT: missing caller\nVERDICT: CLEAN")
        let malformed = FeatureEditAdversarialReviewer.parse(reply: "INSUFFICIENT:\nVERDICT: CLEAN")
        guard context.files.count == 2, prompt.user.contains("Number.isFinite(value)"),
              insufficient.isDisqualifying, insufficient.issues.isEmpty,
              !insufficient.readerFacingIssues.isEmpty, malformed.isDisqualifying else {
            throw HostError.invalidFixture
        }
        print("PASS integrated review checks: unchanged guard supplied, missing and malformed evidence never clear review")
        let brief = try HarnessTaskBrief(userRequest: "Queue exports and allow cancel", desiredOutcome: "Exports wait their turn",
            acceptanceCriteria: [.init(id: "queue", statement: "Jobs wait"), .init(id: "cancel", statement: "Cancel stops work")])
        let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        var reviews = 0
        let session = try HarnessModelSession(implementationArm: .astraLow,
            settings: .init(maxCalls: 10, maxInputBytes: 1_000_000), maximumDurationNanoseconds: 10_000_000_000) { request in
                if request.phase == .intake { return HarnessModelReply(text: briefJSON) }
                reviews += 1
                let cancellation = reviews == 1 ? "" : "COVERED: cancel | test/jobs.test.js | cancel stops\n"
                return HarnessModelReply(text: "COVERED: queue | test/jobs.test.js | jobs wait\n" + cancellation + "VERDICT: CLEAN")
            }
        let workflow = HarnessFeatureWorkflow(modelSession: session)
        _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "inert fixture")
        let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
        provider.setHarnessPhase(.review)
        let files = ["test/jobs.test.js": "test('jobs wait'); test('cancel stops');"]
        provider.prepareBehaviorReview(revision: "r1", suitePassed: true, testCommand: "node --test", suppliedFiles: files)
        _ = try await provider.respond(systemPrompt: "Inert review", conversation: [], maximumOutputTokens: 500)
        guard provider.behaviorAssessment?.pending.count == 1,
              provider.takeBehaviorRepairRequest() != nil, provider.takeBehaviorRepairRequest() == nil else { throw HostError.invalidFixture }
        provider.prepareBehaviorReview(revision: "r2", suitePassed: false, testCommand: nil, suppliedFiles: files)
        guard provider.behaviorAssessment == nil else { throw HostError.invalidFixture }
        _ = try await provider.respond(systemPrompt: "Inert review", conversation: [], maximumOutputTokens: 500)
        guard provider.behaviorAssessment?.permitsAutomaticDelivery == false else { throw HostError.invalidFixture }
        provider.prepareBehaviorReview(revision: "r3", suitePassed: true, testCommand: "node --test", suppliedFiles: files)
        _ = try await provider.respond(systemPrompt: "Inert review", conversation: [], maximumOutputTokens: 500)
        guard provider.behaviorAssessment?.permitsAutomaticDelivery == true else { throw HostError.invalidFixture }
        provider.setHarnessPhase(.repair)
        guard provider.behaviorAssessment == nil else { throw HostError.invalidFixture }
        let malformedSession = try HarnessModelSession(implementationArm: .astraLow,
            settings: .init(maxCalls: 10, maxInputBytes: 1_000_000), maximumDurationNanoseconds: 10_000_000_000) { request in
                HarnessModelReply(text: request.phase == .intake ? briefJSON
                    : "COVERED: queue | absent.test.js | missing\nISSUE: A cancellation assertion is swallowed\nVERDICT: DISQUALIFYING")
            }
        let malformedWorkflow = HarnessFeatureWorkflow(modelSession: malformedSession)
        _ = try await malformedWorkflow.plan(request: brief.userRequest, repositorySummary: "inert fixture")
        let malformedProvider = HarnessWorkflowMaintainProvider(workflow: malformedWorkflow)
        malformedProvider.setHarnessPhase(.review)
        malformedProvider.prepareBehaviorReview(revision: "r1", suitePassed: true,
            testCommand: "node --test", suppliedFiles: files)
        _ = try await malformedProvider.respond(systemPrompt: "Inert review", conversation: [], maximumOutputTokens: 500)
        guard malformedProvider.behaviorAssessment?.permitsAutomaticDelivery == false,
              malformedProvider.takeBehaviorRepairRequest()?.contains("assertion is swallowed") == true,
              malformedProvider.takeBehaviorRepairRequest() == nil else { throw HostError.invalidFixture }
        print("PASS native behavior wiring: partial coverage repairs once, stale review cleared, skipped suite blocks, complete reviewed coverage allows")
        let reviewContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-review-check-" + UUID().uuidString)
        let reviewRoot = reviewContainer.appendingPathComponent("work")
        let reviewScratch = reviewContainer.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: reviewRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reviewScratch, withIntermediateDirectories: false)
        let previousScratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"]
        setenv("IRIS_HARNESS_SCRATCH", reviewScratch.path, 1)
        defer {
            if let previousScratch { setenv("IRIS_HARNESS_SCRATCH", previousScratch, 1) }
            else { unsetenv("IRIS_HARNESS_SCRATCH") }
            try? FileManager.default.removeItem(at: reviewContainer)
        }
        try Data("export const oldValue = 1;\n".utf8).write(to: reviewRoot.appendingPathComponent("old.js"))
        let reviewRunner = try MaintainShellRunner(repoRootPath: reviewRoot.path)
        let initialized = try await reviewRunner.run("git init -q && git add old.js && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm baseline", deadline: 20)
        guard initialized.succeeded else { throw HostError.invalidFixture }
        try Data("export const newValue = 2;\n".utf8).write(to: reviewRoot.appendingPathComponent("new.js"))
        let indexURL = reviewRoot.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let newFileDiff = await MaintainTierCFixer.reviewDiffIncludingNewFiles(runner: reviewRunner, repoRootPath: reviewRoot.path)
        guard let newFileDiff, newFileDiff.contains("new.js"), newFileDiff.contains("newValue"),
              try Data(contentsOf: indexURL) == indexBefore else { throw HostError.invalidFixture }
        let committed = try await reviewRunner.run("git add -A && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm feature && git --no-pager diff HEAD~1 HEAD", deadline: 20)
        guard committed.succeeded,
              HarnessFrozenComparison.digest(Data(newFileDiff.utf8)) == HarnessFrozenComparison.digest(Data(committed.outputTail.utf8)) else {
            throw HostError.invalidFixture
        }
        print("PASS review snapshot: new files included, original index unchanged, committed revision matches")
        try await checkExecutionContext()
        try await runHarnessReviewReserveChecks()
        try runVerificationDiagnosticChecks()
        try await runRepairTestCheckpointChecks()
        try await runCommandFreshnessChecks()
        try await runRepairWindowChecks()
    }

    @MainActor private static func checkExecutionContext() async throws {
        let longHistory = (0..<100).map { index in
            MaintainChatTurn(role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "Exact turn \(index)", attachedImagePNGData: index == 0 ? Data([1, 2, 3]) : nil)
        }
        let preserved = MaintainTierCFixer.conversationWindowedForSending(longHistory,
            preservesHarnessHistory: true)
        guard preserved.map(\.text) == longHistory.map(\.text),
              preserved.first?.attachedImagePNGData == Data([1, 2, 3]),
              MaintainTierCFixer.conversationWindowedForSending(longHistory).count < longHistory.count
            else { throw HostError.invalidFixture }
        let brief = try HarnessTaskBrief(userRequest: "Build the queue without sending anything",
            desiredOutcome: "Queue exports locally",
            acceptanceCriteria: [.init(id: "queue", statement: "Jobs wait")])
        let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        let patch = "I am implementing the current piece.\n```write src/queue.js\n"
            + String(repeating: "// A source line in this fixture\n", count: 250) + "```\n"
        let parsed = MaintainFileEditApplier.parseDetailed(fromModelReply: patch)
        guard parsed.requests.count == 1, parsed.rejections.isEmpty else { throw HostError.invalidFixture }
        var requests: [HarnessModelRequest] = []
        let session = try HarnessModelSession(implementationArm: .astraLow,
            settings: .init(maxCalls: 10, maxInputBytes: 1_000_000), maximumDurationNanoseconds: 10_000_000_000) { request in
                requests.append(request)
                return HarnessModelReply(text: request.phase == .intake ? briefJSON : patch)
            }
        let workflow = HarnessFeatureWorkflow(modelSession: session)
        _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "inert fixture")
        let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
        var conversation = [MaintainChatTurn(role: "user", text: "Do not press Send.")]
        for step in 1...4 {
            let reply = try await provider.respond(systemPrompt: "Inert edit", conversation: conversation, maximumOutputTokens: 1000)
            provider.observeEngineProgress(.appliedStructuredFileEdits(paths: ["edited src/queue.js"]))
            provider.observeEngineProgress(.editedFiles(paths: ["src/queue.js"], stepNumber: step))
            conversation.append(MaintainChatTurn(role: "assistant", text: reply))
            conversation.append(MaintainChatTurn(role: "user", text: "Applied. Continue without sending anything."))
        }
        _ = try await provider.respond(systemPrompt: "Inert edit", conversation: conversation, maximumOutputTokens: 1000)
        guard provider.compactedAssistantTurns > 0,
              provider.sentConversationBytes < provider.originalConversationBytes,
              requests.last?.conversation.first?.text == "Do not press Send.",
              provider.executionJournal.changedPaths == ["src/queue.js"],
              requests.last?.systemPrompt.contains("Source edit sequence: 4") == true else { throw HostError.invalidFixture }
        print("PASS execution context: confirmed edit receipts compact old payloads, explicit instructions and current source record retained")
        print("INERT REPLAY BYTES: \(provider.originalConversationBytes) -> \(provider.sentConversationBytes); this is prompt text, not measured model tokens")
        // Mixed success followed by a rejection must revoke the receipt before
        // the next request. The full attempted patch remains available to fix.
        provider.observeEngineProgress(.appliedStructuredFileEdits(paths: ["edited src/queue.js"]))
        provider.observeEngineProgress(.editedFiles(paths: ["src/queue.js"], stepNumber: 5))
        provider.observeEngineProgress(.structuredFileEditRejected(reason: "The second patch did not match"))
        provider.observeEngineProgress(.jailedCommandFinished(exitCode: 1, duration: 0,
            outputTailLines: ["Fixture command failed"]))
        _ = try await provider.respond(systemPrompt: "Inert repair", conversation: conversation, maximumOutputTokens: 1000)
        guard requests.last?.conversation.map(\.text) == conversation.map(\.text),
              requests.last?.systemPrompt.contains("The second patch did not match") == true,
              requests.last?.systemPrompt.contains("Command 1 exited 1") == true else { throw HostError.invalidFixture }
        print("PASS failure context: partial-edit rejection revokes compaction and command failure remains visible")
        let originalBeforeRefusal = provider.originalConversationBytes
        let sentBeforeRefusal = provider.sentConversationBytes
        _ = try? await provider.respond(systemPrompt: "Must not be submitted", conversation: conversation, maximumOutputTokens: 0)
        guard provider.originalConversationBytes == originalBeforeRefusal,
              provider.sentConversationBytes == sentBeforeRefusal else { throw HostError.invalidFixture }
        print("PASS projection accounting: refused calls do not count as submitted conversation data")
    }

    @MainActor private static func writeLedger(_ snapshot: HarnessRunLedgerSnapshot, root: URL,
                                               printSummary: Bool = true) {
        let allSettled = snapshot.inFlightCallCount == 0
        let summary: [String: Any] = [
            "admittedCalls": snapshot.admittedCallCount,
            "settledCalls": snapshot.settledCallCount,
            "inFlightCalls": snapshot.inFlightCallCount,
            "submittedInputBytes": snapshot.accountedInputBytes,
            "inputTokens": allSettled ? (snapshot.measuredInputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "cachedInputTokens": allSettled ? (snapshot.measuredCachedInputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "outputTokens": allSettled ? (snapshot.measuredOutputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "reasoningOutputTokens": allSettled ? (snapshot.measuredReasoningOutputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "calls": snapshot.settledCalls.map { record -> [String: Any] in
                ["phase": record.reservation.task.rawValue,
                 "inputBytes": record.accountedInputBytes,
                 "inputTokens": record.inputTokens.map { $0 as Any } ?? NSNull(),
                 "cachedInputTokens": record.cachedInputTokens.map { $0 as Any } ?? NSNull(),
                 "outputTokens": record.outputTokens.map { $0 as Any } ?? NSNull(),
                 "reasoningOutputTokens": record.reasoningOutputTokens.map { $0 as Any } ?? NSNull()]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            do { try data.write(to: root.appendingPathComponent("usage.json"), options: .atomic) }
            catch { print("USAGE CHECKPOINT FAILED: reported usage may not survive a host exit") }
            if printSummary { print("USAGE: " + String(decoding: data, as: UTF8.self)) }
        }
    }
}
