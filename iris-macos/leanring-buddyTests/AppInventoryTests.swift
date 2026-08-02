//
//  AppInventoryTests.swift
//  leanring-buddyTests
//
//  Covers `AppInventoryService` and `ReleaseVersion` — which catalog apps are
//  on this Mac, and whether a newer release exists.
//
//  Nothing here touches what is actually installed on the machine running the
//  suite. The catalog is a fixed list handed to the service, and the lookup
//  from bundle identifier to app bundle is a stub that answers out of a
//  dictionary the test wrote. The only real filesystem work is on `.app`
//  bundles the test builds in its own temporary directory, which is deliberate:
//  reading `CFBundleShortVersionString` out of a real plist is the part most
//  worth exercising for real, and it is the part most likely to meet a bundle
//  with nothing useful in it.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

@MainActor
struct AppInventoryTests {

    // MARK: - unknown is not "not installed"

    @Test func anAppWithNoBundleIdentifierIsUnknownRatherThanMissing() async throws {
        // Nothing is installed as far as the stub is concerned, so the only
        // thing separating these two apps is whether the catalog knows an
        // identifier to look for.
        let inventoryService = AppInventoryService(
            catalogDirectory: StubbedCatalogAppDirectory(catalogApps: [
                CatalogAppDescriptor(
                    slug: "lunara",
                    name: "Lunara",
                    macBundleId: nil,
                    latestReleaseTag: "v1.0.0"
                ),
                CatalogAppDescriptor(
                    slug: "nitroai",
                    name: "NitroAI",
                    macBundleId: "com.nitroai.app",
                    latestReleaseTag: "v1.0.0"
                ),
            ]),
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: [:]
            )
        )

        await inventoryService.refreshInventory()

        let lunaraEntry = try #require(
            inventoryService.inventoryEntries.first { $0.slug == "lunara" }
        )
        #expect(lunaraEntry.installationState == .unknown)
        #expect(lunaraEntry.installationState != .notInstalled)
        // "I cannot tell" must never turn into a claim about an update either.
        #expect(lunaraEntry.updateAvailability == .unknown)

        let nitroEntry = try #require(
            inventoryService.inventoryEntries.first { $0.slug == "nitroai" }
        )
        #expect(nitroEntry.installationState == .notInstalled)

        // Neither app is shown: one is genuinely absent and the other cannot be
        // seen, and a row for either would be a statement Iris cannot make.
        #expect(inventoryService.installedEntriesForDisplay.isEmpty)
    }

    @Test func aBundleIdentifierThatIsPresentButBlankIsAlsoUnknown() async throws {
        // An empty string in the catalog is a configuration accident, not an
        // identifier. Looking it up would find nothing and report the app
        // missing, which is exactly the wrong answer.
        let installationState = AppInventoryService.installationState(
            forCatalogDescriptor: CatalogAppDescriptor(
                slug: "cue",
                name: "cue",
                macBundleId: "   ",
                latestReleaseTag: "v0.2.1"
            ),
            using: StubbedInstalledApplicationLocator(applicationBundleURLsByBundleIdentifier: [:])
        )
        #expect(installationState == .unknown)
    }

    // MARK: - Installed detection and version reading

    @Test func anInstalledAppReportsItsShortVersionString() async throws {
        let temporaryDirectory = try TemporaryApplicationBundleDirectory()
        defer { temporaryDirectory.removeEverything() }

        let simplicityBundleURL = try temporaryDirectory.makeApplicationBundle(
            named: "Simplicity.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.simplicity.desktop",
                "CFBundleShortVersionString": "0.1.0",
            ]
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: StubbedCatalogAppDirectory(catalogApps: [
                CatalogAppDescriptor(
                    slug: "simplicity",
                    name: "Simplicity",
                    macBundleId: "com.simplicity.desktop",
                    latestReleaseTag: "v0.1.0"
                ),
            ]),
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: [
                    "com.simplicity.desktop": simplicityBundleURL,
                ]
            )
        )

        await inventoryService.refreshInventory()

        let simplicityEntry = try #require(inventoryService.inventoryEntries.first)
        #expect(simplicityEntry.installationState == .installed(installedVersion: "0.1.0"))
        #expect(simplicityEntry.updateAvailability == .upToDate)
        #expect(inventoryService.installedEntriesForDisplay.map(\.slug) == ["simplicity"])
    }

    @Test func aBundleWithNoUsableVersionIsStillInstalledButClaimsNothingAboutUpdates() async throws {
        let temporaryDirectory = try TemporaryApplicationBundleDirectory()
        defer { temporaryDirectory.removeEverything() }

        // Three ways a version can be unusable: the key is missing entirely, the
        // value is not a string, and the whole plist is unreadable bytes.
        let bundleWithNoVersionKey = try temporaryDirectory.makeApplicationBundle(
            named: "NoVersionKey.app",
            infoPlistEntries: ["CFBundleIdentifier": "com.example.noversionkey"]
        )
        let bundleWithANumericVersion = try temporaryDirectory.makeApplicationBundle(
            named: "NumericVersion.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.example.numericversion",
                "CFBundleShortVersionString": 3 as NSNumber,
            ]
        )
        let bundleWithACorruptPlist = try temporaryDirectory.makeApplicationBundle(
            named: "CorruptPlist.app",
            rawInfoPlistBytes: Data("this is not a property list at all".utf8)
        )

        #expect(
            InstalledApplicationVersionReader.shortVersionString(
                forApplicationBundleAt: bundleWithNoVersionKey
            ) == nil
        )
        #expect(
            InstalledApplicationVersionReader.shortVersionString(
                forApplicationBundleAt: bundleWithANumericVersion
            ) == nil
        )
        #expect(
            InstalledApplicationVersionReader.shortVersionString(
                forApplicationBundleAt: bundleWithACorruptPlist
            ) == nil
        )
        // A path with no bundle at it at all reads as nil rather than throwing.
        #expect(
            InstalledApplicationVersionReader.shortVersionString(
                forApplicationBundleAt: temporaryDirectory.rootURL
                    .appendingPathComponent("NotThere.app")
            ) == nil
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: StubbedCatalogAppDirectory(catalogApps: [
                CatalogAppDescriptor(
                    slug: "whimprflow",
                    name: "WhimprFlow",
                    macBundleId: "com.example.noversionkey",
                    latestReleaseTag: "v9.9.9"
                ),
            ]),
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: [
                    "com.example.noversionkey": bundleWithNoVersionKey,
                ]
            )
        )
        await inventoryService.refreshInventory()

        let entry = try #require(inventoryService.inventoryEntries.first)
        // It is installed — that much is certain and worth showing. Whether it
        // is behind v9.9.9 is not knowable, so nothing is claimed.
        #expect(entry.installationState == .installed(installedVersion: nil))
        #expect(entry.updateAvailability == .unknown)
        #expect(entry.isInstalled)
    }

    // MARK: - Version comparison

    @Test func versionComparisonIsNumericRatherThanAlphabetical() async throws {
        // The bug this whole type exists to prevent: a string compare puts
        // "1.10.0" before "1.9.0" and would offer a downgrade as an update.
        #expect(ReleaseVersion.compare("1.10.0", to: "1.9.0") == .newerThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.9.0", to: "1.10.0") == .olderThanTheOtherVersion)
        #expect(ReleaseVersion.compare("0.2.10", to: "0.2.9") == .newerThanTheOtherVersion)
        #expect("1.10.0" < "1.9.0", "a plain string compare really does get this wrong")
    }

    @Test func aMissingComponentIsAZeroAndALeadingVIsIgnored() async throws {
        #expect(ReleaseVersion.compare("1.2", to: "1.2.0") == .theSameAsTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0", to: "1.2") == .theSameAsTheOtherVersion)
        #expect(ReleaseVersion.compare("1", to: "1.0.0.0") == .theSameAsTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.1", to: "1.2") == .newerThanTheOtherVersion)

        // Release tags carry a `v`; the version inside an app bundle does not.
        // These two must still compare as the same release.
        #expect(ReleaseVersion.compare("0.1.1", to: "v0.1.1") == .theSameAsTheOtherVersion)
        #expect(ReleaseVersion.compare("V0.1.1", to: "0.1.1") == .theSameAsTheOtherVersion)
        #expect(ReleaseVersion.compare("v1.10.0", to: "v1.9.0") == .newerThanTheOtherVersion)

        // Build metadata has no effect on precedence, per semver.
        #expect(ReleaseVersion.compare("1.2.0+build.7", to: "1.2.0") == .theSameAsTheOtherVersion)
    }

    @Test func aPreReleaseRanksBelowTheReleaseItLeadsUpTo() async throws {
        #expect(ReleaseVersion.compare("1.2.0-beta.1", to: "1.2.0") == .olderThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0", to: "1.2.0-beta.1") == .newerThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0-alpha", to: "1.2.0-beta") == .olderThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0-beta", to: "1.2.0-beta.1") == .olderThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0-beta.2", to: "1.2.0-beta.10") == .olderThanTheOtherVersion)
        #expect(ReleaseVersion.compare("1.2.0-rc.1", to: "1.2.0-rc.1") == .theSameAsTheOtherVersion)
        // A pre-release of a higher version still beats a lower final release.
        #expect(ReleaseVersion.compare("1.3.0-beta", to: "1.2.9") == .newerThanTheOtherVersion)
    }

    @Test func aVersionThatCannotBeReadIsUnknownRatherThanAGuess() async throws {
        for unreadableVersion in ["", "   ", "nightly", "latest", "v", "version", "1.x.3", "1..2", "1.2.0-"] {
            #expect(
                ReleaseVersion.compare(unreadableVersion, to: "1.2.0") == .cannotBeCompared,
                "\(unreadableVersion) is not a version and must not be ranked"
            )
            #expect(
                ReleaseVersion.compare("1.2.0", to: unreadableVersion) == .cannotBeCompared
            )
        }
        #expect(ReleaseVersion.parse("2026.07.31") != nil, "a date-shaped tag is still numeric")
    }

    // MARK: - Update detection

    @Test func anUpdateIsReportedOnlyWhenTheLatestIsStrictlyNewer() async throws {
        // Behind: the one case that is an update.
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "1.9.0"),
                latestReleaseTag: "v1.10.0"
            ) == .updateIsAvailable(latestReleaseTag: "v1.10.0")
        )

        // Equal is not an update, however differently the two are written.
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "1.10.0"),
                latestReleaseTag: "v1.10.0"
            ) == .upToDate
        )
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "1.2"),
                latestReleaseTag: "v1.2.0"
            ) == .upToDate
        )

        // Ahead is not an update either — somebody running a local build newer
        // than the published release is in front of us, and "update" would walk
        // them backwards.
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "2.0.0"),
                latestReleaseTag: "v1.10.0"
            ) == .upToDate
        )

        // Nothing knowable: no release to compare to, an unreadable installed
        // version, an unreadable tag, or an app that is not installed at all.
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "1.0.0"),
                latestReleaseTag: nil
            ) == .unknown
        )
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "nightly"),
                latestReleaseTag: "v1.10.0"
            ) == .unknown
        )
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .installed(installedVersion: "1.0.0"),
                latestReleaseTag: "rolling"
            ) == .unknown
        )
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .notInstalled,
                latestReleaseTag: "v1.10.0"
            ) == .unknown
        )
        #expect(
            AppInventoryService.updateAvailability(
                forInstallationState: .unknown,
                latestReleaseTag: "v1.10.0"
            ) == .unknown
        )
    }

    @Test func theAppWithAnUpdateIsListedFirst() async throws {
        let temporaryDirectory = try TemporaryApplicationBundleDirectory()
        defer { temporaryDirectory.removeEverything() }

        let currentAppBundleURL = try temporaryDirectory.makeApplicationBundle(
            named: "Astro.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.browseros.BrowserOS",
                "CFBundleShortVersionString": "0.1.0",
            ]
        )
        let staleAppBundleURL = try temporaryDirectory.makeApplicationBundle(
            named: "WhimprFlow.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.whimpr.whimprflow",
                "CFBundleShortVersionString": "0.1.1",
            ]
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: StubbedCatalogAppDirectory(catalogApps: [
                CatalogAppDescriptor(
                    slug: "astro",
                    name: "Astro",
                    macBundleId: "com.browseros.BrowserOS",
                    latestReleaseTag: "v0.1.0"
                ),
                CatalogAppDescriptor(
                    slug: "whimprflow",
                    name: "WhimprFlow",
                    macBundleId: "com.whimpr.whimprflow",
                    latestReleaseTag: "v0.2.0"
                ),
            ]),
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: [
                    "com.browseros.BrowserOS": currentAppBundleURL,
                    "com.whimpr.whimprflow": staleAppBundleURL,
                ]
            )
        )

        await inventoryService.refreshInventory()

        // Alphabetically Astro comes first; the app with an update outranks it,
        // because the whole reason to look at this section is the update.
        #expect(inventoryService.installedEntriesForDisplay.map(\.slug) == ["whimprflow", "astro"])
        #expect(inventoryService.installedEntriesForDisplay.first?.hasAnUpdateAvailable == true)
    }

    // MARK: - What the user is looking at

    @Test func theFrontmostCatalogAppIsIdentifiedAndAnythingElseIsNone() async throws {
        let temporaryDirectory = try TemporaryApplicationBundleDirectory()
        defer { temporaryDirectory.removeEverything() }

        let nitroBundleURL = try temporaryDirectory.makeApplicationBundle(
            named: "NitroAI.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.nitroai.app",
                "CFBundleShortVersionString": "1.0.0",
            ]
        )

        let inventoryService = AppInventoryService(
            catalogDirectory: StubbedCatalogAppDirectory(catalogApps: [
                CatalogAppDescriptor(
                    slug: "nitroai",
                    name: "NitroAI",
                    macBundleId: "com.nitroai.app",
                    latestReleaseTag: "v1.0.0"
                ),
                CatalogAppDescriptor(
                    slug: "lunara",
                    name: "Lunara",
                    macBundleId: nil,
                    latestReleaseTag: "v1.0.0"
                ),
            ]),
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: ["com.nitroai.app": nitroBundleURL]
            )
        )
        await inventoryService.refreshInventory()

        inventoryService.updateFrontmostApplication(
            Self.foregroundApp(withBundleIdentifier: "com.nitroai.app")
        )
        #expect(inventoryService.frontmostCatalogAppSlug == "nitroai")

        // LaunchServices is case-insensitive about identifiers, so a catalog
        // entry typed differently should still match rather than silently miss.
        inventoryService.updateFrontmostApplication(
            Self.foregroundApp(withBundleIdentifier: "COM.NITROAI.APP")
        )
        #expect(inventoryService.frontmostCatalogAppSlug == "nitroai")

        // Something that is not ours in front means no catalog app is in front.
        inventoryService.updateFrontmostApplication(
            Self.foregroundApp(withBundleIdentifier: "com.apple.Safari")
        )
        #expect(inventoryService.frontmostCatalogAppSlug == nil)

        // An app AppKit cannot identify, and nothing in front at all, are both
        // "no catalog app" rather than a stale previous answer.
        inventoryService.updateFrontmostApplication(
            Self.foregroundApp(withBundleIdentifier: nil)
        )
        #expect(inventoryService.frontmostCatalogAppSlug == nil)
        inventoryService.updateFrontmostApplication(nil)
        #expect(inventoryService.frontmostCatalogAppSlug == nil)
    }

    @Test func switchingIntoACatalogAppDoesNotRescanOnEverySwitch() async throws {
        // The frontmost app changes dozens of times a minute. A rescan can spawn
        // a Spotlight query, so it is allowed at most once a minute.
        let justNow = Date()

        #expect(
            AppInventoryService.shouldRefreshAutomatically(
                frontmostAppIsInTheCatalog: true,
                lastSuccessfulRefreshCompletedAt: justNow,
                now: justNow.addingTimeInterval(5)
            ) == false
        )
        #expect(
            AppInventoryService.shouldRefreshAutomatically(
                frontmostAppIsInTheCatalog: true,
                lastSuccessfulRefreshCompletedAt: justNow,
                now: justNow.addingTimeInterval(
                    AppInventoryService.minimumSecondsBetweenAutomaticRefreshes + 1
                )
            ) == true
        )
        // Switching into something that is not ours is never a reason to scan.
        #expect(
            AppInventoryService.shouldRefreshAutomatically(
                frontmostAppIsInTheCatalog: false,
                lastSuccessfulRefreshCompletedAt: nil,
                now: justNow
            ) == false
        )
    }

    // MARK: - Failures

    @Test func aCatalogThatCannotBeReadKeepsTheLastKnownInventory() async throws {
        let temporaryDirectory = try TemporaryApplicationBundleDirectory()
        defer { temporaryDirectory.removeEverything() }

        let nitroBundleURL = try temporaryDirectory.makeApplicationBundle(
            named: "NitroAI.app",
            infoPlistEntries: [
                "CFBundleIdentifier": "com.nitroai.app",
                "CFBundleShortVersionString": "1.0.0",
            ]
        )

        let catalogDirectory = StubbedCatalogAppDirectory(catalogApps: [
            CatalogAppDescriptor(
                slug: "nitroai",
                name: "NitroAI",
                macBundleId: "com.nitroai.app",
                latestReleaseTag: "v1.0.0"
            ),
        ])
        let inventoryService = AppInventoryService(
            catalogDirectory: catalogDirectory,
            installedApplicationLocator: StubbedInstalledApplicationLocator(
                applicationBundleURLsByBundleIdentifier: ["com.nitroai.app": nitroBundleURL]
            )
        )
        await inventoryService.refreshInventory()
        #expect(inventoryService.installedEntriesForDisplay.count == 1)

        await catalogDirectory.failEveryFurtherFetch(
            with: .transportFailure(reason: "The network connection was lost.")
        )
        await inventoryService.refreshInventory()

        // An app that was installed a minute ago is still installed when the
        // network drops, so the list survives and only the message is new.
        #expect(inventoryService.installedEntriesForDisplay.count == 1)
        #expect(inventoryService.lastRefreshFailureMessage != nil)
    }

    // MARK: - Helpers

    private static func foregroundApp(withBundleIdentifier bundleIdentifier: String?) -> ForegroundAppIdentity {
        ForegroundAppIdentity(
            platform: "macos",
            processIdentifier: 1234,
            displayName: "Whatever",
            bundleIdentifier: bundleIdentifier,
            executablePath: nil
        )
    }
}

// MARK: - Stubs

/// A fixed catalog, so no test depends on what publik is serving today.
private actor StubbedCatalogAppDirectory: CatalogAppDirectorySource {
    private let fixedCatalogApps: [CatalogAppDescriptor]
    private var failureToThrow: AppCatalogDirectoryError?

    init(catalogApps: [CatalogAppDescriptor]) {
        self.fixedCatalogApps = catalogApps
    }

    func failEveryFurtherFetch(with failure: AppCatalogDirectoryError) {
        failureToThrow = failure
    }

    func catalogApps() async throws -> [CatalogAppDescriptor] {
        if let failureToThrow = failureToThrow {
            throw failureToThrow
        }
        return fixedCatalogApps
    }
}

/// A fixed bundle-identifier-to-location map, so no test depends on what is
/// installed on the machine running it.
private struct StubbedInstalledApplicationLocator: InstalledApplicationLocating {
    let applicationBundleURLsByBundleIdentifier: [String: URL]

    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        applicationBundleURLsByBundleIdentifier[bundleIdentifier]
    }
}

/// Builds throwaway `.app` bundles so the real `Info.plist` reader can be
/// exercised against real files — including files with nothing usable in them.
private struct TemporaryApplicationBundleDirectory {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-app-inventory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeApplicationBundle(
        named bundleName: String,
        infoPlistEntries: [String: Any]
    ) throws -> URL {
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlistEntries,
            format: .xml,
            options: 0
        )
        return try makeApplicationBundle(named: bundleName, rawInfoPlistBytes: infoPlistData)
    }

    func makeApplicationBundle(
        named bundleName: String,
        rawInfoPlistBytes: Data
    ) throws -> URL {
        let applicationBundleURL = rootURL.appendingPathComponent(bundleName)
        let contentsDirectoryURL = applicationBundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contentsDirectoryURL,
            withIntermediateDirectories: true
        )
        try rawInfoPlistBytes.write(
            to: contentsDirectoryURL.appendingPathComponent("Info.plist")
        )
        return applicationBundleURL
    }

    func removeEverything() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
