import Foundation
import IrisMobileShellCore

/// No app-name allowlist and no JavaScript/native message bridge. Authority is
/// the verified revision plus a current main-frame request in its content root.
enum NativeMediaPermissionPolicy {
    static let maximumItems = NativeMediaImportPolicy.maximumItems
    // The picker's own byte limits live in NativeMediaImportPolicy: images
    // keep a fixed cap, video has no fixed cap at all (round 3, long-clip
    // import -- free space is the only limit; see
    // NativeMediaImportPolicy.evaluateSpace and NativeSelectedMediaLease).
    // This constant stays as the ceiling for exports (NativeMediaExportPolicy),
    // a single flat cap unrelated to picked-media import, unchanged by that
    // work.
    static let maximumFileBytes = 2 * 1024 * 1024 * 1024

    static func allows(
        capability: String, requestedCapabilities: [String], isValid: Bool,
        isMainFrame: Bool, frameURL: URL?, contentRoot: URL
    ) -> Bool {
        guard isValid, isMainFrame, requestedCapabilities.contains(capability),
              let frameURL, frameURL.isFileURL else { return false }
        let root = contentRoot.standardizedFileURL.pathComponents
        let file = frameURL.standardizedFileURL.pathComponents
        return file.count > root.count && Array(file.prefix(root.count)) == root
    }
}
