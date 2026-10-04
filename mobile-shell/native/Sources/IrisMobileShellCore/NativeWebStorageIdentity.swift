import CryptoKit
import Foundation

/// Stable WebKit storage identity for one verified app/project/data namespace.
///
/// The revision is deliberately excluded so approved revisions that preserve
/// the same declared data namespace resolve to the same WebKit data store.
/// Callers cannot supply a UUID directly; the identifier is derived from the
/// verified package identity tuple.
public struct NativeWebStorageIdentity: Equatable, Hashable, Sendable {
    public let identifier: UUID

    static let derivationNamespace = "iris.native-web-storage.v1"

    init(appId: String, projectId: String, dataNamespace: String) throws {
        guard NativeSecurity.isStableId(appId) else {
            throw NativeShellError.invalidStableIdentifier(appId)
        }
        guard NativeSecurity.isStableId(projectId) else {
            throw NativeShellError.invalidStableIdentifier(projectId)
        }
        guard NativeSecurity.isStableId(dataNamespace) else {
            throw NativeShellError.invalidStableIdentifier(dataNamespace)
        }

        var input = Data()
        Self.appendLengthPrefixed(Self.derivationNamespace, to: &input)
        Self.appendLengthPrefixed(appId, to: &input)
        Self.appendLengthPrefixed(projectId, to: &input)
        Self.appendLengthPrefixed(dataNamespace, to: &input)

        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // RFC 9562 UUIDv8 leaves the payload definition to the application.
        // Preserve the SHA-derived bits while marking a standards-valid custom
        // UUID and RFC variant. This also guarantees a nonzero identifier.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        identifier = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let utf8 = Array(value.utf8)
        var length = UInt64(utf8.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: utf8)
    }
}
