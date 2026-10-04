import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore
#if canImport(WebKit)
import WebKit
#endif

/// RC-04, "Also delete my data" really deletes (round 6, prep A).
///
/// The oracle is the disk, read back by the test itself: directory listings and
/// byte counts under the store root, the permissions file, the Versions
/// objects folder, and (on the Mac, with a real WKWebView) the folder WebKit
/// keeps for the app's named data store. None of it asks the removal code what
/// it did.
///
/// The people simulated: Priya keeps a video editor called Kneecap with 6 MB
/// of saved clips and also a calorie app, Nut AI. She removes Kneecap with
/// "Also delete my data" ticked, then a week later reinstalls it. Sam removes
/// it without ticking, and expects his clips to be waiting when he comes back.
final class NativeAppRemovalTests: XCTestCase {
    private var fixture: RemovalFixture!
    private var coordinator: NativeShellLibraryCoordinator!
    private let kneecap = NativeShellAppIdentity(appId: "iris.removal-test.kneecap", projectId: "iris.removal-test.kneecap.mobile")
    private let nutAI = NativeShellAppIdentity(appId: "iris.removal-test.nutai", projectId: "iris.removal-test.nutai.mobile")

    override func setUpWithError() throws {
        fixture = try RemovalFixture()
        coordinator = NativeShellLibraryCoordinator(
            rootURL: fixture.storeRoot,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.storage"])
        )
    }

    override func tearDownWithError() throws {
        fixture.cleanup()
    }

    // MARK: the world

    /// Installs and activates one generated package; returns the web storage
    /// identifier the app really opens with (the oracle for "which store").
    @discardableResult
    private func install(_ identity: NativeShellAppIdentity, tag: String = "1", capabilities: String = "[\"web.storage\"]") async throws -> UUID? {
        let package = try fixture.package(for: identity, tag: tag, capabilities: capabilities)
        let review = try await coordinator.reviewImport(packageBytes: package.bytes)
        let staged = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
        )
        try await coordinator.activate(identity: identity, revisionId: staged.revisionId)
        let launched = try await coordinator.launchActive(identity: identity)
        return launched.launch.webStorageIdentity?.identifier
    }

    /// For an app that asked for web.storage: the identifier of the store it really opens with.
    @discardableResult
    private func installWithStorage(_ identity: NativeShellAppIdentity, tag: String = "1") async throws -> UUID {
        let identifier = try await install(identity, tag: tag)
        return try XCTUnwrap(identifier, "the app asked for web.storage")
    }

    /// Clips the app saved through the shell: real bytes in the app's reader data folder.
    private func saveClips(_ identity: NativeShellAppIdentity, megabytes: Int) async throws -> URL {
        let dir = try await coordinator.readerDataDirectory(identity: identity, namespace: identity.appId)
        var bytes = Data(count: megabytes * 1_048_576)
        bytes.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4_096) { buffer[index] = UInt8(truncatingIfNeeded: index >> 12) | 1 }
        }
        try bytes.write(to: dir.appendingPathComponent("holiday.mov"))
        try Data("timeline".utf8).write(to: dir.appendingPathComponent("project.json"))
        return dir
    }

    private func path(_ top: String, _ identity: NativeShellAppIdentity) -> URL {
        fixture.storeRoot.appendingPathComponent(top, isDirectory: true)
            .appendingPathComponent(identity.appId, isDirectory: true)
            .appendingPathComponent(identity.projectId, isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Path -> sha256 of every file under a folder.
    private func snapshot(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let item as URL in walker {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: item) else { continue }
            result[String(item.path.dropFirst(url.path.count))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func decisions(_ identity: NativeShellAppIdentity) -> [String] {
        // A brand new store object reads the file from disk.
        NativePermissionStore(rootURL: fixture.storeRoot).decidedCapabilities(for: identity).map(\.capability)
    }

    // MARK: Priya: remove with "Also delete my data" ticked

    func testRemoveWithDataDeletesTheAppsBytesAndNothingOfTheOtherApp() async throws {
        let kneecapStore = try await installWithStorage(kneecap)
        try await install(nutAI)
        _ = try await saveClips(kneecap, megabytes: 6)
        let nutData = try await saveClips(nutAI, megabytes: 1)
        let permissions = NativePermissionStore(rootURL: fixture.storeRoot)
        try permissions.setDecision(.granted, for: "web.media.photo-picker", identity: kneecap)
        try permissions.setDecision(.granted, for: "web.media.photo-picker", identity: nutAI)
        let nutBefore = snapshot(path("content", nutAI)).merging(snapshot(nutData)) { a, _ in a }
        let kneecapBytesBefore = treeBytes(path("content", kneecap)) + treeBytes(path("reader-data", kneecap))
        XCTAssertGreaterThan(kneecapBytesBefore, 6_000_000, "the clips are really on disk")
        let web = FakeWebStorage()

        let report = try await coordinator.removeApp(
            identity: kneecap, alsoDeleteData: true, webStorage: web, permissionStore: permissions
        )

        // Bytes gone from disk, read back.
        XCTAssertFalse(exists(path("content", kneecap)), "stored versions")
        XCTAssertFalse(exists(path("state", kneecap)), "active pointer, pins, delivery markers")
        XCTAssertFalse(exists(path("reader-data", kneecap)), "saved clips")
        XCTAssertEqual(treeBytes(fixture.storeRoot.appendingPathComponent("content/\(kneecap.appId)")), 0)
        XCTAssertEqual(decisions(kneecap), [], "what she allowed is forgotten")
        XCTAssertEqual(web.removed, [[kneecapStore]], "the app's own named WebKit store, the one it really opened with")
        // The report agrees with the disk (and is not trusted on its own).
        XCTAssertEqual(report.webStorageStoresRemoved, 1)
        XCTAssertEqual(report.permissionDecisionsForgotten, 1)
        XCTAssertGreaterThanOrEqual(report.dataBytesFreed, 6_000_000)
        XCTAssertGreaterThan(report.codeBytesFreed, 0)
        XCTAssertEqual(report.plainSummary(appName: "Kneecap"), "Removed Kneecap and deleted its saved data from this iPhone.")
        // The other app is exactly as it was, byte for byte.
        let nutAfter = snapshot(path("content", nutAI)).merging(snapshot(nutData)) { a, _ in a }
        XCTAssertEqual(nutAfter, nutBefore)
        XCTAssertEqual(decisions(nutAI), ["web.media.photo-picker"])
        // The per-app parent folders do not linger empty.
        XCTAssertTrue(exists(fixture.storeRoot.appendingPathComponent("content/\(nutAI.appId)")))
        XCTAssertFalse(exists(fixture.storeRoot.appendingPathComponent("content/\(kneecap.appId)")))
    }

    func testReinstallAfterRemovingWithDataStartsEmpty() async throws {
        try await install(kneecap)
        _ = try await saveClips(kneecap, megabytes: 2)
        try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: FakeWebStorage())
        try await install(kneecap)
        let dir = try await coordinator.readerDataDirectory(identity: kneecap, namespace: kneecap.appId)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "nothing of the old clips came back")
    }

    // MARK: Sam: remove without ticking it

    func testRemoveKeepingDataRemovesCodeOnlyAndTheClipsWaitForAReinstall() async throws {
        try await install(kneecap)
        let clips = try await saveClips(kneecap, megabytes: 3)
        let permissions = NativePermissionStore(rootURL: fixture.storeRoot)
        try permissions.setDecision(.granted, for: "web.media.photo-picker", identity: kneecap)
        let clipsBefore = snapshot(clips)
        let web = FakeWebStorage()

        let report = try await coordinator.removeApp(
            identity: kneecap, alsoDeleteData: false, webStorage: web, permissionStore: permissions
        )

        XCTAssertFalse(exists(path("content", kneecap)), "code is gone")
        XCTAssertFalse(exists(path("state", kneecap)))
        XCTAssertEqual(snapshot(clips), clipsBefore, "saved clips are byte-identical")
        XCTAssertEqual(decisions(kneecap), ["web.media.photo-picker"], "her earlier choice is kept")
        XCTAssertTrue(web.removed.isEmpty, "the WebKit store is left alone")
        XCTAssertEqual(report.webStorageStoresRemoved, 0)
        XCTAssertEqual(report.dataBytesFreed, 0)
        XCTAssertEqual(report.plainSummary(appName: "Kneecap"),
                       "Removed Kneecap. Its saved data stays on this iPhone in case you install it again.")

        try await install(kneecap)
        let dir = try await coordinator.readerDataDirectory(identity: kneecap, namespace: kneecap.appId)
        XCTAssertEqual(snapshot(dir), clipsBefore, "the clips are waiting after the reinstall")
    }

    // MARK: things going wrong

    /// The app was still open, so WebKit refuses to delete its store. Nothing
    /// else may have been touched, so she can close the app and try again.
    func testWebKitRefusalLeavesEverythingInPlaceAndARetryWorks() async throws {
        try await install(kneecap)
        let clips = try await saveClips(kneecap, megabytes: 1)
        let permissions = NativePermissionStore(rootURL: fixture.storeRoot)
        try permissions.setDecision(.granted, for: "web.media.photo-picker", identity: kneecap)
        let clipsBefore = snapshot(clips)
        let contentBefore = snapshot(path("content", kneecap))
        let refusing = FakeWebStorage(failure: NativeAppRemovalError.webStorageRemovalFailed("in use"))

        do {
            _ = try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: refusing, permissionStore: permissions)
            XCTFail("a refused store removal must throw")
        } catch let error as NativeAppRemovalError {
            XCTAssertEqual(error, .webStorageRemovalFailed("in use"))
        }

        XCTAssertEqual(snapshot(path("content", kneecap)), contentBefore, "still installed")
        XCTAssertEqual(snapshot(clips), clipsBefore, "clips untouched")
        XCTAssertEqual(decisions(kneecap), ["web.media.photo-picker"])
        let stillOpens = try await coordinator.launchActive(identity: kneecap)
        XCTAssertEqual(stillOpens.identity, kneecap, "the app still opens")

        let report = try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: FakeWebStorage(), permissionStore: permissions)
        XCTAssertGreaterThanOrEqual(report.dataBytesFreed, 1_000_000)
        XCTAssertFalse(exists(path("reader-data", kneecap)))
        XCTAssertFalse(exists(path("content", kneecap)))
    }

    /// An app that never asked for web storage has no named WebKit store, so
    /// there is nothing to ask WebKit for, and WebKit's mood cannot block the removal.
    func testAppWithoutWebStorageAsksWebKitForNothing() async throws {
        let plain = NativeShellAppIdentity(appId: "iris.removal-test.plain", projectId: "iris.removal-test.plain.mobile")
        let identifier = try await install(plain, capabilities: "[]")
        XCTAssertNil(identifier)
        let web = FakeWebStorage(failure: NativeAppRemovalError.webStorageRemovalFailed("should never be asked"))
        let report = try await coordinator.removeApp(identity: plain, alsoDeleteData: true, webStorage: web)
        XCTAssertEqual(report.webStorageStoresRemoved, 0)
        XCTAssertFalse(exists(path("content", plain)))
    }

    func testRemovingAnAppThatIsAlreadyGoneSucceedsAndReportsZero() async throws {
        let report = try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: FakeWebStorage())
        XCTAssertEqual(report.codeBytesFreed, 0)
        XCTAssertEqual(report.dataBytesFreed, 0)
        XCTAssertEqual(report.webStorageStoresRemoved, 0)
    }

    func testAnUnsafeIdentityIsRefusedAndNothingIsTouched() async throws {
        try await install(nutAI)
        let before = snapshot(fixture.storeRoot)
        for bad in [NativeShellAppIdentity(appId: "../content", projectId: "x"),
                    NativeShellAppIdentity(appId: nutAI.appId, projectId: "../../etc"),
                    NativeShellAppIdentity(appId: "", projectId: "")] {
            do {
                _ = try await coordinator.removeApp(identity: bad, alsoDeleteData: true, webStorage: FakeWebStorage())
                XCTFail("\(bad) must be refused")
            } catch {}
        }
        XCTAssertEqual(snapshot(fixture.storeRoot), before)
    }

    /// A link planted inside the app's data folder must never lead the delete
    /// out of the app: the link goes, the file it points at stays.
    func testALinkInsideTheDataFolderIsRemovedNotFollowed() async throws {
        try await install(kneecap)
        let outside = fixture.root.appendingPathComponent("someone-elses-photos", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("wedding.jpg"))
        let readerParent = path("reader-data", kneecap).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: readerParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path("reader-data", kneecap), withDestinationURL: outside)

        try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: FakeWebStorage())

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: path("reader-data", kneecap).path), "the link itself is gone")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("wedding.jpg")), Data("precious".utf8))
    }

    // MARK: Versions: objects, checkouts, refs

    /// Two apps share one identical file. Removing Kneecap with its data frees
    /// the objects only Kneecap used; the shared object and Nut AI's own stay.
    func testVersionsObjectsOnlyKneecapUsedAreDeletedAndSharedOnesSurvive() async throws {
        let world = try VersionsTestRoot()
        defer { world.cleanup() }
        let store = try world.makeStore()
        let objects = await store.objects, manifests = await store.manifests
        let checkouts = await store.checkouts, versionState = await store.state
        let shared = NativeVersionStagedFile(path: "vendor/lib.js", data: Data(repeating: 7, count: 9_000), mediaType: "text/javascript")
        let kneecapOnly = VersionsFixture.files(seed: 11, count: 3, averageBytes: 40_000)
        let nutOnly = VersionsFixture.files(seed: 22, count: 2, averageBytes: 30_000)

        func stage(_ identity: NativeShellAppIdentity, _ files: [NativeVersionStagedFile]) async throws {
            let created = VersionsFixture.isoNow()
            let ids = VersionsFixture.identity(appId: identity.appId, projectId: identity.projectId, baseRevisionId: nil, files: files, createdAt: created)
            try await store.stage(appId: identity.appId, projectId: identity.projectId, revisionId: ids.revisionId, baseRevisionId: nil,
                                  contentHash: ids.contentHash, createdAt: created, files: files)
            _ = try await store.activate(appId: identity.appId, projectId: identity.projectId, revisionId: ids.revisionId)
        }
        try await stage(kneecap, [shared] + kneecapOnly)
        try await stage(nutAI, [shared] + nutOnly)

        func hashes(_ files: [NativeVersionStagedFile]) -> Set<String> { Set(files.map { NativeObjectStore.hex($0.data) }) }
        let sharedHash = NativeObjectStore.hex(shared.data)
        let onDiskBefore = try objects.allObjectHashes()
        XCTAssertEqual(onDiskBefore, hashes([shared] + kneecapOnly + nutOnly))
        let objectBytesBefore = treeBytes(objects.root)
        let nutManifestsBefore = snapshot(manifests.root.appendingPathComponent(nutAI.appId))
        let nutCheckoutBefore = snapshot(checkouts.root.appendingPathComponent(nutAI.appId))
        XCTAssertFalse(nutCheckoutBefore.isEmpty)

        let report = try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true, webStorage: FakeWebStorage(), versionsStore: store)

        let onDiskAfter = try objects.allObjectHashes()
        XCTAssertEqual(onDiskAfter, hashes([shared] + nutOnly), "Kneecap's own objects are gone; the shared one and Nut AI's stay")
        XCTAssertTrue(onDiskAfter.contains(sharedHash))
        let objectBytesAfter = treeBytes(objects.root)
        XCTAssertLessThan(objectBytesAfter, objectBytesBefore)
        XCTAssertEqual(Int64(objectBytesBefore - objectBytesAfter), report.dataBytesFreed, "what the report says matches what left the disk")
        XCTAssertFalse(exists(checkouts.root.appendingPathComponent(kneecap.appId)), "checkouts")
        XCTAssertFalse(exists(manifests.root.appendingPathComponent(kneecap.appId)), "manifests")
        XCTAssertFalse(exists(versionState.directory(appId: kneecap.appId, projectId: kneecap.projectId)), "journal, pointer, Features ledger")
        XCTAssertEqual(snapshot(manifests.root.appendingPathComponent(nutAI.appId)), nutManifestsBefore)
        XCTAssertEqual(snapshot(checkouts.root.appendingPathComponent(nutAI.appId)), nutCheckoutBefore)
        // The shared object still has Nut AI's count, so removing Nut AI now deletes it too.
        try await coordinator.removeApp(identity: nutAI, alsoDeleteData: true, webStorage: FakeWebStorage(), versionsStore: store)
        XCTAssertEqual(try objects.allObjectHashes(), [], "with the last user gone the shared object goes as well")
    }

    // MARK: the real WebKit data store (Mac)

    #if canImport(WebKit) && canImport(AppKit)
    /// A real WKWebView writes localStorage into the app's named data store;
    /// removing with the toggle on deletes that store's folder from disk and
    /// its records; with the toggle off both are still there.
    @MainActor
    func testRealWebsiteDataStoreIsDeletedWithDataAndSurvivesWithout() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("named data stores need macOS 14") }
        let identifier = try await installWithStorage(kneecap)
        try await writeLocalStorage(kneecap, identifier: identifier)
        let folder = try XCTUnwrap(webKitStoreFolder(identifier), "WebKit created the app's named store folder")
        XCTAssertGreaterThan(treeBytes(folder), 0)
        let records = await recordCount(identifier)
        XCTAssertGreaterThan(records, 0, "the page's localStorage is in the store")

        // Toggle off: code goes, the store and its bytes stay.
        try await coordinator.removeApp(identity: kneecap, alsoDeleteData: false)
        XCTAssertTrue(exists(folder), "store folder kept")
        let recordsKept = await recordCount(identifier)
        XCTAssertGreaterThan(recordsKept, 0)

        // Reinstall finds the same store (same identity), then remove with the toggle on.
        let again = try await installWithStorage(kneecap)
        XCTAssertEqual(again, identifier, "same app, same named store")
        try await coordinator.removeApp(identity: kneecap, alsoDeleteData: true)
        XCTAssertFalse(exists(folder), "the store's folder is gone from disk")
        // Asked before anything touches the store again (opening it by identifier recreates it).
        let all = await WKWebsiteDataStore.allDataStoreIdentifiers
        XCTAssertFalse(all.contains(identifier), "WebKit no longer lists the store")
    }

    @MainActor
    private func writeLocalStorage(_ identity: NativeShellAppIdentity, identifier: UUID) async throws {
        _ = NSApplication.shared
        let launched = try await coordinator.launchActive(identity: identity)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        var view: WKWebView? = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        let loaded = expectation(description: "loaded")
        let waiter = LoadWaiter { loaded.fulfill() }
        view?.navigationDelegate = waiter
        view?.loadFileURL(launched.launch.entrypointURL, allowingReadAccessTo: launched.launch.readAccessRootURL)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await view?.callAsyncJavaScript(
            "localStorage.setItem('draft', 'x'.repeat(200000)); return localStorage.length",
            arguments: [:], in: nil, contentWorld: .page
        )
        // Let WebKit flush to disk, then let go of the view so the store is not "in use".
        try await Task.sleep(nanoseconds: 3_000_000_000)
        view?.navigationDelegate = nil
        view = nil
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    }

    @MainActor
    @available(macOS 14.0, *)
    private func recordCount(_ identifier: UUID) async -> Int {
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        return await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).count
    }

    /// Where WebKit keeps a named store: <Library>/WebKit/<process>/WebsiteDataStore/<UUID>.
    private func webKitStoreFolder(_ identifier: UUID) -> URL? {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("WebKit", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker {
            if url.lastPathComponent.caseInsensitiveCompare(identifier.uuidString) == .orderedSame,
               url.deletingLastPathComponent().lastPathComponent == "WebsiteDataStore" { return url }
            if walker.level > 4 { walker.skipDescendants() }
        }
        return nil
    }
    #endif

    // MARK: helpers

    private func treeBytes(_ url: URL) -> Int {
        var total = 0
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.totalFileAllocatedSize ?? 0 }
        }
        return total
    }
}

/// A stand-in for WebKit's store removal that records what it was asked for.
private final class FakeWebStorage: NativeWebStorageRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[UUID]] = []
    private let failure: Error?
    init(failure: Error? = nil) { self.failure = failure }
    var removed: [[UUID]] { lock.lock(); defer { lock.unlock() }; return calls }
    func removeStores(identifiers: [UUID]) async throws {
        if let failure { throw failure }
        lock.lock(); calls.append(identifiers); lock.unlock()
    }
}

private final class RemovalFixture {
    let root: URL
    let storeRoot: URL
    private var cache: [String: Data] = [:]
    private var index = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-app-removal-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    struct Package { let bytes: Data }

    /// A real delivery package built by the repository's own desktop tooling
    /// (node), asking for web.storage so the app gets a named WebKit store.
    func package(for identity: NativeShellAppIdentity, tag: String, capabilities: String) throws -> Package {
        index += 1
        let output = root.appendingPathComponent("package-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = repositoryRoot().appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let nonce = SHA256.hash(data: Data("\(identity.appId)-\(tag)".utf8)).map { String(format: "%02x", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path, "--output", output.path, "--base", "null",
            "--content", "<!doctype html><meta charset=utf-8><title>\(identity.appId)</title><main>hello</main>",
            "--nonce", nonce, "--namespace", identity.appId, "--capabilities", capabilities,
            "--app", identity.appId, "--project", identity.projectId,
        ]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RemovalFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: err, encoding: .utf8) ?? "generator failed"])
        }
        guard let object = try JSONSerialization.jsonObject(with: out) as? [String: Any],
              let packagePath = object["packagePath"] as? String else {
            throw NSError(domain: "RemovalFixture", code: 2)
        }
        return Package(bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
