import CryptoKit
import Foundation

@main
struct PackagedAPIInstallationChecks {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            print("Signed API installation check failed: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent("outputs/iris_kneecap_user_test_20260916/seamless_mobile_20260918/resumed_20260918/core-acceptance/api-install-binding-20260919/fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            count += 1
            guard try condition() else { throw Failure(message: message) }
        }
        func rejects(_ expected: NativePackagedAPIError? = nil, _ body: () throws -> Void) throws {
            count += 1
            do { try body() } catch let error as NativePackagedAPIError {
                guard expected == nil || error == expected else { throw Failure(message: "Expected \(String(describing: expected)), got \(error)") }
                return
            }
            throw Failure(message: "Expected rejection")
        }
        let key = Curve25519.Signing.PrivateKey()
        let keyID = "iris.synthetic.publisher"
        let verifier = try NativePackagedAPIVerifier(trustedPublisherKeys: [keyID: key.publicKey.rawRepresentation])
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let resources = repository.appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources")
        func installApp(_ name: String) async throws -> NativeShellLaunchOutcome {
            let bytes = try Data(contentsOf: resources.appendingPathComponent(name))
            let review = try await coordinator.reviewImport(packageBytes: bytes)
            _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
            try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
            return try await coordinator.launchActive(identity: review.identity)
        }
        let one = try await installApp("SafeDemo.irisapp")
        let identity = one.identity
        let apiRoot = root.appendingPathComponent("bindings")
        let store = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        try check(try store.installed(for: one.launch) == nil, "initial missing is unconfigured")
        try check(!FileManager.default.fileExists(atPath: apiRoot.path), "lookup must not create a store")
        let source = "globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__.adapter = async request => request.input;"
        func makePackage(_ launch: VerifiedLaunchDescriptor, changes: [String: Any] = [:]) throws -> Data {
            let code = Data(source.utf8)
            var payload: [String: Any] = [
                "version": 1, "sdkMajor": 1, "adapterId": "iris.synthetic.api", "adapterVersion": "1.0.0",
                "appId": identity.appId, "projectId": identity.projectId, "revisionId": launch.revisionId,
                "sourceSha256": NativeSecurity.sha256(code), "sourceBase64": code.base64EncodedString(),
                "capabilities": [] as [String]
            ]
            for (key, value) in changes { payload[key] = value }
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let signature = try key.signature(for: NativePackagedAPIVerifier.signingDomain + bytes)
            return try JSONSerialization.data(withJSONObject: [
                "format": NativePackagedAPIVerifier.format, "keyId": keyID,
                "payloadBase64": bytes.base64EncodedString(), "signatureBase64": signature.base64EncodedString()
            ], options: [.sortedKeys])
        }
        let bytes1 = try makePackage(one.launch)
        let emptyRegistry = try NativePackagedAPIVerifier()
        try rejects(.unknownPublisher) { _ = try emptyRegistry.verify(bytes1, identity: identity, revisionId: one.launchedRevisionId) }
        let wrongKey = Curve25519.Signing.PrivateKey()
        let wrongVerifier = try NativePackagedAPIVerifier(trustedPublisherKeys: [keyID: wrongKey.publicKey.rawRepresentation])
        try rejects(.invalidSignature) { _ = try wrongVerifier.verify(bytes1, identity: identity, revisionId: one.launchedRevisionId) }
        let installed1 = try store.install(bytes1, for: one.launch)
        try check(installed1.source == source, "verified source bytes")
        try check(installed1.identity == identity, "scope bound to actual Core launch")
        try check(installed1.revisionId == one.launchedRevisionId, "exact content revision")
        try check(try store.install(bytes1, for: one.launch) == installed1, "idempotent exact install")
        let reopened = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        try check(try reopened.installed(for: one.launch) == installed1, "durable signature recheck")
        let revoked = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: emptyRegistry)
        try rejects(.unknownPublisher) { _ = try revoked.installed(for: one.launch) }

        let two = try await installApp("SafeDemoUpdate.irisapp")
        try check(two.launchedRevisionId != one.launchedRevisionId, "actual app update")
        try check(try reopened.installed(for: two.launch) == nil, "update cannot inherit API")
        try rejects(.invalidScope) { _ = try reopened.install(bytes1, for: two.launch) }
        let bytes2 = try makePackage(two.launch, changes: ["adapterVersion": "2.0.0"])
        let installed2 = try reopened.install(bytes2, for: two.launch)
        try check(installed2.adapterVersion == "2.0.0", "independent version binding")
        try rejects(.immutableBindingConflict) { _ = try reopened.install(makePackage(two.launch, changes: ["adapterVersion": "2.0.1"]), for: two.launch) }
        try check(try reopened.installed(for: two.launch) == installed2, "conflict preserves prior API")
        try await coordinator.revert(identity: identity, to: one.launchedRevisionId)
        let restored = try await coordinator.launchActive(identity: identity)
        try check(try reopened.installed(for: restored.launch) == installed1, "revert restores exact API")
        let entries = try await coordinator.refreshLibrary()
        try check(entries.first?.revisions.count == 2, "version history preserved")
        try check(entries.first?.currentRevisionId == one.launchedRevisionId, "reverted pointer")

        let invalid: [([String: Any], NativePackagedAPIError)] = [
            (["version": 2], .unsupportedSDK), (["sdkMajor": 2], .unsupportedSDK),
            (["appId": "other"], .invalidScope), (["projectId": "other"], .invalidScope),
            (["capabilities": ["network"]], .unsupportedCapabilities),
            (["sourceSha256": "sha256:" + String(repeating: "0", count: 64)], .invalidSource),
            (["adapterVersion": "01.0.0"], .invalidSource), (["adapterVersion": "1.0"], .invalidSource),
            (["adapterId": "../arbitrary"], .invalidSource), (["providerKey": "not-a-credential"], .invalidEnvelope)
        ]
        for (changes, expected) in invalid {
            try rejects(expected) { _ = try verifier.verify(makePackage(one.launch, changes: changes), identity: identity, revisionId: one.launchedRevisionId) }
        }
        var envelope = try JSONSerialization.jsonObject(with: bytes1) as! [String: Any]
        var payload = Data(base64Encoded: envelope["payloadBase64"] as! String)!
        payload.append(32)
        envelope["payloadBase64"] = payload.base64EncodedString()
        try rejects(.invalidSignature) { _ = try verifier.verify(JSONSerialization.data(withJSONObject: envelope), identity: identity, revisionId: one.launchedRevisionId) }
        try rejects(.invalidEnvelope) { _ = try verifier.verify(Data(repeating: 32, count: NativePackagedAPIVerifier.maximumEnvelopeBytes + 1), identity: identity, revisionId: one.launchedRevisionId) }
        let names = try FileManager.default.contentsOfDirectory(at: apiRoot, includingPropertiesForKeys: nil)
        try check(names.filter { $0.pathExtension == "irisapi" }.count == 2, "exactly two immutable bindings")
        let firstFile = names.first { (try? Data(contentsOf: $0)) == bytes1 }!
        try Data("corrupt".utf8).write(to: firstFile)
        try rejects { _ = try reopened.installed(for: one.launch) }
        try FileManager.default.removeItem(at: firstFile)
        let ownedTarget = root.appendingPathComponent("synthetic-symlink-target")
        try bytes1.write(to: ownedTarget)
        try FileManager.default.createSymbolicLink(at: firstFile, withDestinationURL: ownedTarget)
        try rejects(.unsafeStorage) { _ = try reopened.installed(for: one.launch) }
        try check(try Data(contentsOf: ownedTarget) == bytes1, "symlink rejection preserves target")
        print("Signed API installation: \(count)/\(count) production checks passed. Real app review/stage/activate/update/revert; no provider/network/UI.")
    }
    struct Failure: Error { let message: String }
}
