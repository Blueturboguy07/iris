import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsMigrationTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    private func run(
        _ root: VersionsTestRoot,
        legacyRoot: URL,
        current: String?,
        fallback: String?,
        fault: NativeVersionFaultInjector = .init()
    ) async throws -> NativeVersionStore {
        let store = try root.makeStore()
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacyRoot, v1Root: root.v1)
        try await migration.migrate(
            appId: appId, projectId: projectId, currentRevisionId: current, fallbackRevisionId: fallback,
            objects: store.objects, manifests: store.manifests, refs: store.refs,
            ledger: store.ledger, checkouts: store.checkouts, fault: fault
        )
        return store
    }

    func testMigratesEveryRevisionIntoObjectsManifestsAndLedgerRows() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "1", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "2", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 400, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(id: v2, base: v1, seed: 401, createdAt: VersionsFixture.isoNow(offsetSeconds: -200)),
        ], to: legacyRoot)

        let store = try await run(root, legacyRoot: legacyRoot, current: v2, fallback: v1)

        let manifests = try await store.manifests.list(appId: appId, projectId: projectId)
        XCTAssertEqual(Set(manifests.map(\.revisionId)), [v1, v2])
        let __mv1v2M3 = await store.ledger.rows(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2M3.count, 2)

        for manifest in manifests {
            for file in manifest.files {
                let __mv1v2M4 = await store.objects.exists(sha256: file.sha256)
                XCTAssertTrue(__mv1v2M4)
                let __mv1v2M1 = try await store.refs.count(sha256: file.sha256)
                XCTAssertEqual(__mv1v2M1, 1)
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path),
                      "C4: retain the legacy tree until an object-store checkout has been launched and verified")
        for manifest in manifests {
            let legacyContent = legacyRoot.appendingPathComponent(manifest.revisionId).appendingPathComponent("content")
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyContent.path), "C4: legacy bytes remain available before verified launch")
            for file in manifest.files {
                let legacyFile = legacyContent.appendingPathComponent(file.path)
                let legacyBytes = try Data(contentsOf: legacyFile)
                XCTAssertEqual(NativeObjectStore.hex(legacyBytes), file.sha256, "C4: legacy bytes still match the migrated manifest")
                let objectURL = await store.objects.path(forSHA256: file.sha256)
                let objectBytes = try Data(contentsOf: objectURL)
                XCTAssertEqual(NativeObjectStore.hex(objectBytes), file.sha256, "C4: migrated object is independently hash-verified")
            }
        }
    }

    func testMigrationRejectsLegacyBytesThatDoNotMatchTheirDeclaredHash() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let revisionId = "rev-sha256:" + String(repeating: "d", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: revisionId, base: nil, seed: 412,
                                            createdAt: VersionsFixture.isoNow(offsetSeconds: -100)),
        ], to: legacyRoot)
        let legacyFile = legacyRoot.appendingPathComponent(revisionId)
            .appendingPathComponent("content/assets/file-0.bin")
        var damagedBytes = try Data(contentsOf: legacyFile)
        damagedBytes[damagedBytes.startIndex] ^= 0x01
        try damagedBytes.write(to: legacyFile)

        let store = try root.makeStore()
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacyRoot, v1Root: root.v1)
        do {
            try await migration.migrate(
                appId: appId, projectId: projectId, currentRevisionId: revisionId, fallbackRevisionId: nil,
                objects: store.objects, manifests: store.manifests, refs: store.refs,
                ledger: store.ledger, checkouts: store.checkouts
            )
            XCTFail("C4: migration must reject a source file whose bytes do not match its declared hash")
        } catch {
            // Any clear verification refusal satisfies this seam. The invariants below
            // independently ensure a failed attempt leaves the legacy source usable.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path),
                      "C4: failed verification must preserve the legacy source bytes")
        XCTAssertEqual(try Data(contentsOf: legacyFile), damagedBytes,
                       "C4: failed verification must not rewrite source content")
        let manifests = try await store.manifests.list(appId: appId, projectId: projectId)
        XCTAssertTrue(manifests.isEmpty, "C4: an unverifiable revision must not be exposed as migrated")
    }

    func testCurrentRevisionGetsHashVerifiedLaunchableCheckout() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "3", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 402, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
        ], to: legacyRoot)

        let legacyContentFile = legacyRoot.appendingPathComponent(v1).appendingPathComponent("content/assets/file-0.bin")
        let legacyBytes = try Data(contentsOf: legacyContentFile)
        let expectedHash = NativeObjectStore.hex(legacyBytes)

        let store = try await run(root, legacyRoot: legacyRoot, current: v1, fallback: nil)

        let checkoutContent = await store.checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: v1).appendingPathComponent("assets/file-0.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkoutContent.path))
        let checkoutBytes = try Data(contentsOf: checkoutContent)
        XCTAssertEqual(NativeObjectStore.hex(checkoutBytes), NativeObjectStore.hex(try Data(contentsOf: legacyContentFile)),
                       "C4: checkout bytes verify against the still-present legacy source; copy or safe hardlink is acceptable")
        let objectURL = await store.objects.path(forSHA256: expectedHash)
        XCTAssertEqual(NativeObjectStore.hex(checkoutBytes), expectedHash,
                       "C4: checkout content verifies against its manifest hash")
        XCTAssertEqual(NativeObjectStore.hex(try Data(contentsOf: objectURL)), expectedHash,
                       "C4: referenced object independently verifies against the manifest hash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyContentFile.path),
                      "C4: retain legacy bytes until a verified launch")
    }

    func testMigrationPreservesLegacyBytesForUnchangedFiles() async throws {
        // C4 permits copy or a verified safe hardlink, while requiring the
        // original legacy bytes to survive until a verified launch.
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "4", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "5", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 403, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(id: v2, base: v1, seed: 404, createdAt: VersionsFixture.isoNow(offsetSeconds: -200)),
        ], to: legacyRoot)

        // v1 is retained history while v2 is current. Its legacy bytes must
        // remain intact even though its objects are present in the new store.
        let legacyFile = legacyRoot.appendingPathComponent(v1).appendingPathComponent("content/assets/file-0.bin")
        let originalBytes = try Data(contentsOf: legacyFile)
        let originalHash = NativeObjectStore.hex(originalBytes)

        let store = try await run(root, legacyRoot: legacyRoot, current: v2, fallback: nil)

        let objectPath = await store.objects.path(forSHA256: originalHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: objectPath.path))
        let objectBytes = try Data(contentsOf: objectPath)
        XCTAssertEqual(NativeObjectStore.hex(objectBytes), originalHash,
                       "C4: object content must hash-verify; copying or a safe hardlink is allowed")
        XCTAssertEqual(try Data(contentsOf: legacyFile), originalBytes,
                       "C4: source legacy bytes stay intact before verified launch")
    }

    func testDuplicateContentAcrossRevisionsIsDeduplicatedNotDoubleStored() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "6", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "7", count: 64)
        // Same seed => identical file bytes across both revisions (mirrors a
        // real update where most files are unchanged).
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 405, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(id: v2, base: v1, seed: 405, createdAt: VersionsFixture.isoNow(offsetSeconds: -200)),
        ], to: legacyRoot)

        let store = try await run(root, legacyRoot: legacyRoot, current: v2, fallback: v1)
        let m1 = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)
        let m2 = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v2)
        XCTAssertEqual(Set(m1.files.map(\.sha256)), Set(m2.files.map(\.sha256)))
        for file in m1.files {
            let __mv1v2M2 = try await store.refs.count(sha256: file.sha256)
            XCTAssertEqual(__mv1v2M2, 2, "identical content across two revisions must be one object, two references")
        }

        let report = try versionsRunOracle(v1Root: root.v1)
        let findings = report["findings"] as? [[String: Any]] ?? [["kind": "no-json"]]
        XCTAssertEqual(findings.count, 0, "oracle findings: \(findings)")
    }

    // MV2 groundwork (SPEC.md section 2.7): a legacy `metadata.json` always
    // carries the app manifest (displayName, dataNamespace, capabilities,
    // ...); migration must not silently drop it, since `revisionSummaries()`
    // (section 2.7) reads manifests only, never content, so a manifest
    // without these fields is unable to answer what app it belongs to.
    func testMigrationCarriesTheAppManifestForward() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "a", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 408, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
        ], to: legacyRoot)

        let store = try await run(root, legacyRoot: legacyRoot, current: v1, fallback: nil)
        let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertEqual(manifest.manifest?.displayName, "Legacy Fixture App")
        XCTAssertEqual(manifest.manifest?.dataNamespace, "publik.kneecap")
        XCTAssertEqual(manifest.manifest?.dataUpdatePolicy, "preserve")
    }

    // Contract v1.1 (SPEC.md section 2.6): a revision that already had a
    // feature title before migration keeps that exact title on the phone,
    // rather than falling back to the generic "Update from <date>".
    func testMigrationKeepsAnExistingFeatureTitleInsteadOfTheGenericFallback() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "b", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "c", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 409, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(
                id: v2, base: v1, seed: 410, createdAt: VersionsFixture.isoNow(offsetSeconds: -200),
                changes: [NativeVersionChange(title: "Added: Dark mode", kind: .added, target: nil)]
            ),
        ], to: legacyRoot)

        let store = try await run(root, legacyRoot: legacyRoot, current: v2, fallback: v1)
        let rows = await store.ledger.rows(appId: appId, projectId: projectId)
        let row = rows.first { $0.revisionId == v2 }
        XCTAssertEqual(row?.title, "Added: Dark mode")
        XCTAssertEqual(row?.kind, .added)
        let firstRow = rows.first { $0.revisionId == v1 }
        XCTAssertEqual(firstRow?.title, "First version")
    }

    func testMigrationIsResumableAfterAPartialRun() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "8", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "9", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 406, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(id: v2, base: v1, seed: 407, createdAt: VersionsFixture.isoNow(offsetSeconds: -200)),
        ], to: legacyRoot)

        let store = try root.makeStore()
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacyRoot, v1Root: root.v1)
        do {
            try await migration.migrate(
                appId: appId, projectId: projectId, currentRevisionId: v2, fallbackRevisionId: v1,
                objects: store.objects, manifests: store.manifests, refs: store.refs,
                ledger: store.ledger, checkouts: store.checkouts,
                fault: NativeVersionFaultInjector(point: .migration_midRename)
            )
            XCTFail("expected simulated crash")
        } catch is NativeVersionSimulatedCrash {}

        // Resume.
        try await migration.migrate(
            appId: appId, projectId: projectId, currentRevisionId: v2, fallbackRevisionId: v1,
            objects: store.objects, manifests: store.manifests, refs: store.refs,
            ledger: store.ledger, checkouts: store.checkouts
        )

        XCTAssertEqual(migration.readJournal(appId: appId, projectId: projectId)?.done, true)
        let __mv1v2M5 = try await store.manifests.list(appId: appId, projectId: projectId)
        XCTAssertEqual(Set(__mv1v2M5.map(\.revisionId)), [v1, v2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path),
                      "C4: resumable migration keeps the source tree until a verified checkout launch")
        let current = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v2)
        for file in current.files {
            let legacyBytes = try Data(contentsOf: legacyRoot.appendingPathComponent(v2).appendingPathComponent("content").appendingPathComponent(file.path))
            XCTAssertEqual(NativeObjectStore.hex(legacyBytes), file.sha256, "C4: retry retains exact source bytes")
            let objectURL = await store.objects.path(forSHA256: file.sha256)
            XCTAssertEqual(NativeObjectStore.hex(try Data(contentsOf: objectURL)), file.sha256, "C4: retry produces verified object bytes")
        }
    }
}
