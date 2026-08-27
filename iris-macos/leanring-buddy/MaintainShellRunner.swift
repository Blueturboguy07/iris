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
    /// How many bytes this runner dropped off the FRONT of the output to
    /// produce `outputTail`. Zero means `outputTail` is the whole thing.
    ///
    /// It exists because a truncation nobody reports is a truncation nobody can
    /// mention. The Tier C loop truncates a second time before showing output
    /// to the model and marks its own cut — but it was marking a cut in a
    /// string this runner had ALREADY silently clipped, so the "head" it
    /// labelled as the start of the output was the start of the last 16KB of
    /// it. Reporting the number here is what lets the only layer that talks to
    /// the model tell the truth about both cuts.
    let bytesDroppedBeforeTail: Int

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

    /// How much of a command's combined output survives to `outputTail`.
    ///
    /// Deliberately far above what any consumer keeps (the Tier C loop shows a
    /// model 4,000 characters; verification reads the last 2,000 of a failure)
    /// so that in the ordinary case this layer truncates NOTHING and there is
    /// exactly one truncator in the pipeline. At 16KB it routinely became a
    /// second, silent one: `cat` of a real 40KB source file — the on-demand
    /// loop's most common command — was clipped here before the loop ever saw
    /// it, so the loop's own "head + [middle omitted] + tail" marker described
    /// a gap that was not where it said it was. When even this is exceeded the
    /// overflow is counted into `bytesDroppedBeforeTail` rather than vanishing.
    private static let outputTailLimit = 65_536

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
                let (tail, droppedByteCount) = collector.tail(limit: Self.outputTailLimit)
                continuation.resume(returning: MaintainCommandResult(
                    exitCode: finished.terminationStatus,
                    outputTail: tail,
                    timedOut: collector.didTimeOut,
                    bytesDroppedBeforeTail: droppedByteCount
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                continuation.resume(returning: MaintainCommandResult(
                    exitCode: 127,
                    outputTail: "failed to spawn: \(error.localizedDescription)",
                    timedOut: false,
                    bytesDroppedBeforeTail: 0
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
        /// Bytes discarded off the FRONT of the stream, across every trim.
        private var droppedByteCount = 0

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            if buffer.count > 1_048_576 {
                // A runaway command's output is bounded here, but the bytes
                // dropped are COUNTED — a consumer that shows this output to a
                // model has to be able to say that a beginning existed.
                let keptSuffix = buffer.suffix(262_144)
                droppedByteCount += buffer.count - keptSuffix.count
                buffer = Data(keptSuffix)
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

        /// The last `limit` bytes as text, plus how many bytes were dropped off
        /// the front to get there — this call's own clip added to anything the
        /// overflow trim in `append` already discarded.
        func tail(limit: Int) -> (text: String, bytesDropped: Int) {
            lock.lock()
            defer { lock.unlock() }
            let slice = buffer.suffix(limit)
            return (
                String(decoding: slice, as: UTF8.self),
                droppedByteCount + (buffer.count - slice.count)
            )
        }
    }
}
