import CryptoKit
import Darwin
import Foundation

@testable import IrisHarnessNative

/// A small Test-bundle regression for the native-review repair boundary. The
/// model transport is inert. The fixer, provider, serializer and jailed Git
/// runner are real. This never launches the declared native executable because
/// the native code-admission reply is deliberately negative.
@main
struct UnadmittedRepairChecks {
    private enum CheckFailure: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    nonisolated private enum Scenario: String, CaseIterable {
        case unadmittedRepair
        case admittedNoOpRepair
        case admittedChangedRepair
        case unadmittedSourceChanged
        case unadmittedCancelled

        var deniesRepair: Bool {
            self == .unadmittedRepair || self == .unadmittedSourceChanged || self == .unadmittedCancelled
        }
    }

    private static var expectedUnadmittedReviewCount: Int {
#if UNADMITTED_EXPECT_OLD
        return 2
#else
        return 1
#endif
    }

    nonisolated private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var requestValues: [HarnessModelRequest] = []
        private var admittedBytesValue: UInt64 = 0
        private var refusedRepairCountValue = 0
        private var reviewCountValue = 0
        private var repairCountValue = 0
        private var nativeReviewWasReturnedValue = false
        private var serializerCouldNotForceValue = false
        private var cancelledValue = false

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelledValue
        }

        func cancel() {
            lock.lock()
            cancelledValue = true
            lock.unlock()
        }

        var requests: [HarnessModelRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requestValues
        }

        var admittedBytes: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return admittedBytesValue
        }

        var refusedRepairCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return refusedRepairCountValue
        }

        var reviewCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reviewCountValue
        }

        var repairCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return repairCountValue
        }

        var serializerCouldNotForce: Bool {
            lock.lock()
            defer { lock.unlock() }
            return serializerCouldNotForceValue
        }

        func admissionBytes(
            for request: HarnessModelRequest,
            actualBytes: UInt64,
            maximumInputBytes: UInt64,
            preservedReviewBytes: UInt64,
            scenario: Scenario
        ) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }

            // The counter first computes the same Codex prompt shape as the
            // production adapter. Only the one refused repair is moved to the
            // exact byte boundary, which makes this a deterministic control
            // flow regression without changing production accounting.
            guard scenario.deniesRepair,
                  request.phase == .repair,
                  nativeReviewWasReturnedValue,
                  refusedRepairCountValue == 0 else {
                return actualBytes
            }

            let remaining = maximumInputBytes >= admittedBytesValue
                ? maximumInputBytes - admittedBytesValue : 0
            let availableAfterReview = remaining >= preservedReviewBytes
                ? remaining - preservedReviewBytes : 0
            guard availableAfterReview < remaining else {
                serializerCouldNotForceValue = true
                return actualBytes
            }
            let boundary = availableAfterReview == UInt64.max
                ? UInt64.max : availableAfterReview + 1
            guard boundary <= remaining else {
                serializerCouldNotForceValue = true
                return actualBytes
            }
            refusedRepairCountValue += 1
            return max(actualBytes, boundary)
        }

        func recordAdmitted(
            request: HarnessModelRequest,
            inputBytes: UInt64
        ) {
            lock.lock()
            requestValues.append(request)
            admittedBytesValue += inputBytes
            switch request.phase {
            case .repair:
                repairCountValue += 1
            case .review:
                reviewCountValue += 1
            default:
                break
            }
            lock.unlock()
        }

        func markReviewReturned() {
            lock.lock()
            nativeReviewWasReturnedValue = true
            lock.unlock()
        }
    }

    private struct Fixture {
        let projectRoot: URL
        let clone: URL
        let application: URL
        let artifact: URL
        let scratch: URL
        let registryURL: URL
        let originalRegistryData: Data?
        let originalRegistryExisted: Bool
        let runner: MaintainShellRunner
        let sourceURL: URL
        let testURL: URL
        let project: IrisTestProjectRegistry.Project
        let briefJSON: String
        let verificationCommands: VerificationCommands
        let baselineSource: String
        let baselineHead: String
    }

    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard IrisTestEnvironment.isEnabled else {
            print("SKIP unadmitted repair checks: requires the Iris Test bundle")
            return
        }
        guard ProcessInfo.processInfo.environment["IRIS_UNADMITTED_FIXTURE_ROOT"] != nil else {
            print("SKIP unadmitted repair checks: set IRIS_UNADMITTED_FIXTURE_ROOT to a fresh direct child of /Users/Shared")
            return
        }
        do {
            try await runChecks()
            print("UNADMITTED REPAIR CHECKS PASS: 5 native review/repair boundary groups; disposable Test fixture only")
        } catch {
            print("UNADMITTED REPAIR CHECKS FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func runChecks() async throws {
        _ = try isolatedFixtureRoot()
        guard case .test = MaintainSandbox.runtimeProcessPolicy() else {
            throw CheckFailure.failed("the IRIS_TEST_BUILD Test process policy was unavailable")
        }
        var completed = 0
        for scenario in Scenario.allCases {
            let observation = try await runScenario(scenario)
            let requests = observation.requests
            let reviews = requests.filter { $0.phase == .review }
            let repairs = requests.filter { $0.phase == .repair }
            let expectedReviews = scenario == .unadmittedRepair
                ? expectedUnadmittedReviewCount : scenario == .unadmittedCancelled ? 1 : 2
            try require(reviews.count == expectedReviews,
                        "\(scenario.rawValue) expected \(expectedReviews) native review request(s), got \(reviews.count)")
            try require(observation.refusedRepairCount == (scenario.deniesRepair ? 1 : 0),
                        "\(scenario.rawValue) exact admission boundary did not match the expected refused-repair count")
            try require(observation.serializerCouldNotForce == false,
                        "\(scenario.rawValue) could not place its synthetic request at the remaining-byte boundary")
            try require(requests.count == Int(observation.admittedCallCount),
                        "\(scenario.rawValue) transport/admitted-call counts diverged")
            try require(observation.admittedBytes == observation.ledgerInputBytes,
                        "\(scenario.rawValue) transport bytes diverged from ledger accounting")
            try require(repairs.count == (scenario.deniesRepair ? 2 : scenario == .admittedNoOpRepair ? 3 : 4),
                        "\(scenario.rawValue) repair transport count was unexpected: \(repairs.count)")
            try require(observation.resultWasFailure,
                        "\(scenario.rawValue) a disqualifying native review was reported as success")
            try require(observation.cancellationWasReported == (scenario == .unadmittedCancelled),
                        "\(scenario.rawValue) cancellation outcome was not preserved")
            try require(observation.sourceAfterRun == observation.baselineSource,
                        "\(scenario.rawValue) did not restore the baseline source")
            try require(observation.finalHead == observation.baselineHead,
                        "\(scenario.rawValue) changed the baseline Git revision")
            try require(observation.finalStatus.isEmpty,
                        "\(scenario.rawValue) left source changes after failed verification: \(observation.finalStatus)")
            try require(observation.hasGitDirectory,
                        "\(scenario.rawValue) failed to restore the Git directory after the refused run")
            print("PASS \(scenario.rawValue): reviews=\(reviews.count), admittedRepairs=\(repairs.count), refusedRepairs=\(observation.refusedRepairCount), ledgerCalls=\(observation.admittedCallCount)")
            completed += 1
        }
        try require(completed == Scenario.allCases.count, "not all unadmitted-repair scenarios completed")
    }

    private struct ScenarioObservation {
        let resultWasFailure: Bool
        let cancellationWasReported: Bool
        let sourceAfterRun: String
        let finalHead: String
        let finalStatus: String
        let hasGitDirectory: Bool
        let baselineSource: String
        let baselineHead: String
        let requests: [HarnessModelRequest]
        let refusedRepairCount: Int
        let serializerCouldNotForce: Bool
        let admittedCallCount: UInt64
        let admittedBytes: UInt64
        let ledgerInputBytes: UInt64
    }

    @MainActor
    private static func runScenario(_ scenario: Scenario) async throws -> ScenarioObservation {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let observation = Observation()
        let maximumInputBytes: UInt64 = 1_800_000
        let preservedReviewBytes = HarnessReviewInputBudget.defaultMaximumInputBytesPerStage * 2
        let baselineSource = fixture.baselineSource
        let baselineHead = fixture.baselineHead
        let sourceURL = fixture.sourceURL
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: .init(maxCalls: 18, maxInputBytes: maximumInputBytes),
            maximumDurationNanoseconds: 180_000_000_000,
            serializedInputByteCounter: { request in
                let actualBytes = try actualCodexInputBytes(request)
                let admittedBytes = observation.admissionBytes(
                    for: request,
                    actualBytes: actualBytes,
                    maximumInputBytes: maximumInputBytes,
                    preservedReviewBytes: preservedReviewBytes,
                    scenario: scenario
                )
                if request.phase == .repair, observation.refusedRepairCount == 1 {
                    if scenario == .unadmittedSourceChanged {
                        try Data("export const featureValue = 3;\n".utf8).write(to: sourceURL)
                    } else if scenario == .unadmittedCancelled {
                        observation.cancel()
                    }
                }
                return admittedBytes
            }
        ) { request in
            let serializedBytes = try actualCodexInputBytes(request)
            observation.recordAdmitted(request: request, inputBytes: serializedBytes)
            return try await reply(
                for: request,
                scenario: scenario,
                observation: observation,
                briefJSON: fixture.briefJSON
            )
        }
        session.ledgerDidChange = { _ in }
        let workflow = HarnessFeatureWorkflow(modelSession: session)
        let brief = try await workflow.plan(
            request: "Change the fixture value and prove the behavior with a focused test.",
            repositorySummary: "src/feature.js and tests/feature.test.js are the complete fixture"
        )
        try require(brief.acceptanceCriteria.count == 1, "fixture planning reply did not produce one acceptance criterion")
        let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
        var events: [MaintainTierCProgressEvent] = []
        let result = await MaintainTierCFixer(provider: provider).attemptOnDemandEdit(
            clonePath: fixture.clone.path,
            appSlug: fixture.project.slug,
            appStack: .tauri,
            changeId: "unadmitted-\(scenario.rawValue)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            request: brief.userRequest,
            kind: .feature,
            progressHandler: { event in events.append(event) },
            cancellationCheck: { observation.cancelled },
            manifestChangeApproval: { _ in false },
            verificationCommandsOverride: fixture.verificationCommands,
            runsAnIndependentReview: true
        )
        let finalSource = String(decoding: try Data(contentsOf: fixture.sourceURL), as: UTF8.self)
        let finalHead = try await output(fixture.runner, "git rev-parse --verify HEAD^{commit}")
        let finalStatus = try await output(fixture.runner, "git status --porcelain=v1 --untracked-files=all")
        let resultWasFailure: Bool
        let cancellationWasReported: Bool
        if case .couldNotComplete(let reason) = result {
            resultWasFailure = true
            cancellationWasReported = reason == MaintainTierCFixer.stoppedByReaderReason
        } else {
            resultWasFailure = false
            cancellationWasReported = false
        }
        let reviewFailureEvents = events.filter {
            if case .verificationCompleted(let receipt) = $0 {
                return receipt.failureStage == "native-review-required"
            }
            return false
        }
        try require(!reviewFailureEvents.isEmpty,
                    "\(scenario.rawValue) did not preserve the native review failure in progress")
        return ScenarioObservation(
            resultWasFailure: resultWasFailure,
            cancellationWasReported: cancellationWasReported,
            sourceAfterRun: finalSource,
            finalHead: finalHead,
            finalStatus: finalStatus,
            hasGitDirectory: FileManager.default.fileExists(
                atPath: fixture.clone.appendingPathComponent(".git").path
            ),
            baselineSource: baselineSource,
            baselineHead: baselineHead,
            requests: observation.requests,
            refusedRepairCount: observation.refusedRepairCount,
            serializerCouldNotForce: observation.serializerCouldNotForce,
            admittedCallCount: session.ledger.snapshot.admittedCallCount,
            admittedBytes: observation.admittedBytes,
            ledgerInputBytes: session.ledger.snapshot.accountedInputBytes
        )
    }

    @MainActor
    private static func reply(
        for request: HarnessModelRequest,
        scenario: Scenario,
        observation: Observation,
        briefJSON: String
    ) async throws -> HarnessModelReply {
        switch request.phase {
        case .intake:
            return HarnessModelReply(text: briefJSON)
        case .edit:
            let editCount = requestCount(observation, phase: .edit)
            if editCount == 1 {
                return HarnessModelReply(text: """
                Implement the requested value.
                ```write src/feature.js
                export const featureValue = 2;
                Promise.resolve().catch(() => {});
                ```
                ```write tests/feature.test.js
                test('featureValue', () => {});
                ```
                """)
            }
            return HarnessModelReply(text: "DONE")
        case .repair:
            let repairCount = requestCount(observation, phase: .repair)
            switch repairCount {
            case 1:
                return HarnessModelReply(text: """
                Remove the failed draft construct and keep the requested behavior.
                ```write src/feature.js
                export const featureValue = 2;
                ```
                ```write tests/feature.test.js
                test('featureValue', () => {});
                ```
                """)
            case 2:
                return HarnessModelReply(text: "DONE")
            case 3:
                if scenario == .admittedNoOpRepair {
                    return HarnessModelReply(text: "DONE")
                }
                if scenario == .admittedChangedRepair {
                    return HarnessModelReply(text: """
                    Refresh the candidate with a changed source identity.
                    ```write src/feature.js
                    export const featureValue = 3;
                    ```
                    """)
                }
                return HarnessModelReply(text: "DONE")
            default:
                return HarnessModelReply(text: "DONE")
            }
        case .review:
            observation.markReviewReturned()
            return HarnessModelReply(text: """
            ISSUE: the submitted native candidate does not preserve the requested behavior.
            VERDICT: DISQUALIFYING
            """)
        case .recheck:
            return HarnessModelReply(text: "DONE")
        }
    }

    private static func requestCount(_ observation: Observation, phase: HarnessRunTaskKind) -> Int {
        observation.requests.filter { $0.phase == phase }.count
    }

    /// Mirrors `HarnessCodexAdapter`'s actual Codex wire shape, including the
    /// framing preamble, conversation labels, trailing cue and image bytes.
    nonisolated private static func actualCodexInputBytes(_ request: HarnessModelRequest) throws -> UInt64 {
        let searchAvailable = false
        let capabilityNote = "\n\nCURRENT TRANSPORT: web search is disabled for this call. This overrides generic search guidance above."
        let conversation = request.conversation.map {
            MaintainChatTurn(role: $0.role, text: $0.text, attachedImagePNGData: $0.imagePNG)
        }
        let prompt = CodexExecInvocation.promptText(
            systemPrompt: request.systemPrompt + capabilityNote,
            conversation: conversation,
            webSearchEnabled: searchAvailable
        )
        var total = UInt64(prompt.utf8.count)
        for image in request.conversation.compactMap(\.imagePNG) {
            let count = UInt64(image.count)
            let next = total.addingReportingOverflow(count)
            guard !next.overflow else { throw CheckFailure.failed("serialized request size overflowed") }
            total = next.partialValue
        }
        return total
    }

    /// This probe must never replace the real Iris Test registry or write to
    /// the user's Test profile. A Test-mode source adapter used for this
    /// standalone check maps the Test support/log roots beneath this explicit
    /// directory. The guard runs before Test policy setup or fixture writes.
    @MainActor
    private static func isolatedFixtureRoot() throws -> URL {
        guard let rawRoot = ProcessInfo.processInfo.environment["IRIS_UNADMITTED_FIXTURE_ROOT"] else {
            throw CheckFailure.failed("IRIS_UNADMITTED_FIXTURE_ROOT was not supplied")
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard rawRoot == root.path,
              root.path.hasPrefix("/Users/Shared/iris-unadmitted-env-"),
              root.deletingLastPathComponent().path == "/Users/Shared",
              MaintainSandbox.canonicalExistingDirectory(root.path) == root.path else {
            throw CheckFailure.failed("fixture root must be an existing canonical iris-unadmitted-env directory directly under /Users/Shared")
        }

        let fileManager = FileManager.default
        let support = IrisTestEnvironment.applicationSupportDirectory.standardizedFileURL
        let logs = IrisTestEnvironment.logsDirectory.standardizedFileURL
        let scratch = IrisTestEnvironment.commandScratchDirectory.standardizedFileURL
        func isSafeChild(_ candidate: URL) -> Bool {
            guard candidate.path.hasPrefix(root.path + "/") else { return false }
            var current = root
            let relativeComponents = candidate.path
                .dropFirst(root.path.count + 1)
                .split(separator: "/")
            for component in relativeComponents {
                current.appendPathComponent(String(component), isDirectory: true)
                if fileManager.fileExists(atPath: current.path),
                   MaintainSandbox.canonicalPath(current.path) != current.path {
                    return false
                }
            }
            return true
        }
        guard isSafeChild(support), isSafeChild(logs), isSafeChild(scratch) else {
            throw CheckFailure.failed("Test support, log and command-scratch paths are not isolated below IRIS_UNADMITTED_FIXTURE_ROOT")
        }
        let registry = support.appendingPathComponent("test-projects.json")
        guard !fileManager.fileExists(atPath: registry.path) else {
            throw CheckFailure.failed("refusing to replace an existing isolated Test registry")
        }
        return root
    }

    @MainActor
    private static func makeFixture() async throws -> Fixture {
        let files = FileManager.default
        let support = IrisTestEnvironment.applicationSupportDirectory
        let projectRoot = support.appendingPathComponent(
            "Projects/iris-unadmitted-repair-\(UUID().uuidString)", isDirectory: true
        )
        let clone = projectRoot.appendingPathComponent("clone", isDirectory: true)
        let application = support.appendingPathComponent(
            "Projects/Apps/Unadmitted Repair \(UUID().uuidString).app", isDirectory: true
        )
        let artifact = clone.appendingPathComponent("build/Unadmitted Repair.app", isDirectory: true)
        let scratch = IrisTestEnvironment.commandScratchDirectory.appendingPathComponent(
            "iris-unadmitted-repair-\(UUID().uuidString)", isDirectory: true
        )
        let registryURL = support.appendingPathComponent("test-projects.json")
        let originalRegistryExisted = files.fileExists(atPath: registryURL.path)
        let originalRegistryData = try? Data(contentsOf: registryURL)
        let sourceURL = clone.appendingPathComponent("src/feature.js")
        let testURL = clone.appendingPathComponent("tests/feature.test.js")
        let bundleIdentifier = "com.publikhq.iris.test.unadmitted.\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let baselineSource = "export const featureValue = 1;\n"

        try files.createDirectory(at: clone.appendingPathComponent("src"), withIntermediateDirectories: true)
        try files.createDirectory(at: clone.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        try files.createDirectory(at: application, withIntermediateDirectories: true)
        try files.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data(baselineSource.utf8).write(to: sourceURL)
        try Data("// baseline fixture test\n".utf8).write(to: testURL)
        try Data("build/\n".utf8).write(to: clone.appendingPathComponent(".gitignore"))
        try writeBundleInfo(application, bundleIdentifier: bundleIdentifier, name: "Unadmitted Repair")
        try writeBundleInfo(artifact, bundleIdentifier: bundleIdentifier, name: "Unadmitted Repair")

        let executablePath = MaintainSandbox.canonicalPath("/usr/bin/true")
        let nativePlan = IrisTestNativeVerification.Plan(
            executablePath: executablePath,
            arguments: [],
            protectedFileSHA256: [
                MaintainSandbox.canonicalPath(sourceURL.path): try digest(sourceURL.path),
                MaintainSandbox.canonicalPath(testURL.path): try digest(testURL.path),
            ],
            executableSHA256: try digest(executablePath),
            deadlineSeconds: 5
        )
        let testCommand = "test -s src/feature.js && test -s tests/feature.test.js"
        let declaration = IrisTestVerificationDeclaration(
            originalTestCommand: testCommand,
            confinedTestCommand: testCommand,
            native: nativePlan
        )
        let placeholderProject = IrisTestProjectRegistry.Project(
            slug: "unadmitted-repair",
            name: "Unadmitted Repair",
            clonePath: MaintainSandbox.canonicalPath(clone.path),
            applicationPath: MaintainSandbox.canonicalPath(application.path),
            buildArtifactPath: MaintainSandbox.canonicalPath(artifact.path),
            bundleIdentifier: bundleIdentifier,
            pinnedCommit: String(repeating: "a", count: 40),
            nativeVerification: declaration
        )
        try writeRegistry([placeholderProject], to: registryURL)
        let runner = try MaintainShellRunner(repoRootPath: placeholderProject.clonePath)
        let initialized = try await runner.run(
            "git init -q -b main && git add -- src/feature.js tests/feature.test.js .gitignore && git -c user.name=Fixture -c user.email=fixture@example.invalid commit --no-gpg-sign -qm baseline",
            deadline: 30
        )
        try require(initialized.succeeded, "could not initialize the unadmitted-repair fixture")
        let baselineHead = try await output(runner, "git rev-parse --verify HEAD^{commit}")
        let project = IrisTestProjectRegistry.Project(
            slug: placeholderProject.slug,
            name: placeholderProject.name,
            clonePath: placeholderProject.clonePath,
            applicationPath: placeholderProject.applicationPath,
            buildArtifactPath: placeholderProject.buildArtifactPath,
            bundleIdentifier: placeholderProject.bundleIdentifier,
            pinnedCommit: baselineHead,
            nativeVerification: declaration
        )
        try writeRegistry([project], to: registryURL)
        let brief = try HarnessTaskBrief(
            userRequest: "Change the fixture value and prove the behavior with a focused test.",
            desiredOutcome: "The fixture exports the requested value",
            acceptanceCriteria: [
                .init(id: "value", statement: "The source exports featureValue equal to 2")
            ]
        )
        return Fixture(
            projectRoot: projectRoot,
            clone: clone,
            application: application,
            artifact: artifact,
            scratch: scratch,
            registryURL: registryURL,
            originalRegistryData: originalRegistryData,
            originalRegistryExisted: originalRegistryExisted,
            runner: runner,
            sourceURL: sourceURL,
            testURL: testURL,
            project: project,
            briefJSON: String(decoding: try JSONEncoder().encode(brief), as: UTF8.self),
            verificationCommands: VerificationCommands(
                buildCommand: "test -s src/feature.js",
                testCommand: testCommand,
                commandSubdirectory: nil
            ),
            baselineSource: baselineSource,
            baselineHead: baselineHead
        )
    }

    @MainActor
    private static func cleanup(_ fixture: Fixture) {
        let files = FileManager.default
        if fixture.originalRegistryExisted, let data = fixture.originalRegistryData {
            try? data.write(to: fixture.registryURL, options: .atomic)
        } else {
            try? files.removeItem(at: fixture.registryURL)
        }
        try? files.removeItem(at: fixture.projectRoot)
        try? files.removeItem(at: fixture.application)
        try? files.removeItem(at: fixture.scratch)
    }

    private static func writeBundleInfo(_ bundle: URL, bundleIdentifier: String, name: String) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": name,
                "CFBundleExecutable": name.replacingOccurrences(of: " ", with: ""),
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private static func writeRegistry(
        _ projects: [IrisTestProjectRegistry.Project],
        to url: URL
    ) throws {
        let data = try JSONEncoder().encode(projects)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func output(_ runner: MaintainShellRunner, _ command: String) async throws -> String {
        let result = try await runner.run(command, deadline: 30)
        try require(result.succeeded && result.bytesDroppedBeforeTail == 0,
                    "fixture command failed (\(result.exitCode)): \(result.outputTail)")
        return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func digest(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }
}
