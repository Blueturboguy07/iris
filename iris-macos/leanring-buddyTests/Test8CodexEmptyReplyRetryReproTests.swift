//
//  Test8CodexEmptyReplyRetryReproTests.swift
//  leanring-buddyTests
//
//  THE REPORT (Test 8, Iris 0.9.4 build 20). A reader ran an app edit on their
//  own Mac against the Codex CLI and the card told them, in full:
//
//      "That didn't work. Iris couldn't complete that edit — nothing changed.
//       (model call failed: codex exec produced no assistant message — it ran
//       and exited cleanly without answering. try again, and if it keeps
//       happening connect a different model in settings.)"
//
//  Runtime finding: the same model/provider failure family as Test 6 — the
//  edit run died on a single Codex round trip rather than on anything about the
//  edit. Here the round trip did not error: `codex exec` exited 0 and simply
//  wrote no assistant message (an empty `--output-last-message`, no
//  `agent_message` in the event stream). `CodexMaintainProvider.runCodexExec`
//  treated that clean-but-empty run as a hard `requestFailed` on the FIRST
//  occurrence and ended the whole edit run, reverting everything.
//
//  The message itself tells the reader to "try again" — so the fix is to have
//  Iris try again ITSELF first. A clean exit with no answer is a TRANSIENT
//  empty, the same dropped-call shape the fix loop already retries
//  (`MaintainTierCFixer.maximumTransportDropRetriesPerRun`): it is retried a
//  bounded number of times with a short backoff before the honest message is
//  surfaced, and the honest message is kept for the case where the empties
//  KEEP coming.
//
//  These are REAL subprocess repros in the founder's sense: they drive the
//  actual `CodexMaintainProvider.runCodexExec` against a real `codex`-shaped
//  process (a shell script standing in for the CLI) that exits 0 and writes
//  nothing, and they count the real process spawns on disk. Nothing about the
//  retry is mocked — only the CLI binary is a stand-in, and only so the test
//  needs no ChatGPT login. The backoff between retries is driven to 0 so the
//  ladder runs in milliseconds; the retry COUNT is the production constant.
//

import Foundation
import Testing

@testable import Iris

@Suite(.serialized) struct Test8CodexEmptyReplyRetryReproTests {

    // MARK: - A stand-in for the codex CLI

    /// A throwaway directory holding a fake `codex` and its spawn-count file.
    private struct FakeCodex {
        let binaryPath: String
        let spawnCountFilePath: String
        let scratchRootURL: URL

        /// How many times the fake was actually spawned, read off disk — the
        /// real evidence that a retry did or did not happen.
        func spawnCount() -> Int {
            (try? String(contentsOfFile: spawnCountFilePath, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true).count ?? 0
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: scratchRootURL)
        }
    }

    /// Builds a `codex`-shaped shell script.
    ///
    /// On each spawn it drains stdin (Iris writes the prompt there and closes
    /// it), appends one line to its spawn-count file, and then — for the first
    /// `emptyRunsBeforeAnswering` spawns — writes NOTHING to the
    /// `--output-last-message` path and prints nothing, i.e. it "exits cleanly
    /// without answering". From the spawn AFTER that count it writes
    /// `assistantMessage` to the `--output-last-message` path, which is exactly
    /// how the real CLI hands back the final turn. It always exits 0, so this
    /// is the clean-but-empty shape and never the error shape.
    private static func makeFakeCodex(
        emptyRunsBeforeAnswering: Int,
        assistantMessage: String
    ) throws -> FakeCodex {
        let scratchRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test8-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratchRootURL, withIntermediateDirectories: true
        )
        let binaryPath = scratchRootURL.appendingPathComponent("codex").path
        let spawnCountFilePath = scratchRootURL.appendingPathComponent("spawns.log").path

        // Values are inlined into the script so it needs no environment coupling
        // with the test runner. Single-quoted so paths and the message survive
        // the shell verbatim; the message is kept free of single quotes below.
        let script = """
        #!/bin/sh
        cat >/dev/null 2>&1
        echo spawn >> '\(spawnCountFilePath)'
        outputLastMessagePath=""
        previousArgument=""
        for argument in "$@"; do
            if [ "$previousArgument" = "--output-last-message" ]; then
                outputLastMessagePath="$argument"
            fi
            previousArgument="$argument"
        done
        spawnCount=$(wc -l < '\(spawnCountFilePath)' | tr -d ' ')
        if [ "$spawnCount" -gt \(emptyRunsBeforeAnswering) ] && [ -n "$outputLastMessagePath" ]; then
            printf '%s' '\(assistantMessage)' > "$outputLastMessagePath"
        fi
        exit 0
        """
        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryPath
        )
        return FakeCodex(
            binaryPath: binaryPath,
            spawnCountFilePath: spawnCountFilePath,
            scratchRootURL: scratchRootURL
        )
    }

    /// A `codex`-shaped script that exits NON-ZERO with stderr — the real
    /// failure shape, which must never be swept into the empty-reply retry.
    private static func makeFailingCodex(exitCode: Int32, stderrLine: String) throws -> FakeCodex {
        let scratchRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test8-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratchRootURL, withIntermediateDirectories: true
        )
        let binaryPath = scratchRootURL.appendingPathComponent("codex").path
        let spawnCountFilePath = scratchRootURL.appendingPathComponent("spawns.log").path
        let script = """
        #!/bin/sh
        cat >/dev/null 2>&1
        echo spawn >> '\(spawnCountFilePath)'
        printf '%s\\n' '\(stderrLine)' 1>&2
        exit \(exitCode)
        """
        try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryPath
        )
        return FakeCodex(
            binaryPath: binaryPath,
            spawnCountFilePath: spawnCountFilePath,
            scratchRootURL: scratchRootURL
        )
    }

    /// Drives the real provider against a fake codex with the retry backoff
    /// collapsed to 0 so the whole ladder runs in milliseconds. The retry COUNT
    /// is untouched (the production constant), so what is being measured is the
    /// real production ladder, only sped up.
    private static func runAgainst(_ fakeCodex: FakeCodex) async throws -> String {
        try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: fakeCodex.binaryPath,
            promptText: "fix the thing",
            attachedImagePNGDataList: [],
            model: nil,
            webSearchEnabled: false,
            timeoutSeconds: 30,
            emptyReplyRetryWaitSecondsOverride: 0
        )
    }

    // MARK: - The repros

    /// THE BUG. A codex that always exits cleanly with no assistant message used
    /// to fail the whole edit on the FIRST run. It must now be retried the full
    /// bounded number of times — proven by counting the real process spawns —
    /// before the honest, unchanged message is surfaced. (Revert the fix by
    /// setting `maximumEmptyReplyRetriesPerStep` to 0 and this spawns once and
    /// fails immediately, exactly as it did at HEAD.)
    @Test func aCleanButEmptyCodexRunIsRetriedTheBoundedNumberOfTimesBeforeSurfacing() async throws {
        let fakeCodex = try Self.makeFakeCodex(
            emptyRunsBeforeAnswering: Int.max, assistantMessage: "never reached"
        )
        defer { fakeCodex.cleanUp() }

        var surfacedMessage: String? = nil
        do {
            _ = try await Self.runAgainst(fakeCodex)
            Issue.record("expected the persistently-empty run to surface a failure, but it returned")
        } catch let error as MaintainModelProviderError {
            surfacedMessage = error.userFacingMessage
        }

        // The honest message is kept verbatim for the keeps-happening case.
        #expect(surfacedMessage?.contains("produced no assistant message") == true)
        #expect(surfacedMessage?.contains("try again") == true)
        // One first attempt PLUS the bounded retries — the whole point of the fix.
        let expectedSpawns = 1 + CodexMaintainProvider.maximumEmptyReplyRetriesPerStep
        #expect(fakeCodex.spawnCount() == expectedSpawns)
    }

    /// THE COMMON CASE. When the empty is genuinely transient — codex answers on
    /// a later run — the retry recovers the real answer instead of failing the
    /// edit. At HEAD (no retry) this throws on the first empty; the returned
    /// message here is the observation that the fix works.
    @Test func aTransientEmptyRecoversTheRealAnswerOnRetry() async throws {
        // Empty on the first two spawns, then a real answer on the third. This
        // needs at least two retries, so it is impossible under the HEAD
        // behavior and possible only because the ladder retries.
        let fakeCodex = try Self.makeFakeCodex(
            emptyRunsBeforeAnswering: 2, assistantMessage: "here is the fix"
        )
        defer { fakeCodex.cleanUp() }

        let answer = try await Self.runAgainst(fakeCodex)
        #expect(answer.trimmingCharacters(in: .whitespacesAndNewlines) == "here is the fix")
        // Two empties then the answering run: exactly three spawns, no more.
        #expect(fakeCodex.spawnCount() == 3)
    }

    /// THE BOUNDARY THAT MUST NOT MOVE. A real, non-zero-exit failure is NOT an
    /// empty reply and must keep failing fast — one spawn, no retry ladder — so
    /// the retry cannot turn a genuine error (a bad argument vector, a real
    /// server failure) into a multi-minute stall. This guards the dependent
    /// surface: `CodexExecOutput.failure` still owns every non-zero exit.
    @Test func aNonZeroExitIsNotSweptIntoTheEmptyReplyRetry() async throws {
        let fakeCodex = try Self.makeFailingCodex(
            exitCode: 2, stderrLine: "error: unexpected argument found"
        )
        defer { fakeCodex.cleanUp() }

        await #expect(throws: MaintainModelProviderError.self) {
            _ = try await Self.runAgainst(fakeCodex)
        }
        // Ran exactly once — the failure was surfaced, not retried.
        #expect(fakeCodex.spawnCount() == 1)
    }
}
