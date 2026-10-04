import Foundation

// MA5-persona-sim (round3/my-apps-organization, SPEC section 5). Shared
// shapes for the My apps persona simulation: the simulated world's apps and
// catalog categories, the trace writer, and the MA1 presence check.
//
// How the pieces fit (takeover rewrite, 2026-09-28):
// - The world (`MyAppsSimWorld` in `MyAppsScenario.swift`) owns the
//   installed apps, the catalog and the clock, and misbehaves on a seeded
//   schedule (`MyAppsWorldFaults.swift`).
// - `MyAppsShellGlue` (`MyAppsRealAdapterMA1.swift`) plays the part of the
//   shell: it calls MA1's REAL reducer, file layer and `MyAppsScreen`
//   unmodified. Faults reach MA1 only through the OS boundary (the file's
//   bytes on disk, a per-process file size limit that makes a write fail
//   partway, the clock) or through MA1's own production crash seam.
// - The persona (`MyAppsPersonaScript.swift`) records what the person
//   meant, step by step, into a JSONL trace. The trace never contains a
//   verdict: `round3/my-apps-organization/tests/oracle_myapps.py`, written
//   in Python from the spec alone, replays it and decides every failure.

/// One installed (or installable) app in the simulated world. The catalog
/// part (`categoryIds`, `description`) is what the store's index would say
/// about the app's slug; `originalName` is the name inside the package.
public struct MyAppsSimApp: Sendable, Equatable {
    public let identity: String
    public var originalName: String
    public var description: String
    public var categoryIds: [Int]
    public var sizeBytes: Int64

    public init(identity: String, originalName: String, description: String, categoryIds: [Int], sizeBytes: Int64) {
        self.identity = identity
        self.originalName = originalName
        self.description = description
        self.categoryIds = categoryIds
        self.sizeBytes = sizeBytes
    }

    var traceObject: [String: Any] {
        ["id": identity, "name": originalName, "desc": description, "cats": categoryIds, "size": sizeBytes]
    }
}

/// One catalog category as the store's index lists it. `order` is the
/// catalog's display order, deliberately NOT equal to `id` in the world,
/// so sorting groups by id instead of by order shows up as a failure.
public struct MyAppsSimCategory: Sendable, Equatable {
    public let id: Int
    public var name: String
    public var order: Int

    public init(id: Int, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }

    var traceObject: [String: Any] { ["id": id, "name": name, "order": order] }
}

/// Writes one JSON object per line. Every event the world, the persona and
/// the shell glue produce goes through here, in order.
public final class MyAppsTraceWriter {
    public let url: URL
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = handle
    }

    public func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            // A non-JSON value here is a harness bug; record it so the
            // oracle fails the run instead of silently skipping a step.
            let fallback = ["e": "harness.error", "detail": "unencodable trace event \(object["e"] ?? "?")"]
            if let data = try? JSONSerialization.data(withJSONObject: fallback) {
                handle.write(data + Data([0x0A]))
            }
            return
        }
        data.append(0x0A)
        handle.write(data)
    }

    public func close() {
        try? handle.close()
    }
}

/// Detects whether unit MA1 has landed, by checking for its owned files on
/// disk relative to this source file (`#filePath`), never the working
/// directory. In this package the check is informational (the package
/// imports `IrisMobileShellCore`, so it cannot even compile without MA1's
/// types); the Python mutation runner uses the same three paths to print
/// `notPresentLine` and skip cleanly before MA1 exists.
public enum MyAppsIntegration {
    public static var isMA1Present: Bool {
        FileManager.default.fileExists(atPath: reducerFileURL.path)
            && FileManager.default.fileExists(atPath: fileLayerFileURL.path)
            && FileManager.default.fileExists(atPath: screenFileURL.path)
    }

    public static var reducerFileURL: URL { myAppsCoreDirectory.appendingPathComponent("MyAppsOrganization.swift") }
    public static var fileLayerFileURL: URL { myAppsCoreDirectory.appendingPathComponent("MyAppsOrganizationFile.swift") }
    public static var screenFileURL: URL { myAppsCoreDirectory.appendingPathComponent("MyAppsScreen.swift") }

    private static var myAppsCoreDirectory: URL {
        // native/tools/iris-mobile-user-sim/Sources/MobileUserSimKit/Scenarios/<this file>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() } // -> native/
        return url
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("IrisMobileShellCore", isDirectory: true)
            .appendingPathComponent("MyApps", isDirectory: true)
    }

    /// The exact words every caller prints when MA1 has not landed.
    public static let notPresentLine = "MA1 not present yet"
}
