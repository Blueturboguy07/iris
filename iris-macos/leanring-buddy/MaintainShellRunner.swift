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
    case testProjectNotRegistered
    case testWorkingDirectoryUnavailable
    case testEnvironmentUnavailable
    case sandboxUnavailable
}

/// One runner per repo. `nonisolated` — the fix loop runs long builds and
/// must never occupy the main actor; callers hop back for UI.
nonisolated final class MaintainShellRunner: Sendable {

    /// Everything this runner ever touches lives under here.
    let repoRootPath: String

    /// The policy is captured when the runner is created. Test still performs
    /// the registry check again in `run`, so a project removed from the exact
    /// Test registry cannot continue using an already-created runner.
    private let processPolicy: MaintainSandbox.ProcessPolicy

    /// True only for a runner explicitly using Test's confined process policy.
    /// Commit code uses this read-only fact to select a disposable identity;
    /// ordinary and HEADLESS runners retain their existing Git behavior.
    var isTestProcessPolicy: Bool {
        if case .test = processPolicy { return true }
        return false
    }

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

    init(
        repoRootPath: String,
        processPolicy explicitPolicy: MaintainSandbox.ProcessPolicy? = nil
    ) throws {
        let selectedPolicy = explicitPolicy ?? MaintainSandbox.runtimeProcessPolicy()
        switch selectedPolicy {
        case .unavailable:
            throw MaintainShellRunnerError.testEnvironmentUnavailable
        case .test:
            guard MaintainSandbox.isAvailable else {
                throw MaintainShellRunnerError.sandboxUnavailable
            }
            guard let canonical = MaintainSandbox.canonicalExistingDirectory(repoRootPath),
                  URL(fileURLWithPath: repoRootPath).standardizedFileURL.path == canonical,
                  MaintainSandbox.repositoryIsAllowed(canonical, under: selectedPolicy) else {
                throw MaintainShellRunnerError.testProjectNotRegistered
            }
            self.repoRootPath = canonical
        case .headless, .ordinary:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repoRootPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MaintainShellRunnerError.repoRootDoesNotExist
            }
            // Preserve the ordinary and HEADLESS lexical path behavior.
            self.repoRootPath = (repoRootPath as NSString).standardizingPath
        }
        self.processPolicy = selectedPolicy
    }

    /// Runs one command via /bin/zsh -c in a directory under the repo root.
    ///
    /// `-l` sources .zshenv and .zprofile, which is where cargo and some node
    /// installs put themselves. What it does NOT source is ~/.zshrc, because
    /// zsh reads that for interactive shells only — and ~/.zshrc is where
    /// `brew shellenv`, nvm, fnm, volta and bun actually live. Combined with a
    /// Finder-launched Iris, whose inherited PATH is launchd's four system
    /// directories, that is how the Tier C verifier came to report "the
    /// environment has no `pnpm` executable; the repository explicitly
    /// requires pnpm 11" about a reader who has pnpm.
    ///
    /// So the child is handed `LoginShellEnvironment`'s merged PATH instead of
    /// Iris's own. `-l` stays: path_helper reorders that PATH but preserves
    /// every entry (measured), and dropping `-l` would lose the other things
    /// .zprofile exports that a build needs.
    func run(
        _ commandText: String,
        inSubdirectory subdirectory: String? = nil,
        deadline: TimeInterval = 900
    ) async throws -> MaintainCommandResult {
        let workingDirectory: String
        switch processPolicy {
        case .test:
            // Registry membership and canonical spelling are checked at every
            // spawn, not only when this runner instance was initialized.
            guard MaintainSandbox.repositoryIsAllowed(repoRootPath, under: processPolicy) else {
                throw MaintainShellRunnerError.testProjectNotRegistered
            }
            if let subdirectory {
                guard !subdirectory.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    throw MaintainShellRunnerError.workingDirectoryOutsideRepoRoot
                }
                workingDirectory = URL(fileURLWithPath: repoRootPath, isDirectory: true)
                    .appendingPathComponent(subdirectory, isDirectory: true)
                    .standardizedFileURL.path
            } else {
                workingDirectory = repoRootPath
            }
            guard workingDirectory == repoRootPath
                || workingDirectory.hasPrefix(repoRootPath + "/"),
                  let canonical = MaintainSandbox.canonicalExistingDirectory(workingDirectory),
                  canonical == workingDirectory else {
                throw MaintainShellRunnerError.testWorkingDirectoryUnavailable
            }
        case .headless, .ordinary:
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
        case .unavailable:
            throw MaintainShellRunnerError.testEnvironmentUnavailable
        }

        let jail: (invocation: String, profilePath: String)?
        let requiresJail: Bool
        switch processPolicy {
        case .headless, .test:
            requiresJail = true
            jail = MaintainSandbox.jailedInvocation(
                forCommand: commandText,
                repoRootPath: repoRootPath,
                policy: processPolicy
            )
        case .ordinary:
            requiresJail = false
            jail = nil
        case .unavailable:
            requiresJail = true
            jail = nil
        }
        guard !requiresJail || jail != nil else {
            return MaintainCommandResult(
                exitCode: 126,
                outputTail: "Command sandbox could not be created.",
                timedOut: false,
                bytesDroppedBeforeTail: 0
            )
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            let isJailedProcess = requiresJail
            switch processPolicy {
            case .headless:
                // A disposable fixture needs tools, not the user's shell
                // startup scripts, Git hooks or global Git identity.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [
                    "-e", "setpgrp(0,0) or die 'process group failed'; exec @ARGV; die 'exec failed';",
                    "--", "/bin/zsh", "-f", "-c", jail!.invocation
                ]
                process.environment = MaintainSandbox.headlessProcessEnvironment()
            case .test(let testPolicy):
                // Test has the same process-group cleanup as HEADLESS, but a
                // separate environment and the stricter Test Seatbelt policy.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [
                    "-e", "setpgrp(0,0) or die 'process group failed'; exec @ARGV; die 'exec failed';",
                    "--", "/bin/zsh", "-f", "-c", jail!.invocation
                ]
                process.environment = MaintainSandbox.testProcessEnvironment(for: testPolicy)
            case .ordinary:
                // The ordinary app keeps its login-shell behavior and user
                // toolchain environment exactly as before.
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", commandText]
                process.environment = LoginShellEnvironment.environmentForChildProcesses()
            case .unavailable:
                // Guarded above; retained for exhaustive setup and fail-closed
                // if this switch is changed independently later.
                continuation.resume(returning: MaintainCommandResult(
                    exitCode: 126,
                    outputTail: "Test process policy is unavailable.",
                    timedOut: false,
                    bytesDroppedBeforeTail: 0
                ))
                return
            }
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
                    if isJailedProcess { killpg(process.processIdentifier, SIGKILL) }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeoutWork)

            process.terminationHandler = { finished in
                // A completed or timed-out shell must not leave fixture jobs
                // running in the process group it created for this command.
                if isJailedProcess { killpg(finished.processIdentifier, SIGKILL) }
                if let jail { try? FileManager.default.removeItem(atPath: jail.profilePath) }
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
                if let jail { try? FileManager.default.removeItem(atPath: jail.profilePath) }
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
