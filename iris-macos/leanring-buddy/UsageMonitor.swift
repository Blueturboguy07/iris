//
//  UsageMonitor.swift
//  leanring-buddy
//
//  Anonymous usage counts: which catalog apps are opened, which AI provider
//  and tier answer, which guides start and finish. Founder, 2026-09-25:
//  "depersonalize the tracking, make it optional, prompt them when they open
//  it, default toggled on, must not break anything in Iris, nothing should
//  wait for it."
//
//  WHAT AN EVENT CAN HOLD. A catalog slug, one of five event kinds, a provider
//  and a tier as enum values, the OS family, the Iris version, and the HOUR it
//  happened in. That is the whole vocabulary: there is no field for a message,
//  a window title, a path, a model name or an account, so no call site can
//  pass one by accident. The server (`lib/iris-usage-events.ts` in publik)
//  refuses any other field and drops a slug its catalog does not list.
//
//  NOTHING WAITS FOR IT. `record` hops onto a private utility queue and
//  returns. Events are held in memory as counts per (event, hour); a timer on
//  the same queue sends one batch at most every 60 seconds. A send that fails
//  for any reason — offline, a 4xx, a 5xx, a timeout — is DROPPED, never
//  retried and never written to disk. While a send is in flight the next tick
//  is skipped. Nothing in this file is awaited by the UI or by any flow.
//
//  OFF MEANS OFF. The switch is read at record time and again at send time.
//  With it off, nothing is recorded and whatever was held is thrown away.
//

import Foundation

/// The five things that are counted. Raw values are the wire names.
nonisolated enum UsageEventKind: String, Sendable, CaseIterable {
    case appOpened = "app_opened"
    case aiCall = "ai_call"
    case modelSelected = "model_selected"
    case guideStarted = "guide_started"
    case guideCompleted = "guide_completed"
}

/// Which route answered, as the server's enum. Mirrors
/// `AssistantProviderPreference`'s raw values, kept separate so this file has
/// no main-actor dependency.
nonisolated enum UsageProvider: String, Sendable, CaseIterable {
    case publikAPI = "publik-api"
    case anthropicKey = "anthropic-key"
    case codex = "codex"
}

/// publik's three tiers. Iris's picker speaks in Anthropic model names; this
/// is the same coarse mapping `PublikAPIModelAlias` uses, so the count and the
/// gateway agree about what "the tier" was.
nonisolated enum UsageModelTier: String, Sendable, CaseIterable {
    case fast
    case balanced
    case smart

    static func forIrisModelName(_ irisModelName: String) -> UsageModelTier {
        let lowercasedName = irisModelName.lowercased()
        if lowercasedName.contains("haiku") { return .fast }
        if lowercasedName.contains("opus") { return .smart }
        return .balanced
    }
}

/// One thing that happened. Built only from enums and a catalog slug.
nonisolated struct UsageEvent: Hashable, Sendable {
    let kind: UsageEventKind
    let appSlug: String?
    let provider: UsageProvider?
    let modelTier: UsageModelTier?

    init(kind: UsageEventKind, appSlug: String? = nil, provider: UsageProvider? = nil, modelTier: UsageModelTier? = nil) {
        self.kind = kind
        // A slug that is not slug-shaped is dropped here rather than sent and
        // refused: the server would reject the whole batch over it.
        self.appSlug = appSlug.flatMap { UsageEvent.isSlugShaped($0) ? $0 : nil }
        self.provider = provider
        self.modelTier = modelTier
    }

    /// The server's slug rule (`apps.slug`): lowercase letters, digits and
    /// inner hyphens, 1–64 characters.
    static func isSlugShaped(_ candidate: String) -> Bool {
        candidate.range(of: "^[a-z0-9]+(?:[a-z0-9-]{0,62}[a-z0-9])?$", options: .regularExpression) != nil
    }
}

/// Where a batch goes. The real one is `URLSessionUsageEventSender`; tests
/// substitute a recorder.
nonisolated protocol UsageEventSending: Sendable {
    /// Send one batch. `completion` is called exactly once with whether the
    /// server accepted it; the monitor drops the batch either way.
    func sendBatch(_ jsonBody: Data, completion: @escaping @Sendable (Bool) -> Void)
    /// Ask the server to erase every count this install sent (the switch was
    /// turned off). Fire and forget.
    func eraseEverythingSent(byInstallIdentifier installIdentifier: String)
}

nonisolated final class UsageMonitor: @unchecked Sendable {

    struct Configuration: Sendable {
        /// Read at record time and at send time.
        let isSharingEnabled: @Sendable () -> Bool
        /// The consent.json install id.
        let installIdentifier: @Sendable () -> String
        /// "0.9.15". A version that is not three numbers is padded; one that
        /// cannot be read at all turns sending off, since the server would
        /// refuse every batch.
        let irisVersion: String
        /// "macos" or "windows".
        let operatingSystem: String
        let sender: UsageEventSending
        let currentDate: @Sendable () -> Date
        /// At most one send per this many seconds.
        let flushInterval: TimeInterval
        /// How many distinct (event, hour) counts are held between sends.
        /// Anything new past this is dropped until the next send.
        let maximumDistinctCountsHeld: Int
    }

    /// Past this the server refuses a row (`MAX_COUNT_PER_EVENT`).
    static let largestCountTheServerAccepts = 500
    /// The server's batch cap (`MAX_USAGE_EVENTS_PER_BATCH`).
    static let largestBatchTheServerAccepts = 50

    /// The app-wide monitor. Inert until `configure` has run, so a call site
    /// that fires before launch finishes simply records nothing.
    static let shared = UsageMonitor()

    private struct HeldCountKey: Hashable {
        let event: UsageEvent
        let hourBucket: String
    }

    private let workQueue: DispatchQueue
    // Everything below is touched only on `workQueue`.
    private var configuration: Configuration?
    private var heldCounts: [HeldCountKey: Int] = [:]
    /// Arrival order, so a batch is sent oldest-first and a truncated batch
    /// drops the newest rather than an arbitrary set.
    private var heldCountOrder: [HeldCountKey] = []
    private var aSendIsInFlight = false
    private var flushTimer: DispatchSourceTimer?
    /// How many events were thrown away (cap, off, failed send). For tests
    /// and for the log line; never sent anywhere.
    private var droppedEventCount = 0

    init(workQueue: DispatchQueue = DispatchQueue(label: "com.publikhq.iris.usage-monitor", qos: .utility)) {
        self.workQueue = workQueue
    }

    // MARK: - Setup

    func configure(_ configuration: Configuration) {
        workQueue.async { self.configuration = configuration }
    }

    /// Starts the send timer. Safe to call more than once.
    func start() {
        workQueue.async {
            guard self.flushTimer == nil, let configuration = self.configuration else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
            timer.schedule(
                deadline: .now() + configuration.flushInterval,
                repeating: configuration.flushInterval,
                leeway: .seconds(5)
            )
            timer.setEventHandler { [weak self] in self?.sendWhatIsHeld() }
            self.flushTimer = timer
            timer.resume()
        }
    }

    func stop() {
        workQueue.async {
            self.flushTimer?.cancel()
            self.flushTimer = nil
        }
    }

    // MARK: - Recording

    /// Counts one event. Returns immediately; never throws; never blocks.
    func record(_ event: UsageEvent) {
        workQueue.async {
            guard let configuration = self.configuration else { return }
            guard configuration.isSharingEnabled() else {
                self.throwAwayEverythingHeld()
                return
            }
            let key = HeldCountKey(
                event: event,
                hourBucket: Self.hourBucket(for: configuration.currentDate())
            )
            if let existingCount = self.heldCounts[key] {
                self.heldCounts[key] = min(existingCount + 1, Self.largestCountTheServerAccepts)
                return
            }
            guard self.heldCounts.count < configuration.maximumDistinctCountsHeld else {
                self.droppedEventCount += 1
                return
            }
            self.heldCounts[key] = 1
            self.heldCountOrder.append(key)
        }
    }

    /// The switch was turned off: forget what is held, and ask the server to
    /// forget what it has.
    func sharingWasTurnedOff() {
        workQueue.async {
            self.throwAwayEverythingHeld()
            guard let configuration = self.configuration else { return }
            configuration.sender.eraseEverythingSent(byInstallIdentifier: configuration.installIdentifier())
        }
    }

    // MARK: - Sending

    private func sendWhatIsHeld() {
        guard let configuration else { return }
        guard configuration.isSharingEnabled() else {
            throwAwayEverythingHeld()
            return
        }
        guard !aSendIsInFlight, !heldCountOrder.isEmpty else { return }
        guard let irisVersion = Self.threePartVersion(configuration.irisVersion) else {
            throwAwayEverythingHeld()
            return
        }

        let keysToSend = Array(heldCountOrder.prefix(Self.largestBatchTheServerAccepts))
        let events: [[String: Any]] = keysToSend.map { key in
            var entry: [String: Any] = [
                "event": key.event.kind.rawValue,
                "os": configuration.operatingSystem,
                "irisVersion": irisVersion,
                "hourBucket": key.hourBucket,
                "count": heldCounts[key] ?? 1,
            ]
            if let appSlug = key.event.appSlug { entry["appSlug"] = appSlug }
            if let provider = key.event.provider { entry["provider"] = provider.rawValue }
            if let modelTier = key.event.modelTier { entry["modelTier"] = modelTier.rawValue }
            return entry
        }
        // Whatever did not fit in this batch is dropped with it: the next
        // minute starts from nothing rather than growing a backlog.
        droppedEventCount += max(0, heldCountOrder.count - keysToSend.count)
        heldCounts.removeAll()
        heldCountOrder.removeAll()

        let body: [String: Any] = ["installId": configuration.installIdentifier(), "events": events]
        guard let jsonBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }

        aSendIsInFlight = true
        configuration.sender.sendBatch(jsonBody) { [weak self] _ in
            // Accepted or not, the batch is gone. See the file note.
            self?.workQueue.async { self?.aSendIsInFlight = false }
        }
    }

    private func throwAwayEverythingHeld() {
        droppedEventCount += heldCounts.values.reduce(0, +)
        heldCounts.removeAll()
        heldCountOrder.removeAll()
    }

    // MARK: - Wire format helpers

    /// The hour an event happened in, UTC: "2026-09-25T14:00:00Z".
    static func hourBucket(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:00:00Z",
            components.year ?? 1970, components.month ?? 1, components.day ?? 1, components.hour ?? 0
        )
    }

    /// "0.9" → "0.9.0", "0.9.15" → itself, "1.2.3.4" → "1.2.3", "dev" → nil.
    static func threePartVersion(_ version: String) -> String? {
        let numericParts = version.split(separator: ".").map(String.init)
        guard !numericParts.isEmpty,
              numericParts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let padded = (numericParts + ["0", "0", "0"]).prefix(3)
        return padded.joined(separator: ".")
    }

    // MARK: - For tests

    /// Runs one send tick now, on the monitor's own queue, and waits for it.
    func sendNowAndWaitForTesting() {
        workQueue.sync { self.sendWhatIsHeld() }
    }

    /// Waits for every queued `record` to land.
    func drainForTesting() {
        workQueue.sync {}
    }

    var heldCountsForTesting: [UsageEvent: Int] {
        workQueue.sync {
            var byEvent: [UsageEvent: Int] = [:]
            for (key, count) in heldCounts { byEvent[key.event, default: 0] += count }
            return byEvent
        }
    }

    var droppedEventCountForTesting: Int { workQueue.sync { droppedEventCount } }
    var aSendIsInFlightForTesting: Bool { workQueue.sync { aSendIsInFlight } }
}

// MARK: - The real sender

/// POSTs a batch to `{publik}/api/telemetry/usage`. Ephemeral session: no
/// cookies, no cache, no credential of any kind — a usage count has no
/// account, so nothing that could identify one is attached.
nonisolated struct URLSessionUsageEventSender: UsageEventSending {
    let endpoint: URL
    let session: URLSession

    init(publikBaseURL: URL) {
        self.endpoint = publikBaseURL.appendingPathComponent("api/telemetry/usage")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func sendBatch(_ jsonBody: Data, completion: @escaping @Sendable (Bool) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        session.dataTask(with: request) { _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(error == nil && (200..<300).contains(statusCode))
        }.resume()
    }

    func eraseEverythingSent(byInstallIdentifier installIdentifier: String) {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "install_id", value: installIdentifier)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        session.dataTask(with: request) { _, _, _ in }.resume()
    }
}
