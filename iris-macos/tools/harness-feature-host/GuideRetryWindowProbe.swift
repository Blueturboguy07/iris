// Manual native-window probe for the surfaced-step retry controls.
//
// This is deliberately outside build.mjs and is not an installed Iris Test
// app. Compile it with GuideSessionControllerRetryConcurrencyTests.swift and
// -D GUIDE_RETRY_WINDOW_PROBE against a headless IrisHarnessNative module. It
// presents the real GuideAutopilotTakeoverController and
// GuideAutopilotTerminalView around the same suspended shell fixture used by
// the executable controller regressions.
//
// The small companion window has one probe-only action: release the held
// environment refresh after the reader presses the real terminal "Try again"
// control. The terminal's Try again, Continue, yellow minimize, and red stop
// controls remain the production controls. This checks native window
// visibility and stop behavior only; it is not installed Iris Test or full
// Kneecap acceptance.

#if GUIDE_RETRY_WINDOW_PROBE
import AppKit
import SwiftUI

#if IRIS_HARNESS_STANDALONE
@testable import IrisHarnessNative
#else
@testable import Iris
#endif

@main
@MainActor
struct GuideRetryWindowProbeMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = GuideRetryWindowProbeApplicationDelegate()
        application.delegate = delegate
        application.activate(ignoringOtherApps: true)
        application.run()
    }
}

@MainActor
final class GuideRetryWindowProbeApplicationDelegate: NSObject, NSApplicationDelegate {
    private var fixture: GuideRetryWindowProbeFixture?
    private var takeover: GuideAutopilotTakeoverController?
    private var probeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        Task { await prepareControlledFixture() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        fixture?.controller.stopAutopilot()
        takeover?.dismiss(afterHold: false, onlyIfOwnedBy: .guideInstall)
        if let fixture {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
    }

    private func prepareControlledFixture() async {
        do {
            let fixture = try GuideSessionControllerRetryConcurrencyTests.makeWindowProbeFixture()
            self.fixture = fixture
            await fixture.controller.openLatestVersionOfGuide(slug: "retry-concurrency")
            fixture.controller.startAutopilot()

            let surfaced = await pump {
                fixture.controller.currentStepIndex == 1
                    && fixture.controller.autopilotHandedTheCurrentStepToTheReader
            }
            guard surfaced, let runner = fixture.controller.autopilotRunner else {
                showFailure("The controlled fixture did not surface its retry step.")
                return
            }

            let takeover = GuideAutopilotTakeoverController()
            self.takeover = takeover
            fixture.controller.setAutopilotIsShownAsTakeover(true)
            guard takeover.present(
                runner: runner,
                onApproveRiskyCommand: { [weak self] in
                    self?.fixture?.controller.approveThePendingRiskyCommand()
                },
                onSkipRiskyCommand: { [weak self] in
                    self?.fixture?.controller.skipThePendingRiskyCommand()
                },
                onRetrySurfacedStep: { [weak self] in
                    self?.fixture?.controller.retryTheSurfacedStep()
                },
                onContinuePastSurfacedStep: { [weak self] in
                    self?.fixture?.controller.skipTheSurfacedStepAndContinue()
                },
                onReaderFinishedManualStep: { [weak self] in
                    self?.fixture?.controller.readerFinishedTheGatedStep()
                },
                onEscapeHatch: { [weak self] in
                    self?.stopFromProductionEscapeHatch()
                },
                owner: .guideInstall
            ) else {
                showFailure("The controlled takeover could not be presented.")
                return
            }

            showProbeControls()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            showFailure("Fixture setup stopped: \(error)")
        }
    }

    private func showProbeControls() {
        guard fixture != nil else { return }
        let controls = GuideRetryWindowProbeControls(
            releaseHeldRefresh: { [weak self] in
                self?.fixture?.shell.releaseNextRefresh()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Retry fixture controls"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: controls)
        window.center()
        window.orderFrontRegardless()
        probeWindow = window
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Controlled retry fixture stopped"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func stopFromProductionEscapeHatch() {
        fixture?.controller.abortOrCloseAutopilotFromTheEscapeHatch()
        takeover?.dismiss(afterHold: false, onlyIfOwnedBy: .guideInstall)
    }

    private func pump(
        within seconds: Double = 3,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct GuideRetryWindowProbeControls: View {
    let releaseHeldRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTROLLED FIXTURE ONLY")
                .font(.system(size: 12, weight: .bold))
            Text("This is not installed Iris Test or full Kneecap acceptance.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Press Try again in the terminal, then release its held refresh here.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Button("Release held refresh (probe control)") {
                releaseHeldRefresh()
            }
            .buttonStyle(.borderedProminent)
            Text("Use the terminal's red stop and yellow minimize controls for the native action check.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }
}
#endif
