import Foundation
import Testing
@testable import IrisEnvironment

@Suite("Iris Test identity and storage")
struct IrisTestEnvironmentTests {
    @Test("normal identity preserves the existing app names")
    func normalIdentityPreservesExistingNames() {
        let identity = IrisTestEnvironment.identity(
            forBundleIdentifier: IrisTestEnvironment.standardBundleIdentifier
        )

        #expect(identity.bundleIdentifier == "com.publikhq.iris")
        #expect(identity.displayName == "Iris")
        #expect(identity.applicationSupportDirectoryName == "Iris")
        #expect(identity.logsDirectoryName == "Iris")
        #expect(identity.keychainServiceName == "com.publikhq.iris")
        #expect(!identity.isTestApplication)
    }

    @Test("exact test bundle selects the isolated identity")
    func exactTestBundleSelectsIsolatedIdentity() {
        let identity = IrisTestEnvironment.identity(
            forBundleIdentifier: IrisTestEnvironment.testBundleIdentifier
        )

        #expect(identity.bundleIdentifier == "com.publikhq.iris.test")
        #expect(identity.displayName == "Iris Test")
        #expect(identity.applicationSupportDirectoryName == "Iris Test")
        #expect(identity.logsDirectoryName == "Iris Test")
        #expect(identity.keychainServiceName == "com.publikhq.iris.test")
        #expect(identity.isTestApplication)
        #expect(identity.keychainServiceName != IrisTestEnvironment.standardIdentity.keychainServiceName)
    }

    @Test("nearby and missing bundle identifiers do not enable test storage")
    func nearbyAndMissingBundleIdentifiersDoNotEnableTestStorage() {
        for bundleIdentifier in [
            nil,
            "com.publikhq.iris.testing",
            "com.publikhq.iris.test.helper",
            "com.publikhq.irisTests"
        ] {
            #expect(!IrisTestEnvironment.identity(forBundleIdentifier: bundleIdentifier).isTestApplication)
        }
    }

    @Test("derived paths use exact app-specific directory names")
    func derivedPathsUseExactAppSpecificDirectoryNames() {
        let applicationSupportRoot = URL(fileURLWithPath: "/fixture/Library/Application Support")
        let logsRoot = URL(fileURLWithPath: "/fixture/Library/Logs")
        let testIdentity = IrisTestEnvironment.testIdentity
        let standardIdentity = IrisTestEnvironment.standardIdentity

        #expect(
            IrisTestEnvironment.applicationSupportDirectory(
                for: standardIdentity, rootDirectory: applicationSupportRoot
            ).path == "/fixture/Library/Application Support/Iris"
        )
        #expect(
            IrisTestEnvironment.applicationSupportDirectory(
                for: testIdentity, rootDirectory: applicationSupportRoot
            ).path == "/fixture/Library/Application Support/Iris Test"
        )
        #expect(
            IrisTestEnvironment.logsDirectory(
                for: standardIdentity, rootDirectory: logsRoot
            ).path == "/fixture/Library/Logs/Iris"
        )
        #expect(
            IrisTestEnvironment.logsDirectory(
                for: testIdentity, rootDirectory: logsRoot
            ).path == "/fixture/Library/Logs/Iris Test"
        )
    }

    @Test("the test host's standard runtime URLs keep the original locations")
    func standardRuntimeURLsKeepOriginalLocations() {
        #expect(!IrisTestEnvironment.isEnabled)
        #expect(
            IrisTestEnvironment.applicationSupportDirectory.path
                .hasSuffix("/Library/Application Support/Iris")
        )
        #expect(
            IrisTestEnvironment.logsDirectory.path.hasSuffix("/Library/Logs/Iris")
        )
    }
}
