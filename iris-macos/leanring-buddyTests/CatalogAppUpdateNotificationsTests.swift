//
//  CatalogAppUpdateNotificationsTests.swift
//  leanring-buddyTests
//
//  Covers `CatalogAppUpdateSeenTagsStore` and `CatalogAppUpdateNotificationDecision`
//  — which installed-app updates are worth a proactive nudge, and that the same
//  version is never announced twice.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct CatalogAppUpdateNotificationsTests {

    private func installedEntry(
        slug: String,
        name: String,
        installedVersion: String,
        updateAvailability: CatalogAppUpdateAvailability
    ) -> CatalogAppInventoryEntry {
        CatalogAppInventoryEntry(
            slug: slug,
            name: name,
            macBundleId: "com.example.\(slug)",
            latestReleaseTag: nil,
            installationState: .installed(installedVersion: installedVersion),
            updateAvailability: updateAvailability,
            isLocallyEditable: false
        )
    }

    // MARK: - CatalogAppUpdateSeenTagsStore

    @Test func aTagNeverAnnouncedComesBackNil() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        #expect(store.lastAnnouncedReleaseTag(forSlug: "whimprflow") == nil)
    }

    @Test func markingATagAsAnnouncedIsRememberedForThatSlugOnly() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        store.markAsAnnounced(releaseTag: "v0.3.0", forSlug: "whimprflow")

        #expect(store.lastAnnouncedReleaseTag(forSlug: "whimprflow") == "v0.3.0")
        #expect(store.lastAnnouncedReleaseTag(forSlug: "nitroai") == nil)
    }

    @Test func aNewerTagOverwritesTheRememberedOne() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        store.markAsAnnounced(releaseTag: "v0.3.0", forSlug: "whimprflow")
        store.markAsAnnounced(releaseTag: "v0.4.0", forSlug: "whimprflow")

        #expect(store.lastAnnouncedReleaseTag(forSlug: "whimprflow") == "v0.4.0")
    }

    // MARK: - CatalogAppUpdateNotificationDecision.newlyAvailableUpdates

    @Test func anUpdateNeverAnnouncedBeforeIsNewlyAvailable() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.2.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.3.0")
            ),
        ]

        let newlyAvailable = CatalogAppUpdateNotificationDecision.newlyAvailableUpdates(
            in: entries, notAlreadyAnnouncedAccordingTo: store
        )

        #expect(newlyAvailable.map(\.slug) == ["whimprflow"])
    }

    @Test func anUpdateAlreadyAnnouncedAtTheSameTagIsNotRepeated() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        store.markAsAnnounced(releaseTag: "v0.3.0", forSlug: "whimprflow")
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.2.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.3.0")
            ),
        ]

        let newlyAvailable = CatalogAppUpdateNotificationDecision.newlyAvailableUpdates(
            in: entries, notAlreadyAnnouncedAccordingTo: store
        )

        #expect(newlyAvailable.isEmpty)
    }

    @Test func aNewerTagThanWhatWasAnnouncedIsNewlyAvailableAgain() throws {
        // The reader was told about v0.3.0 and never updated (or updated and a
        // v0.4.0 shipped since) — a strictly newer tag than what was announced
        // is real news, not a repeat.
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        store.markAsAnnounced(releaseTag: "v0.3.0", forSlug: "whimprflow")
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.2.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.4.0")
            ),
        ]

        let newlyAvailable = CatalogAppUpdateNotificationDecision.newlyAvailableUpdates(
            in: entries, notAlreadyAnnouncedAccordingTo: store
        )

        #expect(newlyAvailable.map(\.slug) == ["whimprflow"])
    }

    @Test func anAppThatIsUpToDateIsNeverNewlyAvailable() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.3.0",
                updateAvailability: .upToDate
            ),
        ]

        let newlyAvailable = CatalogAppUpdateNotificationDecision.newlyAvailableUpdates(
            in: entries, notAlreadyAnnouncedAccordingTo: store
        )

        #expect(newlyAvailable.isEmpty)
    }

    @Test func onlyTheAppsWithAGenuinelyNewUpdateAreReturnedFromAMixedList() throws {
        let store = CatalogAppUpdateSeenTagsStore(
            userDefaults: try #require(UserDefaults(suiteName: "iris.test.seen-tags.\(UUID())"))
        )
        store.markAsAnnounced(releaseTag: "v1.0.0", forSlug: "already-told")
        let entries = [
            installedEntry(
                slug: "already-told", name: "Already Told", installedVersion: "0.9.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v1.0.0")
            ),
            installedEntry(
                slug: "brand-new", name: "Brand New", installedVersion: "0.1.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.2.0")
            ),
            installedEntry(
                slug: "up-to-date", name: "Up To Date", installedVersion: "2.0.0",
                updateAvailability: .upToDate
            ),
        ]

        let newlyAvailable = CatalogAppUpdateNotificationDecision.newlyAvailableUpdates(
            in: entries, notAlreadyAnnouncedAccordingTo: store
        )

        #expect(newlyAvailable.map(\.slug) == ["brand-new"])
    }

    // MARK: - CatalogAppUpdateNotificationDecision.consolidatedNotificationText

    @Test func oneNewUpdateReadsAsASingleAppSentence() {
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.2.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.3.0")
            ),
        ]

        let (title, body) = CatalogAppUpdateNotificationDecision.consolidatedNotificationText(
            forNewlyAvailableEntries: entries
        )

        #expect(title == "Update available")
        #expect(body == "WhimprFlow v0.3.0")
    }

    @Test func severalNewUpdatesAreConsolidatedIntoOneNotificationNeverOnePerApp() {
        let entries = [
            installedEntry(
                slug: "whimprflow", name: "WhimprFlow", installedVersion: "0.2.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v0.3.0")
            ),
            installedEntry(
                slug: "nitroai", name: "NitroAI", installedVersion: "1.0.0",
                updateAvailability: .updateIsAvailable(latestReleaseTag: "v1.1.0")
            ),
        ]

        let (title, body) = CatalogAppUpdateNotificationDecision.consolidatedNotificationText(
            forNewlyAvailableEntries: entries
        )

        #expect(title == "2 updates available")
        #expect(body == "WhimprFlow v0.3.0, NitroAI v1.1.0")
    }
}
