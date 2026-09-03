//
//  Bug6EditScreenshotDeliveryEndToEndTests.swift
//  leanring-buddyTests
//
//  THE WHOLE TAP, and the image really leaving this process. Bug 6 is one
//  missing picture: Akrit typed "Can you do what the image says?" over a
//  Google Doc, WhimprFlow is a menu-bar app with no window to photograph, so
//  `appWindowScreenshotPNG` was nil, so the opening turn — the only turn that
//  may carry an image — carried none, and the model correctly reported that
//  the referenced image was not in the request.
//
//  `Bug6EditScreenshotDeliveryReproTests` pins that mechanism. It stops three
//  steps short of what the reader actually experiences, and each of those steps
//  is a place a fix can be green and still not work:
//
//    1. its edit worker is an object in THIS process, so no image byte ever
//       crosses a process boundary. The field provider was Codex, which
//       delivers a picture by writing a FILE and passing `--image <path>` to a
//       child process — the repro builds that argument vector with
//       `CodexExecInvocation.arguments` and runs nothing;
//    2. it never reaches an ending: its run stops at the model's second turn
//       with the verification pair stubbed to `true`, so "the reader got their
//       change instead of a refusal" is not asserted anywhere;
//    3. it connects the reader's-screen seam BY HAND. Deleting the three lines
//       in `CompanionManager` that connect it in production would leave the
//       repro green and every real run blind again.
//
//  This file closes all three.
//
//  WHAT IS REAL HERE:
//    • a real git repository under $HOME shaped like his WhimprFlow clone;
//    • the real `OnDemandEditCoordinator` driven the way the card drives it —
//      pick, describe, clarify, approve, start — through its real eligibility,
//      provenance, clone-lock and dirty-tree gates;
//    • the real `MaintainTierCFixer` loop behind it, the real Seatbelt jail,
//      the real un-jailed verification build, the real cheat scan, the real
//      adversarial reviewer, the real commit onto an `iris/edit-…` branch;
//    • the real `CodexMaintainProvider.runCodexExec` — a real child process,
//      spawned with the real argument vector, fed the real prompt on stdin,
//      handed the real PNG as a real file on disk;
//    • the real `CompanionManager` wiring, asserted where production installs
//      it rather than where a test could install it for itself.
//
//  WHAT IS FAKED, and it is one thing: the `codex` binary. This Mac has no
//  Codex CLI, and a guard must not depend on one being signed in. In its place
//  is a REAL executable — a script — that reads its own argv, opens the file it
//  was pointed at, and decides its answer from what actually arrived. That is
//  the whole point: the stand-in cannot know whether Iris sent a picture unless
//  a picture really landed on its disk, so "the image was delivered" is read
//  off a second process's filesystem rather than off an in-process field.
//
//  WHAT IS STILL NOT REAL, and why. Nothing here calls ScreenCaptureKit. A test
//  binary holds no Screen Recording grant, so a real capture could only ever
//  return nil — it would pass this file for the wrong reason — and asking for
//  the grant would put a system prompt in front of the founder mid-run. So the
//  reader's screen arrives through the same injected seam production fills from
//  `OnDemandEditAppEvidence.captureReadersScreenPNG()`, and the third test below
//  is what pins production to actually fill it.
//
//  PROVEN TO GUARD: see the commit message. Against the pre-fix tree the fix's
//  seam does not exist, and `theSameRunWithNoReadersScreenEndsExactlyAsTheFieldRunDid`
//  — which names no post-fix symbol — is the negative control that shows the
//  ending in the first test is caused by the picture and not by the script.
//

import AppKit
import Foundation
import Testing

// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// MARK: - The guard

/// Serialized and env-gated like the other engine suites: each test stands up a
/// real git repository, spawns `sandbox-exec`, `git` and a real child process
/// for the model, and drives the real Tier C loop. Set
/// IRIS_SKIP_ONDEMAND_ENGINE_TESTS=1 to skip.
@MainActor
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["IRIS_SKIP_ONDEMAND_ENGINE_TESTS"] != "1"),
    .serialized
)
struct Bug6EditScreenshotDeliveryEndToEndTests {

    /// THE TAP HE MADE, ending the way it should have ended.
    ///
    /// Five things have to be true, and they are five different parts of the
    /// bug rather than five readings of one:
    ///
    ///   1. the reader is TOLD what Iris photographed — his run log said
    ///      "runtime evidence: its recent log output" and named no picture;
    ///   2. real image bytes reach a real child process, as a real file it can
    ///      open, on the opening call and only there;
    ///   3. the prompt that arrives with them says WHAT the picture is — a
    ///      desktop announced as "the app's current window" would be worse than
    ///      no picture, because two overlapping windows read as one app;
    ///   4. the run ENDS in the change he asked for rather than in the refusal
    ///      he got, committed on a branch the card names;
    ///   5. and the change is really in the tree — the verification command is
    ///      a real grep over the real file, so a run that committed nothing
    ///      cannot reach the branch at all.
    @Test func theReadersScreenReachesTheEditModelAsRealBytesAndTheChangeLands() async throws {
        guard MaintainSandbox.isAvailable else {
            Issue.record("this guard needs the Seatbelt jail the edit loop runs inside")
            return
        }
        let clone = try Bug6E2EWhimprflowClone.make()
        defer { clone.remove() }
        let codex = try Bug6E2EFakeCodexCLI.make()
        defer { codex.remove() }

        let session = Bug6E2EReaderSession(
            clone: clone, codex: codex, readersScreenPNG: Bug6E2EReadersScreen.documentScreenshotPNG
        )
        defer { session.forgetWhatThisTestRemembered() }
        await session.tapEditAndWaitForTheRunToEnd()

        // A run that never reached the model cannot say anything about what the
        // model was sent. Reported as a harness failure so it can never be
        // mistaken for the bug.
        guard codex.numberOfCallsMade > 0 else {
            Issue.record("""
                the run never reached the model — phase \(session.phaseDescription), \
                status \(session.statusLine ?? "none"). This is a harness problem, not the bug.
                \(session.terminalTranscriptForDiagnostics)
                """)
            return
        }

        // The loop really ran, in the real jail, over the real repository —
        // his log's `$ sed -n …` / `exit 0`. Asserted so no failure below can
        // ever be a dead harness wearing the bug's clothes, and so "1.3 seconds"
        // is read as a fast Mac rather than as a skipped engine.
        #expect(
            session.jailedCommandsThatRan.contains { $0.contains("crates/whimpr-core/src/settings.rs") },
            "the jail ran: \(session.jailedCommandsThatRan.joined(separator: " ; "))"
        )
        #expect(session.exitStatusesOfJailedCommands.first == 0)

        // 1. WHAT THE READER IS TOLD. His log's line named only the log tail.
        #expect(
            session.narrationTheReaderSaw.contains {
                $0.contains("a screenshot of your screen")
                    && $0.contains("WhimprFlow has no window to photograph")
            },
            """
            the reader was never told a picture of their screen was taken, which is \
            the line his own run log was missing. Iris said: \
            \(session.narrationTheReaderSaw.joined(separator: " | "))
            """
        )

        // 2. THE BYTES, ON THE OTHER SIDE OF A PROCESS BOUNDARY. Not "the turn
        //    holds a Data" — a second process opened a file and read it.
        let imageTheChildProcessOpened = codex.imageDeliveredOnCall(1)
        #expect(
            imageTheChildProcessOpened != nil,
            """
            NO IMAGE CROSSED THE PROCESS BOUNDARY. `codex exec` was invoked as: \
            \(codex.argumentsOnCall(1).joined(separator: " "))
            """
        )
        #expect(
            imageTheChildProcessOpened == Bug6E2EReadersScreen.documentScreenshotPNG,
            """
            the model was handed \(imageTheChildProcessOpened?.count ?? 0) bytes, but the \
            reader's screen was \(Bug6E2EReadersScreen.documentScreenshotPNG.count) bytes — \
            something re-encoded or replaced the picture on the way out.
            """
        )
        // The engine strips the image after the first reply so later steps do
        // not re-spend image tokens. That contract is asserted from the child's
        // own argument vectors rather than trusted.
        #expect(
            codex.numberOfCallsMade >= 2 && codex.imageDeliveredOnCall(2) == nil,
            """
            the picture was re-sent on step 2. Calls made: \(codex.numberOfCallsMade); \
            step 2 ran as: \(codex.argumentsOnCall(2).joined(separator: " "))
            """
        )

        // 3. AND THE PROMPT SAYS WHAT IT IS. Read out of the prompt the child
        //    actually received on stdin, not out of a string this test built.
        let promptTheModelReceived = codex.promptOnCall(1)
        #expect(
            promptTheModelReceived.contains("screenshot of the user's WHOLE SCREEN"),
            """
            the prompt never told the model what the attached picture is of. It opened: \
            \(promptTheModelReceived.prefix(400))…
            """
        )
        #expect(
            promptTheModelReceived.contains("it is NOT a picture of the app"),
            "the prompt did not warn that the picture is not the app itself"
        )
        #expect(
            promptTheModelReceived.contains("screenshot of the app's current window") == false,
            """
            the reader's desktop was announced to the model as the app's own window, \
            which is the one way to send a picture and still mislead — several windows \
            may be visible in it and they may overlap.
            """
        )
        #expect(
            promptTheModelReceived.contains(Bug6E2EReadersScreen.theRequestHeTyped),
            "the request the reader typed did not reach the model"
        )

        // 4. THE ENDING. His run ended BLOCKED asking for the picture; this one
        //    ends in the change, on a branch the card names.
        #expect(
            session.wasBlockedAskingForTheImage == false,
            """
            THE FIELD ENDING AGAIN: the run stopped to ask for the picture it had \
            already been sent — "\(session.blockedExplanation ?? "")"
            """
        )
        #expect(
            session.appliedBranchName != nil,
            """
            the run did not end in an applied change. Phase: \(session.phaseDescription).
            What the reader watched:
            \(session.terminalTranscriptForDiagnostics)
            """
        )
        #expect(
            session.statusLine?.contains("Applied on branch") == true,
            "the card never told the reader the change was applied; it said: \(session.statusLine ?? "(nothing)")"
        )

        // 5. AND THE CHANGE IS REALLY THERE. The committed branch is read
        //    through git, not through the coordinator that just claimed it.
        let branchName = session.appliedBranchName ?? ""
        #expect(
            clone.fileContentsOnBranch(branchName, path: "crates/whimpr-core/src/settings.rs")
                .contains(Bug6E2EFakeCodexCLI.markerTheModelWritesIntoTheRustSettings),
            """
            the branch \(branchName.isEmpty ? "(none)" : branchName) does not carry the change \
            the document asked for, so "applied" was a claim rather than a commit.
            """
        )
    }

    /// THE NEGATIVE CONTROL, and the reason the ending above means anything.
    ///
    /// The same fixture, the same real child process, the same real engine —
    /// with nothing standing in for the reader's screen, which is exactly the
    /// state every windowless app was in before the fix. The stand-in model is
    /// not scripted to block: it blocks because it looked for a picture, found
    /// none, and said so in his words. If this test ever goes green by producing
    /// an applied change, the model in the test above is answering from
    /// something other than the image and the whole guard is worthless.
    ///
    /// It names no symbol the fix introduced, so it compiles and runs against
    /// the tree before the fix as well as after it.
    @Test func theSameRunWithNoReadersScreenEndsExactlyAsTheFieldRunDid() async throws {
        guard MaintainSandbox.isAvailable else {
            Issue.record("this guard needs the Seatbelt jail the edit loop runs inside")
            return
        }
        let clone = try Bug6E2EWhimprflowClone.make()
        defer { clone.remove() }
        let codex = try Bug6E2EFakeCodexCLI.make()
        defer { codex.remove() }

        // readersScreenPNG nil: the coordinator's fallback source is left
        // unconnected, which is what a menu-bar app had on every code path.
        let session = Bug6E2EReaderSession(clone: clone, codex: codex, readersScreenPNG: nil)
        defer { session.forgetWhatThisTestRemembered() }
        await session.tapEditAndWaitForTheRunToEnd()

        guard codex.numberOfCallsMade > 0 else {
            Issue.record("""
                the control never reached the model — phase \(session.phaseDescription). \
                This is a harness problem, not a result.
                """)
            return
        }

        #expect(
            codex.imageDeliveredOnCall(1) == nil,
            "the control was supposed to send no picture, and sent one"
        )
        #expect(
            session.wasBlockedAskingForTheImage,
            """
            with no picture sent, the run did NOT end the way his did — so the model in \
            the sibling test is not deciding from the image, and that test proves nothing. \
            Phase: \(session.phaseDescription), status: \(session.statusLine ?? "none")
            """
        )
        #expect(
            session.appliedBranchName == nil,
            "a run that could not see the request's subject committed a change anyway"
        )
    }

    /// THE HOOKUP, at the one place a test cannot install for itself.
    ///
    /// Both tests above connect the reader's-screen source by hand, because a
    /// test binary holds no Screen Recording grant. That leaves exactly one hole
    /// — the three lines in `CompanionManager` that connect it in production —
    /// and deleting them would leave every run blind again with both tests above
    /// still green. This is the same class of hole `Test7ForeignEditWiringTests`
    /// covers for the paste catcher, closed the same way: build the real manager
    /// and ask the real coordinator whether it has the source at all.
    @Test func theProductionWiringGivesTheCoordinatorTheReadersScreenToFallBackOn() {
        let companionManager = CompanionManager()
        #expect(
            companionManager.onDemandEditCoordinator.captureReadersScreenPNGForFallback != nil,
            """
            the coordinator CompanionManager builds has no reader's-screen source, so an app \
            with no window to photograph is back to sending no picture at all — the exact \
            state Akrit's run was in. Everything else about the fix can still be present and \
            tested; it is simply no longer connected to the coordinator the app runs.
            """
        )
        // The gatherer beside it is asserted too, so a future edit that replaces
        // the block wholesale cannot satisfy this test by keeping only the new
        // line and dropping the one it falls back FROM.
        #expect(
            companionManager.onDemandEditCoordinator.gatherRuntimeEvidenceForApp != nil,
            "the app-window gatherer the fallback is a fallback FOR is no longer wired"
        )
    }
}

// MARK: - The reader's screen (a real image, really rendered)

/// The document he was looking at, and the words the run turned on.
enum Bug6E2EReadersScreen {

    /// The raw request each of his edit-run logs preserved.
    static let theRequestHeTyped = "Can you do what the image says?"

    /// The prompt text the packet transcribed from the document screenshot.
    static let theDocumentSaid = """
        The whimprflow engine is a bit bad, can we edit the local model it uses, \
        or connect it to CLI? It just seems a bit off so maybe its an issue with \
        the transcription or background noise, but there is something making it \
        not as good as like wisprflow.
        """

    /// The model's verdict, verbatim from run 2's log.
    static let theBlockedSentenceFromTheField = """
        The referenced image is not present in the request, so its requested behavior \
        cannot be identified reliably from the repository alone.
        """

    /// The question it handed back with it, verbatim.
    static let theQuestionFromTheField = "Please attach the image or paste the text shown in it."

    /// A real PNG of a document holding that text — what a capture of his screen
    /// would have carried. Rendered once, because the bytes are compared by
    /// identity on the far side of a process boundary and a re-render could drift.
    static let documentScreenshotPNG: Data = renderTheDocument()

    private static func renderTheDocument() -> Data {
        let width = 1000
        let height = 560
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 8
        (theDocumentSaid as NSString).draw(
            in: NSRect(x: 60, y: 60, width: width - 120, height: height - 120),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 26),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - The clone (a real repository, shaped like his)

/// His WhimprFlow checkout, reduced to the files the run reads and the one it
/// changes. A real git repository under $HOME, because eligibility resolves
/// symlinks and refuses anything outside it.
@MainActor
struct Bug6E2EWhimprflowClone {
    let path: String

    /// A slug of this guard's own: the coordinator READS and WRITES per-app
    /// memory under ~/Library/Logs/Iris/edit-runs, and a test must neither mine
    /// nor pollute the founder's real run history for a real app. Distinct from
    /// the repro's slug so the two files can run in the same process.
    static let appSlug = "whimprflow-bug6e2e"
    static let appName = "WhimprFlow"

    static func make() throws -> Bug6E2EWhimprflowClone {
        let containingDirectory = NSHomeDirectory() + "/.iris-bug6-e2e-clones/\(UUID().uuidString)"
        let clonePath = containingDirectory + "/whimprflow"
        let fileManager = FileManager.default
        for subdirectory in ["src-tauri/src", "ui/src/hub", "crates/whimpr-core/src"] {
            try fileManager.createDirectory(
                atPath: clonePath + "/" + subdirectory, withIntermediateDirectories: true
            )
        }
        let clone = Bug6E2EWhimprflowClone(path: clonePath)

        clone.write(".gitignore", "node_modules/\ntarget/\ndist/\n")
        clone.write("src-tauri/tauri.conf.json", """
        {
          "build": {
            "beforeBuildCommand": "pnpm build",
            "frontendDist": "../ui/dist"
          }
        }
        """)
        clone.write("src-tauri/Cargo.toml", """
        [package]
        name = "whimprflow"
        version = "0.1.0"
        edition = "2021"

        [[bin]]
        name = "whimprflow"
        path = "src/main.rs"
        """)
        clone.write("src-tauri/src/main.rs", "fn main() { println!(\"whimprflow\"); }\n")

        // A real pnpm project pinned to the pnpm this Mac actually has, so the
        // recipe the engine derives is the one his clone produced. Nothing here
        // installs: the dependency approval and the frontend build are Bug 5's
        // subject, and this guard's verification command touches neither.
        clone.write("ui/package.json", """
        {
          "name": "whimprflow-ui",
          "private": true,
          "packageManager": "pnpm@\(Bug6E2EToolchain.pnpmVersionOnThisMac)",
          "scripts": { "build": "vite build" },
          "devDependencies": { "vite": "5.4.0" }
        }
        """)
        clone.write("ui/pnpm-workspace.yaml", "packages:\n  - '.'\n")
        clone.write("ui/src/hub/SettingsPane.tsx", """
        export function SettingsPane() {
          // Hotkey, cleanup engine, and (nothing yet) the transcription model.
          return <div className="settings-pane">WhimprFlow settings</div>
        }
        """)

        // The file run 2's first jailed command read, and the file the change
        // lands in.
        clone.write("crates/whimpr-core/src/settings.rs", """
        // WhimprFlow settings. The transcription engine and its model live here.
        pub struct Settings {
            pub hotkey: String,
            pub transcription_model: String,
            pub cleanup_engine: Option<String>,
        }

        impl Default for Settings {
            fn default() -> Self {
                Self {
                    hotkey: "fn".to_string(),
                    transcription_model: "whisper-small".to_string(),
                    cleanup_engine: None,
                }
            }
        }
        """)

        clone.git(["init", "-q"])
        clone.git(["config", "user.email", "t@t"])
        clone.git(["config", "user.name", "t"])
        clone.git(["add", "-A"])
        clone.git(["commit", "-qm", "base"])
        return clone
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func write(_ relativePath: String, _ contents: String) {
        try? contents.write(toFile: path + "/" + relativePath, atomically: true, encoding: .utf8)
    }

    /// What a file looks like ON the committed branch, read through git so the
    /// claim "applied on branch X" is checked against the repository rather
    /// than against the object that made the claim.
    func fileContentsOnBranch(_ branchName: String, path relativePath: String) -> String {
        guard !branchName.isEmpty else { return "" }
        return git(["show", "\(branchName):\(relativePath)"])
    }

    @discardableResult
    func git(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = Pipe()
        try? process.run()
        let data = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// The real pnpm on this machine, read once. A fixture that hard-coded a
/// version would be describing a project rather than being one.
enum Bug6E2EToolchain {
    static let pnpmVersionOnThisMac: String = readPnpmVersion() ?? "10.0.0"

    private static func readPnpmVersion() -> String? {
        for candidatePath in ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
        where FileManager.default.isExecutableFile(atPath: candidatePath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidatePath)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let version, !version.isEmpty { return version }
        }
        return nil
    }
}

// MARK: - The `codex` binary, faked; the transport around it, real

/// A real executable standing in for the Codex CLI, which this Mac does not
/// have and which a guard must not require a login to.
///
/// It is deliberately NOT a script that prints a canned answer. It reads its own
/// argument vector, COPIES the file `--image` points at, reads the prompt off
/// stdin, and picks its reply from what it found — so the model's behaviour is a
/// function of what actually landed on its disk, and "the picture was delivered"
/// is a fact recorded by a second process rather than an assertion about a field
/// in this one. Everything around it — the argument vector, the scratch
/// directory, the PNG written to a file, the stdin feed, the pipe draining, the
/// `--output-last-message` read-back — is `CodexMaintainProvider`'s own code.
@MainActor
struct Bug6E2EFakeCodexCLI {
    let binaryPath: String
    let recordDirectoryPath: String

    /// Written into the Rust settings file by the model's edit turn, and the
    /// thing the verification command greps for. A run that committed without
    /// making the change cannot pass.
    static let markerTheModelWritesIntoTheRustSettings = "TRANSCRIPTION_MODEL_IS_CONFIGURABLE"

    static func make() throws -> Bug6E2EFakeCodexCLI {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-bug6-e2e-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recordDirectory = root.appendingPathComponent("record", isDirectory: true)
        try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
        let fake = Bug6E2EFakeCodexCLI(
            binaryPath: root.appendingPathComponent("codex").path,
            recordDirectoryPath: recordDirectory.path
        )

        // The replies live in files rather than inside the script, so no shell
        // quoting stands between the model's words and the engine's parser.
        fake.writeRecord("verdict-marker.txt", FeatureEditAdversarialReviewer.verdictLineMarker)
        fake.writeRecord("reply-investigate.txt", """
            Opening the settings and transcription sources to identify the requested change.

            ```bash
            sed -n '1,60p' crates/whimpr-core/src/settings.rs
            ```
            """)
        fake.writeRecord("reply-edit.txt", """
            The attached picture of the user's screen asks for the local transcription \
            model to be configurable, so I am adding the flag that turns it on.

            ```bash
            printf 'pub const \(markerTheModelWritesIntoTheRustSettings): bool = true;\\n' >> crates/whimpr-core/src/settings.rs
            ```
            """)
        fake.writeRecord("reply-done.txt", "The change is in place.\nDONE")
        fake.writeRecord("reply-blocked.txt", """
            BLOCKED: \(Bug6E2EReadersScreen.theBlockedSentenceFromTheField)
            QUESTION: \(Bug6E2EReadersScreen.theQuestionFromTheField)
            """)
        fake.writeRecord(
            "reply-review.txt",
            "Nothing disqualifying in the diff or the evidence log.\n"
                + "\(FeatureEditAdversarialReviewer.verdictLineMarker) "
                + FeatureEditAdversarialReviewer.cleanVerdictToken
        )

        try fake.script.write(toFile: fake.binaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.binaryPath
        )
        return fake
    }

    func remove() {
        let root = (binaryPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: What the child process recorded about each call

    var numberOfCallsMade: Int {
        Int(readRecord("call-count").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The argument vector the child was actually launched with, one entry per
    /// line, as the child itself saw it.
    func argumentsOnCall(_ callNumber: Int) -> [String] {
        readRecord("call-\(callNumber).argv")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// The prompt the child read off stdin.
    func promptOnCall(_ callNumber: Int) -> String { readRecord("call-\(callNumber).prompt") }

    /// The bytes of the file `--image` pointed at, copied out by the child
    /// before the provider deleted its scratch directory. nil when that call
    /// carried no image at all.
    func imageDeliveredOnCall(_ callNumber: Int) -> Data? {
        FileManager.default.contents(
            atPath: (recordDirectoryPath as NSString)
                .appendingPathComponent("call-\(callNumber)-image.png")
        )
    }

    private func writeRecord(_ name: String, _ contents: String) {
        try? contents.write(
            toFile: (recordDirectoryPath as NSString).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    private func readRecord(_ name: String) -> String {
        (try? String(
            contentsOfFile: (recordDirectoryPath as NSString).appendingPathComponent(name),
            encoding: .utf8
        )) ?? ""
    }

    /// The stand-in itself. POSIX sh so it needs nothing but what
    /// `CodexCLILogin.environmentForCodex()` already puts on PATH.
    private var script: String {
        """
        #!/bin/sh
        # A stand-in for `codex exec`, written by
        # Bug6EditScreenshotDeliveryEndToEndTests. It answers from what actually
        # arrived: the file --image points at, and the prompt on stdin.
        REC='\(recordDirectoryPath)'

        n=$(cat "$REC/call-count" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" > "$REC/call-count"

        out=""
        prev=""
        : > "$REC/call-$n.argv"
        for a in "$@"; do
          printf '%s\\n' "$a" >> "$REC/call-$n.argv"
          if [ "$prev" = "--output-last-message" ]; then out="$a"; fi
          if [ "$prev" = "--image" ]; then
            cp "$a" "$REC/call-$n-image.png"
            printf '%s' "$n" > "$REC/an-image-arrived"
          fi
          prev="$a"
        done

        # The prompt, read to EOF exactly as the real CLI reads it.
        cat > "$REC/call-$n.prompt"

        # No --output-last-message means Iris built an invocation this stand-in
        # cannot answer; fail loudly rather than silently.
        if [ -z "$out" ]; then exit 3; fi

        # The adversarial reviewer is a different role in a fresh context, told
        # apart by the verdict protocol its own system prompt teaches.
        if grep -qFf "$REC/verdict-marker.txt" "$REC/call-$n.prompt"; then
          cp "$REC/reply-review.txt" "$out"
          exit 0
        fi

        e=$(cat "$REC/edit-call-count" 2>/dev/null || echo 0)
        e=$((e + 1))
        printf '%s' "$e" > "$REC/edit-call-count"

        # Step 1 investigates, exactly as run 2's first step did.
        if [ "$e" = "1" ]; then
          cp "$REC/reply-investigate.txt" "$out"
          exit 0
        fi

        # Step 2 onwards: do what the picture asks — or, with no picture
        # anywhere in this conversation, report its absence in his words.
        if [ -f "$REC/an-image-arrived" ]; then
          if [ "$e" = "2" ]; then
            cp "$REC/reply-edit.txt" "$out"
          else
            cp "$REC/reply-done.txt" "$out"
          fi
        else
          cp "$REC/reply-blocked.txt" "$out"
        fi
        exit 0
        """
    }
}

/// The Tier C provider, spawning the stand-in through `CodexMaintainProvider`'s
/// OWN process code.
///
/// `respond` is `CodexMaintainProvider.respond`'s body verbatim minus its two
/// credential guards — `locateCodexBinary()` and `CodexCLILogin.currentState()`
/// — which would demand a real, signed-in CLI on this Mac and have nothing to
/// do with Bug 6. Everything past that line is the production path: the same
/// prompt assembly, the same turn → attachment mapping, and the same
/// `runCodexExec`, which builds the argument vector, validates it, writes each
/// image to a real file, spawns the process, feeds stdin and reads the reply back.
@MainActor
final class Bug6E2ECodexTransportProvider: MaintainModelProviding {
    let displayName = "Codex (a stand-in binary, real transport)"
    let identifier = "test-provider-bug6-e2e-codex"
    let isAvailable = true

    private let codexBinaryPath: String

    init(codexBinaryPath: String) {
        self.codexBinaryPath = codexBinaryPath
    }

    func respond(
        systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
    ) async throws -> String {
        let promptText = CodexExecInvocation.promptText(
            systemPrompt: systemPrompt, conversation: conversation
        )
        let attachedImages = conversation.compactMap { $0.attachedImagePNGData }
        return try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: codexBinaryPath,
            promptText: promptText,
            attachedImagePNGDataList: attachedImages,
            model: nil,
            webSearchEnabled: true,
            // Shorter than production's 300s: the stand-in answers in
            // milliseconds, and a hang here should fail the guard rather than
            // sit on the suite for five minutes.
            timeoutSeconds: 60,
            // The retry ladder itself is untouched — only the pause between
            // retries, so a stand-in that ever answered empty is not worth 15
            // seconds of wall clock.
            emptyReplyRetryWaitSecondsOverride: 0
        )
    }
}

// MARK: - The reader's session, driven through the real coordinator

/// One reader, one tap: pick the app, type his sentence, answer whatever Iris
/// asks, approve the plan, start, and wait for the run to end. Every gate along
/// the way is the real one.
///
/// The coordinator is built with production defaults except for the seams it
/// already exposes for exactly this:
///
///   • `probeRequestTriggers`, the pre-edit clarification probe, which is a
///     MODEL call and is answered all-quiet here (its own fail-open watchdog
///     does the same when a network stalls);
///   • `gatherRuntimeEvidenceForApp`, returning what the real gatherer returns
///     for a menu-bar app: real composed log text and NO window screenshot,
///     because no window of an LSUIElement app clears `captureFrontWindowPNG`'s
///     on-screen / 200x150 filter;
///   • `captureReadersScreenPNGForFallback`, which production fills from
///     `OnDemandEditAppEvidence.captureReadersScreenPNG()` and a test binary
///     cannot (no Screen Recording grant). Left unconnected when
///     `readersScreenPNG` is nil — the pre-fix state;
///   • `performOnDemandEdit`, wired to the SAME `MaintainTierCFixer` call
///     `defaultPerformOnDemandEdit` wires it to, with the Codex stand-in
///     standing in for the reader's resolved provider.
///
/// The delivery closures (`packageEditedAppFromClone`,
/// `terminateAndRelaunchEditedApp`) are left nil, which is a supported
/// production state: a successful run then ends at `.done` having committed the
/// branch, without packaging or relaunching anything. That matters here — this
/// Mac's Iris is running and must not be rebuilt or replaced by a test.
@MainActor
final class Bug6E2EReaderSession {
    let coordinator: OnDemandEditCoordinator

    init(clone: Bug6E2EWhimprflowClone, codex: Bug6E2EFakeCodexCLI, readersScreenPNG: Data?) {
        // A private defaults suite per session, so one session's provenance
        // cannot leak into another's — or into the Iris running on this Mac.
        let installProvenanceStore = InstallProvenanceStore(
            userDefaults: UserDefaults(suiteName: "iris.bug6.e2e.\(UUID().uuidString)")!
        )
        installProvenanceStore.recordGuideSourceClone(
            appSlug: Bug6E2EWhimprflowClone.appSlug,
            clonePath: clone.path,
            pinnedCommit: nil,
            canonicalRepo: nil
        )
        // Anything an earlier test remembered about this slug is forgotten
        // BEFORE the run, so "memory: N prior run(s) injected" cannot change
        // the prompt between the two runs in this file.
        Self.forgetTheMemoryForThisGuardsSlug()

        let provider = Bug6E2ECodexTransportProvider(codexBinaryPath: codex.binaryPath)
        self.coordinator = OnDemandEditCoordinator(
            installProvenanceStore: installProvenanceStore,
            patchQueue: PatchQueue(
                baseDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iris-bug6-e2e-\(UUID().uuidString)")
            ),
            // Never `.shared`: a lock held by this Mac's real Iris, or by a
            // sibling test, would refuse the run for a reason with nothing to
            // do with Bug 6.
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: {
                resolvedClonePath, appSlug, appStack, changeId, scrubbedRequest, kind,
                progressHandler, cancellationCheck, runtimeEvidence,
                additionalPromptSections, manifestChangeApproval in
                // What `defaultPerformOnDemandEdit` does, minus the provider
                // resolution — so the evidence → engine → opening-turn plumbing
                // under test is the production one.
                let fixer = MaintainTierCFixer(provider: provider)
                return await fixer.attemptOnDemandEdit(
                    clonePath: resolvedClonePath,
                    appSlug: appSlug,
                    appStack: appStack,
                    changeId: changeId,
                    request: scrubbedRequest,
                    kind: kind,
                    progressHandler: progressHandler,
                    cancellationCheck: cancellationCheck,
                    runtimeLogContext: runtimeEvidence.runtimeLogText,
                    appWindowScreenshotPNG: runtimeEvidence.appWindowScreenshotPNG,
                    attachedScreenshotIsOfTheReadersWholeScreen:
                        runtimeEvidence.screenshotIsOfTheReadersWholeScreen,
                    additionalPromptSections: additionalPromptSections,
                    manifestChangeApproval: manifestChangeApproval,
                    // A REAL command over the real tree, not `true`: it exits 0
                    // only once the model's edit is actually in the file, so a
                    // run that committed nothing cannot reach a branch. The
                    // toolchain build is Bug 5's subject and is deliberately not
                    // this guard's dependency.
                    verificationCommandsOverride: VerificationCommands(
                        buildCommand: "grep -q "
                            + Bug6E2EFakeCodexCLI.markerTheModelWritesIntoTheRustSettings
                            + " crates/whimpr-core/src/settings.rs",
                        testCommand: nil,
                        commandSubdirectory: nil
                    )
                )
            }
        )

        // The menu-bar app's evidence: logs, and no window.
        coordinator.gatherRuntimeEvidenceForApp = { _ in
            OnDemandEditRuntimeEvidence(
                runtimeLogText: OnDemandEditAppEvidence.composedRuntimeContext(
                    logTail: """
                        11:50:19 whimprflow: hotkey pressed, capture started
                        11:50:21 whimprflow: transcription finished in 412ms
                        """,
                    crashReportExcerpt: nil
                ),
                appWindowScreenshotPNG: nil
            )
        }
        if let readersScreenPNG {
            coordinator.captureReadersScreenPNGForFallback = { readersScreenPNG }
        }
    }

    // MARK: What the reader ends up looking at

    var phaseDescription: String { String(describing: coordinator.phase) }
    var statusLine: String? { coordinator.statusLine }

    /// Iris's own sentences to the reader, in order.
    var narrationTheReaderSaw: [String] {
        coordinator.editRunner.transcript.compactMap { entry in
            if case .explanation(let text) = entry { return text }
            return nil
        }
    }

    /// The commands the real Seatbelt jail actually ran — his log's `$ sed -n …`.
    var jailedCommandsThatRan: [String] {
        coordinator.editRunner.transcript.compactMap { entry in
            if case .commandFromTheGuide(let text) = entry { return text }
            return nil
        }
    }

    /// How each of them exited — his log's `exit 0 (0.1s)`.
    var exitStatusesOfJailedCommands: [Int32] {
        coordinator.editRunner.transcript.compactMap { entry in
            if case .exitStatus(let code, _) = entry { return code }
            return nil
        }
    }

    var blockedExplanation: String? {
        guard case .blockedByModel(let explanation) = coordinator.phase else { return nil }
        return explanation
    }

    /// The field ending: stopped on purpose, asking for a picture.
    var wasBlockedAskingForTheImage: Bool {
        blockedExplanation?.contains(Bug6E2EReadersScreen.theBlockedSentenceFromTheField) == true
    }

    /// The branch the change was committed on, or nil when the run did not end
    /// in an applied change.
    var appliedBranchName: String? {
        guard case .appliedAndRebuilt(let branchName, _, _, _, _) = coordinator.lastResult else {
            return nil
        }
        return branchName
    }

    /// The run as the reader watched it, so a failure can be diagnosed without
    /// re-running anything.
    var terminalTranscriptForDiagnostics: String {
        coordinator.editRunner.transcript.map { entry in
            switch entry {
            case .stepHeading(let stepTitle, _, _): return "== \(stepTitle)"
            case .commandFromTheGuide(let text): return "$ \(text)"
            case .commandFromAFix(let text, _, _, _): return "$ \(text)"
            case .output(let line): return "   \(line)"
            case .exitStatus(let code, _): return "   exit \(code)"
            case .awaitingConfirmation(let request): return "   ? \(request.commandText)"
            case .explanation(let text): return " . \(text)"
            }
        }.joined(separator: "\n")
    }

    // MARK: The tap

    func tapEditAndWaitForTheRunToEnd() async {
        coordinator.pickApp(
            slug: Bug6E2EWhimprflowClone.appSlug,
            name: Bug6E2EWhimprflowClone.appName,
            stack: .tauri
        )
        guard coordinator.phase == .describe else {
            // Loud rather than silent. The eligibility gate needs a connected
            // model provider and an available sandbox, neither of which is
            // stubbable — and a guard that goes green because the machine could
            // not reach the code is worse than no guard.
            Issue.record("the app was not eligible to edit: \(phaseDescription)")
            return
        }

        // A FEATURE, not a bug fix: a bug fix asks the model for a repro command
        // and runs three extra legs around it, which is a different subject.
        coordinator.describeRequest(Bug6E2EReadersScreen.theRequestHeTyped, kind: .feature)
        _ = await Bug6E2EWait.until(timeout: 60) {
            self.coordinator.phase == .presentingPlan || self.coordinator.phase == .clarifying
        }

        // The clarification batch is code-authored, so answering it the way a
        // reader would — the first option that is not "Stop" — is a
        // deterministic choice rather than a guess.
        if coordinator.phase == .clarifying {
            var answersByQuestionId: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                answersByQuestionId[question.id] =
                    question.options.first { !$0.lowercased().hasPrefix("stop") }
                    ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answersByQuestionId)
        }
        _ = await Bug6E2EWait.until(timeout: 60) { self.coordinator.phase == .presentingPlan }
        guard coordinator.phase == .presentingPlan else {
            Issue.record("the plan was never presented, so there was nothing to approve: \(phaseDescription)")
            return
        }

        coordinator.confirmPlanAndStart()
        let reachedAnEnding = await Bug6E2EWait.until(timeout: 300) { self.runHasSettled }
        if !reachedAnEnding {
            Issue.record("the run never finished — it is still \(phaseDescription)")
        }
    }

    /// True once the run is no longer in flight — any terminal phase, or one
    /// waiting on the reader.
    private var runHasSettled: Bool {
        switch coordinator.phase {
        case .pickApp, .describe, .clarifying, .presentingPlan, .awaitingStartConsent,
             .running, .committing, .delivering, .relaunching:
            return false
        default:
            return true
        }
    }

    // MARK: Leaving nothing behind

    /// Delete what this guard wrote into the real run-log folder: its per-app
    /// memory and its run transcripts. The slug is this guard's own, so nothing
    /// belonging to a real app is touched.
    func forgetWhatThisTestRemembered() {
        Self.forgetTheMemoryForThisGuardsSlug()
    }

    private static func forgetTheMemoryForThisGuardsSlug() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: OnDemandEditRunLog.memoryFilePath(
            forAppSlug: Bug6E2EWhimprflowClone.appSlug,
            inDirectoryPath: OnDemandEditRunLog.memoryIndexDirectoryPath
        ))
        let runsDirectory = OnDemandEditRunLog.runsDirectoryPath
        let runFileNames = (try? fileManager.contentsOfDirectory(atPath: runsDirectory)) ?? []
        for runFileName in runFileNames
        where runFileName.hasSuffix("-\(Bug6E2EWhimprflowClone.appSlug).log") {
            try? fileManager.removeItem(
                atPath: (runsDirectory as NSString).appendingPathComponent(runFileName)
            )
        }
    }
}

enum Bug6E2EWait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
