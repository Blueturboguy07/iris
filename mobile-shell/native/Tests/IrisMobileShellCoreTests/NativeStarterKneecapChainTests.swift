import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Round 6, prep A (goal G10): the Kneecap starter chain that ships inside
/// Iris ends on package 06 (the project-delete fix), read from the REAL bundled
/// files, not from a fixture.
///
/// Two people: Mia installs Iris fresh and must end on 06. Omar already has the
/// 05 build from the last TestFlight; the launch after updating must carry him
/// to 06 without touching his saved data folder.
///
/// The oracles do not come from the code under test: the 06 file's own hash and
/// revision id are the numbers written down in kneecap-bugpass DELETE_FIX.md
/// (sha256 e00e5161..., revision af6c8052...), and continuity is re-derived
/// from each file's own envelope.
final class NativeStarterKneecapChainTests: XCTestCase {
    private static let native = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let folder = native.appendingPathComponent("IrisMobileShellApp/Resources/Starter/Kneecap", isDirectory: true)

    private static let deleteFixSHA = "e00e5161be9fb556c4ca55f993aadcd6c2d56732dedb5c67433beca340e02956"
    private static let deleteFixRevision = "rev-sha256:af6c80522ef0b53a135843b1679b1e347ce69a0ec980036d0f7189a24bec0f34"
    private static let bugpassRevision = "rev-sha256:cc3101cfdc8b96dd6c9feb4795032f3f468d9ea15c67644ce04a13184472e3d7"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kneecap-chain-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var entry: NativeStarterCatalog.Entry {
        NativeStarterCatalog.entries.first { $0.label == "Kneecap" }!
    }

    private func bytes(_ names: [String]) throws -> [Data] {
        try names.map { try Data(contentsOf: Self.folder.appendingPathComponent($0)) }
    }

    private func envelope(_ data: Data) throws -> [String: Any] {
        let package = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(package["envelope"] as? [String: Any])
    }

    private func coordinator() -> NativeShellLibraryCoordinator {
        NativeShellLibraryCoordinator(
            rootURL: root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.storage", "web.media.photo-picker", "web.media.export"])
        )
    }

    /// The list names the file, the file is the reviewed one, and each file
    /// picks up exactly where the one before it ended.
    func testTheChainListEndsOnTheDeleteFixAndIsContiguousByTheFilesOwnEnvelopes() throws {
        XCTAssertEqual(entry.orderedFileNames.last, "06-deletefix.irisapp")
        XCTAssertEqual(entry.orderedFileNames.suffix(3), ["04-longclip.irisapp", "05-bugpass.irisapp", "06-deletefix.irisapp"])
        let files = try bytes(entry.orderedFileNames)
        XCTAssertEqual(SHA256.hash(data: files.last!).map { String(format: "%02x", $0) }.joined(), Self.deleteFixSHA)
        var previousRevision: String?
        for (index, data) in files.enumerated() {
            let env = try envelope(data)
            XCTAssertEqual(env["baseRevisionId"] as? String, previousRevision, "\(entry.orderedFileNames[index]) starts where the one before ended")
            previousRevision = env["revisionId"] as? String
        }
        XCTAssertEqual(previousRevision, Self.deleteFixRevision)
        XCTAssertEqual(try envelope(files[files.count - 2])["revisionId"] as? String, Self.bugpassRevision)
    }

    /// Mia: a fresh install runs the real bundled chain and Kneecap opens on 06.
    func testAFreshInstallEndsOnTheDeleteFix() async throws {
        let coordinator = coordinator()
        let chain = NativeStarterInstaller.AppChain(displayName: entry.displayName, orderedPackages: try bytes(entry.orderedFileNames))
        let results = await NativeStarterInstaller().installMissing([entry.label: chain], into: coordinator)
        guard case let .installed(_, finalRevisionId)? = results[entry.label] else {
            return XCTFail("expected an install, got \(String(describing: results[entry.label]))")
        }
        XCTAssertEqual(finalRevisionId, Self.deleteFixRevision)
        let identity = NativeShellAppIdentity(appId: "publik.kneecap", projectId: "publik.kneecap.mobile")
        let library = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(library?.currentRevisionId, Self.deleteFixRevision)
        let launched = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launched.launchedRevisionId, Self.deleteFixRevision)
        XCTAssertFalse(launched.didFallback)
    }

    /// Omar: already on 05. The next launch moves him to 06, and the folder the
    /// app keeps his projects in is byte-identical before and after.
    func testAnExistingInstallOn05MovesTo06AndKeepsItsDataFolder() async throws {
        let coordinator = coordinator()
        let names = entry.orderedFileNames
        let upToBugpass = Array(names.dropLast())
        XCTAssertEqual(upToBugpass.last, "05-bugpass.irisapp")
        let old = NativeStarterInstaller.AppChain(displayName: entry.displayName, orderedPackages: try bytes(upToBugpass))
        let first = await NativeStarterInstaller().installMissing([entry.label: old], into: coordinator)
        guard case let .installed(_, oldRevision)? = first[entry.label] else { return XCTFail("05 install: \(String(describing: first[entry.label]))") }
        XCTAssertEqual(oldRevision, Self.bugpassRevision)
        let identity = NativeShellAppIdentity(appId: "publik.kneecap", projectId: "publik.kneecap.mobile")
        let dataDir = try await coordinator.readerDataDirectory(identity: identity, namespace: "publik.kneecap.v1")
        try Data("Omar's holiday timeline".utf8).write(to: dataDir.appendingPathComponent("project.json"))

        let updated = NativeStarterInstaller.AppChain(displayName: entry.displayName, orderedPackages: try bytes(names))
        let second = await NativeStarterInstaller().installMissing([entry.label: updated], into: coordinator)
        guard case let .installed(_, newRevision)? = second[entry.label] else { return XCTFail("06 update: \(String(describing: second[entry.label]))") }
        XCTAssertEqual(newRevision, Self.deleteFixRevision)
        let library = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(library?.currentRevisionId, Self.deleteFixRevision)
        XCTAssertEqual(try Data(contentsOf: dataDir.appendingPathComponent("project.json")), Data("Omar's holiday timeline".utf8))
    }
}
