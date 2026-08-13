//
//  MaintainShellRunner.swift
//  leanring-buddy
//
//  Runs the fix loop's own commands — `git apply`, a build, a test suite —
//  as plain child processes with a working directory and a deadline.
//
//  Deliberately NOT the guide autopilot's pty session: that exists to type
//  into a visible, interactive shell the way a person would, with ZLE tamed
//  and output paced for reading. Verification is machinery, not theater —
//  it wants exit codes and captured output, tolerates no prompt noise, and
//  runs many commands back to back. A pty would add failure modes and
//  remove nothing.
//
//  Commands that reach this runner are code-authored (the harness's fixed
//  build/test/git vocabulary) or have already passed the risk gate (a
//  model-proposed fix). The runner still refuses to run outside the repo
//  root it was created for — the last line of the "writes stay inside the
//  app's repo" rule, enforced where the process actually spawns.
//

import Foundation

struct MaintainCommandResult: Sendable {
    let exitCode: Int32
    /// Combined stdout+stderr, tail-bounded — verification wants the error,
    /// not a gigabyte of webpack progress bars.
    let outputTail: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

enum MaintainShellRunnerError: Error {
    case workingDirectoryOutsideRepoRoot
    case repoRootDoesNotExist
}

/// One runner per repo. `nonisolated` — the fix loop runs long builds and
/// must never occupy the main actor; callers hop back for UI.
nonisolated final class MaintainShellRunner: Sendable {

    /// Everything this runner ever touches lives under here.
    let repoRootPath: String

    private static let outputTailLimit = 16_384

    init(repoRootPath: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoRootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MaintainShellRunnerError.repoRootDoesNotExist
        }
        self.repoRootPath = (repoRootPath as NSString).standardizingPath
    }

    /// Runs one command via /bin/zsh -c in a directory under the repo root.
    /// The login environment is rebuilt the same way the autopilot shell's
    /// is (PATH from the user's dotfiles via the shared ZDOTDIR trick would
    /// be overkill here — a login zsh -l -c sources .zprofile and .zshenv
    /// through the normal path because no ZDOTDIR override is set).
    func run(
        _ commandText: String,
        inSubdirectory subdirectory: String? = nil,
        deadline: TimeInterval = 900
    ) async throws -> MaintainCommandResult {
        let workingDirectory: String
        if let subdirectory {
            workingDirectory = ((repoRootPath as NSString)
                .appendingPathComponent(subdirectory) as NSString).standardizingPath
        } else {
            workingDirectory = repoRootPath
        }
        guard workingDirectory == repoRootPath
            || workingDirectory.hasPrefix(repoRootPath + "/") else {
            throw MaintainShellRunnerError.workingDirectoryOutsideRepoRoot
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -l so PATH comes from the user's login files — cargo lives in
            // ~/.zshenv, node in .zprofile, exactly the lesson the autopilot
            // shell already paid for.
            process.arguments = ["-l", "-c", commandText]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let collector = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data) }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    collector.markTimedOut()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeoutWork)

            process.terminationHandler = { finished in
                timeoutWork.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = try? pipe.fileHandleForReading.readToEnd()
                if let remaining, !remaining.isEmpty { collector.append(remaining) }
                continuation.resume(returning: MaintainCommandResult(
                    exitCode: finished.terminationStatus,
                    outputTail: collector.tail(limit: Self.outputTailLimit),
                    timedOut: collector.didTimeOut
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                continuation.resume(returning: MaintainCommandResult(
                    exitCode: 127,
                    outputTail: "failed to spawn: \(error.localizedDescription)",
                    timedOut: false
                ))
            }
        }
    }

    /// Byte sink shared between the readability handler's queue and the
    /// termination handler. A lock, because the two race by design.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var timedOut = false

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            if buffer.count > 1_048_576 {
                buffer = buffer.suffix(262_144)
            }
        }

        func markTimedOut() {
            lock.lock()
            defer { lock.unlock() }
            timedOut = true
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func tail(limit: Int) -> String {
            lock.lock()
            defer { lock.unlock() }
            let slice = buffer.suffix(limit)
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
