import Foundation

actor AttemptRecorder {
    private(set) var results: [CodexProcessAttemptResult] = []

    func append(_ result: CodexProcessAttemptResult) {
        results.append(result)
    }
}

@main
struct CodexProviderContractChecks {
    static func main() async throws {
        try checkInvocationEffort()
        try checkUnknownEffortRejected()
        try checkUnknownUsageFieldsStayNil()
        try checkSearchFramingMatchesCapability()
        try await checkRetryObserverAndZeroOverride()
        try await checkLargePromptSurvivesEarlyChildOutput()
        try await checkFinalMessageDoesNotHangOnStubbornChild()
        try await checkCancellationKillsChild()
        print("PASS provider contract checks: 8")
    }

    private static func checkSearchFramingMatchesCapability() throws {
        let offline = CodexExecInvocation.promptText(systemPrompt: "contract", conversation: [],
            webSearchEnabled: false)
        let online = CodexExecInvocation.promptText(systemPrompt: "contract", conversation: [])
        guard offline.contains("disabled for this call"),
              !offline.contains("Web search is a normal tool"),
              online.contains(CodexExecInvocation.framingPreamble) else {
            throw Failure.message("prompt framing disagrees with configured search capability")
        }
    }

    private static func checkInvocationEffort() throws {
        let arguments = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/final.txt",
            workingDirectory: "/tmp",
            model: "gpt-6-astra",
            reasoningEffort: .medium,
            webSearchEnabled: false
        )
        guard let configIndex = arguments.firstIndex(of: "-c") else {
            throw Failure.message("reasoning config was not emitted")
        }
        guard arguments[configIndex + 1] == "model_reasoning_effort=\"medium\"" else {
            throw Failure.message("reasoning config had the wrong value")
        }
        guard try CodexExecInvocation.validated(arguments) == arguments else {
            throw Failure.message("builder output did not validate")
        }
    }

    private static func checkUnknownEffortRejected() throws {
        var arguments = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/final.txt",
            workingDirectory: "/tmp",
            reasoningEffort: .low,
            webSearchEnabled: false
        )
        guard let configIndex = arguments.firstIndex(of: "-c") else {
            throw Failure.message("missing effort config for rejection check")
        }
        arguments[configIndex + 1] = "model_reasoning_effort=\"unsupported\""
        do {
            _ = try CodexExecInvocation.validated(arguments)
            throw Failure.message("unsupported effort was accepted")
        } catch CodexExecInvocation.ValidationError.invalidReasoningEffort {
            return
        } catch {
            throw Failure.message("wrong validation error for unsupported effort")
        }
    }

    private static func checkUnknownUsageFieldsStayNil() throws {
        let json = #"{"type":"turn.completed","usage":{"input_tokens":8}}"#
        guard let usage = CodexExecOutput.usage(fromJSONL: json),
              usage.inputTokens == 8,
              usage.cachedInputTokens == nil,
              usage.outputTokens == nil,
              usage.reasoningOutputTokens == nil else {
            throw Failure.message("missing usage fields were not preserved as nil")
        }
    }

    private static func checkRetryObserverAndZeroOverride() async throws {
        let fixture = try FakeCodexFixture(mode: .emptyThenAnswer)
        defer { fixture.cleanUp() }
        let recorder = AttemptRecorder()
        let observer = CodexProcessAttemptObserver(afterAttempt: { result in
            await recorder.append(result)
        })
        let answer = try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: fixture.binaryPath,
            promptText: "answer",
            attachedImagePNGDataList: [],
            model: "gpt-6-astra",
            webSearchEnabled: false,
            timeoutSeconds: 5,
            reasoningEffort: .low,
            emptyReplyRetryWaitSecondsOverride: 0,
            attemptObserver: observer
        )
        guard answer == "answer" else { throw Failure.message("wrong fake answer") }
        let results = await recorder.results
        guard results.count == 2,
              results[0].outcome == .emptyReply,
              results[1].outcome == .succeeded,
              results[1].usage?.inputTokens == 17,
              results[1].usage?.outputTokens == nil else {
            throw Failure.message("observer did not report bounded attempts and nil unknown usage")
        }

        let oneAttemptFixture = try FakeCodexFixture(mode: .alwaysEmpty)
        defer { oneAttemptFixture.cleanUp() }
        let oneAttemptRecorder = AttemptRecorder()
        let oneAttemptObserver = CodexProcessAttemptObserver(afterAttempt: { result in
            await oneAttemptRecorder.append(result)
        })
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: oneAttemptFixture.binaryPath,
                promptText: "answer",
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 5,
                reasoningEffort: .low,
                emptyReplyRetryWaitSecondsOverride: 0,
                maximumEmptyReplyRetriesOverride: 0,
                attemptObserver: oneAttemptObserver
            )
            throw Failure.message("zero retry override returned an answer")
        } catch is MaintainModelProviderError {
            // Expected honest empty result after one physical process.
        }
        let oneAttemptResults = await oneAttemptRecorder.results
        guard oneAttemptResults.count == 1,
              oneAttemptResults[0].outcome == .emptyReply else {
            throw Failure.message("zero retry override allowed hidden attempts")
        }
        guard fixture.spawnCount() == 2, oneAttemptFixture.spawnCount() == 1 else {
            throw Failure.message("fake process count did not match observer attempts")
        }
    }

    private static func checkCancellationKillsChild() async throws {
        let fixture = try FakeCodexFixture(mode: .sleep)
        defer { fixture.cleanUp() }
        let recorder = AttemptRecorder()
        let observer = CodexProcessAttemptObserver(afterAttempt: { result in
            await recorder.append(result)
        })
        let start = Date()
        let task = Task {
            try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: fixture.binaryPath,
                promptText: "wait",
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 30,
                reasoningEffort: .medium,
                maximumEmptyReplyRetriesOverride: 0,
                attemptObserver: observer
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
#if IRIS_HARNESS_HEADLESS
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: fixture.childPIDPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
#endif
        task.cancel()
        do {
            _ = try await task.value
            throw Failure.message("cancelled provider returned")
        } catch is CancellationError {
            // Expected cancellation after the fake child was terminated.
        }
        guard Date().timeIntervalSince(start) < 5 else {
            throw Failure.message("provider did not cancel promptly")
        }
        let results = await recorder.results
        guard results.count == 1, results[0].outcome == .cancelled else {
            throw Failure.message("cancellation was not reported")
        }
#if IRIS_HARNESS_HEADLESS
        guard let text = try? String(contentsOfFile: fixture.childPIDPath, encoding: .utf8),
              let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.message("fake descendant was not started")
        }
        for _ in 0..<100 where kill(child, 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard kill(child, 0) != 0 else {
            throw Failure.message("cancelled headless provider left its descendant running")
        }
#endif
    }

    private static func checkFinalMessageDoesNotHangOnStubbornChild() async throws {
        let fixture = try FakeCodexFixture(mode: .finalMessageThenStubborn)
        defer { fixture.cleanUp() }
        let recorder = CompletionRecorder()
        let start = Date()
        let task = Task {
            do {
                let answer = try await CodexMaintainProvider.runCodexExec(
                    codexBinaryPath: fixture.binaryPath,
                    promptText: "finish then wait",
                    attachedImagePNGDataList: [],
                    model: "gpt-6-astra",
                    webSearchEnabled: false,
                    timeoutSeconds: 0.25,
                    reasoningEffort: .low,
                    maximumEmptyReplyRetriesOverride: 0
                )
                await recorder.record("succeeded:\(answer)")
            } catch is CancellationError {
                await recorder.record("cancelled")
            } catch {
                await recorder.record("failed")
            }
        }

        for _ in 0..<150 where await recorder.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let outcome = await recorder.value else {
            task.cancel()
            throw Failure.message("stubborn child did not honor the provider deadline")
        }
        guard outcome == "failed" else {
            throw Failure.message("stubborn child unexpectedly returned \(outcome)")
        }
        guard Date().timeIntervalSince(start) < 1.5 else {
            throw Failure.message("provider deadline completion exceeded its bounded check")
        }
    }

    private static func checkLargePromptSurvivesEarlyChildOutput() async throws {
        let fixture = try FakeCodexFixture(mode: .largeStdoutBeforeRead)
        defer { fixture.cleanUp() }

        let promptText = String(repeating: "p", count: 300_000)
        guard promptText.utf8.count >= 262_144 else {
            throw Failure.message("large prompt fixture was smaller than the child output")
        }
        let start = Date()
        let outcome = await withTaskGroup(of: LargePromptOutcome.self) { group in
            group.addTask {
                do {
                    let answer = try await CodexMaintainProvider.runCodexExec(
                        codexBinaryPath: fixture.binaryPath,
                        promptText: promptText,
                        attachedImagePNGDataList: [],
                        model: "gpt-6-astra",
                        webSearchEnabled: false,
                        timeoutSeconds: 30,
                        reasoningEffort: .low,
                        maximumEmptyReplyRetriesOverride: 0
                    )
                    return .succeeded(answer)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return .timedOut
                } catch {
                    return .watchdogCancelled
                }
            }

            let firstOutcome = await group.next() ?? .timedOut
            group.cancelAll()
            return firstOutcome
        }

        guard Date().timeIntervalSince(start) < 2 else {
            throw Failure.message("large prompt provider check exceeded its 2s watchdog")
        }
        guard case .succeeded(let answer) = outcome, answer == "answer" else {
            throw Failure.message("large prompt provider check did not return the output-last-message answer")
        }
    }

    private struct FakeCodexFixture {
        enum Mode: String {
            case emptyThenAnswer, alwaysEmpty, sleep, largeStdoutBeforeRead, finalMessageThenStubborn
        }

        let rootURL: URL
        let binaryPath: String
        let countPath: String
        var childPIDPath: String { rootURL.appendingPathComponent("child-pid").path }

        init(mode: Mode) throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iris-codex-contract-\(UUID().uuidString)")
            countPath = rootURL.appendingPathComponent("count").path
            binaryPath = rootURL.appendingPathComponent("fake-codex").path
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
#if IRIS_HARNESS_HEADLESS
            let sleepCommand = "/bin/sleep 10 & echo $! > '\(childPIDPath)'; wait"
#else
            let sleepCommand = "exec /bin/sleep 10"
#endif
            let script = """
            #!/bin/sh
            count_file='\(countPath)'
            count=0
            if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
            count=$((count + 1))
            printf '%s' "$count" > "$count_file"
            output_path=''
            previous=''
            for argument in "$@"; do
              if [ "$previous" = "--output-last-message" ]; then output_path="$argument"; fi
              previous="$argument"
            done
            mode='\(mode.rawValue)'
            if [ "$mode" = "largeStdoutBeforeRead" ]; then
              if ! /bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null; then exit 97; fi
            fi
            cat >/dev/null
            if [ "$mode" = "finalMessageThenStubborn" ]; then
              printf '%s' 'answer' > "$output_path"
              trap '' TERM
              exec /bin/sleep 30
            fi
            if [ "$mode" = "sleep" ]; then \(sleepCommand); fi
            if { [ "$mode" = "emptyThenAnswer" ] && [ "$count" -ge 2 ]; } || [ "$mode" = "largeStdoutBeforeRead" ]; then
              printf '%s' 'answer' > "$output_path"
            fi
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":17}}'
            exit 0
            """
            try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        }

        func spawnCount() -> Int {
            Int((try? String(contentsOfFile: countPath, encoding: .utf8)) ?? "0") ?? 0
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    actor CompletionRecorder {
        private(set) var value: String?

        func record(_ value: String) {
            self.value = value
        }
    }

    private enum Failure: Error {
        case message(String)
    }

    private enum LargePromptOutcome: Sendable {
        case succeeded(String)
        case cancelled
        case failed(String)
        case timedOut
        case watchdogCancelled
    }
}
