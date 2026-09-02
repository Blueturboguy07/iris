//
//  Test8DiscoveryTests.swift
//  leanring-buddyTests
//
//  The read-only logic behind the settings panel's "discover more apps"
//  surface: given the whole catalog and what the reader typed, which apps to
//  offer and in what order.
//
//  This is the half of the Test 8 discovery feature that has to be RIGHT rather
//  than merely pretty — an installed app leaking back into the "discover" list
//  would offer a second confusing install path, and a search that missed the
//  obvious match would send the reader who "can't tell which repo to pick"
//  away empty-handed. None of it touches the network or anything installed on
//  the machine running the suite: the catalog is a fixed list built in the test.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct Test8DiscoveryTests {

    /// Builds one catalog inventory entry with just the fields discovery reads.
    private func inventoryEntry(
        slug: String,
        name: String,
        isInstalled: Bool,
        latestReleaseTag: String? = "v1.0.0",
        installStateIsUnknown: Bool = false
    ) -> CatalogAppInventoryEntry {
        let installationState: CatalogAppInstallationState
        if installStateIsUnknown {
            installationState = .unknown
        } else if isInstalled {
            installationState = .installed(installedVersion: "1.0.0")
        } else {
            installationState = .notInstalled
        }
        return CatalogAppInventoryEntry(
            slug: slug,
            name: name,
            macBundleId: installStateIsUnknown ? nil : "com.\(slug).app",
            latestReleaseTag: latestReleaseTag,
            installationState: installationState,
            updateAvailability: .unknown,
            isLocallyEditable: false
        )
    }

    // MARK: - What is offered

    @Test func discoveryExcludesInstalledAppsButStillOffersUnknownOnes() {
        // Installed → never offered (it has its own section). notInstalled →
        // offered. unknown (publik has no bundle id, so Iris cannot tell) →
        // still offered, because hiding a searchable app for the sake of a
        // maybe-already-installed would make it un-findable for no reason.
        let inventory = [
            inventoryEntry(slug: "alpha", name: "Alpha", isInstalled: true),
            inventoryEntry(slug: "bravo", name: "Bravo", isInstalled: false),
            inventoryEntry(slug: "charlie", name: "Charlie", isInstalled: false, installStateIsUnknown: true),
        ]

        let discoverable = CatalogAppDiscovery.discoverableApps(
            fromInventory: inventory,
            matchingSearchText: ""
        )

        #expect(discoverable.map(\.slug) == ["bravo", "charlie"])
        #expect(!discoverable.contains { $0.slug == "alpha" })
    }

    @Test func emptySearchReturnsEveryDiscoverableAppAlphabetically() {
        let inventory = [
            inventoryEntry(slug: "mango", name: "Mango", isInstalled: false),
            inventoryEntry(slug: "apricot", name: "Apricot", isInstalled: false),
            inventoryEntry(slug: "banana", name: "Banana", isInstalled: false),
        ]

        let discoverable = CatalogAppDiscovery.discoverableApps(
            fromInventory: inventory,
            matchingSearchText: "   "
        )

        // Whitespace-only counts as empty, and the result is sorted by name.
        #expect(discoverable.map(\.name) == ["Apricot", "Banana", "Mango"])
    }

    // MARK: - Search

    @Test func searchMatchesNameAndSlugCaseAndDiacriticInsensitively() {
        let inventory = [
            inventoryEntry(slug: "cal-ai", name: "Cal AI", isInstalled: false),
            inventoryEntry(slug: "lunara", name: "Lunara", isInstalled: false),
            inventoryEntry(slug: "noscroll", name: "NoScroll", isInstalled: false),
        ]

        // Name substring, lower case.
        #expect(
            CatalogAppDiscovery.discoverableApps(fromInventory: inventory, matchingSearchText: "cal")
                .map(\.slug) == ["cal-ai"]
        )
        // Different case still matches.
        #expect(
            CatalogAppDiscovery.discoverableApps(fromInventory: inventory, matchingSearchText: "LUN")
                .map(\.slug) == ["lunara"]
        )
        // Match on the slug, not just the display name.
        #expect(
            CatalogAppDiscovery.discoverableApps(fromInventory: inventory, matchingSearchText: "scroll")
                .map(\.slug) == ["noscroll"]
        )
    }

    @Test func aSearchThatMatchesNothingReturnsNothing() {
        let inventory = [
            inventoryEntry(slug: "lunara", name: "Lunara", isInstalled: false),
        ]

        #expect(
            CatalogAppDiscovery.discoverableApps(fromInventory: inventory, matchingSearchText: "zzz")
                .isEmpty
        )
    }

    @Test func searchNeverMatchesAnInstalledApp() {
        // Even an exact name match on an installed app stays out of discovery.
        let inventory = [
            inventoryEntry(slug: "lunara", name: "Lunara", isInstalled: true),
        ]

        #expect(
            CatalogAppDiscovery.discoverableApps(fromInventory: inventory, matchingSearchText: "lunara")
                .isEmpty
        )
    }

    // MARK: - Starter suggestions

    @Test func starterSuggestionsPreferReleasesThenAlphabeticalAndRespectTheCap() {
        let inventory = [
            inventoryEntry(slug: "zed", name: "Zed", isInstalled: false, latestReleaseTag: nil),
            inventoryEntry(slug: "apricot", name: "Apricot", isInstalled: false, latestReleaseTag: "v1"),
            inventoryEntry(slug: "mango", name: "Mango", isInstalled: false, latestReleaseTag: "v2"),
            inventoryEntry(slug: "banana", name: "Banana", isInstalled: false, latestReleaseTag: nil),
            inventoryEntry(slug: "kiwi", name: "Kiwi", isInstalled: true, latestReleaseTag: "v1"),
        ]

        // Apps with a published release come first (alphabetical among them),
        // then the release-less ones (alphabetical among them). The installed
        // Kiwi never appears.
        let starters = CatalogAppDiscovery.starterSuggestions(fromInventory: inventory)
        #expect(starters.map(\.name) == ["Apricot", "Mango", "Banana", "Zed"])
        #expect(!starters.contains { $0.slug == "kiwi" })

        // The cap is honoured, and it keeps the highest-priority picks.
        let firstTwoStarters = CatalogAppDiscovery.starterSuggestions(fromInventory: inventory, limit: 2)
        #expect(firstTwoStarters.map(\.name) == ["Apricot", "Mango"])
    }

    @Test func starterSuggestionsAreEmptyWhenEverythingIsInstalled() {
        let inventory = [
            inventoryEntry(slug: "alpha", name: "Alpha", isInstalled: true),
            inventoryEntry(slug: "bravo", name: "Bravo", isInstalled: true),
        ]

        #expect(CatalogAppDiscovery.starterSuggestions(fromInventory: inventory).isEmpty)
    }

    @Test func starterSuggestionsAreEmptyForAnEmptyCatalog() {
        #expect(CatalogAppDiscovery.starterSuggestions(fromInventory: []).isEmpty)
    }
}
