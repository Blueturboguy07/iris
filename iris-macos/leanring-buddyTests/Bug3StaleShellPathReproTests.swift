//
//  Bug3StaleShellPathReproTests.swift
//  leanring-buddyTests
//
//  Bug 3 — "Stale PATH after a mid-run tool install (relaunch required)".
//
//  THE FIELD SCENARIO, from Akrit's Test 9 logs (Iris 0.9.6 build 22), replayed
//  here step for step:
//
//    06:59:44  [51270] login-shell PATH captured with -l -i: 16 directories
//    06:59:45  drive: step[6] id=install-deps → `cd ~/kneecap` exit 0, then
//              `bun install` exit 127            (bun was not installed yet)
//    07:00:04  drive: install-deps result=skippedByReader
//              (the fix ladder's only offer was advice: "Install bun by running:
//               curl -fsSL https://bun.sh/install | bash" — Bug 7 — so the step
//               was surfaced to the reader with Try again / Continue past it)
//              …the reader installs bun in their own Terminal. bun's official
//              installer drops the binary in ~/.bun/bin and APPENDS an
//              `export PATH=…/.bun/bin:$PATH` line to ~/.zshrc.
//    07:00:07  Try again → `cd ~/kneecap` exit 0, `bun install` exit 127
//    07:00:21  Try again → `cd ~/kneecap` exit 0, `bun install` exit 127
//    07:02:33  the process ends
//    07:03:42  [51799] login-shell PATH captured with -l -i: 17 directories
//    07:04:03  the SAME install-deps step → exit 0
//    07:04:09  the SAME build-editor step → exit 0
//
//  So: the tool was installed, the reader's dotfiles were updated, and the only
//  thing that ever picked either of those up was quitting and relaunching Iris.
//  `GuideSessionController.retryTheSurfacedStep` re-enters the SAME
//  `GuideAutopilotRunner` and therefore the SAME `GuideAutopilotShellSession` —
//  one persistent `zsh -l -i` whose environment was built once, at spawn, when
//  its generated ZDOTDIR sourced the reader's real .zshenv/.zprofile/.zshrc
//  (`privateZdotdir`). Nothing on the retry path re-sources anything, rebuilds
//  the shell, or runs `hash -r`, so "Try again" can only ever re-ask a shell
//  that still has yesterday's PATH.
//
//  WHAT IS REAL HERE, and what is not:
//    - a real pty running the reader's real login shell (`zsh -l -i`) through
//      the app's own `GuideAutopilotPseudoTerminal`, driven with the app's own
//      generated ZDOTDIR (`GuideAutopilotShellSession.privateZdotdir()`) and the
//      app's own in-band sentinel protocol;
//    - a real temporary HOME with a real minimal `.zshrc`, a real git repo at
//      `~/kneecap` holding the kneecap workspace's own files, and a real
//      `~/.bun/bin/bun` executable created mid-run exactly the way bun's
//      installer creates it;
//    - the real `GuideSessionController`, the real drive loop, the real
//      `GuideAutopilotRunner`, the real risk gate, and the real
//      `retryTheSurfacedStep()` the "Try again" button calls;
//    - the real kneecap guide's own steps and commands, served over a stubbed
//      URLProtocol instead of publik.
//
//  The ONE thing that is not the shipped object is the shell class itself:
//  `GuideAutopilotShellSession` reads the reader's home from
//  `FileManager.default.homeDirectoryForCurrentUser` in two non-injectable
//  places (`privateZdotdir`'s cached rc and `childEnvironment`), so there is no
//  seam to point it at a scratch home — and a test must never append an
//  `export PATH=…` to the developer's own ~/.zshrc.
//  `PersistentLoginShellInATemporaryReaderHome` below is therefore a
//  line-for-line stand-in for that class's spawn + preamble + sentinel
//  protocol, differing ONLY in taking the home directory as a parameter. It
//  captures PATH exactly once, from the ready marker's third field, the same way
//  `GuideAutopilotShellSession.finishRun` does — that one-shot capture IS the
//  bug, so it is reproduced rather than papered over.
//
//  `onlyAFreshlyStartedShellSeesTheToolTheReaderJustInstalled` is the control:
//  it proves the fixture (the temp home, the dotfile append, the bun binary, the
//  16 → 17 directory growth) genuinely works, so the headline test's failure can
//  only be Iris's retry path and not a broken scratch machine.
//

import Foundation
import Testing
@testable import Iris

/// The same switch `GuideAutopilotShellSessionTests` uses: these spawn real
/// processes, so a box where that is unwelcome can opt out.
private let bug3PtyTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

// MARK: - A real persistent login shell, in a home directory the test owns

/// A stand-in for `GuideAutopilotShellSession` that takes the reader's home as
/// a parameter. Everything else is copied from it deliberately: the same
/// `zsh -l -i` through the same `GuideAutopilotPseudoTerminal`, the same
/// generated ZDOTDIR, the same PATH-less child environment, the same preamble
/// whose ready marker carries `$PATH` as its third field, and the same
/// once-only capture of that field into `searchPath`.
///
/// See the file header for why the shipped class cannot be used directly.
@MainActor
final class PersistentLoginShellInATemporaryReaderHome: GuideAutopilotShellSessionDriving {

    var onOutputLine: ((String) -> Void)?

    var currentWorkingDirectory: String { state.snapshotWorkingDirectory() }
    var resolvedSearchPath: String? { state.snapshotSearchPath() }

    /// Every command this shell was asked to run, with the exit status the real
    /// shell gave it. This is the test's window onto "the same command, in the
    /// same shell, three times" — the shape the field log has.
    private(set) var attempts: [(command: String, exitStatus: Int32)] = []

    /// How many shell processes were spawned for this session. The field bug is
    /// precisely that this stays at 1 across every "Try again".
    var numberOfShellProcessesSpawned: Int { state.snapshotSpawnCount() }

    private let state: State

    init(readerHome: String, startingDirectory: String) {
        state = State(readerHome: readerHome, startingDirectory: startingDirectory)
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
        deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        let outcome: GuideAutopilotCommandOutcome = await withCheckedContinuation { continuation in
            state.enqueueRun(command.text, deadline: deadline) { continuation.resume(returning: $0) }
        }
        switch outcome {
        case .succeeded:
            attempts.append((command: command.text, exitStatus: 0))
        case .failed(let exitStatus, _):
            attempts.append((command: command.text, exitStatus: exitStatus))
        default:
            // -1 stands for "the shell never gave a status" (timed out, died,
            // was cancelled) so a wedge is visibly different from a real 127.
            attempts.append((command: command.text, exitStatus: -1))
        }
        return outcome
    }

    func cancelTheRunningCommand() async {}

    func endSession() async {
        await withCheckedContinuation { continuation in
            state.enqueueEnd { continuation.resume() }
        }
    }

    func tailForTheModel() -> String { state.snapshotTail() }

    /// Exit statuses for one command's text, in the order they happened.
    func exitStatuses(of commandText: String) -> [Int32] {
        attempts.filter { $0.command == commandText }.map(\.exitStatus)
    }

    // MARK: The queue-confined core (mirrors `GuideAutopilotShellSession.SessionState`)

    private final class State: @unchecked Sendable {

        var deliverOutputLine: ((String) -> Void)?

        private let queue = DispatchQueue(label: "iris.bug3.repro.shell-session")
        private let readerHome: String
        private let startingDirectory: String

        private var terminal: GuideAutopilotPseudoTerminal?
        private var workingDirectory: String
        private var searchPath: String?
        private var shellHasExited = false
        private var spawnCount = 0
        private var markerToken: String?
        private var finishRunning: ((GuideAutopilotCommandOutcome) -> Void)?
        private var markerScanText = ""
        private var lineBuffer = ""
        private var tail = ""
        private var displayIsSuppressedUntilShellIsReady = true

        init(readerHome: String, startingDirectory: String) {
            self.readerHome = readerHome
            self.startingDirectory = startingDirectory
            self.workingDirectory = startingDirectory
        }

        func enqueueStart(_ completion: @escaping @Sendable (Bool) -> Void) {
            queue.async { self.startShell(completion) }
        }

        func enqueueRun(
            _ commandText: String,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            queue.async { self.runCommand(commandText, deadline: deadline, completion) }
        }

        func enqueueEnd(_ completion: @escaping @Sendable () -> Void) {
            queue.async { self.endShell(completion) }
        }

        func snapshotWorkingDirectory() -> String { queue.sync { workingDirectory } }
        func snapshotSearchPath() -> String? { queue.sync { searchPath } }
        func snapshotSpawnCount() -> Int { queue.sync { spawnCount } }
        func snapshotTail() -> String { queue.sync { String(tail.suffix(4_000)) } }

        private func startShell(_ completion: @escaping @Sendable (Bool) -> Void) {
            let terminal = GuideAutopilotPseudoTerminal()
            terminal.onOutput = { [weak self] bytes in
                self?.queue.async { self?.ingest(bytes) }
            }
            terminal.onProcessExit = { [weak self] _ in
                self?.queue.async { self?.noteShellExited() }
            }

            // The shipped `childEnvironment()`, with the home directory taken
            // from the caller instead of `FileManager.default`. PATH is
            // deliberately absent so the login shell rebuilds it through
            // path_helper and the (temporary) reader's own dotfiles — which is
            // exactly the mechanism this bug lives in.
            let user = NSUserName()
            var environment: [String: String] = [
                "HOME": readerHome,
                "USER": user,
                "LOGNAME": user,
                "SHELL": GuideAutopilotShellSession.loginShellPath(),
                "TMPDIR": NSTemporaryDirectory(),
                "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8",
                "IRIS_AUTOPILOT": "1",
            ]
            if let zdotdir = GuideAutopilotShellSession.privateZdotdir() {
                environment["ZDOTDIR"] = zdotdir
                // The generated rc reads this with `${IRIS_USER_HOME:-<real home>}`,
                // so pointing it at the scratch home is what keeps this test off
                // the developer's own dotfiles.
                environment["IRIS_USER_HOME"] = readerHome
            }

            do {
                try terminal.spawn(
                    shellPath: GuideAutopilotShellSession.loginShellPath(),
                    arguments: ["-l", "-i"],
                    environment: environment
                )
            } catch {
                completion(false)
                return
            }
            self.terminal = terminal
            spawnCount += 1
            shellHasExited = false
            displayIsSuppressedUntilShellIsReady = true
            markerScanText = ""
            lineBuffer = ""

            let readyToken = Self.freshToken()
            markerToken = readyToken
            finishRunning = { outcome in
                if case .succeeded = outcome { completion(true) } else { completion(false) }
            }
            scheduleDeadline(seconds: 60, forToken: readyToken)
            // The shipped preamble, verbatim: the third `%s` is `$PATH`, and it
            // is the ONLY time this session ever learns what PATH is.
            terminal.write(
                "export PAGER=cat GIT_PAGER=cat LESS=-FRX GIT_TERMINAL_PROMPT=0\n"
                + "cd \(Self.shellQuoted(startingDirectory))\n"
                + "printf '\\n__IRIS_END_\(readyToken)__ %d\\t%s\\t%s\\n' \"$?\" \"$PWD\" \"$PATH\"\n"
            )
        }

        private func runCommand(
            _ commandText: String,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            guard let terminal, !shellHasExited else {
                completion(.sessionFailed)
                return
            }
            guard finishRunning == nil else {
                completion(.sessionFailed)
                return
            }
            let token = Self.freshToken()
            markerToken = token
            markerScanText = ""
            lineBuffer = ""
            finishRunning = completion
            terminal.write(
                commandText
                + "\nprintf '\\n__IRIS_END_\(token)__ %d\\t%s\\n' \"$?\" \"$PWD\"\n"
            )
            // Capped well below the shipped 900s command deadline: a test that
            // wedges must FAIL, not sit there for a quarter of an hour.
            scheduleDeadline(seconds: min(deadline, 90), forToken: token)
        }

        private func ingest(_ bytes: [UInt8]) {
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            markerScanText += text
            if markerScanText.count > 65_536 {
                markerScanText = String(markerScanText.suffix(32_768))
            }
            lineBuffer += text
            while let newline = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<newline])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                guard !displayIsSuppressedUntilShellIsReady else { continue }
                let visible: String
                if let markerStart = line.range(of: "__IRIS_END_") {
                    visible = String(line[..<markerStart.lowerBound])
                } else {
                    visible = line
                }
                guard !visible.isEmpty else { continue }
                tail += visible + "\n"
                if tail.count > 16_384 { tail = String(tail.suffix(8_192)) }
                deliverOutputLine?(visible)
            }
            scanForMarker()
        }

        /// The shipped scan: the token appears in the echoed `printf` too, so
        /// only an occurrence followed by a real status digit on a line that has
        /// fully arrived counts.
        private func scanForMarker() {
            guard let token = markerToken else { return }
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

        private func finishRun(withMarkerLine markerLine: String) {
            markerToken = nil
            let fields = markerLine.split(separator: "\t", maxSplits: 2)
            let exitStatus = fields.first.flatMap { Int32($0) } ?? -1
            if fields.count > 1 { workingDirectory = String(fields[1]) }
            if fields.count > 2 {
                // Only the ready marker carries PATH. Captured here, once, and
                // never refreshed — the defect this file reproduces.
                searchPath = String(fields[2])
            }
            if displayIsSuppressedUntilShellIsReady {
                displayIsSuppressedUntilShellIsReady = false
                lineBuffer = ""
            }
            let completion = finishRunning
            finishRunning = nil
            if exitStatus == 0 {
                completion?(.succeeded(workingDirectory: workingDirectory))
            } else {
                completion?(.failed(exitStatus: exitStatus, workingDirectory: workingDirectory))
            }
        }

        private func noteShellExited() {
            shellHasExited = true
            markerToken = nil
            let completion = finishRunning
            finishRunning = nil
            completion?(.sessionFailed)
        }

        private func scheduleDeadline(seconds: TimeInterval, forToken token: String) {
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.markerToken == token, let completion = self.finishRunning else {
                    return
                }
                self.finishRunning = nil
                self.markerToken = nil
                completion(.timedOut)
            }
        }

        private func endShell(_ completion: @escaping @Sendable () -> Void) {
            if let finish = finishRunning {
                finishRunning = nil
                markerToken = nil
                finish(.cancelled)
            }
            terminal?.onOutput = nil
            terminal?.onProcessExit = nil
            terminal?.write("exit\n")
            let terminalToClose = terminal
            terminal = nil
            shellHasExited = true
            queue.asyncAfter(deadline: .now() + 0.3) {
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
}

// MARK: - The reader's Mac, in a temporary home

/// Builds the machine Akrit's Test 9 ran on, in a scratch directory: a home with
/// a minimal `.zshrc`, a real git checkout of the kneecap workspace at
/// `~/kneecap`, and — on demand, part-way through a run — a real bun installed
/// the way bun's official installer installs it.
enum Bug3ReaderMacFixture {

    /// A temporary HOME containing `.zshrc` and a real `~/kneecap` git repo.
    static func makeTemporaryReaderMac() throws -> String {
        let home = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug3-reader-\(UUID().uuidString)")
        let checkout = (home as NSString).appendingPathComponent("kneecap")
        let mobile = (checkout as NSString).appendingPathComponent("apps/mobile")
        try FileManager.default.createDirectory(
            atPath: mobile, withIntermediateDirectories: true
        )

        // The reader's shell BEFORE bun: nothing but what the system gives it.
        try """
        # The reader's own zsh setup, before they installed anything.
        export IRIS_BUG3_READER_SHELL=1
        """.write(
            toFile: (home as NSString).appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        // kneecap's own workspace shape, so `bun install` and
        // `cd apps/mobile && bun run build` are real commands about real files.
        try #"{"name":"kneecap","private":true,"workspaces":["apps/*"]}"#.write(
            toFile: (checkout as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        try #"{"name":"@kneecap/mobile","scripts":{"build":"vite build"}}"#.write(
            toFile: (mobile as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )

        // A REAL git repo, because the field checkout was one and the guide's
        // steps run inside it.
        let gitEnvironment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        runProcess("/usr/bin/git", ["init", "-q"], inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["config", "user.email", "reader@example.invalid"],
                   inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["config", "user.name", "Reader"],
                   inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["add", "-A"], inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["commit", "-q", "-m", "kneecap"],
                   inDirectory: checkout, environment: gitEnvironment)
        return home
    }

    /// What the reader did in their own Terminal at ~07:00 while Iris sat on the
    /// surfaced step: `curl -fsSL https://bun.sh/install | bash`. The installer
    /// drops the binary in `~/.bun/bin` and appends the export block below to
    /// `~/.zshrc` — which is why a NEW shell finds bun and a running one cannot.
    static func installBunTheWayItsOfficialInstallerDoes(inHome home: String) throws {
        let binDirectory = (home as NSString).appendingPathComponent(".bun/bin")
        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true
        )
        let bunPath = (binDirectory as NSString).appendingPathComponent("bun")
        // Stands in for bun 1.4.0 — the version the field Mac ended up with.
        // `install` writes bun.lock into the checkout, which is exactly the one
        // file Test 9 found dirty, "timestamped the same second install-deps
        // succeeded".
        try """
        #!/bin/sh
        case "$1" in
          --version|-v) echo "1.4.0" ;;
          install)
            echo "bun install v1.4.0"
            : > bun.lock
            echo "12 packages installed [8.00ms]"
            ;;
          run)
            echo "vite v5.4.0 building for production..."
            echo "built in 1.20s"
            ;;
          *)
            echo "bun: unknown command: $1" >&2
            exit 1
            ;;
        esac
        exit 0
        """.write(toFile: bunPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bunPath
        )

        let zshrcPath = (home as NSString).appendingPathComponent(".zshrc")
        let existing = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        try (existing + """


        # bun
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        """).write(toFile: zshrcPath, atomically: true, encoding: .utf8)
    }

    private static func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        inDirectory directory: String,
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - The kneecap guide, served the way publik serves it

/// Answers `GET /api/iris/guides/kneecap` with the real published kneecap
/// guide's Mac + iPhone branch, truncated after `build-editor`.
///
/// Truncated on purpose: the next step (`install-xcode`) is an `open` step whose
/// href is an App Store link, and the drive loop opens a manual step's link with
/// `NSWorkspace`. A test must not launch the App Store on the machine running
/// it. Every step the Test 9 evidence exercises — `install-deps` and
/// `build-editor` — is here verbatim, including their working directories.
final class Bug3KneecapGuideURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.kneecapGuideJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The `build-editor` step's `watch` block is the one thing dropped from the
    /// published guide: its expectation is a `visual` prompt, which would put the
    /// watch loop on the screen-capture-and-ask-a-model path inside a test host
    /// that has neither. Nothing in this bug depends on it.
    static let kneecapGuideJSON = """
    {
      "appSlug": "kneecap",
      "appName": "kneecap",
      "version": 2,
      "status": "pilot",
      "sourceOwner": "Blueturboguy07",
      "sourceRepo": "kneecap",
      "sourceCommit": "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
      "outputType": "mobile_app",
      "estimatedMinutes": 40,
      "readmeSectionIds": ["build"],
      "branches": [
        {
          "platform": "macos",
          "target": "ios",
          "label": "Mac + iPhone",
          "shell": "terminal",
          "setupSteps": [
            {"id": "install-git", "kind": "terminal", "tool": "git", "title": "Install Git",
             "body": "Apple opens a small installer.", "command": "xcode-select --install",
             "verifierLabel": "Git responds with a version number"},
            {"id": "install-node", "kind": "open", "tool": "node", "title": "Install Node LTS",
             "body": "Choose the macOS Installer (.pkg).",
             "href": "https://nodejs.org/en/download", "actionLabel": "Open download",
             "verifierLabel": "Node responds with a version number"}
          ],
          "steps": [
            {"id": "open-shell", "kind": "terminal", "title": "Open Terminal",
             "body": "Keep it open beside Iris.", "verifierLabel": "Terminal is open"},
            {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
             "body": "Git and the current Node LTS are required.",
             "command": "git --version\\nnode --version",
             "verifierLabel": "Git and Node respond with version numbers"},
            {"id": "install-bun", "kind": "terminal", "title": "Install Bun",
             "body": "kneecap's workspace is built with Bun. This installs it through npm.",
             "command": "npm install -g bun",
             "verifierLabel": "Bun responds with a version number"},
            {"id": "clone", "workingDirectory": "~", "kind": "terminal",
             "title": "Copy kneecap to this Mac", "body": "",
             "command": "cd ~\\nif [ ! -d kneecap/.git ]; then\\ngit clone https://github.com/Blueturboguy07/kneecap.git\\nfi",
             "verifierLabel": "A kneecap folder appears"},
            {"id": "enter-folder", "workingDirectory": "~", "kind": "terminal",
             "title": "Open the kneecap folder", "body": "", "command": "cd kneecap",
             "verifierLabel": "Your terminal prompt is inside the kneecap folder"},
            {"id": "pin-source", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Use the reviewed version", "body": "",
             "command": "git checkout fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
             "verifierLabel": "Git reports the reviewed commit"},
            {"id": "install-deps", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Install the workspace",
             "body": "A few minutes the first time.", "command": "bun install",
             "verifierLabel": "The command finishes without an error"},
            {"id": "build-editor", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Build the editor",
             "body": "Bundles the editor into apps/mobile/www.",
             "command": "cd apps/mobile\\nbun run build",
             "verifierLabel": "Vite reports the build finished"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

// MARK: - The fix ladder's field behaviour

/// What the ladder actually did in Test 9: it diagnosed the missing tool and
/// handed the reader an instruction to run themselves ("Your turn"), which is
/// what surfaces the step with Try again / Continue past it. Modelled rather
/// than called for real so this test spends nothing and asks no model.
@MainActor
final class Bug3LadderThatOnlyGivesBunAdvice: GuideAutopilotFixProposing {

    private(set) var timesAsked = 0

    private static let advice = GuideAutopilotProposedFix(
        diagnosis: "bun isn't installed, so the workspace install can't run.",
        confidence: "high",
        action: .askTheReaderToDoSomething(
            instruction: "Install bun by running: curl -fsSL https://bun.sh/install | bash"
        ),
        retryTheOriginalCommandAfterwards: false,
        cameFromWebSearch: false
    )

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        timesAsked += 1
        return Self.advice
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        timesAsked += 1
        return Self.advice
    }
}

/// The runner's second session, for dev-server steps. Nothing in this guide
/// holds the shell open, so it is only ever asked to shut down.
@MainActor
final class Bug3UnusedLongRunningShell: GuideAutopilotShellSessionDriving {
    var onOutputLine: ((String) -> Void)?
    var currentWorkingDirectory = "/"
    var resolvedSearchPath: String?
    func start() async -> Bool { true }
    func run(
        _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        .succeeded(workingDirectory: currentWorkingDirectory)
    }
    func cancelTheRunningCommand() async {}
    func endSession() async {}
    func tailForTheModel() -> String { "" }
}

// MARK: - The tests

@MainActor
@Suite(.enabled(if: bug3PtyTestsAreEnabled), .serialized)
struct Bug3StaleShellPathReproTests {

    private static func guideServiceServingTheKneecapGuide() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Bug3KneecapGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug3.repro.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    /// Polls a main-actor condition. The drive loop runs in a `Task` it does not
    /// hand back, so a test observes its effects.
    private func pump(
        within seconds: Double = 60,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func approved(_ command: String) throws -> GuideAutopilotApprovedCommand {
        try #require(GuideAutopilotRiskAssessment.approve(command))
    }

    // MARK: The bug

    /// Test 9, replayed: install-deps fails 127 because bun is missing, the
    /// reader installs bun (binary in ~/.bun/bin, export appended to ~/.zshrc)
    /// while the step sits surfaced, and then taps "Try again" — twice.
    ///
    /// On the unfixed code every retry re-runs `bun install` in the SAME shell
    /// process, whose PATH was captured once at spawn, so it exits 127 again and
    /// the install never moves. That is the whole reported defect: the reader had
    /// to quit and relaunch Iris.
    @Test func tryAgainAfterAMidRunToolInstallStillCannotFindTheTool() async throws {
        let readerHome = try Bug3ReaderMacFixture.makeTemporaryReaderMac()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        // The ZDOTDIR trick — and therefore this whole reproduction — only
        // applies when the login shell is zsh, as it is on every shipped Mac.
        try #require(
            GuideAutopilotShellSession.privateZdotdir() != nil,
            "this reproduction needs the zsh login shell the autopilot drives"
        )

        let shell = PersistentLoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        let ladder = Bug3LadderThatOnlyGivesBunAdvice()
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheKneecapGuide(),
            // Git and Node were both present on the reader's Mac, so the setup
            // detour never fires; bun is the one thing missing, and the shell
            // itself is what discovers that.
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: Bug3UnusedLongRunningShell(),
                    fixProposer: ladder,
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // The reader's "Let Iris take control of your Mac?" grant, over a suite of
        // this test's own so the developer's real preference is untouched.
        controller.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug3.grant.\(UUID().uuidString)")
            )
        )
        controller.confirmAutonomousControl = { true }

        // Test 9 resumed the guide at step 6 — install-deps.
        await controller.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:ios", stepIndexFromDeepLink: 6
        )
        try #require(controller.selectedBranch != nil, "the kneecap guide must open")
        try #require(controller.currentStepIndex == 6, "the run resumes on install-deps")

        controller.startAutopilot()

        // 06:59:45 — `cd ~/kneecap` then `bun install`, which the real shell
        // cannot find because bun is not installed yet.
        let surfaced = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        #expect(surfaced, "the failing step must surface with Try again / Continue past it")
        #expect(
            shell.exitStatuses(of: "bun install") == [127],
            """
            the first attempt must be the field's exit 127 — got \
            \(shell.exitStatuses(of: "bun install")); terminal tail: \
            \(shell.tailForTheModel())
            """
        )
        #expect(ladder.timesAsked > 0, "the fix ladder ran and could only give advice")

        // ~07:00 — the reader does what they were told, in their own Terminal.
        try Bug3ReaderMacFixture.installBunTheWayItsOfficialInstallerDoes(inHome: readerHome)
        try #require(
            FileManager.default.isExecutableFile(
                atPath: (readerHome as NSString).appendingPathComponent(".bun/bin/bun")
            ),
            "bun really is installed on this machine now"
        )

        // 07:00:07 — "Try again".
        controller.retryTheSurfacedStep()
        _ = await pump { shell.exitStatuses(of: "bun install").count >= 2 }
        try #require(
            shell.exitStatuses(of: "bun install").count >= 2,
            "Try again must actually re-run the step's command"
        )
        // The invariant the fix must keep: one shell for the whole install, so
        // later steps still see earlier steps' `cd` and env. Finding the tool
        // by quietly spawning a second shell would pass the assertion below
        // for the wrong reason.
        #expect(
            shell.numberOfShellProcessesSpawned == 1,
            "Try again must reuse the guide's one persistent shell, not spawn another"
        )
        #expect(
            shell.exitStatuses(of: "bun install")[1] == 0,
            """
            THE BUG: bun is installed and on the reader's PATH, but "Try again" \
            re-ran `bun install` in the same shell process — spawned \
            \(shell.numberOfShellProcessesSpawned) time(s), PATH captured once at \
            spawn — so it exited \(shell.exitStatuses(of: "bun install")[1]) again. \
            That shell still searches: \(shell.resolvedSearchPath ?? "nothing")
            """
        )

        // 07:00:21 — the reader tries a second time, exactly as in the log.
        if controller.autopilotHandedTheCurrentStepToTheReader {
            controller.retryTheSurfacedStep()
            _ = await pump { shell.exitStatuses(of: "bun install").count >= 3 }
            #expect(
                shell.exitStatuses(of: "bun install").last == 0,
                """
                THE BUG, twice: a second "Try again" is no different from the \
                first — \(shell.exitStatuses(of: "bun install")) — because nothing \
                on the retry path re-sources the reader's dotfiles, rebuilds the \
                shell, or clears its command hash.
                """
            )
        }

        // 07:04:03 — with the tool found, the install carries on by itself.
        _ = await pump(within: 20) { controller.currentStepIndex > 6 }
        #expect(
            controller.currentStepIndex > 6,
            """
            THE CONSEQUENCE: the install is stuck on step 6 (install-deps) with \
            everything it needs already on the machine. In the field the only \
            thing that ever moved it was quitting and relaunching Iris.
            """
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
        await shell.endSession()
    }

    // MARK: The control

    /// The same temporary Mac, driven at the shell level only, to prove the
    /// fixture is honest: the running shell keeps failing after bun is installed,
    /// and a shell started AFTERWARDS — the relaunched process 51799 — finds it
    /// immediately, with a PATH exactly one directory longer (the field's
    /// "16 directories" → "17 directories").
    ///
    /// This test passes on the unfixed code. It exists so that a failure in
    /// `tryAgainAfterAMidRunToolInstallStillCannotFindTheTool` can only mean Iris
    /// never refreshed the shell, and never means the scratch machine, the
    /// dotfile append, or the bun stand-in was broken.
    @Test func onlyAFreshlyStartedShellSeesTheToolTheReaderJustInstalled() async throws {
        let readerHome = try Bug3ReaderMacFixture.makeTemporaryReaderMac()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        try #require(GuideAutopilotShellSession.privateZdotdir() != nil)

        // Process 51270.
        let firstProcessShell = PersistentLoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        try #require(await firstProcessShell.start(), "the login shell must come up")
        _ = await firstProcessShell.run(try approved("cd ~/kneecap"), deadline: 30)

        let beforeTheInstall = await firstProcessShell.run(
            try approved("bun install"), deadline: 60
        )
        #expect(
            beforeTheInstall == .failed(
                exitStatus: 127,
                workingDirectory: firstProcessShell.currentWorkingDirectory
            ),
            "bun is missing, so the real shell answers 127: got \(beforeTheInstall)"
        )
        let pathTheFirstProcessCaptured = try #require(firstProcessShell.resolvedSearchPath)

        try Bug3ReaderMacFixture.installBunTheWayItsOfficialInstallerDoes(inHome: readerHome)

        let afterTheInstallSameShell = await firstProcessShell.run(
            try approved("bun install"), deadline: 60
        )
        #expect(
            afterTheInstallSameShell == .failed(
                exitStatus: 127,
                workingDirectory: firstProcessShell.currentWorkingDirectory
            ),
            """
            a shell that has already sourced the dotfiles cannot see a PATH line \
            appended to them afterwards — this is the zsh-level fact the app's \
            "Try again" is built on top of: got \(afterTheInstallSameShell)
            """
        )
        await firstProcessShell.endSession()

        // Process 51799 — the relaunch, 18 seconds later.
        let relaunchedShell = PersistentLoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        try #require(await relaunchedShell.start(), "the relaunched login shell must come up")
        _ = await relaunchedShell.run(try approved("cd ~/kneecap"), deadline: 30)
        let afterTheRelaunch = await relaunchedShell.run(
            try approved("bun install"), deadline: 60
        )
        #expect(
            afterTheRelaunch == .succeeded(
                workingDirectory: relaunchedShell.currentWorkingDirectory
            ),
            "a freshly spawned shell finds bun at once: got \(afterTheRelaunch)"
        )

        let pathTheRelaunchCaptured = try #require(relaunchedShell.resolvedSearchPath)
        #expect(
            pathTheRelaunchCaptured.contains("/.bun/bin"),
            "the relaunched shell's PATH carries the directory bun's installer added"
        )
        #expect(
            pathTheRelaunchCaptured.split(separator: ":").count
                == pathTheFirstProcessCaptured.split(separator: ":").count + 1,
            """
            exactly one directory longer, the field's 16 → 17: \
            \(pathTheFirstProcessCaptured.split(separator: ":").count) → \
            \(pathTheRelaunchCaptured.split(separator: ":").count)
            """
        )
        // And the install really ran: bun.lock, the one file Test 9 found dirty.
        #expect(FileManager.default.fileExists(
            atPath: (readerHome as NSString).appendingPathComponent("kneecap/bun.lock")
        ))

        await relaunchedShell.endSession()
    }
}
