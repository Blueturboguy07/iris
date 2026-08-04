//
//  AppLinkDiscovery.swift
//  leanring-buddy
//
//  Which publik apps are running *right now*, and where to reach them.
//
//  One JSON file per running app in `~/Library/Application Support/publik/run`.
//  This is Chrome's `DevToolsActivePort` pattern, and it is here because it is
//  the only local discovery mechanism that also answers the question a log file
//  never could: is the app alive. One directory listing gives the socket path,
//  liveness and a version to negotiate against, all at once.
//
//  The app that writes these files is `packages/app-link/lib/runfile.js`.
//

import Foundation

/// One running app, as announced by its instance file.
nonisolated struct AppLinkInstance: Equatable, Sendable, Identifiable {
    let appId: String
    let appSlug: String?
    let appName: String
    let appVersion: String?
    let protocolVersion: String
    let socketPath: String
    let processIdentifier: pid_t
    /// Regenerated on every launch. Compared against what the app says on
    /// connect, which is what catches a recycled PID.
    let instanceId: String
    /// A cheap second factor, not a boundary — any process running as this user
    /// can read the file it came from. Never logged, never shown.
    let token: String
    let startedAt: String?

    var id: String { appId }

    /// True when the app is new enough to understand us. A protocol version we
    /// do not know is a reason to stop, not to try anyway.
    var speaksAKnownProtocol: Bool { protocolVersion == AppLinkProtocol.version }

    init?(json: [String: Any]) {
        guard
            let appId = json["appId"] as? String,
            let socketPath = json["socketPath"] as? String,
            let instanceId = json["instanceId"] as? String,
            let token = json["token"] as? String,
            let pid = json["pid"] as? Int
        else {
            return nil
        }
        self.appId = appId
        self.appSlug = json["appSlug"] as? String
        self.appName = json["appName"] as? String ?? appId
        self.appVersion = json["appVersion"] as? String
        self.protocolVersion = json["protocolVersion"] as? String ?? "0"
        self.socketPath = socketPath
        self.processIdentifier = pid_t(pid)
        self.instanceId = instanceId
        self.token = token
        self.startedAt = json["startedAt"] as? String
    }

    init(
        appId: String,
        appSlug: String? = nil,
        appName: String,
        appVersion: String? = nil,
        protocolVersion: String = AppLinkProtocol.version,
        socketPath: String,
        processIdentifier: pid_t,
        instanceId: String,
        token: String,
        startedAt: String? = nil
    ) {
        self.appId = appId
        self.appSlug = appSlug
        self.appName = appName
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.processIdentifier = processIdentifier
        self.instanceId = instanceId
        self.token = token
        self.startedAt = startedAt
    }
}

/// Answers "is that PID something we could still be talking to".
///
/// Injectable because the alternative is a test that depends on which processes
/// happen to exist on the machine running it.
nonisolated protocol ProcessLivenessChecking: Sendable {
    func isRunning(_ pid: pid_t) -> Bool
}

nonisolated struct SystemProcessLivenessChecker: ProcessLivenessChecking {
    init() {}

    /// Signal 0 runs the existence and permission checks without delivering
    /// anything. ESRCH means gone; EPERM means it exists but belongs to another
    /// user, which cannot be one of our apps, so it is stale for our purposes.
    func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

nonisolated enum AppLinkDiscovery {
    /// `~/Library/Application Support/publik/run`, matching `paths.js`.
    static func defaultRunDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("publik/run", isDirectory: true)
    }

    /// Every app announcing itself, stale entries dropped.
    ///
    /// A file whose process is gone is deleted on the way past. It is only
    /// tidiness — every reader checks liveness — but a directory full of ghosts
    /// is how people stop trusting the mechanism.
    static func runningInstances(
        in directory: URL? = nil,
        fileManager: FileManager = .default,
        liveness: any ProcessLivenessChecking = SystemProcessLivenessChecker()
    ) -> [AppLinkInstance] {
        let runDirectory = directory ?? defaultRunDirectory(fileManager: fileManager)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var instances: [AppLinkInstance] = []
        for entry in entries where entry.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: entry),
                let object = try? JSONSerialization.jsonObject(with: data),
                let json = object as? [String: Any],
                let instance = AppLinkInstance(json: json)
            else {
                // A half-written or corrupt file is not worth failing discovery
                // over. It will be replaced on the app's next launch.
                continue
            }

            guard liveness.isRunning(instance.processIdentifier) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            instances.append(instance)
        }
        return instances.sorted { $0.appId < $1.appId }
    }

    static func runningInstance(
        appId: String,
        in directory: URL? = nil,
        fileManager: FileManager = .default,
        liveness: any ProcessLivenessChecking = SystemProcessLivenessChecker()
    ) -> AppLinkInstance? {
        runningInstances(in: directory, fileManager: fileManager, liveness: liveness)
            .first { $0.appId == appId }
    }
}
