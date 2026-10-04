import Foundation
import os

// MARK: - Pure policy (Foundation only; compiles on macOS and iOS)
//
// This half of the file has no AVFoundation or UIKit import so it can be
// exercised by a plain macOS command-line checker
// (tools/shell-audio-checks) without an iOS simulator. The iOS-only half
// below adapts it to the real AVAudioSession and its notifications.

/// What the native shell asks its own audio session to do on behalf of an
/// open fullscreen app. Kept separate from `AVFoundation` so the state
/// machine in `NativeAudioSessionPolicy` never has to import it.
protocol NativeAudioSessionControlling: AnyObject {
    /// Category playback, mode default, no `.mixWithOthers`. Playback
    /// category is what keeps Web Audio audible with the ring/silent
    /// switch on; `.mixWithOthers` would leave the switch free to mute it
    /// in some WebKit configurations, so it is deliberately left out.
    func setPlaybackCategory() throws
    /// Activate or deactivate the session. Deactivating passes
    /// `notifyOthersOnDeactivation` so an app that was ducked for Iris
    /// gets its own audio back.
    func setActive(_ active: Bool) throws
}

/// Owns the shell's one audio-session decision: which open fullscreen app
/// presentation, if any, currently holds the playback category and an
/// active session.
///
/// The tracked state is small on purpose: which presentation is open,
/// whether it asked for a media capability, and which presentation (if
/// any) is the one that actually activated the session. Only that last
/// field decides whether a close call is allowed to deactivate, which is
/// what stops a late close from an app that has already been replaced
/// from cutting off the app that replaced it.
@MainActor
final class NativeAudioSessionPolicy {
    private let controller: NativeAudioSessionControlling
    private let logger = Logger(subsystem: "com.publikhq.iris.mobileshell", category: "audio-session")

    /// The presentation currently considered open: the most recent
    /// `appDidOpen` not yet matched by a same-ID `appDidClose` (or
    /// replaced by a different presentation's `appDidOpen`).
    private(set) var openPresentationID: UUID?
    private var openWantsPlayback = false
    /// The presentation that actually holds the active session, if any.
    /// Only this presentation's close is allowed to deactivate.
    private(set) var activatedPresentationID: UUID?

    /// True once `setPlaybackCategory` and `setActive(true)` have both
    /// succeeded for the presentation in `activatedPresentationID`, and
    /// not yet undone by a deactivate, a failure, or a system
    /// interruption.
    private(set) var isSessionActive = false
    /// True when the most recent attempt to activate the session threw.
    /// Cleared by the next successful activation. Lets a caller (or a
    /// test) observe "another app is holding the session" instead of the
    /// policy silently believing it is active when it is not.
    private(set) var lastActivationFailed = false

    init(controller: NativeAudioSessionControlling) {
        self.controller = controller
    }

    /// True when any requested capability is a media capability. Exact
    /// prefix match on "web.media.", not a substring match: Kneecap
    /// ("web.storage", "web.media.photo-picker", "web.media.export") and
    /// FreeHarmony ("web.media.camera") both qualify; Nut AI, which
    /// declares no "web.media.*" capability, does not.
    static func wantsPlayback(requestedCapabilities: [String]) -> Bool {
        requestedCapabilities.contains { $0.hasPrefix("web.media.") }
    }

    /// An app presentation appeared. A media app sets the playback
    /// category and activates; a non-media app never itself calls into
    /// the session. Reopening the same presentation ID again (a duplicate
    /// `onAppear`, or a retry after a failed activation) never
    /// double-activates. Opening a different presentation while one is
    /// already open is close-then-open: the presentation being replaced
    /// is deactivated first (if it was the one holding the session), so a
    /// same-ID close that arrives later for it finds nothing left to undo.
    func appDidOpen(presentationID: UUID, requestedCapabilities: [String]) {
        let wantsPlayback = Self.wantsPlayback(requestedCapabilities: requestedCapabilities)
        if openPresentationID == presentationID {
            openWantsPlayback = wantsPlayback
            if wantsPlayback, activatedPresentationID != presentationID {
                activate(for: presentationID)
            }
            return
        }
        if let previous = openPresentationID {
            performClose(previous)
        }
        openPresentationID = presentationID
        openWantsPlayback = wantsPlayback
        logger.log("open presentation=\(presentationID.uuidString, privacy: .public) media=\(wantsPlayback, privacy: .public)")
        guard wantsPlayback else { return }
        activate(for: presentationID)
    }

    /// An app presentation went away. Deactivates only when this
    /// presentation ID is still the one on file as open; a close for an
    /// ID that has already been superseded by a newer open (a late
    /// `onDisappear` racing a fast reopen) is a no-op, so it can never
    /// undo whatever replaced it.
    func appDidClose(presentationID: UUID) {
        guard openPresentationID == presentationID else { return }
        performClose(presentationID)
        openPresentationID = nil
        openWantsPlayback = false
    }

    /// The system interrupted the session (for example an incoming
    /// call). iOS already deactivates the session itself; this only
    /// updates the policy's own bookkeeping so a later
    /// `interruptionEnded` knows whether there is anything to resume.
    func interruptionBegan() {
        guard isSessionActive else { return }
        isSessionActive = false
        logger.log("interruption began presentation=\(self.activatedPresentationID?.uuidString ?? "none", privacy: .public)")
    }

    /// The interruption ended. Reactivates only when the system says it
    /// is safe to resume AND a media app is still the one open; an app
    /// closed during the interruption, or an interruption that ended
    /// without `shouldResume`, must not bring audio back on its own.
    func interruptionEnded(shouldResume: Bool) {
        logger.log("interruption ended shouldResume=\(shouldResume, privacy: .public)")
        guard shouldResume, let openID = openPresentationID, openWantsPlayback else { return }
        activate(for: openID)
    }

    /// The media server restarted: every prior session configuration is
    /// gone. Re-applies the category and reactivates if a media app is
    /// still open; otherwise just clears the now-stale bookkeeping.
    func mediaServicesWereReset() {
        logger.log("media services reset")
        guard let openID = openPresentationID, openWantsPlayback else {
            activatedPresentationID = nil
            isSessionActive = false
            return
        }
        activate(for: openID)
    }

    private func performClose(_ presentationID: UUID) {
        guard activatedPresentationID == presentationID else { return }
        deactivate()
    }

    private func activate(for presentationID: UUID) {
        do {
            try controller.setPlaybackCategory()
            try controller.setActive(true)
            activatedPresentationID = presentationID
            isSessionActive = true
            lastActivationFailed = false
        } catch {
            if activatedPresentationID == presentationID { activatedPresentationID = nil }
            isSessionActive = false
            lastActivationFailed = true
            logger.error("activate failed presentation=\(presentationID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func deactivate() {
        do {
            try controller.setActive(false)
        } catch {
            logger.error("deactivate failed: \(String(describing: error), privacy: .public)")
        }
        activatedPresentationID = nil
        isSessionActive = false
    }
}

// MARK: - iOS adapter

#if os(iOS)
import AVFoundation

/// The real `AVAudioSession.sharedInstance()` behind
/// `NativeAudioSessionControlling`.
final class AVAudioSessionController: NativeAudioSessionControlling {
    func setPlaybackCategory() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    func setActive(_ active: Bool) throws {
        if active {
            try AVAudioSession.sharedInstance().setActive(true)
        } else {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Forwards `AVAudioSession` interruption and media-services-reset
/// notifications to the policy on the main actor. Kept alive by
/// `NativeAudioSessionPolicy.shared` for the app's lifetime; NotificationCenter
/// does not retain observers added this way.
@MainActor
final class NativeAudioSessionObserver {
    private static var current: NativeAudioSessionObserver?
    private let policy: NativeAudioSessionPolicy

    static func install(on policy: NativeAudioSessionPolicy) {
        current = NativeAudioSessionObserver(policy: policy)
    }

    private init(policy: NativeAudioSessionPolicy) {
        self.policy = policy
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        let shouldResume: Bool
        if type == .ended {
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        } else {
            shouldResume = false
        }
        Task { @MainActor [policy] in
            switch type {
            case .began: policy.interruptionBegan()
            case .ended: policy.interruptionEnded(shouldResume: shouldResume)
            @unknown default: break
            }
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        Task { @MainActor [policy] in
            policy.mediaServicesWereReset()
        }
    }
}

extension NativeAudioSessionPolicy {
    /// One shared instance for the host, built with the real
    /// `AVAudioSession`-backed controller.
    static let shared: NativeAudioSessionPolicy = {
        let policy = NativeAudioSessionPolicy(controller: AVAudioSessionController())
        NativeAudioSessionObserver.install(on: policy)
        return policy
    }()
}
#endif
