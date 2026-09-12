//
//  ChatGuideToolTests.swift
//  leanring-buddyTests
//
//  The pieces of "open an install guide from chat" that need no network and no
//  eye: the catalog carrying each app's guide slug, and the manager turning
//  whatever the reader called an app into exactly one catalog entry.
//

import Foundation
import Testing
@testable import Iris

struct ChatGuideToolTests {

    private func inventoryEntry(slug: String, name: String, guideSlug: String?) -> CatalogAppInventoryEntry {
        CatalogAppInventoryEntry(
            slug: slug,
            name: name,
            macBundleId: nil,
            latestReleaseTag: nil,
            installationState: .unknown,
            updateAvailability: .unknown,
            isLocallyEditable: false,
            guideSlug: guideSlug
        )
    }

    // MARK: - The catalog carries the guide slug

    @Test func aCatalogRowWithAGuideSlugDecodesIt() throws {
        let catalogJSON = Data("""
        {"slug":"cue","name":"cue","macBundleId":"com.cue.app","latestReleaseTag":"v0.2.1","guideSlug":"cue"}
        """.utf8)
        let descriptor = try JSONDecoder().decode(CatalogAppDescriptor.self, from: catalogJSON)
        #expect(descriptor.guideSlug == "cue")
    }

    @Test func aCatalogRowFromAnOlderPublikWithoutTheFieldStillDecodes() throws {
        // A publik deployed before the catalog carried `guideSlug` must not
        // break the whole inventory; it simply offers no guides.
        let catalogJSON = Data("""
        {"slug":"cue","name":"cue","macBundleId":null,"latestReleaseTag":null}
        """.utf8)
        let descriptor = try JSONDecoder().decode(CatalogAppDescriptor.self, from: catalogJSON)
        #expect(descriptor.guideSlug == nil)
    }

    @Test func theInventoryEntryKeepsTheGuideSlugAndSaysWhetherItHasAGuide() {
        let entries = AppInventoryService.buildInventoryEntries(
            fromCatalogDescriptors: [
                CatalogAppDescriptor(slug: "cue", name: "cue", macBundleId: nil, latestReleaseTag: nil, guideSlug: "cue"),
                CatalogAppDescriptor(slug: "chatmany", name: "chatmany", macBundleId: nil, latestReleaseTag: nil, guideSlug: nil),
            ],
            using: NothingIsInstalledLocator()
        )
        #expect(entries.map(\.guideSlug) == ["cue", nil])
        #expect(entries.map(\.hasAnInstallGuide) == [true, false])
    }

    // MARK: - Matching what the reader said to one catalog entry

    private var catalog: [CatalogAppInventoryEntry] {
        [
            inventoryEntry(slug: "nut-ai", name: "Nut AI", guideSlug: "nut-ai"),
            inventoryEntry(slug: "nutcracker", name: "Nutcracker", guideSlug: "nutcracker"),
            inventoryEntry(slug: "simplicity", name: "Simplicity", guideSlug: "simplicity"),
            inventoryEntry(slug: "chatmany", name: "chatmany", guideSlug: nil),
        ]
    }

    @Test func anExactSlugOrNameWinsWhateverTheCase() {
        #expect(CompanionManager.catalogEntry(matching: "Simplicity", in: catalog)?.slug == "simplicity")
        #expect(CompanionManager.catalogEntry(matching: "SIMPLICITY", in: catalog)?.slug == "simplicity")
        #expect(CompanionManager.catalogEntry(matching: "nut-ai", in: catalog)?.slug == "nut-ai")
    }

    @Test func spacesHyphensAndUnderscoresDoNotSeparateTheSameName() {
        #expect(CompanionManager.catalogEntry(matching: "nut ai", in: catalog)?.slug == "nut-ai")
        #expect(CompanionManager.catalogEntry(matching: "nutai", in: catalog)?.slug == "nut-ai")
        #expect(CompanionManager.catalogEntry(matching: "nut_ai", in: catalog)?.slug == "nut-ai")
    }

    @Test func aUniquePartialMatchWinsButAnAmbiguousOneDoesNot() {
        // "simplic" can only be Simplicity.
        #expect(CompanionManager.catalogEntry(matching: "simplic", in: catalog)?.slug == "simplicity")
        // "nut" is Nut AI or Nutcracker — opening either would be a guess.
        #expect(CompanionManager.catalogEntry(matching: "nut", in: catalog) == nil)
        #expect(CompanionManager.catalogEntries(containing: "nut", in: catalog).map(\.slug) == ["nut-ai", "nutcracker"])
    }

    @Test func nothingMatchesNothing() {
        #expect(CompanionManager.catalogEntry(matching: "", in: catalog) == nil)
        #expect(CompanionManager.catalogEntry(matching: "   ", in: catalog) == nil)
        #expect(CompanionManager.catalogEntry(matching: "photoshop", in: catalog) == nil)
    }

    @Test func anAppWithoutAGuideStillMatchesSoTheModelCanBeToldWhy() {
        // The manager reports "listed but no guide yet" for this case; the
        // match itself must not hide the app.
        let matched = CompanionManager.catalogEntry(matching: "chatmany", in: catalog)
        #expect(matched?.slug == "chatmany")
        #expect(matched?.hasAnInstallGuide == false)
    }
}

/// A Mac with none of the catalog apps installed, for building inventory
/// entries whose only interesting fact is the guide slug they carry.
private struct NothingIsInstalledLocator: InstalledApplicationLocating {
    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        nil
    }
}
