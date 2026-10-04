import CryptoKit
import Foundation

public enum NativePackagedAPIError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unknownPublisher
    case invalidSignature
    case unsupportedSDK
    case invalidScope
    case invalidSource
    case unsupportedCapabilities
    case unsafeStorage
    case corruptStoredBundle
    case immutableBindingConflict
    case storageLimit
}

/// Produced only by verification against a Host-owned publisher key. Neither an
/// app manifest nor a downloaded envelope may supply its own trust root.
/// This authenticates adapter bytes; it is not an account or server credential.
public struct NativeVerifiedPackagedAPI: Equatable, Sendable {
    public let publisherKeyId: String
    public let adapterId: String
    public let adapterVersion: String
    public let identity: NativeShellAppIdentity
    public let revisionId: String
    public let sourceSHA256: String
    public let envelopeSHA256: String
    public let source: String
    fileprivate let envelope: Data

    fileprivate init(
        publisherKeyId: String, adapterId: String, adapterVersion: String,
        identity: NativeShellAppIdentity, revisionId: String,
        sourceSHA256: String, source: String, envelope: Data
    ) {
        self.publisherKeyId = publisherKeyId
        self.adapterId = adapterId
        self.adapterVersion = adapterVersion
        self.identity = identity
        self.revisionId = revisionId
        self.sourceSHA256 = sourceSHA256
        self.envelopeSHA256 = NativeSecurity.sha256(envelope)
        self.source = source
        self.envelope = envelope
    }
}

/// Transport-independent verification for a separately supplied API package.
/// No fetch, credential lookup, script execution or capability grant occurs here.
public struct NativePackagedAPIVerifier: Sendable {
    public static let format = "iris.packaged-api.signed.v1"
    public static let maximumEnvelopeBytes = 512 * 1024
    public static let maximumSourceBytes = 128 * 1024
    public static let signingDomain = Data("iris.packaged-api.v1\u{0}".utf8)
    private let trustedPublisherKeys: [String: Data]

    public init(trustedPublisherKeys: [String: Data] = [:]) throws {
        guard trustedPublisherKeys.count <= 16 else { throw NativePackagedAPIError.unknownPublisher }
        for (id, bytes) in trustedPublisherKeys {
            guard NativeSecurity.isStableId(id), bytes.count == 32,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)) != nil else {
                throw NativePackagedAPIError.unknownPublisher
            }
        }
        self.trustedPublisherKeys = trustedPublisherKeys
    }

    public func verify(
        _ envelopeBytes: Data,
        identity: NativeShellAppIdentity,
        revisionId: String
    ) throws -> NativeVerifiedPackagedAPI {
        guard NativeSecurity.isStableId(identity.appId), NativeSecurity.isStableId(identity.projectId),
              NativeSecurity.isRevisionId(revisionId) else { throw NativePackagedAPIError.invalidScope }
        guard !envelopeBytes.isEmpty, envelopeBytes.count <= Self.maximumEnvelopeBytes else {
            throw NativePackagedAPIError.invalidEnvelope
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: envelopeBytes) }
        catch { throw NativePackagedAPIError.invalidEnvelope }
        guard envelope.format == Self.format,
              let payload = Self.strictBase64(envelope.payloadBase64), !payload.isEmpty,
              payload.count <= 256 * 1024,
              let signature = Self.strictBase64(envelope.signatureBase64), signature.count == 64 else {
            throw NativePackagedAPIError.invalidEnvelope
        }
        guard let keyBytes = trustedPublisherKeys[envelope.keyId],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw NativePackagedAPIError.unknownPublisher
        }
        guard key.isValidSignature(signature, for: Self.signingDomain + payload) else {
            throw NativePackagedAPIError.invalidSignature
        }
        let body: Payload
        do { body = try JSONDecoder().decode(Payload.self, from: payload) }
        catch { throw NativePackagedAPIError.invalidEnvelope }
        guard body.version == 1, body.sdkMajor == 1 else { throw NativePackagedAPIError.unsupportedSDK }
        guard body.appId == identity.appId, body.projectId == identity.projectId,
              body.revisionId == revisionId else { throw NativePackagedAPIError.invalidScope }
        guard body.capabilities.isEmpty else { throw NativePackagedAPIError.unsupportedCapabilities }
        guard NativeSecurity.isStableId(body.adapterId), Self.validVersion(body.adapterVersion),
              let sourceBytes = Self.strictBase64(body.sourceBase64),
              !sourceBytes.isEmpty, sourceBytes.count <= Self.maximumSourceBytes,
              NativeSecurity.sha256(sourceBytes) == body.sourceSha256,
              let source = String(data: sourceBytes, encoding: .utf8),
              !source.contains("\u{0}"), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativePackagedAPIError.invalidSource
        }
        return NativeVerifiedPackagedAPI(
            publisherKeyId: envelope.keyId, adapterId: body.adapterId, adapterVersion: body.adapterVersion,
            identity: identity, revisionId: revisionId, sourceSHA256: body.sourceSha256,
            source: source, envelope: envelopeBytes
        )
    }

    private static func strictBase64(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }

    private static func validVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 32 && pieces.count == 3 && pieces.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                && ($0 == "0" || $0.first != "0")
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw NativePackagedAPIError.invalidEnvelope
        }
    }

    private struct Envelope: Decodable {
        let format: String
        let keyId: String
        let payloadBase64: String
        let signatureBase64: String
        enum CodingKeys: String, CodingKey { case format, keyId, payloadBase64, signatureBase64 }
        init(from decoder: Decoder) throws {
            try requireKeys(decoder, ["format", "keyId", "payloadBase64", "signatureBase64"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(String.self, forKey: .format)
            keyId = try c.decode(String.self, forKey: .keyId)
            payloadBase64 = try c.decode(String.self, forKey: .payloadBase64)
            signatureBase64 = try c.decode(String.self, forKey: .signatureBase64)
        }
    }

    private struct Payload: Decodable {
        let version: Int
        let sdkMajor: Int
        let adapterId: String
        let adapterVersion: String
        let appId: String
        let projectId: String
        let revisionId: String
        let sourceSha256: String
        let sourceBase64: String
        let capabilities: [String]
        enum CodingKeys: String, CodingKey {
            case version, sdkMajor, adapterId, adapterVersion, appId, projectId
            case revisionId, sourceSha256, sourceBase64, capabilities
        }
        init(from decoder: Decoder) throws {
            try requireKeys(decoder, ["version", "sdkMajor", "adapterId", "adapterVersion", "appId", "projectId", "revisionId", "sourceSha256", "sourceBase64", "capabilities"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            sdkMajor = try c.decode(Int.self, forKey: .sdkMajor)
            adapterId = try c.decode(String.self, forKey: .adapterId)
            adapterVersion = try c.decode(String.self, forKey: .adapterVersion)
            appId = try c.decode(String.self, forKey: .appId)
            projectId = try c.decode(String.self, forKey: .projectId)
            revisionId = try c.decode(String.self, forKey: .revisionId)
            sourceSha256 = try c.decode(String.self, forKey: .sourceSha256)
            sourceBase64 = try c.decode(String.self, forKey: .sourceBase64)
            capabilities = try c.decode([String].self, forKey: .capabilities)
        }
    }
}

/// Immutable API bindings keyed by the verified app/project/content revision.
/// Reopening or reverting re-verifies the signature with the CURRENT Host key
/// registry. Missing is unconfigured; corruption is an error, never missing.
/// Does not install/activate app content or change reader data/history.
@MainActor
public final class NativePackagedAPIInstallationStore {
    private let rootURL: URL
    private let verifier: NativePackagedAPIVerifier
    private let files = FileManager.default
    public static let maximumBindings = 256

    public init(rootURL: URL, verifier: NativePackagedAPIVerifier) throws {
        guard rootURL.isFileURL, rootURL.path != "/",
              (try? FileManager.default.destinationOfSymbolicLink(atPath: rootURL.path)) == nil else {
            throw NativePackagedAPIError.unsafeStorage
        }
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = URL(fileURLWithPath: resolvedRoot.path, isDirectory: true)
        self.verifier = verifier
    }

    @discardableResult
    public func install(_ bytes: Data, for launch: VerifiedLaunchDescriptor) throws -> NativeVerifiedPackagedAPI {
        guard let identity = launch.identity else { throw NativePackagedAPIError.invalidScope }
        // Verify before creating storage. A source-supplied key or capability
        // can never reach the durable installation record.
        let verified = try verifier.verify(bytes, identity: identity, revisionId: launch.revisionId)
        let target = try bindingURL(for: launch)
        if let existing = try read(target) {
            let prior = try verifier.verify(existing, identity: identity, revisionId: launch.revisionId)
            guard prior == verified else { throw NativePackagedAPIError.immutableBindingConflict }
            return prior
        }
        try ensureRoot()
        try requireBindingCapacity()
        let temporary = rootURL.appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? files.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: [.withoutOverwriting])
        try assertSafeRootIfPresent()
        // A hard-link promotion publishes complete bytes and cannot overwrite
        // an already-bound revision. Removing the temporary name leaves one link.
        do { try files.linkItem(at: temporary, to: target) }
        catch {
            if let existing = try read(target), existing == bytes { return verified }
            throw NativePackagedAPIError.immutableBindingConflict
        }
        return verified
    }

    public func installed(for launch: VerifiedLaunchDescriptor) throws -> NativeVerifiedPackagedAPI? {
        let target = try bindingURL(for: launch)
        guard let bytes = try read(target) else { return nil }
        guard let identity = launch.identity else { throw NativePackagedAPIError.invalidScope }
        return try verifier.verify(bytes, identity: identity, revisionId: launch.revisionId)
    }

    private func bindingURL(for launch: VerifiedLaunchDescriptor) throws -> URL {
        guard let identity = launch.identity, NativeSecurity.isStableId(identity.appId),
              NativeSecurity.isStableId(identity.projectId), NativeSecurity.isRevisionId(launch.revisionId) else {
            throw NativePackagedAPIError.invalidScope
        }
        let key = [identity.appId, identity.projectId, launch.revisionId].joined(separator: "\n")
        let digest = NativeSecurity.sha256(Data(key.utf8)).dropFirst("sha256:".count)
        return rootURL.appendingPathComponent(String(digest) + ".irisapi")
    }

    private func assertSafeRootIfPresent() throws {
        guard (try? files.destinationOfSymbolicLink(atPath: rootURL.path)) == nil,
              rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path else {
            throw NativePackagedAPIError.unsafeStorage
        }
        if files.fileExists(atPath: rootURL.path) {
            let a = try files.attributesOfItem(atPath: rootURL.path)
            guard a[.type] as? FileAttributeType == .typeDirectory else { throw NativePackagedAPIError.unsafeStorage }
        }
    }

    private func ensureRoot() throws {
        try assertSafeRootIfPresent()
        try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try assertSafeRootIfPresent()
    }

    private func requireBindingCapacity() throws {
        guard let enumerator = files.enumerator(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]
        ) else { throw NativePackagedAPIError.unsafeStorage }
        var entries = 0
        var bindings = 0
        for case let url as URL in enumerator {
            entries += 1
            if url.pathExtension == "irisapi" { bindings += 1 }
            guard entries <= 512, bindings < Self.maximumBindings else { throw NativePackagedAPIError.storageLimit }
        }
    }

    private func read(_ url: URL) throws -> Data? {
        try assertSafeRootIfPresent()
        guard (try? files.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw NativePackagedAPIError.unsafeStorage
        }
        guard files.fileExists(atPath: url.path) else { return nil }
        let a = try files.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let size = a[.size] as? NSNumber, size.intValue > 0,
              size.intValue <= NativePackagedAPIVerifier.maximumEnvelopeBytes else {
            throw NativePackagedAPIError.corruptStoredBundle
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: NativePackagedAPIVerifier.maximumEnvelopeBytes + 1) ?? Data()
        guard bytes.count == size.intValue else { throw NativePackagedAPIError.corruptStoredBundle }
        return bytes
    }
}
