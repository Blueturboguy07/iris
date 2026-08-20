//
//  GuideAutopilotShellSession.swift
//  leanring-buddy
//
//  One persistent login shell for one guide session. Steps in a guide assume
//  their predecessors' state — `cd cue` then `npm ci` — so commands run in a
//  single long-lived shell, not one process per command, and the session
//  remembers its cwd from the end marker of every command.
//
//  The environment is built from scratch, never inherited: a Finder-launched
//  app carries launchd's four-directory PATH, and handing that to the shell
//  is how "Iris says node is missing but it is right there" happens. PATH is
//  deliberately absent from the child environment so the login+interactive
//  shell rebuilds it through path_helper and the user's own dotfiles.
//
//  The shell is driven through a generated ZDOTDIR whose .zshrc loads the
//  user's real zsh setup and then turns off ZLE, zsh's interactive line
//  editor. That is what makes programmatic command injection reliable: with
//  ZLE off there is no per-keystroke echo, no bracketed paste, and no prompt
//  redraw to mangle or wedge the input, and — because it happens during
//  shell startup, before a byte of injected input is read — there is no race.
//  See `privateZdotdir`.
//
//  Exit codes ride an in-band sentinel: after each command the session sends
//      printf '\n__IRIS_END_<token>__ %d\t%s\n' "$?" "$PWD"
//  with a fresh random token per command, matched only at line start — so a
//  file that happens to contain the marker text cannot forge completion.
//  Fields are tab-separated because a cwd with spaces is ordinary.
//
//  Isolation: the sentinel path is confined to the pty's own queue, never
//  the main actor. A running install must complete its bookkeeping even
//  while the app's main thread is busy drawing, or blocked by something
//  unrelated — if marker detection rode the main actor, a stalled UI would
//  read as a stalled shell. Only the public API surface and the output-line
//  callback touch the main actor.
//

import Foundation

/// The local diagnostic log — how the guide autopilot and maintain mode leave
/// a play-by-play a person can read, since os_log is not captured for this
/// signed app. It began life as a throwaway trace for the empty-terminal
/// wedge and became genuinely useful for support and QA, so rather than a
/// TEMPORARY file in the home directory it is a proper, bounded log:
///
///   - it lives in `~/Library/Logs/Iris/` (the conventional place a user or
///     support would look), not loose in the home directory;
///   - it is size-capped and rolls to one `.1` backup, so it can never grow
///     without limit on a long-lived install;
///   - it records STRUCTURE only — app slugs, exit codes, state flags, and
///     random per-command sentinel tokens — never command text, command
///     output, chat/wish text, crash evidence, or any credential. That rule
///     is load-bearing: this file is plaintext and never leaves the machine,
///     but it must still be safe for a user to read or hand to support.
///
/// The message is built on the caller's actor; the write hops to this serial
/// queue, so the size check and roll below are race-free and no
/// actor-isolated state is read off-actor.
private let irisTraceQueue = DispatchQueue(label: "iris.diagnostic.log")
private let irisLogDirectoryPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/Iris")
private let irisTraceFilePath = (irisLogDirectoryPath as NSString)
    .appendingPathComponent("iris.log")
/// Roll at 512 KB; with one backup the log costs at most ~1 MB on disk.
private let irisTraceMaximumBytes = 512 * 1024
func irisTrace(_ message: String) {
    let line = message + "\n"
    irisTraceQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            atPath: irisLogDirectoryPath, withIntermediateDirectories: true
        )
        // Roll before the write when the file has grown past the cap: the
        // current log becomes iris.log.1 (replacing any older backup) and a
        // fresh iris.log starts. Bounds total on-disk size to ~2x the cap.
        if let attributes = try? fileManager.attributesOfItem(atPath: irisTraceFilePath),
           let size = attributes[.size] as? Int, size > irisTraceMaximumBytes {
            let rolledPath = irisTraceFilePath + ".1"
            try? fileManager.removeItem(atPath: rolledPath)
            try? fileManager.moveItem(atPath: irisTraceFilePath, toPath: rolledPath)
        }
        if let handle = FileHandle(forWritingAtPath: irisTraceFilePath) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? line.write(toFile: irisTraceFilePath, atomically: false, encoding: .utf8)
        }
    }
}

/// How one command ended.
enum GuideAutopilotCommandOutcome: Equatable, Sendable {
    case succeeded(workingDirectory: String)
    case failed(exitStatus: Int32, workingDirectory: String)
    /// The reader (or the runner) cancelled it mid-flight.
    case cancelled
    /// No end marker within the deadline; the session was rebuilt.
    case timedOut
    /// Output stopped mid-line and the tail reads like a question. The
    /// command is still running; the runner surfaces this to the reader.
    case seemsToBeAskingAQuestion(tail: String)
    /// The session itself is unusable (spawn failed, shell died).
    case sessionFailed
}

/// The seam the runner is tested through: a fake implements this with
/// scripted outcomes; only `GuideAutopilotShellSession` owns a real pty.
@MainActor
protocol GuideAutopilotShellSessionDriving: AnyObject {
    var onOutputLine: ((String) -> Void)? { get set }
    var currentWorkingDirectory: String { get }
    var resolvedSearchPath: String? { get }
    func start() async -> Bool
    func run(
        _ command: GuideAutopilotApprovedCommand,
        deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome
    func cancelTheRunningCommand() async
    func endSession() async
    func tailForTheModel() -> String
    /// Off-queue hard stop for the escape hatch: SIGKILL the running command's
    /// process group immediately, without waiting on the (often output-flooded)
    /// command queue. The real pty session overrides this; fakes need do
    /// nothing, so it carries a default no-op below.
    func killTheRunningProcessGroupImmediately()
}

extension GuideAutopilotShellSessionDriving {
    func killTheRunningProcessGroupImmediately() {}
}

@MainActor
final class GuideAutopilotShellSession: GuideAutopilotShellSessionDriving {

    static let defaultCommandDeadline: TimeInterval = 900
    /// A cold interactive shell legitimately takes a while on a machine with
    /// heavy dotfiles (nvm alone can add seconds, compinit more).
    static let readyDeadline: TimeInterval = 60
    /// Silence this long, with an unterminated tail that reads like a
    /// question, is surfaced instead of waited out.
    static let promptDetectionSilence: TimeInterval = 20

    /// Delivered on the main actor, for the transcript view.
    var onOutputLine: ((String) -> Void)?

    var currentWorkingDirectory: String { state.snapshotWorkingDirectory() }
    var resolvedSearchPath: String? { state.snapshotSearchPath() }

    private let state: SessionState

    init(startingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        state = SessionState(startingDirectory: startingDirectory)
        state.deliverOutputLine = { [weak self] line in
            Task { @MainActor [weak self] in self?.onOutputLine?(line) }
        }
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            state.enqueueStart { continuation.resume(returning: $0) }
        }
    }

    func run(
        _ command: GuideAutopilotApprovedCommand,
        deadline: TimeInterval = GuideAutopilotShellSession.defaultCommandDeadline
    ) async -> GuideAutopilotCommandOutcome {
        await withCheckedContinuation { continuation in
            state.enqueueRun(command, deadline: deadline) { continuation.resume(returning: $0) }
        }
    }

    func cancelTheRunningCommand() async {
        await withCheckedContinuation { continuation in
            state.enqueueCancel { continuation.resume() }
        }
    }

    func killTheRunningProcessGroupImmediately() {
        state.killTheRunningProcessGroupImmediately()
    }

    func endSession() async {
        await withCheckedContinuation { continuation in
            state.enqueueEnd { continuation.resume() }
        }
    }

    func tailForTheModel() -> String {
        state.snapshotModelTail()
    }

    func displayLinesSnapshot() -> [String] {
        state.snapshotDisplayLines()
    }

    // MARK: - The queue-confined core

    /// Everything below runs on `queue` (or reads under it). Marked
    /// @unchecked Sendable because the queue is the isolation mechanism;
    /// no property is touched off it except via the enqueue/snapshot API.
    private final class SessionState: @unchecked Sendable {

        var deliverOutputLine: ((String) -> Void)?

        private let queue = DispatchQueue(label: "iris.autopilot.shell-session")
        private let startingDirectory: String

        private var terminal: GuideAutopilotPseudoTerminal?
        /// A mirror of `terminal` kept behind a lock so the escape hatch can
        /// SIGKILL the running command's process group WITHOUT going through
        /// `queue`. A heavy build (electron-builder dumping its whole dependency
        /// tree) floods `queue` with `ingest` blocks, so a cancel enqueued
        /// behind them lands far too late — and the build ignores the Ctrl-C the
        /// normal cancel would send anyway. Written on `queue` alongside
        /// `terminal`; read off it, under the lock, by
        /// `killTheRunningProcessGroupImmediately()`.
        private let killHandleLock = NSLock()
        private var terminalForImmediateKill: GuideAutopilotPseudoTerminal?
        private var buffer = GuideAutopilotOutputBuffer()
        private var workingDirectory: String
        private var searchPath: String?
        private var shellHasExited = false
        private var markerToken: String?
        private var finishRunning: ((GuideAutopilotCommandOutcome) -> Void)?
        private var lastOutputAt = Date.distantPast
        private var cancellationWasRequested = false
        private var alreadyDeliveredLineCount = 0
        private var commandGeneration = 0
        /// Guards against the preamble being sent twice (start plus a rebuild).
        private var preambleHasBeenSent = false
        private var pendingReadyToken: String?
        /// True from shell spawn until the ready marker lands. The preamble
        /// (the PAGER/GIT_PAGER/LESS/GIT_TERMINAL_PROMPT exports, the `cd`, and
        /// the ready `printf`) echoes back on a `-i` pty before `unsetopt zle`
        /// has fully silenced echo, so that setup noise reaches the wire and,
        /// left alone, lands in the terminal as a garbled first line
        /// (`export PAGER=cat …cd '/Users/…'printf '\n`). None of it is the
        /// reader's business, so on-screen delivery is held until the shell
        /// reports ready. The model tail and the marker scan are unaffected.
        private var displayIsSuppressedUntilShellIsReady = true
        /// A raw copy of recent output for marker detection only, with \r
        /// deleted (not collapsed as the display buffer does for progress
        /// bars) so the sentinel survives even when the shell's canonical
        /// echo or a wrap sprinkles carriage returns through the line. Reset
        /// before every command; bounded so it cannot grow without limit.
        private var markerScanText = ""

        init(startingDirectory: String) {
            self.startingDirectory = startingDirectory
            self.workingDirectory = startingDirectory
        }

        // MARK: Public entry points (hop onto the queue)

        func enqueueStart(_ completion: @escaping @Sendable (Bool) -> Void) {
            queue.async { self.startShell(completion) }
        }

        func enqueueRun(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            queue.async { self.runCommand(command, deadline: deadline, completion) }
        }

        func enqueueCancel(_ completion: @escaping @Sendable () -> Void) {
            queue.async { self.cancelRunningCommand(completion) }
        }

        func enqueueEnd(_ completion: @escaping @Sendable () -> Void) {
            queue.async { self.endShell(completion) }
        }

        func snapshotWorkingDirectory() -> String {
            queue.sync { workingDirectory }
        }

        func snapshotSearchPath() -> String? {
            queue.sync { searchPath }
        }

        func snapshotModelTail() -> String {
            queue.sync { buffer.tailForTheModel() }
        }

        func snapshotDisplayLines() -> [String] {
            queue.sync { buffer.displayLines }
        }

        // MARK: Startup (on queue)

        private func startShell(_ completion: @escaping @Sendable (Bool) -> Void) {
            let terminal = GuideAutopilotPseudoTerminal()
            terminal.onOutput = { [weak self] bytes in
                // Already on the pty queue? No — the terminal has its own
                // queue; hop onto ours so all state stays confined here.
                self?.queue.async { self?.ingest(bytes) }
            }
            terminal.onProcessExit = { [weak self, weak terminal] _ in
                self?.queue.async { self?.noteShellExited(from: terminal) }
            }

            do {
                // A login + interactive shell. zsh treats any pty stdin as
                // interactive regardless of -i, so ZLE is unavoidable at
                // spawn; the preamble's first line disables it. -l sources
                // the login files and -i sources ~/.zshrc, so the PATH the
                // guides need (path_helper, brew, nvm, cargo) is all present.
                try terminal.spawn(
                    shellPath: GuideAutopilotShellSession.loginShellPath(),
                    arguments: ["-l", "-i"],
                    environment: GuideAutopilotShellSession.childEnvironment()
                )
            } catch {
                completion(false)
                return
            }
            self.terminal = terminal
            rememberTerminalForImmediateKill(terminal)
            shellHasExited = false
            preambleHasBeenSent = false
            displayIsSuppressedUntilShellIsReady = true
            buffer.removeAll()
            alreadyDeliveredLineCount = 0
            markerScanText = ""

            let readyToken = Self.freshToken()
            pendingReadyToken = readyToken
            markerToken = readyToken
            finishRunning = { outcome in
                if case .succeeded = outcome { completion(true) } else { completion(false) }
            }
            scheduleDeadline(seconds: GuideAutopilotShellSession.readyDeadline, forToken: readyToken)
            // Send the preamble immediately, before ZLE has fully seized the
            // tty: written this early it lands in the tty input buffer and
            // the shell consumes it as one batch, which is what lets
            // `unsetopt zle` on line 1 disable the editor before it can start
            // echoing per-keystroke. Waiting for the prompt to appear first —
            // the intuitive thing — is precisely what lets ZLE grab each
            // character and wedge the injection.
            sendPreamble()

            // Fail-open backstop. The ready marker rides the preamble, which is
            // written while a `-l -i` shell's ZLE can still mangle it; on some
            // shell setups that marker is missed entirely, and then the ready
            // completion never fires — `startSession` hangs and the terminal
            // stays blank forever with no recourse. If the marker has not landed
            // a few seconds after spawn, the shell has long since sourced its
            // dotfiles and settled, so proceed anyway: the first real command
            // (sent after this, cleanly) runs and its own marker gates it. The
            // 60s deadline/rebuild stays as a further backstop for a truly dead
            // shell, but it must never be the reader's first experience.
            queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                guard self.markerToken == readyToken, let readyCompletion = self.finishRunning else {
                    irisTrace("shell: fail-open SKIPPED (ready already resolved: markerToken match=\(self.markerToken == readyToken), finishRunning set=\(self.finishRunning != nil))")
                    return
                }
                irisTrace("shell: FAIL-OPEN fired — ready marker missed, proceeding anyway")
                self.displayIsSuppressedUntilShellIsReady = false
                self.finishRunning = nil
                self.markerToken = nil
                self.buffer.removeAll()
                self.alreadyDeliveredLineCount = 0
                readyCompletion(.succeeded(workingDirectory: self.workingDirectory))
            }
        }

        /// Sent only once the shell's own prompt has settled — never into a
        /// half-initialised ZLE, which is what wedged the injection when the
        /// preamble raced the shell awake.
        //
        // The critical first line disables ZLE, zsh's interactive line
        // editor: a `-i` shell drives ZLE, which echoes every keystroke,
        // wraps input in bracketed-paste markers, and redraws the prompt —
        // all of which mangle programmatic injection. `unsetopt zle` executes
        // under ZLE (its newline is Enter), turning it off; every line after
        // is read raw. We keep `-i` because it is what sources ~/.zshrc,
        // where version managers put the PATH the guides need.
        private func sendPreamble() {
            guard !preambleHasBeenSent, let token = pendingReadyToken, let terminal else { return }
            preambleHasBeenSent = true
            // Discard the prompt noise so the ready marker is found in clean
            // output, and the first real command starts from an empty buffer.
            buffer.removeAll()
            alreadyDeliveredLineCount = 0
            markerScanText = ""
            // ZLE and echo are already off — the generated ZDOTDIR/.zshrc
            // did that during shell startup, before any of this was read, so
            // there is no editor to race and plain \n terminators are read
            // cleanly. This preamble only tidies pager behaviour, moves to
            // the starting directory, and prints the ready marker (whose
            // third field, the real PATH, feeds tool-version lookups).
            terminal.write(
                "export PAGER=cat GIT_PAGER=cat LESS=-FRX GIT_TERMINAL_PROMPT=0\n"
                + "cd \(Self.shellQuoted(startingDirectory))\n"
                + "printf '\\n__IRIS_END_\(token)__ %d\\t%s\\t%s\\n' \"$?\" \"$PWD\" \"$PATH\"\n"
            )
            irisTrace("shell: preamble written, token=\(token)")
        }

        // MARK: Running (on queue)

        private func runCommand(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            irisTrace("shell: runCommand called, len=\(command.text.count), busy=\(self.finishRunning != nil), exited=\(self.shellHasExited)")
            guard let terminal, !shellHasExited else {
                irisTrace("shell: runCommand → sessionFailed (no terminal / exited)")
                completion(.sessionFailed)
                return
            }
            guard finishRunning == nil else {
                irisTrace("shell: runCommand → sessionFailed (finishRunning still set — prior run never completed)")
                completion(.sessionFailed)
                return
            }
            if GuideAutopilotCommandShape.looksSyntacticallyIncomplete(command.text) {
                // An unterminated construct would swallow the end marker and
                // wedge every later command; refuse to send it at all.
                irisTrace("shell: runCommand → refused (looks syntactically incomplete)")
                completion(.failed(exitStatus: 2, workingDirectory: workingDirectory))
                return
            }

            let token = Self.freshToken()
            markerToken = token
            cancellationWasRequested = false
            buffer.removeAll()
            alreadyDeliveredLineCount = 0
            markerScanText = ""
            lastOutputAt = Date()
            finishRunning = completion
            irisTrace("shell: runCommand WRITING command, token=\(token)")

            // ZLE is off by now, so plain \n line terminators are read
            // correctly by the shell, including the command's own internal
            // newlines.
            terminal.write(
                command.text
                + "\nprintf '\\n__IRIS_END_\(token)__ %d\\t%s\\n' \"$?\" \"$PWD\"\n"
            )
            scheduleDeadline(seconds: deadline, forToken: token)
            schedulePromptDetection(forToken: token)
        }

        // MARK: Ingestion and the marker (on queue)

        private func ingest(_ bytes: [UInt8]) {
            lastOutputAt = Date()
            buffer.append(bytes)
            // Marker scan runs off a raw, \r-stripped copy — the display
            // buffer's progress-bar collapse would eat the sentinel.
            let text = String(decoding: bytes, as: UTF8.self)
            markerScanText += text.replacingOccurrences(of: "\r", with: "")
            if markerScanText.count > 65_536 {
                markerScanText = String(markerScanText.suffix(32_768))
            }
            deliverDisplayLines()
            scanForMarker()
        }

        private func deliverDisplayLines() {
            let lines = buffer.displayLines
            deliverNewLines(lines, upTo: max(lines.count - 1, 0))
        }

        private func scanForMarker() {
            guard let token = markerToken else { return }
            // The token appears twice in the stream: once in the echoed
            // `printf` command that defines the marker (followed by the
            // literal `%d`) and once in that command's real output (followed
            // by the integer exit status). Scan every occurrence and accept
            // the one whose next character is a real status digit and whose
            // line has fully arrived — so the echo is never mistaken for the
            // result, and a half-arrived PATH field is never truncated.
            let markerNeedle = "__IRIS_END_\(token)__ "
            var searchStart = markerScanText.startIndex
            while let range = markerScanText.range(
                of: markerNeedle, range: searchStart..<markerScanText.endIndex
            ) {
                let afterMarker = markerScanText[range.upperBound...]
                if afterMarker.first.map({ $0.isNumber || $0 == "-" }) == true,
                   let newline = afterMarker.firstIndex(of: "\n") {
                    finishRun(withMarkerLine: String(afterMarker[..<newline]))
                    return
                }
                searchStart = range.upperBound
            }
        }

        private func deliverNewLines(_ lines: [String], upTo end: Int) {
            guard end > alreadyDeliveredLineCount else { return }
            // Before the shell is ready, every line is preamble setup noise the
            // reader must never see. Consume it (advance the cursor) but show
            // nothing; real command output only starts after the ready marker.
            if displayIsSuppressedUntilShellIsReady {
                alreadyDeliveredLineCount = end
                return
            }
            for line in lines[alreadyDeliveredLineCount..<end] {
                // The sentinel is machinery, never shown to the reader — but
                // the pty's newline translation can leave a short command's
                // output and its marker collapsed onto one display line, so
                // strip from the marker onward rather than dropping the line.
                let visible: Substring
                if let markerStart = line.range(of: "__IRIS_END_") {
                    visible = line[..<markerStart.lowerBound]
                } else {
                    visible = Substring(line)
                }
                if !visible.isEmpty {
                    deliverOutputLine?(String(visible))
                }
            }
            alreadyDeliveredLineCount = end
        }

        private func finishRun(withMarkerLine markerLine: String) {
            // Flush any output that arrived in the same burst as the marker —
            // a short command's whole output can land with its sentinel, and
            // deliverNewLines holds back the final line until then.
            let lines = buffer.displayLines
            deliverNewLines(lines, upTo: lines.count)
            markerToken = nil
            alreadyDeliveredLineCount = 0
            commandGeneration += 1
            let fields = markerLine.split(separator: "\t", maxSplits: 2)
            let exitStatus = fields.first.flatMap { Int32($0) } ?? -1
            irisTrace("shell: MARKER seen, fields=\(fields.count), exit=\(exitStatus), wasSuppressed=\(self.displayIsSuppressedUntilShellIsReady)")
            if fields.count > 1 {
                workingDirectory = String(fields[1])
            }
            if fields.count > 2 {
                // Only the ready marker carries a third field (PATH), used for
                // tool-version lookups.
                searchPath = String(fields[2])
            }
            if displayIsSuppressedUntilShellIsReady {
                // The FIRST completed marker is the preamble's "ready" marker:
                // the shell is up and the setup noise is done echoing. Clear
                // suppression here rather than only when a clean third (PATH)
                // field parses — on an unusual `-i` shell the marker can arrive
                // with the PATH field split or empty (Swift's `split` omits a
                // trailing empty field), and gating the clear on it stranded the
                // terminal permanently blank while every command ran unseen.
                displayIsSuppressedUntilShellIsReady = false
                buffer.removeAll()
                alreadyDeliveredLineCount = 0
            }

            let completion = finishRunning
            finishRunning = nil
            if cancellationWasRequested {
                completion?(.cancelled)
            } else if exitStatus == 0 {
                completion?(.succeeded(workingDirectory: workingDirectory))
            } else {
                completion?(.failed(exitStatus: exitStatus, workingDirectory: workingDirectory))
            }
        }

        private func noteShellExited(from exitedTerminal: GuideAutopilotPseudoTerminal?) {
            // A late exit from a terminal we have already replaced must not mark
            // the fresh shell dead. The escape hatch SIGKILLs the old terminal
            // off-queue and then rebuilds; that old terminal's process-exit can
            // land on the queue after the new shell is already running, and
            // without this guard it would set `shellHasExited` on the new one.
            guard exitedTerminal === terminal else { return }
            shellHasExited = true
            markerToken = nil
            commandGeneration += 1
            let completion = finishRunning
            finishRunning = nil
            completion?(.sessionFailed)
        }

        // MARK: Deadline, prompt detection, cancellation (on queue)

        private func scheduleDeadline(seconds: TimeInterval, forToken token: String) {
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.deadlineFired(forToken: token, escalation: 0)
            }
        }

        private func deadlineFired(forToken token: String, escalation: Int) {
            guard markerToken == token, finishRunning != nil else { return }
            switch escalation {
            case 0:
                terminal?.sendInterrupt()
            case 1:
                terminal?.sendEndOfInput()
            default:
                // A wedged shell must never strand the guide: kill the whole
                // group and rebuild at the last known cwd. The scrubbed tail
                // goes to the console because "the marker never came" is
                // undebuggable without knowing what the shell did say.
                print("🖥️ autopilot shell missed its deadline; scrubbed tail:\n\(buffer.tailForTheModel())\n[open line: \(buffer.unterminatedTail)]")
                let completion = finishRunning
                finishRunning = nil
                markerToken = nil
                rebuildShell()
                completion?(.timedOut)
                return
            }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.deadlineFired(forToken: token, escalation: escalation + 1)
            }
        }

        private func schedulePromptDetection(forToken token: String) {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.checkForInteractivePrompt(token: token)
            }
        }

        private func checkForInteractivePrompt(token: String) {
            guard markerToken == token, finishRunning != nil else { return }
            defer { schedulePromptDetection(forToken: token) }
            let tail = buffer.unterminatedTail
            let silentFor = Date().timeIntervalSince(lastOutputAt)
            guard silentFor >= GuideAutopilotShellSession.promptDetectionSilence,
                  !tail.isEmpty else { return }
            let promptShapes = [
                #"\(y/n\)\s*$"#, #"\[Y/n\]\s*$"#, #"\[y/N\]\s*$"#,
                #"password:\s*$"#, #"passphrase"#, #"Username:\s*$"#,
            ]
            let looksLikeAQuestion = promptShapes.contains {
                tail.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
            }
            guard looksLikeAQuestion, let completion = finishRunning else { return }
            // Leave the command running — the reader may answer in v2; v1
            // offers Cancel. The marker token stays live so a late answer
            // still ends the run normally.
            finishRunning = nil
            completion(.seemsToBeAskingAQuestion(tail: tail))
        }

        private func cancelRunningCommand(_ completion: @escaping @Sendable () -> Void) {
            // The escape hatch, and the reader wants out NOW. The process group
            // has usually already been SIGKILLed off-queue
            // (`killTheRunningProcessGroupImmediately`) to beat a flood of build
            // output that jams this queue; here we settle the bookkeeping and
            // hand back a FRESH shell so "Try again" has somewhere to run.
            //
            // There is deliberately no gentle Ctrl-C-and-wait path: a build that
            // ignores SIGINT (electron-builder does, mid-package) would sit
            // through it, which is exactly the wedge that left the reader unable
            // to stop the setup. Rebuilding drops this step's `cd`/env, but the
            // escape hatch has already handed the step back to the reader, so
            // there is nothing left in this shell to preserve.
            cancellationWasRequested = true
            let pending = finishRunning
            finishRunning = nil
            markerToken = nil
            // Belt-and-suspenders: kill the group here too in case a caller
            // reached cancel without the off-queue kill. `killProcessGroup` is a
            // no-op on an already-reaped pid.
            terminal?.killProcessGroup()
            pending?(.cancelled)
            // Only a session that actually had a shell needs a fresh one; the
            // long-running session may never have been started for this step.
            if terminal != nil {
                rebuildShell()
            }
            completion()
        }

        private func rebuildShell() {
            // A discarded terminal's exit callback must not fire into the
            // rebuilt session's state.
            terminal?.onOutput = nil
            terminal?.onProcessExit = nil
            terminal?.killProcessGroup()
            terminal = nil
            rememberTerminalForImmediateKill(nil)
            startShell { _ in }
        }

        /// Mirrors the live terminal into the lock-guarded handle the escape
        /// hatch reads off-queue. Always called on `queue`, wherever `terminal`
        /// is assigned or cleared.
        private func rememberTerminalForImmediateKill(_ terminal: GuideAutopilotPseudoTerminal?) {
            killHandleLock.lock()
            terminalForImmediateKill = terminal
            killHandleLock.unlock()
        }

        /// Off-queue: SIGKILL the running command's whole process group right
        /// now. Safe from any thread — it touches only the lock-guarded handle,
        /// and `killProcessGroup` guards a reaped pid. The queue-confined
        /// cleanup (resolve the pending command, rebuild the shell) still runs;
        /// this only makes the process die immediately instead of behind a
        /// flood of its own output.
        func killTheRunningProcessGroupImmediately() {
            killHandleLock.lock()
            let terminal = terminalForImmediateKill
            killHandleLock.unlock()
            terminal?.killProcessGroup()
        }

        private func endShell(_ completion: @escaping @Sendable () -> Void) {
            if let finish = finishRunning {
                finishRunning = nil
                markerToken = nil
                cancellationWasRequested = true
                terminal?.sendInterrupt()
                finish(.cancelled)
            }
            terminal?.onOutput = nil
            terminal?.onProcessExit = nil
            terminal?.write("exit\n")
            let terminalToClose = terminal
            terminal = nil
            rememberTerminalForImmediateKill(nil)
            shellHasExited = true
            queue.asyncAfter(deadline: .now() + 0.5) {
                terminalToClose?.killProcessGroup()
                completion()
            }
        }

        private static func freshToken() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        private static func shellQuoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    // MARK: - Environment

    nonisolated static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        for fallback in ["/bin/zsh", "/bin/bash"]
        where FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return "/bin/sh"
    }

    /// True when the login shell is zsh, which is the only shell the ZDOTDIR
    /// trick below applies to.
    nonisolated static func loginShellIsZsh() -> Bool {
        loginShellPath().hasSuffix("/zsh")
    }

    /// Creates a private ZDOTDIR whose `.zshrc` loads the user's real zsh
    /// setup (so PATH and version managers are present) and then disables
    /// ZLE, zsh's interactive line editor — the deterministic way to get an
    /// editor-free interactive shell, because it happens during startup
    /// before the shell reads a byte of injected input, with no race. Cached
    /// per process; returns nil if the directory cannot be created or the
    /// shell is not zsh. The system-wide /etc/z* files (path_helper) are
    /// unaffected by ZDOTDIR and still run; only the user's ~/.z* move here,
    /// which is why the generated rc sources the real ~/.zprofile and
    /// ~/.zshrc explicitly.
    nonisolated static func privateZdotdir() -> String? {
        guard loginShellIsZsh() else { return nil }
        return zdotdirOnce
    }

    private nonisolated static let zdotdirOnce: String? = {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-autopilot-zdotdir")
        let rc = """
        # Generated by Iris autopilot. Load the user's real zsh environment,
        # then turn off the interactive line editor so Iris can drive the
        # shell without ZLE echoing, redrawing, or bracketed-paste mangling.
        IRIS_USER_HOME="${IRIS_USER_HOME:-\(realHome)}"
        # .zshenv is in this list because ZDOTDIR redirects where zsh looks for
        # it, so the user's real one never runs on its own — and .zshenv is
        # exactly where rustup writes `. "$HOME/.cargo/env"`. Without it the
        # autopilot shell had no cargo, and every `tauri build` a guide asked
        # for failed in a shell while working in the reader's own Terminal.
        for _iris_rc in .zshenv .zprofile .zshrc; do
          [ -r "$IRIS_USER_HOME/$_iris_rc" ] && source "$IRIS_USER_HOME/$_iris_rc"
        done
        unset _iris_rc
        unsetopt zle 2>/dev/null
        unsetopt prompt_cr prompt_sp 2>/dev/null
        stty -echo 2>/dev/null
        PS1='' PS2='' PROMPT='' RPROMPT=''
        """
        do {
            try FileManager.default.createDirectory(
                atPath: base, withIntermediateDirectories: true
            )
            try rc.write(toFile: (base as NSString).appendingPathComponent(".zshrc"),
                         atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return base
    }()

    /// Built from scratch. PATH is deliberately absent — the login shell
    /// rebuilds it — and nothing of Iris's own environment leaks through.
    nonisolated static func childEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        var environment: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "SHELL": loginShellPath(),
            "TMPDIR": NSTemporaryDirectory(),
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "IRIS_AUTOPILOT": "1",
        ]
        if let zdotdir = privateZdotdir() {
            environment["ZDOTDIR"] = zdotdir
            environment["IRIS_USER_HOME"] = home
        }
        return environment
    }
}
