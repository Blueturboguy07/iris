#if IRIS_HARNESS_HEADLESS
import Foundation

/// Only compiled into the command-line fixture host. Foundation on macOS may
/// ignore TMPDIR, so every fixture write boundary uses this explicit directory.
nonisolated enum HarnessFixtureEnvironment {
    static var sourceRoot: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }

    static var sourceReadDenial: String {
        let quoted = sourceRoot.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "(deny file-read* (subpath \"\(quoted)\"))"
    }

    static var scratchDirectory: URL {
        guard let path = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"] else {
            preconditionFailure("Fixture scratch directory was not configured")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}
#endif
