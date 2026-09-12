//
//  IrisTestEnvironment.swift
//  leanring-buddy
//
//  Runtime identity and private storage locations for the separately built
//  Iris Test app. The ordinary Iris bundle remains on the ordinary locations.
//

import Foundation

nonisolated struct IrisRuntimeIdentity: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let applicationSupportDirectoryName: String
    let logsDirectoryName: String
    let keychainServiceName: String

    var isTestApplication: Bool {
        bundleIdentifier == IrisTestEnvironment.testBundleIdentifier
    }
}

public nonisolated enum IrisTestEnvironment {
    static let standardBundleIdentifier = "com.publikhq.iris"
    static let testBundleIdentifier = "com.publikhq.iris.test"

    static let standardIdentity = IrisRuntimeIdentity(
        bundleIdentifier: standardBundleIdentifier,
        displayName: "Iris",
        applicationSupportDirectoryName: "Iris",
        logsDirectoryName: "Iris",
        keychainServiceName: standardBundleIdentifier
    )

    static let testIdentity = IrisRuntimeIdentity(
        bundleIdentifier: testBundleIdentifier,
        displayName: "Iris Test",
        applicationSupportDirectoryName: "Iris Test",
        logsDirectoryName: "Iris Test",
        keychainServiceName: testBundleIdentifier
    )

    /// Pure mapping used by the runtime selector and isolated tests. Only the
    /// exact test bundle identifier enables the alternate identity.
    static func identity(forBundleIdentifier bundleIdentifier: String?) -> IrisRuntimeIdentity {
        bundleIdentifier == testBundleIdentifier ? testIdentity : standardIdentity
    }

    static var runtimeIdentity: IrisRuntimeIdentity {
        identity(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// True only for the separately configured Iris Test bundle.
    public static var isEnabled: Bool {
        runtimeIdentity.isTestApplication
    }

    public static var displayName: String { runtimeIdentity.displayName }
    public static var applicationSupportDirectoryName: String {
        runtimeIdentity.applicationSupportDirectoryName
    }
    public static var logsDirectoryName: String { runtimeIdentity.logsDirectoryName }
    public static var keychainServiceName: String { runtimeIdentity.keychainServiceName }

    /// The app-specific directory below `~/Library/Application Support`.
    public static var applicationSupportDirectory: URL {
        applicationSupportDirectory(
            for: runtimeIdentity, rootDirectory: applicationSupportRootDirectory
        )
    }

    /// Alias with an explicit URL suffix for callers that name URL values this
    /// way. Both names resolve to the same directory.
    public static var applicationSupportDirectoryURL: URL { applicationSupportDirectory }

    /// The app-specific directory below `~/Library/Logs`.
    public static var logsDirectory: URL {
        logsDirectory(for: runtimeIdentity, rootDirectory: logsRootDirectory)
    }

    public static var logsDirectoryURL: URL { logsDirectory }

    /// One private scratch root for the experimental app's local commands.
    public static var commandScratchDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("CommandScratch", isDirectory: true)
    }

    static func applicationSupportDirectory(
        for identity: IrisRuntimeIdentity, rootDirectory: URL
    ) -> URL {
        rootDirectory.appendingPathComponent(
            identity.applicationSupportDirectoryName, isDirectory: true
        )
    }

    static func logsDirectory(
        for identity: IrisRuntimeIdentity, rootDirectory: URL
    ) -> URL {
        rootDirectory.appendingPathComponent(identity.logsDirectoryName, isDirectory: true)
    }

    private static var applicationSupportRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static var logsRootDirectory: URL {
        let libraryDirectory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        // The Foundation library URL is `~/Library`; logs live one level below
        // it, matching the original `~/Library/Logs/Iris` location.
        return libraryDirectory.appendingPathComponent("Logs", isDirectory: true)
    }
}
