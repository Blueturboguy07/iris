//
//  LoginShellEnvironment.swift
//  leanring-buddy
//
//  The `PATH` Iris hands to the child processes it spawns, resolved from the
//  reader's own login shell instead of inherited from launchd.
//
//  THE REPORTED SYMPTOM, in the reader's words: "When you quit and re-open
//  Iris, it does not save what stage of the install you were at." Their saved
//  step 12 kept being moved back to step 2. Iris was saving it correctly and
//  then throwing it away: `GuideActualPositionFinder` asks `ToolVersionService`
//  whether `pnpm` responds on this machine, got "could not check" on a Mac
//  where pnpm works perfectly, and concluded — correctly, from a false premise
//  — that the reader was back at the install-pnpm step. The same false fact
//  reached the Tier C verifier as "the environment has no `pnpm` executable;
//  the repository explicitly requires pnpm 11", to a reader who has pnpm.
//
//  WHY. An app launched from Finder inherits launchd's environment, not the
//  environment the reader's shell builds. Measured on this Mac with a stub
//  .app whose executable dumps its own environment, opened by Finder itself:
//
//      PWD=/
//      PATH=/usr/bin:/bin:/usr/sbin:/sbin
//
//  and nothing else — no /opt/homebrew/bin, no npm prefix, and crucially no
//  directory holding `node`. `pnpm`, `npm`, `npx`, `corepack` and every
//  node_modules/.bin/* shim is a `#!/usr/bin/env node` script, so Iris FOUND
//  pnpm through its fallback discovery, executed that exact file, and the
//  shebang could not resolve its interpreter:
//
//      env: node: No such file or directory        (exit 127)
//
//  127 is not zero, so the version check throws, and a throw means "could not
//  check" all the way up. `node` itself answers fine under the same PATH
//  because its fallback is a real Mach-O binary — that asymmetry is the proof
//  this is a PATH-inheritance bug and not a missing tool.
//
//  WHY NOT MORE FALLBACK PATHS. That was the previous pass at this, and it is
//  what made the failure so confusing: the fallback list is already right, it
//  hands back the correct file. What is broken is the ENVIRONMENT the child is
//  launched in, and no list of paths can fix a shebang that cannot find its
//  interpreter. Iris kept getting better at finding a tool it could not run.
//
//  WHY `-l -i` AND NOT `-l`. zsh reads ~/.zshrc for INTERACTIVE shells only,
//  and ~/.zshrc is where `brew shellenv`, nvm, fnm, volta, bun and rbenv
//  actually put themselves. `CodexCLILogin` already paid for this lesson in
//  the field — "the original 'ask a login shell' fallback resolved nothing at
//  all". Measured again here, on a synthetic home whose node is added only by
//  .zshrc: `zsh -l -c 'command -v node'` misses it, `zsh -l -i -c` finds it.
//  On THIS Mac the login-only PATH does contain /opt/homebrew/bin, but only
//  because an old Homebrew installer left /etc/paths.d/homebrew behind. That
//  is luck, not a guarantee, and shipping the `-l -c` form would have been a
//  fix that still failed on the next reader's Mac.
//
//  WHY NOT THE AUTOPILOT'S ZDOTDIR. `GuideAutopilotShellSession` drives an
//  interactive shell through a generated ZDOTDIR, but that exists to disable
//  ZLE — zsh's line editor — which only exists when the shell has a pty. Here
//  stdio is pipes, so there is no ZLE to tame and `-l -i` sources .zshenv,
//  .zprofile and .zshrc through the normal path. Borrowing the ZDOTDIR would
//  mean capturing the PATH of a shell Iris had modified, which is one step
//  further from the question actually being asked: what does the reader's own
//  shell see?
//
//  WHAT THIS IS NOT. It is not a replacement for the inherited PATH or for the
//  fallback discovery — it is a UNION with both, captured value first. A
//  reader's dotfiles can be broken, slow, or absent; when the capture fails
//  everything behaves exactly as it did before this file existed.
//

import Foundation

/// Resolves the reader's real login-shell `PATH` once per launch and hands it
/// to every child process Iris spawns.
nonisolated enum LoginShellEnvironment {

    // MARK: - What callers use

    /// The `PATH` every child process should be launched with: what the
    /// reader's own shell would use, then whatever this process inherited,
    /// deduplicated and in that order.
    ///
    /// The captured half goes first deliberately. It is the same answer the
    /// guide autopilot's shell gets, so "does pnpm respond on this machine"
    /// and "what does `pnpm install` actually run" can no longer disagree —
    /// and a disagreement between those two is what the reader experienced as
    /// lost progress. `nil` only when there is no PATH at all to offer, which
    /// keeps `locateExecutableOnSearchPath`'s "PATH is not set" case honest.
    static func searchPathForChildProcesses() -> String? {
        mergedSearchPath(
            capturedFromLoginShell: capturedLoginShellSearchPath(),
            inheritedFromThisProcess: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    /// This process's environment with `PATH` replaced by the merged one.
    /// Everything else is passed through untouched: a build that needs the
    /// reader's `CARGO_HOME` or proxy variables should still get them.
    static func environmentForChildProcesses() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath = searchPathForChildProcesses() {
            environment["PATH"] = searchPath
        }
        return environment
    }

    // MARK: - Merging (pure)

    /// Both lists, captured first, without duplicates and without the empty
    /// component that means "the current directory" — a relative entry in a
    /// PATH Iris hands to a build is a hazard nobody asked for.
    static func mergedSearchPath(
        capturedFromLoginShell: String?,
        inheritedFromThisProcess: String?
    ) -> String? {
        var mergedDirectories: [String] = []
        var directoriesAlreadyAdded = Set<String>()
        for searchPathList in [capturedFromLoginShell, inheritedFromThisProcess] {
            guard let searchPathList else { continue }
            for component in searchPathList.split(separator: ":", omittingEmptySubsequences: true) {
                let directory = String(component)
                if directoriesAlreadyAdded.insert(directory).inserted {
                    mergedDirectories.append(directory)
                }
            }
        }
        return mergedDirectories.isEmpty ? nil : mergedDirectories.joined(separator: ":")
    }

    // MARK: - Capturing it from the reader's shell (once per launch)

    /// The reader's login-shell `PATH`, or nil if it could not be read.
    ///
    /// Captured at most once per launch, because it costs a subprocess that
    /// sources somebody's entire dotfile stack. A reader who installs a tool
    /// while Iris is running is still served: the fallback discovery in
    /// `ToolVersionService` re-runs every time and finds tools this PATH
    /// misses.
    static func capturedLoginShellSearchPath() -> String? {
        if let settledCapture = captureIfItHasSettled() {
            return settledCapture
        }

        // A cold interactive shell with heavy dotfiles legitimately takes
        // seconds (`GuideAutopilotShellSession.readyDeadline` allows sixty).
        // Blocking the main thread for that would trade a wrong tool check for
        // a beachball, so a main-thread caller gets the inherited PATH now and
        // the answer from the launch after this one — every consumer that
        // matters (the version checks, the verifier's runner) is already off
        // the main thread by design.
        guard !Thread.isMainThread else {
            startTheCaptureInTheBackground()
            return nil
        }

        captureSerializationLock.lock()
        defer { captureSerializationLock.unlock() }
        // A second thread that queued behind the lock must not run the shell
        // again — the first one through has already settled the answer.
        if let settledCapture = captureIfItHasSettled() {
            return settledCapture
        }

        let capturedSearchPath = captureFromTheReadersLoginShell()
        captureStateLock.lock()
        capturedLoginShellSearchPathValue = capturedSearchPath
        captureHasSettled = true
        captureStateLock.unlock()
        return capturedSearchPath
    }

    /// Throw away this launch's answer. Exists for tests, which need to prove
    /// the capture works rather than that some earlier test cached it.
    static func forgetTheCapturedSearchPath() {
        captureStateLock.lock()
        capturedLoginShellSearchPathValue = nil
        captureHasSettled = false
        aBackgroundCaptureIsUnderway = false
        captureStateLock.unlock()
    }

    private static let captureStateLock = NSLock()
    private static let captureSerializationLock = NSLock()
    private nonisolated(unsafe) static var capturedLoginShellSearchPathValue: String?
    private nonisolated(unsafe) static var captureHasSettled = false
    private nonisolated(unsafe) static var aBackgroundCaptureIsUnderway = false

    /// `.some(value)` once the capture has run — where `value` is itself
    /// optional, because "we asked and the shell had nothing for us" is a
    /// settled answer and must not trigger the subprocess again.
    private static func captureIfItHasSettled() -> String?? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return captureHasSettled ? .some(capturedLoginShellSearchPathValue) : nil
    }

    private static func startTheCaptureInTheBackground() {
        captureStateLock.lock()
        let someoneElseIsAlreadyDoingIt = aBackgroundCaptureIsUnderway
        aBackgroundCaptureIsUnderway = true
        captureStateLock.unlock()
        guard !someoneElseIsAlreadyDoingIt else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = capturedLoginShellSearchPath()
        }
    }

    private static func captureFromTheReadersLoginShell() -> String? {
        let loginShellPath = GuideAutopilotShellSession.loginShellPath()
        for attempt in captureAttempts {
            guard let rawShellOutput = runTheCaptureCommand(
                loginShellPath: loginShellPath,
                arguments: attempt.arguments + ["-c", searchPathCaptureCommand],
                deadline: attempt.deadline
            ) else { continue }
            guard let capturedSearchPath = searchPathFromShellOutput(rawShellOutput),
                  searchPathNamesAtLeastOneRealDirectory(capturedSearchPath) else { continue }
            irisTrace(
                "login-shell PATH captured with \(attempt.arguments.joined(separator: " ")): "
                + "\(capturedSearchPath.split(separator: ":").count) directories"
            )
            return capturedSearchPath
        }
        // Worth saying out loud: from here on Iris is back to launchd's PATH
        // plus the fallback discovery, which is where the reported bug lives.
        irisTrace("login-shell PATH capture failed — falling back to this process's own PATH")
        return nil
    }

    /// Interactive-login first because that is the one that reads ~/.zshrc;
    /// login-only second for a shell where `-i` misbehaves. Same order, and
    /// the same reasoning, as `CodexCLILogin.resolveCodexOnPathViaShell`.
    ///
    /// The deadlines are short on purpose. This runs before a tool check can
    /// answer, and a reader whose dotfiles hang should get "Iris could not
    /// check" a few seconds later, not never.
    private static let captureAttempts: [(arguments: [String], deadline: TimeInterval)] = [
        (arguments: ["-l", "-i"], deadline: 8),
        (arguments: ["-l"], deadline: 4),
    ]

    // MARK: - Reading the answer out of the shell's chatter

    /// A dotfile stack is allowed to print things — instant prompts, version
    /// manager notices, a fortune. So the PATH is fenced rather than assumed
    /// to be the whole of stdout, which is the same raw-sentinel-scan trick
    /// the autopilot pty uses to find where a command's output starts.
    private static let searchPathBeginMarker = "<<<IRIS-PATH:"
    private static let searchPathEndMarker = ":IRIS-PATH>>>"

    static var searchPathCaptureCommand: String {
        "printf '\\n%s%s%s\\n' '\(searchPathBeginMarker)' \"$PATH\" '\(searchPathEndMarker)'"
    }

    /// The fenced PATH, or nil if the shell never printed one. Control
    /// characters are dropped: a `PATH` cannot legitimately contain one, and a
    /// stray escape sequence from a themed prompt must not end up in the
    /// environment of every process Iris spawns.
    static func searchPathFromShellOutput(_ rawShellOutput: String) -> String? {
        guard let beginMarkerRange = rawShellOutput.range(of: searchPathBeginMarker),
              let endMarkerRange = rawShellOutput.range(
                  of: searchPathEndMarker,
                  range: beginMarkerRange.upperBound..<rawShellOutput.endIndex
              ) else {
            return nil
        }
        let fencedText = rawShellOutput[beginMarkerRange.upperBound..<endMarkerRange.lowerBound]
        let withoutControlCharacters = fencedText.filter { character in
            !character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            }
        }
        let searchPathDirectories = withoutControlCharacters
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        return searchPathDirectories.isEmpty
            ? nil
            : searchPathDirectories.joined(separator: ":")
    }

    /// A last sanity check before this value becomes the environment of every
    /// child process: a captured PATH naming nothing that exists is a mangled
    /// read, not a machine with no directories on it.
    static func searchPathNamesAtLeastOneRealDirectory(
        _ searchPath: String,
        directoryExists: (String) -> Bool = { candidatePath in
            var candidateIsDirectory: ObjCBool = false
            let candidateExists = FileManager.default.fileExists(
                atPath: candidatePath, isDirectory: &candidateIsDirectory
            )
            return candidateExists && candidateIsDirectory.boolValue
        }
    ) -> Bool {
        searchPath
            .split(separator: ":", omittingEmptySubsequences: true)
            .contains { directoryExists(String($0)) }
    }

    // MARK: - Running the shell

    private static func runTheCaptureCommand(
        loginShellPath: String,
        arguments: [String],
        deadline: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        // A themed prompt paints escape sequences into stdout on a shell it
        // believes is interactive; `dumb` is how you tell it not to bother.
        environment["TERM"] = "dumb"
        // So a reader's own dotfiles can tell this apart from a shell they
        // opened — and so a config that shells out to Iris cannot recurse.
        environment["IRIS_LOGIN_SHELL_PROBE"] = "1"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read on its own thread rather than after the wait: a chatty dotfile
        // stack that fills the 64KB pipe buffer would otherwise block the
        // shell forever while this thread waits for it to exit.
        let collectedOutput = CollectedShellOutput()
        let readingHasFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collectedOutput.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readingHasFinished.signal()
        }
        let processHasExited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            processHasExited.signal()
        }

        if processHasExited.wait(timeout: .now() + .milliseconds(Int(deadline * 1000))) == .timedOut {
            process.terminate()
            if processHasExited.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = processHasExited.wait(timeout: .now() + .seconds(2))
            }
        }
        _ = readingHasFinished.wait(timeout: .now() + .seconds(2))

        // Whatever it printed before it was killed is still parsed. A shell
        // that prints the PATH and then hangs on the way out has answered the
        // question; discarding that would be throwing away the fix.
        return collectedOutput.text
    }

    /// Somewhere for the reading thread to put what it read. `@unchecked
    /// Sendable` with a lock, the same shape (and the same reason) as
    /// `MaintainShellRunner.OutputCollector`.
    private final class CollectedShellOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var collectedData = Data()

        func store(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            collectedData = data
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: collectedData, as: UTF8.self)
        }
    }
}
