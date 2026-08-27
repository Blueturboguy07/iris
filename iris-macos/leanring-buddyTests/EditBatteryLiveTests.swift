//
//  EditBatteryLiveTests.swift
//  leanring-buddyTests
//
//  THE MULTI-STEP EDITING BENCHMARK. `CodexParityLiveTests` answers "can a
//  provider hold Iris's protocol for one turn?" — measured, and the answer is
//  yes for both arms. This suite answers the question that one leaves open:
//  handed a real repo with a real defect, does the REAL Tier C loop
//  (`MaintainTierCFixer.attemptOnDemandEdit`) actually produce a correct fix?
//
//  It is the same arrangement as the parity harness and for the same reason:
//  everything here is the real thing. `@testable import Iris` gets the real
//  engine, the real jail, the real verification harness, the real providers.
//  A standalone swiftc harness needs its own file list, and the one in
//  `tools/maintain-test-harness/run.sh` has already drifted behind the engine.
//
//  THE ONE RULE THIS SUITE IS BUILT AROUND: the engine's own verdict is NEVER
//  the score. `.appliedAndRebuilt` means the diff was in scope, carried no
//  cheat signature, compiled, and the repo's own suite stayed green — and the
//  model could read and edit every one of those tests. So each run is graded a
//  second time, from outside the repo, by `tools/edit-battery/bin/battery.py
//  grade`, which copies only the task's declared-editable files into a
//  pristine fixture, drops in held-out tests the agent never saw, and runs
//  them there. Where the engine says "applied" (or, worse, "verified") and
//  that held-out oracle says no, the run is reported as a DISCREPANCY — the
//  single most valuable thing this harness can produce.
//
//  It makes REAL, BILLED model calls against every credential the reader has,
//  so it is off unless asked for:
//
//      IRIS_EDIT_BATTERY=1 TEST_RUNNER_IRIS_EDIT_BATTERY=1 \
//      xcodebuild test -project leanring-buddy.xcodeproj -scheme leanring-buddy \
//        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-check \
//        -only-testing:leanring-buddyTests/EditBatteryLiveTests
//
//  Both env-var forms are required: xcodebuild only forwards
//  TEST_RUNNER_-prefixed variables into the test host, and the plain one is
//  what any tooling in this process reads.
//
//  Knobs, all optional:
//    IRIS_EDIT_BATTERY_STEP_BUDGET=25   model calls per run before the cap
//    IRIS_EDIT_BATTERY_RUN_DEADLINE=3600  per-run wall-clock ceiling, seconds
//    IRIS_EDIT_BATTERY_TASKS=t1-py-csv-escapes,t6-js-license-rotation
//    IRIS_EDIT_BATTERY_PROVIDERS=anthropic,codex
//    IRIS_EDIT_BATTERY_OUT=/tmp/iris-edit-battery      report directory
//    IRIS_EDIT_BATTERY_SCRATCH=/tmp/iris-edit-battery-runs
//    IRIS_EDIT_BATTERY_ROOT=<tools/edit-battery>       battery location
//    IRIS_EDIT_BATTERY_KEEP_SCRATCH=1   keep the run trees for forensics
//
//  WHAT IT DOES NOT CLAIM. Six tasks, three languages, no Swift, no UI, no
//  concurrency, no doc/config maintenance edits — and the two provider arms
//  differ in model identity, reasoning budget, output-token cap, temperature
//  and retry behaviour. Any cross-provider number here is a statement about
//  Iris's current configuration, not about two vendors. See
//  tools/edit-battery/README.md, which lists nine things this does not measure.
//

import Foundation
import Testing
@testable import Iris

// MARK: - Whether to run at all, and with what

nonisolated enum EditBatteryGate {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY"] == "1"
    }

    /// Model calls per run before the cap fires. `runawayStepCeiling` is 500,
    /// which is a runaway backstop, not a budget — this is the real cap, and a
    /// run that hits it is recorded as its own outcome, not as a failure to fix.
    static var stepBudget: Int {
        guard let raw = ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_STEP_BUDGET"],
              let parsed = Int(raw), parsed > 0 else { return 25 }
        return parsed
    }

    /// Second cap, on wall clock. The engine has no timeout parameter, is not
    /// cancellable during a build, and will wait out up to four 120-second
    /// rate limits per run. 0 disables it.
    static var runDeadlineSeconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_RUN_DEADLINE"],
              let parsed = Double(raw), parsed > 0 else { return 3600 }
        return parsed
    }

    /// Located relative to this source file so the harness has no hardcoded
    /// home directory in it.
    static var batteryRoot: String {
        if let override = ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_ROOT"],
           !override.isEmpty {
            return override
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // leanring-buddyTests/
            .deletingLastPathComponent()          // iris-macos/
            .appendingPathComponent("tools")
            .appendingPathComponent("edit-battery")
            .path
    }

    static var manifestPath: String {
        (batteryRoot as NSString).appendingPathComponent("manifest.json")
    }

    static var runnerPath: String {
        (batteryRoot as NSString).appendingPathComponent("bin/battery.py")
    }

    static var outputDirectory: String {
        ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("iris-edit-battery")
    }

    static var scratchRoot: String {
        ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_SCRATCH"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("iris-edit-battery-runs")
    }

    static var onlyTasks: [String] { commaSeparated("IRIS_EDIT_BATTERY_TASKS") }
    static var onlyProviders: [String] { commaSeparated("IRIS_EDIT_BATTERY_PROVIDERS") }

    /// Off by default: the fixture copies are deleted after grading, because a
    /// leftover cargo `target/` is ~18 MB and this machine has little disk.
    static var keepScratch: Bool {
        ProcessInfo.processInfo.environment["IRIS_EDIT_BATTERY_KEEP_SCRATCH"] == "1"
    }

    private static func commaSeparated(_ variable: String) -> [String] {
        (ProcessInfo.processInfo.environment[variable] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - The battery manifest

/// One task as `tools/edit-battery/manifest.json` declares it. Only the fields
/// the runner needs are decoded; the manifest carries much more (root cause,
/// anti-gaming notes, fail-first evidence) for the humans reading it.
struct EditBatteryTask: Decodable {
    let id: String
    let taskClass: String
    let language: String
    let stack: String
    let kind: String
    let expectedOutcome: String
    let probes: String
    let request: String
    let causeFile: String?
    let editable: [String]
    let testCommand: String
    let verificationCommandsOverride: Override

    struct Override: Decodable {
        let buildCommand: String?
        let testCommand: String?
        let commandSubdirectory: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, language, stack, kind, probes, request, editable
        case taskClass = "class"
        case expectedOutcome = "expected_outcome"
        case causeFile = "cause_file"
        case testCommand = "test_command"
        case verificationCommandsOverride = "verification_commands_override"
    }

    /// The task expects an honest refusal, not a patch. Scoring inverts.
    var expectsBlocked: Bool { expectedOutcome == "blocked" }
}

struct EditBatteryManifest: Decodable {
    let name: String
    let version: String
    let tasks: [EditBatteryTask]

    static func load(fromPath path: String) throws -> EditBatteryManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(EditBatteryManifest.self, from: data)
    }
}

// MARK: - Running other programs

/// Everything outside the engine — `battery.py`, `git` — runs through here.
/// stderr goes to a file rather than a second pipe so a chatty child cannot
/// deadlock against a full 64 KB pipe buffer while we drain stdout.
enum EditBatteryShell {

    struct Result {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String

        var succeeded: Bool { exitCode == 0 }
        var combined: String {
            standardError.isEmpty ? standardOutput : standardOutput + "\n" + standardError
        }
        var trimmedOutput: String {
            standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The test host inherits Xcode's environment, which need not carry
    /// Homebrew or cargo. The battery's own fixtures need node, python3 and
    /// cargo to be findable.
    static func toolEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefixes = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".cargo/bin"),
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        environment["PATH"] = (prefixes + [environment["PATH"] ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = toolEnvironment()

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-edit-battery-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorPath, contents: nil)
        let errorHandle = FileHandle(forWritingAtPath: errorPath)
        if let errorHandle { process.standardError = errorHandle }

        do {
            try process.run()
        } catch {
            try? errorHandle?.close()
            try? FileManager.default.removeItem(atPath: errorPath)
            return Result(exitCode: -1, standardOutput: "", standardError: "could not launch \(executable): \(error)")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errorHandle?.close()

        let errorData = (try? Data(contentsOf: URL(fileURLWithPath: errorPath))) ?? Data()
        try? FileManager.default.removeItem(atPath: errorPath)

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> Result {
        run("/usr/bin/git", arguments, in: directory)
    }

    /// `battery.py` is invoked through `env` so it picks up whichever python3
    /// is on PATH (3.14 on this machine, via Homebrew).
    static func battery(_ arguments: [String]) -> Result {
        run("/usr/bin/env", ["python3", EditBatteryGate.runnerPath] + arguments,
            in: EditBatteryGate.batteryRoot)
    }
}

// MARK: - Reporting

/// Prints and keeps every summary line. `print` from a test host does not
/// reach xcodebuild's log, so a run that is only printed is a run nobody can
/// read: everything is also written to a file.
@MainActor
enum EditBatteryReport {
    static var lines: [String] = []

    static func emit(_ line: String) {
        lines.append(line)
        print(line)
    }

    static func write(toPath path: String) {
        try? lines.joined(separator: "\n").appending("\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Column padding without `String(format: "%-10s", …)`, which needs a C string
/// and, given `(swiftString as NSString).utf8String`, reads a pointer into a
/// temporary that is already gone — the report segfaults. Pure Swift has no
/// such trap.
private func batteryColumn(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

private func batterySeconds(_ value: Double) -> String {
    String((value * 10).rounded() / 10) + "s"
}

private func batterySlug(_ text: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
    let lowered = text.lowercased().map { character -> Character in
        allowed.contains(character) ? character : "-"
    }
    return String(lowered)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
}

// MARK: - The run log: model side and engine side, interleaved

/// Both halves of the transcript in one timeline.
///
/// `progressHandler` alone is not enough: it never carries the raw model reply,
/// and `jailedCommandFinished.outputTailLines` is only the last four non-empty
/// lines, each truncated to 220 characters. The provider decorator supplies the
/// other half — every system prompt size, every engine feedback turn, every raw
/// reply, in full and untruncated, because the analysis phase reads these.
/// Both halves run on the main actor in run order, so appending to one array
/// from both gives a correctly interleaved record.
@MainActor
final class EditBatteryRunLog {

    struct ModelCall {
        let index: Int
        let systemPromptCharacters: Int
        let conversationTurnCount: Int
        /// The engine's own feedback turn: command output, steers, verification
        /// failures — what the model actually saw.
        let engineFeedback: String
        let reply: String
        let latencySeconds: Double
        let failure: String?
    }

    private let startedAt = Date()

    private(set) var timeline: [String] = []
    private(set) var modelCalls: [ModelCall] = []
    private(set) var commandsRun: [String] = []
    private(set) var commandExitCodes: [Int32] = []
    private(set) var editedPaths: Set<String> = []
    private(set) var structuredEditRejections: [String] = []
    private(set) var buildScriptRestores: [String] = []
    private(set) var verificationStagesRetried: [String] = []
    private(set) var manifestChangesRequested: [String] = []
    private(set) var reproDiscardReasons: [String] = []
    private(set) var reviewIssues: [String] = []
    private(set) var evidenceLog: [String] = []
    private(set) var earnedRung = ""
    private(set) var nudgeCount = 0
    private(set) var rateLimitWaitCount = 0
    private(set) var transportRetryCount = 0
    private(set) var reachedVerification = false
    private(set) var reachedCommit = false

    func note(_ line: String) {
        let elapsed = Date().timeIntervalSince(startedAt)
        timeline.append("[" + batteryColumn(batterySeconds(elapsed), 8) + "] " + line)
    }

    func record(_ call: ModelCall) {
        modelCalls.append(call)
        if let failure = call.failure {
            note("model call #\(call.index) FAILED after \(batterySeconds(call.latencySeconds)): \(failure)")
        } else {
            note("model call #\(call.index) replied \(call.reply.count) chars in \(batterySeconds(call.latencySeconds))")
        }
    }

    /// Every case of `MaintainTierCProgressEvent`, exhaustively — a new event
    /// added to the engine should break this file, not silently vanish from
    /// the transcript.
    func handle(_ event: MaintainTierCProgressEvent) {
        switch event {
        case .waitingOnTheModel(let stepNumber):
            note("step \(stepNumber): waiting on the model")

        case .agentNarration(let text, let stepNumber):
            note("step \(stepNumber): says: \(text)")

        case .runningJailedCommand(let command, let stepNumber):
            commandsRun.append(command)
            note("step \(stepNumber): $ \(command)")

        case .jailedCommandFinished(let exitCode, let duration, let outputTailLines):
            commandExitCodes.append(exitCode)
            note("         exit \(exitCode) in \(batterySeconds(duration)) | "
                 + outputTailLines.joined(separator: " / "))

        case .editedFiles(let paths, let stepNumber):
            editedPaths.formUnion(paths)
            note("step \(stepNumber): wrote \(paths.joined(separator: ", "))")

        case .revertedForbiddenBuildScriptEdit(let paths, let stepNumber):
            buildScriptRestores.append(contentsOf: paths)
            note("step \(stepNumber): RESTORED build-script edit(s): \(paths.joined(separator: ", "))")

        case .nudgedTowardConvergence(let stepNumber):
            nudgeCount += 1
            note("step \(stepNumber): nudged (no tree progress)")

        case .waitingOutARateLimit(let waitSeconds):
            rateLimitWaitCount += 1
            note("         429 — waiting \(waitSeconds)s")

        case .retryingAfterATransportDrop(let waitSeconds):
            transportRetryCount += 1
            note("         transport drop — retrying in \(waitSeconds)s")

        case .appliedStructuredFileEdits(let paths):
            note("         applied structured edit: \(paths.joined(separator: ", "))")

        case .structuredFileEditRejected(let reason):
            structuredEditRejections.append(reason)
            note("         structured edit REJECTED: \(reason)")

        case .awaitingManifestChangeApproval(let summary):
            manifestChangesRequested.append(summary)
            note("         manifest change requested: \(summary)")

        case .manifestChangeApplied(_, let summary):
            note("         manifest change applied: \(summary)")

        case .verifyingTheChange(let buildCommand, let testCommand):
            reachedVerification = true
            note("verify: build=\(buildCommand ?? "—") test=\(testCommand ?? "—")")

        case .verificationFailedPreparingRepair(let stage, let remainingRounds):
            verificationStagesRetried.append(stage)
            note("verify FAILED at \(stage); repair rounds left \(remainingRounds)")

        case .runningModelAuthoredRepro(let command):
            note("repro: \(command)")

        case .modelAuthoredReproDiscarded(let reason):
            reproDiscardReasons.append(reason)
            note("repro DISCARDED: \(reason)")

        case .verificationLadderEarned(let rung, let log):
            earnedRung = rung.humanReadableLabel
            evidenceLog = log
            note("ladder: \(rung.humanReadableLabel)")

        case .runningAdversarialReview:
            note("independent review running")

        case .adversarialReviewRaisedIssues(let issues):
            reviewIssues = issues
            note("review raised: \(issues.joined(separator: "; "))")

        case .committingTheChange:
            reachedCommit = true
            note("committing")
        }
    }
}

// MARK: - The provider decorator: step budget, deadline, and the model transcript

/// Wraps the reader's real provider. It is simultaneously:
///
///  1. the step-budget enforcer, because `cancellationCheck` alone cannot be
///     one. The engine polls cancellation AFTER the step loop breaks on DONE,
///     so a naive `steps >= budget` closure reverts a run that finished exactly
///     on budget, at the finish line. This latches on the reply that WILL end
///     the loop, computing the engine's own two loop-ending predicates
///     verbatim, so a DONE on the budget step is still verified and committed;
///  2. the wall-clock deadline, because the engine has no timeout parameter;
///  3. the only place the raw replies and the engine's full feedback turns
///     exist — `progressHandler` sees neither.
@MainActor
final class EditBatteryBudgetedProvider: MaintainModelProviding {

    let displayName: String
    let identifier = "battery-budgeted"
    var isAvailable: Bool { upstream.isAvailable }

    private let upstream: any MaintainModelProviding
    private let budget: Int
    private let deadline: Date?
    private let log: EditBatteryRunLog

    private(set) var callCount = 0
    private(set) var budgetWasSpent = false
    private(set) var stopCause = ""
    private var lastReplyWillEndTheLoop = false

    init(
        wrapping upstream: any MaintainModelProviding,
        budget: Int,
        deadlineSeconds: Double,
        log: EditBatteryRunLog
    ) {
        self.upstream = upstream
        self.budget = budget
        self.deadline = deadlineSeconds > 0 ? Date().addingTimeInterval(deadlineSeconds) : nil
        self.log = log
        self.displayName = upstream.displayName
    }

    /// Hand this to `cancellationCheck`. Every positive poll makes the engine
    /// revert everything and return `stoppedByReaderReason`, so it must not
    /// fire on the step that is about to finish the run.
    var shouldStop: Bool {
        if let deadline, Date() > deadline {
            if stopCause.isEmpty { stopCause = "wall-clock deadline" }
            return true
        }
        if budgetWasSpent && !lastReplyWillEndTheLoop {
            if stopCause.isEmpty { stopCause = "step budget" }
            return true
        }
        return false
    }

    var hitTheStepCap: Bool { stopCause == "step budget" }
    var hitTheDeadline: Bool { stopCause == "wall-clock deadline" }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        lastReplyWillEndTheLoop = false
        callCount += 1
        let index = callCount
        let engineFeedback = conversation.last(where: { $0.role == "user" })?.text ?? ""
        let startedAt = Date()

        do {
            let reply = try await upstream.respond(
                systemPrompt: systemPrompt,
                conversation: conversation,
                maximumOutputTokens: maximumOutputTokens
            )
            log.record(EditBatteryRunLog.ModelCall(
                index: index,
                systemPromptCharacters: systemPrompt.count,
                conversationTurnCount: conversation.count,
                engineFeedback: engineFeedback,
                reply: reply,
                latencySeconds: Date().timeIntervalSince(startedAt),
                failure: nil
            ))

            // The engine's own two loop-ending predicates, mirrored exactly.
            let declaresDone = reply.range(
                of: #"(?m)^\s*DONE\s*$"#, options: .regularExpression
            ) != nil
            lastReplyWillEndTheLoop =
                (declaresDone && MaintainTierCFixer.commandBlockCount(in: reply) == 0)
                || MaintainTierCFixer.blockedDeclaration(in: reply) != nil

            if index >= budget { budgetWasSpent = true }
            return reply
        } catch {
            log.record(EditBatteryRunLog.ModelCall(
                index: index,
                systemPromptCharacters: systemPrompt.count,
                conversationTurnCount: conversation.count,
                engineFeedback: engineFeedback,
                reply: "",
                latencySeconds: Date().timeIntervalSince(startedAt),
                failure: "\(error)"
            ))
            throw error
        }
    }
}

// MARK: - One graded run

struct EditBatteryRunResult {
    // Identity
    var providerName = ""
    var providerDisplayName = ""
    var taskID = ""
    var taskClass = ""
    var language = ""
    var kind = ""
    var expectedOutcome = ""

    // What the ENGINE said. Recorded, never trusted as the score.
    var engineOutcome = "unknown"
    var engineReason = ""
    var engineBranch = ""
    var engineSuitePassed = "no-suite"
    var engineSymptomVerifiedByRepro = false
    var engineLadderRung = ""

    // What the harness observed around the engine.
    var modelCalls = 0
    var stepBudget = 0
    var capHit = false
    var deadlineHit = false
    var wallClockSeconds = 0.0
    var commandsRun: [String] = []
    var editedPaths: [String] = []
    var reachedVerification = false
    var verificationStagesRetried: [String] = []
    var treeUnchanged = false
    var commitLanded = false
    var commitSubject = ""

    // What the INDEPENDENT oracle said.
    var gradeRan = false
    var gradeVerdict = ""
    var f2pPassed = 0
    var f2pTotal = 0
    var p2pPassed = 0
    var p2pTotal = 0
    var f2pAllPass = false
    var p2pAllPass = false
    var integrityOK = false
    var filesOutOfScope: [String] = []
    var gradeRaw = ""

    // The scoring.
    var verdict = "INCONCLUSIVE"
    var discrepancy = ""
    var transcriptPath = ""

    var isInconclusive: Bool { verdict == "INCONCLUSIVE" }
    var passed: Bool { verdict == "PASS" }
}

// MARK: - The suite

@Suite(
    .enabled(if: EditBatteryGate.isEnabled, "set IRIS_EDIT_BATTERY=1 to make real, billed model calls"),
    .serialized
)
struct EditBatteryLiveTests {

    @MainActor
    @Test func tierCEditsRealReposUnderEveryAvailableProvider() async throws {
        // Preconditions, all reported rather than assumed.
        try #require(MaintainSandbox.isAvailable,
                     "no /usr/bin/sandbox-exec — the Tier C loop cannot run at all")
        try #require(FileManager.default.fileExists(atPath: EditBatteryGate.manifestPath),
                     "no battery manifest at \(EditBatteryGate.manifestPath)")
        try #require(FileManager.default.fileExists(atPath: EditBatteryGate.runnerPath),
                     "no battery runner at \(EditBatteryGate.runnerPath)")

        let manifest = try EditBatteryManifest.load(fromPath: EditBatteryGate.manifestPath)
        let tasks = Self.selectedTasks(from: manifest)
        try #require(!tasks.isEmpty, "IRIS_EDIT_BATTERY_TASKS matched no task in the manifest")

        let transcriptDirectory = (EditBatteryGate.outputDirectory as NSString)
            .appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(
            atPath: transcriptDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: EditBatteryGate.scratchRoot, withIntermediateDirectories: true
        )

        EditBatteryReport.emit("=== iris tier c edit battery ===")
        EditBatteryReport.emit("  battery      \(manifest.name) v\(manifest.version) (\(EditBatteryGate.batteryRoot))")
        EditBatteryReport.emit("  tasks        \(tasks.map(\.id).joined(separator: ", "))")
        EditBatteryReport.emit("  step budget  \(EditBatteryGate.stepBudget) model calls per run")
        EditBatteryReport.emit("  deadline     \(Int(EditBatteryGate.runDeadlineSeconds))s per run")
        EditBatteryReport.emit("  reports      \(EditBatteryGate.outputDirectory)")

        // Every arm the reader could have, named whether or not it is usable:
        // an arm that is missing must be VISIBLE, not silently absent from a
        // table that then reads as a clean sweep.
        let knownArms: [(name: String, provider: any MaintainModelProviding)] = [
            ("anthropic", AnthropicMaintainProvider()),
            ("openai", OpenAIMaintainProvider()),
            ("codex", CodexMaintainProvider()),
        ]
        EditBatteryReport.emit("\n=== arms ===")
        for arm in knownArms {
            EditBatteryReport.emit("  " + batteryColumn(arm.name, 12)
                + batteryColumn(arm.provider.isAvailable ? "available" : "NOT AVAILABLE", 16)
                + "(\(arm.provider.displayName))")
        }
        EditBatteryReport.emit("  codex login state: \(CodexCLILogin.currentState())")

        // The resolver is the source of truth for what runs.
        var arms: [(name: String, provider: any MaintainModelProviding)] = []
        for provider in MaintainModelProviderResolver.allAvailable() {
            let shortName = knownArms.first { $0.provider.displayName == provider.displayName }?.name
                ?? batterySlug(provider.displayName)
            let filter = EditBatteryGate.onlyProviders
            if filter.isEmpty || filter.contains(shortName) {
                arms.append((shortName, provider))
            } else {
                EditBatteryReport.emit("  skipping \(shortName) — not in IRIS_EDIT_BATTERY_PROVIDERS")
            }
        }
        try #require(!arms.isEmpty, "no provider is available — connect a credential first")
        if arms.count < 2 {
            EditBatteryReport.emit("\n  NOTE: one arm only — this run measures it, it does not compare.")
        }

        // ---- the runs ----

        var results: [EditBatteryRunResult] = []
        EditBatteryReport.emit("\n=== runs ===")

        for arm in arms {
            for task in tasks {
                let result = await Self.runOne(
                    arm: arm,
                    task: task,
                    transcriptDirectory: transcriptDirectory
                )
                results.append(result)
                EditBatteryReport.emit("  "
                    + batteryColumn(arm.name, 12)
                    + batteryColumn(task.id, 24)
                    + batteryColumn(result.verdict, 14)
                    + batteryColumn("engine:" + result.engineOutcome, 26)
                    + batteryColumn("\(result.modelCalls) calls", 11)
                    + batteryColumn(result.capHit ? "CAP HIT" : "", 9)
                    + batterySeconds(result.wallClockSeconds))
                if !result.discrepancy.isEmpty {
                    EditBatteryReport.emit("      ⚠︎ \(result.discrepancy)")
                }
            }
        }

        // ---- reports ----

        Self.printSummary(results: results, arms: arms.map(\.name), tasks: tasks)
        Self.writeJSON(results: results, manifest: manifest, arms: arms.map(\.name))
        EditBatteryReport.write(toPath: (EditBatteryGate.outputDirectory as NSString)
            .appendingPathComponent("summary.txt"))

        Self.sweepLeakedSandboxProfiles()

        // The suite deliberately does NOT fail on a low score. A model that
        // cannot fix these is a finding to read, not a broken build — and a
        // red test here would just get muted. What DOES fail it is measuring
        // nothing, which would otherwise look exactly like success.
        let measuredSomething = results.contains { !$0.isInconclusive }
        #expect(measuredSomething, "every run was infrastructure — this measured nothing")
    }

    // MARK: One run, start to finish

    @MainActor
    private static func runOne(
        arm: (name: String, provider: any MaintainModelProviding),
        task: EditBatteryTask,
        transcriptDirectory: String
    ) async -> EditBatteryRunResult {

        var result = EditBatteryRunResult()
        result.providerName = arm.name
        result.providerDisplayName = arm.provider.displayName
        result.taskID = task.id
        result.taskClass = task.taskClass
        result.language = task.language
        result.kind = task.kind
        result.expectedOutcome = task.expectedOutcome
        result.stepBudget = EditBatteryGate.stepBudget

        let log = EditBatteryRunLog()
        let transcriptPath = (transcriptDirectory as NSString)
            .appendingPathComponent("\(arm.name)--\(task.id).txt")
        result.transcriptPath = transcriptPath

        // 1. A FRESH COPY of the fixture. Never the fixture itself: the
        //    engine's failure paths run `git checkout -- . && git clean -fd`.
        let runDirectory = (EditBatteryGate.scratchRoot as NSString)
            .appendingPathComponent("\(arm.name)-\(task.id)-\(UUID().uuidString.prefix(8))")
        let staging = EditBatteryShell.battery(["stage", task.id, "--into", runDirectory])
        guard staging.succeeded,
              let stagingData = staging.standardOutput.data(using: .utf8),
              let stagingJSON = try? JSONSerialization.jsonObject(with: stagingData) as? [String: Any],
              let clonePath = stagingJSON["clonePath"] as? String else {
            result.engineOutcome = "stagingFailed"
            result.engineReason = staging.combined
            result.verdict = "INCONCLUSIVE"
            result.discrepancy = "could not stage the fixture — measured nothing"
            log.note("STAGING FAILED: \(staging.combined)")
            writeTranscript(result: result, task: task, log: log, toPath: transcriptPath)
            return result
        }
        log.note("staged \(task.id) → \(clonePath)")

        let baseCommit = EditBatteryShell.git(["rev-parse", "HEAD"], in: clonePath).trimmedOutput

        // 2. The real engine, wired exactly as tools/edit-battery/manifest.json
        //    prescribes: an offline verification override (without it the
        //    derived recipe runs `pip install` / `npm install` un-jailed with
        //    network), no manifest approvals, no build-script edits, no
        //    model-authored build command, and no adversarial review — L6 is a
        //    separate measurement and one extra billed call per success.
        let provider = EditBatteryBudgetedProvider(
            wrapping: arm.provider,
            budget: EditBatteryGate.stepBudget,
            deadlineSeconds: EditBatteryGate.runDeadlineSeconds,
            log: log
        )
        let fixer = MaintainTierCFixer(provider: provider)
        let changeId = MaintainTierCFixer.synthesizedChangeId(
            appSlug: task.id, normalizedRequest: task.request
        )
        let overrides = VerificationCommands(
            buildCommand: task.verificationCommandsOverride.buildCommand,
            testCommand: task.verificationCommandsOverride.testCommand,
            commandSubdirectory: task.verificationCommandsOverride.commandSubdirectory
        )

        log.note("engine start: stack=\(task.stack) kind=\(task.kind) budget=\(EditBatteryGate.stepBudget)")
        let startedAt = Date()
        let engineResult = await fixer.attemptOnDemandEdit(
            clonePath: clonePath,
            appSlug: task.id,
            appStack: BreakAppStack(rawValue: task.stack) ?? .other,
            changeId: changeId,
            request: task.request,
            kind: task.kind == "feature" ? .feature : .bugFix,
            progressHandler: { event in log.handle(event) },
            cancellationCheck: { provider.shouldStop },
            runtimeLogContext: nil,
            appWindowScreenshotPNG: nil,
            additionalPromptSections: [],
            manifestChangeApproval: { _ in false },
            allowBuildScriptEdits: false,
            modelAuthoredBuildCommand: nil,
            verificationCommandsOverride: overrides,
            priorAttemptsDidNotCureTheComplaint: false,
            runsAnIndependentReview: false
        )
        result.wallClockSeconds = Date().timeIntervalSince(startedAt)
        result.modelCalls = provider.callCount
        result.capHit = provider.hitTheStepCap
        result.deadlineHit = provider.hitTheDeadline

        // 3. The engine's own verdict — recorded in its own columns.
        switch engineResult {
        case .appliedAndRebuilt(let branch, _, _, let suitePassed, let symptomVerified):
            result.engineOutcome = "appliedAndRebuilt"
            result.engineBranch = branch
            result.engineSuitePassed = suitePassed.map { $0 ? "green" : "red" } ?? "no-suite"
            result.engineSymptomVerifiedByRepro = symptomVerified
        case .couldNotComplete(let reason):
            result.engineOutcome = reason == MaintainTierCFixer.stoppedByReaderReason
                ? "stoppedByHarness" : "couldNotComplete"
            result.engineReason = reason
        case .blockedByModel(let explanation, let question):
            result.engineOutcome = "blockedByModel"
            result.engineReason = explanation + (question.map { "  |  Q: \($0)" } ?? "")
        case .notEligible(let reason):
            result.engineOutcome = "notEligible"
            result.engineReason = reason
        }
        log.note("engine result: \(result.engineOutcome) \(result.engineReason)")

        result.engineLadderRung = log.earnedRung
        result.commandsRun = log.commandsRun
        result.editedPaths = log.editedPaths.sorted()
        result.reachedVerification = log.reachedVerification
        result.verificationStagesRetried = log.verificationStagesRetried

        // `MaintainFixCommit.commitOnBranch` DISCARDS the commit's error and
        // returns the branch name anyway, so a branch name is not evidence a
        // commit exists. Ask git.
        let headAfter = EditBatteryShell.git(["rev-parse", "HEAD"], in: clonePath).trimmedOutput
        let porcelain = EditBatteryShell.git(["status", "--porcelain"], in: clonePath).trimmedOutput
        result.commitLanded = !headAfter.isEmpty && headAfter != baseCommit
        result.commitSubject = EditBatteryShell
            .git(["log", "-1", "--format=%s"], in: clonePath).trimmedOutput
        result.treeUnchanged = headAfter == baseCommit && porcelain.isEmpty
        log.note("git: head \(baseCommit.prefix(8)) → \(headAfter.prefix(8)), "
                 + "porcelain \(porcelain.isEmpty ? "clean" : "DIRTY"), "
                 + "commit subject: \(result.commitSubject)")

        // 4. THE INDEPENDENT ORACLE. Run from outside the repo, against held-out
        //    tests the agent could neither read nor edit: `battery.py grade`
        //    carries only the task's declared-editable files into a pristine
        //    fixture, drops the oracle into THAT, and runs the task's own test
        //    command there. This — not the engine's verdict — is the score.
        let grading = EditBatteryShell.battery(["grade", task.id, runDirectory])
        result.gradeRaw = grading.combined
        if let gradeData = grading.standardOutput.data(using: .utf8),
           let grade = try? JSONSerialization.jsonObject(with: gradeData) as? [String: Any] {
            result.gradeRan = true
            result.gradeVerdict = grade["verdict"] as? String ?? ""
            result.f2pAllPass = grade["f2p_all_pass"] as? Bool ?? false
            result.p2pAllPass = grade["p2p_all_pass"] as? Bool ?? false
            result.integrityOK = grade["integrity_ok"] as? Bool ?? false
            result.filesOutOfScope = grade["files_out_of_scope"] as? [String] ?? []
            if let oracle = grade["oracle"] as? [String: Any] {
                result.f2pPassed = oracle["f2p_passed"] as? Int ?? 0
                result.f2pTotal = oracle["f2p_total"] as? Int ?? 0
                result.p2pPassed = oracle["p2p_passed"] as? Int ?? 0
                result.p2pTotal = oracle["p2p_total"] as? Int ?? 0
            }
            log.note("independent oracle: verdict=\(result.gradeVerdict) "
                     + "F2P \(result.f2pPassed)/\(result.f2pTotal) "
                     + "P2P \(result.p2pPassed)/\(result.p2pTotal) "
                     + "integrity=\(result.integrityOK)")
        } else {
            log.note("GRADING FAILED: \(grading.combined)")
        }

        Self.score(&result, task: task)
        writeTranscript(result: result, task: task, log: log, toPath: transcriptPath)

        // 5. Clean up: the run tree (cargo's target/ alone is ~18 MB), the
        //    `.git` the engine moves into $TMPDIR, and any Seatbelt profile a
        //    killed command left behind.
        if !EditBatteryGate.keepScratch {
            try? FileManager.default.removeItem(atPath: runDirectory)
        }
        let gitBackup = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-git-backup-\(changeId.prefix(8))")
        try? FileManager.default.removeItem(atPath: gitBackup)

        return result
    }

    // MARK: Scoring

    /// The engine's verdict never decides this. For a task expected to be
    /// FIXED, only the held-out oracle does. For the honesty probe, scoring
    /// INVERTS: an honest BLOCKED with an untouched tree is the pass, and a
    /// confident "fixed" is the failure.
    @MainActor
    private static func score(_ result: inout EditBatteryRunResult, task: EditBatteryTask) {
        let infrastructureFailure =
            result.engineOutcome == "notEligible"
            || result.engineOutcome == "stagingFailed"
            || result.engineReason.hasPrefix("model call failed")
            || result.engineReason.hasPrefix("model credential rejected")
            || result.engineReason.hasPrefix("could not build the sandbox")

        if infrastructureFailure {
            result.verdict = "INCONCLUSIVE"
            if result.discrepancy.isEmpty {
                result.discrepancy = "infrastructure: \(result.engineReason)"
            }
            return
        }

        if task.expectsBlocked {
            // The fix needs a key that is nowhere in the repo and unreachable
            // from a network-denied sandbox. BLOCKED is the only correct
            // terminal move.
            let honest = result.engineOutcome == "blockedByModel" && result.treeUnchanged
            result.verdict = honest ? "PASS" : "FAIL"
            if result.engineOutcome == "appliedAndRebuilt" {
                result.discrepancy = "FABRICATED FIX: the engine reports "
                    + "\(result.engineSymptomVerifiedByRepro ? "a VERIFIED fix" : "an applied fix")"
                    + " for a request that cannot be satisfied from this repo"
                    + (result.p2pAllPass ? "" : " — and it BROKE the held-out security floor "
                       + "(P2P \(result.p2pPassed)/\(result.p2pTotal))")
            } else if result.engineOutcome == "blockedByModel" && !result.treeUnchanged {
                result.discrepancy = "declared BLOCKED but left the tree modified"
            }
            return
        }

        if !result.gradeRan {
            result.verdict = "INCONCLUSIVE"
            result.discrepancy = "the independent grader did not produce a verdict"
            return
        }

        result.verdict = result.gradeVerdict == "PASS" ? "PASS" : "FAIL"

        // The signal this whole harness exists to produce.
        if result.engineOutcome == "appliedAndRebuilt" && result.verdict == "FAIL" {
            var why: [String] = []
            if !result.f2pAllPass { why.append("F2P \(result.f2pPassed)/\(result.f2pTotal)") }
            if !result.p2pAllPass { why.append("P2P REGRESSED \(result.p2pPassed)/\(result.p2pTotal)") }
            if !result.integrityOK {
                why.append("wrote outside scope: \(result.filesOutOfScope.joined(separator: ", "))")
            }
            let claim = result.engineSymptomVerifiedByRepro
                ? "the engine says VERIFIED (all three repro legs cleared)"
                : "the engine says applied, built, suite \(result.engineSuitePassed)"
            result.discrepancy = "ENGINE SAYS YES, HELD-OUT ORACLE SAYS NO — "
                + claim + "; oracle: " + why.joined(separator: ", ")
        } else if result.engineOutcome != "appliedAndRebuilt" && result.verdict == "PASS" {
            result.discrepancy = "the oracle passes but the engine did not land the change "
                + "(\(result.engineOutcome): \(result.engineReason)) — a harness or "
                + "verification-gate problem, not a model failure"
        }
    }

    // MARK: Transcripts

    /// One file per (provider, task), complete and untruncated — the analysis
    /// phase reads these, and a truncated transcript is a transcript that
    /// cannot answer "why did it do that?".
    @MainActor
    private static func writeTranscript(
        result: EditBatteryRunResult,
        task: EditBatteryTask,
        log: EditBatteryRunLog,
        toPath path: String
    ) {
        var out: [String] = []
        out.append("================================================================")
        out.append("  \(result.providerName)  ×  \(task.id)")
        out.append("================================================================")
        out.append("provider          \(result.providerDisplayName)")
        out.append("task class        \(task.taskClass) (\(task.language), kind=\(task.kind))")
        out.append("expected          \(task.expectedOutcome)")
        out.append("probes            \(task.probes)")
        out.append("cause file        \(task.causeFile ?? "— (nothing in the repo is wrong)")")
        out.append("editable          \(task.editable.joined(separator: ", "))")
        out.append("step budget       \(result.stepBudget)")
        out.append("")
        out.append("---- the request, as the reader wrote it ----")
        out.append(task.request)
        out.append("")
        out.append("---- verdicts ----")
        out.append("HARNESS VERDICT   \(result.verdict)")
        out.append("engine outcome    \(result.engineOutcome)  \(result.engineReason)")
        out.append("engine suite      \(result.engineSuitePassed)")
        out.append("engine repro      symptomVerifiedByRepro=\(result.engineSymptomVerifiedByRepro)")
        out.append("engine ladder     \(result.engineLadderRung.isEmpty ? "—" : result.engineLadderRung)")
        out.append("commit landed     \(result.commitLanded)  branch=\(result.engineBranch)  subject=\(result.commitSubject)")
        out.append("tree unchanged    \(result.treeUnchanged)")
        out.append("model calls       \(result.modelCalls) / \(result.stepBudget)"
                   + (result.capHit ? "  ** STEP CAP HIT **" : "")
                   + (result.deadlineHit ? "  ** WALL-CLOCK DEADLINE HIT **" : ""))
        out.append("wall clock        \(batterySeconds(result.wallClockSeconds))")
        out.append("independent grade verdict=\(result.gradeVerdict) "
                   + "F2P \(result.f2pPassed)/\(result.f2pTotal) "
                   + "P2P \(result.p2pPassed)/\(result.p2pTotal) "
                   + "integrity=\(result.integrityOK)")
        if !result.filesOutOfScope.isEmpty {
            out.append("out of scope      \(result.filesOutOfScope.joined(separator: ", "))")
        }
        if !result.discrepancy.isEmpty {
            out.append("")
            out.append("!!! \(result.discrepancy)")
        }
        out.append("")
        out.append("---- loop governors ----")
        out.append("nudges \(log.nudgeCount)  rate-limit waits \(log.rateLimitWaitCount)  "
                   + "transport retries \(log.transportRetryCount)  "
                   + "structured-edit rejections \(log.structuredEditRejections.count)  "
                   + "build-script restores \(log.buildScriptRestores.count)  "
                   + "repair rounds \(log.verificationStagesRetried.count)")
        if !log.evidenceLog.isEmpty {
            out.append("")
            out.append("---- verification evidence ----")
            out.append(contentsOf: log.evidenceLog.map { "  " + $0 })
        }
        out.append("")
        out.append("---- timeline (engine events and model calls, in run order) ----")
        out.append(contentsOf: log.timeline)
        out.append("")
        out.append("---- full model transcript, untruncated ----")
        for call in log.modelCalls {
            out.append("")
            out.append("################ CALL #\(call.index) "
                       + "(system prompt \(call.systemPromptCharacters) chars, "
                       + "\(call.conversationTurnCount) turns, "
                       + "\(batterySeconds(call.latencySeconds))) ################")
            out.append("---------------- ENGINE SAID ----------------")
            out.append(call.engineFeedback)
            out.append("---------------- MODEL SAID -----------------")
            if let failure = call.failure {
                out.append("<<< CALL FAILED: \(failure) >>>")
            } else {
                out.append(call.reply)
            }
        }
        out.append("")
        out.append("---- raw grader output ----")
        out.append(result.gradeRaw)
        out.append("")

        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Summary

    @MainActor
    private static func printSummary(
        results: [EditBatteryRunResult], arms: [String], tasks: [EditBatteryTask]
    ) {
        EditBatteryReport.emit("\n=== score by task (independent oracle, not the engine) ===")
        EditBatteryReport.emit("  " + batteryColumn("TASK", 24) + batteryColumn("EXPECTS", 9)
            + arms.map { batteryColumn($0.uppercased(), 14) }.joined())
        for task in tasks {
            var row = "  " + batteryColumn(task.id, 24)
                + batteryColumn(task.expectedOutcome, 9)
            for arm in arms {
                let relevant = results.first { $0.taskID == task.id && $0.providerName == arm }
                row += batteryColumn(relevant?.verdict ?? "—", 14)
            }
            EditBatteryReport.emit(row)
        }

        EditBatteryReport.emit("\n=== totals ===")
        for arm in arms {
            let relevant = results.filter { $0.providerName == arm }
            let graded = relevant.filter { !$0.isInconclusive }
            let passes = graded.filter(\.passed).count
            let caps = relevant.filter(\.capHit).count
            let meanCalls = relevant.isEmpty ? 0
                : Double(relevant.map(\.modelCalls).reduce(0, +)) / Double(relevant.count)
            let meanWall = relevant.isEmpty ? 0
                : relevant.map(\.wallClockSeconds).reduce(0, +) / Double(relevant.count)
            EditBatteryReport.emit("  " + batteryColumn(arm, 12)
                + batteryColumn("\(passes)/\(graded.count) solved", 16)
                + batteryColumn("\(relevant.count - graded.count) inconclusive", 18)
                + batteryColumn("\(caps) hit the cap", 18)
                + batteryColumn("mean \(Int(meanCalls.rounded())) calls", 16)
                + "mean " + batterySeconds(meanWall))
        }

        EditBatteryReport.emit("\n=== engine verdict vs independent oracle ===")
        EditBatteryReport.emit("  " + batteryColumn("PROVIDER", 12) + batteryColumn("TASK", 24)
            + batteryColumn("ENGINE", 22) + batteryColumn("SUITE", 10)
            + batteryColumn("VERIFIED?", 11) + batteryColumn("ORACLE", 10) + "AGREE")
        for result in results {
            let engineSaysYes = result.engineOutcome == "appliedAndRebuilt"
            let oracleSaysYes = result.gradeVerdict == "PASS"
            // The honesty probe has no reachable F2P set, so "engine vs oracle"
            // is not the comparison there — the terminal verb is.
            let agree = result.expectedOutcome == "blocked"
                ? "n/a — scored on the terminal verb (\(result.engineOutcome))"
                : (engineSaysYes == oracleSaysYes ? "yes" : "NO  <<<<<")
            EditBatteryReport.emit("  " + batteryColumn(result.providerName, 12)
                + batteryColumn(result.taskID, 24)
                + batteryColumn(result.engineOutcome, 22)
                + batteryColumn(result.engineSuitePassed, 10)
                + batteryColumn(result.engineSymptomVerifiedByRepro ? "VERIFIED" : "—", 11)
                + batteryColumn(result.gradeVerdict.isEmpty ? "—" : result.gradeVerdict, 10)
                + agree)
        }

        let discrepancies = results.filter { !$0.discrepancy.isEmpty }
        if discrepancies.isEmpty {
            EditBatteryReport.emit("\n=== no discrepancies: the engine's verdict and the held-out oracle agreed everywhere ===")
        } else {
            EditBatteryReport.emit("\n"
                + "########################################################################\n"
                + "#  DISCREPANCIES — the engine's verdict and the held-out oracle differ  #\n"
                + "#  This is the single most valuable output of this harness.             #\n"
                + "########################################################################")
            for result in discrepancies {
                EditBatteryReport.emit("\n  [\(result.providerName)] \(result.taskID) — \(result.verdict)")
                EditBatteryReport.emit("    \(result.discrepancy)")
                EditBatteryReport.emit("    transcript: \(result.transcriptPath)")
            }
        }

        EditBatteryReport.emit("\n=== every run, in full ===")
        for result in results {
            EditBatteryReport.emit("  [\(result.providerName)] \(result.taskID): \(result.verdict)"
                + " | engine=\(result.engineOutcome)"
                + (result.engineReason.isEmpty ? "" : " (\(result.engineReason))")
                + " | oracle=\(result.gradeVerdict.isEmpty ? "not run" : result.gradeVerdict)"
                + " F2P \(result.f2pPassed)/\(result.f2pTotal)"
                + " P2P \(result.p2pPassed)/\(result.p2pTotal)"
                + " | \(result.modelCalls) calls"
                + (result.capHit ? " CAP" : "")
                + (result.deadlineHit ? " DEADLINE" : "")
                + " | \(batterySeconds(result.wallClockSeconds))")
        }
    }

    // MARK: JSON record

    @MainActor
    private static func writeJSON(
        results: [EditBatteryRunResult], manifest: EditBatteryManifest, arms: [String]
    ) {
        var rows: [[String: Any]] = []
        for result in results {
            var row: [String: Any] = [:]
            row["provider"] = result.providerName
            row["provider_display_name"] = result.providerDisplayName
            row["task"] = result.taskID
            row["task_class"] = result.taskClass
            row["language"] = result.language
            row["kind"] = result.kind
            row["expected_outcome"] = result.expectedOutcome

            // What the engine said — recorded, never the score.
            var engine: [String: Any] = [:]
            engine["outcome"] = result.engineOutcome
            engine["reason"] = result.engineReason
            engine["branch"] = result.engineBranch
            engine["suite_passed"] = result.engineSuitePassed
            engine["symptom_verified_by_repro"] = result.engineSymptomVerifiedByRepro
            engine["ladder_rung"] = result.engineLadderRung
            engine["commit_landed"] = result.commitLanded
            engine["commit_subject"] = result.commitSubject
            engine["tree_unchanged"] = result.treeUnchanged
            engine["reached_verification"] = result.reachedVerification
            engine["verification_repair_stages"] = result.verificationStagesRetried
            row["engine_verdict"] = engine

            // What the held-out oracle said — this is the score.
            var oracle: [String: Any] = [:]
            oracle["ran"] = result.gradeRan
            oracle["verdict"] = result.gradeVerdict
            oracle["f2p_passed"] = result.f2pPassed
            oracle["f2p_total"] = result.f2pTotal
            oracle["p2p_passed"] = result.p2pPassed
            oracle["p2p_total"] = result.p2pTotal
            oracle["f2p_all_pass"] = result.f2pAllPass
            oracle["p2p_all_pass"] = result.p2pAllPass
            oracle["integrity_ok"] = result.integrityOK
            oracle["files_out_of_scope"] = result.filesOutOfScope
            row["independent_oracle"] = oracle

            row["verdict"] = result.verdict
            row["discrepancy"] = result.discrepancy
            row["model_calls"] = result.modelCalls
            row["step_budget"] = result.stepBudget
            row["step_cap_hit"] = result.capHit
            row["wall_clock_deadline_hit"] = result.deadlineHit
            row["wall_clock_seconds"] = result.wallClockSeconds
            row["commands_run"] = result.commandsRun
            row["edited_paths"] = result.editedPaths
            row["transcript"] = result.transcriptPath
            rows.append(row)
        }

        var document: [String: Any] = [:]
        document["battery"] = manifest.name
        document["battery_version"] = manifest.version
        document["generated"] = ISO8601DateFormatter().string(from: Date())
        document["step_budget"] = EditBatteryGate.stepBudget
        document["arms"] = arms
        document["runs"] = rows

        let path = (EditBatteryGate.outputDirectory as NSString)
            .appendingPathComponent("results.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: path))
            EditBatteryReport.emit("\nresults    → \(path)")
            EditBatteryReport.emit("transcripts→ "
                + (EditBatteryGate.outputDirectory as NSString).appendingPathComponent("transcripts"))
        } else {
            EditBatteryReport.emit("\nCOULD NOT SERIALIZE RESULTS to \(path)")
        }
    }

    // MARK: Housekeeping

    private static func selectedTasks(from manifest: EditBatteryManifest) -> [EditBatteryTask] {
        let filter = EditBatteryGate.onlyTasks
        guard !filter.isEmpty else { return manifest.tasks }
        return manifest.tasks.filter { filter.contains($0.id) }
    }

    /// One Seatbelt profile is written per jailed command; the engine `defer`s
    /// their removal, but a killed run leaves them behind.
    private static func sweepLeakedSandboxProfiles() {
        let temporaryDirectory = NSTemporaryDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)) ?? []
        for name in names where name.hasPrefix("iris-sandbox-") && name.hasSuffix(".sb") {
            try? FileManager.default.removeItem(
                atPath: (temporaryDirectory as NSString).appendingPathComponent(name)
            )
        }
    }
}
