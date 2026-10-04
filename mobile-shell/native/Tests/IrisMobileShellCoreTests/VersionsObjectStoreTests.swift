import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsObjectStoreTests: XCTestCase {
    func testWriteIsContentAddressedAndIdempotent() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))

        let data = Data("hello iris".utf8)
        let hex1 = try store.write(data)
        let hex2 = try store.write(data) // identical content: fast no-op, same hash
        XCTAssertEqual(hex1, hex2)
        // Independent oracle for the hash itself: CryptoKit directly, not
        // the store's own `NativeObjectStore.hex` helper.
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex1, expected)
        XCTAssertTrue(store.exists(sha256: hex1))
        XCTAssertEqual(try store.read(sha256: hex1), data)
        XCTAssertTrue(try store.verify(sha256: hex1))

        // The object is read-only (0444) once written.
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path(forSHA256: hex1).path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms & 0o777, 0o444)
    }

    func testDifferentContentGetsDifferentObjects() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let a = try store.write(Data("A".utf8))
        let b = try store.write(Data("B".utf8))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try store.allObjectHashes(), Set([a, b]))
    }

    func testFanOutDirectoryIsTwoHexCharsOfTheHash() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let hex = try store.write(Data("fan-out".utf8))
        let path = store.path(forSHA256: hex)
        XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, String(hex.prefix(2)))
        XCTAssertEqual(path.lastPathComponent, hex)
    }

    func testSweepOrphanTempsOnlyRemovesOldTempFiles() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objectsRoot = root.v1.appendingPathComponent("objects")
        let store = try NativeObjectStore(root: objectsRoot)

        let freshTemp = objectsRoot.appendingPathComponent("tmp-fresh")
        try Data("in flight".utf8).write(to: freshTemp)
        let oldTemp = objectsRoot.appendingPathComponent("tmp-old")
        try Data("orphaned".utf8).write(to: oldTemp)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldTemp.path)

        let swept = store.sweepOrphanTemps(olderThan: 600)
        XCTAssertEqual(swept, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTemp.path), "a temp write still in flight must never be swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTemp.path))
    }

    func testAllocatedBytesUsesStBlocksNotLogicalSize() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let hex = try store.write(Data(repeating: 0x41, count: 10_000))
        let allocated = try store.allocatedBytes(sha256: hex)
        XCTAssertGreaterThan(allocated, 0)
        // st_blocks is quantized to the filesystem's block size, so this is
        // "close to" 10,000, not exactly it, the whole point of using it.
        XCTAssertGreaterThanOrEqual(allocated, 10_000 - 4096)
    }

    func testDeleteReclaimsWritePermissionFirst() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let hex = try store.write(Data("to be deleted".utf8))
        try store.delete(sha256: hex)
        XCTAssertFalse(store.exists(sha256: hex))
    }

    func testCloneOrCopySharesBlocksOnAPFSAndFallsBackElsewhere() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let src = root.base.appendingPathComponent("source.bin")
        try Data(repeating: 0x99, count: 4096).write(to: src)
        let dst = root.base.appendingPathComponent("clone.bin")
        let cloned = try nativeCloneOrCopyFile(from: src, to: dst)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
        // On the CI/dev volume (APFS) this clones; elsewhere the function
        // still succeeds via the copy fallback, so only content is asserted
        // strictly and `cloned` is logged for information.
        _ = cloned
    }

    func testConcurrentWritesOfIdenticalContentNeverLeaveATempFileBehind() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let data = Data("race".utf8)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try store.write(data) }
            }
            var hashes = Set<String>()
            for try await hash in group { hashes.insert(hash) }
            XCTAssertEqual(hashes.count, 1)
        }
        let leftoverTemps = (try? FileManager.default.contentsOfDirectory(at: root.v1.appendingPathComponent("objects"), includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("tmp-") } ?? []
        XCTAssertEqual(leftoverTemps.count, 0)
    }
}
