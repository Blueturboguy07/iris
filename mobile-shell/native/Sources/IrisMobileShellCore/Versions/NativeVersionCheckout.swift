import Darwin
import Foundation

/// `checkouts/<appId>/<projectId>/rev-sha256:<id>/` (SPEC 2.1, 2.3): the
/// launchable tree of a version, built by `clonefile` from `objects/` so
/// WKWebView always loads from a real directory while the store itself stays
/// content-addressed.
public struct NativeVersionCheckoutRecord: Codable, Equatable, Sendable {
    public let cloned: Bool
    public let builtAt: String
    public var verifiedAt: String?
}

public enum NativeVersionCheckoutError: Error, Equatable, Sendable {
    case verificationFailed(String)
}

public struct NativeVersionCheckoutBuilder: Sendable {
    public let root: URL // .../v1/checkouts
    private let objects: NativeObjectStore
    private var fileManager: FileManager { .default }

    public init(root: URL, objects: NativeObjectStore) throws {
        self.root = root
        self.objects = objects
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func revisionDir(appId: String, projectId: String, revisionId: String) -> URL {
        root.appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(revisionId, isDirectory: true)
    }

    public func contentRoot(appId: String, projectId: String, revisionId: String) -> URL {
        revisionDir(appId: appId, projectId: projectId, revisionId: revisionId).appendingPathComponent("content", isDirectory: true)
    }

    public func exists(appId: String, projectId: String, revisionId: String) -> Bool {
        fileManager.fileExists(atPath: revisionDir(appId: appId, projectId: projectId, revisionId: revisionId).path)
    }

    /// Rebuilds a checkout tree from a manifest's files. Every file's
    /// destination is cloned individually (or copied on a volume that
    /// refuses `clonefile`), matching SPEC 2.3 step 2 exactly. The whole
    /// tree is built at a temporary name and renamed into place, so a
    /// concurrent reader (or a crash) never sees a half-built checkout at
    /// the real path.
    @discardableResult
    public func build(
        manifest: NativeVersionManifest,
        appId: String,
        projectId: String,
        now: () -> String = { NativeVersionRefs.iso(Date()) },
        fault: NativeVersionFaultInjector = .init()
    ) throws -> NativeVersionCheckoutRecord {
        let finalDir = revisionDir(appId: appId, projectId: projectId, revisionId: manifest.revisionId)
        if exists(appId: appId, projectId: projectId, revisionId: manifest.revisionId) {
            if let record = try? verify(manifest: manifest, appId: appId, projectId: projectId) {
                return record
            }
            try? fileManager.removeItem(at: finalDir)
        }

        let tmpDir = root.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        let contentDir = tmpDir.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)

        var allCloned = true
        for file in manifest.files {
            let dest = contentDir.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let src = objects.path(forSHA256: file.sha256)
            do {
                let cloned = try nativeCloneOrCopyFile(from: src, to: dest)
                allCloned = allCloned && cloned
            } catch {
                throw NativeVersionCheckoutError.verificationFailed("clone failed for \(file.path): \(error)")
            }
        }

        try verifyExactTree(contentDir, against: manifest)

        let record = NativeVersionCheckoutRecord(cloned: allCloned, builtAt: now(), verifiedAt: now())
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: tmpDir.appendingPathComponent("checkout.json"), options: .atomic)

        try fileManager.createDirectory(at: finalDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(tmpDir.path, finalDir.path) == 0 else {
            let err = errno
            try? fileManager.removeItem(at: tmpDir)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        // The checkout now exists at its real path, cloned, verified and
        // renamed into place: this is "after checkout build" (SPEC 2.4's
        // crash-point list), the moment before the pointer write.
        try fault.fire(.journalWrite_afterCheckoutBuilt)
        return record
    }

    /// Re-verifies an existing checkout against the manifest rather than
    /// rebuilding it (SPEC 2.3: "already present from an earlier switch:
    /// verify it instead of rebuilding").
    @discardableResult
    public func verify(manifest: NativeVersionManifest, appId: String, projectId: String) throws -> NativeVersionCheckoutRecord {
        let dir = revisionDir(appId: appId, projectId: projectId, revisionId: manifest.revisionId)
        let contentDir = dir.appendingPathComponent("content", isDirectory: true)
        try verifyExactTree(contentDir, against: manifest)
        var record = (try? Data(contentsOf: dir.appendingPathComponent("checkout.json")))
            .flatMap { try? JSONDecoder().decode(NativeVersionCheckoutRecord.self, from: $0) }
            ?? NativeVersionCheckoutRecord(cloned: true, builtAt: NativeVersionRefs.iso(Date()), verifiedAt: nil)
        record.verifiedAt = NativeVersionRefs.iso(Date())
        try? JSONEncoder().encode(record).write(to: dir.appendingPathComponent("checkout.json"), options: .atomic)
        return record
    }

    private func verifyExactTree(_ contentDir: URL, against manifest: NativeVersionManifest) throws {
        for file in manifest.files {
            let path = contentDir.appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: path) else {
                throw NativeVersionCheckoutError.verificationFailed("missing \(file.path)")
            }
            guard data.count == file.bytes, NativeObjectStore.hex(data) == file.sha256 else {
                throw NativeVersionCheckoutError.verificationFailed("hash mismatch \(file.path)")
            }
        }
        // No extra files beyond the manifest's table. Paths are taken
        // relative by `enumerator(atPath:)` itself: comparing absolute URL
        // paths against `contentDir.path` breaks whenever the root sits
        // behind a symlink (/var is /private/var on macOS and iOS), because
        // the enumerator reports the resolved spelling. Anything that is not
        // a directory counts as a file (a stray symlink or socket in a
        // checkout is unexpected too, not silently ignored).
        let expected = Set(manifest.files.map(\.path))
        var actual = Set<String>()
        guard let enumerator = FileManager.default.enumerator(atPath: contentDir.path) else {
            throw NativeVersionCheckoutError.verificationFailed("checkout tree unreadable")
        }
        while let relative = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            actual.insert(relative)
        }
        guard actual == expected else {
            throw NativeVersionCheckoutError.verificationFailed("unexpected files in checkout tree")
        }
    }

    /// Deletes the clone tree of a version that is neither current nor
    /// fallback (SPEC 2.3 step 5). Objects stay; only the clone goes.
    public func delete(appId: String, projectId: String, revisionId: String) throws {
        let dir = revisionDir(appId: appId, projectId: projectId, revisionId: revisionId)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }
}
