//
//  GuideAutopilotShellSessionTests.swift
//  leanring-buddyTests
//
//  The only tests in this repo that spawn a real process — deliberately.
//  Fakes prove the runner's state machine; nothing but a live pty proves the
//  sentinel protocol, job control, and cwd tracking against an actual shell.
//  Commands are harmless (pwd, cd, sleep) and everything runs inside the
//  scratch home the initialiser is given. Set IRIS_SKIP_PTY_TESTS=1 to skip
//  on a box where spawning is unwelcome.
//
//  Serialized, and each test ends its session before returning: concurrent
//  interactive zsh startups contend on the user's own dotfiles, and a shell
//  left behind by one test must not haunt the next.
//

import Foundation
import Testing
@testable import Iris

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

@MainActor
struct GuideAutopilotCommandShapeTests {

    @Test func devServersAreRecognisedAndBuildCommandsAreNot() {
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("npm run dev"))
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("corepack pnpm dev"))
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("docker compose up"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen("docker compose up -d"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen("npm ci"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen(
            "ui/node_modules/.bin/tauri build --bundles app"))
    }

    @Test func unterminatedConstructsAreRefusedBeforeTheyWedgeTheShell() {
        #expect(GuideAutopilotCommandShape.looksSyntacticallyIncomplete("echo 'unterminated"))
        #expect(GuideAutopilotCommandShape.looksSyntacticallyIncomplete("cat <<EOF\nhello"))
        #expect(!GuideAutopilotCommandShape.looksSyntacticallyIncomplete(
            "git commit -m 'a complete message'"))
    }

    @Test func hostsAreExtractedForFixValidation() {
        let hosts = GuideAutopilotCommandShape.hostsTheCommandWouldReach(
            "git clone https://github.com/Blueturboguy07/cue.git && curl https://registry.npmjs.org/x"
        )
        #expect(hosts == ["github.com", "registry.npmjs.org"])
    }
}
