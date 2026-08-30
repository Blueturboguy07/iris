//
//  Test6PathReproTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS, two reports that turn out to be one bug:
//
//    - "When you quit and re-open Iris, it does not save what stage of the
//      install you were at." Saved progress at step 12 or 11 was repeatedly
//      moved back to step 2, because Iris believed pnpm was missing, even
//      though pnpm installation had succeeded earlier in each run.
//    - From the Tier C verifier, mid-run: "the environment has no `pnpm`
//      executable; the repository explicitly requires pnpm 11." The reader
//      HAS pnpm. Their own shell prints a version for it.
//
//  WHAT IS ACTUALLY WRONG. An Iris launched from Finder does not inherit the
//  reader's login-shell PATH; it inherits launchd's. That was measured on this
//  Mac rather than assumed — a stub .app bundle whose executable dumps its own
//  environment, opened by Finder itself (`tell application "Finder" to open`,
//  not `open`, which leaks the caller's environment) — and the answer was
//  exactly:
//
//      PWD=/
//      PATH=/usr/bin:/bin:/usr/sbin:/sbin
//
//  and nothing else. Note what is NOT there: /opt/homebrew/bin, ~/.npm-global
//  /bin, and — the one that does the damage — any directory holding `node`.
//
//  So `locateExecutableOnSearchPath` misses pnpm, `trustedToolFallbackPaths`
//  then FINDS it (~/.npm-global/bin/pnpm on this machine), and Iris executes
//  it directly. pnpm, npm, npx, corepack and every node_modules/.bin/* shim
//  are `#!/usr/bin/env node` scripts, and with that PATH the shebang cannot
//  resolve `node`:
//
//      env: node: No such file or directory        (exit 127)
//
//  127 is not zero, so `checkToolVersionBlocking` throws `versionCheckFailed`,
//  `checkOneTool` turns that into `.couldNotBeChecked`, and
//  `gatherPositionEvidence` records "does `pnpm` respond on this machine:
//  could not check". Paired with a missing ui/node_modules, the position
//  finder correctly concludes the reader is back at install-pnpm — from a
//  false premise. The reader sees their progress thrown away.
//
//  `node` itself is fine under the same PATH, because its fallback is a real
//  Mach-O binary and not a shebang script. That asymmetry is the proof this is
//  a PATH-inheritance bug and not a missing tool.
//
//  These tests recreate the reader's machine by putting THIS process on the
//  PATH a Finder launch measurably gives, then asking Iris its own question.
//  The suite is `.serialized` and restores PATH in a `defer`, because setenv
//  is process-global.
//

import Foundation
import Testing
@testable import Iris

// MARK: - The condition a Finder launch puts Iris in

/// The exact PATH a Finder-launched app gets on macOS, measured (see the file
/// comment). Not the value the comment in `ToolVersionService` claims — there
/// is no /usr/local/bin in it, and that difference is load-bearing, because
/// /usr/local/bin/node exists on this Mac and would have hidden the bug.
private let pathThatAFinderLaunchGives = "/usr/bin:/bin:/usr/sbin:/sbin"

/// Runs `body` with this process on launchd's PATH, then puts PATH back.
///
/// The login-shell PATH capture is forgotten on the way in AND on the way out,
/// so the capture that answers inside `body` is one made from the reproduced
/// condition — a process on launchd's PATH — and not one some earlier test
/// took under the test runner's much richer environment. Forgetting it again
/// afterwards keeps this suite from leaving a Finder-shaped answer cached for
/// everything that runs after it.
private func withTheEnvironmentAFinderLaunchGives<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    let pathBeforeTheTest = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", pathThatAFinderLaunchGives, 1)
    LoginShellEnvironment.forgetTheCapturedSearchPath()
    defer {
        if let pathBeforeTheTest {
            setenv("PATH", pathBeforeTheTest, 1)
        } else {
            unsetenv("PATH")
        }
        LoginShellEnvironment.forgetTheCapturedSearchPath()
    }
    warmTheLoginShellCaptureOffTheMainThread()
    return try body()
}

/// Resolve the login-shell PATH from a thread that is definitely not the main
/// one. `LoginShellEnvironment` deliberately refuses to run somebody's whole
/// dotfile stack on the main thread — an eight-second beachball would be a
/// worse bug than the one being fixed — and hands a main-thread caller the
/// inherited PATH while it resolves in the background. Every production caller
/// of the version check is already off the main thread; a test that happened
/// to run on it would otherwise measure that refusal instead of the fix.
private func warmTheLoginShellCaptureOffTheMainThread() {
    let captureHasFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        _ = LoginShellEnvironment.capturedLoginShellSearchPath()
        captureHasFinished.signal()
    }
    captureHasFinished.wait()
}

/// Whether the reader's own login shell can run this tool — the ground truth
/// these tests are measured against, established WITHOUT going through any of
/// the Iris lookup code under test. A machine that genuinely has no pnpm is a
/// machine where "pnpm is missing" is the right answer, so there is nothing to
/// reproduce and the test is skipped rather than failed.
private func theLoginShellCanRun(_ toolName: String) -> Bool {
    let loginShellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    guard let result = try? ToolVersionService.runCommand(
        executablePath: loginShellPath,
        arguments: ["-l", "-c", "\(toolName) --version"],
        environment: nil,
        workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
    ) else { return false }
    return result.terminationStatus == 0
}

private let theLoginShellCanRunPnpm = theLoginShellCanRun("pnpm")
private let theLoginShellCanRunNpm = theLoginShellCanRun("npm")

@Suite(.serialized) struct Test6PathReproTests {

    // MARK: - The reported symptom, at the fact that causes it

    /// "When you quit and re-open Iris, it does not save what stage of the
    /// install you were at."
    ///
    /// It does save it. It then throws it away, because this check — the one
    /// fact the whole resume decision hangs off — says pnpm cannot be checked
    /// on a machine that has pnpm installed and working.
    @Test(
        "a Finder-launched Iris can still check pnpm",
        .enabled(if: theLoginShellCanRunPnpm)
    )
    func aFinderLaunchedIrisCanStillCheckPnpm() throws {
        try withTheEnvironmentAFinderLaunchGives {
            do {
                let toolVersion = try ToolVersionService.checkToolVersionBlocking(tool: "pnpm")
                #expect(
                    toolVersion.available,
                    """
                    Iris reported pnpm as ABSENT on a Mac whose own login shell \
                    runs it. The position finder reads this as "no" and sends \
                    the reader back to the install-pnpm step.
                    """
                )
                #expect(
                    toolVersion.version.first?.isNumber == true,
                    "pnpm answered with something that is not a version: '\(toolVersion.version)'"
                )
            } catch let toolVersionError as ToolVersionError {
                Issue.record(
                    """
                    Iris could not check pnpm at all: \
                    \(toolVersionError.userFacingMessage) — the position finder \
                    records this as "could not check" and the reader's saved \
                    step is discarded.
                    """
                )
            }
        }
    }

    /// pnpm is not special. Every Node-based tool a guide can watch for is the
    /// same `#!/usr/bin/env node` shim, so if this bug is real for pnpm it is
    /// real for npm too — which is what makes it a class of failure rather
    /// than one unlucky tool.
    @Test(
        "a Finder-launched Iris can still check npm",
        .enabled(if: theLoginShellCanRunNpm)
    )
    func aFinderLaunchedIrisCanStillCheckNpm() throws {
        try withTheEnvironmentAFinderLaunchGives {
            do {
                let toolVersion = try ToolVersionService.checkToolVersionBlocking(tool: "npm")
                #expect(toolVersion.available, "Iris reported npm as absent on a Mac that has npm.")
                #expect(
                    toolVersion.version.first?.isNumber == true,
                    "npm answered with something that is not a version: '\(toolVersion.version)'"
                )
            } catch let toolVersionError as ToolVersionError {
                Issue.record("Iris could not check npm at all: \(toolVersionError.userFacingMessage)")
            }
        }
    }

    // MARK: - The mechanism, asserted where the fix has to land

    /// Iris FINDS pnpm and then cannot run it. Adding more fallback paths — the
    /// last attempt at this — cannot help: the path it already picks is the
    /// right file, and the child process is what is broken. The environment
    /// Iris hands its children has to be able to resolve `node`.
    @Test(
        "the pnpm Iris picks can actually run in the environment Iris gives it",
        .enabled(if: theLoginShellCanRunPnpm)
    )
    func theExecutableIrisPicksCanActuallyRun() throws {
        try withTheEnvironmentAFinderLaunchGives {
            let searchPathLookupOutcome = ToolVersionService
                .locateExecutableOnSearchPath(named: "pnpm")
            let executablePath = try ToolVersionService.selectToolExecutablePath(
                tool: "pnpm",
                searchPathLookupOutcome: searchPathLookupOutcome,
                trustedFallbackPaths: ToolVersionService.trustedToolFallbackPaths(for: "pnpm")
            )
            guard let executablePath else {
                Issue.record("Iris found no pnpm at all on a Mac whose login shell runs it.")
                return
            }

            // Exactly how `checkToolVersionBlocking` spawns it — the same two
            // named values it passes, rather than a copy of them, so this test
            // cannot go on passing while the real probe drifts somewhere else.
            // Before the fix both were nil: the child inherited launchd's PATH
            // and the shebang could not find node.
            let commandResult = try ToolVersionService.runCommand(
                executablePath: executablePath,
                arguments: ["--version"],
                environment: ToolVersionService.environmentForToolVersionCommands(),
                workingDirectory: ToolVersionService.workingDirectoryForToolVersionCommands()
            )
            let output = ToolVersionService.boundedCommandOutput(
                standardOutput: commandResult.standardOutput,
                standardError: commandResult.standardError
            )
            #expect(
                commandResult.terminationStatus == 0,
                """
                Iris picked \(executablePath) and could not run it: \
                exit \(commandResult.terminationStatus), '\(output)'. \
                The file is there; the environment it was launched in has no node.
                """
            )
        }
    }

    /// The asymmetry that names the cause. `node` is a real binary at a
    /// fallback path, so it answers even on launchd's PATH; pnpm is a shebang
    /// script that needs `node` to be findable, so it does not. Two tools, one
    /// PATH, opposite answers — which is a PATH bug, not a missing install.
    @Test(
        "Iris does not answer differently for node and for the tools node runs",
        .enabled(if: theLoginShellCanRunPnpm)
    )
    func nodeAndPnpmGetTheSameAnswer() throws {
        try withTheEnvironmentAFinderLaunchGives {
            let nodeIsUsable = (try? ToolVersionService.checkToolVersionBlocking(tool: "node"))?
                .available ?? false
            let pnpmIsUsable = (try? ToolVersionService.checkToolVersionBlocking(tool: "pnpm"))?
                .available ?? false
            #expect(
                nodeIsUsable == pnpmIsUsable,
                """
                node usable: \(nodeIsUsable), pnpm usable: \(pnpmIsUsable). \
                Both are installed on this Mac. A disagreement here is Iris \
                reporting on its own PATH, not on the reader's machine.
                """
            )
        }
    }
}
