//
//  guide-rehearsal
//
//  Walks one install guide the way a reader does — real Terminal window, real
//  commands, real screenshots — and asks the model the *same* question the
//  watch loop asks, about each frame.
//
//  Compiled together with `leanring-buddy/WatchVisualCheck.swift`, so the
//  prompt and the verdict parsing are the app's own and cannot drift.
//
//  THE POINT OF THIS TOOL is the before-frame. Every expectation is evaluated
//  twice: once before its command has run, once after. An expectation that
//  answers "done" to the before-frame is worse than no expectation at all —
//  it skips the reader past work they have not done — and no happy-path test
//  can see that failure.
//
//  Run it from a Terminal that already holds Screen Recording, since a child
//  process inherits its parent's TCC grants.
//

import AppKit
import Foundation

// MARK: - The guide, as the app fetches it

struct RehearsalStep: Decodable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let command: String?
    let watch: RehearsalWatch?
}

struct RehearsalWatch: Decodable {
    let expect: [RehearsalExpectation]
    let sensitive: Bool?
    let hints: [String]?
}

struct RehearsalExpectation: Decodable {
    let type: String
    let prompt: String?
    let bundleId: String?
    let tool: String?
    let host: String?
    let roleLabel: String?
}

struct RehearsalBranch: Decodable {
    let platform: String
    let target: String?
    let shell: String
    let setupSteps: [RehearsalStep]
    let steps: [RehearsalStep]
}

struct RehearsalGuide: Decodable {
    let appSlug: String
    let appName: String
    let version: Int
    let branches: [RehearsalBranch]
}

// MARK: - Outcomes

enum RehearsalOutcome {
    case verified                       // notYet before, completed after
    case firesEarly(String)             // said done before the work happened
    case neverFires(String)             // still not done after the work
    case instantPass                    // a local signal already true before — a finding, not a bug
    case notRehearsed(String)
    case harnessCouldNotAsk(String)

    var symbol: String {
        switch self {
        case .verified: return "PASS"
        case .firesEarly: return "FIRES-EARLY"
        case .neverFires: return "NEVER-FIRES"
        case .instantPass: return "INSTANT-PASS"
        case .notRehearsed: return "skipped"
        case .harnessCouldNotAsk: return "HARNESS-GAP"
        }
    }
}

struct RehearsalResult {
    let stepId: String
    let expectation: String
    let beforeVerdict: String
    let afterVerdict: String
    let outcome: RehearsalOutcome
}

// MARK: - Driving a real Terminal

/// A real Terminal.app window, because a `visual` expectation is judged against
/// a *picture of a terminal*. Piping stdout would test a string the app never
/// looks at: no wrapping, no prompt, no scrollback, no window chrome.
enum TerminalDriver {
    static func run(_ appleScript: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Opens the window the whole rehearsal happens in, and points HOME at the
    /// scratch directory before anything else runs. `cd ~` and `git clone` then
    /// behave exactly as written on a fresh machine, and nothing touches the
    /// operator's real home — which matters here because ~/cue already exists
    /// with uncommitted work on it.
    static func openWindow(scratchHome: String) throws -> String {
        let identifier = try run("""
        tell application "Terminal"
            activate
            set w to do script "export HOME=\(scratchHome); cd ~; clear; echo rehearsal-ready"
            return id of window 1
        end tell
        """)
        return identifier
    }

    static func isBusy(windowId: String) throws -> Bool {
        let answer = try run("""
        tell application "Terminal" to return busy of window id \(windowId)
        """)
        return answer == "true"
    }

    /// Types a command into the window and waits for the prompt to come back.
    static func runCommand(_ command: String, windowId: String, timeoutSeconds: Double) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "; ")
        _ = try run("""
        tell application "Terminal" to do script "\(escaped)" in window id \(windowId)
        """)

        // `busy` flips a beat after the script is dispatched; give it that beat
        // before believing an idle reading.
        Thread.sleep(forTimeInterval: 1.5)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try !isBusy(windowId: windowId) { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        FileHandle.standardError.write(Data("  ! command still running after \(Int(timeoutSeconds))s, capturing anyway\n".utf8))
    }
}

// MARK: - Capturing what is on screen

enum ScreenCapture {
    /// The whole screen, as JPEG. The watch loop captures displays rather than
    /// windows, so this matches what the model would really be handed.
    /// Bring the rehearsal's own window to the front before capturing.
    ///
    /// Without this the frame is whatever happened to be on the operator's
    /// screen — on the machine this was written on, six unrelated terminal
    /// windows from other work. Asking "in the terminal, has npm finished"
    /// against six terminals is not a hard question, it is an ambiguous one,
    /// and the answers were correspondingly random: the same step passed,
    /// fired early and never fired across three consecutive runs.
    ///
    /// A reader following an install guide has the terminal they are typing
    /// into in front of them. This makes the frame match that, and it is the
    /// difference between measuring the guide and measuring the operator's
    /// desktop clutter.
    static func raise(windowId: String) {
        _ = try? TerminalDriver.run("""
        tell application "Terminal"
            activate
            set frontmost of window id \(windowId) to true
        end tell
        """)
        Thread.sleep(forTimeInterval: 1.2)
    }

    static func captureScreen(to url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "jpg", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RehearsalError.captureFailed
        }
        return try Data(contentsOf: url)
    }
}

enum RehearsalError: Error { case captureFailed, noKey, guideUnavailable }

// MARK: - Asking the model the app's own question

struct VisualEvaluator {
    let apiKey: String
    private(set) var callsMade = 0
    let callBudget: Int

    mutating func evaluate(
        screenshot: Data,
        stepTitle: String,
        visualPrompt: String,
        hints: [String]
    ) -> (verdict: WatchVerdict?, raw: String) {
        guard callsMade < callBudget else { return (nil, "budget exhausted") }
        callsMade += 1

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 256,
            "system": WatchVisualCheck.systemPrompt(hintsTheStepAuthorWrote: hints),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshot.base64EncodedString()]],
                    ["type": "text", "text": WatchVisualCheck.userPrompt(stepTitle: stepTitle, visualPrompt: visualPrompt)],
                ],
            ]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let semaphore = DispatchSemaphore(value: 0)
        var answer = ""
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { answer = "transport error: \(error.localizedDescription)"; return }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { answer = "unreadable response"; return }
            if let content = json["content"] as? [[String: Any]] {
                answer = content.compactMap { $0["text"] as? String }.joined()
            } else if let failure = json["error"] as? [String: Any] {
                answer = "api error: \(failure["message"] as? String ?? "unknown")"
            }
        }.resume()
        semaphore.wait()

        return (WatchVisualCheck.verdict(fromModelAnswer: answer, hintsTheStepAuthorWrote: hints), answer)
    }
}

// MARK: - Local expectations, evaluated the way the loop does

enum LocalSignals {
    static func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Deliberately mirrors `ToolVersionService`: PATH only, plus the two fixed
    /// fallbacks. Using `which` in a login shell would find tools the app
    /// itself cannot see, and reporting those as satisfied is the exact lie
    /// this harness exists to catch.
    static func toolIsVisibleToAGUIApp(_ tool: String) -> Bool {
        let fallbacks: [String: [String]] = [
            "git": ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"],
            "node": ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
        ]
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            if FileManager.default.isExecutableFile(atPath: "\(directory)/\(tool)") { return true }
        }
        return (fallbacks[tool] ?? []).contains { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
let slug = arguments.count > 1 ? arguments[1] : "cue"
let wantedPlatform = arguments.count > 2 ? arguments[2] : "macos"
let apiBase = ProcessInfo.processInfo.environment["PUBLIK_API_BASE"] ?? "https://publikhq.com"

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
    print("ANTHROPIC_API_KEY is not set. Source .env.local first — and do not echo it.")
    exit(1)
}

// Same endpoint Iris fetches, so the rehearsal reads exactly what ships.
guard
    let guideURL = URL(string: "\(apiBase)/api/iris/guides/\(slug)"),
    let guideData = try? Data(contentsOf: guideURL),
    let guide = try? JSONDecoder().decode(RehearsalGuide.self, from: guideData)
else {
    print("Could not fetch guide \(slug) from \(apiBase)")
    exit(1)
}

guard let branch = guide.branches.first(where: { $0.platform == wantedPlatform && $0.target == nil })
        ?? guide.branches.first(where: { $0.platform == wantedPlatform }) else {
    print("Guide \(slug) has no \(wantedPlatform) branch")
    exit(1)
}

let runDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("guide-rehearsal-\(slug)-\(Int(Date().timeIntervalSince1970))")
let scratchHome = runDirectory.appendingPathComponent("home")
try FileManager.default.createDirectory(at: scratchHome, withIntermediateDirectories: true)

print("Rehearsing \(guide.appName) v\(guide.version), branch \(branch.platform)")
print("Scratch HOME: \(scratchHome.path)")
print("Run directory: \(runDirectory.path)\n")

var evaluator = VisualEvaluator(apiKey: apiKey, callBudget: 60)
var results: [RehearsalResult] = []

// Keep the display awake for the whole rehearsal. `npm ci` and `npm run pack`
// take minutes with no keyboard input, and a sleeping display captures as a
// solid black frame — against which the model quite correctly answers NOT_YET
// to everything. Two runs were thrown away to learn this: the verdicts looked
// like guide bugs and were an unlit screen.
let keepAwake = Process()
keepAwake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
keepAwake.arguments = ["-d", "-i"]
try? keepAwake.run()
defer { keepAwake.terminate() }

let windowId = try TerminalDriver.openWindow(scratchHome: scratchHome.path)
Thread.sleep(forTimeInterval: 2)

// The two prerequisite steps open Apple's own installers. A reader who already
// has git and node skips them, and nothing should be automating a system
// installer dialog.
for (index, step) in branch.steps.enumerated() {
    print("[\(index + 1)/\(branch.steps.count)] \(step.title)")

    // A step with no watch block still has to RUN. Skipping its command was
    // this harness's own first bug: `cd cue` carries no expectation, so
    // `npm ci` then ran in an empty home and the model correctly reported the
    // install as unfinished. A harness that reports its own gap as a guide
    // failure is worse than no harness.
    let watch = step.watch
    let hasSomethingToEvaluate = !(watch?.expect.isEmpty ?? true)

    // Commands that take the shell and never give it back. `npm start` launches
    // Electron and holds the terminal until the app quits, so every later
    // command would be typed into a busy shell.
    let holdsTheShellOpen = (step.command?.contains("npm start") ?? false)
        || (step.command?.contains("npm run dev") ?? false)

    if holdsTheShellOpen {
        print("   not rehearsed: `\(step.command ?? "")` holds the shell until the app quits\n")
        if hasSomethingToEvaluate, let watch {
            for expectation in watch.expect {
                results.append(RehearsalResult(
                    stepId: step.id, expectation: expectation.type,
                    beforeVerdict: "-", afterVerdict: "-",
                    outcome: .notRehearsed("the command holds the shell open until the app is quit")))
            }
        }
        continue
    }

    guard hasSomethingToEvaluate, let watch else {
        // Run it, evaluate nothing. The later steps depend on this having happened.
        if let command = step.command {
            print("   running (unwatched): \(command.replacingOccurrences(of: "\n", with: " ; "))")
            try TerminalDriver.runCommand(command, windowId: windowId, timeoutSeconds: 600)
        } else {
            print("   nothing to run and nothing to watch")
        }
        print("")
        continue
    }

    if watch.sensitive == true {
        for expectation in watch.expect {
            results.append(RehearsalResult(
                stepId: step.id, expectation: expectation.type,
                beforeVerdict: "-", afterVerdict: "-",
                outcome: .notRehearsed("sensitive: Iris takes no screenshot at all here, so rehearsing it would break the promise the flag exists to make")))
        }
        print("   sensitive — skipped by design\n")
        continue
    }

    // BEFORE. The frame the reader sees while the step is still undone.
    let beforeURL = runDirectory.appendingPathComponent("\(step.id)-before.jpg")
    ScreenCapture.raise(windowId: windowId)
    let beforeFrame = try ScreenCapture.captureScreen(to: beforeURL)

    var beforeVerdicts: [String: WatchVerdict?] = [:]
    for expectation in watch.expect where expectation.type == "visual" {
        let (verdict, _) = evaluator.evaluate(
            screenshot: beforeFrame, stepTitle: step.title,
            visualPrompt: expectation.prompt ?? "", hints: watch.hints ?? [])
        beforeVerdicts["visual"] = verdict
    }
    var beforeLocal: [String: Bool] = [:]
    for expectation in watch.expect where expectation.type != "visual" {
        switch expectation.type {
        case "toolVersion":
            beforeLocal[expectation.type] = LocalSignals.toolIsVisibleToAGUIApp(expectation.tool ?? "")
        case "foregroundApp":
            beforeLocal[expectation.type] = LocalSignals.frontmostBundleIdentifier() == expectation.bundleId
        default:
            beforeLocal[expectation.type] = false
        }
    }

    // Do the work.
    if let command = step.command {
        print("   running: \(command.replacingOccurrences(of: "\n", with: " ; "))")
        try TerminalDriver.runCommand(command, windowId: windowId, timeoutSeconds: 600)
    } else {
        print("   no command — capturing the same frame twice")
    }
    Thread.sleep(forTimeInterval: 2)

    // AFTER.
    let afterURL = runDirectory.appendingPathComponent("\(step.id)-after.jpg")
    ScreenCapture.raise(windowId: windowId)
    let afterFrame = try ScreenCapture.captureScreen(to: afterURL)

    for expectation in watch.expect {
        var beforeText = "-", afterText = "-"
        var outcome: RehearsalOutcome

        if expectation.type == "visual" {
            let before = beforeVerdicts["visual"] ?? nil
            let (after, rawAfter) = evaluator.evaluate(
                screenshot: afterFrame, stepTitle: step.title,
                visualPrompt: expectation.prompt ?? "", hints: watch.hints ?? [])
            beforeText = String(describing: before ?? .notYet)
            afterText = String(describing: after ?? .notYet)

            if before == .completed {
                outcome = .firesEarly("said the step was done before the command ran")
            } else if after == .completed {
                outcome = .verified
            } else if after == nil {
                outcome = .harnessCouldNotAsk("model did not answer in the required shape: \(rawAfter.prefix(80))")
            } else {
                outcome = .neverFires("still not satisfied after the command completed")
            }
        } else {
            let before = beforeLocal[expectation.type] ?? false
            let after: Bool
            switch expectation.type {
            case "toolVersion": after = LocalSignals.toolIsVisibleToAGUIApp(expectation.tool ?? "")
            case "foregroundApp": after = LocalSignals.frontmostBundleIdentifier() == expectation.bundleId
            default: after = false
            }
            beforeText = before ? "satisfied" : "not satisfied"
            afterText = after ? "satisfied" : "not satisfied"

            if before && after {
                outcome = .instantPass
            } else if after {
                outcome = .verified
            } else if expectation.type == "urlHost" || expectation.type == "axElement" {
                outcome = .harnessCouldNotAsk("\(expectation.type) needs the reader's browser or an AX grant this harness does not drive")
            } else if step.command == nil {
                // Nothing was run, so nothing could have changed. A step whose
                // work is a manual drag into /Applications cannot be rehearsed,
                // and calling that a never-fires would be a false accusation.
                outcome = .notRehearsed("the step's work is manual — this harness runs commands, it does not move files for the reader")
            } else {
                outcome = .neverFires("not satisfied even after the command completed")
            }
        }

        let label = expectation.type == "visual"
            ? "visual: \(String((expectation.prompt ?? "").prefix(52)))"
            : "\(expectation.type): \(expectation.tool ?? expectation.bundleId ?? expectation.host ?? expectation.roleLabel ?? "")"
        results.append(RehearsalResult(stepId: step.id, expectation: label,
                                       beforeVerdict: beforeText, afterVerdict: afterText, outcome: outcome))
        print("   \(outcome.symbol.padding(toLength: 13, withPad: " ", startingAt: 0)) \(label)")
        print("      before=\(beforeText)  after=\(afterText)")
    }
    print("")
}

// MARK: - Report

print(String(repeating: "=", count: 78))
print("REHEARSAL: \(guide.appName) v\(guide.version) — \(branch.platform)")
print(String(repeating: "=", count: 78))
for result in results {
    print("\(result.outcome.symbol.padding(toLength: 13, withPad: " ", startingAt: 0)) \(result.stepId.padding(toLength: 16, withPad: " ", startingAt: 0)) \(result.expectation)")
}
let verified = results.filter { if case .verified = $0.outcome { return true }; return false }.count
let early = results.filter { if case .firesEarly = $0.outcome { return true }; return false }.count
let never = results.filter { if case .neverFires = $0.outcome { return true }; return false }.count
let instant = results.filter { if case .instantPass = $0.outcome { return true }; return false }.count
let skipped = results.filter { if case .notRehearsed = $0.outcome { return true }; return false }.count
let gaps = results.filter { if case .harnessCouldNotAsk = $0.outcome { return true }; return false }.count

print("\nverified both directions: \(verified)")
print("FIRES EARLY (skips the reader ahead): \(early)")
print("NEVER FIRES (strands the reader): \(never)")
print("instant pass (a finding about the guide, not a bug): \(instant)")
print("not rehearsed by design: \(skipped)")
print("harness could not ask: \(gaps)")
print("\nmodel calls: \(evaluator.callsMade)")
print("frames: \(runDirectory.path)")
