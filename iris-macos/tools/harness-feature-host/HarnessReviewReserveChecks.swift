import Foundation
@testable import IrisHarnessNative

private enum HarnessReviewReserveCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Test-only decorator for the real provider. The headless host cannot capture
/// an Iris Test registry declaration, so this keeps the production provider and
/// model session while exercising the existing two-call native review reserve.
@MainActor
private final class NativeReserveFixtureProvider: MaintainModelProviding,
    HarnessPhaseAwareModelProviding, HarnessBehaviorReviewProviding,
    HarnessExecutionObserving, HarnessReviewBudgetProviding {
    private let base: HarnessWorkflowMaintainProvider

    init(base: HarnessWorkflowMaintainProvider) { self.base = base }

    var displayName: String { base.displayName }
    var identifier: String { base.identifier }
    var requestedModelDescription: String { base.requestedModelDescription }
    var isAvailable: Bool { base.isAvailable }

    func respond(systemPrompt: String, conversation: [MaintainChatTurn],
                 maximumOutputTokens: Int) async throws -> String {
        try await base.respond(systemPrompt: systemPrompt, conversation: conversation,
                               maximumOutputTokens: maximumOutputTokens)
    }

    func setHarnessPhase(_ phase: HarnessRunTaskKind) { base.setHarnessPhase(phase) }

    func prepareBehaviorReview(revision: String, suitePassed: Bool, testCommand: String?,
                               suppliedFiles: [String: String], reviewPurpose: HarnessReviewPurpose) {
        base.prepareBehaviorReview(revision: revision, suitePassed: suitePassed,
            testCommand: testCommand, suppliedFiles: suppliedFiles, reviewPurpose: reviewPurpose)
    }

    func takeBehaviorRepairRequest() -> String? { base.takeBehaviorRepairRequest() }
    func observeEngineProgress(_ event: MaintainTierCProgressEvent) { base.observeEngineProgress(event) }

    func configureReviewStages(nativeChecksRequired: Bool) {
        base.configureReviewStages(nativeChecksRequired: true)
    }

    func beginVerification() { base.beginVerification() }
    var shouldYieldEditingToVerification: Bool { base.shouldYieldEditingToVerification }
    var shouldRunEarlyBuildCheckpoint: Bool { base.shouldRunEarlyBuildCheckpoint }
}

/// Exercises the real edit, verification and independent-review handoff with
/// a fake model transport. This is a headless fixture check, not an app run.
@MainActor
func runHarnessReviewReserveChecks() async throws {
    var diagnosticOutcome = VerificationOutcome()
    diagnosticOutcome.suite = .failed
    diagnosticOutcome.blockedStage = "suite"
    diagnosticOutcome.blockedOutputTail = "\u{1B}[31mfirst assertion\u{1B}[0m\nsecond assertion\n"
    let diagnosticReceipt = diagnosticOutcome.editReceipt
    guard diagnosticReceipt.failureOutputTail == "first assertion\nsecond assertion\n",
          !diagnosticReceipt.summary.contains("assertion") else {
        throw HarnessReviewReserveCheckError.failed("failure details must preserve separate lines without expanding the compact summary")
    }
    let credentialVariants = [
        "openai_api_key='lowercase-secret-with spaces'",
        "Authorization: Basic short-basic-credential",
        "x-api-key: short-header-credential",
        "client_secret=\"quoted-secret-value\"",
    ].joined(separator: "\n")
    diagnosticOutcome.blockedOutputTail = credentialVariants
    guard let scrubbedCredentialTail = diagnosticOutcome.editReceipt.failureOutputTail,
          !scrubbedCredentialTail.contains("lowercase-secret-with spaces"),
          !scrubbedCredentialTail.contains("short-basic-credential"),
          !scrubbedCredentialTail.contains("short-header-credential"),
          !scrubbedCredentialTail.contains("quoted-secret-value"),
          scrubbedCredentialTail.components(separatedBy: "[REDACTED]").count == 5 else {
        throw HarnessReviewReserveCheckError.failed("failure details did not scrub lowercase, header and quoted credential variants")
    }
    diagnosticOutcome.blockedOutputTail = String(repeating: "x", count: 5_000) + "\nlast assertion"
    guard let boundedTail = diagnosticOutcome.editReceipt.failureOutputTail,
          boundedTail.count <= 2_000, boundedTail.hasSuffix("last assertion") else {
        throw HarnessReviewReserveCheckError.failed("failure details exceeded their bound or dropped the final assertion")
    }
    diagnosticOutcome.blockedOutputTail = nil
    guard diagnosticOutcome.editReceipt.failureOutputTail == nil else {
        throw HarnessReviewReserveCheckError.failed("missing output was invented")
    }
    diagnosticOutcome.blockedStage = nil
    diagnosticOutcome.blockedOutputTail = "stale failure"
    guard diagnosticOutcome.editReceipt.failureOutputTail == nil else {
        throw HarnessReviewReserveCheckError.failed("successful verification retained stale failure details")
    }
    print("PASS verification diagnostics: multiline/control stripping, bounded tail, missing output and stale failure checks")
    let fileManager = FileManager.default
    let fixtureContainer = fileManager.temporaryDirectory
        .appendingPathComponent("iris-review-reserve-" + UUID().uuidString)
    let workRoot = fixtureContainer.appendingPathComponent("work")
    let scratchRoot = fixtureContainer.appendingPathComponent("scratch")
    try fileManager.createDirectory(at: workRoot.appendingPathComponent("src"),
                                    withIntermediateDirectories: true)
    try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

    let previousScratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"]
    setenv("IRIS_HARNESS_SCRATCH", scratchRoot.path, 1)
    defer {
        if let previousScratch { setenv("IRIS_HARNESS_SCRATCH", previousScratch, 1) }
        else { unsetenv("IRIS_HARNESS_SCRATCH") }
    }
    defer { try? fileManager.removeItem(at: fixtureContainer) }

    let sourceURL = workRoot.appendingPathComponent("src/feature.js")
    try Data("export const featureValue = 1;\n".utf8).write(to: sourceURL)
    let runner = try MaintainShellRunner(repoRootPath: workRoot.path)
    let initialized = try await runner.run(
        "git init -q && git add src/feature.js && git -c user.name=IrisFixture -c user.email=fixture@example.invalid commit -qm baseline",
        deadline: 20
    )
    guard initialized.succeeded else {
        throw HarnessReviewReserveCheckError.failed("could not initialize the private fixture Git repository")
    }
    let remotes = try await runner.run("git remote", deadline: 20)
    let status = try await runner.run("git status --porcelain", deadline: 20)
    guard remotes.succeeded, remotes.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          status.succeeded, status.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          try fileManager.contentsOfDirectory(atPath: scratchRoot.path).isEmpty else {
        throw HarnessReviewReserveCheckError.failed("fixture was not clean, remote-free and scratch-empty")
    }
    let baselineHead = try await runner.run("git rev-parse HEAD", deadline: 20)
    guard baselineHead.succeeded else {
        throw HarnessReviewReserveCheckError.failed("fixture baseline commit could not be read")
    }

    let brief = try HarnessTaskBrief(
        userRequest: "Change the fixture value",
        desiredOutcome: "The fixture exports the new value",
        acceptanceCriteria: [
            .init(id: "value", statement: "The source exports featureValue equal to 2")
        ]
    )
    let briefJSON = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    let editReply = """
    Update the source value.
    ```write src/feature.js
    export const featureValue = 2;
    ```
    """

    func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct ScenarioObservation {
        let result: MaintainOnDemandEditResult
        let phases: [HarnessRunTaskKind]
        let requests: [HarnessModelRequest]
        let events: [MaintainTierCProgressEvent]
        let admittedCallCount: UInt64
        let provider: HarnessWorkflowMaintainProvider
    }

    func runScenario(testCommand: String?, markerURLs: [URL], requireEditResponse: Bool = true) async throws -> ScenarioObservation {
        var phases: [HarnessRunTaskKind] = []
        var requests: [HarnessModelRequest] = []
        var editResponseCount = 0
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            // This scenario isolates the three-call boundary. Leave room for
            // the real editor prompt plus the independent review byte reserve;
            // exact byte-boundary refusal is exercised by session tests.
            settings: .init(maxCalls: 3, maxInputBytes: 500_000),
            maximumDurationNanoseconds: 120_000_000_000
        ) { request in
            phases.append(request.phase)
            requests.append(request)
            switch request.phase {
            case .intake:
                return HarnessModelReply(text: briefJSON)
            case .edit:
                editResponseCount += 1
                return HarnessModelReply(text: editReply)
            case .review:
                return HarnessModelReply(text: "VERDICT: CLEAN")
            case .repair, .recheck:
                return HarnessModelReply(text: editReply)
            }
        }
        let workflow = HarnessFeatureWorkflow(modelSession: session)
        _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "src/feature.js")
        let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
        let fixer = MaintainTierCFixer(provider: provider)
        var events: [MaintainTierCProgressEvent] = []
        let result = await fixer.attemptOnDemandEdit(
            clonePath: workRoot.path,
            appSlug: "fixture",
            appStack: .electron,
            changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            request: brief.userRequest,
            kind: .feature,
            progressHandler: { event in events.append(event) },
            cancellationCheck: { false },
            manifestChangeApproval: { _ in false },
            verificationCommandsOverride: VerificationCommands(
                buildCommand: "printf build > \(shellQuoted(markerURLs[0].path))",
                testCommand: testCommand,
                commandSubdirectory: nil
            ),
            runsAnIndependentReview: true
        )
        guard !requireEditResponse || (editResponseCount == 1 &&
              editReply.range(of: #"(?m)^\s*DONE\s*$"#, options: .regularExpression) == nil) else {
            throw HarnessReviewReserveCheckError.failed("the fixture editor response unexpectedly declared DONE or was duplicated")
        }
        return ScenarioObservation(result: result, phases: phases, requests: requests, events: events,
            admittedCallCount: session.ledger.snapshot.admittedCallCount, provider: provider)
    }

    func runEarlyBuildCheckpointScenario(
        maxCalls: Int,
        editReplies: [String],
        buildCommand: String?,
        cancellationAfterEditCount: Int? = nil,
        nativeReviewReserve: Bool = false
    ) async throws -> ScenarioObservation {
        var phases: [HarnessRunTaskKind] = []
        var requests: [HarnessModelRequest] = []
        var events: [MaintainTierCProgressEvent] = []
        var editResponseCount = 0
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: .init(maxCalls: maxCalls, maxInputBytes: 500_000),
            maximumDurationNanoseconds: 120_000_000_000
        ) { request in
            phases.append(request.phase)
            requests.append(request)
            switch request.phase {
            case .intake:
                return HarnessModelReply(text: briefJSON)
            case .edit:
                let reply = editResponseCount < editReplies.count
                    ? editReplies[editResponseCount] : "DONE"
                editResponseCount += 1
                return HarnessModelReply(text: reply)
            case .review:
                return HarnessModelReply(text: "COVERED: value | src/feature.js | featureValue remains 2\nVERDICT: CLEAN")
            case .repair, .recheck:
                return HarnessModelReply(text: "DONE")
            }
        }
        let workflow = HarnessFeatureWorkflow(modelSession: session)
        _ = try await workflow.plan(request: brief.userRequest, repositorySummary: "src/feature.js")
        let baseProvider = HarnessWorkflowMaintainProvider(workflow: workflow)
        let provider: MaintainModelProviding = nativeReviewReserve
            ? NativeReserveFixtureProvider(base: baseProvider)
            : baseProvider
        let fixer = MaintainTierCFixer(provider: provider)
        let result = await fixer.attemptOnDemandEdit(
            clonePath: workRoot.path,
            appSlug: "early-checkpoint-fixture",
            appStack: .electron,
            changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            request: brief.userRequest,
            kind: .feature,
            progressHandler: { event in events.append(event) },
            cancellationCheck: {
                guard let cancellationAfterEditCount else { return false }
                return editResponseCount >= cancellationAfterEditCount
            },
            manifestChangeApproval: { _ in false },
            verificationCommandsOverride: VerificationCommands(
                buildCommand: buildCommand,
                testCommand: nil,
                commandSubdirectory: nil
            ),
            runsAnIndependentReview: true
        )
        return ScenarioObservation(result: result, phases: phases, requests: requests, events: events,
            admittedCallCount: session.ledger.snapshot.admittedCallCount, provider: baseProvider)
    }

    func editorConversationText(_ observation: ScenarioObservation) -> String {
        observation.requests
            .filter { $0.phase == .edit }
            .flatMap { $0.conversation.map(\.text) }
            .joined(separator: "\n")
    }

    func startingObservationText(_ observation: ScenarioObservation) -> String {
        let conversation = editorConversationText(observation)
        guard let start = conversation.range(of: "OBSERVED STARTING TESTS, BEFORE YOUR EDIT") else {
            return ""
        }
        return String(conversation[start.lowerBound...])
    }

    let baselineRevision = baselineHead.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourcePath = shellQuoted(sourceURL.path)
    func resetFixtureToBaseline() async throws {
        let reset = try await runner.run("git reset --hard \(shellQuoted(baselineRevision))", deadline: 20)
        guard reset.succeeded else {
            throw HarnessReviewReserveCheckError.failed("could not reset the private fixture to its baseline between scenarios")
        }
    }

    let failingTestMarker = scratchRoot.appendingPathComponent("suite-failed")
    let failingBuildMarker = scratchRoot.appendingPathComponent("build-failed-case")
    let longCredential = String(repeating: "s", count: 3_500)
        + "LONG_TAIL_CANARY_"
        + String(repeating: "s", count: 1_500)
    let failingTestCommand = "printf suite > \(shellQuoted(failingTestMarker.path)); printf 'PROFILE_RESTART_ASSERTION_FAILED\\nOPENAI_API_KEY=FAKE_TEST_CREDENTIAL_123456789\\nOPENAI_API_KEY=BOUNDARY_PREFIX_\(longCredential)\\n'; exit 17"
    let failed = try await runScenario(testCommand: failingTestCommand,
                                       markerURLs: [failingBuildMarker, failingTestMarker])
    let editingPrompt = failed.requests.first(where: { $0.phase == .edit })?.systemPrompt ?? ""
    let normalizedEditingPrompt = editingPrompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard normalizedEditingPrompt.contains("Derive expected assertions from the agreed outcome")
            && normalizedEditingPrompt.contains("each user-decision check before reading current output")
            && normalizedEditingPrompt.contains("distinguishes the chosen behavior from the alternatives")
            && normalizedEditingPrompt.contains("populated state and preservation where relevant")
            && normalizedEditingPrompt.contains("Never rewrite an expected value to match current output")
            && normalizedEditingPrompt.contains("fix both implementation and assertion") else {
        throw HarnessReviewReserveCheckError.failed("editor prompt omitted the outcome-derived state-transition oracle contract")
    }
    print("PASS editor oracle contract: outcome-derived assertions, state transitions and regression-preserving expectations were supplied")
    let failedJournal = failed.provider.executionJournal.promptSection
    let failedHead = try await runner.run("git rev-parse HEAD", deadline: 20)
    let failedStatus = try await runner.run("git status --porcelain", deadline: 20)
    guard failed.phases.map(\.rawValue) == ["intake", "edit"], failed.admittedCallCount == 2,
          failed.provider.behaviorAssessment == nil,
          !failed.events.contains(where: {
              if case .verificationFailedPreparingRepair = $0 { return true }
              return false
          }),
          failed.events.contains(where: {
              if case .verifyingTheChange = $0 { return true }
              return false
          }),
          fileManager.fileExists(atPath: failingBuildMarker.path),
          fileManager.fileExists(atPath: failingTestMarker.path),
          failedHead.succeeded,
          failedHead.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
              == baselineHead.outputTail.trimmingCharacters(in: .whitespacesAndNewlines),
          failedStatus.succeeded,
          failedStatus.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          failedJournal.contains("PROFILE_RESTART_ASSERTION_FAILED"),
          !failedJournal.contains("FAKE_TEST_CREDENTIAL") else {
        throw HarnessReviewReserveCheckError.failed("failed suite spent review capacity, repaired unboundedly or left a source change")
    }
    guard case .couldNotComplete = failed.result else {
        throw HarnessReviewReserveCheckError.failed("a configured failing suite was counted as a successful edit")
    }
    guard let failedStartingCheckIndex = failed.events.firstIndex(where: {
              if case .checkingStartingTests = $0 { return true }
              return false
          }),
          let failedStartingResultIndex = failed.events.firstIndex(where: {
              if case .startingTestsChecked = $0 { return true }
              return false
          }),
          let failedFirstEditorWaitIndex = failed.events.firstIndex(where: {
              if case .waitingOnTheModel = $0 { return true }
              return false
          }),
          failedStartingCheckIndex < failedStartingResultIndex,
          failedStartingResultIndex < failedFirstEditorWaitIndex else {
        throw HarnessReviewReserveCheckError.failed("the starting-suite observation was not ordered before the first editor transport")
    }
    let failedStartingObservation = startingObservationText(failed)
    guard failedStartingObservation.contains("OBSERVED STARTING TESTS, BEFORE YOUR EDIT"),
          failedStartingObservation.contains("already failed before Iris edited any source"),
          failedStartingObservation.contains("PROFILE_RESTART_ASSERTION_FAILED"),
          !failedStartingObservation.contains("FAKE_TEST_CREDENTIAL"),
          !failedStartingObservation.contains("LONG_TAIL_CANARY") else {
        throw HarnessReviewReserveCheckError.failed("the failed starting-suite diagnostic did not reach the editor as scrubbed evidence")
    }
    guard failed.events.contains(where: {
        if case .verificationCompleted(let receipt) = $0 {
                return receipt.failureStage == "suite"
                    && receipt.failureOutputTail?.contains("PROFILE_RESTART_ASSERTION_FAILED") == true
                    && receipt.failureOutputTail?.contains("FAKE_TEST_CREDENTIAL") == false
                    && receipt.failureOutputTail?.contains("LONG_TAIL_CANARY") == false
                    && receipt.testsPassed == false
                    && !receipt.summary.contains("PROFILE_RESTART_ASSERTION_FAILED")
        }
        return false
    }) else {
        throw HarnessReviewReserveCheckError.failed("rollback lost the failing assertion, leaked its credential canary or cluttered the status summary")
    }
    print("PASS review reserve failure: build and suite ran, review and repair were not admitted, no success")
    print("PASS verification failure details: assertion retained before rollback, credential scrubbed, compact summary unchanged")
    print("PASS starting-suite failure: scrubbed baseline evidence reached the editor and the final failure still blocked")

    let baselinePassBuildMarker = scratchRoot.appendingPathComponent("build-baseline-pass")
    let baselinePassTestMarker = scratchRoot.appendingPathComponent("suite-baseline-pass")
    let baselinePassCommand = "printf suite > \(shellQuoted(baselinePassTestMarker.path)) && test -f \(sourcePath)"
    let baselinePass = try await runScenario(testCommand: baselinePassCommand,
                                             markerURLs: [baselinePassBuildMarker, baselinePassTestMarker])
    let baselinePassEditorConversation = editorConversationText(baselinePass)
    let baselinePassDiff = try await runner.run("git --no-pager diff HEAD~1 HEAD", deadline: 20)
    let baselinePassRevision = baselinePassDiff.succeeded
        ? HarnessFrozenComparison.digest(Data(baselinePassDiff.outputTail.utf8)) : ""
    guard baselinePass.phases.map(\.rawValue) == ["intake", "edit", "review"],
          baselinePass.admittedCallCount == 3,
          baselinePassEditorConversation.contains("The starting tests passed before Iris edited any source."),
          baselinePass.events.contains(where: {
              if case .startingTestsChecked(let summary) = $0 { return summary.contains("passed before Iris edited") }
              return false
          }),
          baselinePass.provider.behaviorAssessment?.permitsAutomaticDelivery(forRevision: baselinePassRevision) == false,
          baselinePassDiff.succeeded,
          baselinePassDiff.outputTail.contains("feature.js") else {
        throw HarnessReviewReserveCheckError.failed("a passing starting suite skipped the editor or was treated as final acceptance")
    }
    guard case .appliedAndRebuilt(_, _, _, let baselinePassSuitePassed, _) = baselinePass.result,
          baselinePassSuitePassed == true else {
        throw HarnessReviewReserveCheckError.failed("the passing starting suite did not retain its final suite result")
    }
    print("PASS starting-suite success: a pre-edit pass still required edit and review; incomplete review blocked automatic delivery")

    try await resetFixtureToBaseline()
    let noSuiteBuildMarker = scratchRoot.appendingPathComponent("build-no-suite")
    let noSuiteTestMarker = scratchRoot.appendingPathComponent("suite-no-suite")
    let noSuite = try await runScenario(testCommand: nil,
                                        markerURLs: [noSuiteBuildMarker, noSuiteTestMarker])
    let noSuiteEditorConversation = editorConversationText(noSuite)
    guard noSuite.phases.map(\.rawValue) == ["intake", "edit", "review"],
          noSuite.admittedCallCount == 3,
          !noSuite.events.contains(where: {
              if case .checkingStartingTests = $0 { return true }
              return false
          }),
          !noSuite.events.contains(where: {
              if case .startingTestsChecked = $0 { return true }
              return false
          }),
          !noSuiteEditorConversation.contains("OBSERVED STARTING TESTS, BEFORE YOUR EDIT"),
          fileManager.fileExists(atPath: noSuiteBuildMarker.path),
          !fileManager.fileExists(atPath: noSuiteTestMarker.path) else {
        throw HarnessReviewReserveCheckError.failed("a missing test command did not skip the starting-state check honestly")
    }
    guard case .appliedAndRebuilt(_, _, _, let noSuitePassed, _) = noSuite.result,
          noSuitePassed == nil else {
        throw HarnessReviewReserveCheckError.failed("a missing test command was silently counted as suite-green")
    }
    print("PASS no-suite path: starting check skipped and final suite result remained unknown")

    try await resetFixtureToBaseline()

    let passingBuildMarker = scratchRoot.appendingPathComponent("build-passed")
    let passingTestMarker = scratchRoot.appendingPathComponent("suite-passed")
    let passingTestCommand = "printf suite > \(shellQuoted(passingTestMarker.path)) && grep -q 'featureValue = 2' \(sourcePath)"
    let passed = try await runScenario(testCommand: passingTestCommand,
                                       markerURLs: [passingBuildMarker, passingTestMarker])
    let committedDiff = try await runner.run("git --no-pager diff HEAD~1 HEAD", deadline: 20)
    let currentRevision = committedDiff.succeeded
        ? HarnessFrozenComparison.digest(Data(committedDiff.outputTail.utf8))
        : ""
    guard passed.phases.map(\.rawValue) == ["intake", "edit", "review"], passed.admittedCallCount == 3,
          committedDiff.succeeded, committedDiff.outputTail.contains("feature.js"),
          fileManager.fileExists(atPath: passingBuildMarker.path),
          fileManager.fileExists(atPath: passingTestMarker.path),
          passed.events.contains(where: {
              if case .verifyingTheChange(let build, let test) = $0 {
                  return build?.contains("build-passed") == true && test?.contains("suite-passed") == true
              }
              return false
          }),
          passed.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.buildPassed == true && receipt.testsPassed == true
              }
              return false
          }),
          passed.provider.behaviorAssessment?.pending.count == 1,
          passed.provider.behaviorAssessment?.permitsAutomaticDelivery(forRevision: currentRevision) == false else {
        throw HarnessReviewReserveCheckError.failed("passing fixture did not reserve exactly one review call or did not block incomplete review delivery")
    }
    guard case .appliedAndRebuilt = passed.result else {
        throw HarnessReviewReserveCheckError.failed("passing fixture source was not saved through the existing verification path")
    }
    print("PASS review reserve success: intake, edit and review used three calls; build/test ran; incomplete review blocked delivery")

    try await resetFixtureToBaseline()
    let sameContentBuildMarker = scratchRoot.appendingPathComponent("build-same-content")
    let sameContentTestMarker = scratchRoot.appendingPathComponent("suite-same-content")
    let sameContentCopy = scratchRoot.appendingPathComponent("same-content-copy")
    let sameContentTestCommand = "cp \(sourcePath) \(shellQuoted(sameContentCopy.path)) && touch \(sourcePath) && cat \(shellQuoted(sameContentCopy.path)) > \(sourcePath) && printf suite > \(shellQuoted(sameContentTestMarker.path))"
    let sameContent = try await runScenario(testCommand: sameContentTestCommand,
                                             markerURLs: [sameContentBuildMarker, sameContentTestMarker])
    let sameContentDiff = try await runner.run("git --no-pager diff HEAD~1 HEAD", deadline: 20)
    guard sameContent.phases.map(\.rawValue) == ["intake", "edit", "review"],
          sameContent.admittedCallCount == 3,
          sameContent.events.contains(where: {
              if case .startingTestsChecked(let summary) = $0 {
                  return summary.contains("passed before Iris edited")
              }
              return false
          }),
          sameContent.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.buildPassed == true && receipt.testsPassed == true
              }
              return false
          }),
          sameContentDiff.succeeded,
          sameContentDiff.outputTail.contains("feature.js"),
          fileManager.fileExists(atPath: sameContentBuildMarker.path),
          fileManager.fileExists(atPath: sameContentTestMarker.path) else {
        throw HarnessReviewReserveCheckError.failed("a same-content baseline rewrite was mistaken for a tracked-source mutation")
    }
    guard case .appliedAndRebuilt(_, _, _, let sameContentSuitePassed, _) = sameContent.result,
          sameContentSuitePassed == true else {
        throw HarnessReviewReserveCheckError.failed("a same-content baseline rewrite blocked the edit or lost final suite verification")
    }
    print("PASS same-content baseline: touch and byte-identical rewrite did not block editor transport")

    try await resetFixtureToBaseline()
    let mutatingBuildMarker = scratchRoot.appendingPathComponent("build-mutating-start")
    let mutatingTestMarker = scratchRoot.appendingPathComponent("suite-mutating-start")
    let mutatingTestCommand = "printf 'export const featureValue = 99;\\n' > \(sourcePath); exit 17"
    let mutatingStart = try await runScenario(testCommand: mutatingTestCommand,
                                              markerURLs: [mutatingBuildMarker, mutatingTestMarker],
                                              requireEditResponse: false)
    let mutatedSource = try String(contentsOf: sourceURL, encoding: .utf8)
    guard mutatingStart.phases.map(\.rawValue) == ["intake"],
          mutatingStart.admittedCallCount == 1,
          !mutatingStart.requests.contains(where: { $0.phase == .edit }),
          !mutatingStart.events.contains(where: {
              if case .waitingOnTheModel = $0 { return true }
              return false
          }),
          mutatedSource == "export const featureValue = 99;\n",
          mutatingStart.events.contains(where: {
              if case .startingTestsChecked(let summary) = $0 {
                  return summary.contains("already failed before Iris edited")
              }
              return false
          }) else {
        throw HarnessReviewReserveCheckError.failed("a source-mutating starting suite reached the editor or was not surfaced as a baseline stop")
    }
    guard case .couldNotComplete(let reason) = mutatingStart.result,
          reason == "The starting tests changed tracked source, or its state could not be verified. Iris stopped and preserved that state for inspection." else {
        throw HarnessReviewReserveCheckError.failed("a source-mutating starting suite did not stop with an explicit inspection reason")
    }
    print("PASS source-mutating baseline: editor transport was not admitted and the mutated fixture was preserved for inspection")

    try await resetFixtureToBaseline()
    let checkpointFailureMarker = scratchRoot.appendingPathComponent("early-checkpoint-failure")
    let checkpointFailureBuild = "if grep -q checkpoint-pass \(sourcePath); then printf 'checkpoint-pass\\n' >> \(shellQuoted(checkpointFailureMarker.path)); else printf 'checkpoint-failure\\n' >> \(shellQuoted(checkpointFailureMarker.path)); exit 17; fi"
    let checkpointEditOne = """
    Update the source value while keeping the requested export.
    ```write src/feature.js
    export const featureValue = 2;
    ```
    """
    let checkpointEditTwo = """
    Keep working on the requested source change.
    ```write src/feature.js
    export const featureValue = 2; // intermediate-step-2
    ```
    """
    let checkpointEditThree = """
    Continue the source change.
    ```write src/feature.js
    export const featureValue = 2; // intermediate-step-3
    ```
    """
    let checkpointRepair = """
    The build checkpoint reported a failure. Repair the source and keep the export at 2.
    ```write src/feature.js
    export const featureValue = 2; // checkpoint-pass
    ```
    """
    let checkpointFailure = try await runEarlyBuildCheckpointScenario(
        maxCalls: 8,
        editReplies: [checkpointEditOne, checkpointEditTwo, checkpointEditThree, checkpointRepair],
        buildCommand: checkpointFailureBuild
    )
    let checkpointFailureConversation = editorConversationText(checkpointFailure)
    let checkpointFailureRuns = fileManager.fileExists(atPath: checkpointFailureMarker.path)
        ? try String(contentsOf: checkpointFailureMarker, encoding: .utf8)
        : ""
    guard checkpointFailure.phases.map(\.rawValue) == ["intake", "edit", "edit", "edit", "edit", "edit", "review"],
          checkpointFailure.admittedCallCount == 7,
          checkpointFailureConversation.contains("EARLY BUILD CHECKPOINT"),
          checkpointFailureConversation.contains("failed"),
          checkpointFailureConversation.contains("checkpoint-failure"),
          checkpointFailureRuns.components(separatedBy: "\n").filter({ !$0.isEmpty }).count == 2,
          checkpointFailureRuns.contains("checkpoint-failure"),
          checkpointFailureRuns.contains("checkpoint-pass"),
          checkpointFailure.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.buildPassed == true
              }
              return false
          }),
          checkpointFailure.events.contains(where: {
              if case .verifyingTheChange = $0 { return true }
              return false
          }) else {
        throw HarnessReviewReserveCheckError.failed("a failed early build checkpoint was not surfaced to a later edit without consuming the final review call")
    }
    guard case .appliedAndRebuilt = checkpointFailure.result else {
        throw HarnessReviewReserveCheckError.failed("a repaired early-build checkpoint did not reach final verification")
    }
    print("PASS early build checkpoint failure: failed declared build reached the next edit, repair succeeded and review remained admitted")

    try await resetFixtureToBaseline()
    let checkpointPassMarker = scratchRoot.appendingPathComponent("early-checkpoint-pass")
    let checkpointPassBuild = "printf 'checkpoint-pass\\n' >> \(shellQuoted(checkpointPassMarker.path)) && grep -q checkpoint-pass \(sourcePath)"
    let checkpointPassOne = """
    Make the requested source edit.
    ```write src/feature.js
    export const featureValue = 2; // checkpoint-pass-one
    ```
    """
    let checkpointPassTwo = """
    Continue the requested source edit.
    ```write src/feature.js
    export const featureValue = 2; // checkpoint-pass-two
    ```
    """
    let checkpointPassThree = """
    Finish the source edit while retaining the checkpoint canary.
    ```write src/feature.js
    export const featureValue = 2; // checkpoint-pass-three
    ```
    """
    let checkpointPass = try await runEarlyBuildCheckpointScenario(
        maxCalls: 8,
        editReplies: [checkpointPassOne, checkpointPassTwo, checkpointPassThree],
        buildCommand: checkpointPassBuild
    )
    let checkpointPassConversation = editorConversationText(checkpointPass)
    let checkpointPassRuns = fileManager.fileExists(atPath: checkpointPassMarker.path)
        ? try String(contentsOf: checkpointPassMarker, encoding: .utf8)
        : ""
    guard checkpointPass.phases.map(\.rawValue) == ["intake", "edit", "edit", "edit", "edit", "review"],
          checkpointPass.admittedCallCount == 6,
          checkpointPassConversation.contains("EARLY BUILD CHECKPOINT"),
          checkpointPassConversation.contains("passed"),
          checkpointPassRuns.components(separatedBy: "\n").filter({ !$0.isEmpty }).count == 2,
          checkpointPassRuns.components(separatedBy: "\n").filter({ !$0.isEmpty }).allSatisfy({ $0 == "checkpoint-pass" }),
          checkpointPass.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.buildPassed == true
              }
              return false
          }) else {
        throw HarnessReviewReserveCheckError.failed("a passing early build checkpoint skipped the later edit or final independent review")
    }
    guard case .appliedAndRebuilt = checkpointPass.result else {
        throw HarnessReviewReserveCheckError.failed("a passing early-build checkpoint did not preserve the normal verified result")
    }
    print("PASS early build checkpoint success: passing diagnostic reached the next edit and did not replace final verification or review")

    try await resetFixtureToBaseline()
    let patternScanMarker = scratchRoot.appendingPathComponent("early-pattern-scan")
    let patternScanBuild = "if test -e .git; then printf 'pattern-scan-final\\n' >> \(shellQuoted(patternScanMarker.path)); else printf 'pattern-scan-early\\n' >> \(shellQuoted(patternScanMarker.path)); fi"
    let patternEditOne = """
    Update the source and add the small transaction helper.
    ```write src/feature.js
    export const featureValue = 2; // pattern-scan-step-1
    ```
    ```write src/added-helper.js
    export async function finishTransaction(tx) {
      await tx.done.catch(() => {});
    }
    ```
    """
    let patternEditTwo = """
    Continue the requested source change.
    ```write src/feature.js
    export const featureValue = 2; // pattern-scan-step-2
    ```
    """
    let patternEditThree = """
    Continue the requested source change while keeping the helper.
    ```write src/feature.js
    export const featureValue = 2; // pattern-scan-step-3
    ```
    """
    let patternRepair = """
    The early code-pattern scan found an empty error handler. Preserve the original error for the caller.
    ```write src/feature.js
    export const featureValue = 2; // pattern-scan-repaired
    ```
    ```write src/added-helper.js
    export async function finishTransaction(tx) {
      return tx.done.then(
        () => undefined,
        (error) => {
          console.debug("transaction completed after abort", error);
        },
      );
    }
    ```
    """
    let patternScan = try await runEarlyBuildCheckpointScenario(
        maxCalls: 15,
        editReplies: [patternEditOne, patternEditTwo, patternEditThree, patternRepair],
        buildCommand: patternScanBuild,
        nativeReviewReserve: true
    )
    let patternScanConversation = editorConversationText(patternScan)
    let patternScanSecondEditConversation = patternScan.requests
        .filter { $0.phase == .edit }
        .dropFirst()
        .first?
        .conversation
        .map(\.text)
        .joined(separator: "\n") ?? ""
    let patternScanRuns = fileManager.fileExists(atPath: patternScanMarker.path)
        ? try String(contentsOf: patternScanMarker, encoding: .utf8)
        : ""
    guard patternScan.phases.map(\.rawValue) == ["intake", "edit", "edit", "edit", "edit", "edit", "review"],
          patternScan.admittedCallCount == 7,
          patternScanConversation.contains("EARLY CODE-PATTERN SCAN"),
          patternScanConversation.contains("swallowed error handler"),
          patternScanConversation.contains("src/added-helper.js"),
          patternScanSecondEditConversation.contains("EARLY CODE-PATTERN SCAN"),
          !patternScanConversation.contains("EARLY BUILD CHECKPOINT"),
          patternScanRuns.split(separator: "\n").map(String.init) == ["pattern-scan-final"],
          patternScan.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.buildPassed == true
              }
              return false
          }) else {
        throw HarnessReviewReserveCheckError.failed("the early code-pattern scan did not report an added-file finding before the repair edit")
    }
    guard case .appliedAndRebuilt = patternScan.result else {
        throw HarnessReviewReserveCheckError.failed("a repaired early code-pattern finding did not reach final verification")
    }
    print("PASS early code-pattern scan: the external-Git diff included an added file, diagnosed the finding before reserve and allowed a repair")

    try await resetFixtureToBaseline()
    let unrepairedPattern = try await runEarlyBuildCheckpointScenario(
        maxCalls: 3,
        editReplies: [patternEditOne],
        buildCommand: patternScanBuild
    )
    guard case .couldNotComplete(let unrepairedReason) = unrepairedPattern.result,
          unrepairedReason == "the fix failed verification (cheat-signature)",
          unrepairedPattern.phases.map(\.rawValue) == ["intake", "edit"],
          unrepairedPattern.admittedCallCount == 2,
          unrepairedPattern.events.contains(where: {
              if case .verificationCompleted(let receipt) = $0 {
                  return receipt.failureStage == "cheat-signature"
                      && receipt.failureOutputTail?.contains("src/added-helper.js") == true
              }
              return false
          }) else {
        throw HarnessReviewReserveCheckError.failed("the final anti-gaming gate did not reject an unrepaired added-file pattern")
    }
    print("PASS final code-pattern hard gate: an unrepaired added-file finding still rejected the change after build")

    try await resetFixtureToBaseline()
    let tinyCheckpointMarker = scratchRoot.appendingPathComponent("early-checkpoint-tiny")
    let tinyCheckpoint = try await runEarlyBuildCheckpointScenario(
        maxCalls: 3,
        editReplies: [editReply],
        buildCommand: "printf tiny > \(shellQuoted(tinyCheckpointMarker.path))"
    )
    let tinyCheckpointConversation = editorConversationText(tinyCheckpoint)
    guard tinyCheckpoint.phases.map(\.rawValue) == ["intake", "edit", "review"],
          tinyCheckpoint.admittedCallCount == 3,
          !tinyCheckpointConversation.contains("EARLY BUILD CHECKPOINT"),
          fileManager.fileExists(atPath: tinyCheckpointMarker.path) else {
        throw HarnessReviewReserveCheckError.failed("a tiny run spent checkpoint work or skipped the mandatory final review")
    }
    print("PASS early build checkpoint tiny-run guard: no checkpoint overhead was added before the final review reserve")

    try await resetFixtureToBaseline()
    let noDeclaredBuild = try await runEarlyBuildCheckpointScenario(
        maxCalls: 3,
        editReplies: [editReply],
        buildCommand: nil
    )
    let noDeclaredBuildConversation = editorConversationText(noDeclaredBuild)
    guard noDeclaredBuild.phases.map(\.rawValue) == ["intake", "edit", "review"],
          noDeclaredBuild.admittedCallCount == 3,
          !noDeclaredBuildConversation.contains("EARLY BUILD CHECKPOINT") else {
        throw HarnessReviewReserveCheckError.failed("a run without a declared build emitted a fabricated checkpoint or skipped final review")
    }
    print("PASS early build checkpoint no-build guard: no declared build produced no diagnostic and final review still ran")

    try await resetFixtureToBaseline()
    let cancellationMarker = scratchRoot.appendingPathComponent("early-checkpoint-cancelled")
    let cancellation = try await runEarlyBuildCheckpointScenario(
        maxCalls: 8,
        editReplies: [checkpointEditOne, checkpointEditTwo, checkpointEditThree],
        buildCommand: "printf cancelled > \(shellQuoted(cancellationMarker.path))",
        cancellationAfterEditCount: 3
    )
    let cancellationConversation = editorConversationText(cancellation)
    let cancellationStatus = try await runner.run("git status --porcelain", deadline: 20)
    guard case .couldNotComplete(let cancellationReason) = cancellation.result,
          cancellationReason == MaintainTierCFixer.stoppedByReaderReason,
          cancellation.phases.map(\.rawValue) == ["intake", "edit", "edit", "edit"],
          cancellation.admittedCallCount == 4,
          !cancellationConversation.contains("EARLY BUILD CHECKPOINT"),
          !fileManager.fileExists(atPath: cancellationMarker.path),
          cancellationStatus.succeeded,
          cancellationStatus.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HarnessReviewReserveCheckError.failed("cancellation at the checkpoint boundary ran a build or failed to restore the fixture")
    }
    print("PASS early build checkpoint cancellation: reader stop prevented checkpoint side effects and restored the fixture")
}
