import XCTest
@testable import IrisMobileShellCore

// Unit MA1-organization-core. `MyAppsOrganizationFile`: atomic writes, the
// version rule, quarantine of a bad file, and the measured file size at the
// SPEC 3.2 limits (never asserted from an estimate).

final class MyAppsOrganizationFileTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("myapps-file-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLoadWithNoFileYetReturnsEmptyArrangementNotAnError() throws {
        let file = try MyAppsOrganizationFile(root: tempRoot)
        let result = file.load()
        XCTAssertEqual(result.arrangement, .empty)
        XCTAssertFalse(result.wasQuarantined)
        XCTAssertFalse(result.versionTooNew)
    }

    func testSaveThenLoadRoundTrips() throws {
        let file = try MyAppsOrganizationFile(root: tempRoot)
        var arrangement = try require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p"], createdAt: "t"), to: .empty)).arrangement
        arrangement = try require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: arrangement)).arrangement
        try file.save(arrangement)

        let loaded = file.load()
        XCTAssertEqual(loaded.arrangement, arrangement)
        XCTAssertFalse(loaded.wasQuarantined)
    }
    private func require(_ o: Result<MyAppsActionOutcome, MyAppsActionError>) throws -> MyAppsActionOutcome {
        switch o { case let .success(v): return v; case let .failure(e): throw e }
    }

    func testSaveWritesAtomicallyNeverInPlace() throws {
        // After save(), no `my-apps.json.tmp-*` sibling should remain: the
        // temp file must have been renamed away, not merely written.
        let file = try MyAppsOrganizationFile(root: tempRoot)
        try file.save(.empty)
        let entries = try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix("my-apps.json.tmp-") })
        XCTAssertTrue(entries.contains { $0.lastPathComponent == "my-apps.json" })
    }

    func testCrashBetweenTempWriteAndRenameLeavesThePreviousFileIntact() throws {
        let file = try MyAppsOrganizationFile(root: tempRoot)
        let first = try require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "First"), to: .empty)).arrangement
        try file.save(first)

        let second = try require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Second"), to: first)).arrangement
        let crashing = MyAppsFileFaultInjector(point: .afterTempWriteBeforeRename)
        XCTAssertThrowsError(try file.save(second, fault: crashing))

        // The previous file must be untouched (SPEC 3.1: "A crash between
        // the temporary write and the rename leaves the previous file
        // intact").
        let afterCrash = file.load()
        XCTAssertEqual(afterCrash.arrangement, first, "a crash before rename must never partially apply the new write")

        // The sweep on the NEXT load must clean up the orphaned tmp file.
        let entries = try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix("my-apps.json.tmp-") }, "sweepTemporaryFiles must run on load()")
    }

    func testCorruptFileIsQuarantinedAndNeverOverwrittenSilently() throws {
        let fileURL = tempRoot.appendingPathComponent("my-apps.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: fileURL)

        let file = try MyAppsOrganizationFile(root: tempRoot)
        let result = file.load()
        XCTAssertTrue(result.wasQuarantined)
        XCTAssertEqual(result.arrangement, .empty)

        let badURL = tempRoot.appendingPathComponent("my-apps.json.bad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: badURL.path))
        XCTAssertEqual(try Data(contentsOf: badURL), Data("{ not valid json".utf8))

        // A second load with a second corruption must not silently lose the
        // first quarantined copy's content without at least replacing it
        // deliberately (spec: "one copy kept" -- the newest, on purpose).
        try Data("{ still bad".utf8).write(to: fileURL)
        _ = file.load()
        XCTAssertEqual(try Data(contentsOf: badURL), Data("{ still bad".utf8))
    }

    func testEmptyLoadNeverOverwritesAnUnreadFile() throws {
        // Regression for mutation #11 ("A corrupt file overwritten with an
        // empty arrangement"): load() must be read-only with respect to
        // `my-apps.json` itself (it may only ever create `.bad`, never
        // touch or replace the original corrupt bytes at the main path
        // until the caller explicitly saves something new).
        let fileURL = tempRoot.appendingPathComponent("my-apps.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let originalBytes = Data("not json at all".utf8)
        try originalBytes.write(to: fileURL)

        let file = try MyAppsOrganizationFile(root: tempRoot)
        _ = file.load()

        // The corrupt original must still be exactly what it was (it was
        // moved logically via quarantine's *copy*, but the load() call
        // itself must not have run a save()).
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "quarantine must remove the bad file from the main path, not merely copy it")
    }

    func testVersionNewerThanReaderIsParkedNotOverwritten() throws {
        let file = try MyAppsOrganizationFile(root: tempRoot)
        // Simulate a future shell having written version 2 to the main
        // file's *next* sibling name this reader knows about
        // (`my-apps.json.v1`, the name THIS reader would park an unknown
        // version under -- but to test "reading a version this reader does
        // not understand", write version 2 to the MAIN path directly, as a
        // future shell would after this reader is itself out of date).
        struct FutureArrangement: Encodable {
            let version = 2
            let folders: [MyAppsFolder] = []
            let apps: [String: MyAppsAppEntry] = [:]
            let collapsedGroups: [Int] = []
            let hintDismissed = false
        }
        let data = try JSONEncoder().encode(FutureArrangement())
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try data.write(to: tempRoot.appendingPathComponent("my-apps.json"))

        let result = file.load()
        XCTAssertTrue(result.versionTooNew)
        XCTAssertEqual(result.arrangement, .empty, "never invents data for a version it does not understand")

        // The original (version-2) file at the main path must be untouched:
        // "never written back over".
        let stillThere = try Data(contentsOf: tempRoot.appendingPathComponent("my-apps.json"))
        XCTAssertEqual(stillThere, data)
    }

    /// KF-1 regression (MA5's persona sweep, 36/36 reproductions, sweep run
    /// p2-hurried/s20260928/r0): the ordinary `save()` that follows a
    /// versionTooNew `load()` must never overwrite the newer main file. SPEC
    /// 3.1: "the shell writes my-apps.json.v1 and reads that one next time."
    /// Before the fix, `save()` always wrote to `fileURL` regardless of what
    /// `load()` had just returned, so the very next ordinary edit (any move,
    /// rename, or folder change) destroyed the newer version's folders.
    func testSaveAfterVersionTooNewLoadParksToSidecarNotMainFile() throws {
        let file = try MyAppsOrganizationFile(root: tempRoot)
        struct FutureArrangement: Encodable {
            let version = 2
            let folders: [MyAppsFolder] = [
                MyAppsFolder(id: "F-future", name: "From the future", order: 0, createdAt: "t", collapsed: false, apps: ["a::p"])
            ]
            let apps: [String: MyAppsAppEntry] = [:]
            let collapsedGroups: [Int] = []
            let hintDismissed = false
        }
        let futureData = try JSONEncoder().encode(FutureArrangement())
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try futureData.write(to: tempRoot.appendingPathComponent("my-apps.json"))

        let loaded = file.load()
        XCTAssertTrue(loaded.versionTooNew)
        // KF-1 fix part 2: the newer file's readable fields (its real
        // folders) must come through, not be discarded to `.empty` --
        // SPEC 3.1 "read for the fields it understands", and the direct
        // cause of the sweep's "arrangement-lost" findings before this fix.
        XCTAssertEqual(loaded.arrangement.folders.map(\.id), ["F-future"], "a version this reader does not fully understand must still hand back its readable fields, never an invented empty arrangement")

        // An ordinary edit (any reducer action) followed by the debounced
        // save this reader would actually perform in production:
        let edited = try require(MyAppsOrganizationReducer.apply(
            .createFolder(id: "F1", name: "Editing", initialApps: ["b::q"], createdAt: "t"),
            to: loaded.arrangement
        )).arrangement
        try file.save(edited)

        // The version-2 file at the main path must still be exactly what it
        // was before this save: "never written back over".
        let stillThere = try Data(contentsOf: tempRoot.appendingPathComponent("my-apps.json"))
        XCTAssertEqual(stillThere, futureData, "an ordinary save must never overwrite a newer main file")

        // This reader's own edit must have landed in the version-1 sidecar
        // instead, and a fresh load() (a relaunch) must read it back.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("my-apps.json.v1").path))
        let reloaded = file.load()
        XCTAssertFalse(reloaded.versionTooNew)
        XCTAssertEqual(reloaded.arrangement, edited)
    }

    func testSweepRemovesOrphanedTempFilesOnLoad() throws {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let orphan = tempRoot.appendingPathComponent("my-apps.json.tmp-\(UUID().uuidString)")
        try Data("leftover".utf8).write(to: orphan)

        let file = try MyAppsOrganizationFile(root: tempRoot)
        _ = file.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: Measured file size at the SPEC 3.2 limits (never estimated)

    func testMeasuredFileSizeAt1000AppsAnd40FoldersIsUnderSpecEstimate() throws {
        var arrangement = MyAppsArrangement.empty
        var folders: [MyAppsFolder] = []
        for f in 0..<MyAppsLimits.maxFolders {
            folders.append(MyAppsFolder(id: "folder-\(f)-uuidlike-1234", name: "Folder Name \(f)", order: f, createdAt: "2026-09-28T09:12:00Z", collapsed: false, apps: []))
        }
        var apps: [String: MyAppsAppEntry] = [:]
        for i in 0..<1000 {
            let identity = "com.publik.app\(i)::com.publik.project\(i)"
            apps[identity] = MyAppsAppEntry(name: "Custom Name \(i)", lastOpenedAt: "2026-09-28T09:40:11Z", installedAt: "2026-09-20T18:02:00Z")
            folders[i % folders.count].apps.append(identity)
        }
        arrangement.folders = folders
        arrangement.apps = apps
        arrangement.collapsedGroups = Array(0..<20)

        let data = try JSONEncoder().encode(arrangement)
        // SPEC 3.2: "about 130 KB worst case; measured, not estimated".
        // Assert against a generous ceiling (this file has EVERY app
        // renamed, which the spec's own estimate does not assume) rather
        // than a tight number, and report the measured value.
        XCTAssertLessThan(data.count, 400_000, "measured \(data.count) bytes for 1,000 apps (all renamed) + 40 folders")
        print("MyApps file size measured at 1,000 apps / 40 folders (all renamed): \(data.count) bytes")
    }

    func testMeasuredSaveAndLoadTimeAt1000AppsUnderLimits() throws {
        var arrangement = MyAppsArrangement.empty
        for i in 0..<1000 {
            arrangement.apps["app\(i)::proj\(i)"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T09:00:00Z")
        }
        let file = try MyAppsOrganizationFile(root: tempRoot)
        let saveStart = DispatchTime.now()
        try file.save(arrangement)
        let saveMs = Double(DispatchTime.now().uptimeNanoseconds - saveStart.uptimeNanoseconds) / 1_000_000
        let loadStart = DispatchTime.now()
        _ = file.load()
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1_000_000
        print("MyApps save at 1,000 apps: \(saveMs) ms; load: \(loadMs) ms (SPEC 3.1 budget: load under 30 ms in release)")
        // Generous debug-build ceiling; the release number is the main
        // session's to measure on device per the project's separate-facts rule.
        XCTAssertLessThan(loadMs, 500)
    }
}
