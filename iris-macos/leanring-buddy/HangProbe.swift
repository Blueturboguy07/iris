//
//  HangProbe.swift
//  leanring-buddy
//
//  Answers one question from outside a process: is the frontmost catalog app
//  responding? A hung app enumerates its windows fine (the window server
//  holds those), so window presence proves nothing — the only honest probe
//  is asking the app's own main thread for something, with a timeout.
//
//  Mechanism: `AXUIElementSetMessagingTimeout` bounds how long an AX read may
//  block, and a hung target answers `kAXErrorCannotComplete` or eats the
//  whole timeout. The probe runs on its own serial queue (never the main
//  thread — Iris must not hang measuring a hang), and only escalates after
//  N consecutive failures: a long import, a first-run indexing pass, and a
//  compile all look exactly like a hang from outside for a few seconds.
//
//  The caller decides WHEN to probe (frontmost catalog app, screen static —
//  that gating is the incident coordinator's job); this file only knows HOW.
//

import AppKit
import ApplicationServices
import Foundation

/// The probe's verdict about one process, delivered after each tick.
enum HangProbeVerdict: Equatable, Sendable {
    /// The app answered the probe within the timeout.
    case responsive
    /// Failed probes so far, below the escalation threshold.
    case unresponsiveButBelowThreshold(consecutiveFailures: Int)
    /// N consecutive failures: this is a hang worth asking about. Carries
    /// how long the app has been unresponsive, for the ask's wording.
    case confirmedHang(unresponsiveSeconds: Int)
    /// The app exited between ticks — the crash watcher's business now.
    case processDisappeared
}

@MainActor
final class HangProbe {

    /// Apple's spinner heuristics run at 2–4 seconds, which is far too eager
    /// for an external observer with no visibility into legitimate work.
    /// Four failed probes at the tick interval is ~8–10s of confirmed
    /// silence before anything escalates.
    static let consecutiveFailuresBeforeConfirming = 4
    static let probeTimeoutSeconds: Float = 1.5

    /// Delivered on the main actor after every probe tick.
    var onVerdict: ((_ processIdentifier: pid_t, _ verdict: HangProbeVerdict) -> Void)?

    /// The AX work happens here so a probe eating its full timeout never
    /// stalls Iris's own UI — the quick/slow split alt-tab-style switchers
    /// use for exactly this reason.
    private let probeQueue = DispatchQueue(label: "iris.maintain.hang-probe", qos: .utility)

    private var consecutiveFailuresByProcess: [pid_t: Int] = [:]
    private var firstFailureAtByProcess: [pid_t: Date] = [:]
    /// One probe per pid in flight, ever — a stacked-up queue of probes
    /// against a hung app would deliver a burst of stale verdicts when it
    /// finally recovers.
    private var probeInFlightForProcess: Set<pid_t> = []

    /// Ask the target's main thread for its focused window, bounded by the
    /// messaging timeout. Call on every tick while the gate conditions hold;
    /// forget-state is automatic when the answer comes back healthy.
    func probe(processIdentifier: pid_t) {
        guard !probeInFlightForProcess.contains(processIdentifier) else { return }
        guard NSRunningApplication(processIdentifier: processIdentifier) != nil else {
            forget(processIdentifier: processIdentifier)
            onVerdict?(processIdentifier, .processDisappeared)
            return
        }
        probeInFlightForProcess.insert(processIdentifier)

        probeQueue.async { [weak self] in
            let element = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.probeTimeoutSeconds)
            var focusedWindow: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                element, kAXFocusedWindowAttribute as CFString, &focusedWindow
            )
            // Anything the app itself answered — even "no focused window",
            // even "attribute unsupported" — proves the main thread is alive.
            // Only a timeout-shaped failure counts against it.
            let mainThreadAnswered = result != .cannotComplete

            Task { @MainActor [weak self] in
                self?.record(processIdentifier: processIdentifier, answered: mainThreadAnswered)
            }
        }
    }

    /// The app left the gate (backgrounded, quit, screen changed): its
    /// counters must not survive to poison the next observation window.
    func forget(processIdentifier: pid_t) {
        consecutiveFailuresByProcess[processIdentifier] = nil
        firstFailureAtByProcess[processIdentifier] = nil
        probeInFlightForProcess.remove(processIdentifier)
    }

    private func record(processIdentifier: pid_t, answered: Bool) {
        probeInFlightForProcess.remove(processIdentifier)

        if answered {
            let hadConfirmed = (consecutiveFailuresByProcess[processIdentifier] ?? 0)
                >= Self.consecutiveFailuresBeforeConfirming
            forget(processIdentifier: processIdentifier)
            // Recovery after a confirmed hang is itself signal — the ask
            // happens after the fact, never mid-hang, so the coordinator
            // needs to hear the app came back.
            if hadConfirmed {
                irisTrace("maintain: hang recovered pid=\(processIdentifier)")
            }
            onVerdict?(processIdentifier, .responsive)
            return
        }

        let failures = (consecutiveFailuresByProcess[processIdentifier] ?? 0) + 1
        consecutiveFailuresByProcess[processIdentifier] = failures
        if firstFailureAtByProcess[processIdentifier] == nil {
            firstFailureAtByProcess[processIdentifier] = Date()
        }

        if failures >= Self.consecutiveFailuresBeforeConfirming {
            let since = firstFailureAtByProcess[processIdentifier] ?? Date()
            let unresponsiveSeconds = Int(Date().timeIntervalSince(since).rounded())
            irisTrace("maintain: hang confirmed pid=\(processIdentifier) after \(failures) probes, ~\(unresponsiveSeconds)s")
            onVerdict?(processIdentifier, .confirmedHang(unresponsiveSeconds: unresponsiveSeconds))
        } else {
            onVerdict?(processIdentifier, .unresponsiveButBelowThreshold(consecutiveFailures: failures))
        }
    }
}
