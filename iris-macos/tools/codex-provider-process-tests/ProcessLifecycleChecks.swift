import Foundation

private enum ProcessCheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

@main
struct CodexProviderProcessLifecycleChecks {
    static func main() async throws {
        try await checkLargeInputAndOutputDoNotDeadlock()
        try await checkExitedParentCannotHoldPipeReadersOpen()
        try await checkCancellationKillsTheProcessTree()
        try await checkLaunchFailureIsBoundedAndMapped()
        print("PASS production process lifecycle checks: 4")
    }

    private static func checkLargeInputAndOutputDoNotDeadlock() async throws {
        let fixture = try FakeCodexFixture(mode: .largeStdoutBeforeRead)
        defer { fixture.cleanUp() }

        let promptText = String(repeating: "p", count: 300_000)
        let startedAt = Date()
        let answer = try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: fixture.binaryPath,
            promptText: promptText,
            attachedImagePNGDataList: [],
            model: "gpt-6-astra",
            webSearchEnabled: false,
            timeoutSeconds: 10,
            reasoningEffort: .low,
            maximumEmptyReplyRetriesOverride: 0
        )

        guard answer == "answer" else {
            throw ProcessCheckFailure.message("large prompt returned the wrong answer")
        }
        guard Date().timeIntervalSince(startedAt) < 2 else {
            throw ProcessCheckFailure.message("large prompt and stdout check exceeded its bound")
        }

        // A child that never reads stdin must be stopped by the call deadline,
        // not wedge the caller in a blocking pipe write or terminate it with
        // SIGPIPE.
        let stalledFixture = try FakeCodexFixture(mode: .neverReadsStdin)
        defer { stalledFixture.cleanUp() }
        let stalledStartedAt = Date()
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: stalledFixture.binaryPath,
                promptText: String(repeating: "p", count: 300_000),
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 0.5,
                reasoningEffort: .low,
                maximumEmptyReplyRetriesOverride: 0
            )
            throw ProcessCheckFailure.message("a child that never reads stdin unexpectedly returned")
        } catch let error as MaintainModelProviderError {
            guard case .requestFailed(let message) = error,
                  message.contains("exceeded its time limit") else {
                throw ProcessCheckFailure.message("stalled stdin deadline mapped to the wrong provider error")
            }
        }
        guard Date().timeIntervalSince(stalledStartedAt) < 2 else {
            throw ProcessCheckFailure.message("stalled stdin write exceeded its timeout bound")
        }
        try await waitForDescendantToExit(fixture: stalledFixture)
    }

    private static func checkExitedParentCannotHoldPipeReadersOpen() async throws {
        let fixture = try FakeCodexFixture(mode: .parentExitsWithPipeHoldingDescendant)
        defer { fixture.cleanUp() }

        let startedAt = Date()
        let answer = try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: fixture.binaryPath,
            promptText: "finish and close every pipe",
            attachedImagePNGDataList: [],
            model: "gpt-6-astra",
            webSearchEnabled: false,
            timeoutSeconds: 10,
            reasoningEffort: .low,
            maximumEmptyReplyRetriesOverride: 0
        )

        guard answer == "answer" else {
            throw ProcessCheckFailure.message("pipe descendant check returned the wrong answer")
        }
        guard Date().timeIntervalSince(startedAt) < 2 else {
            throw ProcessCheckFailure.message(
                "provider waited for a descendant-held stdout or stderr pipe after the parent exited"
            )
        }
        try await waitForDescendantToExit(fixture: fixture)

        let detachedFixture = try FakeCodexFixture(mode: .detachedPipeHolder)
        defer { detachedFixture.cleanUp() }
        let detachedStartedAt = Date()
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: detachedFixture.binaryPath,
                promptText: "finish and close every pipe",
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 10,
                reasoningEffort: .low,
                maximumEmptyReplyRetriesOverride: 0
            )
            throw ProcessCheckFailure.message("detached pipe holder unexpectedly returned an answer")
        } catch let error as MaintainModelProviderError {
            guard case .requestFailed(let message) = error,
                  message.contains("helper kept its output open") else {
                throw ProcessCheckFailure.message("detached pipe holder mapped to the wrong provider error")
            }
        }
        guard Date().timeIntervalSince(detachedStartedAt) < 3 else {
            throw ProcessCheckFailure.message("detached pipe holder exceeded the collector timeout bound")
        }
        detachedFixture.terminateRecordedChild()
        try await waitForDescendantToExit(fixture: detachedFixture)
    }

    private static func checkCancellationKillsTheProcessTree() async throws {
        let fixture = try FakeCodexFixture(mode: .sleepWithDescendant)
        defer { fixture.cleanUp() }

        let task = Task {
            try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: fixture.binaryPath,
                promptText: "wait",
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 10,
                reasoningEffort: .low,
                maximumEmptyReplyRetriesOverride: 0
            )
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: fixture.childPIDPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard FileManager.default.fileExists(atPath: fixture.childPIDPath) else {
            task.cancel()
            _ = try? await task.value
            throw ProcessCheckFailure.message("cancellation fixture did not start its descendant")
        }

        task.cancel()
        do {
            _ = try await task.value
            throw ProcessCheckFailure.message("cancelled provider returned an answer")
        } catch is CancellationError {
            // Expected cancellation from the provider's task boundary.
        }

        try await waitForDescendantToExit(fixture: fixture)

        // Cancellation must also interrupt the provider while its nonblocking
        // stdin loop is waiting for a reader that never consumes the prompt.
        let stalledFixture = try FakeCodexFixture(mode: .neverReadsStdin)
        defer { stalledFixture.cleanUp() }
        let stalledTaskStartedAt = Date()
        let stalledTask = Task {
            try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: stalledFixture.binaryPath,
                promptText: String(repeating: "p", count: 300_000),
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 10,
                reasoningEffort: .low,
                maximumEmptyReplyRetriesOverride: 0
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: stalledFixture.childPIDPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard FileManager.default.fileExists(atPath: stalledFixture.childPIDPath) else {
            stalledTask.cancel()
            _ = try? await stalledTask.value
            throw ProcessCheckFailure.message("stalled-input cancellation fixture did not start its child")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        stalledTask.cancel()
        do {
            _ = try await stalledTask.value
            throw ProcessCheckFailure.message("cancellation during stalled stdin returned an answer")
        } catch is CancellationError {
            // Expected cancellation while the provider was feeding stdin.
        }
        guard Date().timeIntervalSince(stalledTaskStartedAt) < 2 else {
            throw ProcessCheckFailure.message("cancellation during stalled stdin exceeded its bound")
        }
        try await waitForDescendantToExit(fixture: stalledFixture)
    }

    private static func checkLaunchFailureIsBoundedAndMapped() async throws {
        let missingBinaryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-codex-missing-\(UUID().uuidString)").path
        let startedAt = Date()
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: missingBinaryPath,
                promptText: "launch failure",
                attachedImagePNGDataList: [],
                model: "gpt-6-astra",
                webSearchEnabled: false,
                timeoutSeconds: 10,
                reasoningEffort: .low,
                maximumEmptyReplyRetriesOverride: 0
            )
            throw ProcessCheckFailure.message("missing Codex binary unexpectedly returned")
        } catch let error as MaintainModelProviderError {
            guard case .requestFailed(let message) = error,
                  message.contains("couldn't start it") else {
                throw ProcessCheckFailure.message("launch failure mapped to the wrong provider error")
            }
        }
        guard Date().timeIntervalSince(startedAt) < 1 else {
            throw ProcessCheckFailure.message("launch failure was not returned promptly")
        }
    }

    private static func waitForDescendantToExit(fixture: FakeCodexFixture) async throws {
        guard let childPID = fixture.childPID() else {
            throw ProcessCheckFailure.message("fixture did not record its descendant PID")
        }
        for _ in 0..<100 where kill(childPID, 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard kill(childPID, 0) != 0 else {
            throw ProcessCheckFailure.message("provider left its descendant running")
        }
    }

    private struct FakeCodexFixture {
        enum Mode: String {
            case largeStdoutBeforeRead
            case neverReadsStdin
            case parentExitsWithPipeHoldingDescendant
            case detachedPipeHolder
            case sleepWithDescendant
        }

        let rootURL: URL
        let binaryPath: String
        let countPath: String
        let childPIDPath: String
        let detachedReadyPath: String
        let mode: Mode

        init(mode: Mode) throws {
            self.mode = mode
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iris-codex-process-\(UUID().uuidString)")
            binaryPath = rootURL.appendingPathComponent("fake-codex").path
            countPath = rootURL.appendingPathComponent("count").path
            childPIDPath = rootURL.appendingPathComponent("child-pid").path
            detachedReadyPath = rootURL.appendingPathComponent("detached-ready").path
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let modeScript: String
            switch mode {
            case .largeStdoutBeforeRead:
                modeScript = """
                if ! /bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null; then exit 97; fi
                cat >/dev/null
                printf '%s' 'answer' > "$output_path"
                """
            case .neverReadsStdin:
                modeScript = """
                (/bin/sleep 10) &
                printf '%s' "$!" > '\(childPIDPath)'
                wait
                """
            case .parentExitsWithPipeHoldingDescendant:
                modeScript = """
                cat >/dev/null
                (/bin/sleep 10) &
                printf '%s' "$!" > '\(childPIDPath)'
                printf '%s' 'answer' > "$output_path"
                """
            case .detachedPipeHolder:
                modeScript = """
                DETACHED_READY_PATH='\(detachedReadyPath)'
                export DETACHED_READY_PATH
                (/usr/bin/perl -MPOSIX -e 'POSIX::setsid() or die; open my $f, ">", $ENV{DETACHED_READY_PATH} or die; print $f "ready"; close $f; sleep 10') &
                printf '%s' "$!" > '\(childPIDPath)'
                attempt=0
                while [ "$attempt" -lt 50 ] && [ ! -f "$DETACHED_READY_PATH" ]; do
                  attempt=$((attempt + 1))
                  /bin/sleep 0.01
                done
                printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":17}}'
                exit 0
                """
            case .sleepWithDescendant:
                modeScript = """
                (/bin/sleep 10) &
                printf '%s' "$!" > '\(childPIDPath)'
                cat >/dev/null
                wait
                """
            }

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
            \(modeScript)
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":17}}'
            exit 0
            """
            try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        }

        func childPID() -> Int32? {
            guard let text = try? String(contentsOfFile: childPIDPath, encoding: .utf8) else {
                return nil
            }
            return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func terminateRecordedChild() {
            guard let childPID = childPID(), childPID > 0 else { return }
            _ = kill(childPID, SIGKILL)
        }

        func cleanUp() {
            terminateRecordedChild()
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
