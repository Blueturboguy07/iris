//
//  Bug4EditThisAppCardReproTests.swift
//  leanring-buddyTests
//
//  BUG 4, TEST 9 (Iris 0.9.6 build 22): "Edit this app click shows nothing."
//
//  THE FIELD SCENARIO, from the cofounder's own runtime log, in order:
//
//    07:03:42Z  Iris relaunches (pid 51799) and resumes the kneecap iOS guide
//               with autopilot driving it — the centered terminal takeover is up.
//    07:06:08Z  "drive: step[12] id=run kind=open exec=false"
//               "drive: step run → MANUAL branch, waiting at gate (return)"
//               "takeover: PARKED + set readerMustManuallyContinue=true,
//                showsTerminalFace=true, title=Plug in your iPhone and press play"
//               The takeover slides to the corner and WAITS on the reader. It is
//               never torn down again in the whole log.
//    07:06→07:18  The reader spends fifteen minutes asking Iris about Xcode and
//               the missing iOS simulator runtime — thirteen exchanges in the
//               eye's bar, the last at 07:18:10Z. So the bar is open, and it is
//               showing a conversation.
//    07:19:45Z  "stack: nitroai not in the curated table — derived electron from
//                /Users/akrit/NitroAI"
//               That line is `CompanionManager.appStack(forSlug:)`, which only
//               runs from `requestOnDemandEdit(forEntry:)`. The reader clicked
//               "Edit this app" on NitroAI in the settings panel, and the click
//               WAS accepted: the pick ran, the app was resolved, the coordinator
//               moved on.
//               Nothing appeared. No edit-run file was ever written, because the
//               reader was never shown anything to answer.
//
//  WHAT THESE TESTS DRIVE. The real settings-panel section view, hosted in a real
//  NSPanel, clicked with a real NSEvent through the panel's own `sendEvent` —
//  which runs the real `onEditApp` closure `CompanionPanelView` supplies, the real
//  `CompanionManager.requestOnDemandEdit(forEntry:)`, the real stack derivation
//  off a real git clone on disk, and the real `OnDemandEditCoordinator.pickApp`.
//  Then the real `OverlayEyeInputBarView` is rendered into a real off-screen
//  window either side of that click and MEASURED, the way `Test7OverlaySilenceRepro`
//  measures it — because "shows nothing" is a claim about pixels, and the only
//  honest way to test it is to draw them.
//
//  WHAT IS ACTUALLY WRONG (and it is not where the bug report points). The click
//  chain is fine end to end. The blocker is `OverlayEyeInputBar.swift`'s
//  `theCenteredTakeoverIsCoveringTheScreen` (L586-595):
//
//      (guideSessionController.autopilotIsShownAsTakeover
//          && !guideSessionController.readerHasFinishedTheGuide)
//          || companionManager.onDemandEditTakeoverIsUp
//
//  Parking a manual step sets `readerMustManuallyContinue`; it does NOT clear
//  `autopilotIsShownAsTakeover` (only `stopAutopilot()` / finishing the guide
//  does). So that flag was true for the whole fifteen minutes — and it gates two
//  things that have nothing to do with the guide it is about:
//
//    1. the bar's top-level if/else (L599-742): while it is true the bar renders
//       ONLY the ask field and the exchange. `MaintainAskCard`, `OnDemandEditCard`
//       and `finishedEditsList` are not in the layout at all, whatever phase the
//       edit coordinator is in;
//    2. `anAppIsOpenForEditing` (L957): `guard !theCenteredTakeoverIsCoveringTheScreen`
//       — which is what would otherwise turn the field into the "NitroAI · Ask |
//       Edit" composer that the `.describe` phase the pick just entered is drawn
//       as.
//
//  A guide that is parked waiting for the reader to plug in a phone therefore
//  swallows the entire surface of an edit on a COMPLETELY DIFFERENT app. The pick
//  succeeded and had nowhere to appear.
//
//  These tests do not grep source. Every assertion is either state the running
//  app reaches or the height and pixels the real views actually draw.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

// MARK: - Standing in for publik's catalog and LaunchServices

/// The catalog route, answered locally. The reader's machine had NitroAI
/// installed from source; this is the one row that produces its settings-panel
/// entry without a network call.
private struct Bug4CatalogDirectory: CatalogAppDirectorySource {
    let apps: [CatalogAppDescriptor]
    func catalogApps() async throws -> [CatalogAppDescriptor] { apps }
}

/// LaunchServices, answered locally: the app is installed. Only the presence of
/// a bundle matters here — `installationState` is what decides whether the row is
/// drawn at all, and an app that is not installed has no "Edit this app".
private struct Bug4InstalledApplicationLocator: InstalledApplicationLocating {
    let installedBundlePath: String
    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        URL(fileURLWithPath: installedBundlePath)
    }
}

/// A guide's autopilot run, sitting exactly where the reader's was: mid-install,
/// nothing executing, waiting at a manual gate. Enough for the real takeover
/// controller to present and park a real terminal window over the screen.
@MainActor
private final class Bug4ParkedGuideRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 11)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Open the project", stepNumber: 11, totalSteps: 13),
        .commandFromTheGuide(text: "open ios/App/App.xcworkspace"),
        .exitStatus(code: 0, duration: 3.5)
    ]
    @Published var isExecutingACommand: Bool = false
}

// MARK: - The suite

/// `.serialized` because every test here puts real windows on the screen — an
/// off-screen host for the settings section and the eye bar, and (in the first
/// test) the real centered takeover. Two of those racing each other would have
/// them reading one another's windows out of `NSApplication.shared.windows`.
@Suite("Bug 4 — \"Edit this app\" shows nothing while a guide is parked", .serialized)
@MainActor
struct Bug4EditThisAppCardReproTests {

    // MARK: 1. The precondition: a parked guide is still "shown as takeover"

    /// The mechanism the whole bug rests on, proved on the real objects rather
    /// than asserted from the source: when autopilot hands a manual step to the
    /// reader, the takeover PARKS — it slides to the corner and waits — and
    /// `autopilotIsShownAsTakeover` stays true the entire time. There is no
    /// teardown line anywhere in the reader's log after 07:06:08Z, and this is
    /// why: parking never clears the flag.
    ///
    /// This test passes before and after the fix. It is here so that a reader of
    /// the failure below can see that the state it sets up is the state the
    /// cofounder's Mac was actually in.
    @Test("a guide parked at a manual step is still flagged as covering the screen")
    func aParkedGuideStillCountsAsATakeoverCoveringTheScreen() async throws {
        let companionManager = CompanionManager()
        defer { companionManager.stop() }
        let guideSessionController = companionManager.guideSessionController

        // Exactly what `CompanionManager.presentAutopilotTakeover()` does when the
        // reader taps "Let Iris run it": raise the terminal, and tell the guide
        // controller it is being shown as a takeover.
        let takeoverController = GuideAutopilotTakeoverController()
        defer { takeoverController.dismiss(afterHold: false) }
        guideSessionController.setAutopilotIsShownAsTakeover(true)
        takeoverController.present(
            runner: Bug4ParkedGuideRunner(),
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )

        let terminalPanel = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? GuideAutopilotTakeoverTerminalPanel }.last,
            "the real takeover never put a terminal window on screen, so there is nothing to park"
        )
        // The entry morph grows the window from eye-sized to terminal-sized, and a
        // park requested before it settles is deferred. Wait it out, the way the
        // takeover's own tests do.
        _ = await Self.pump(within: 10) { terminalPanel.frame.width > 400 }
        let frameBeforeParking = terminalPanel.frame

        // 07:06:08Z — "step run → MANUAL branch, waiting at gate".
        takeoverController.parkForManualStep(
            title: "Plug in your iPhone and press play",
            instruction: "Pick your iPhone in Xcode's device menu and press the play button."
        )
        let parked = await Self.pump(within: 10) { terminalPanel.frame != frameBeforeParking }
        #expect(parked, "the takeover never actually parked, so this is not the reader's state")

        // THE POINT. Fifteen minutes of chatting later, this is still true.
        #expect(
            guideSessionController.autopilotIsShownAsTakeover,
            "parking cleared the takeover flag — then this bug's premise is wrong and the trace needs redoing"
        )
        #expect(
            !guideSessionController.readerHasFinishedTheGuide,
            "the guide is parked mid-install, not finished"
        )
    }

    // MARK: 2. The click really does reach the coordinator

    /// The half the runtime log already proves, re-proved here on the real
    /// controls: a real NSEvent click on the real "Edit this app" button, routed
    /// through a real NSPanel's `sendEvent`, runs the real handler and picks the
    /// app — WITH the parked guide's takeover flag up, exactly as on the
    /// cofounder's Mac.
    ///
    /// This passes on the unfixed code, and it has to: it is what rules out "the
    /// button swallowed the click" as an explanation for the failure below.
    @Test("the real click on \"Edit this app\" reaches the coordinator and picks the app")
    func theRealClickPicksTheApp() async throws {
        let scenario = try await Bug4FieldScenario.make()
        defer { scenario.tearDown() }
        scenario.companionManager.guideSessionController.setAutopilotIsShownAsTakeover(true)

        let section = Bug4SettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()

        let coordinator = scenario.companionManager.onDemandEditCoordinator
        #expect(
            coordinator.activeAppSlug == scenario.appSlug,
            "the click never reached `requestOnDemandEdit` — the coordinator has no app open"
        )
        #expect(
            coordinator.activeAppName == Bug4FieldScenario.appName,
            "the coordinator opened on the wrong app"
        )
        // `.describe` when this Mac has an editing credential connected,
        // `.notEligible` when it does not. Either is a pick that landed, and
        // either is something the reader is owed on screen; what must not happen
        // is the coordinator sitting untouched on `.pickApp`.
        #expect(
            coordinator.phase != .pickApp,
            "the pick left the coordinator on `.pickApp`: \(coordinator.phase)"
        )
    }

    // MARK: 3. THE REPRO

    /// THE REPORTED BUG, end to end, in the state the reader was in.
    ///
    /// A guide is parked at a manual step. The reader has been chatting in the
    /// eye's bar for a quarter of an hour, so the bar is open with an exchange in
    /// it. They open the settings panel and click "Edit this app" on a DIFFERENT
    /// app — one the guide has nothing to do with. The click lands, the pick
    /// succeeds (asserted, so a failure here cannot be a dead button).
    ///
    /// And the bar draws the same thing it drew before: same height, same pixels.
    /// No composer header naming the app, no edit card, no refusal — nothing. The
    /// reader's own words for it: "Edit this app click shows nothing."
    @Test("the bar shows the app the reader just picked, even while a guide is parked")
    func theBarShowsTheEditTheReaderJustAskedForWhileAGuideIsParked() async throws {
        let scenario = try await Bug4FieldScenario.make()
        defer { scenario.tearDown() }
        let companionManager = scenario.companionManager

        // 07:06:08Z — the kneecap guide is parked at "Plug in your iPhone and
        // press play". `parkForManualStep` leaves this flag set (test 1).
        companionManager.guideSessionController.setAutopilotIsShownAsTakeover(true)

        // 07:06→07:18 — fifteen minutes of Xcode questions in the eye's bar. The
        // bar is open and showing the last of them when the reader goes to the
        // settings panel.
        let theXcodeConversation = Bug4BarRendering.theReadersXcodeExchange()
        let barWhileOnlyChatting = Bug4BarRendering.bar(
            companionManager: companionManager, exchange: theXcodeConversation
        )

        // 07:19:45Z — the click.
        let section = Bug4SettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()

        // The pick landed. If this fails, the test is broken, not the app.
        let coordinator = companionManager.onDemandEditCoordinator
        try #require(
            coordinator.activeAppSlug == scenario.appSlug && coordinator.phase != .pickApp,
            """
            the click did not pick the app (phase \(coordinator.phase)), so this run says \
            nothing about what the bar draws — fix the harness, not the app
            """
        )

        let barAfterThePick = Bug4BarRendering.bar(
            companionManager: companionManager, exchange: theXcodeConversation
        )

        #expect(
            barAfterThePick.height > barWhileOnlyChatting.height,
            """
            The reader picked \(Bug4FieldScenario.appName) to edit — the coordinator is in \
            \(coordinator.phase) — and the eye's bar is still exactly \
            \(barWhileOnlyChatting.height)pt tall, the same as before the click. Nothing about \
            the edit was added to it: no "\(Bug4FieldScenario.appName) · Ask | Edit" composer \
            header, no edit card, not even a refusal. A guide parked at "Plug in your iPhone \
            and press play" is hiding the entire surface of an edit on a different app.
            """
        )
        #expect(
            barAfterThePick.pixels != barWhileOnlyChatting.pixels,
            """
            The bar drew byte-identical pixels before and after the app was picked. This is \
            "Edit this app click shows nothing", photographed.
            """
        )
    }

    // MARK: 4. The control — the same click, with no guide parked

    /// The same scenario with the one difference that matters: no guide is
    /// parked. The bar grows, because the surface the pick opens is allowed into
    /// the layout.
    ///
    /// This passes on the unfixed code. It is what proves the failure above is
    /// the takeover flag and not a broken harness: same clone, same real click,
    /// same real bar, same measurement — only the parked guide removed.
    @Test("with no guide parked, the very same click does change the bar")
    func theSameClickChangesTheBarWhenNoGuideIsParked() async throws {
        let scenario = try await Bug4FieldScenario.make()
        defer { scenario.tearDown() }
        let companionManager = scenario.companionManager
        #expect(
            !companionManager.guideSessionController.autopilotIsShownAsTakeover,
            "no guide has been started, so nothing should be flagged as a takeover"
        )

        let theXcodeConversation = Bug4BarRendering.theReadersXcodeExchange()
        let barBeforeTheClick = Bug4BarRendering.bar(
            companionManager: companionManager, exchange: theXcodeConversation
        )

        let section = Bug4SettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()

        let coordinator = companionManager.onDemandEditCoordinator
        try #require(
            coordinator.activeAppSlug == scenario.appSlug && coordinator.phase != .pickApp,
            "the click did not pick the app (phase \(coordinator.phase))"
        )

        let barAfterTheClick = Bug4BarRendering.bar(
            companionManager: companionManager, exchange: theXcodeConversation
        )
        #expect(
            barAfterTheClick.height > barBeforeTheClick.height,
            """
            Even with no guide in the way the bar did not grow after the pick \
            (\(barBeforeTheClick.height)pt → \(barAfterTheClick.height)pt, phase \
            \(coordinator.phase)). That is a harness failure, not the reported bug — the \
            measurement cannot see the edit surface at all.
            """
        )
    }

    // MARK: - Waiting

    /// Polls a main-actor condition. The takeover animates on its own clock, so a
    /// fixed sleep is a coin flip on a loaded machine.
    private static func pump(
        within seconds: Double, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}

// MARK: - The reader's machine, rebuilt

/// Everything the reader's Mac had that this bug needs: a real git clone of a
/// real Electron-shaped app inside $HOME, a provenance record saying Iris
/// installed it from source with a guide, and a real inventory service that
/// therefore offers "Edit this app" for it.
@MainActor
private struct Bug4FieldScenario {

    static let appName = "NitroAI"

    let companionManager: CompanionManager
    let inventoryService: AppInventoryService
    let appSlug: String
    let clonePath: String

    static func make() async throws -> Bug4FieldScenario {
        // The reader's slug is literally `nitroai`. This test uses a unique one
        // because the provenance store writes through `UserDefaults.standard`,
        // which the test host shares with the real Iris on this Mac — a test must
        // not leave a fake install record behind under a real app's name.
        // Everything the bug turns on (not in the curated stack table, so the
        // stack is derived by reading the clone) is true of this slug too.
        let appSlug = "nitroai-bug4-\(UUID().uuidString.prefix(8))"
        let clonePath = try makeElectronSourceCloneInsideHome()

        let companionManager = CompanionManager()
        companionManager.installProvenanceStore.recordGuideSourceClone(
            appSlug: appSlug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: Bug4CatalogDirectory(apps: [
                CatalogAppDescriptor(
                    slug: appSlug,
                    name: appName,
                    macBundleId: "com.publik.\(appSlug)",
                    // No published release: the row then draws exactly one
                    // button, "Edit this app", which is the one being clicked.
                    latestReleaseTag: nil
                )
            ]),
            installedApplicationLocator: Bug4InstalledApplicationLocator(
                installedBundlePath: "/Applications/\(appName).app"
            )
        )
        // The same join `CompanionManager` wires: the inventory's advisory
        // `isLocallyEditable` flag comes from the provenance store and nowhere
        // else, so the affordance is offered for exactly the apps Iris may edit.
        inventoryService.localPatchingPermittedForSlug = { slug in
            companionManager.installProvenanceStore.localPatchingIsPermitted(forAppSlug: slug)
        }
        await inventoryService.refreshInventory()

        return Bug4FieldScenario(
            companionManager: companionManager,
            inventoryService: inventoryService,
            appSlug: appSlug,
            clonePath: clonePath
        )
    }

    func tearDown() {
        // `requestOnDemandEdit` brings the eye overlay up if it was hidden, and
        // the manager holds timers and watchers. `stop()` is the app's own way of
        // putting all of that down.
        companionManager.stop()
        Bug4FieldScenario.forgetProvenance(forAppSlug: appSlug)
        try? FileManager.default.removeItem(atPath: clonePath)
    }

    /// A real git repo, clean, inside $HOME, whose `package.json` names Electron
    /// — so `CompanionManager.appStack(forSlug:)` derives `.electron` by READING
    /// it, which is the "derived electron from /Users/akrit/NitroAI" line in the
    /// reader's log — and carrying a build script, so the clone has a rebuild
    /// recipe the eligibility gate can find.
    static func makeElectronSourceCloneInsideHome() throws -> String {
        let repositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iris-bug4-repro", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let repositoryPath = repositoryURL.path
        let packageJSON = #"{"name":"nitroai","version":"1.0.0","private":true,"main":"main.js","#
            + #""scripts":{"build":"true","test":"true"},"#
            + #""devDependencies":{"electron":"^31.0.0"}}"#
            + "\n"
        try packageJSON.write(
            toFile: repositoryPath + "/package.json", atomically: true, encoding: .utf8
        )
        try "require('electron')\n".write(
            toFile: repositoryPath + "/main.js", atomically: true, encoding: .utf8
        )
        git(["init", "-q"], in: repositoryPath)
        git(["config", "user.email", "repro@example.invalid"], in: repositoryPath)
        git(["config", "user.name", "repro"], in: repositoryPath)
        git(["add", "-A"], in: repositoryPath)
        git(["commit", "-qm", "base"], in: repositoryPath)
        return repositoryPath
    }

    /// The test host shares `UserDefaults.standard` with the real app, so the
    /// fake install a test records has to be taken back out again.
    static func forgetProvenance(forAppSlug appSlug: String) {
        let defaultsKey = "iris:maintain:install-provenance"
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var recordsByAppSlug = try? JSONDecoder()
                  .decode([String: RecordedInstallProvenance].self, from: data) else { return }
        recordsByAppSlug.removeValue(forKey: appSlug)
        if let reencoded = try? JSONEncoder().encode(recordsByAppSlug) {
            UserDefaults.standard.set(reencoded, forKey: defaultsKey)
        }
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - The settings panel's app list, in a real window, clicked for real

/// The real `AppInventorySectionView` — the "Your publik apps" section of the
/// menu bar panel — hosted in a real `NSPanel`, wired to the same `onEditApp`
/// closure `CompanionPanelView` passes it.
@MainActor
private final class Bug4SettingsPanelSection {

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>

    /// The width the menu bar panel gives this section.
    private static let panelWidth: CGFloat = 320

    init(scenario: Bug4FieldScenario) {
        let companionManager = scenario.companionManager
        let section = AppInventorySectionView(
            appInventoryService: scenario.inventoryService,
            appLinkService: companionManager.appLinkService,
            // Byte for byte what `CompanionPanelView` supplies (L255-257).
            onEditApp: { installedEntry in
                companionManager.requestOnDemandEdit(forEntry: installedEntry)
            }
        )
        hostingView = NSHostingView(
            rootView: AnyView(section.frame(width: Self.panelWidth))
        )
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: Self.panelWidth,
            height: max(hostingView.fittingSize.height, 1)
        )
        panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hostingView
        // Parked well off any real display: the section has to be in a window to
        // be hit-tested and clicked, and it must not flash over the reader's
        // screen while it is.
        panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        panel.orderFront(nil)
        // SwiftUI installs its representable-backed NSViews on a later runloop
        // turn, so a tree read straight after `orderFront` is read before the
        // button's own view could possibly be in it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Presses "Edit this app" the way a finger does: a real `NSEvent` mouse-down
    /// and mouse-up carrying the panel's own window number, handed to the panel's
    /// `sendEvent`, which is the path a hardware click takes.
    ///
    /// FINDING THE BUTTON. `IrisTinyButtonStyle` ends in `.pointerCursor()`, whose
    /// `PointerCursorNSView` is a real AppKit view laid out over exactly the
    /// button's rectangle — the only handle a SwiftUI `Button` (which has no view
    /// of its own) leaves in the tree. The row is built so that "Edit this app" is
    /// the only such button in the section: the app is not running, so there is no
    /// "Ask it what's wrong", and it has no published release, so there is no
    /// "Update to…".
    func clickEditThisApp() throws {
        var everyView: [NSView] = []
        func collect(_ view: NSView) {
            everyView.append(view)
            for subview in view.subviews { collect(subview) }
        }
        collect(hostingView)

        let pointerCursorViews = everyView.filter {
            String(describing: type(of: $0)) == "PointerCursorNSView"
        }
        let button = try #require(
            pointerCursorViews.count == 1 ? pointerCursorViews.first : nil,
            """
            expected exactly one clickable pill in the app row — the "Edit this app" button — \
            and found \(pointerCursorViews.count). Without a unique handle this test would be \
            clicking something unknown, so it refuses to guess.
            """
        )

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let centre = CGPoint(x: buttonInWindow.midX, y: buttonInWindow.midY)
        func mouseEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: centre, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        if let pressed = mouseEvent(.leftMouseDown) { panel.sendEvent(pressed) }
        if let released = mouseEvent(.leftMouseUp) { panel.sendEvent(released) }
        // The handler runs synchronously off the mouse-up, but it also brings the
        // overlay up and posts two notifications; give those a turn to land before
        // anything is measured.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
}

// MARK: - Photographing the real eye bar

@MainActor
private enum Bug4BarRendering {

    struct RenderedBar {
        let height: CGFloat
        let pixels: Data?
    }

    /// The last of the reader's thirteen Xcode exchanges, so the bar under test is
    /// the bar they were actually looking at: open, with a conversation in it.
    static func theReadersXcodeExchange() -> OverlayEyeExchange {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("why is there no iphone simulator in xcode")
        exchange.registerIrisAnswered(
            "Xcode is still downloading the iOS 26.5 runtime — 632.9 MB of 8.52 GB so far. "
                + "The simulator list stays empty until it finishes.",
            theAnswerIsAFailureMessage: false
        )
        exchange.registerTheReaderWentBackToTheField()
        return exchange
    }

    /// The REAL input bar, laid out in a real window parked far off screen, so
    /// what is measured is what the reader would see rather than what the source
    /// suggests they would.
    static func bar(
        companionManager: CompanionManager,
        exchange: OverlayEyeExchange
    ) -> RenderedBar {
        let view = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: {},
            onTheBarShouldReleaseTheKeyboard: {},
            onTheBarShouldTakeTheKeyboardBack: {},
            onTheBarsMeasuredHeightChanged: { _ in },
            showingTheExchange: exchange
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: max(hostingView.fittingSize.height, 1)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hostingView.layoutSubtreeIfNeeded()

        let measuredHeight = hostingView.fittingSize.height
        var pixels: Data?
        if let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            pixels = representation.representation(using: .png, properties: [:])
        }
        window.orderOut(nil)
        return RenderedBar(height: measuredHeight, pixels: pixels)
    }
}
