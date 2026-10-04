import CryptoKit
import Foundation

/// Builds real `DeliveryPackageV1` bytes by shelling out to the same real
/// desktop pipeline (`mobile-shell/desktop/cli.mjs` stage/approve/deliver)
/// that `native/Tests/Fixtures/generate-desktop-package.mjs` already uses for
/// `NativeShellLibraryCoordinatorTests`. This package does not modify that
/// script or the desktop package; it only invokes the existing fixture
/// generator as a subprocess, exactly as the Core test target does.
///
/// This is why persona scenarios exercise the real
/// `DeliveryPackageV1Validator` byte-for-byte instead of a hand-built stub:
/// the packages a scenario feeds into `NativeShellLibraryCoordinator` are the
/// same shape a real desktop-to-phone delivery would produce.
public struct GeneratedPackage: Sendable {
    public let bytes: Data
    public let revisionId: String
    public let contentHash: String
    public let appId: String
    public let projectId: String
    public let displayName: String
    public let capabilities: [String]

    /// SHA-256 of the raw package bytes, in the same "sha256:<hex>" shape
    /// `NativeSecurity.sha256` produces (that type is internal to
    /// IrisMobileShellCore, so this recomputes it independently rather than
    /// reaching into the module's private API).
    public var packageSHA256: String {
        "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PackageFixtureError: Error, CustomStringConvertible {
    case generatorFailed(String)
    case repositoryRootNotFound

    public var description: String {
        switch self {
        case .generatorFailed(let message): return "package fixture generator failed: \(message)"
        case .repositoryRootNotFound: return "could not locate mobile-shell/native/Tests/Fixtures from this package"
        }
    }
}

public enum PackageFixture {
    /// Generates one real, validator-passing package. `nonce` must be a
    /// distinct 64-character string per generated package (the delivery
    /// nonce replay guard rejects reuse); callers normally derive it from a
    /// scenario name plus an integer.
    public static func generate(
        content: String,
        baseRevisionId: String? = nil,
        nonce: String,
        capabilities: [String] = [],
        appId: String,
        projectId: String,
        displayName: String,
        namespace: String? = nil,
        workDirectory: URL
    ) throws -> GeneratedPackage {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let script = try fixtureGeneratorScript()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", workDirectory.path,
            "--base", baseRevisionId ?? "null",
            "--content", content,
            "--nonce", nonce,
            "--namespace", namespace ?? appId,
            "--capabilities", try jsonArrayString(capabilities),
            "--app", appId,
            "--project", projectId,
            "--display-name", displayName,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw PackageFixtureError.generatorFailed(String(data: errData, encoding: .utf8) ?? "unknown error")
        }
        guard let resultObject = try JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let packagePath = resultObject["packagePath"] as? String,
              let revisionId = resultObject["revisionId"] as? String,
              let contentHash = resultObject["contentHash"] as? String else {
            throw PackageFixtureError.generatorFailed("unexpected generator output: \(String(data: outData, encoding: .utf8) ?? "")")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: packagePath))
        return GeneratedPackage(
            bytes: bytes,
            revisionId: revisionId,
            contentHash: contentHash,
            appId: appId,
            projectId: projectId,
            displayName: displayName,
            capabilities: capabilities
        )
    }

    private static func fixtureGeneratorScript() throws -> URL {
        // This file lives at
        // mobile-shell/native/Tools/iris-mobile-user-sim/Sources/MobileUserSimKit/PackageFixture.swift
        // so five parents up is mobile-shell/native.
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MobileUserSimKit
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // iris-mobile-user-sim
            .deletingLastPathComponent() // Tools
            .deletingLastPathComponent() // native
        let script = nativeRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("generate-desktop-package.mjs", isDirectory: false)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw PackageFixtureError.repositoryRootNotFound
        }
        return script
    }

    private static func jsonArrayString(_ values: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: values)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
