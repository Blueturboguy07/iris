import Foundation

public protocol DeliveryPackageValidator: Sendable {
    func validate(
        packageBytes: Data,
        approvalAuthority: any DeliveryApprovalAuthority
    ) throws -> ContractValidatedDelivery
}

public protocol DeliveryApprovalAuthority: Sendable {
    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval?
}

/// A structurally/integrity-validated look at raw package bytes before any
/// approval authority has trusted them. The embedded approval is exposed only
/// so a host can show exactly what it is asking the reader to review.
public struct DeliveryPackageInspection: Equatable, Sendable {
    public let packageSHA256: String
    public let embeddedApproval: TrustedDeliveryApproval
    public let appId: String
    public let projectId: String
    public let baseRevisionId: String?
    public let revisionId: String
    public let contentHash: String
    public let deliveryNonce: String
    public let displayName: String
    public let minShellVersion: String
    public let requestedCapabilities: [String]
    public let dataNamespace: String

    public init(
        packageSHA256: String,
        embeddedApproval: TrustedDeliveryApproval,
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        revisionId: String,
        contentHash: String,
        deliveryNonce: String,
        displayName: String,
        minShellVersion: String,
        requestedCapabilities: [String],
        dataNamespace: String
    ) {
        self.packageSHA256 = packageSHA256
        self.embeddedApproval = embeddedApproval
        self.appId = appId
        self.projectId = projectId
        self.baseRevisionId = baseRevisionId
        self.revisionId = revisionId
        self.contentHash = contentHash
        self.deliveryNonce = deliveryNonce
        self.displayName = displayName
        self.minShellVersion = minShellVersion
        self.requestedCapabilities = requestedCapabilities
        self.dataNamespace = dataNamespace
    }
}

/// This authority exists only after an explicit local reader review. It is
/// deliberately named so callers cannot mistake local consent for authenticated
/// desktop identity. It can authorize exactly one validator lookup.
public final class LocalUserReviewApprovalAuthority: DeliveryApprovalAuthority, @unchecked Sendable {
    public let packageSHA256: String
    public let approval: TrustedDeliveryApproval

    private let lock = NSLock()
    private var wasConsumed = false

    public init(inspection: DeliveryPackageInspection) {
        packageSHA256 = inspection.packageSHA256
        approval = inspection.embeddedApproval
    }

    public func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        lock.lock()
        defer { lock.unlock() }
        guard !wasConsumed, approval.approvalId == approvalId else { return nil }
        wasConsumed = true
        return approval
    }
}

public struct TrustedDeliveryApproval: Equatable, Sendable {
    public let approvalId: String
    public let requestId: String?
    public let requestNonce: String?
    public let appId: String
    public let projectId: String
    public let baseRevisionId: String?
    public let approvedRevisionId: String
    public let approvedContentHash: String
    public let approvedAt: String

    public init(
        approvalId: String,
        requestId: String?,
        requestNonce: String?,
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        approvedRevisionId: String,
        approvedContentHash: String,
        approvedAt: String
    ) {
        self.approvalId = approvalId
        self.requestId = requestId
        self.requestNonce = requestNonce
        self.appId = appId
        self.projectId = projectId
        self.baseRevisionId = baseRevisionId
        self.approvedRevisionId = approvedRevisionId
        self.approvedContentHash = approvedContentHash
        self.approvedAt = approvedAt
    }
}

public struct DeliveryManifestReceipt: Equatable, Sendable {
    public let displayName: String
    public let runtimeType: String
    public let entrypoint: String
    public let minShellVersion: String
    public let requestedCapabilities: [String]
    public let dataNamespace: String
    public let dataUpdatePolicy: String

    public init(
        displayName: String,
        runtimeType: String,
        entrypoint: String,
        minShellVersion: String,
        requestedCapabilities: [String],
        dataNamespace: String,
        dataUpdatePolicy: String
    ) {
        self.displayName = displayName
        self.runtimeType = runtimeType
        self.entrypoint = entrypoint
        self.minShellVersion = minShellVersion
        self.requestedCapabilities = requestedCapabilities
        self.dataNamespace = dataNamespace
        self.dataUpdatePolicy = dataUpdatePolicy
    }
}

public struct DeliveryFileReceipt: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let mediaType: String
    public let data: Data

    public init(path: String, sha256: String, bytes: Int, mediaType: String, data: Data) {
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.mediaType = mediaType
        self.data = data
    }
}

/// A narrow result emitted only after the exact raw DeliveryPackageV1 bytes have
/// passed the native parity validator and a separately trusted approval lookup.
public struct ContractValidatedDelivery: Equatable, Sendable {
    public let contractVersion: Int
    public let appId: String
    public let projectId: String
    public let baseRevisionId: String?
    public let revisionId: String
    public let manifestHash: String
    public let contentHash: String
    public let createdAt: String
    public let deliveryNonce: String
    public let approvalId: String
    public let manifest: DeliveryManifestReceipt
    public let files: [DeliveryFileReceipt]
    /// Contract v1.1 (SPEC.md section 2.6): the plain-words feature title(s)
    /// this revision carries, covered by `contentHash` like every other
    /// revision field. `nil` (the default) for every revision that predates
    /// this field or simply never sets one; a shell shows "Update from
    /// <date>" in that case (MV4's job, not this type's).
    public let changes: [NativeVersionChange]?

    public init(
        contractVersion: Int,
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        revisionId: String,
        manifestHash: String,
        contentHash: String,
        createdAt: String,
        deliveryNonce: String,
        approvalId: String,
        manifest: DeliveryManifestReceipt,
        files: [DeliveryFileReceipt],
        changes: [NativeVersionChange]? = nil
    ) {
        self.contractVersion = contractVersion
        self.appId = appId
        self.projectId = projectId
        self.baseRevisionId = baseRevisionId
        self.revisionId = revisionId
        self.manifestHash = manifestHash
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.deliveryNonce = deliveryNonce
        self.approvalId = approvalId
        self.manifest = manifest
        self.files = files
        self.changes = changes
    }

    public var minShellVersion: String { manifest.minShellVersion }
    public var requestedCapabilities: [String] { manifest.requestedCapabilities }
    public var dataNamespace: String { manifest.dataNamespace }
    public var entrypoint: String { manifest.entrypoint }
}

public struct CapabilityPolicy: Equatable, Sendable {
    public let supportedCapabilities: Set<String>
    public let grantedNativeCapabilities: Set<String>

    public static let denyAll = CapabilityPolicy()

    public init(
        supportedCapabilities: Set<String> = [],
        grantedNativeCapabilities: Set<String> = []
    ) {
        self.supportedCapabilities = supportedCapabilities
        self.grantedNativeCapabilities = grantedNativeCapabilities
    }

    func validate(requested: [String]) throws {
        let requestedSet = Set(requested)
        let unsupported = requestedSet.subtracting(supportedCapabilities).sorted()
        if !unsupported.isEmpty {
            throw NativeShellError.unsupportedCapabilities(unsupported)
        }

        let nativeRequested = requestedSet.filter { $0.hasPrefix("native.") }
        let ungranted = Set(nativeRequested).subtracting(grantedNativeCapabilities).sorted()
        if !ungranted.isEmpty {
            throw NativeShellError.ungrantedNativeCapabilities(ungranted)
        }
    }
}

public struct StagedRevisionReceipt: Equatable, Sendable {
    public let revisionId: String
    public let alreadyStaged: Bool
}

public struct NativeRevisionSummary: Equatable, Sendable, Identifiable {
    public let appId: String
    public let projectId: String
    public let revisionId: String
    public let baseRevisionId: String?
    public let displayName: String
    public let dataNamespace: String
    public let requestedCapabilities: [String]
    public let createdAt: String
    /// Verified decoded content size, not exclusive APFS allocation. nil keeps
    /// older caller-constructed summaries honest instead of inventing zero.
    public let contentBytes: Int?
    /// Contract v1.1 (SPEC.md section 2.6): this revision's feature title(s),
    /// when the package carried one. `nil` for a revision published before
    /// this field existed, or one nobody gave a title to; MV4's Features
    /// page falls back to "Update from <date>" / "First version" in that
    /// case, never here (this type stays a plain fact carrier).
    public let changes: [NativeVersionChange]?

    public var id: String { revisionId }

    public init(
        appId: String,
        projectId: String,
        revisionId: String,
        baseRevisionId: String?,
        displayName: String,
        dataNamespace: String,
        requestedCapabilities: [String],
        createdAt: String,
        contentBytes: Int? = nil,
        changes: [NativeVersionChange]? = nil
    ) {
        self.appId = appId
        self.projectId = projectId
        self.revisionId = revisionId
        self.baseRevisionId = baseRevisionId
        self.displayName = displayName
        self.dataNamespace = dataNamespace
        self.requestedCapabilities = requestedCapabilities
        self.createdAt = createdAt
        self.contentBytes = contentBytes
        self.changes = changes
    }
}

public struct NativeVerifiedResourceReceipt: Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let mediaType: String
}

public struct VerifiedLaunchDescriptor: Equatable, Sendable {
    public let identity: NativeShellAppIdentity?
    public let revisionId: String
    public let entrypointURL: URL
    public let readAccessRootURL: URL
    public let webStorageIdentity: NativeWebStorageIdentity?
    /// Carried only from the verified installed revision. Downloaded JavaScript
    /// cannot grant itself permissions or change this presentation snapshot.
    public let requestedCapabilities: [String]
    public let resources: [NativeVerifiedResourceReceipt]

    init(
        identity: NativeShellAppIdentity? = nil,
        revisionId: String,
        entrypointURL: URL,
        readAccessRootURL: URL,
        webStorageIdentity: NativeWebStorageIdentity? = nil,
        requestedCapabilities: [String] = [],
        resources: [NativeVerifiedResourceReceipt] = []
    ) {
        self.identity = identity
        self.revisionId = revisionId
        self.entrypointURL = entrypointURL
        self.readAccessRootURL = readAccessRootURL
        self.webStorageIdentity = webStorageIdentity
        self.requestedCapabilities = requestedCapabilities
        self.resources = resources
    }
}

public enum NativeShellError: Error, Equatable, CustomStringConvertible {
    case invalidPackageJSON
    case packageTooLarge
    case invalidPackageField(String)
    case untrustedDeliveryApproval(String)
    case deliveryApprovalMismatch(String)
    case unsupportedContractVersion(Int)
    case invalidStableIdentifier(String)
    case invalidDeliveryNonce
    case invalidContentHash
    case invalidRevisionIdentity
    case invalidPackagePath(String)
    case duplicatePackagePath(String)
    case missingEntrypoint(String)
    case sourceOutsidePackage(String)
    case sourceSymlink(String)
    case sourceNotRegularFile(String)
    case byteCountMismatch(String)
    case hashMismatch(String)
    case appMismatch(expected: String, actual: String)
    case projectMismatch(expected: String, actual: String)
    case baseMismatch(expected: String?, actual: String?)
    case deliveryReplay
    case invalidShellVersion(String)
    case shellTooOld(required: String, actual: String)
    case unsupportedCapabilities([String])
    case ungrantedNativeCapabilities([String])
    case userDataNamespaceMismatch(expected: String, actual: String)
    case revisionNotStaged(String)
    case storedRevisionInvalid(String)
    case unsafeStorageNamespace(String)
    case noActiveRevision
    case noUsableFallback

    public var description: String {
        switch self {
        case .invalidPackageJSON: return "delivery package is not valid JSON"
        case .packageTooLarge: return "delivery package exceeds the v1 size limit"
        case .invalidPackageField(let field): return "invalid delivery package field: \(field)"
        case .untrustedDeliveryApproval(let approvalId): return "delivery approval is not trusted: \(approvalId)"
        case .deliveryApprovalMismatch(let approvalId): return "embedded delivery approval does not match trusted authority: \(approvalId)"
        case .unsupportedContractVersion(let version): return "unsupported contract version: \(version)"
        case .invalidStableIdentifier(let value): return "invalid stable identifier: \(value)"
        case .invalidDeliveryNonce: return "invalid delivery nonce"
        case .invalidContentHash: return "invalid content hash"
        case .invalidRevisionIdentity: return "revision id does not match content hash"
        case .invalidPackagePath(let path): return "invalid package path: \(path)"
        case .duplicatePackagePath(let path): return "duplicate package path: \(path)"
        case .missingEntrypoint(let path): return "entrypoint is absent from package files: \(path)"
        case .sourceOutsidePackage(let path): return "source is outside package directory: \(path)"
        case .sourceSymlink(let path): return "source contains a symbolic-link component: \(path)"
        case .sourceNotRegularFile(let path): return "source is not a regular file: \(path)"
        case .byteCountMismatch(let path): return "byte count mismatch: \(path)"
        case .hashMismatch(let path): return "SHA-256 mismatch: \(path)"
        case .appMismatch(let expected, let actual): return "app mismatch: expected \(expected), got \(actual)"
        case .projectMismatch(let expected, let actual): return "project mismatch: expected \(expected), got \(actual)"
        case .baseMismatch(let expected, let actual): return "base mismatch: expected \(expected ?? "nil"), got \(actual ?? "nil")"
        case .deliveryReplay: return "delivery nonce was already used"
        case .invalidShellVersion(let version): return "invalid shell version: \(version)"
        case .shellTooOld(let required, let actual): return "shell \(actual) is older than required \(required)"
        case .unsupportedCapabilities(let values): return "unsupported capabilities: \(values.joined(separator: ", "))"
        case .ungrantedNativeCapabilities(let values): return "ungranted native capabilities: \(values.joined(separator: ", "))"
        case .userDataNamespaceMismatch(let expected, let actual): return "user-data namespace mismatch: expected \(expected), got \(actual)"
        case .revisionNotStaged(let revision): return "revision is not staged: \(revision)"
        case .storedRevisionInvalid(let revision): return "stored revision is invalid: \(revision)"
        case .unsafeStorageNamespace(let path): return "storage namespace is unsafe: \(path)"
        case .noActiveRevision: return "no active revision"
        case .noUsableFallback: return "active revision is invalid and no usable fallback exists"
        }
    }
}
