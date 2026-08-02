//
//  AppAwarenessService.swift
//  leanring-buddy
//
//  Knows which app the user is actually looking at, so a guide step can say
//  "switch to Terminal" only when they are not already in it. Ported from the
//  macOS half of `foreground_app_identity` in
//  `iris-desktop/src-tauri/src/main.rs` (lines 762-799), which remains the
//  behavioral spec.
//

import AppKit
import Combine
import Foundation

struct ForegroundAppIdentity: Equatable, Sendable {
    /// Always "macos" here. The Tauri shell also answers for Windows; this app
    /// only ever runs on a Mac, so the field exists to keep the shape identical.
    let platform: String
    let processIdentifier: UInt32
    let displayName: String?
    let bundleIdentifier: String?
    let executablePath: String?
}

enum AppAwarenessError: Error, Equatable, Sendable {
    case noForegroundApplicationIsAvailable
}

/// Publishes which app is in front, refreshed on a timer.
///
/// PRIVACY: the foreground app is held in memory only and is never written to
/// disk — not to UserDefaults, not to a log, not to a crash report. It is a
/// running record of what the user is doing on their own machine, and it stops
/// existing the moment the app quits. Do not add persistence here.
@MainActor
final class AppAwarenessService: ObservableObject {
    /// Matches the Tauri panel's cadence (`setInterval(pollForeground, 1600)` in
    /// `iris-desktop/ui/app.js`). Fast enough that a guide notices the reader
    /// switching to Terminal, slow enough to stay invisible in Activity Monitor.
    static let foregroundPollingIntervalSeconds: Double = 1.6

    @Published private(set) var currentForegroundApp: ForegroundAppIdentity?
    @Published private(set) var isPollingForegroundApp = false

    private var foregroundPollingTask: Task<Void, Never>?

    deinit {
        foregroundPollingTask?.cancel()
    }

    /// Reads the frontmost app once, right now. Ported from
    /// `platform_foreground_app` (main.rs:778-799).
    static func currentForegroundApplicationIdentity() throws -> ForegroundAppIdentity {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw AppAwarenessError.noForegroundApplicationIsAvailable
        }

        let processIdentifier = frontmostApplication.processIdentifier
        return ForegroundAppIdentity(
            platform: "macos",
            // A negative pid means AppKit could not identify the process; the
            // Rust conversion lands on zero in the same situation.
            processIdentifier: processIdentifier > 0 ? UInt32(processIdentifier) : 0,
            displayName: frontmostApplication.localizedName,
            bundleIdentifier: frontmostApplication.bundleIdentifier,
            executablePath: frontmostApplication.executableURL?.path
        )
    }

    /// Starts refreshing `currentForegroundApp`. Calling this while already
    /// polling does nothing, so a view appearing twice cannot start two timers.
    func startPollingForegroundApp() {
        guard foregroundPollingTask == nil else {
            return
        }

        isPollingForegroundApp = true
        refreshCurrentForegroundApp()

        let pollingIntervalNanoseconds = UInt64(
            Self.foregroundPollingIntervalSeconds * 1_000_000_000
        )
        foregroundPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
                } catch {
                    // The only error here is cancellation, which the loop
                    // condition handles on the next pass.
                    return
                }
                guard let self = self else {
                    return
                }
                self.refreshCurrentForegroundApp()
            }
        }
    }

    func stopPollingForegroundApp() {
        foregroundPollingTask?.cancel()
        foregroundPollingTask = nil
        isPollingForegroundApp = false
        // Dropping the last reading on stop is deliberate: nothing about the
        // user's screen should outlive the moment Iris stops watching.
        currentForegroundApp = nil
    }

    private func refreshCurrentForegroundApp() {
        // A momentary failure to read the frontmost app (during a Space switch,
        // for instance) leaves the previous reading in place rather than
        // flickering the UI to "nothing in front".
        guard let foregroundApp = try? Self.currentForegroundApplicationIdentity() else {
            return
        }
        if currentForegroundApp != foregroundApp {
            currentForegroundApp = foregroundApp
        }
    }
}
