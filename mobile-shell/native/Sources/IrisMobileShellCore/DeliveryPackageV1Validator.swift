import CoreFoundation
import Foundation

/// Strict native parity validator for the shared `iris.mobile-shell.package+json`
/// transport. Approval is authenticated by a caller-owned authority and never by
/// the package's embedded approval object.
public struct DeliveryPackageV1Validator: DeliveryPackageValidator, Sendable {
    public static let maximumRawPackageBytes = 48 * 1024 * 1024

    public init() {}

    /// Parses and verifies the complete package without treating its embedded
    /// approval as authenticated authority. Hosts use this only to render a
    /// review screen; staging still requires `validate(...approvalAuthority:)`.
    public func inspect(packageBytes: Data) throws -> DeliveryPackageInspection {
        guard packageBytes.count <= Self.maximumRawPackageBytes else {
            throw NativeShellError.packageTooLarge
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: packageBytes, options: [])
        } catch {
            throw NativeShellError.invalidPackageJSON
        }
        let package = try object(root, label: "package")
        try exactKeys(package, expected: ["approval", "envelope", "files", "format"], label: "package")
        guard try string(package["format"], label: "package.format") == NativeSecurity.packageFormat else {
            throw NativeShellError.invalidPackageField("package.format")
        }
        let embeddedApproval = try parseApproval(package["approval"])
        let delivery = try validate(
            packageBytes: packageBytes,
            approvalAuthority: InspectionOnlyApprovalAuthority(approval: embeddedApproval)
        )
        return DeliveryPackageInspection(
            packageSHA256: NativeSecurity.sha256(packageBytes),
            embeddedApproval: embeddedApproval,
            appId: delivery.appId,
            projectId: delivery.projectId,
            baseRevisionId: delivery.baseRevisionId,
            revisionId: delivery.revisionId,
            contentHash: delivery.contentHash,
            deliveryNonce: delivery.deliveryNonce,
            displayName: delivery.manifest.displayName,
            minShellVersion: delivery.minShellVersion,
            requestedCapabilities: delivery.requestedCapabilities,
            dataNamespace: delivery.dataNamespace
        )
    }

    public func validate(
        packageBytes: Data,
        approvalAuthority: any DeliveryApprovalAuthority
    ) throws -> ContractValidatedDelivery {
        guard packageBytes.count <= Self.maximumRawPackageBytes else {
            throw NativeShellError.packageTooLarge
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: packageBytes, options: [])
        } catch {
            throw NativeShellError.invalidPackageJSON
        }
        let package = try object(root, label: "package")
        try exactKeys(package, expected: ["approval", "envelope", "files", "format"], label: "package")
        guard try string(package["format"], label: "package.format") == NativeSecurity.packageFormat else {
            throw NativeShellError.invalidPackageField("package.format")
        }

        let embeddedApproval = try parseApproval(package["approval"])
        guard let trustedApproval = try approvalAuthority.trustedApproval(approvalId: embeddedApproval.approvalId) else {
            throw NativeShellError.untrustedDeliveryApproval(embeddedApproval.approvalId)
        }
        guard trustedApproval == embeddedApproval else {
            throw NativeShellError.deliveryApprovalMismatch(embeddedApproval.approvalId)
        }

        let envelope = try object(package["envelope"], label: "package.envelope")
        try exactKeys(
            envelope,
            expected: [
                "approvalId", "appId", "baseRevisionId", "contentHash", "deliveryNonce",
                "envelopeId", "issuedAt", "kind", "projectId", "revision", "revisionId", "version",
            ],
            label: "package.envelope"
        )
        guard try string(envelope["kind"], label: "envelope.kind") == "iris.mobile-shell.delivery-envelope" else {
            throw NativeShellError.invalidPackageField("envelope.kind")
        }
        try requireVersionOne(envelope["version"], label: "envelope.version")
        let envelopeId = try string(envelope["envelopeId"], label: "envelope.envelopeId")
        guard NativeSecurity.isOpaqueId(envelopeId) else { throw NativeShellError.invalidPackageField("envelope.envelopeId") }
        let deliveryNonce = try string(envelope["deliveryNonce"], label: "envelope.deliveryNonce")
        guard NativeSecurity.isNonce(deliveryNonce) else { throw NativeShellError.invalidDeliveryNonce }
        let envelopeApprovalId = try string(envelope["approvalId"], label: "envelope.approvalId")
        let appId = try string(envelope["appId"], label: "envelope.appId")
        let projectId = try string(envelope["projectId"], label: "envelope.projectId")
        let baseRevisionId = try nullableRevisionId(envelope["baseRevisionId"], label: "envelope.baseRevisionId")
        let envelopeRevisionId = try revisionId(envelope["revisionId"], label: "envelope.revisionId")
        let envelopeContentHash = try sha256(envelope["contentHash"], label: "envelope.contentHash")
        try requireCanonicalInstant(envelope["issuedAt"], label: "envelope.issuedAt")

        let parsedRevision = try parseRevision(envelope["revision"])
        guard parsedRevision.appId == appId,
              parsedRevision.projectId == projectId,
              parsedRevision.baseRevisionId == baseRevisionId,
              parsedRevision.revisionId == envelopeRevisionId,
              parsedRevision.contentHash == envelopeContentHash else {
            throw NativeShellError.invalidPackageField("envelope.revision binding")
        }
        guard envelopeApprovalId == embeddedApproval.approvalId,
              appId == embeddedApproval.appId,
              projectId == embeddedApproval.projectId,
              baseRevisionId == embeddedApproval.baseRevisionId,
              envelopeRevisionId == embeddedApproval.approvedRevisionId,
              envelopeContentHash == embeddedApproval.approvedContentHash else {
            throw NativeShellError.deliveryApprovalMismatch(embeddedApproval.approvalId)
        }

        let identity = NativeSecurity.revisionIdentity(
            appId: parsedRevision.appId,
            projectId: parsedRevision.projectId,
            baseRevisionId: parsedRevision.baseRevisionId,
            manifest: parsedRevision.manifest,
            files: parsedRevision.files.map {
                DeliveryFileReceipt(
                    path: $0.path,
                    sha256: $0.sha256,
                    bytes: $0.bytes,
                    mediaType: $0.mediaType,
                    data: Data()
                )
            },
            changes: parsedRevision.changes
        )
        guard identity.manifestHash == parsedRevision.manifestHash,
              identity.contentHash == parsedRevision.contentHash,
              identity.revisionId == parsedRevision.revisionId else {
            throw NativeShellError.invalidRevisionIdentity
        }

        let bodies = try array(package["files"], label: "package.files")
        guard bodies.count == parsedRevision.files.count,
              (1...NativeSecurity.maximumPackageFiles).contains(bodies.count) else {
            throw NativeShellError.invalidPackageField("package.files")
        }
        let descriptors = Dictionary(uniqueKeysWithValues: parsedRevision.files.map { ($0.path, $0) })
        var seenPaths = Set<String>()
        var decodedTotal = 0
        var deliveredFiles: [DeliveryFileReceipt] = []
        deliveredFiles.reserveCapacity(bodies.count)

        for (index, bodyValue) in bodies.enumerated() {
            let body = try object(bodyValue, label: "package.files[\(index)]")
            try exactKeys(body, expected: ["contentBase64", "mediaType", "path"], label: "package.files[\(index)]")
            let path = try string(body["path"], label: "package.files[\(index)].path")
            guard NativeSecurity.isSafePackagePath(path), seenPaths.insert(path).inserted else {
                throw NativeShellError.invalidPackagePath(path)
            }
            guard let descriptor = descriptors[path] else {
                throw NativeShellError.invalidPackageField("package.files[\(index)].path")
            }
            let mediaType = try string(body["mediaType"], label: "package.files[\(index)].mediaType")
            guard mediaType == descriptor.mediaType else {
                throw NativeShellError.invalidPackageField("package.files[\(index)].mediaType")
            }
            let encoded = try string(body["contentBase64"], label: "package.files[\(index)].contentBase64")
            let data = try decodeCanonicalBase64(encoded, declaredBytes: descriptor.bytes, path: path)
            decodedTotal += data.count
            guard decodedTotal <= NativeSecurity.maximumDecodedPackageBytes else {
                throw NativeShellError.packageTooLarge
            }
            guard NativeSecurity.sha256(data) == descriptor.sha256 else {
                throw NativeShellError.hashMismatch(path)
            }
            deliveredFiles.append(
                DeliveryFileReceipt(
                    path: path,
                    sha256: descriptor.sha256,
                    bytes: descriptor.bytes,
                    mediaType: descriptor.mediaType,
                    data: data
                )
            )
        }
        guard seenPaths.count == descriptors.count else {
            throw NativeShellError.invalidPackageField("package.files")
        }

        return ContractValidatedDelivery(
            contractVersion: 1,
            appId: parsedRevision.appId,
            projectId: parsedRevision.projectId,
            baseRevisionId: parsedRevision.baseRevisionId,
            revisionId: parsedRevision.revisionId,
            manifestHash: parsedRevision.manifestHash,
            contentHash: parsedRevision.contentHash,
            createdAt: parsedRevision.createdAt,
            deliveryNonce: deliveryNonce,
            approvalId: embeddedApproval.approvalId,
            manifest: parsedRevision.manifest,
            files: deliveredFiles,
            changes: parsedRevision.changes
        )
    }

    private func parseApproval(_ value: Any?) throws -> TrustedDeliveryApproval {
        let approval = try object(value, label: "package.approval")
        try exactKeys(
            approval,
            expected: [
                "approvalId", "appId", "approvedAt", "approvedContentHash", "approvedRevisionId",
                "baseRevisionId", "kind", "projectId", "requestId", "requestNonce", "version",
            ],
            label: "package.approval"
        )
        guard try string(approval["kind"], label: "approval.kind") == "iris.mobile-shell.delivery-approval" else {
            throw NativeShellError.invalidPackageField("approval.kind")
        }
        try requireVersionOne(approval["version"], label: "approval.version")
        let approvalId = try string(approval["approvalId"], label: "approval.approvalId")
        guard NativeSecurity.isOpaqueId(approvalId) else { throw NativeShellError.invalidPackageField("approval.approvalId") }
        let requestId = try nullableString(approval["requestId"], label: "approval.requestId")
        let requestNonce = try nullableString(approval["requestNonce"], label: "approval.requestNonce")
        guard (requestId == nil) == (requestNonce == nil) else {
            throw NativeShellError.invalidPackageField("approval request binding")
        }
        if let requestId, !NativeSecurity.isOpaqueId(requestId) {
            throw NativeShellError.invalidPackageField("approval.requestId")
        }
        if let requestNonce, !NativeSecurity.isNonce(requestNonce) {
            throw NativeShellError.invalidPackageField("approval.requestNonce")
        }
        let appId = try stableId(approval["appId"], label: "approval.appId")
        let projectId = try stableId(approval["projectId"], label: "approval.projectId")
        let baseRevisionId = try nullableRevisionId(approval["baseRevisionId"], label: "approval.baseRevisionId")
        let approvedRevisionId = try revisionId(approval["approvedRevisionId"], label: "approval.approvedRevisionId")
        let approvedContentHash = try sha256(approval["approvedContentHash"], label: "approval.approvedContentHash")
        guard NativeSecurity.revisionId(forContentHash: approvedContentHash) == approvedRevisionId else {
            throw NativeShellError.invalidRevisionIdentity
        }
        let approvedAt = try canonicalInstant(approval["approvedAt"], label: "approval.approvedAt")
        return TrustedDeliveryApproval(
            approvalId: approvalId,
            requestId: requestId,
            requestNonce: requestNonce,
            appId: appId,
            projectId: projectId,
            baseRevisionId: baseRevisionId,
            approvedRevisionId: approvedRevisionId,
            approvedContentHash: approvedContentHash,
            approvedAt: approvedAt
        )
    }

    private func parseRevision(_ value: Any?) throws -> ParsedRevision {
        let revision = try object(value, label: "envelope.revision")
        try exactKeys(
            revision,
            expected: [
                "appId", "baseRevisionId", "contentHash", "createdAt", "files", "kind", "manifest",
                "manifestHash", "projectId", "revisionId", "version",
            ],
            optional: ["changes"],
            label: "envelope.revision"
        )
        guard try string(revision["kind"], label: "revision.kind") == "iris.mobile-shell.revision" else {
            throw NativeShellError.invalidPackageField("revision.kind")
        }
        try requireVersionOne(revision["version"], label: "revision.version")
        let appId = try stableId(revision["appId"], label: "revision.appId")
        let projectId = try stableId(revision["projectId"], label: "revision.projectId")
        let baseRevisionId = try nullableRevisionId(revision["baseRevisionId"], label: "revision.baseRevisionId")
        let revisionId = try revisionId(revision["revisionId"], label: "revision.revisionId")
        let manifestHash = try sha256(revision["manifestHash"], label: "revision.manifestHash")
        let contentHash = try sha256(revision["contentHash"], label: "revision.contentHash")
        guard NativeSecurity.revisionId(forContentHash: contentHash) == revisionId else {
            throw NativeShellError.invalidRevisionIdentity
        }
        let createdAt = try canonicalInstant(revision["createdAt"], label: "revision.createdAt")
        let manifest = try parseManifest(revision["manifest"], expectedAppId: appId, expectedProjectId: projectId)
        let fileValues = try array(revision["files"], label: "revision.files")
        guard !fileValues.isEmpty, fileValues.count <= NativeSecurity.maximumPackageFiles else {
            throw NativeShellError.invalidPackageField("revision.files")
        }
        var seen = Set<String>()
        var totalBytes = 0
        var files: [ParsedFileDescriptor] = []
        for (index, fileValue) in fileValues.enumerated() {
            let file = try object(fileValue, label: "revision.files[\(index)]")
            try exactKeys(file, expected: ["bytes", "mediaType", "path", "sha256"], label: "revision.files[\(index)]")
            let path = try string(file["path"], label: "revision.files[\(index)].path")
            guard NativeSecurity.isSafePackagePath(path), seen.insert(path).inserted else {
                throw NativeShellError.invalidPackagePath(path)
            }
            let digest = try sha256(file["sha256"], label: "revision.files[\(index)].sha256")
            let byteCount = try integer(file["bytes"], label: "revision.files[\(index)].bytes")
            guard byteCount >= 0, byteCount <= NativeSecurity.maximumSingleFileBytes else {
                throw NativeShellError.packageTooLarge
            }
            totalBytes += byteCount
            guard totalBytes <= NativeSecurity.maximumDecodedPackageBytes else { throw NativeShellError.packageTooLarge }
            let mediaType = try string(file["mediaType"], label: "revision.files[\(index)].mediaType")
            guard NativeSecurity.isMediaType(mediaType) else {
                throw NativeShellError.invalidPackageField("revision.files[\(index)].mediaType")
            }
            files.append(ParsedFileDescriptor(path: path, sha256: digest, bytes: byteCount, mediaType: mediaType))
        }
        guard !NativeSecurity.hasStoragePathAlias(files.map(\.path)) else {
            throw NativeShellError.invalidPackageField("revision.files contains a storage path alias")
        }
        guard let entrypoint = files.first(where: { $0.path == manifest.entrypoint }), entrypoint.mediaType == "text/html" else {
            throw NativeShellError.missingEntrypoint(manifest.entrypoint)
        }
        let changes: [NativeVersionChange]?
        if let rawChanges = revision["changes"] {
            changes = try parseChanges(rawChanges, label: "revision.changes")
        } else {
            changes = nil
        }
        return ParsedRevision(
            appId: appId,
            projectId: projectId,
            baseRevisionId: baseRevisionId,
            revisionId: revisionId,
            manifestHash: manifestHash,
            contentHash: contentHash,
            createdAt: createdAt,
            manifest: manifest,
            files: files,
            changes: changes
        )
    }

    private func parseManifest(_ value: Any?, expectedAppId: String, expectedProjectId: String) throws -> DeliveryManifestReceipt {
        let manifest = try object(value, label: "revision.manifest")
        try exactKeys(
            manifest,
            expected: ["appId", "capabilities", "data", "displayName", "kind", "projectId", "runtime", "version"],
            label: "revision.manifest"
        )
        guard try string(manifest["kind"], label: "manifest.kind") == "iris.mobile-shell.manifest" else {
            throw NativeShellError.invalidPackageField("manifest.kind")
        }
        try requireVersionOne(manifest["version"], label: "manifest.version")
        let appId = try stableId(manifest["appId"], label: "manifest.appId")
        let projectId = try stableId(manifest["projectId"], label: "manifest.projectId")
        guard appId == expectedAppId, projectId == expectedProjectId else {
            throw NativeShellError.invalidPackageField("manifest app/project binding")
        }
        let displayName = try string(manifest["displayName"], label: "manifest.displayName")
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, displayName.utf16.count <= 120 else {
            throw NativeShellError.invalidPackageField("manifest.displayName")
        }
        let runtime = try object(manifest["runtime"], label: "manifest.runtime")
        try exactKeys(runtime, expected: ["entrypoint", "minShellVersion", "type"], label: "manifest.runtime")
        let runtimeType = try string(runtime["type"], label: "manifest.runtime.type")
        guard runtimeType == "web" else { throw NativeShellError.invalidPackageField("manifest.runtime.type") }
        let entrypoint = try string(runtime["entrypoint"], label: "manifest.runtime.entrypoint")
        guard NativeSecurity.isSafePackagePath(entrypoint) else { throw NativeShellError.invalidPackagePath(entrypoint) }
        let minShellVersion = try string(runtime["minShellVersion"], label: "manifest.runtime.minShellVersion")
        guard NativeSecurity.compareSemver(minShellVersion, minShellVersion) != nil else {
            throw NativeShellError.invalidShellVersion(minShellVersion)
        }
        let capabilityValues = try array(manifest["capabilities"], label: "manifest.capabilities")
        var seenCapabilities = Set<String>()
        var capabilities: [String] = []
        for (index, value) in capabilityValues.enumerated() {
            let capability = try string(value, label: "manifest.capabilities[\(index)]")
            guard NativeSecurity.knownCapabilities.contains(capability), seenCapabilities.insert(capability).inserted else {
                throw NativeShellError.invalidPackageField("manifest.capabilities[\(index)]")
            }
            capabilities.append(capability)
        }
        let data = try object(manifest["data"], label: "manifest.data")
        try exactKeys(data, expected: ["namespace", "updatePolicy"], label: "manifest.data")
        let dataNamespace = try stableId(data["namespace"], label: "manifest.data.namespace")
        let updatePolicy = try string(data["updatePolicy"], label: "manifest.data.updatePolicy")
        guard updatePolicy == "preserve" else { throw NativeShellError.invalidPackageField("manifest.data.updatePolicy") }
        return DeliveryManifestReceipt(
            displayName: displayName,
            runtimeType: runtimeType,
            entrypoint: entrypoint,
            minShellVersion: minShellVersion,
            requestedCapabilities: capabilities,
            dataNamespace: dataNamespace,
            dataUpdatePolicy: updatePolicy
        )
    }

    private func decodeCanonicalBase64(_ value: String, declaredBytes: Int, path: String) throws -> Data {
        let expectedEncodedLength = 4 * ((declaredBytes + 2) / 3)
        guard value.utf8.count == expectedEncodedLength,
              !value.isEmpty,
              value.utf8.count % 4 == 0,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 43 || byte == 47 || byte == 61
              }),
              let decoded = Data(base64Encoded: value, options: []),
              decoded.base64EncodedString() == value else {
            throw NativeShellError.invalidPackageField("file base64: \(path)")
        }
        guard decoded.count == declaredBytes else { throw NativeShellError.byteCountMismatch(path) }
        return decoded
    }

    private func object(_ value: Any?, label: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func array(_ value: Any?, label: String) throws -> [Any] {
        guard let value = value as? [Any] else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func exactKeys(_ object: [String: Any], expected: Set<String>, optional: Set<String> = [], label: String) throws {
        let allowed = expected.union(optional)
        let present = Set(object.keys)
        guard present.isSubset(of: allowed), expected.isSubset(of: present) else {
            throw NativeShellError.invalidPackageField("\(label) keys")
        }
    }

    private func exactKeys(_ object: [String: Any], expected: [String], optional: [String] = [], label: String) throws {
        try exactKeys(object, expected: Set(expected), optional: Set(optional), label: label)
    }

    /// Contract v1.1 `revision.changes` (SPEC.md section 2.6): optional,
    /// 1 to 32 entries, each an exact `{kind, target, title}` object. A
    /// shell too old to have this parser at all already refuses the whole
    /// package via `exactKeys` on `revision` itself (the key is simply not
    /// in its `optional` set); this only validates the entries once the
    /// key IS recognized.
    private func parseChanges(_ value: Any?, label: String) throws -> [NativeVersionChange] {
        let values = try array(value, label: label)
        guard (1...32).contains(values.count) else { throw NativeShellError.invalidPackageField(label) }
        var result: [NativeVersionChange] = []
        result.reserveCapacity(values.count)
        for (index, entry) in values.enumerated() {
            let itemLabel = "\(label)[\(index)]"
            let object = try object(entry, label: itemLabel)
            try exactKeys(object, expected: ["kind", "target", "title"], label: itemLabel)
            let title = try string(object["title"], label: "\(itemLabel).title")
            let hasControlCharacter = title.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
            guard !title.isEmpty, title.utf16.count <= 120, !hasControlCharacter else {
                throw NativeShellError.invalidPackageField("\(itemLabel).title")
            }
            let kindRaw = try string(object["kind"], label: "\(itemLabel).kind")
            guard let kind = NativeVersionChange.Kind(rawValue: kindRaw) else {
                throw NativeShellError.invalidPackageField("\(itemLabel).kind")
            }
            let target = try nullableRevisionId(object["target"], label: "\(itemLabel).target")
            result.append(NativeVersionChange(title: title, kind: kind, target: target))
        }
        return result
    }

    private func string(_ value: Any?, label: String) throws -> String {
        guard let value = value as? String else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func nullableString(_ value: Any?, label: String) throws -> String? {
        if value is NSNull { return nil }
        return try string(value, label: label)
    }

    private func integer(_ value: Any?, label: String) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              floor(number.doubleValue) == number.doubleValue,
              abs(number.doubleValue) <= 9_007_199_254_740_991,
              let integer = Int(exactly: number) else {
            throw NativeShellError.invalidPackageField(label)
        }
        return integer
    }

    private func requireVersionOne(_ value: Any?, label: String) throws {
        let version = try integer(value, label: label)
        guard version == 1 else { throw NativeShellError.unsupportedContractVersion(version) }
    }

    private func stableId(_ value: Any?, label: String) throws -> String {
        let value = try string(value, label: label)
        guard NativeSecurity.isStableId(value) else { throw NativeShellError.invalidStableIdentifier(value) }
        return value
    }

    private func sha256(_ value: Any?, label: String) throws -> String {
        let value = try string(value, label: label)
        guard NativeSecurity.isSHA256(value) else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func revisionId(_ value: Any?, label: String) throws -> String {
        let value = try string(value, label: label)
        guard NativeSecurity.isRevisionId(value) else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func nullableRevisionId(_ value: Any?, label: String) throws -> String? {
        if value is NSNull { return nil }
        return try revisionId(value, label: label)
    }

    private func canonicalInstant(_ value: Any?, label: String) throws -> String {
        let value = try string(value, label: label)
        guard NativeSecurity.isCanonicalISOInstant(value) else { throw NativeShellError.invalidPackageField(label) }
        return value
    }

    private func requireCanonicalInstant(_ value: Any?, label: String) throws {
        _ = try canonicalInstant(value, label: label)
    }
}

private struct InspectionOnlyApprovalAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private struct ParsedFileDescriptor {
    let path: String
    let sha256: String
    let bytes: Int
    let mediaType: String
}

private struct ParsedRevision {
    let appId: String
    let projectId: String
    let baseRevisionId: String?
    let revisionId: String
    let manifestHash: String
    let contentHash: String
    let createdAt: String
    let manifest: DeliveryManifestReceipt
    let files: [ParsedFileDescriptor]
    let changes: [NativeVersionChange]?
}
