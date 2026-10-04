import Foundation

/// Fakes the device's free-storage boundary at exactly one real call site:
/// `NativeRevisionStore.stageIntoTemporaryDirectory` creates a fresh
/// "<staging-uuid>/content" directory before writing any of a new revision's
/// bytes (mobile-shell/native/Sources/IrisMobileShellCore/NativeRevisionStore.swift:332-333).
/// Everything else about staging (validation, atomic move, cleanup on
/// failure, the active pointer never advancing) is the real, unmodified
/// `NativeRevisionStore` running against this `FileManager` subclass.
///
/// Limitation, stated plainly for the integrator: production code writes a
/// file's bytes with `Data.write(to:)`, which does not go through the
/// injected `FileManager` at all, so this cannot gate storage byte-for-byte
/// mid-write. It gates the one directory-creation call that must happen
/// before any of those writes for a given staging attempt, which is enough to
/// prove the real "refuse the update, old version still opens, no partial
/// revision left behind" behavior without mounting a real quota-limited
/// volume (which would need Finder-visible disk-image mounts this harness's
/// hard rules forbid touching).
public final class LowStorageFileManager: FileManager, @unchecked Sendable {
    private let world: DeviceWorld
    private let lock = NSLock()
    private var pendingWriteBytes: Int?
    private var pendingWriteLabel: String?

    public init(world: DeviceWorld) {
        self.world = world
        super.init()
    }

    /// Arms the next staging-content-directory creation to consult the
    /// world's free space for exactly `requestedBytes`. Call this
    /// immediately before the one `stage(...)` call it should gate; it
    /// disarms itself after firing once, so an unrelated later directory
    /// creation is never charged against a stale armed value.
    public func armNextStagingWrite(label: String, requestedBytes: Int) {
        lock.lock()
        pendingWriteBytes = requestedBytes
        pendingWriteLabel = label
        lock.unlock()
    }

    public override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if isStagingContentDirectory(url) {
            lock.lock()
            let bytes = pendingWriteBytes
            let label = pendingWriteLabel ?? "stage-content"
            pendingWriteBytes = nil
            pendingWriteLabel = nil
            lock.unlock()
            if let bytes {
                let granted = world.attemptStorageWrite(label: label, requestedBytes: bytes)
                guard granted else {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteOutOfSpaceError,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Simulated device has insufficient free storage to stage this update.",
                        ]
                    )
                }
            }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    private func isStagingContentDirectory(_ url: URL) -> Bool {
        url.lastPathComponent == "content"
            && url.deletingLastPathComponent().lastPathComponent.hasPrefix(".staging-")
    }
}
