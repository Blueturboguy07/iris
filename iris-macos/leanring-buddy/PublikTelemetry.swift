// PublikTelemetry.swift — publik telemetry v1 client for Swift 5 (Foundation and URLSession only).
// It sends two usage events to publik: app_opened and active_session. Nothing else.
//
// How to add it:
//   1. Copy this file into your app target or your command-line target.
//   2. Call this once at start-up:
//        PublikTelemetry.start(appSlug: "your-slug", appVersion: "1.2.3")
//   3. Optional: add `keyProvider: { yourPublikKeyOrNil }` to count a signed-in user by account.
//
// Opt-outs: DO_NOT_TRACK=1, PUBLIK_TELEMETRY=0, or "usage": false in <publik dir>/consent.json.
// Docs: https://publikhq.com/skills/telemetry.md
// Public domain (CC0). Copy it into your app.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Every member is `nonisolated`: the client stays off the main actor in every build setting.
public enum PublikTelemetry {
    /// Returns the app's current publik key (`pk_...`), or nil when the user is signed out.
    public typealias KeyProvider = @Sendable () -> String?

    nonisolated private static let endpoint = "https://publikhq.com/api/v1/telemetry"
    nonisolated private static let once = DispatchSemaphore(value: 1) // the first start() takes it
    nonisolated private static let stopSignal = DispatchSemaphore(value: 0)

    /// Sends app_opened on a background thread and starts the 30-minute active_session timer.
    /// A second call does nothing. `keyProvider` runs on the background thread before each send.
    nonisolated public static func start(appSlug: String, appVersion: String, keyProvider: KeyProvider? = nil) {
        guard once.wait(timeout: .now()) == .success else { return }
        let slug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let version = cleanVersion(appVersion)
        let seconds = Double(env("PUBLIK_TELEMETRY_INTERVAL_SECONDS")) ?? 0 // tests only
        let interval = seconds >= 1 && seconds <= 86400 ? seconds : 1800
        Thread.detachNewThread {
            Thread.current.name = "publik-telemetry"
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)
            var installID: String? // one install ID for the whole run
            send("app_opened", slug, version, keyProvider, session, &installID)
            while stopSignal.wait(timeout: .now() + interval) == .timedOut {
                send("active_session", slug, version, keyProvider, session, &installID)
            }
            session.finishTasksAndInvalidate()
        }
    }

    /// The server takes 1 to 64 printable ASCII characters, with no "v" at the start and no space at an end.
    nonisolated private static func cleanVersion(_ value: String) -> String {
        let ascii = String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e })
        let text = String(ascii.drop(while: { "vV ".contains($0) }).prefix(64)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "0" : text
    }

    /// Optional. Stops the timer.
    nonisolated public static func stop() {
        stopSignal.signal()
    }

    /// One attempt: no retry, 5 second limit, never throws. Does not wait for the answer.
    nonisolated private static func send(_ event: String, _ slug: String, _ version: String, _ keyProvider: KeyProvider?, _ session: URLSession, _ installID: inout String?) {
        let debug = env("PUBLIK_TELEMETRY_DEBUG") == "1"
        let say: @Sendable (String) -> Void = { result in
            guard debug, #available(macOS 10.15.4, iOS 13.4, tvOS 13.4, watchOS 6.2, *) else { return }
            try? FileHandle.standardError.write(contentsOf: Data("publik-telemetry: \(event) -> \(result)\n".utf8))
        }
        #if os(macOS)
        let os = "macos"
        #elseif os(Windows)
        let os = "windows"
        #elseif os(Linux)
        let os = "linux"
        #else
        let os = "" // iOS and other systems: telemetry v1 has no `os` value, so nothing is sent
        #endif
        if os.isEmpty { return }
        let dir = publikDir()
        if optedOut(dir) { return say("off (opt-out)") }
        let id = installID ?? loadInstallID(dir)
        installID = id
        var body: [String: Any] = ["v": 1, "app": slug, "install_id": id, "event": event, "app_version": version, "os": os]
        #if arch(arm64)
        body["arch"] = "arm64"
        #elseif arch(x86_64)
        body["arch"] = "x64"
        #endif
        let override = env("PUBLIK_TELEMETRY_URL")
        guard let url = URL(string: override.isEmpty ? endpoint : override), let data = try? JSONSerialization.data(withJSONObject: body) else {
            return say("bad URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = publikKey(dir, slug, keyProvider) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse { say(String(http.statusCode)) } else { say(error?.localizedDescription ?? "error") }
        }.resume()
    }

    nonisolated private static func env(_ name: String) -> String {
        (ProcessInfo.processInfo.environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// <publik dir>: the folder that all publik apps share on this computer account.
    /// On Linux, XDG_CONFIG_HOME counts only when it is an absolute path.
    nonisolated private static func publikDir() -> URL? {
        #if os(Windows)
        let base: URL? = env("LOCALAPPDATA").isEmpty ? nil : URL(fileURLWithPath: env("LOCALAPPDATA"))
        #elseif os(Linux)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base: URL? = env("XDG_CONFIG_HOME").hasPrefix("/") ? URL(fileURLWithPath: env("XDG_CONFIG_HOME")) : home.appendingPathComponent(".config")
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #endif
        return base?.appendingPathComponent("publik")
    }

    nonisolated private static func readJSON(_ file: URL?) -> [String: Any] {
        guard let file = file, let data = try? Data(contentsOf: file) else { return [:] }
        return parseJSON(data)
    }

    /// Foundation reads UTF-8, UTF-16 and UTF-32, with or without a byte-order mark. It fails on
    /// UTF-32LE with a mark, so this function removes that mark. Notepad and PowerShell on Windows
    /// save such files. A Windows "ANSI" file can hold a byte that is not UTF-8: the second try
    /// reads the text with that byte replaced.
    nonisolated private static func parseJSON(_ data: Data) -> [String: Any] {
        let text = data.starts(with: [0xff, 0xfe, 0, 0]) ? Data(data.dropFirst(4)) : data
        if let json = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any] { return json }
        return ((try? JSONSerialization.jsonObject(with: Data(String(decoding: text, as: UTF8.self).utf8))) as? [String: Any]) ?? [:]
    }

    /// Opt-out. Checked before each send, before telemetry.json or the network is used.
    nonisolated private static func optedOut(_ dir: URL?) -> Bool {
        if !["", "0", "false"].contains(env("DO_NOT_TRACK").lowercased()) { return true }
        if ["0", "false", "off"].contains(env("PUBLIK_TELEMETRY").lowercased()) { return true }
        return (readJSON(dir?.appendingPathComponent("consent.json"))["usage"] as? Bool) == false
    }

    /// What telemetry.json holds: (ID, "ok"), or (nil, state). The state is "missing", "unreadable"
    /// (the read failed) or "damaged" (the read worked and the content is not valid).
    nonisolated private static func savedID(_ file: URL) -> (id: String?, state: String) {
        guard let data = try? Data(contentsOf: file) else {
            return (nil, FileManager.default.fileExists(atPath: file.path) ? "unreadable" : "missing")
        }
        // Version 4 only: the server takes no other kind.
        let uuid4 = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        guard let id = parseJSON(data)["install_id"] as? String, id.range(of: uuid4, options: [.regularExpression, .caseInsensitive]) != nil else {
            return (nil, "damaged")
        }
        return (id.lowercased(), "ok")
    }

    /// Saves a new telemetry.json in one step: the full text goes to a temp file, then a hard link gives
    /// it the real name. An app that starts at the same time sees no file or the full file, never an
    /// empty file. Returns "saved", "exists" (another app saved its file first) or "failed".
    nonisolated private static func saveNew(_ file: URL, _ text: Data) -> String {
        let files = FileManager.default
        let name = "\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
        let temp = file.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? files.removeItem(at: temp) }
        guard (try? text.write(to: temp, options: .withoutOverwriting)) != nil else { return "failed" }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if (try? files.linkItem(at: temp, to: file)) != nil { return "saved" }
        if files.fileExists(atPath: file.path) { return "exists" }
        do {
            try text.write(to: file, options: .withoutOverwriting) // no hard links on this disk: plain exclusive create
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return "saved"
        } catch {
            return files.fileExists(atPath: file.path) ? "exists" : "failed"
        }
    }

    /// One random UUID v4 per computer account, in <publik dir>/telemetry.json (mode 0600).
    nonisolated private static func loadInstallID(_ dir: URL?) -> String {
        let fresh = UUID().uuidString.lowercased() // if the file cannot be read or saved, this ID lasts for this run only
        guard let dir = dir else { return fresh }
        let file = dir.appendingPathComponent("telemetry.json")
        let files = FileManager.default
        let created = ISO8601DateFormatter().string(from: Date()) // 2026-11-06T12:00:00Z
        let text = Data("{\"install_id\": \"\(fresh)\", \"created_at\": \"\(created)\"}\n".utf8)
        var replaced = false
        for _ in 0..<3 {
            var saved = savedID(file)
            if saved.state == "damaged" && !replaced {
                Thread.sleep(forTimeInterval: 0.1) // an app with an old client can be in the middle of its save
                saved = savedID(file)
                if saved.state == "damaged" {
                    replaced = true
                    try? files.removeItem(at: file) // the content is not valid: replace the file once
                    if files.fileExists(atPath: file.path) { return fresh }
                    saved = (nil, "missing")
                }
            }
            if let found = saved.id { return found }
            if saved.state != "missing" { return fresh } // the read failed: keep the file
            try? files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if saveNew(file, text) != "exists" { return fresh }
            // another publik app saved its ID first: the next round reads that one
        }
        return fresh
    }

    /// Key order: the app's own publik key, then PUBLIK_API_KEY, then <publik dir>/apps/<slug>.json.
    /// Only a publik key (pk_...) is sent. A provider key such as sk-... is never sent.
    nonisolated private static func publikKey(_ dir: URL?, _ slug: String, _ keyProvider: KeyProvider?) -> String? {
        let safeSlug = slug.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
        let sources: [() -> String?] = [
            { keyProvider?() },
            { ProcessInfo.processInfo.environment["PUBLIK_API_KEY"] },
            { safeSlug ? readJSON(dir?.appendingPathComponent("apps").appendingPathComponent(slug + ".json"))["key"] as? String : nil },
        ]
        for source in sources {
            if let key = source()?.trimmingCharacters(in: .whitespacesAndNewlines), key.range(of: "^pk_[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                return key
            }
        }
        return nil
    }
}
