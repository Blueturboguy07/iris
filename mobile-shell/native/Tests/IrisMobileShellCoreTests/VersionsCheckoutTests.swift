import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsCheckoutTests: XCTestCase {
    private func makeManifestAndObjects(objects: NativeObjectStore, revisionId: String) throws -> NativeVersionManifest {
        // Byte counts come from the real content: a hand-typed count once
        // disagreed with the data (19 vs 18) and the store rightly refused it.
        let aData = Data("index.html content".utf8)
        let bData = Data("app.js content".utf8)
        let a = try objects.write(aData)
        let b = try objects.write(bData)
        return NativeVersionManifest(
            revisionId: revisionId, baseRevisionId: nil, contentHash: "sha256:\(revisionId)",
            createdAt: VersionsFixture.isoNow(),
            files: [
                NativeVersionFileEntry(path: "index.html", sha256: a, bytes: aData.count, mediaType: "text/html"),
                NativeVersionFileEntry(path: "assets/app.js", sha256: b, bytes: bData.count, mediaType: "text/javascript"),
            ]
        )
    }

    func testBuildProducesAnExactByteForByteTree() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objects = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let builder = try NativeVersionCheckoutBuilder(root: root.v1.appendingPathComponent("checkouts"), objects: objects)
        let manifest = try makeManifestAndObjects(objects: objects, revisionId: "rev-sha256:c1")

        let record = try builder.build(manifest: manifest, appId: "app", projectId: "proj")
        let contentRoot = builder.contentRoot(appId: "app", projectId: "proj", revisionId: "rev-sha256:c1")
        XCTAssertEqual(try String(contentsOf: contentRoot.appendingPathComponent("index.html"), encoding: .utf8), "index.html content")
        XCTAssertEqual(try String(contentsOf: contentRoot.appendingPathComponent("assets/app.js"), encoding: .utf8), "app.js content")
        XCTAssertNotNil(record.builtAt)
    }

    func testRebuildingAnExistingCheckoutVerifiesInsteadOfCloningAgain() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objects = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let builder = try NativeVersionCheckoutBuilder(root: root.v1.appendingPathComponent("checkouts"), objects: objects)
        let manifest = try makeManifestAndObjects(objects: objects, revisionId: "rev-sha256:c2")

        _ = try builder.build(manifest: manifest, appId: "app", projectId: "proj")
        let contentRoot = builder.contentRoot(appId: "app", projectId: "proj", revisionId: "rev-sha256:c2")
        let originalInode = try (FileManager.default.attributesOfItem(atPath: contentRoot.appendingPathComponent("index.html").path)[.systemFileNumber] as? NSNumber)?.intValue

        let second = try builder.build(manifest: manifest, appId: "app", projectId: "proj")
        let secondInode = try (FileManager.default.attributesOfItem(atPath: contentRoot.appendingPathComponent("index.html").path)[.systemFileNumber] as? NSNumber)?.intValue
        XCTAssertEqual(originalInode, secondInode, "verify-in-place must not delete and re-clone an already-correct checkout")
        XCTAssertNotNil(second.verifiedAt)
    }

    func testCorruptedCheckoutFileIsDetectedByVerify() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objects = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let builder = try NativeVersionCheckoutBuilder(root: root.v1.appendingPathComponent("checkouts"), objects: objects)
        let manifest = try makeManifestAndObjects(objects: objects, revisionId: "rev-sha256:c3")
        _ = try builder.build(manifest: manifest, appId: "app", projectId: "proj")

        let contentRoot = builder.contentRoot(appId: "app", projectId: "proj", revisionId: "rev-sha256:c3")
        let corrupted = contentRoot.appendingPathComponent("index.html")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: corrupted.path)
        try Data("tampered".utf8).write(to: corrupted)

        XCTAssertThrowsError(try builder.verify(manifest: manifest, appId: "app", projectId: "proj"))

        // The store's own build() self-heals by deleting and rebuilding on
        // a failed verify.
        _ = try builder.build(manifest: manifest, appId: "app", projectId: "proj")
        XCTAssertEqual(try String(contentsOf: corrupted, encoding: .utf8), "index.html content")
    }

    func testDeleteRemovesOnlyTheCloneTreeNeverTheUnderlyingObjects() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objects = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let builder = try NativeVersionCheckoutBuilder(root: root.v1.appendingPathComponent("checkouts"), objects: objects)
        let manifest = try makeManifestAndObjects(objects: objects, revisionId: "rev-sha256:c4")
        _ = try builder.build(manifest: manifest, appId: "app", projectId: "proj")

        try builder.delete(appId: "app", projectId: "proj", revisionId: "rev-sha256:c4")
        XCTAssertFalse(builder.exists(appId: "app", projectId: "proj", revisionId: "rev-sha256:c4"))
        for file in manifest.files {
            XCTAssertTrue(objects.exists(sha256: file.sha256), "deleting a checkout must never touch the shared object store")
        }
    }
}
