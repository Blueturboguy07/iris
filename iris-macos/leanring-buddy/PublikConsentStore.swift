//
//  PublikConsentStore.swift
//  leanring-buddy
//
//  The one consent file publik's convention names
//  (docs/publik-sdk-convention.md §4 in the publik repo):
//
//      ~/Library/Application Support/publik/consent.json
//      {"telemetry": false, "install_id": "<uuid>", "updated_at": "…"}
//
//  Iris owns it; catalog apps only read it. This file adds the anonymous usage
//  switch to it (founder, 2026-09-25: "depersonalize the tracking, make it
//  optional, prompt them when they open it, default toggled on") without
//  touching what the file already promised:
//
//    - `telemetry` is crash telemetry and stays OPT-IN. Nothing here ever sets
//      it to true. A file Iris creates starts with `"telemetry": false`, and an
//      existing value is carried through every write untouched.
//    - `install_id` is the random id both kinds of report are keyed by. It is
//      not a user id and it is also the capability that erases this install's
//      history on the server, so it is minted with `UUID()` and nothing else.
//    - Keys Iris does not know about (another client may add one) survive
//      every write.
//
//  The usage keys it adds:
//
//    usage                    true or false. Absent until the disclosure card
//                             has been shown: nothing is counted before then.
//    usage_disclosed_at       when the card first appeared on screen.
//    usage_choice_confirmed   true once the reader pressed Continue or Turn
//                             off, so the card stops asking.
//
//  Thread-safe because the usage monitor reads the switch from its own queue.
//  Reads come from memory; the file is read once, at init, and written only
//  when something changes. It is a couple of hundred bytes.
//

import Foundation

/// Where the anonymous usage switch stands.
nonisolated enum UsageSharingState: Equatable, Sendable {
    /// The disclosure has never been on screen. Nothing is counted.
    case notYetDisclosed
    /// Disclosed, and on — the default once the card has been shown.
    case sharing
    /// The reader turned it off.
    case notSharing
}

nonisolated final class PublikConsentStore: @unchecked Sendable {

    /// `~/Library/Application Support/publik/consent.json`. Iris is not
    /// sandboxed (see leanring-buddy.entitlements), so this is the real
    /// shared location every catalog app reads, not a container copy.
    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("publik", isDirectory: true)
            .appendingPathComponent("consent.json", isDirectory: false)
    }

    private enum Key {
        static let telemetry = "telemetry"
        static let installId = "install_id"
        static let updatedAt = "updated_at"
        static let usage = "usage"
        static let usageDisclosedAt = "usage_disclosed_at"
        static let usageChoiceConfirmed = "usage_choice_confirmed"
    }

    private let fileURL: URL
    private let currentDate: @Sendable () -> Date
    private let lock = NSLock()
    /// The file's contents as last read or written. Only touched under `lock`.
    private var document: [String: Any]

    init(fileURL: URL = PublikConsentStore.defaultFileURL, currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.currentDate = currentDate
        self.document = Self.readDocument(at: fileURL) ?? [:]
    }

    // MARK: - Reading

    var usageSharingState: UsageSharingState {
        lock.lock()
        defer { lock.unlock() }
        switch document[Key.usage] as? Bool {
        case .some(true): return .sharing
        case .some(false): return .notSharing
        case .none: return .notYetDisclosed
        }
    }

    /// True only when counts may be sent right now.
    var isUsageSharingOn: Bool { usageSharingState == .sharing }

    /// Whether the first-open card should still be on screen: it stays until
    /// the reader has pressed one of its two buttons.
    var readerHasAnsweredTheUsageDisclosure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (document[Key.usageChoiceConfirmed] as? Bool) == true
    }

    /// Whether the card has ever been on screen. Decides whether Iris opens its
    /// settings panel at launch so the disclosure is seen at first open.
    var usageDisclosureHasBeenShown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return document[Key.usageDisclosedAt] is String
    }

    /// Crash telemetry's switch, read for completeness. Iris never writes it
    /// to true; see the file note.
    var crashTelemetryIsOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (document[Key.telemetry] as? Bool) == true
    }

    /// The install id, minted and saved the first time it is asked for. The
    /// stored value is used as long as it is a well-formed UUID.
    func installIdentifier() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let stored = document[Key.installId] as? String, UUID(uuidString: stored) != nil {
            return stored.lowercased()
        }
        let minted = UUID().uuidString.lowercased()
        document[Key.installId] = minted
        persistWhileLocked()
        return minted
    }

    // MARK: - Writing

    /// The card has been drawn. From here the switch reads ON unless the reader
    /// turns it off — that is the "default toggled on" the founder asked for,
    /// and it only starts once the disclosure has actually been shown. Does
    /// nothing on the second and later calls.
    func recordThatTheUsageDisclosureWasShown() {
        lock.lock()
        defer { lock.unlock() }
        guard !(document[Key.usageDisclosedAt] is String) else { return }
        document[Key.usageDisclosedAt] = Self.timestamp(currentDate())
        if document[Key.usage] == nil {
            document[Key.usage] = true
        }
        persistWhileLocked()
    }

    /// The reader pressed Continue (with the switch as they left it) or Turn
    /// off, or flipped the switch in settings.
    func recordUsageSharingChoice(isOn: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if !(document[Key.usageDisclosedAt] is String) {
            document[Key.usageDisclosedAt] = Self.timestamp(currentDate())
        }
        document[Key.usage] = isOn
        document[Key.usageChoiceConfirmed] = true
        persistWhileLocked()
    }

    // MARK: - File

    private func persistWhileLocked() {
        // The convention's safe default, written out rather than implied, so a
        // catalog app reading a file Iris created sees an explicit "no".
        if !(document[Key.telemetry] is Bool) {
            document[Key.telemetry] = false
        }
        if !(document[Key.installId] is String) {
            document[Key.installId] = UUID().uuidString.lowercased()
        }
        document[Key.updatedAt] = Self.timestamp(currentDate())

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A consent file that cannot be written leaves the in-memory answer
            // in force for this launch. Nothing about Iris depends on the write.
            print("⚠️ consent.json could not be written: \(error.localizedDescription)")
        }
    }

    private static func readDocument(at fileURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
