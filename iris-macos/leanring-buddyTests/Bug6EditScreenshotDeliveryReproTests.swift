//
//  Bug6EditScreenshotDeliveryReproTests.swift
//  leanring-buddyTests
//
//  THE REPORT. Test 10, Akrit, Iris 0.9.7 build 23, on his WhimprFlow clone.
//  He had a Google Doc open on his screen holding the request he wanted made,
//  and typed into the edit card:
//
//      Can you do what the image says?
//
//  The document said, verbatim:
//
//      The whimprflow engine is a bit bad, can we edit the local model it uses,
//      or connect it to CLI? …
//
//  What his own run log records, in order (run 2 of the cycle, 18:50:22Z):
//
//      Request: Can you do what the image says?
//      [11:50:42] memory: 3 prior run(s) injected
//      [11:50:42] runtime evidence: its recent log output      ← LOG ONLY
//      [11:50:50] iris: Opening the settings and hotkey sources …
//      [11:50:50] $ sed -n '1,260p' crates/whimpr-core/src/settings.rs; …
//      [11:50:50] exit 0 (0.1s)
//      [11:50:57] iris: BLOCKED: The referenced image is not present in the
//                 request, so its requested behavior cannot be identified
//                 reliably from the repository alone. QUESTION: Please attach
//                 the image or paste the text shown in it.
//
//  And the packet's own reading of the same window: "ScreenCaptureKit
//  enumerated on-screen content at 11:50:22.572 … The second run nevertheless
//  ended with `The referenced image is not present in the request`. This
//  supports a handoff/payload failure between the visible captured screen and
//  the edit-model request, not a general screen-recording failure."
//
//  THE MECHANISM, which this file reproduces rather than restates. The whole
//  edit engine has exactly ONE source of an image, `OnDemandEditAppEvidence`'s
//  `captureFrontWindowPNG(macBundleId:)`, and it can only ever photograph the
//  TARGET APP'S OWN front window: it filters ScreenCaptureKit's shareable
//  windows to `owningApplication.bundleIdentifier == macBundleId && isOnScreen
//  && width >= 200 && height >= 150`. WhimprFlow is a menu-bar app (LSUIElement)
//  — no window clears that filter — so the enumeration the packet saw succeed
//  returned an empty list, `appWindowScreenshotPNG` was nil, and
//  `OnDemandEditRuntimeEvidence` reached the engine carrying log text and
//  nothing else. `MaintainTierCFixer` attaches `appWindowScreenshotPNG` to the
//  opening turn (MaintainTierCFixer.swift:850) and nowhere else, so nil there
//  means zero image bytes on the wire, on every provider. The reader's SCREEN —
//  the thing "what the image says" actually refers to, and the exact capture
//  chat performs for every ordinary question through
//  `CompanionScreenCaptureUtility` — is never asked for, on any code path.
//  The model's BLOCKED was therefore correct: it reported precisely what it
//  had been sent.
//
//  WHAT IS REAL HERE, and deliberately so:
//    • a real git repository under $HOME shaped like his clone (src-tauri/ +
//      ui/ + crates/whimpr-core/), holding the very files run 2's first jailed
//      command read, and a real pnpm project pinned to THIS Mac's real pnpm;
//    • the real `OnDemandEditCoordinator` driven the way the card drives it —
//      pick, describe, clarify, approve the plan, start — through its real
//      eligibility, provenance, clone-lock and dirty-tree gates;
//    • the real `MaintainTierCFixer.attemptOnDemandEdit` behind it, wired from
//      the runtime evidence exactly as `defaultPerformOnDemandEdit` wires it,
//      running its real Seatbelt-jailed loop against that repository;
//    • the real `CodexExecInvocation.arguments` (the field provider was Codex)
//      built from the conversation the engine actually produced, so "no image
//      bytes crossed the process boundary" is read off the command line rather
//      than assumed. The Codex CLI is not installed on this Mac and is not
//      needed here: the argument vector is a pure function that runs nothing.
//    • a real PNG, rendered with AppKit, standing for the document he was
//      looking at — so "the image that never arrived" is a concrete payload
//      with bytes rather than a description of one.
//
//  WHAT IS NOT REAL, and why. Nothing in this file calls ScreenCaptureKit. A
//  test binary holds no Screen Recording grant, so a real capture here could
//  only ever return nil — it would prove the bug by accident, for the wrong
//  reason — and asking for the grant would put a system prompt in front of the
//  founder mid-run. The windowless app is therefore modelled at the seam the
//  coordinator already injects (`gatherRuntimeEvidenceForApp`), returning
//  exactly what the real gatherer returns for an LSUIElement app: real composed
//  log text from `OnDemandEditAppEvidence.composedRuntimeContext`, and a nil
//  screenshot.
//
//  WHERE THE CONTRACT LIVES, for whoever fixes this. The contract is "a run
//  whose request is about something on the reader's screen must send the model
//  an image of that screen, and must say what it sent" — NOT "the coordinator
//  has a property named X". A test binary can never capture a screen for real,
//  so the fix has to expose the reader's-screen source as an injectable seam
//  the way `gatherRuntimeEvidenceForApp` already is, and this file's driver has
//  ONE marked place (`wireTheReadersScreenSourceHereWhenTheFixLands`) where that
//  seam gets connected to `Bug6ReadersScreen.documentScreenshotPNG`. Connect it
//  there and this repro turns green; move the assertions only if the fix puts
//  the decision somewhere else entirely.
//

import AppKit
import Foundation
import Testing

// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// MARK: - The field cycle, end to end

/// Serialized and env-gated like the other engine suites: this spawns
/// `sandbox-exec` and `git` and runs the REAL Tier C loop against a real
/// repository on disk. Set IRIS_SKIP_ONDEMAND_ENGINE_TESTS=1 to skip.
@MainActor
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["IRIS_SKIP_ONDEMAND_ENGINE_TESTS"] != "1"),
    .serialized
)
struct Bug6TheFieldEditRunTests {

    /// THE RECREATION of 18:50:22Z. A menu-bar app with no capturable window, a
    /// request that points at the reader's screen, and a worker that answers
    /// from what it was actually sent.
    ///
    /// Every expectation below is about the one thing the report is: an image
    /// the reader was looking at, which no part of the edit path ever asked
    /// for, so the worker was handed a request naming a picture it could not
    /// have had.
    @Test func theEditWorkerIsAskedAboutAnImageItIsNeverSent() async throws {
        guard MaintainSandbox.isAvailable else {
            Issue.record("this repro needs the Seatbelt jail the edit loop runs inside")
            return
        }
        let clone = try Bug6WhimprflowClone.make()
        defer { clone.remove() }

        let run = Bug6CoordinatorRun(clone: clone)
        defer { run.forgetWhatThisTestRemembered() }
        await run.driveTheReadersRequestAllTheWayThrough()

        // A run that never reached the worker cannot say anything about what
        // the worker was sent — that is a harness failure, and it is reported
        // as one so it can never be mistaken for the bug.
        guard run.editWorker.callCount > 0 else {
            Issue.record("""
                the repro never reached the edit worker — phase \
                \(String(describing: run.coordinator.phase)), status \
                \(run.coordinator.statusLine ?? "none"). This is a harness problem, \
                not the bug.
                """)
            return
        }

        // The loop really ran: his log's `$ sed -n '1,260p'
        // crates/whimpr-core/src/settings.rs` and `exit 0 (0.1s)`, here as a
        // real Seatbelt-jailed command over the real repository. Asserted so a
        // failure below can never be a dead harness wearing the bug's clothes.
        #expect(
            run.jailedCommandsThatRan.contains { $0.contains("crates/whimpr-core/src/settings.rs") },
            "the jail ran: \(run.jailedCommandsThatRan.joined(separator: " ; "))"
        )
        #expect(run.exitStatusesOfJailedCommands.first == 0)
        #expect(run.editWorker.callCount >= 2, "the worker was asked to investigate, then to act")

        // The premise, read off the run rather than off the fixture: the app
        // has no window to photograph, exactly as WhimprFlow has none, and the
        // log half of the evidence did arrive (his "runtime evidence: its
        // recent log output").
        #expect(
            run.runtimeEvidenceTheRunWasGiven?.appWindowScreenshotPNG == nil,
            "the fixture must model a menu-bar app with no capturable window"
        )
        #expect(run.runtimeEvidenceTheRunWasGiven?.runtimeLogText != nil)

        // ── THE BUG ────────────────────────────────────────────────────────
        // The reader asked about a picture on their screen. Nothing in the edit
        // path ever photographs a screen, so the opening turn — the one and
        // only turn that may carry an image — carried none.
        let imageOnTheOpeningTurn = run.editWorker.openingImagePNGByCall.first ?? nil
        #expect(
            imageOnTheOpeningTurn != nil,
            """
            NO IMAGE REACHED THE EDIT REQUEST. The reader asked \
            "\(Bug6ReadersScreen.theRequestHeTyped)" with \
            \(Bug6ReadersScreen.documentScreenshotPNG.count) bytes of document on their screen, \
            and the opening turn to the edit worker carried no image at all: the app has no \
            window to photograph, and Iris never looks at the reader's screen for an edit.
            """
        )

        // Whatever image is sent has to be announced, or a model reading the
        // prompt cannot tell what it is looking at. Today none is sent and the
        // prompt correspondingly names none.
        let openingText = run.editWorker.openingTextByCall.first ?? ""
        #expect(
            openingText.lowercased().contains("screenshot"),
            """
            THE PROMPT NAMES NO IMAGE. The opening message never tells the worker that a \
            picture is attached or what it is of, because none is. It opens: \
            \(openingText.prefix(240))…
            """
        )

        // ── THE WIRE ───────────────────────────────────────────────────────
        // The field provider was Codex, which delivers images by writing each
        // one to a file and passing `--image <path>`. Built from the engine's
        // real opening conversation, the vector carries no image at all — which
        // also settles that Codex's delivery is not the defect: there is simply
        // nothing for it to deliver.
        let codexArguments = Bug6CodexWire.argumentsForTheOpeningCall(
            run.editWorker.conversationOnTheOpeningCall
        )
        #expect(
            codexArguments.contains("--image"),
            """
            THE CODEX INVOCATION CARRIES NO IMAGE. From the engine's real opening conversation, \
            `codex exec` is invoked as: \(codexArguments.joined(separator: " "))
            """
        )

        // ── THE ENDING HE SAW ──────────────────────────────────────────────
        // The stand-in worker answers from what it was sent, so with no image
        // it blocks in his exact words. That ending is the failure, not the
        // fixture: a run must not die asking for a picture Iris could have been
        // looking at the whole time.
        #expect(
            run.coordinator.phase != .blockedByModel(
                explanation: Bug6ReadersScreen.theBlockedSentenceFromTheField
            ),
            """
            THE FIELD ENDING REPRODUCED: the run ended BLOCKED — \
            "\(Bug6ReadersScreen.theBlockedSentenceFromTheField)" QUESTION: \
            "\(run.coordinator.blockedQuestionForUser ?? "none")"
            """
        )

        // And what the reader is told: his log's "runtime evidence: its recent
        // log output" is the same sentence the terminal shows him, and it names
        // no picture, because none was ever taken.
        #expect(
            run.narrationTheReaderSaw.contains { $0.lowercased().contains("screen") },
            """
            THE READER IS TOLD NOTHING ABOUT A SCREENSHOT. Iris narrated: \
            \(run.narrationTheReaderSaw.joined(separator: " | "))
            """
        )
    }
}

// MARK: - What the evidence bundle can carry at all (the premise, documented)

/// Pure checks on the shape of the evidence a run is built from. These pass
/// today; they are here so the mechanism above cannot be argued with.
@MainActor
@Suite struct Bug6WhatTheRuntimeEvidenceCanCarryTests {

    /// The gatherer's only image field is named for the one thing it can hold —
    /// the app's OWN window — and an app it has no bundle id for yields nothing
    /// at all. Nothing here can produce a picture of the reader's screen:
    /// there is no field for one.
    @Test func theEvidenceBundleHasNoPlaceForTheReadersScreen() async {
        let nothingToGather = await OnDemandEditAppEvidence.gather(macBundleId: nil)
        #expect(nothingToGather.appWindowScreenshotPNG == nil)
        #expect(nothingToGather.runtimeLogText == nil)

        let evidenceForAWindowlessApp = OnDemandEditRuntimeEvidence(
            runtimeLogText: "App log tail (most recent last):\n11:50 whimprflow: idle",
            appWindowScreenshotPNG: nil
        )
        #expect(evidenceForAWindowlessApp.appWindowScreenshotPNG == nil)
    }

    /// The engine's opening message says "a screenshot of the app's current
    /// window" only when a window capture succeeded. With none — every menu-bar
    /// app, always — it mentions no picture whatsoever, which is why a model
    /// asked about "the image" can only report its absence.
    @Test func theOpeningMessageOffersNoImageWhenTheAppHasNoWindow() {
        let messageWithNoCapture = MaintainTierCFixer.openingMessage(
            appSlug: "whimprflow",
            task: .onDemand(request: Bug6ReadersScreen.theRequestHeTyped, kind: .feature),
            repoMapSummary: "",
            runtimeShapePreflightAddendum: nil,
            runtimeLogContext: "App log tail (most recent last):\n11:50 whimprflow: idle",
            hasAttachedWindowScreenshot: false
        )
        #expect(messageWithNoCapture.contains("screenshot of the app's current window") == false)
        #expect(messageWithNoCapture.contains(Bug6ReadersScreen.theRequestHeTyped))

        // And the sentence that DOES exist speaks only of the app's own window,
        // which is the thing a menu-bar app can never provide.
        let messageWithACapture = MaintainTierCFixer.openingMessage(
            appSlug: "whimprflow",
            task: .onDemand(request: Bug6ReadersScreen.theRequestHeTyped, kind: .feature),
            repoMapSummary: "",
            runtimeShapePreflightAddendum: nil,
            runtimeLogContext: nil,
            hasAttachedWindowScreenshot: true
        )
        #expect(messageWithACapture.contains("screenshot of the app's current window"))
    }
}

// MARK: - The reader's screen (a real image, really rendered)

/// The document he was looking at, and the words the run turned on. Rendered
/// with AppKit into real PNG bytes so "the image that never arrived" is a
/// concrete payload the assertions can point at.
enum Bug6ReadersScreen {

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

    /// A real PNG of a document holding that text — what a capture of his
    /// screen would have carried. Rendered once, because the bytes are compared
    /// by identity and a re-render could drift.
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

/// His WhimprFlow checkout, reduced to what run 2 actually touched: the Tauri
/// crate, the pnpm frontend, and the files its first jailed command read. A
/// real git repository under $HOME, because eligibility resolves symlinks and
/// refuses anything outside it.
@MainActor
struct Bug6WhimprflowClone {
    let path: String

    /// A slug of its own rather than the field's bare "whimprflow": the
    /// coordinator READS and WRITES per-app memory under
    /// ~/Library/Logs/Iris/edit-runs, and a test must neither mine nor pollute
    /// the founder's real run history for a real app.
    static let appSlug = "whimprflow-bug6repro"

    static func make() throws -> Bug6WhimprflowClone {
        let containingDirectory = NSHomeDirectory() + "/.iris-bug6-clones/\(UUID().uuidString)"
        let clonePath = containingDirectory + "/whimprflow"
        let fileManager = FileManager.default
        for subdirectory in [
            "src-tauri/src", "ui/src/hub", "crates/whimpr-core/src", "crates/whimpr-asr/src",
        ] {
            try fileManager.createDirectory(
                atPath: clonePath + "/" + subdirectory, withIntermediateDirectories: true
            )
        }
        let clone = Bug6WhimprflowClone(path: clonePath)

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
        clone.write("src-tauri/src/hotkey.rs", """
        // The push-to-talk hotkey. Fn by default.
        pub const DEFAULT_HOTKEY: &str = "fn";
        """)

        // A real pnpm project, pinned to the pnpm this Mac actually has, so the
        // recipe the coordinator derives is the one his clone produced. No
        // install is run: dependency approval is Bug 5's subject, and this run
        // never reaches a build.
        clone.write("ui/package.json", """
        {
          "name": "whimprflow-ui",
          "private": true,
          "packageManager": "pnpm@\(Bug6Toolchain.pnpmVersionOnThisMac)",
          "scripts": { "build": "vite build" },
          "devDependencies": { "vite": "5.4.0" }
        }
        """)
        clone.write("ui/pnpm-workspace.yaml", "packages:\n  - '.'\n")

        // The files run 2's first jailed command read, by name.
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
        clone.write("crates/whimpr-asr/src/lib.rs", """
        // On-device transcription. The model name comes from Settings.
        pub fn transcribe(_audio: &[f32], model: &str) -> String {
            format!("transcribed with {model}")
        }
        """)
        clone.write("ui/src/hub/SettingsPane.tsx", """
        export function SettingsPane() {
          // Hotkey, cleanup engine, and (nothing yet) the transcription model.
          return <div className="settings-pane">WhimprFlow settings</div>
        }
        """)
        clone.write("ui/src/hub/api.ts", """
        export async function readSettings() {
          return { hotkey: 'fn', transcriptionModel: 'whisper-small' }
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
enum Bug6Toolchain {
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

// MARK: - The worker (a stand-in that answers from what it was actually sent)

/// The edit worker, replaced by something that can only know what arrived.
///
/// It is NOT a script: a scripted BLOCKED would prove nothing, because it would
/// say the same thing whether or not an image was delivered. This stand-in
/// reads its own opening turn and answers the way the field model did — it
/// investigates first, and then either does what the document asks (if the
/// document reached it) or reports, in his log's exact words, that the
/// referenced image is not in the request.
final class Bug6EditWorkerStandIn: MaintainModelProviding, @unchecked Sendable {
    let displayName = "bug6-edit-worker-stand-in"
    let identifier = "test-provider-bug6"
    let isAvailable = true

    private let lock = NSLock()
    private var calls = 0
    private var openingImages: [Data?] = []
    private var openingTexts: [String] = []
    private var openingConversation: [MaintainChatTurn] = []
    private var anImageArrivedOnTheOpeningTurn = false

    /// Run 2's first jailed command, reading the same files.
    private static let theInvestigationTurn = """
        Opening the settings and transcription sources to identify the image-requested feature.
        ```bash
        sed -n '1,60p' crates/whimpr-core/src/settings.rs; \
        grep -R -n "transcription_model" crates/whimpr-core/src ui/src src-tauri/src
        ```
        """

    /// What it says when nothing but text arrived — verbatim from his log.
    private static let theBlockedTurn = """
        BLOCKED: \(Bug6ReadersScreen.theBlockedSentenceFromTheField)
        QUESTION: \(Bug6ReadersScreen.theQuestionFromTheField)
        """

    /// What it does when the picture DID arrive. A stand-in cannot read a
    /// document and does not pretend to: whether the bytes arrive at all is the
    /// entire subject of this bug, so arrival is what it acts on.
    private static let theEditTheDocumentAsksFor = """
        The attached document asks for a configurable local transcription model.
        ```bash
        printf 'pub const TRANSCRIPTION_MODEL_IS_CONFIGURABLE: bool = true;\\n' >> crates/whimpr-core/src/settings.rs
        ```
        """

    var callCount: Int { lock.whileLocked { calls } }
    var openingImagePNGByCall: [Data?] { lock.whileLocked { openingImages } }
    var openingTextByCall: [String] { lock.whileLocked { openingTexts } }
    var conversationOnTheOpeningCall: [MaintainChatTurn] { lock.whileLocked { openingConversation } }

    func respond(
        systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
    ) async throws -> String {
        lock.lock()
        let callIndex = calls
        calls += 1
        let openingImage = conversation.first?.attachedImagePNGData
        openingImages.append(openingImage)
        openingTexts.append(conversation.first?.text ?? "")
        if callIndex == 0 {
            openingConversation = conversation
            // The engine strips the image after the first reply, so what the
            // opening call saw is the only chance any call has to see it.
            anImageArrivedOnTheOpeningTurn = (openingImage?.isEmpty == false)
        }
        let sawTheReadersScreen = anImageArrivedOnTheOpeningTurn
        lock.unlock()

        switch callIndex {
        case 0: return Self.theInvestigationTurn
        case 1: return sawTheReadersScreen ? Self.theEditTheDocumentAsksFor : Self.theBlockedTurn
        default: return "DONE"
        }
    }
}

private extension NSLock {
    func whileLocked<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - The Codex wire (the field provider's real argument vector)

/// The field run's Tier C provider was Codex, which delivers images by writing
/// each one to a file and passing `--image <path>`. This rebuilds that vector
/// from the conversation the engine really produced, using the provider's own
/// pure builder, so "no image bytes crossed the boundary" is read off the
/// command line rather than inferred. `arguments` executes nothing, and the
/// CLI itself is not installed on this Mac.
enum Bug6CodexWire {
    static func argumentsForTheOpeningCall(_ conversation: [MaintainChatTurn]) -> [String] {
        // Exactly `CodexMaintainProvider.respond`'s own line: every turn that
        // carries image data becomes one attachment path.
        let attachedImages = conversation.compactMap { $0.attachedImagePNGData }
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-bug6-codex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        var attachedImagePaths: [String] = []
        for (index, imagePNGData) in attachedImages.enumerated() {
            let imageURL = scratchDirectory.appendingPathComponent("attachment-\(index).png")
            guard (try? imagePNGData.write(to: imageURL)) != nil else { continue }
            attachedImagePaths.append(imageURL.path)
        }
        return CodexExecInvocation.arguments(
            finalMessageOutputPath: scratchDirectory
                .appendingPathComponent("final-message.txt").path,
            workingDirectory: scratchDirectory.path,
            attachedImagePaths: attachedImagePaths,
            model: nil,
            webSearchEnabled: false
        )
    }
}

// MARK: - The run (the real coordinator, the real engine)

/// Drives the real `OnDemandEditCoordinator` through the steps the card drives
/// — pick, describe, clarify, approve the plan, start — with the REAL Tier C
/// engine behind it and only two things replaced: the model (the stand-in
/// above) and the runtime-evidence gather (a menu-bar app's, which no test
/// binary may capture for real).
@MainActor
final class Bug6CoordinatorRun {
    let coordinator: OnDemandEditCoordinator
    let editWorker = Bug6EditWorkerStandIn()

    /// What the coordinator handed the engine — captured at the seam so the
    /// premise is asserted from the run rather than from the fixture.
    private(set) var runtimeEvidenceTheRunWasGiven: OnDemandEditRuntimeEvidence?

    /// Iris's own sentences to the reader, in order.
    var narrationTheReaderSaw: [String] {
        coordinator.editRunner.transcript.compactMap { entry in
            if case .explanation(let text) = entry { return text }
            return nil
        }
    }

    /// The commands the real jail actually ran — his log's `$ sed -n …` lines.
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

    init(clone: Bug6WhimprflowClone) {
        let provenanceStore = InstallProvenanceStore(
            userDefaults: UserDefaults(suiteName: "iris.bug6.\(UUID().uuidString)")!
        )
        provenanceStore.recordGuideSourceClone(
            appSlug: Bug6WhimprflowClone.appSlug, clonePath: clone.path,
            pinnedCommit: nil, canonicalRepo: nil
        )
        // Anything an earlier run of this test remembered is forgotten BEFORE
        // the run, so "memory: N prior run(s) injected" cannot change the
        // prompt between runs.
        Self.forgetTheMemoryForThisTestsSlug()

        let worker = editWorker
        self.coordinator = OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(
                baseDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iris-bug6-\(UUID().uuidString)")
            ),
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: {
                clonePath, appSlug, appStack, changeId, scrubbedRequest, kind,
                progressHandler, cancellationCheck, runtimeEvidence,
                additionalPromptSections, manifestChangeApproval in
                await Bug6CoordinatorRun.runTheRealEngine(
                    provider: worker,
                    clonePath: clonePath, appSlug: appSlug, appStack: appStack,
                    changeId: changeId, scrubbedRequest: scrubbedRequest, kind: kind,
                    progressHandler: progressHandler, cancellationCheck: cancellationCheck,
                    runtimeEvidence: runtimeEvidence,
                    additionalPromptSections: additionalPromptSections,
                    manifestChangeApproval: manifestChangeApproval
                )
            }
        )

        // The gather seam, returning what the real gatherer returns for a
        // menu-bar app: real composed log text, and no window screenshot,
        // because no window of that app clears `captureFrontWindowPNG`'s
        // on-screen / 200x150 filter.
        coordinator.gatherRuntimeEvidenceForApp = { [weak self] _ in
            let evidence = OnDemandEditRuntimeEvidence(
                runtimeLogText: OnDemandEditAppEvidence.composedRuntimeContext(
                    logTail: """
                        11:50:19 whimprflow: hotkey pressed, capture started
                        11:50:21 whimprflow: transcription finished in 412ms
                        """,
                    crashReportExcerpt: nil
                ),
                appWindowScreenshotPNG: nil
            )
            self?.runtimeEvidenceTheRunWasGiven = evidence
            return evidence
        }

        // ── wireTheReadersScreenSourceHereWhenTheFixLands ──────────────────
        // The reader HAD a document on screen (`Bug6ReadersScreen
        // .documentScreenshotPNG`, real bytes) and Iris never asked for it. A
        // test binary holds no Screen Recording grant, so the fix's source for
        // the reader's screen is injectable, and it is connected here.
        coordinator.captureReadersScreenPNGForFallback = {
            Bug6ReadersScreen.documentScreenshotPNG
        }
    }

    /// The production performer, verbatim except for the provider and a
    /// verification pair that needs no toolchain: this is
    /// `OnDemandEditCoordinator.defaultPerformOnDemandEdit`'s own body, so the
    /// evidence → engine → opening-turn plumbing under test is the real one.
    static func runTheRealEngine(
        provider: Bug6EditWorkerStandIn,
        clonePath: String,
        appSlug: String,
        appStack: BreakAppStack,
        changeId: String,
        scrubbedRequest: String,
        kind: OnDemandEditKind,
        progressHandler: @escaping MaintainTierCProgressHandler,
        cancellationCheck: @escaping MaintainTierCCancellationCheck,
        runtimeEvidence: OnDemandEditRuntimeEvidence,
        additionalPromptSections: [String],
        manifestChangeApproval: @escaping MaintainTierCManifestChangeApproval
    ) async -> MaintainOnDemandEditResult {
        let fixer = MaintainTierCFixer(provider: provider)
        return await fixer.attemptOnDemandEdit(
            clonePath: clonePath,
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
            // His run 2 blocked at step 2 and never reached a build, so the
            // verification pair is stubbed to something instant. Bug 5 owns the
            // pnpm/cargo build; nothing here depends on it.
            verificationCommandsOverride: VerificationCommands(
                buildCommand: "true", testCommand: nil, commandSubdirectory: nil
            ),
            // The independent review is a second call on the same provider;
            // this test reads the ENGINE's conversation, so it stays off.
            runsAnIndependentReview: false
        )
    }

    /// Pick the app, type his sentence, answer whatever Iris asks, approve the
    /// plan, and wait for the run to settle.
    func driveTheReadersRequestAllTheWayThrough() async {
        coordinator.pickApp(
            slug: Bug6WhimprflowClone.appSlug, name: "WhimprFlow", stack: .tauri
        )
        guard coordinator.phase == .describe else {
            Issue.record("""
                the app was not eligible for an edit: \
                \(coordinator.statusLine ?? String(describing: coordinator.phase))
                """)
            return
        }

        coordinator.describeRequest(Bug6ReadersScreen.theRequestHeTyped, kind: .feature)
        _ = await Bug6Wait.until(timeout: 30) {
            self.coordinator.phase == .presentingPlan || self.coordinator.phase == .clarifying
        }
        if coordinator.phase == .clarifying {
            var answersByQuestionId: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                answersByQuestionId[question.id] =
                    question.options.first { !$0.lowercased().hasPrefix("stop") }
                    ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answersByQuestionId)
        }
        _ = await Bug6Wait.until(timeout: 30) { self.coordinator.phase == .presentingPlan }

        coordinator.confirmPlanAndStart()
        _ = await Bug6Wait.until(timeout: 240) { self.runHasSettled }
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

    /// Delete what this test wrote into the real run-log folder: its per-app
    /// memory and its run transcripts. The slug is this test's own, so nothing
    /// belonging to a real app is touched.
    func forgetWhatThisTestRemembered() {
        Self.forgetTheMemoryForThisTestsSlug()
    }

    private static func forgetTheMemoryForThisTestsSlug() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: OnDemandEditRunLog.memoryFilePath(
            forAppSlug: Bug6WhimprflowClone.appSlug,
            inDirectoryPath: OnDemandEditRunLog.memoryIndexDirectoryPath
        ))
        let runsDirectory = OnDemandEditRunLog.runsDirectoryPath
        let runFileNames = (try? fileManager.contentsOfDirectory(atPath: runsDirectory)) ?? []
        for runFileName in runFileNames
        where runFileName.hasSuffix("-\(Bug6WhimprflowClone.appSlug).log") {
            try? fileManager.removeItem(
                atPath: (runsDirectory as NSString).appendingPathComponent(runFileName)
            )
        }
    }
}

enum Bug6Wait {
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
