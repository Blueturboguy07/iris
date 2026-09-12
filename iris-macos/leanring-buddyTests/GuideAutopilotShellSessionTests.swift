//
//  GuideAutopilotShellSessionTests.swift
//  leanring-buddyTests
//
//  The only tests in this repo that spawn a real process — deliberately.
//  Fakes prove the runner's state machine; nothing but a live pty proves the
//  sentinel protocol, job control, and cwd tracking against an actual shell.
//  Commands stay inside the disposable working directory (pwd, cd, sleep, and
//  explicit self-termination of that shell). The login shell's normal dotfiles
//  are only read, never modified. Set IRIS_SKIP_PTY_TESTS=1 to skip
//  on a box where spawning is unwelcome.
//
//  Serialized, and each test ends its session before returning: concurrent
//  interactive zsh startups contend on the user's own dotfiles, and a shell
//  left behind by one test must not haunt the next.
//

import Foundation
import Testing
#if IRIS_HARNESS_STANDALONE
@testable import IrisHarnessNative
#else
@testable import Iris
#endif

private let ptyTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

@MainActor
@Suite(.enabled(if: ptyTestsAreEnabled), .serialized)
struct GuideAutopilotShellSessionTests {

    /// Starts a session, runs the body, and always ends the session before
    /// returning — teardown is awaited, never fire-and-forget.
    private static func withStartedSession(
        _ body: @MainActor (GuideAutopilotShellSession) async throws -> Void
    ) async throws {
        let session = GuideAutopilotShellSession(startingDirectory: NSTemporaryDirectory())
        let started = await session.start()
        guard started else {
            await session.endSession()
            Issue.record("the login shell should start and report ready")
            return
        }
        do {
            try await body(session)
        } catch {
            await session.endSession()
            throw error
        }
        await session.endSession()
    }

    private static func approved(_ command: String) throws -> GuideAutopilotApprovedCommand {
        try #require(GuideAutopilotRiskAssessment.approve(command))
    }

    @Test func aCommandRunsAndItsOutputAndExitStatusComeBack() async throws {
        try await Self.withStartedSession { session in
            var lines: [String] = []
            session.onOutputLine = { lines.append($0) }

            let outcome = await session.run(try Self.approved("echo autopilot-round-trip"))
            guard case .succeeded = outcome else {
                Issue.record("expected success, got \(outcome)")
                return
            }
            // Output lines hop queues; give the last hop a beat.
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(lines.contains { $0.contains("autopilot-round-trip") })
        }
    }

    @Test func aFailingCommandReportsItsExitStatus() async throws {
        try await Self.withStartedSession { session in
            let outcome = await session.run(try Self.approved("sh -c 'exit 3'"))
            #expect(outcome == .failed(
                exitStatus: 3,
                workingDirectory: session.currentWorkingDirectory
            ))
        }
    }

    @Test func anOrganicShellExitRecoversWithoutReplayingTheCommand() async throws {
        try await Self.withStartedSession { session in
            let command = try Self.approved("kill -9 $$")
            let outcome = await session.run(command)
            #expect(outcome == .terminalSessionRestarted,
                    "a dead shell should report a ready replacement, not pretend the command succeeded")

            // The replacement shell restores the last known cwd and is usable
            // for a later, explicit command. The killed command itself appears
            // only once because recovery never replays it.
            let recovered = await session.run(try Self.approved("echo recovered"))
            guard case .succeeded = recovered else {
                Issue.record("expected the replacement shell to accept a later explicit command, got \(recovered)")
                return
            }
        }
    }

    @Test func staleOutputAndExitCallbacksFromAnOldTerminalCannotTouchItsReplacement() async throws {
        try await Self.withStartedSession { session in
            let outcome = await session.run(try Self.approved("printf 'old-terminal-output\\n'; exit 23"))
            #expect(outcome == .terminalSessionRestarted)

            // The old reader may still have queued bytes when recovery starts.
            // A command on the replacement must still receive its own marker.
            let replacement = await session.run(try Self.approved("printf 'replacement-output\\n'"))
            guard case .succeeded = replacement else {
                Issue.record("stale old-terminal callbacks affected the replacement: \(replacement)")
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(session.tailForTheModel().contains("replacement-output"))
        }
    }

    @Test func aRecoveredShellReestablishesTheLastKnownWorkingDirectory() async throws {
        try await Self.withStartedSession { session in
            let changedDirectory = await session.run(try Self.approved("cd /tmp"))
            guard case .succeeded = changedDirectory else {
                Issue.record("expected the cwd setup command to succeed, got \(changedDirectory)")
                return
            }

            #expect(await session.run(try Self.approved("kill -9 $$")) == .terminalSessionRestarted)
            let outcome = await session.run(try Self.approved("pwd"))
            guard case .succeeded(let workingDirectory) = outcome else {
                Issue.record("expected pwd to run after recovery, got \(outcome)")
                return
            }
            #expect(workingDirectory == "/tmp" || workingDirectory == "/private/tmp",
                    "recovery must restore the prior cwd before the next real command")
        }
    }

    @Test func repeatedOrganicShellExitsStopAtTheBoundedRecoveryAllowance() async throws {
        try await Self.withStartedSession { session in
            for attempt in 0..<GuideAutopilotShellSession.maximumAutomaticShellRecoveryAttempts {
                let outcome = await session.run(try Self.approved("kill -9 $$"))
                #expect(outcome == .terminalSessionRestarted,
                        "recovery attempt \(attempt + 1) should be the last bounded replacement")
            }

            let exhausted = await session.run(try Self.approved("kill -9 $$"))
            #expect(exhausted == .sessionFailed,
                    "a repeatedly dying shell must become unavailable instead of respawning forever")
            #expect(await session.run(try Self.approved("echo should-not-run")) == .sessionFailed)
        }
    }

    @Test func explicitEndDoesNotRespawnTheTerminal() async throws {
        let session = GuideAutopilotShellSession(startingDirectory: NSTemporaryDirectory())
        #expect(await session.start())
        await session.endSession()
        try await Task.sleep(nanoseconds: 700_000_000)

        let outcome = await session.run(try Self.approved("echo should-not-run"))
        #expect(outcome == .sessionFailed,
                "endSession is final for this run and must not let a stale exit callback respawn a shell")
    }

    @Test func cancellingDuringStartupResolvesTheOriginalStartAndInvalidatesItsReadyTimer() async throws {
        let session = GuideAutopilotShellSession(
            startingDirectory: NSTemporaryDirectory(),
            startupPreambleDelayForTesting: 1
        )
        let startTask = Task { @MainActor in await session.start() }
        try await Task.sleep(nanoseconds: 100_000_000)

        await session.cancelTheRunningCommand()
        #expect(await startTask.value == false,
                "cancelling before the ready marker must resolve the original start")
        await session.endSession()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let outcome = await session.run(try Self.approved("echo should-not-run"))
        #expect(outcome == .sessionFailed,
                "a delayed ready callback from a cancelled startup must not revive the session")
    }

    @Test func theGeneratedZshrcIgnoresEndOfInput() throws {
        try #require(GuideAutopilotShellSession.loginShellIsZsh())
        let zdotdir = try #require(GuideAutopilotShellSession.privateZdotdir())
        let rc = try String(
            contentsOfFile: (zdotdir as NSString).appendingPathComponent(".zshrc"),
            encoding: .utf8
        )
        #expect(rc.contains("ignoreeof"),
                "deadline Ctrl-D must not kill an otherwise idle persistent shell")
    }

    @Test func workingDirectoryCarriesAcrossCommands() async throws {
        try await Self.withStartedSession { session in
            _ = await session.run(try Self.approved("cd /tmp"))
            let outcome = await session.run(try Self.approved("pwd"))
            guard case .succeeded(let workingDirectory) = outcome else {
                Issue.record("expected success, got \(outcome)")
                return
            }
            // macOS /tmp is a symlink to /private/tmp; the shell may report
            // either spelling depending on how it resolved the cd.
            #expect(workingDirectory == "/tmp" || workingDirectory == "/private/tmp")
        }
    }

    @Test func theLoginShellRebuildsARealSearchPath() async throws {
        try await Self.withStartedSession { session in
            let searchPath = session.resolvedSearchPath
            #expect(searchPath?.contains("/usr/bin") == true,
                    "the -l shell should have run path_helper; got \(searchPath ?? "nil")")
        }
    }

    @Test func aMarkerShapedStringInOutputCannotForgeCompletion() async throws {
        try await Self.withStartedSession { session in
            let outcome = await session.run(
                try Self.approved("printf '__IRIS_END_deadbeef__ 0\\t/forged\\n'\ntrue")
            )
            guard case .succeeded(let workingDirectory) = outcome else {
                Issue.record("expected success, got \(outcome)")
                return
            }
            #expect(workingDirectory != "/forged",
                    "a printed marker with the wrong token must not be believed")
        }
    }

    @Test func cancellationInterruptsARunningCommandQuickly() async throws {
        try await Self.withStartedSession { session in
            let startedAt = Date()
            let sleepCommand = try Self.approved("sleep 30")
            async let running = session.run(sleepCommand)
            try await Task.sleep(nanoseconds: 500_000_000)
            await session.cancelTheRunningCommand()
            let outcome = await running
            #expect(outcome == .cancelled)
            #expect(Date().timeIntervalSince(startedAt) < 15,
                    "cancel must not wait out the sleep")
        }
    }

    @Test func theOffQueueKillStopsARunningCommandAndTheSessionRecovers() async throws {
        // The escape hatch's real teardown: SIGKILL the process group off the
        // command queue (so a flood of build output cannot delay it), then the
        // async cancel settles the bookkeeping and rebuilds. What the reader
        // needs afterwards is a session they can Try Again on.
        try await Self.withStartedSession { session in
            let startedAt = Date()
            let sleepCommand = try Self.approved("sleep 30")
            async let running = session.run(sleepCommand)
            try await Task.sleep(nanoseconds: 500_000_000)

            // This is the escape-hatch sequence the runner performs.
            session.killTheRunningProcessGroupImmediately()
            await session.cancelTheRunningCommand()

            let outcome = await running
            // Either the cancel resolved it, or the off-queue kill's process
            // exit did — both are a clean stop, neither is "still running".
            #expect(outcome == .cancelled || outcome == .sessionFailed,
                    "the stopped command must not report success, got \(outcome)")
            #expect(Date().timeIntervalSince(startedAt) < 15,
                    "the kill must not wait out the sleep")

            // The session rebuilt a fresh shell, so the next command runs once
            // that shell finishes coming up. A real reader taps "Try again"
            // seconds later, well after it is ready; the test retries briefly to
            // cover the just-rebuilt window rather than racing it.
            var recovered = false
            for _ in 0..<20 where !recovered {
                if case .succeeded = await session.run(try Self.approved("echo recovered")) {
                    recovered = true
                } else {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            #expect(recovered, "the session should be usable again after the escape hatch")
        }
    }

    @Test func hugeOutputStaysBounded() async throws {
        try await Self.withStartedSession { session in
            let outcome = await session.run(
                try Self.approved("i=0; while [ $i -lt 6000 ]; do echo line-$i; i=$((i+1)); done")
            )
            guard case .succeeded = outcome else {
                Issue.record("expected success, got \(outcome)")
                return
            }
            let lines = session.displayLinesSnapshot()
            #expect(lines.count <= GuideAutopilotOutputBuffer.maximumDisplayLines)
        }
    }
}

@MainActor
struct GuideAutopilotOutputBufferTests {

    @Test func ansiSequencesAreStrippedAndTextSurvives() {
        let noisy = "\u{1B}[1;32mDone\u{1B}[0m in \u{1B}]0;title\u{07}1.2s"
        #expect(GuideAutopilotOutputBuffer.strippedOfControlSequences(noisy) == "Done in 1.2s")
    }

    @Test func carriageReturnProgressBarsKeepOnlyTheFinalFrame() {
        let progress = "downloading   1%\rdownloading  50%\rdownloading 100%"
        #expect(GuideAutopilotOutputBuffer.strippedOfControlSequences(progress)
                == "downloading 100%")
    }

    @Test func aTrailingCarriageReturnIsALineTerminatorNotAProgressBar() {
        // The pty's ONLCR discipline ends every line \r\n — the sentinel
        // marker itself arrives this way and must survive.
        #expect(GuideAutopilotOutputBuffer.strippedOfControlSequences("__MARKER__ 0\t/tmp\r")
                == "__MARKER__ 0\t/tmp")
    }

    @Test func secretsAreScrubbedOnEgressOnly() {
        var buffer = GuideAutopilotOutputBuffer()
        buffer.ingest("ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnopqrstuvwx\n")
        buffer.ingest("a harmless line\n")
        #expect(buffer.tailForTheModel().contains("[REDACTED]"))
        #expect(!buffer.tailForTheModel().contains("sk-ant-abcdefghijklmnop"))
        // The display keeps the reader's own output unmasked.
        #expect(buffer.displayLines.first?.contains("sk-ant-") == true)
    }

    @Test func aSplitUTF8CodePointSurvivesChunkBoundaries() {
        var buffer = GuideAutopilotOutputBuffer()
        let emoji = Array("✓ done\n".utf8)
        buffer.append(Array(emoji[0..<2]))   // splits the ✓
        buffer.append(Array(emoji[2...]))
        #expect(buffer.displayLines == ["✓ done"])
    }
}
