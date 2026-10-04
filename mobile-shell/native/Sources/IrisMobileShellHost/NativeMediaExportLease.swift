import Foundation
import Darwin
import IrisMobileShellCore

/// One bounded download in a private, marker-owned directory. This custody is
/// temporary: it is not app storage, an installer, or the user's Save destination.
/// The download session must cancel its writer before releasing this lease.
final class NativeMediaExportLease: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case closed, unsafeFile, invalidSize, alreadyReserved, io, full
        /// RC-09a (apple-compliance/REQUIRED_CHANGES.md, M-03): a real,
        /// free-space-based rejection, distinct from `.invalidSize` (which
        /// now only means "over the hard ceiling", see `maximumBytes`).
        case notEnoughSpace(requiredBytes: Int64, availableBytes: Int64)
    }
    /// RC-09a: was a flat 32 MB (AUDIT.md M-03: "a video editor whose
    /// exports fail" -- Kneecap could import a two-minute clip under the
    /// free-space rule and then be unable to export it at all). Raised to
    /// the same hard ceiling `NativeMediaExportPolicy`'s own upfront
    /// response check already uses (`maximumExportBytes`, 2 GiB via
    /// `NativeMediaPermissionPolicy.maximumFileBytes`) so the two checks
    /// agree instead of the lease silently being far stricter than the
    /// policy that already approved the response. This is a hard ceiling,
    /// not a target: unlike import (which has no fixed cap at all), export
    /// keeps one, because Save to Photos/Files makes its own destination
    /// copy on top of this lease's copy, and nothing here can observe or
    /// bound that destination copy's own size the way import's batch
    /// bookkeeping can. The free-space check just below this is what
    /// actually raises the *effective* limit for an ordinary device with
    /// real headroom; this ceiling is the backstop for a device that
    /// somehow has a great deal of the disk free.
    static let maximumBytes = Int(NativeMediaExportPolicy.maximumExportBytes)
    static let rootName = "iris-media-export-v1"
    static let markerName = ".iris-export-lease-v1"
    static let lockName = ".iris-export-lease.lock"
    static let marker = Data("iris-media-export-lease-v1\n".utf8)
    private static let rootMarkerName = ".iris-export-root-v1"
    private static let rootMarker = Data("iris-media-export-root-v1\n".utf8)
    private static let registryLock = NSLock()
    private static var live: Set<String> = []

    private let mutex = NSLock()
    private let directory: URL
    private var lockFD: Int32
    private var closed = false
    private var reservation: (url: URL, bytes: Int)?

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        let prepared = try Self.prepare(parent: parent)
        directory = prepared.0
        lockFD = prepared.1
    }

    deinit { close() }
    var directoryForTesting: URL { directory }

    /// `availableBytesOverride` is nil in every real call site (the default):
    /// production always reads the real volume, fresh, right here. A test
    /// passes an explicit value so the free-space branch is deterministic
    /// (real available space on a CI/dev machine varies, and unlike import,
    /// export keeps a fixed hard ceiling, so sizing a real fixture file
    /// relative to real free space the way the import test does cannot
    /// reliably reach the insufficient-space branch on a machine with a lot
    /// of free space -- see `NativeMediaExportAdversarialTests.swift`).
    func reserve(expectedBytes: Int, fileExtension: String, availableBytesOverride: Int64? = nil) throws -> URL {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed else { throw Failure.closed }
        guard reservation == nil else { throw Failure.alreadyReserved }
        guard (1...Self.maximumBytes).contains(expectedBytes) else { throw Failure.invalidSize }
        // RC-09a (M-03): a real free-space check, "in line with import"
        // (the same `evaluateSpace` formula `NativeSelectedMediaLease` uses,
        // called here for a single file with nothing else already
        // committed). Read fresh, right before this reservation, same as
        // the import side. `availableBytes == nil` (the volume stat could
        // not be read) stays optimistic, matching import's own documented
        // behavior for that case: it does not block an export just because
        // one stat call failed.
        let availableBytes: Int64? = availableBytesOverride ?? (try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage)
        if let availableBytes,
           case .insufficient(let requiredBytes, let stillAvailable) = NativeMediaImportPolicy.evaluateSpace(
               alreadyCommittedBytes: 0, addingBytes: Int64(expectedBytes), availableBytes: availableBytes
           ) {
            throw Failure.notEnoughSpace(requiredBytes: requiredBytes, availableBytes: stillAvailable)
        }
        guard (1...8).contains(fileExtension.utf8.count),
              fileExtension.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              ownsCurrentDirectory(using: lockFD) else {
            throw Failure.unsafeFile
        }
        // WKDownload requires a destination that does not exist yet. The private
        // parent and unguessable name prevent accepting a caller-provided path.
        let url = directory.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT else { throw Failure.unsafeFile }
        reservation = (url, expectedBytes)
        return url
    }

    func validatedFile() throws -> URL {
        mutex.lock()
        defer { mutex.unlock() }
        guard !closed else { throw Failure.closed }
        guard let reservation, ownsCurrentDirectory(using: lockFD) else {
            throw Failure.unsafeFile
        }
        let fd = open(reservation.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0, info.st_nlink == 1,
              info.st_size == Int64(reservation.bytes),
              info.st_size > 0, info.st_size <= Int64(Self.maximumBytes) else {
            throw Failure.unsafeFile
        }
        return reservation.url
    }

    func close() {
        mutex.lock()
        guard !closed else { mutex.unlock(); return }
        closed = true
        reservation = nil
        let fd = lockFD
        lockFD = -1
        mutex.unlock()
        // Never follow or delete a substituted/unknown directory. If exact owned
        // removal fails, the next lease will reap it or fail closed.
        if ownsCurrentDirectory(using: fd) {
            try? FileManager.default.removeItem(at: directory)
        }
        Self.registryLock.lock()
        Self.live.remove(directory.path)
        Self.registryLock.unlock()
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }

    private static func prepare(parent: URL) throws -> (URL, Int32) {
        guard parent.isFileURL else { throw Failure.unsafeFile }
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard ownedDirectory(parent, privateOnly: false) else { throw Failure.unsafeFile }
        let root = parent.appendingPathComponent(rootName, isDirectory: true)
        let created = mkdir(root.path, 0o700) == 0
        guard created || errno == EEXIST else { throw Failure.io }
        guard ownedDirectory(root) else { throw Failure.unsafeFile }
        if created { try writeMarker(root.appendingPathComponent(rootMarkerName), bytes: rootMarker) }
        guard exactMarker(root.appendingPathComponent(rootMarkerName), bytes: rootMarker) else {
            throw Failure.unsafeFile
        }
        let rootFD = open(root.appendingPathComponent(".iris-export-root.lock").path,
                          O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard rootFD >= 0 else { throw Failure.io }
        defer { _ = flock(rootFD, LOCK_UN); _ = Darwin.close(rootFD) }
        guard ownedFile(rootFD), flock(rootFD, LOCK_EX) == 0 else { throw Failure.unsafeFile }
        guard ownedDirectory(root), exactMarker(root.appendingPathComponent(rootMarkerName), bytes: rootMarker) else {
            throw Failure.unsafeFile
        }
        try reap(in: root)
        let directory = root.appendingPathComponent("lease-" + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.io }
        var leaseFD: Int32 = -1
        do {
            try writeMarker(directory.appendingPathComponent(markerName), bytes: marker)
            leaseFD = open(directory.appendingPathComponent(lockName).path,
                           O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard leaseFD >= 0, ownedFile(leaseFD), flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.io }
            registryLock.lock()
            live.insert(directory.path)
            registryLock.unlock()
            return (directory, leaseFD)
        } catch {
            if leaseFD >= 0 { _ = Darwin.close(leaseFD) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func ownsCurrentDirectory(using fd: Int32) -> Bool {
        guard fd >= 0, Self.ownedFile(fd), Self.ownedDirectory(directory),
              Self.exactMarker(directory.appendingPathComponent(Self.markerName), bytes: Self.marker) else { return false }
        var held = stat(), atPath = stat()
        guard fstat(fd, &held) == 0,
              lstat(directory.appendingPathComponent(Self.lockName).path, &atPath) == 0,
              (atPath.st_mode & S_IFMT) == S_IFREG,
              atPath.st_uid == geteuid(), (atPath.st_mode & 0o077) == 0,
              atPath.st_nlink == 1 else { return false }
        // An exact copied marker is not sufficient evidence of directory identity.
        // It must still contain the same private lock inode held by this lease.
        return held.st_dev == atPath.st_dev && held.st_ino == atPath.st_ino
    }

    private static func reap(in root: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard children.count <= 128 else { throw Failure.full }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("lease-"), let uuid = UUID(uuidString: String(name.dropFirst(6))),
                  name == "lease-" + uuid.uuidString,
                  ownedDirectory(child), exactMarker(child.appendingPathComponent(markerName), bytes: marker) else { continue }
            registryLock.lock()
            let isLive = live.contains(child.path)
            registryLock.unlock()
            if isLive { continue }
            let lockURL = child.appendingPathComponent(lockName)
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                // Root lock excludes another creator between marker and lock.
                guard errno == ENOENT else { throw Failure.unsafeFile }
                try removeStale(child)
                continue
            }
            defer { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
            guard ownedFile(fd) else { throw Failure.unsafeFile }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Failure.io }
                continue
            }
            guard ownedDirectory(child), exactMarker(child.appendingPathComponent(markerName), bytes: marker) else {
                throw Failure.unsafeFile
            }
            try removeStale(child)
        }
    }

    private static func removeStale(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch { throw Failure.full }
    }

    private static func ownedDirectory(_ url: URL, privateOnly: Bool = true) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid() && (!privateOnly || (info.st_mode & 0o077) == 0)
    }

    private static func ownedFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0 && info.st_nlink == 1
    }

    private static func exactMarker(_ url: URL, bytes: Data) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard ownedFile(fd) else { return false }
        return (try? handle.read(upToCount: bytes.count + 1)) == bytes
    }

    private static func writeMarker(_ url: URL, bytes: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
    }
}
