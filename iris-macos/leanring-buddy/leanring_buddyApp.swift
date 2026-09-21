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
import UserNotifications

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
final class CompanionAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        // So a tap on the catalog-app-update notification (the only
        // notification Iris ever shows) reaches `userNotificationCenter(_:
        // didReceive:)` below instead of just activating the app with
        // nowhere for that to lead — Iris has no main window for macOS to
        // bring forward on its own.
        UNUserNotificationCenter.current().delegate = self
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        startSparkleUpdater()

        if let guideDeepLinkWaitingForLaunchToFinish {
            self.guideDeepLinkWaitingForLaunchToFinish = nil
            openGuide(fromDeepLink: guideDeepLinkWaitingForLaunchToFinish)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A quit in the middle of an on-demand edit — parked on a consent card,
        // say — must not leave Iris's half-written edits in the reader's clone
        // for the next run to refuse over. Synchronous and sub-second.
        companionManager.recoverAnyOnDemandEditIrisLeftUncommitted(at: "quit")
        companionManager.stop()
    }

    // MARK: - Notifications

    /// Without this, macOS silently drops a notification delivered while Iris
    /// is the active app instead of showing it — the standard
    /// `UNUserNotificationCenterDelegate` gotcha. Iris has no main window to
    /// read as "already looking at this", so the banner + sound always show.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tap on the catalog-app-update notification (the only notification
    /// Iris ever shows). `.clickyShowPanel` is the same mechanism
    /// `OnDemandEditCard` already uses to bring the settings panel forward
    /// from outside `MenuBarPanelManager` — the panel is where "Your publik
    /// apps" and its "Update to…" pill live.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
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
            // The console line above is invisible to a reader who just clicked
            // a link and watched nothing happen — a stale bookmark, a
            // hand-typed `iris://guide/<slug>` with no `?version=`, a copy
            // that dropped a query parameter. This is the only user-visible
            // side of the rejection.
            companionManager.presentDeepLinkRejection(rejection.rejectionMessage)
        }
    }

    private func openGuide(fromDeepLink guideDeepLink: GuideDeepLink) {
        // The bar under the eye comes forward first, so the reader sees the
        // guide loading rather than watching nothing happen after clicking a
        // link. It is the bar and not the menu bar panel because the guide
        // lives at the eye now — posting `.clickyShowPanel` here would open
        // settings and leave the guide with nowhere to appear at all.
        NotificationCenter.default.post(name: .clickySummonAskBar, object: nil)
        Task {
            let guideSessionController = companionManager.guideSessionController
            await guideSessionController.openGuide(fromDeepLink: guideDeepLink)
            // Logged because a link that parses can still fail to open — a
            // retired version, a guide still in review — and the reason lives
            // only in the panel otherwise.
            switch guideSessionController.loadState {
            case .guideIsOpen:
                // Aim the eye at whatever the first visible step is about. The
                // step-change hooks cover every later move; this covers the
                // arrival, which none of them see.
                guideSessionController.refreshPointingForTheOpenStep()
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

    /// Starts the updater only when this build is configured to update itself
    /// from somewhere we control.
    ///
    /// The feed URL and the public key it trusts were inherited verbatim from
    /// the template this app was forked from, and pointed at an unrelated
    /// third party's repository with that project's EdDSA key. Sparkle starts
    /// on launch, so every install asked a stranger for updates and would have
    /// installed anything they signed. Removing the two Info.plist keys closes
    /// that, but a plist is easy to reintroduce by accident — a merge, a
    /// template, a copied file — so the refusal lives here too, where it is
    /// code and has to be argued with rather than merely overwritten.
    ///
    /// Both keys must be present for updates to run at all: a feed with no key
    /// is an unauthenticated download, which is worse than no updates.
    private func startSparkleUpdater() {
        let bundle = Bundle.main
        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let feedURL, !feedURL.isEmpty, let publicKey, !publicKey.isEmpty else {
            irisTrace("sparkle: no feed and/or no public key configured — updater not started")
            return
        }

        // Whatever the feed is, it has to be ours. A signed update from someone
        // else's host is still someone else's code running on this machine.
        let host = URL(string: feedURL)?.host?.lowercased() ?? ""
        let trustedUpdateHosts = ["github.com", "raw.githubusercontent.com", "publikhq.com", "www.publikhq.com"]
        let ownedByUs = feedURL.lowercased().contains("blueturboguy07/iris")
            || host == "publikhq.com" || host == "www.publikhq.com"
        guard trustedUpdateHosts.contains(host), ownedByUs else {
            irisTrace("sparkle: refusing update feed that is not ours — \(host)")
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            irisTrace("sparkle: updater failed to start — \(error)")
        }
    }
}
