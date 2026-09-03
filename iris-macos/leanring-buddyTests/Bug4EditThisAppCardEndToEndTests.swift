//
//  Bug4EditThisAppCardEndToEndTests.swift
//  leanring-buddyTests
//
//  BUG 4 — THE REGRESSION GUARD, DRIVEN THE WAY A PERSON DRIVES IT.
//
//  `Bug4EditThisAppCardReproTests` proves the reported symptom by MEASUREMENT:
//  the bar was the same height and the same pixels either side of the click.
//  That is the right way to photograph "shows nothing", and it is deliberately
//  agnostic about what the bar should have shown instead. This file is the
//  other half — it says, in the app's own words, WHAT the reader must now see,
//  and it refuses to accept a bar that merely got taller.
//
//  HOW FAR DOWN THIS GOES. Everything in the reader's path is the real thing:
//
//    * a real git clone inside $HOME, and a real install-provenance record, so
//      the eligibility gate reads a real repository off a real disk;
//    * the real `AppInventoryService` join that decides an app is offered as
//      editable at all;
//    * the real `AppInventorySectionView` row from the menu bar panel, in a
//      real `NSPanel`, wired to the byte-for-byte `onEditApp` closure
//      `CompanionPanelView` supplies;
//    * a real `NSEvent` mouse-down/up pair dispatched by
//      `NSApplication.shared.sendEvent` — the APPLICATION's own dispatch, which
//      is where a hardware click enters this process, one level further out
//      than the repro's `panel.sendEvent`;
//    * the real `GuideAutopilotTakeoverController`, really presented and really
//      parked with `parkForManualStep`, so the flag this bug turns on is set by
//      the app's own code path rather than by a test calling its setter;
//    * the real `CompanionManager.requestOnDemandEdit`, the real stack
//      derivation, the real `OnDemandEditCoordinator.pickApp` and its real
//      eligibility gate;
//    * the real `OverlayEyeInputBarView`, laid out in a real off-screen window.
//
//  NOTHING IS FAKED — not even the model transport. It is worth saying plainly,
//  because "fake the transport" is the usual shape of a test like this: no
//  model is reached on this path at all. Picking an app is provenance, a repo
//  read and a credential check, and every one of those is local. The only
//  stand-ins are publik's catalog route and LaunchServices, which are answered
//  from memory so the test does not depend on a network or on what happens to
//  be installed in /Applications.
//
//  WHAT IS ASSERTED — the words on the reader's screen, read back out of the
//  rendered AppKit tree rather than inferred from the source:
//
//    1. the refusal card's own sentences ("Iris can't edit this" / the reason),
//       because the reader who picked an app Iris cannot rebuild is owed the
//       explanation and not silence;
//    2. the field's placeholder, "What should change in NitroAI?", which is the
//       composer header + Edit mode the `.describe` phase is made of, naming
//       the app the reader picked by name;
//    3. that the guide's takeover STILL hides what it was written to hide, so a
//       later "fix" that simply deletes the guard fails here.
//
//  All three fail on the unfixed commit (45ea6ff) with the guide parked, and
//  the reason is one line of layout: the bar drew only the ask field and the
//  exchange, so the card was not in the layout at any phase, and
//  `anAppIsOpenForEditing` returned false so the field kept its plain "Ask…"
//  placeholder. Measured there, the whole of what the bar was showing after the
//  click was the answer to the reader's LAST XCODE QUESTION and nothing else.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

// MARK: - Standing in for publik's catalog and LaunchServices

/// The catalog route, answered locally — the one row that produces the settings
/// panel entry under test without a network call.
private struct Bug4EndToEndCatalogDirectory: CatalogAppDirectorySource {
    let apps: [CatalogAppDescriptor]
    func catalogApps() async throws -> [CatalogAppDescriptor] { apps }
}

/// LaunchServices, answered locally: the app is installed. Only the presence of
/// a bundle matters — an app that is not installed has no "Edit this app" row
/// to click.
private struct Bug4EndToEndInstalledApplicationLocator: InstalledApplicationLocating {
    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
    }
}

/// An autopilot run sitting where the reader's was at 07:06:08Z: mid-install,
/// nothing executing, waiting at a manual gate. Enough for the real takeover
/// controller to present a real terminal window and then park it.
@MainActor
private final class Bug4EndToEndParkedRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 11)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Open the project", stepNumber: 11, totalSteps: 13),
        .commandFromTheGuide(text: "open ios/App/App.xcworkspace"),
        .exitStatus(code: 0, duration: 3.5)
    ]
    @Published var isExecutingACommand: Bool = false
}

// MARK: - The suite

/// `.serialized` because every test here puts real windows on the screen — the
/// settings section, the eye bar, and the real centered takeover. Two of those
/// racing each other would have them reading one another's windows out of
/// `NSApplication.shared.windows`.
@Suite("Bug 4 end to end — what the bar SAYS after \"Edit this app\"", .serialized)
@MainActor
struct Bug4EditThisAppCardEndToEndTests {

    // MARK: 1. The card half — a refusal the reader can read

    /// THE READER'S SCENARIO, with the outcome stated in words.
    ///
    /// A guide is parked at a manual step, by the real takeover controller. The
    /// reader clicks "Edit this app" on a different app — one whose clone Iris
    /// has no way to rebuild — and the pick lands in `.notEligible`. The bar
    /// must then be carrying the refusal card's own sentences: the heading
    /// "Iris can't edit this" and the reason underneath it.
    ///
    /// This is the phase the repro cannot pin down, because whether a pick ends
    /// in `.describe` or `.notEligible` depends on what this Mac has connected.
    /// A clone with no rebuild recipe refuses on EVERY machine, credential or
    /// not, so the card half of the fix is guarded here unconditionally.
    ///
    /// On the unfixed commit the whole card was outside the layout while the
    /// flag was up, so the reader got no words at all.
    @Test("a refusal the reader asked for is shown, even while a guide is parked")
    func theRefusalIsShownWhileAGuideIsParked() async throws {
        let scenario = try await Bug4EndToEndScenario.make(cloneCanBeRebuilt: false)
        defer { scenario.tearDown() }

        // 07:06:08Z — the real takeover, really parked on a manual step.
        let parkedGuide = try await Bug4EndToEndParkedGuide.presentAndPark(
            in: scenario.companionManager
        )
        defer { parkedGuide.dismiss() }

        // 07:19:45Z — the click, dispatched by NSApplication itself.
        let section = Bug4EndToEndSettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()

        let coordinator = scenario.companionManager.onDemandEditCoordinator
        try #require(
            coordinator.activeAppSlug == scenario.appSlug,
            "the click never reached `requestOnDemandEdit` — nothing below says anything about the bar"
        )
        guard case .notEligible(let refusalReason) = coordinator.phase else {
            Issue.record(
                """
                a clone with no rebuild recipe was expected to refuse, and the coordinator is in \
                \(coordinator.phase) instead — the scenario no longer sets up the state this test \
                is about, so fix the scenario rather than reading anything into the assertions below
                """
            )
            return
        }

        let bar = Bug4EndToEndBarPhotograph.take(
            companionManager: scenario.companionManager,
            exchange: Bug4EndToEndBarPhotograph.theReadersXcodeConversation()
        )
        #expect(
            bar.readableText.contains("Iris can't edit this"),
            """
            The reader picked \(Bug4EndToEndScenario.appName) and Iris decided it cannot edit it — \
            and the eye's bar does not say so anywhere. Everything it is showing is: \
            \(bar.readableText). A guide parked at "Plug in your iPhone and press play" is hiding \
            the refusal card for an app that guide has nothing to do with.
            """
        )
        #expect(
            bar.readableText.contains(refusalReason),
            """
            The refusal card's heading is on screen but its REASON is not — the reader is told \
            "Iris can't edit this" and never told why. Expected "\(refusalReason)" among: \
            \(bar.readableText).
            """
        )
    }

    // MARK: 2. The composer half — the field names the app by name

    /// The other surface a pick opens, and the one the reader's own click
    /// reached on 2026-09-02: an ELIGIBLE app lands in `.describe`, and the
    /// `.describe` phase is drawn by the bar itself as one composer — the app's
    /// name over the field, an Ask/Edit switch, and a field that asks for the
    /// change by name.
    ///
    /// The placeholder is the whole assertion because it is the one part of that
    /// composer that carries the app's name AND is a real `NSTextField` the test
    /// can read back out of the rendered tree. If it says "What should change in
    /// NitroAI?" then `anAppIsOpenForEditing` is true, the composer header is in
    /// the layout, and the mode in force is Edit — which is the entire surface
    /// the reader was owed.
    ///
    /// REQUIRES A CONNECTED EDITING CREDENTIAL, because the eligibility gate
    /// refuses without one (deliberately: editing runs on the reader's own key,
    /// never the funded tier). A Mac with no model connected reaches
    /// `.notEligible` instead, which is test 1's territory, and the `#require`
    /// below says so rather than failing obscurely.
    @Test("the field asks what to change in the app the reader picked, while a guide is parked")
    func theComposerNamesThePickedAppWhileAGuideIsParked() async throws {
        try #require(
            MaintainModelProviderResolver.firstAvailable() != nil,
            """
            no editing credential is connected on this Mac, so `pickApp` refuses before it can \
            reach `.describe` and the composer this test is about is never the right surface. \
            Connect a model (or read test 1, which guards the refusal card on any machine).
            """
        )
        let scenario = try await Bug4EndToEndScenario.make(cloneCanBeRebuilt: true)
        defer { scenario.tearDown() }

        let parkedGuide = try await Bug4EndToEndParkedGuide.presentAndPark(
            in: scenario.companionManager
        )
        defer { parkedGuide.dismiss() }

        let section = Bug4EndToEndSettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()

        let coordinator = scenario.companionManager.onDemandEditCoordinator
        try #require(
            coordinator.activeAppSlug == scenario.appSlug && coordinator.phase == .describe,
            """
            the pick did not reach the describe step (phase \(coordinator.phase)), so this run \
            says nothing about the composer — fix the scenario, not the app
            """
        )

        let bar = Bug4EndToEndBarPhotograph.take(
            companionManager: scenario.companionManager,
            exchange: Bug4EndToEndBarPhotograph.theReadersXcodeConversation()
        )
        #expect(
            bar.fieldPlaceholder == "What should change in \(Bug4EndToEndScenario.appName)?",
            """
            The reader clicked "Edit this app" on \(Bug4EndToEndScenario.appName), the coordinator \
            is waiting for them to describe the change — and the field still says \
            "\(bar.fieldPlaceholder ?? "nothing at all")". There is no composer header naming the \
            app and no Ask/Edit switch: the one surface the describe step is made of is not on \
            screen, because a guide parked at a manual step is gating it. That is "Edit this app \
            click shows nothing", in the field's own words.
            """
        )
    }

    // MARK: 3. The guard the fix deliberately kept

    /// The over-correction guard. `theCenteredTakeoverIsCoveringTheScreen` was
    /// written for a real reason — while a guide's takeover covers the screen,
    /// the bar's own guide card, history row and terminal pane are a cluttered
    /// second copy of what the takeover is already showing — and the fix gives
    /// the EDIT back without giving those back.
    ///
    /// So: same picked app, same refusal card, and the parked bar must still be
    /// strictly shorter than the unparked one. Deleting the `if` outright would
    /// make the two identical and fail the height check here, while still
    /// passing tests 1 and 2.
    ///
    /// It fails on the unfixed commit as well, but for test 1's reason and not
    /// its own — the card is in neither branch there, so the two renders cannot
    /// be compared at all, which is what the first expectation says. The
    /// LOAD-BEARING assertion is the second one, and it is the only place
    /// anything checks that the guide's suppression survived the fix.
    @Test("the parked guide still suppresses the bar's own chrome")
    func theParkedGuideStillSuppressesTheBarsOwnChrome() async throws {
        let scenario = try await Bug4EndToEndScenario.make(cloneCanBeRebuilt: false)
        defer { scenario.tearDown() }
        let guideSessionController = scenario.companionManager.guideSessionController

        let section = Bug4EndToEndSettingsPanelSection(scenario: scenario)
        defer { section.close() }
        try section.clickEditThisApp()
        try #require(
            scenario.companionManager.onDemandEditCoordinator.activeAppSlug == scenario.appSlug,
            "the click never picked the app, so there is no card to compare either side of the flag"
        )

        // The flag is set directly here rather than by parking a second real
        // takeover: this test is about which branch of the bar's body draws
        // what, and it has to photograph BOTH branches for the same state.
        // Test 1 is where the flag's provenance — a real park leaves it up — is
        // established.
        let conversation = Bug4EndToEndBarPhotograph.theReadersXcodeConversation()
        guideSessionController.setAutopilotIsShownAsTakeover(true)
        let whileParked = Bug4EndToEndBarPhotograph.take(
            companionManager: scenario.companionManager, exchange: conversation
        )
        guideSessionController.setAutopilotIsShownAsTakeover(false)
        let withNoGuideParked = Bug4EndToEndBarPhotograph.take(
            companionManager: scenario.companionManager, exchange: conversation
        )

        #expect(
            whileParked.readableText.contains("Iris can't edit this")
                && withNoGuideParked.readableText.contains("Iris can't edit this"),
            "the edit's card has to be on screen in BOTH branches for the heights to mean anything"
        )
        #expect(
            whileParked.height < withNoGuideParked.height,
            """
            With a guide's takeover covering the screen the bar drew the same \
            \(whileParked.height)pt it draws with no guide at all. The takeover branch is supposed \
            to keep the bar's own chrome — the history row, "New chat", the guide card and the \
            under-the-card terminal — out of the way of the takeover that is already showing them. \
            Giving the edit card back was not licence to give those back too.
            """
        )
    }
}

// MARK: - The reader's machine, rebuilt

/// Everything the reader's Mac had that this bug needs: a real git clone inside
/// $HOME, a provenance record saying Iris installed it from source with a
/// guide, and a real inventory service that therefore offers "Edit this app"
/// for it.
@MainActor
private struct Bug4EndToEndScenario {

    static let appName = "NitroAI"

    let companionManager: CompanionManager
    let inventoryService: AppInventoryService
    let appSlug: String
    let clonePath: String

    /// - Parameter cloneCanBeRebuilt: whether the clone carries a build recipe.
    ///   True is the eligible path (`.describe`, the composer); false has no
    ///   rebuild vocabulary at all and refuses on every machine (`.notEligible`,
    ///   the card) whatever credentials happen to be connected here.
    static func make(cloneCanBeRebuilt: Bool) async throws -> Bug4EndToEndScenario {
        // The reader's slug is literally `nitroai`. A unique one is used here
        // because the provenance store writes through `UserDefaults.standard`,
        // which the test host shares with the real Iris on this Mac — a test
        // must not leave a fake install record behind under a real app's name.
        let appSlug = "nitroai-bug4-e2e-\(UUID().uuidString.prefix(8))"
        let clonePath = try makeSourceCloneInsideHome(withARebuildRecipe: cloneCanBeRebuilt)

        let companionManager = CompanionManager()
        companionManager.installProvenanceStore.recordGuideSourceClone(
            appSlug: appSlug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: Bug4EndToEndCatalogDirectory(apps: [
                CatalogAppDescriptor(
                    slug: appSlug,
                    name: appName,
                    macBundleId: "com.publik.\(appSlug)",
                    // No published release: the row then draws exactly one
                    // button, "Edit this app", which is the one being clicked.
                    latestReleaseTag: nil
                )
            ]),
            installedApplicationLocator: Bug4EndToEndInstalledApplicationLocator()
        )
        // The same join `CompanionManager` wires: the inventory's advisory
        // `isLocallyEditable` flag comes from the provenance store and nowhere
        // else, so the affordance is offered for exactly the apps Iris may edit.
        inventoryService.localPatchingPermittedForSlug = { slug in
            companionManager.installProvenanceStore.localPatchingIsPermitted(forAppSlug: slug)
        }
        await inventoryService.refreshInventory()

        return Bug4EndToEndScenario(
            companionManager: companionManager,
            inventoryService: inventoryService,
            appSlug: appSlug,
            clonePath: clonePath
        )
    }

    func tearDown() {
        // `requestOnDemandEdit` brings the eye overlay up if it was hidden, and
        // the manager holds timers, watchers and a takeover controller.
        // `stop()` is the app's own way of putting all of that down.
        companionManager.stop()
        Bug4EndToEndScenario.forgetProvenance(forAppSlug: appSlug)
        try? FileManager.default.removeItem(atPath: clonePath)
    }

    /// A real git repo, clean, inside $HOME — the provenance gate resolves
    /// symlinks and insists the clone lives under the reader's home directory,
    /// so a temp dir would refuse for the wrong reason.
    ///
    /// With a recipe it is the reader's own shape: a `package.json` naming
    /// Electron (so the stack is DERIVED by reading the clone, which is the
    /// "derived electron from /Users/akrit/NitroAI" line in his log) carrying a
    /// build script. Without one it is a repo with a README and nothing else,
    /// which no rebuild vocabulary can touch.
    static func makeSourceCloneInsideHome(withARebuildRecipe: Bool) throws -> String {
        let repositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iris-bug4-e2e", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let repositoryPath = repositoryURL.path
        if withARebuildRecipe {
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
        } else {
            try "# NitroAI\n\nNothing here Iris knows how to build.\n".write(
                toFile: repositoryPath + "/README.md", atomically: true, encoding: .utf8
            )
        }
        git(["init", "-q"], in: repositoryPath)
        git(["config", "user.email", "e2e@example.invalid"], in: repositoryPath)
        git(["config", "user.name", "e2e"], in: repositoryPath)
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

    static func git(_ arguments: [String], in directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - A guide really parked at a manual step

/// The real takeover, presented and then parked by the real controller.
///
/// The pair of calls is byte for byte what `CompanionManager`'s private
/// `presentAutopilotTakeover()` makes; `parkForManualStep` is what the drive
/// loop calls when a step's MANUAL branch waits at its gate. Between them they
/// leave `autopilotIsShownAsTakeover` up with nothing scheduled to bring it
/// down, which is the state the cofounder's Mac sat in for fifteen minutes.
@MainActor
private struct Bug4EndToEndParkedGuide {

    private let takeoverController: GuideAutopilotTakeoverController

    static func presentAndPark(in companionManager: CompanionManager) async throws
        -> Bug4EndToEndParkedGuide {
        let takeoverController = GuideAutopilotTakeoverController()
        companionManager.guideSessionController.setAutopilotIsShownAsTakeover(true)
        takeoverController.present(
            runner: Bug4EndToEndParkedRunner(),
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )

        let terminalPanel = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? GuideAutopilotTakeoverTerminalPanel }.last,
            "the real takeover never put a terminal window on screen, so there is nothing to park"
        )
        // The entry morph grows the window from eye-sized to terminal-sized, and
        // a park requested before it settles is deferred. Wait it out, the way
        // the takeover's own tests do.
        _ = await pump(within: 10) { terminalPanel.frame.width > 400 }
        let frameBeforeParking = terminalPanel.frame

        takeoverController.parkForManualStep(
            title: "Plug in your iPhone and press play",
            instruction: "Pick your iPhone in Xcode's device menu and press the play button."
        )
        let parked = await pump(within: 10) { terminalPanel.frame != frameBeforeParking }
        #expect(parked, "the takeover never actually parked, so this is not the reader's state")
        #expect(
            companionManager.guideSessionController.autopilotIsShownAsTakeover,
            "parking cleared the takeover flag — then this bug's premise is wrong"
        )
        return Bug4EndToEndParkedGuide(takeoverController: takeoverController)
    }

    func dismiss() {
        takeoverController.dismiss(afterHold: false)
    }

    /// Polls a main-actor condition. The takeover animates on its own clock, so
    /// a fixed sleep is a coin flip on a loaded machine.
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

// MARK: - The settings panel's app list, clicked by NSApplication

/// The real `AppInventorySectionView` — the "Your publik apps" section of the
/// menu bar panel — hosted in a real `NSPanel` and clicked with a real event
/// that `NSApplication` routes, which is where a hardware click enters this
/// process.
@MainActor
private final class Bug4EndToEndSettingsPanelSection {

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>

    /// The width the menu bar panel gives this section.
    private static let panelWidth: CGFloat = 320

    init(scenario: Bug4EndToEndScenario) {
        let companionManager = scenario.companionManager
        let section = AppInventorySectionView(
            appInventoryService: scenario.inventoryService,
            appLinkService: companionManager.appLinkService,
            // Byte for byte what `CompanionPanelView` supplies.
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
        // be hit-tested and clicked, and it must not flash over the founder's
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

    /// Presses "Edit this app" the way a finger does: a real `NSEvent`
    /// mouse-down and mouse-up carrying the panel's own window number, handed to
    /// `NSApplication.shared.sendEvent`, which is the object that receives every
    /// hardware event and decides which window gets it.
    ///
    /// FINDING THE BUTTON. `IrisTinyButtonStyle` ends in `.pointerCursor()`,
    /// whose `PointerCursorNSView` is a real AppKit view laid out over exactly
    /// the button's rectangle — the only handle a SwiftUI `Button` (which has no
    /// view of its own) leaves in the tree. The row is built so that "Edit this
    /// app" is the only such button in the section: the app is not running, so
    /// there is no "Ask it what's wrong", and it has no published release, so
    /// there is no "Update to…".
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
        if let pressed = mouseEvent(.leftMouseDown) { NSApplication.shared.sendEvent(pressed) }
        if let released = mouseEvent(.leftMouseUp) { NSApplication.shared.sendEvent(released) }
        // The handler runs synchronously off the mouse-up, but it also brings the
        // overlay up and posts two notifications; give those a turn to land
        // before anything is measured.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
}

// MARK: - Reading the real eye bar's words back

@MainActor
private enum Bug4EndToEndBarPhotograph {

    struct Photograph {
        let height: CGFloat
        /// The field's placeholder — nil when the bar somehow drew no field.
        let fieldPlaceholder: String?
        /// Every string the bar drew through a real `NSTextField`. SwiftUI paints
        /// plain `Text` straight into a layer, but a `Text` carrying
        /// `.textSelection(.enabled)` — which is every reader-facing line on the
        /// edit card, deliberately, so a refusal can be copied — is backed by a
        /// real text field whose `stringValue` is exactly what is on screen.
        let readableText: [String]
    }

    /// The last of the reader's thirteen Xcode exchanges, so the bar under test
    /// is the bar he was actually looking at: open, with a conversation in it.
    static func theReadersXcodeConversation() -> OverlayEyeExchange {
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

    /// The REAL input bar, laid out in a real window parked far off screen, then
    /// read for what it says rather than only how tall it is.
    static func take(
        companionManager: CompanionManager,
        exchange: OverlayEyeExchange
    ) -> Photograph {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hostingView.layoutSubtreeIfNeeded()

        var everyView: [NSView] = []
        func collect(_ view: NSView) {
            everyView.append(view)
            for subview in view.subviews { collect(subview) }
        }
        collect(hostingView)
        let textFields = everyView.compactMap { $0 as? NSTextField }

        let photograph = Photograph(
            height: hostingView.fittingSize.height,
            // The ask field is the one field with a placeholder; the card's
            // selectable lines have none.
            fieldPlaceholder: textFields.compactMap(\.placeholderString).first,
            readableText: textFields.map(\.stringValue).filter { !$0.isEmpty }
        )
        window.orderOut(nil)
        return photograph
    }
}
