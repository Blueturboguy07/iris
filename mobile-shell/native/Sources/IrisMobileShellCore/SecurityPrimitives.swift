import CryptoKit
import Foundation

enum NativeSecurity {
    static let sha256Prefix = "sha256:"
    static let revisionPrefix = "rev-sha256:"
    static let packageFormat = "iris.mobile-shell.package+json"
    static let maximumPackageFiles = 256
    static let maximumDecodedPackageBytes = 32 * 1024 * 1024
    static let maximumSingleFileBytes = 16 * 1024 * 1024
    static let maximumPackageJSONBytes = 48 * 1024 * 1024
    static let knownCapabilities: Set<String> = [
        "native.camera",
        "native.haptics",
        "native.microphone",
        "native.photo-library",
        "native.share",
        "web.media.camera",
        "web.media.export",
        "web.media.microphone",
        "web.media.photo-picker",
        "web.navigation.external",
        "web.network.same-origin",
        "web.storage",
    ]

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return sha256Prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func revisionId(forContentHash value: String) -> String? {
        guard isSHA256(value) else { return nil }
        return revisionPrefix + value.dropFirst(sha256Prefix.count)
    }

    static func isSHA256(_ value: String) -> Bool {
        guard value.count == sha256Prefix.count + 64, value.hasPrefix(sha256Prefix) else { return false }
        return value.dropFirst(sha256Prefix.count).allSatisfy(isLowerHex)
    }

    static func isRevisionId(_ value: String) -> Bool {
        guard value.count == revisionPrefix.count + 64, value.hasPrefix(revisionPrefix) else { return false }
        return value.dropFirst(revisionPrefix.count).allSatisfy(isLowerHex)
    }

    static func isStableId(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count else { return false }
        guard let first = value.utf8.first, isLowerAlphaNumeric(first) else { return false }
        return value.utf8.allSatisfy { byte in
            isLowerAlphaNumeric(byte) || byte == 46 || byte == 95 || byte == 45
        }
    }

    static func isNonce(_ value: String) -> Bool {
        guard (32...256).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 45
        }
    }

    static func isOpaqueId(_ value: String) -> Bool {
        guard (8...160).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count else { return false }
        guard let first = value.utf8.first, isASCIILetterOrNumber(first) else { return false }
        return value.utf8.allSatisfy { byte in
            isASCIILetterOrNumber(byte) || byte == 46 || byte == 95 || byte == 58 || byte == 45
        }
    }

    static func isMediaType(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            isASCIILetterOrNumber(byte)
                || byte == 33 || byte == 35 || byte == 36 || byte == 38 || byte == 94
                || byte == 95 || byte == 46 || byte == 43 || byte == 45 || byte == 47
        }
    }

    static func isCanonicalISOInstant(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func isSafePackagePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf16.count <= 512 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.contains("\\") else { return false }
        guard !value.contains("?"), !value.contains("#"), !value.contains("%") else { return false }
        guard value.precomposedStringWithCanonicalMapping == value else { return false }
        guard !value.unicodeScalars.contains(where: { $0.value <= 0x1f || $0.value == 0x7f }) else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func hasStoragePathAlias(_ paths: [String]) -> Bool {
        let folded = paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        var seen = Set<String>()
        for path in folded {
            guard seen.insert(path).inserted else { return true }
        }
        for path in folded {
            let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.count > 1 else { continue }
            for end in 1..<segments.count {
                if seen.contains(segments.prefix(end).joined(separator: "/")) { return true }
            }
        }
        return false
    }

    static func compareSemver(_ left: String, _ right: String) -> ComparisonResult? {
        guard let lhs = semver(left), let rhs = semver(right) else { return nil }
        for index in 0..<3 where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// `changes` (contract v1.1, SPEC.md section 2.6) mirrors the JS side's
    /// `revisionIdentityPayload` exactly: omitted from the payload entirely
    /// when `nil` (so every hash computed before this field existed is
    /// bit-for-bit unchanged), and, when present, its array ORDER is kept
    /// as given (unlike `files`, which is sorted by path) -- only each
    /// entry's own three keys are canonicalized (object keys always sort
    /// alphabetically here, matching `canonicalJSONString`).
    static func revisionIdentity(
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        manifest: DeliveryManifestReceipt,
        files: [DeliveryFileReceipt],
        changes: [NativeVersionChange]? = nil
    ) -> (manifestHash: String, contentHash: String, revisionId: String) {
        let manifestValue = canonicalManifest(manifest, appId: appId, projectId: projectId)
        let normalizedFiles = files
            .sorted { canonicalStringLessThan($0.path, $1.path) }
            .map { file in
                CanonicalJSONValue.object([
                    "bytes": .integer(file.bytes),
                    "mediaType": .string(file.mediaType),
                    "path": .string(file.path),
                    "sha256": .string(file.sha256),
                ])
            }
        var payloadFields: [String: CanonicalJSONValue] = [
            "appId": .string(appId),
            "baseRevisionId": baseRevisionId.map(CanonicalJSONValue.string) ?? .null,
            "files": .array(normalizedFiles),
            "manifest": manifestValue,
            "projectId": .string(projectId),
        ]
        if let changes {
            payloadFields["changes"] = .array(changes.map { change in
                CanonicalJSONValue.object([
                    "kind": .string(change.kind.rawValue),
                    "target": change.target.map(CanonicalJSONValue.string) ?? .null,
                    "title": .string(change.title),
                ])
            })
        }
        let payload = CanonicalJSONValue.object(payloadFields)
        let manifestHash = sha256(Data(manifestValue.encoded().utf8))
        let contentHash = sha256(Data(payload.encoded().utf8))
        return (manifestHash, contentHash, revisionId(forContentHash: contentHash)!)
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func assertNoSymlinkComponents(from root: URL, to file: URL, fileManager: FileManager) throws {
        let rootURL = root.standardizedFileURL
        let fileURL = file.standardizedFileURL
        guard isDescendant(fileURL, of: rootURL) else {
            throw NativeShellError.sourceOutsidePackage(file.path)
        }

        let relative = fileURL.pathComponents.dropFirst(rootURL.pathComponents.count)
        var cursor = rootURL
        for component in relative {
            cursor.appendPathComponent(component, isDirectory: false)
            let attributes = try fileManager.attributesOfItem(atPath: cursor.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw NativeShellError.sourceSymlink(file.path)
            }
        }
    }

    private static func semver(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard part.allSatisfy({ $0.isNumber }), let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    private static func isLowerHex(_ character: Character) -> Bool {
        character.isNumber || ("a"..."f").contains(String(character))
    }

    private static func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIILetterOrNumber(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func canonicalManifest(
        _ manifest: DeliveryManifestReceipt,
        appId: String,
        projectId: String
    ) -> CanonicalJSONValue {
        CanonicalJSONValue.object([
            "appId": .string(appId),
            "capabilities": .array(
                manifest.requestedCapabilities
                    .sorted(by: canonicalStringLessThan)
                    .map(CanonicalJSONValue.string)
            ),
            "data": .object([
                "namespace": .string(manifest.dataNamespace),
                "updatePolicy": .string(manifest.dataUpdatePolicy),
            ]),
            "displayName": .string(manifest.displayName),
            "kind": .string("iris.mobile-shell.manifest"),
            "projectId": .string(projectId),
            "runtime": .object([
                "entrypoint": .string(manifest.entrypoint),
                "minShellVersion": .string(manifest.minShellVersion),
                "type": .string(manifest.runtimeType),
            ]),
            "version": .integer(1),
        ])
    }

    private static func canonicalStringLessThan(_ left: String, _ right: String) -> Bool {
        left.utf16.lexicographicallyPrecedes(right.utf16)
    }
}

private indirect enum CanonicalJSONValue {
    case object([String: CanonicalJSONValue])
    case array([CanonicalJSONValue])
    case string(String)
    case integer(Int)
    case null

    func encoded() -> String {
        switch self {
        case .object(let object):
            let pairs = object.keys
                .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                .map { key in
                    "\(Self.quote(key)):\(object[key]!.encoded())"
                }
            return "{\(pairs.joined(separator: ","))}"
        case .array(let values):
            return "[\(values.map { $0.encoded() }.joined(separator: ","))]"
        case .string(let value):
            return Self.quote(value)
        case .integer(let value):
            return String(value)
        case .null:
            return "null"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x00...0x1f:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
