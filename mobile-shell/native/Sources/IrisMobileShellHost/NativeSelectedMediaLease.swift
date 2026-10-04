import Foundation
import IrisMobileShellCore
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

/// A narrow public surface so the app's own launch path (a different module
/// from this one; see `app-entry-typecheck.sh`) can trigger the stale
/// picker-media-lease sweep on startup without gaining access to
/// `NativeSelectedMediaLease`'s full internal API. Wiring the one call this
/// needs at app startup is outside this task's owned files (`IrisMobileShellApp.swift`
/// is not owned here); this task's HANDOFF.md names the exact line to add.
public enum NativeMediaImportLaunchCleanup {
    /// Best-effort: a failure here (an unreadable temp volume, a permissions
    /// oddity) must never block app launch, so this swallows its error. The
    /// same sweep also runs, and does throw, the next time a picker is
    /// actually opened (`NativeSelectedMediaLease.init` -> `prepareLeaseDirectory`),
    /// so nothing is silently skipped forever even if this call's own attempt
    /// fails.
    public static func sweepStaleLeases() {
        try? NativeSelectedMediaLease.sweepStaleLeases()
    }
}

private final class NativeMediaLiveLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String> = []

    func register(_ directory: URL) {
        lock.lock()
        directories.insert(directory.path)
        lock.unlock()
    }

    func unregister(_ directory: URL) {
        lock.lock()
        directories.remove(directory.path)
        lock.unlock()
    }

    func contains(_ directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return directories.contains(directory.path)
    }
}

/// Bounded, per-WebView custody of user-selected media. This is never an app's
/// version history or a telemetry directory. Close and batch rollback revoke
/// late provider work, including callbacks that arrive after picker dismissal.
final class NativeSelectedMediaLease: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case closed
        case unsafeFile
        case tooLarge(kind: NativeMediaImportPolicy.Kind, actualBytes: Int64, maximumBytes: Int64)
        case notEnoughSpace(requiredBytes: Int64, availableBytes: Int64)
        /// The lease's own retained-file-count cap (32), not a byte total:
        /// there is no fixed byte cap on a batch any more (see
        /// `NativeMediaImportPolicy.evaluateSpace`), only free space.
        case full
        case io
    }

    struct Batch: Hashable, Sendable {
        fileprivate let id: UUID
    }

    static let mediaRootName = "iris-selected-media-v1"
    static let rootMarkerName = ".iris-media-root-v1"
    static let rootLockName = ".iris-media-root.lock"
    static let leaseDirectoryPrefix = "lease-"
    static let leaseMarkerName = ".iris-media-lease-v1"
    static let leaseLockName = ".iris-media-lease.lock"
    static let rootMarkerData = Data("iris-selected-media-root-v1\n".utf8)
    static let leaseMarkerData = Data("iris-selected-media-lease-v1\n".utf8)

    private static let liveRegistry = NativeMediaLiveLeaseRegistry()

    private let lock = NSLock()
    private let directory: URL
    private let leaseLockFD: Int32
    private var isClosed = false
    private var retainedBytes = 0
    private var retainedFiles = 0
    /// Active batches contain both completed files and in-flight reservations.
    /// Removing a reservation first makes rollback idempotent under races.
    private var activeBatches: [UUID: [URL: Int]] = [:]

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        let prepared = try Self.prepareLeaseDirectory(parent: parent)
        directory = prepared.directory
        leaseLockFD = prepared.lockFD
        Self.registerLive(directory)
    }

    deinit { close() }

    var directoryForTesting: URL { directory }
    var retainedBytesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedBytes
    }
    var retainedFilesForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedFiles
    }

    func beginBatch() throws -> Batch {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw Failure.closed }
        let batch = Batch(id: UUID())
        activeBatches[batch.id] = [:]
        return batch
    }

    func commit(_ batch: Batch) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, activeBatches.removeValue(forKey: batch.id) != nil else {
            throw Failure.closed
        }
    }

    func rollback(_ batch: Batch) {
        let files: [URL]
        lock.lock()
        if let reservations = activeBatches.removeValue(forKey: batch.id) {
            for size in reservations.values {
                retainedBytes -= size
                retainedFiles -= 1
            }
            files = Array(reservations.keys)
        } else {
            files = []
        }
        lock.unlock()
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Compatibility path for callers that need one retained file without an
    /// explicit multi-item transaction. `kind` defaults to inferring image
    /// vs. video from the file extension when the caller does not already
    /// know it from the picker's UTType (see `copySelectedFile(_:fileExtension:kind:batch:)`).
    func copySelectedFile(_ source: URL, fileExtension: String, kind: NativeMediaImportPolicy.Kind? = nil) throws -> URL {
        let batch = try beginBatch()
        do {
            let copied = try copySelectedFile(source, fileExtension: fileExtension, kind: kind, batch: batch)
            try commit(batch)
            return copied
        } catch {
            rollback(batch)
            throw error
        }
    }

    func copySelectedFile(
        _ source: URL, fileExtension: String,
        kind: NativeMediaImportPolicy.Kind? = nil, batch: Batch,
        takingProviderTemporaryFile: Bool = false
    ) throws -> URL {
        guard source.isFileURL, Self.isSafeFileExtension(fileExtension) else {
            throw Failure.unsafeFile
        }
        let resolvedKind = kind ?? Self.inferredKind(fromFileExtension: fileExtension)
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeFile }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size > 0,
              information.st_size <= Int64(Int.max) else { throw Failure.unsafeFile }
        let size = Int(information.st_size)
        let sizeBytes = Int64(information.st_size)
        guard case .accepted = NativeMediaImportPolicy.evaluateSize(kind: resolvedKind, bytes: sizeBytes) else {
            throw Failure.tooLarge(
                kind: resolvedKind, actualBytes: sizeBytes,
                maximumBytes: NativeMediaImportPolicy.maximumFileBytes(for: resolvedKind) ?? Int64.max
            )
        }
        // Read fresh, right before this item is committed, so it already
        // reflects every byte a prior item in this same batch has actually
        // consumed on disk (see NativeMediaImportPolicy.evaluateSpace's doc
        // comment for why `alreadyCommittedBytes` is not added a second time
        // here).
        let availableBytes: Int64? = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage

        let destination = directory.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        try reserve(destination: destination, size: size, availableBytes: availableBytes, for: batch)
        var succeeded = false
        defer {
            if !succeeded {
                releaseReservation(destination: destination, from: batch)
                try? FileManager.default.removeItem(at: destination)
            }
        }

        // Only an explicit provider-temporary-file transfer allows moving.
        // Other callers retain their original file after the lease closes.
        // The picker hands over a temporary file this call may take (Apple's
        // own docs: it is only guaranteed to live for the duration of the
        // provider's completion handler, which is exactly this call). Prefer
        // an atomic same-volume move over a copy: a move never creates a
        // second full-size copy of the bytes on disk, so a one-hour 4K clip
        // does not need extra disk space just to get from the picker's temp
        // location into the lease. Falls back to the chunked copy below only
        // when the move is not possible (a different volume -- `rename(2)`
        // fails with EXDEV -- or a sandbox/provider restriction).
        if takingProviderTemporaryFile, Self.attemptAtomicMove(from: source, to: destination) {
            guard reservationIsActive(destination: destination, in: batch) else { throw Failure.closed }
            succeeded = true
            return destination
        }

        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw Failure.io }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }

        var total = 0
        while true {
            guard reservationIsActive(destination: destination, in: batch) else { throw Failure.closed }
            let remaining = size - total
            let chunk = try input.read(upToCount: min(1024 * 1024, remaining + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= remaining else { throw Failure.unsafeFile }
            guard reservationIsActive(destination: destination, in: batch) else { throw Failure.closed }
            try output.write(contentsOf: chunk)
            total += chunk.count
        }
        guard total == size, reservationIsActive(destination: destination, in: batch) else {
            throw Failure.unsafeFile
        }
        succeeded = true
        return destination
    }

    /// `true` on success (the file now lives at `destination`; nothing left
    /// behind at `source`). `false` on any failure (cross-volume `EXDEV`,
    /// permissions, or any other `rename(2)` error), with neither path
    /// touched, so the caller's chunked-copy fallback runs against an
    /// unmodified `source`. Internal (not private) so a test can exercise
    /// the move/fallback boundary directly without needing a real
    /// cross-volume filesystem in CI.
    static func attemptAtomicMove(from source: URL, to destination: URL) -> Bool {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath) == 0
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        activeBatches.removeAll()
        retainedBytes = 0
        retainedFiles = 0
        lock.unlock()

        // The held lock protects this exact marker-owned directory from another
        // process's crash reaper until removal is complete.
        try? FileManager.default.removeItem(at: directory)
        Self.unregisterLive(directory)
#if canImport(Darwin)
        _ = flock(leaseLockFD, LOCK_UN)
        _ = Darwin.close(leaseLockFD)
#endif
    }

    static func isSafeFileExtension(_ value: String) -> Bool {
        (1...10).contains(value.utf8.count)
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }

    /// Falls back to the file extension only when a caller has no UTType to
    /// ask (the no-batch convenience overload, used by callers outside the
    /// picker path). The picker path always passes the real `kind` it
    /// already decided from the item's UTType.
    private static func inferredKind(fromFileExtension fileExtension: String) -> NativeMediaImportPolicy.Kind {
        if let type = UTType(filenameExtension: fileExtension),
           type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return .video
        }
        return .image
    }

    /// `availableBytes` is `nil` when the volume's free space could not be
    /// read (matches the old behavior: optimistic, does not block an import
    /// just because the one-time stat call failed). One check here governs
    /// the whole batch's running total (`retainedBytes`, everything already
    /// copied into this lease's current batch), which is what makes a
    /// multi-clip pick fail together rather than partially: see
    /// `NativeMediaImportPolicy.evaluateSpace`'s doc comment.
    private func reserve(destination: URL, size: Int, availableBytes: Int64?, for batch: Batch) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, var reservations = activeBatches[batch.id] else { throw Failure.closed }
        guard retainedFiles < 32 else { throw Failure.full }
        if let availableBytes {
            if case .insufficient(let requiredBytes, let stillAvailable) = NativeMediaImportPolicy.evaluateSpace(
                alreadyCommittedBytes: Int64(retainedBytes), addingBytes: Int64(size), availableBytes: availableBytes
            ) {
                throw Failure.notEnoughSpace(requiredBytes: requiredBytes, availableBytes: stillAvailable)
            }
        }
        reservations[destination] = size
        activeBatches[batch.id] = reservations
        retainedBytes += size
        retainedFiles += 1
    }

    private func releaseReservation(destination: URL, from batch: Batch) {
        lock.lock()
        defer { lock.unlock() }
        guard var reservations = activeBatches[batch.id],
              let size = reservations.removeValue(forKey: destination) else { return }
        retainedBytes -= size
        retainedFiles -= 1
        activeBatches[batch.id] = reservations
    }

    private func reservationIsActive(destination: URL, in batch: Batch) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let reservations = activeBatches[batch.id] else { return false }
        return reservations[destination] != nil
    }

    /// Ensures the shared media root exists (creating and marking it on first
    /// use), takes its exclusive lock, reaps any stale lease directories
    /// under it, and hands back the STILL-LOCKED root lock fd for the caller
    /// to release. Every caller must keep holding this lock until it is done
    /// with whatever it is about to do under `root` (see
    /// `reapCrashLeftovers`'s own doc comment: reaping and a new lease's own
    /// creation are mutually exclusive under this one lock, so a reap can
    /// never run while another process's own creation is midway between its
    /// marker and its lock file -- splitting this into "reap, unlock" then
    /// "separately, unlocked, create a new lease dir" would reopen exactly
    /// that race).
    private static func lockRootAndReapStaleLeases(parent: URL) throws -> (root: URL, rootLockFD: Int32) {
        guard parent.isFileURL else { throw Failure.unsafeFile }
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard try isOwnedDirectory(parent) else { throw Failure.unsafeFile }
        let root = parent.appendingPathComponent(mediaRootName, isDirectory: true)
        let createdRoot = try ensureMediaRoot(root)
        if createdRoot {
            try createExactMarker(root.appendingPathComponent(rootMarkerName), data: rootMarkerData)
        } else {
            guard try hasExactMarker(root.appendingPathComponent(rootMarkerName), data: rootMarkerData) else {
                throw Failure.unsafeFile
            }
        }

        let rootLockURL = root.appendingPathComponent(rootLockName)
        let rootLockFD = open(rootLockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard rootLockFD >= 0 else { throw Failure.unsafeFile }
        var handedOff = false
        defer {
            if !handedOff {
#if canImport(Darwin)
                _ = flock(rootLockFD, LOCK_UN)
                _ = Darwin.close(rootLockFD)
#endif
            }
        }
        guard try fdIsPlainOwnedFile(rootLockFD), flock(rootLockFD, LOCK_EX) == 0 else {
            throw Failure.unsafeFile
        }
        guard try isPlainOwnedDirectory(root),
              try hasExactMarker(root.appendingPathComponent(rootMarkerName), data: rootMarkerData) else {
            throw Failure.unsafeFile
        }

        try reapCrashLeftovers(in: root)
        handedOff = true
        return (root, rootLockFD)
    }

    /// Removes any lease directory left behind by a process that was killed
    /// mid-import (force-quit, jetsam, crash): the "sweep stale leases at
    /// launch" requirement. Safe to call before any lease has ever been
    /// created in this process (creates the shared media root if needed) and
    /// safe to call concurrently with a real lease being created elsewhere
    /// (shares the same root lock as `prepareLeaseDirectory`, so it can never
    /// reap a lease that is mid-creation). See `NativeMediaImportLaunchCleanup`
    /// for the narrow public entry point a caller outside this module uses;
    /// this task's HANDOFF.md has the exact one-line call the app's own
    /// launch path still needs to add.
    static func sweepStaleLeases(parent: URL = FileManager.default.temporaryDirectory) throws {
        let (_, rootLockFD) = try lockRootAndReapStaleLeases(parent: parent)
#if canImport(Darwin)
        _ = flock(rootLockFD, LOCK_UN)
        _ = Darwin.close(rootLockFD)
#endif
    }

    private static func prepareLeaseDirectory(parent: URL) throws -> (directory: URL, lockFD: Int32) {
        let (root, rootLockFD) = try lockRootAndReapStaleLeases(parent: parent)
        defer {
#if canImport(Darwin)
            _ = flock(rootLockFD, LOCK_UN)
            _ = Darwin.close(rootLockFD)
#endif
        }

        let directory = root.appendingPathComponent(
            leaseDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.io }
        var prepared = false
        defer {
            if !prepared { try? FileManager.default.removeItem(at: directory) }
        }

        try createExactMarker(directory.appendingPathComponent(leaseMarkerName), data: leaseMarkerData)
        let leaseLockURL = directory.appendingPathComponent(leaseLockName)
        let leaseFD = open(
            leaseLockURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard leaseFD >= 0 else { throw Failure.io }
        guard try fdIsPlainOwnedFile(leaseFD), flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else {
#if canImport(Darwin)
            _ = Darwin.close(leaseFD)
#endif
            throw Failure.io
        }
        prepared = true
        return (directory, leaseFD)
    }

    private static func ensureMediaRoot(_ root: URL) throws -> Bool {
        var status = stat()
        if lstat(root.path, &status) == 0 {
            guard try isPlainOwnedDirectory(root) else { throw Failure.unsafeFile }
            return false
        }
        guard errno == ENOENT else { throw Failure.io }
        if mkdir(root.path, 0o700) == 0 { return true }
        if errno == EEXIST {
            guard try isPlainOwnedDirectory(root) else { throw Failure.unsafeFile }
            return false
        }
        throw Failure.io
    }

    private static func reapCrashLeftovers(in root: URL) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw Failure.io
        }

        for child in children {
            guard isExactLeaseDirectoryName(child.lastPathComponent) else { continue }
            guard !isRegisteredLive(child) else { continue }
            guard (try? isPlainOwnedDirectory(child)) == true else { continue }
            let marker = child.appendingPathComponent(leaseMarkerName)
            guard (try? hasExactMarker(marker, data: leaseMarkerData)) == true else { continue }

            let lockURL = child.appendingPathComponent(leaseLockName)
            var lockStatus = stat()
            if lstat(lockURL.path, &lockStatus) != 0 {
                // The root lock proves no live creator can still be between its
                // exact marker and lock-file creation. This is a crashed owned child.
                guard errno == ENOENT else { throw Failure.unsafeFile }
                try removeOwnedStaleChild(child)
                continue
            }
            guard (lockStatus.st_mode & S_IFMT) == S_IFREG,
                  lockStatus.st_uid == geteuid() else { throw Failure.unsafeFile }
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0, try fdIsPlainOwnedFile(fd) else {
                if fd >= 0 { _ = Darwin.close(fd) }
                throw Failure.unsafeFile
            }
            let locked = flock(fd, LOCK_EX | LOCK_NB) == 0
            if !locked {
                _ = Darwin.close(fd)
                continue
            }
            do {
                guard try isPlainOwnedDirectory(child),
                      try hasExactMarker(marker, data: leaseMarkerData) else {
                    _ = flock(fd, LOCK_UN)
                    _ = Darwin.close(fd)
                    throw Failure.unsafeFile
                }
                try removeOwnedStaleChild(child)
                _ = flock(fd, LOCK_UN)
                _ = Darwin.close(fd)
            } catch {
                _ = flock(fd, LOCK_UN)
                _ = Darwin.close(fd)
                throw error
            }
        }
    }

    private static func removeOwnedStaleChild(_ child: URL) throws {
        do {
            try FileManager.default.removeItem(at: child)
        } catch {
            // Refuse a new lease if owned crash data could not be reaped. A
            // successful init therefore carries no stale-owned byte debt.
            throw Failure.full
        }
    }

    private static func isExactLeaseDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(leaseDirectoryPrefix) else { return false }
        let suffix = String(name.dropFirst(leaseDirectoryPrefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return false }
        return uuid.uuidString == suffix.uppercased()
    }

    private static func createExactMarker(_ url: URL, data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw Failure.io
        }
    }

    private static func hasExactMarker(_ url: URL, data expected: Data) throws -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        guard try fdIsPlainOwnedFile(fd) else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            return (try handle.readToEnd() ?? Data()) == expected
        } catch {
            throw Failure.io
        }
    }

    private static func isPlainOwnedDirectory(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == geteuid()
            && (status.st_mode & 0o077) == 0
    }

    private static func isOwnedDirectory(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR && status.st_uid == geteuid()
    }

    private static func fdIsPlainOwnedFile(_ fd: Int32) throws -> Bool {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw Failure.io }
        return (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == geteuid()
            && (status.st_mode & 0o022) == 0
    }

    private static func registerLive(_ directory: URL) {
        liveRegistry.register(directory)
    }

    private static func unregisterLive(_ directory: URL) {
        liveRegistry.unregister(directory)
    }

    private static func isRegisteredLive(_ directory: URL) -> Bool {
        liveRegistry.contains(directory)
    }
}
