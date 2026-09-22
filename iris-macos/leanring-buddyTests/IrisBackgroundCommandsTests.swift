//
//  IrisBackgroundCommandsTests.swift
//  leanring-buddyTests
//
//  The incident these exist for: chat ran `npm run dev` in the foreground
//  lane, vite printed "ready … Local: http://localhost:5174/", the process was
//  killed at the 120-second deadline, and the reader was told "i stopped the
//  command after 2 minutes since dev servers run forever, but it's still
//  serving." It was not. The server had been dead since the sentence
//  describing it as alive.
//
//  Two properties have to hold for that to be unreachable rather than merely
//  discouraged, and both are asserted here: a command that never exits cannot
//  run in the killing lane at all, and "is it running" is answered by the
//  kernel rather than by anything the process printed earlier.
//
//  These spawn real processes, so the suite is serialized like the pty tests.
//

import Foundation
import Testing
@testable import Iris

@Suite(.serialized)
struct IrisBackgroundCommandsTests {

    // MARK: - The command that started it

    @Test
    func theExactCommandFromTheIncidentIsRecognisedAsNeverExiting() {
        // If this ever returns false the foreground guard stops firing and the
        // whole failure is reachable again.
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("npm run dev"))
    }

    @Test
    func theOtherWaysAReaderRunsAnAppFromSourceAreRecognisedToo() {
        for command in [
            "npm run dev",
            "pnpm dev",
            "yarn start",
            "bun run serve",
            "next dev",
            "vite",
            "rails server",
            "cargo run",
            "python3 -m http.server",
        ] {
            #expect(GuideAutopilotCommandShape.holdsTheShellOpen(command), "\(command)")
        }
    }

    @Test
    func anOrdinaryCommandIsNotMistakenForAServer() {
        for command in ["npm install", "git status", "ls -la", "npm run build", "cargo build"] {
            #expect(!GuideAutopilotCommandShape.holdsTheShellOpen(command), "\(command)")
        }
    }

    // MARK: - Liveness comes from the kernel

    @MainActor
    @Test
    func aProcessThatExistsIsAliveAndOneThatCannotIsNot() {
        #expect(IrisBackgroundCommands.isAlive(pid: getpid()))
        // Above the default pid ceiling, so nothing can be there.
        #expect(!IrisBackgroundCommands.isAlive(pid: 999_999))
        #expect(!IrisBackgroundCommands.isAlive(pid: 0))
        #expect(!IrisBackgroundCommands.isAlive(pid: -1))
    }

    @MainActor
    @Test
    func aSurvivingCommandIsReportedRunningAndCanBeStopped() async throws {
        let approved = try #require(GuideAutopilotRiskAssessment.approve("sleep 30"))
        let outcome = await IrisBackgroundCommands.shared.start(
            approved,
            workingDirectory: NSHomeDirectory()
        )

        guard case .running(let record) = outcome else {
            Issue.record("sleep 30 should still have been alive after the settle window")
            return
        }
        #expect(IrisBackgroundCommands.isAlive(pid: record.pid))

        let listed = IrisBackgroundCommands.shared.statuses().first { $0.command.id == record.id }
        #expect(listed?.isRunning == true)

        #expect(IrisBackgroundCommands.shared.stop(id: record.id))
        // Terminate is asynchronous at the kernel; what must be true
        // immediately is that Iris no longer claims to be holding it.
        #expect(IrisBackgroundCommands.shared.status(id: record.id) == nil)
    }

    @MainActor
    @Test
    func aCommandThatDiesAtOnceIsReportedDeadRatherThanStarted() async throws {
        // The shape of the original lie: "it started" said about something
        // that is already gone. Exit 3 immediately.
        let approved = try #require(GuideAutopilotRiskAssessment.approve("exit 3"))
        let outcome = await IrisBackgroundCommands.shared.start(
            approved,
            workingDirectory: NSHomeDirectory()
        )

        guard case .exitedImmediately(let exitCode, _) = outcome else {
            Issue.record("a command that exits at once must not be reported as running")
            return
        }
        #expect(exitCode == 3)
    }

    // MARK: - Not killing a stranger

    @MainActor
    @Test
    func aRecycledPidRunningSomethingElseIsLeftAlone() {
        // The reap at launch keys on pid AND command text precisely so a pid
        // that has been handed to an unrelated process is not killed. This
        // process is real and is definitely not the recorded command.
        #expect(
            !IrisBackgroundCommands.processLooksLikeOurs(
                pid: getpid(),
                commandText: "npm run dev --workspace=something-we-never-started"
            )
        )
    }
}
