import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsGCAndScaleTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    // MARK: free()

    func testFreeVersionReclaimsExpectedBytesAndOracleAgrees() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 500, fileCount: 8, averageBytesOverride: 8192, baseRevisionId: nil, createdAtOffset: -300)

        let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)
        var expectedAllocated = 0
        for file in manifest.files { expectedAllocated += try await store.objects.allocatedBytes(sha256: file.sha256) }

        let result = try await store.gc.free(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertEqual(result.bytesReclaimed, expectedAllocated, "bytesReclaimed must be the allocated (st_blocks) size, matching the 'number the disk gets back' promise")

        for file in manifest.files {
            let __mv1v2b1 = await store.objects.exists(sha256: file.sha256)
            XCTAssertFalse(__mv1v2b1)
        }

        let report = try versionsRunOracle(v1Root: root.v1)
        let findings = report["findings"] as? [[String: Any]] ?? [["kind": "no-json"]]
        XCTAssertEqual(findings.count, 0, "oracle findings: \(findings)")
    }

    func testFreeingOneAppsVersionNeverFreesAnObjectAnotherAppStillReferences() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()

        let sharedBytes = Data("shared vendor bundle bytes".utf8)
        let filesA = [NativeVersionStagedFile(path: "vendor/lib.js", data: sharedBytes, mediaType: "text/javascript")]
        let filesB = [NativeVersionStagedFile(path: "vendor/lib.js", data: sharedBytes, mediaType: "text/javascript")]
        let createdAt = VersionsFixture.isoNow()
        let idA = VersionsFixture.identity(appId: "app-a", projectId: "app-a.mobile", baseRevisionId: nil, files: filesA, createdAt: createdAt)
        let idB = VersionsFixture.identity(appId: "app-b", projectId: "app-b.mobile", baseRevisionId: nil, files: filesB, createdAt: createdAt)
        _ = try await store.stage(appId: "app-a", projectId: "app-a.mobile", revisionId: idA.revisionId, baseRevisionId: nil, contentHash: idA.contentHash, createdAt: createdAt, files: filesA)
        _ = try await store.stage(appId: "app-b", projectId: "app-b.mobile", revisionId: idB.revisionId, baseRevisionId: nil, contentHash: idB.contentHash, createdAt: createdAt, files: filesB)

        let sha = NativeObjectStore.hex(sharedBytes)
        let __mv1v1 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v1, 2)

        _ = try await store.gc.free(appId: "app-a", projectId: "app-a.mobile", revisionId: idA.revisionId)
        let __mv1v2b2 = await store.objects.exists(sha256: sha)
        XCTAssertTrue(__mv1v2b2, "app-b's reference must keep the object alive after app-a frees its own version")
        let __mv1v2 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2, 1)

        _ = try await store.gc.free(appId: "app-b", projectId: "app-b.mobile", revisionId: idB.revisionId)
        let __mv1v2b3 = await store.objects.exists(sha256: sha)
        XCTAssertFalse(__mv1v2b3, "once every reference is gone the object is finally collected")
    }

    // MARK: reclaim() ordering

    func testReclaimOrdersOldestCreatedAtFirstNeverByClock() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        // Three unrelated single-version apps, staged in an order that does
        // NOT match their createdAt order, so a clock-based sort and a
        // createdAt-based sort disagree if the code is wrong.
        let oldApp = try await versionsStageFixture(on: store, appId: "app-old", projectId: "app-old.mobile", seed: 502, baseRevisionId: nil, createdAtOffset: -1000)
        let midApp = try await versionsStageFixture(on: store, appId: "app-mid", projectId: "app-mid.mobile", seed: 503, baseRevisionId: nil, createdAtOffset: -500)
        let newApp = try await versionsStageFixture(on: store, appId: "app-new", projectId: "app-new.mobile", seed: 504, baseRevisionId: nil, createdAtOffset: -10)

        let candidates = [
            NativeVersionReclaimCandidate(appId: "app-new", projectId: "app-new.mobile", revisionId: newApp, createdAt: VersionsFixture.isoNow(offsetSeconds: -10)),
            NativeVersionReclaimCandidate(appId: "app-old", projectId: "app-old.mobile", revisionId: oldApp, createdAt: VersionsFixture.isoNow(offsetSeconds: -1000)),
            NativeVersionReclaimCandidate(appId: "app-mid", projectId: "app-mid.mobile", revisionId: midApp, createdAt: VersionsFixture.isoNow(offsetSeconds: -500)),
        ]

        // Target bytes large enough for exactly one version's worth, so
        // only the single oldest candidate should be freed.
        let oldAppFiles = try await store.manifests.read(appId: "app-old", projectId: "app-old.mobile", revisionId: oldApp).files
        var oneVersionBytes = 0
        for file in oldAppFiles { oneVersionBytes += try await store.objects.allocatedBytes(sha256: file.sha256) }

        let freed = try await store.gc.reclaim(candidates: candidates, targetBytes: max(1, oneVersionBytes))
        XCTAssertEqual(freed.map(\.revisionId), [oldApp], "reclaim must free the oldest createdAt first, regardless of staging order")
    }

    // MARK: mark-and-sweep

    func testMarkAndSweepNeverDeletesAReferencedObject() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 505, baseRevisionId: nil, createdAtOffset: -300)
        let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)

        _ = try await store.gc.markAndSweep(graceSeconds: 0)

        for file in manifest.files {
            let __mv1v2b4 = await store.objects.exists(sha256: file.sha256)
            XCTAssertTrue(__mv1v2b4)
        }
    }

    func testMarkAndSweepRespectsTenMinuteGracePeriod() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()

        // A fresh, unreferenced object (an in-flight stage, not yet
        // manifested): must never be swept even though nothing references
        // it, because it might be seconds away from a manifest rename.
        let freshOrphan = try await store.objects.write(Data("in-flight".utf8))
        // An aged, unreferenced object: safe to sweep.
        let agedOrphan = try await store.objects.write(Data("truly-orphaned".utf8))
        let old = Date().addingTimeInterval(-3600)
        let __mv1v2b5 = await store.objects.path(forSHA256: agedOrphan).path
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: __mv1v2b5)

        let swept = try await store.gc.markAndSweep(graceSeconds: 600)
        XCTAssertFalse(swept.contains(freshOrphan), "an object younger than the grace period must never be swept")
        XCTAssertTrue(swept.contains(agedOrphan))
        let __mv1v2b6 = await store.objects.exists(sha256: freshOrphan)
        XCTAssertTrue(__mv1v2b6)
        let __mv1v2b7 = await store.objects.exists(sha256: agedOrphan)
        XCTAssertFalse(__mv1v2b7)
    }

    func testMarkAndSweepSelfHealsADriftedRefcount() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 506, baseRevisionId: nil, createdAtOffset: -300)
        let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)

        // Corrupt the refs table directly (simulating drift from a crash
        // that skipped the refs commit).
        try await store.refs.incrementAll(sha256Hexes: Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.sha256, 999) }))

        _ = try await store.gc.markAndSweep()
        for file in manifest.files {
            let __mv1v3 = try await store.refs.count(sha256: file.sha256)
            XCTAssertEqual(__mv1v3, 1, "mark-and-sweep must recompute the true count, not trust the drifted one")
        }
    }

    // MARK: Scale (SPEC section 3; see HANDOFF.md for why this is a
    // reduced-but-real mechanics check, not the full 19.2 MB x 1,000 x 50
    // table, that belongs to MV5's `revision-storage-benchmark`).

    func testScaleMechanicsAtReducedAppAndVersionCounts() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()

        let appCounts = [3, 100]
        let versionsPerApp = [1, 5]
        var report: [String] = []

        for appCount in appCounts {
            for versionCount in versionsPerApp {
                let label = "\(appCount)x\(versionCount)"
                let subroot = try VersionsTestRoot("scale-\(label)")
                defer { subroot.cleanup() }
                let subStore = try subroot.makeStore()

                let clock = ContinuousClock()
                let buildStart = clock.now
                for appIndex in 0..<appCount {
                    let app = "scale-app-\(appIndex)"
                    let project = "\(app).mobile"
                    var base: String?
                    for versionIndex in 0..<versionCount {
                        // SPEC's measured ~30% new bytes per update: reuse
                        // the seed for 70% of files (unchanged) and vary it
                        // for 30% by folding in the version index.
                        let seed = UInt64(appIndex * 1000) &+ UInt64(versionIndex < 1 ? 0 : versionIndex / 3)
                        let revisionId = try await versionsStageFixture(
                            on: subStore, appId: app, projectId: project, seed: seed,
                            fileCount: 6, averageBytesOverride: 2048,
                            baseRevisionId: base, createdAtOffset: TimeInterval(-1000 + versionIndex)
                        )
                        base = revisionId
                    }
                }
                let buildDuration = clock.now - buildStart

                // mobile-versions SPEC 3.2 is elapsed latency. Waiting on
                // I/O or an actor is part of a person's wait. Measure one
                // operation, without choosing a warmed best-of-three result.
                var manifestCount = 0
                let refreshStart = clock.now
                for appIndex in 0..<appCount {
                    manifestCount += try await subStore.manifests.list(appId: "scale-app-\(appIndex)", projectId: "scale-app-\(appIndex).mobile").count
                }
                let refreshDuration = clock.now - refreshStart

                let gcStart = clock.now
                _ = try await subStore.gc.markAndSweep()
                let gcDuration = clock.now - gcStart

                var totalAllocated = 0
                for sha in try await subStore.objects.allObjectHashes() {
                    totalAllocated += (try? await subStore.objects.allocatedBytes(sha256: sha)) ?? 0
                }

                XCTAssertEqual(manifestCount, appCount * versionCount, "[\(label)] manifest count must match apps x versions exactly")
                // mobile-versions SPEC 3.2, "My apps refresh": 500 ms at 100 apps x 5
                // versions (R8.10). This now includes that exact shape.
                // Listing manifests is a mechanics proxy, not end-to-end
                // My apps refresh acceptance; the runner must measure that.
                XCTAssertLessThan(refreshDuration, .milliseconds(500), "[\(label)] manifest-only refresh must stay under SPEC 3.2's 500 ms")
                XCTAssertLessThan(gcDuration, .seconds(1), "[\(label)] GC mark-and-sweep must stay under 1s at this scale (SPEC section 3.2)")

                report.append("\(label): manifests=\(manifestCount) build=\(buildDuration) refresh=\(refreshDuration) gc=\(gcDuration) allocatedBytes=\(totalAllocated)")
            }
        }

        // Printed for HANDOFF.md; this is the fact the gate quotes, not an
        // assertion against SPEC's full-size table (see note above).
        for line in report { print("[VersionsGCAndScaleTests scale] \(line)") }
    }
}
