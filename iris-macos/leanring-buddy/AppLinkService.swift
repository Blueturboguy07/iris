//
//  AppLinkService.swift
//  leanring-buddy
//
//  What Iris uses to ask a catalog app what it is doing.
//
//  Until now the answer to "cue stopped working" had to be assembled from a
//  screenshot, an accessibility tree and a version number. None of that reaches
//  the reason, which lives in the app's memory: a 403 from a speech model, a
//  global shortcut another application took first, a permission that was never
//  granted. This is the seam that asks.
//
//  PRIVACY: nothing here is written to disk. What an app reports is held for as
//  long as a panel needs it and stops existing when Iris quits. Apps are
//  themselves careful about what they answer with — cue reports a transcript
//  *count*, never the transcript — but that is their guarantee to keep, and
//  this side must not turn a transient answer into a stored one.
//

import Combine
import Foundation

/// Why a question could not be answered, phrased for a person.
nonisolated struct AppLinkFailure: Equatable, Sendable {
    let appId: String
    let message: String
    /// True when the app is reachable but has not been given permission, which
    /// is a different conversation from a failure.
    let needsPermission: Bool
}

/// One app's answer.
nonisolated struct AppLinkReport: Equatable, Sendable, Identifiable {
    let instance: AppLinkInstance
    let verification: AppLinkPeerVerification
    let session: AppLinkSession
    let diagnostics: AppLinkDiagnostics?

    var id: String { instance.appId }

    /// Whether this may be sent anywhere. An unverified peer is anything at all
    /// running under this account claiming to be an app; showing its answer to
    /// the user is fine, and letting it write the public breaks tally is not.
    var mayBeSubmitted: Bool { verification == .codeSignature }

    /// One line for the assistant's context, or nil when there is nothing to say.
    var summaryForAssistant: String? {
        guard let diagnostics else { return nil }
        var lines: [String] = []
        lines.append("\(session.appName) \(diagnostics.appVersion ?? "unknown version") is running.")
        if let state = diagnostics.stateSummary {
            lines.append("state: \(state)")
        }
        if let failure = diagnostics.lastError {
            let frame = failure.frame.map { " in \($0)" } ?? ""
            lines.append("last error: \(failure.message)\(frame)")
        }
        let warnings = diagnostics.events.filter { !$0.isFailure }
        if !warnings.isEmpty {
            lines.append("recent warnings: " + warnings.map(\.message).joined(separator: "; "))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Publishes which publik apps are running and what they say when asked.
@MainActor
final class AppLinkService: ObservableObject {
    /// How Iris identifies itself. The app being asked cannot verify this on
    /// the Node transport, and its consent sheet is written to say so.
    static let clientIdentifier = "com.publikhq.iris"
    static let clientName = "Iris"

    /// Discovery is a directory listing; it costs nothing and can be done on a
    /// timer. Talking to an app is not, and only happens when asked.
    static let discoveryIntervalSeconds: Double = 5

    /// Every app announcing itself right now.
    @Published private(set) var runningInstances: [AppLinkInstance] = []

    /// The most recent answer per app, keyed by bundle identifier.
    @Published private(set) var reports: [String: AppLinkReport] = [:]

    /// The most recent failure per app. Cleared by a successful answer.
    @Published private(set) var failures: [String: AppLinkFailure] = [:]

    @Published private(set) var isQuerying = false

    private let runDirectory: URL?
    private let liveness: any ProcessLivenessChecking
    private var discoveryTask: Task<Void, Never>?

    init(
        runDirectory: URL? = nil,
        liveness: any ProcessLivenessChecking = SystemProcessLivenessChecker()
    ) {
        self.runDirectory = runDirectory
        self.liveness = liveness
    }

    deinit {
        discoveryTask?.cancel()
    }

    // MARK: Discovery

    func refreshRunningInstances() {
        let directory = runDirectory
        let checker = liveness
        runningInstances = AppLinkDiscovery.runningInstances(in: directory, liveness: checker)

        // An app that has quit should not leave a stale answer behind looking
        // like current information.
        let alive = Set(runningInstances.map(\.appId))
        reports = reports.filter { alive.contains($0.key) }
        failures = failures.filter { alive.contains($0.key) }
    }

    func startWatchingForRunningApps() {
        guard discoveryTask == nil else { return }
        refreshRunningInstances()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.discoveryIntervalSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refreshRunningInstances() }
            }
        }
    }

    func stopWatchingForRunningApps() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func runningInstance(forSlug slug: String) -> AppLinkInstance? {
        runningInstances.first { $0.appSlug == slug }
    }

    // MARK: Asking

    /// Ask one app what is going on, prompting the user for read access the
    /// first time.
    ///
    /// The socket work is blocking, so it happens off the main actor and only
    /// the result comes back. `requestReadAccess: false` asks for nothing,
    /// which prompts nobody — useful for finding out whether an app is
    /// reachable at all before putting a sheet in front of someone.
    @discardableResult
    func queryDiagnostics(for instance: AppLinkInstance, requestReadAccess: Bool = true) async -> AppLinkReport? {
        isQuerying = true
        defer { isQuerying = false }

        let scopes = requestReadAccess ? ["read"] : []
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AppLinkReport, AppLinkError> in
            do {
                let connection = try AppLinkConnection.open(
                    to: instance,
                    clientIdentifier: Self.clientIdentifier,
                    clientName: Self.clientName,
                    clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    scopes: scopes
                )
                defer { connection.close() }

                guard let session = connection.session else {
                    return .failure(.connectionClosed)
                }
                // Without the read scope there is nothing to collect, and
                // calling anyway would only earn a -32001.
                let diagnostics = session.canRead ? try connection.captureDiagnostics() : nil
                return .success(
                    AppLinkReport(
                        instance: instance,
                        verification: connection.peerVerification,
                        session: session,
                        diagnostics: diagnostics
                    )
                )
            } catch let error as AppLinkError {
                return .failure(error)
            } catch {
                return .failure(.socketCouldNotBeOpened(reason: error.localizedDescription))
            }
        }.value

        switch outcome {
        case .success(let report):
            reports[instance.appId] = report
            if report.session.canRead {
                failures.removeValue(forKey: instance.appId)
            } else if requestReadAccess {
                failures[instance.appId] = AppLinkFailure(
                    appId: instance.appId,
                    message: "\(instance.appName) has not been given permission to answer Iris. Turn it on under Assistant access in \(instance.appName)'s settings.",
                    needsPermission: true
                )
            }
            return report

        case .failure(let error):
            let needsPermission = {
                if case .remote(let code, _) = error {
                    return code == AppLinkErrorCode.scopeDenied.rawValue || code == AppLinkErrorCode.consentDenied.rawValue
                }
                return false
            }()
            failures[instance.appId] = AppLinkFailure(
                appId: instance.appId,
                message: error.userFacingMessage,
                needsPermission: needsPermission
            )
            return nil
        }
    }

    /// The app the user is looking at, if it is one of ours and it is running.
    func queryDiagnosticsForFrontmostApp(bundleIdentifier: String?) async -> AppLinkReport? {
        guard
            let bundleIdentifier,
            let instance = runningInstances.first(where: { $0.appId == bundleIdentifier })
        else {
            return nil
        }
        return await queryDiagnostics(for: instance)
    }

    /// Context for the assistant about apps that have already answered.
    ///
    /// Deliberately only what is already in hand: composing a prompt must never
    /// be the thing that opens a socket or puts a consent sheet on screen.
    func contextForAssistant() -> String? {
        let summaries = reports.values
            .sorted { $0.instance.appId < $1.instance.appId }
            .compactMap(\.summaryForAssistant)
        guard !summaries.isEmpty else { return nil }
        return "Live status from publik apps on this Mac:\n" + summaries.joined(separator: "\n\n")
    }
}
