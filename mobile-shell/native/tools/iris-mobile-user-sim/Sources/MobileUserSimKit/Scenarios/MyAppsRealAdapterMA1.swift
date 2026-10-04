import CryptoKit
import Darwin
import Foundation
import IrisMobileShellCore

// MA5-persona-sim. `MyAppsShellGlue` stands in for the shell code MA2 and
// the integrator will write around MA1 (SPEC section 6, integration point
// 1): load once at launch, run every person action through MA1's REAL
// `MyAppsOrganizationReducer`, save the whole document through MA1's REAL
// `MyAppsOrganizationFile`, and draw through MA1's REAL
// `MyAppsScreen.sections(input:)`. Nothing here re-implements a rule MA1
// owns; nothing here decides whether MA1 was right (the Python oracle does).
//
// Faults reach MA1 only the way the world would deliver them:
// - Disk full: the per-process file size limit (RLIMIT_FSIZE) is lowered
//   for exactly one save, so the write fails partway through with EFBIG,
//   the same partial-write outcome ENOSPC produces. SIGXFSZ is ignored so
//   the process survives, as an app does.
// - Crash between the temporary write and the rename: MA1's own production
//   seam (`MyAppsFileFaultInjector`, `.afterTempWriteBeforeRename`). The
//   scenario then relaunches, because the process died.
// - Corrupt, truncated or newer-version files: the world writes those bytes
//   to disk before a relaunch (see `MyAppsScenario.swift`); MA1's `load()`
//   runs unmodified over them.
// - Clock skew: the world's clock. The glue writes sequence-consistent
//   timestamps (SPEC 5.3: "the file stores the sequence-consistent timestamp
//   the shell wrote"), because MA1's reducer takes the time as a string and
//   leaves that duty to the shell. MA2 must do the same; see HANDOFF.md.

public enum MyAppsSaveResult: Equatable, Sendable {
    case notNeeded
    case ok
    case failed(String)
    case crashed

    var traceValue: String {
        switch self {
        case .notNeeded: return "none"
        case .ok: return "ok"
        case .failed: return "failed"
        case .crashed: return "crashed"
        }
    }
}

public final class MyAppsShellGlue {
    public let root: URL
    private var file: MyAppsOrganizationFile
    public private(set) var arrangement: MyAppsArrangement = .empty
    public private(set) var noticeShown = false
    public private(set) var versionTooNew = false
    public private(set) var lastLoadMilliseconds: Double = 0
    private var lastStampSecond: Int?
    private var crashOnNextSave = false
    private var diskFullLimitOnNextSave: Int?

    public init(root: URL) throws {
        self.root = root
        self.file = try MyAppsOrganizationFile(root: root)
        launch()
    }

    public var mainFileURL: URL { root.appendingPathComponent("my-apps.json") }
    public var parkedFileURL: URL { root.appendingPathComponent("my-apps.json.v1") }
    public var badFileURL: URL { root.appendingPathComponent("my-apps.json.bad") }

    private func launch() {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = file.load()
        lastLoadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        arrangement = result.arrangement
        noticeShown = result.wasQuarantined
        versionTooNew = result.versionTooNew
        // The newest timestamp already on file, so a relaunch keeps writing
        // later ones even when the clock went backwards.
        let stamps = arrangement.apps.values.flatMap { [$0.lastOpenedAt, $0.installedAt] }.compactMap { $0 }
        lastStampSecond = stamps.compactMap(Self.parseSecond).max()
    }

    /// A force quit and reopen: a fresh file object, one `load()`, nothing
    /// carried over from memory.
    public func relaunch() throws {
        file = try MyAppsOrganizationFile(root: root)
        crashOnNextSave = false
        diskFullLimitOnNextSave = nil
        launch()
    }

    public func armCrashOnNextSave() { crashOnNextSave = true }
    public func armDiskFullOnNextSave(limitBytes: Int) { diskFullLimitOnNextSave = max(1, limitBytes) }

    /// Runs each action through MA1's reducer in order (Select mode sends
    /// many at once), keeps the accepted results in memory like the screen
    /// would, and saves the whole document once if anything changed.
    public func perform(_ actions: [MyAppsAction]) -> (outcomes: [String], save: MyAppsSaveResult) {
        var outcomes: [String] = []
        var anyAccepted = false
        for action in actions {
            switch MyAppsOrganizationReducer.apply(action, to: arrangement) {
            case .success(let outcome):
                arrangement = outcome.arrangement
                outcomes.append("accepted")
                anyAccepted = true
            case .failure(let error):
                outcomes.append("rejected:\(error)")
            }
        }
        guard anyAccepted else { return (outcomes, .notNeeded) }
        return (outcomes, save())
    }

    private func save() -> MyAppsSaveResult {
        let crash = crashOnNextSave
        let limit = diskFullLimitOnNextSave
        crashOnNextSave = false
        diskFullLimitOnNextSave = nil
        let fault = MyAppsFileFaultInjector(point: crash ? .afterTempWriteBeforeRename : .none)
        let previousLimit = limit.map(Self.lowerFileSizeLimit(to:))
        defer { if let previousLimit { Self.restoreFileSizeLimit(previousLimit) } }
        do {
            try file.save(arrangement, fault: fault)
            return .ok
        } catch is MyAppsFileFaultInjector.Triggered {
            return .crashed
        } catch {
            return .failed("\(error)")
        }
    }

    /// A timestamp for `recordOpened` / `recordInstalled` that is never
    /// earlier than, or equal to, one already written (whole seconds, the
    /// file's ISO 8601 resolution).
    public func stamp(worldNow: Date) -> String {
        var second = Int(worldNow.timeIntervalSince1970.rounded(.down))
        if let last = lastStampSecond, second <= last { second = last + 1 }
        lastStampSecond = second
        return Self.format(Date(timeIntervalSince1970: TimeInterval(second)))
    }

    public func sections(
        apps: [MyAppsSimApp],
        categories: [MyAppsSimCategory]?,
        needsDownload: Set<String>,
        sort: MyAppsSort,
        query: String,
        now: Date
    ) -> (output: MyAppsSectionsOutput, milliseconds: Double) {
        let online = categories != nil
        let inputs = apps.map { app in
            MyAppsAppInput(
                identity: app.identity,
                originalName: app.originalName,
                descriptionLine: online ? app.description : "",
                categoryIds: online ? app.categoryIds : [],
                sizeBytes: app.sizeBytes,
                hasUpdate: false,
                isBlocked: false,
                hasCatalogSlug: online,
                needsDownload: needsDownload.contains(app.identity)
            )
        }
        let categoryInputs = (categories ?? []).map { MyAppsCategoryInput(id: $0.id, name: $0.name, order: $0.order) }
        let input = MyAppsSectionsInput(apps: inputs, categories: categoryInputs, arrangement: arrangement, sort: sort, query: query, now: now)
        let start = DispatchTime.now().uptimeNanoseconds
        let output = MyAppsScreen.sections(input: input)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return (output, elapsed)
    }

    // MARK: Helpers

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseSecond(_ text: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { Int($0.timeIntervalSince1970.rounded(.down)) }
    }

    private static let ignoreFileSizeSignal: Void = {
        _ = signal(SIGXFSZ, SIG_IGN)
    }()

    private static func lowerFileSizeLimit(to bytes: Int) -> rlimit {
        _ = ignoreFileSizeSignal
        var current = rlimit()
        getrlimit(RLIMIT_FSIZE, &current)
        var lowered = current
        lowered.rlim_cur = rlim_t(bytes)
        setrlimit(RLIMIT_FSIZE, &lowered)
        return current
    }

    private static func restoreFileSizeLimit(_ previous: rlimit) {
        var previous = previous
        setrlimit(RLIMIT_FSIZE, &previous)
    }
}

/// What is on disk right now, for the trace: each of the three files the
/// spec names, as a SHA-256 plus (only when it changed since the last
/// snapshot) the compressed bytes, so the Python oracle parses the real
/// bytes itself.
final class MyAppsFileSnapshotter {
    private var lastSentSha: [String: String] = [:]

    func snapshot(glue: MyAppsShellGlue) -> [String: Any] {
        var out: [String: Any] = [:]
        out["main"] = describe(glue.mainFileURL, key: "main")
        out["v1"] = describe(glue.parkedFileURL, key: "v1")
        out["bad"] = describe(glue.badFileURL, key: "bad")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: glue.root.path)) ?? []
        out["tmp"] = entries.filter { $0.hasPrefix("my-apps.json.tmp-") }.count
        return out
    }

    private func describe(_ url: URL, key: String) -> Any {
        guard let data = try? Data(contentsOf: url) else { return NSNull() }
        let sha = Self.sha256(data)
        var entry: [String: Any] = ["sha": sha, "n": data.count]
        if lastSentSha[key] != sha {
            entry["z"] = Self.compressedBase64(data)
            lastSentSha[key] = sha
        }
        return entry
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw DEFLATE (Python: `zlib.decompress(b, -15)`), base64.
    static func compressedBase64(_ data: Data) -> String {
        if let compressed = try? (data as NSData).compressed(using: .zlib) as Data {
            return compressed.base64EncodedString()
        }
        return ""
    }
}
