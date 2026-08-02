//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    /// A guide link that arrived before the panel existed. macOS can deliver
    /// the URL that launched the app before `applicationDidFinishLaunching`
    /// runs, and opening a guide into a panel that has not been created yet
    /// would drop the link on the floor.
    private var guideDeepLinkWaitingForLaunchToFinish: GuideDeepLink?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Iris: Starting...")
        print("🎯 Iris: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()

        if let guideDeepLinkWaitingForLaunchToFinish {
            self.guideDeepLinkWaitingForLaunchToFinish = nil
            openGuide(fromDeepLink: guideDeepLinkWaitingForLaunchToFinish)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    // MARK: - Deep links

    /// Every `iris://` link the OS hands this app. The link is parsed by
    /// `IrisDeepLinkParser` before any of it is applied, so a malformed link
    /// can never partially take effect.
    func application(_ application: NSApplication, open urls: [URL]) {
        for incomingURL in urls {
            handleIncomingDeepLink(incomingURL)
        }
    }

    private func handleIncomingDeepLink(_ incomingURL: URL) {
        switch IrisDeepLinkParser.parse(incomingURL) {
        case .success(.guide(let guideDeepLink)):
            print("🎯 Iris: accepted guide deep link — slug \(guideDeepLink.slug), "
                  + "version \(guideDeepLink.version), "
                  + "branch \(guideDeepLink.branchKey ?? "none"), "
                  + "step \(guideDeepLink.stepIndex.map(String.init) ?? "none")")
            guard menuBarPanelManager != nil else {
                guideDeepLinkWaitingForLaunchToFinish = guideDeepLink
                return
            }
            openGuide(fromDeepLink: guideDeepLink)

        case .success(.authCallback):
            // Sign-in callbacks are delivered privately to the
            // `ASWebAuthenticationSession` that started the sign-in, which is
            // where `AccountService` already handles them. One arriving here
            // means no session is waiting for it, and exchanging the code a
            // second time would burn a single-use code for nobody.
            print("🎯 Iris: ignoring a sign-in callback with no sign-in waiting for it")

        case .failure(let rejection):
            print("⚠️ Iris: rejected deep link — \(rejection.rejectionMessage)")
        }
    }

    private func openGuide(fromDeepLink guideDeepLink: GuideDeepLink) {
        // The panel comes forward first so the reader sees the guide loading
        // rather than watching nothing happen after clicking a link.
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
        Task {
            let guideSessionController = companionManager.guideSessionController
            await guideSessionController.openGuide(fromDeepLink: guideDeepLink)
            // Logged because a link that parses can still fail to open — a
            // retired version, a guide still in review — and the reason lives
            // only in the panel otherwise.
            switch guideSessionController.loadState {
            case .guideIsOpen:
                print("🎯 Iris: opened guide \(guideDeepLink.slug) at "
                      + "step \(guideSessionController.currentStepIndex + 1) of "
                      + "\(guideSessionController.numberOfStepsInTheSelectedBranch)")
            case .guideCouldNotBeLoaded(_, let userFacingMessage):
                print("⚠️ Iris: guide \(guideDeepLink.slug) did not open — \(userFacingMessage)")
            case .noGuideIsOpen, .guideIsLoading:
                break
            }
        }
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Iris: Registered as login item")
            } catch {
                print("⚠️ Iris: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Iris: Sparkle updater failed to start: \(error)")
        }
    }
}
