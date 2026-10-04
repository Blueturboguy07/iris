import XCTest
@testable import IrisMobileShellCore

// Unit MA1-organization-core. `MyAppsScreen.sections(input:)`,
// `actions(for:)`, the search matcher and the sort rules, at 3, 100 and
// 1,000 apps (SPEC 5.1's scale personas; SPEC 3.3's performance budget).

final class MyAppsScreenTests: XCTestCase {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    private func makeApp(_ i: Int, categoryIds: [Int] = [], name: String? = nil) -> MyAppsAppInput {
        MyAppsAppInput(
            identity: "app\(i)::proj\(i)",
            originalName: name ?? "App \(i)",
            descriptionLine: "Does app \(i) things",
            categoryIds: categoryIds,
            sizeBytes: Int64(i * 1000),
            hasUpdate: false,
            isBlocked: false,
            hasCatalogSlug: true
        )
    }

    // MARK: Collapse threshold (SPEC 1.1 item 7, mutation #8)

    func testFewerThan6AppsShowsAllAppsWithNoGroupHeaders() {
        let apps = (0..<5).map { makeApp($0, categoryIds: [1]) }
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0)]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertFalse(output.showGroupHeaders)
        XCTAssertEqual(output.sections.count, 1)
        XCTAssertEqual(output.sections[0].kind, .allApps)
        XCTAssertEqual(output.sections[0].rows.count, 5)
    }

    func test6AppsIn2GroupsShowsHeaders() {
        let apps = (0..<3).map { makeApp($0, categoryIds: [1]) } + (3..<6).map { makeApp($0, categoryIds: [2]) }
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0), MyAppsCategoryInput(id: 2, name: "Music", order: 1)]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertTrue(output.showGroupHeaders)
        XCTAssertEqual(output.sections.count, 2)
    }

    func test6AppsInOneGroupOnlyDoesNotShowHeaders() {
        // Mutation #8 guard: 6 apps, but only 1 non-empty group -> below the
        // "2 or more non-empty groups" threshold, so still "All apps".
        let apps = (0..<6).map { makeApp($0, categoryIds: [1]) }
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0)]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertFalse(output.showGroupHeaders)
    }

    // MARK: Grouping by first category id (mutation #6)

    func testAppGroupedByFirstCategoryIdNotLast() {
        let apps = [makeApp(0, categoryIds: [1, 2])] + (1..<6).map { makeApp($0, categoryIds: [2]) }
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0), MyAppsCategoryInput(id: 2, name: "Music", order: 1)]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        let editingSection = output.sections.first { if case .group(let id, _, _) = $0.kind { return id == 1 } else { return false } }
        XCTAssertEqual(editingSection?.rows.map(\.identity), ["app0::proj0"], "app0 lists categories [1,2]; it must land in category 1 (first), not 2 (last)")
    }

    func testUnknownCategoryGoesToOther() {
        let apps = (0..<3).map { makeApp($0, categoryIds: [1]) } + [makeApp(3, categoryIds: [999])] + (4..<6).map { makeApp($0, categoryIds: [1]) }
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0)]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        let other = output.sections.first { if case .other = $0.kind { return true } else { return false } }
        XCTAssertEqual(other?.rows.map(\.identity), ["app3::proj3"])
    }

    // MARK: One-place rule at the screen level: folder apps never also show in a group

    func testAppInAFolderIsNotAlsoInItsAutomaticGroup() {
        // Group headers only show at 2+ non-empty groups (SPEC 1.1 item 7,
        // MyAppsLimits.groupHeaderMinNonEmptyGroups); app5 is category 2 so
        // this fixture actually crosses that threshold instead of silently
        // falling into the no-headers "All apps" branch, where there would
        // be no `.group` section at all to assert against.
        let apps = (0..<5).map { makeApp($0, categoryIds: [1]) } + [makeApp(5, categoryIds: [2])]
        let categories = [MyAppsCategoryInput(id: 1, name: "Editing", order: 0), MyAppsCategoryInput(id: 2, name: "Other cat", order: 1)]
        var arrangement = MyAppsArrangement.empty
        arrangement.folders = [MyAppsFolder(id: "F1", name: "Mine", order: 0, createdAt: "t", apps: ["app0::proj0"])]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        let group = output.sections.first { if case .group(let id, _, _) = $0.kind { return id == 1 } else { return false } }
        XCTAssertFalse(group?.rows.contains { $0.identity == "app0::proj0" } ?? true)
        let folder = output.sections.first { if case .folder = $0.kind { return true } else { return false } }
        XCTAssertEqual(folder?.rows.map(\.identity), ["app0::proj0"])
        // No duplicate anywhere across all sections.
        let allIdentities = output.sections.flatMap { $0.rows.map(\.identity) }
        XCTAssertEqual(allIdentities.count, Set(allIdentities).count, "an app must not be shown twice")
    }

    // MARK: Renamed apps: display name shown, original still searchable (mutation #10)

    func testRenamedAppShowsCustomNameAsDisplayName() {
        var arrangement = MyAppsArrangement.empty
        arrangement.apps["app0::proj0"] = MyAppsAppEntry(name: "Clips")
        let apps = [makeApp(0, name: "Kneecap")]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        let row = output.sections.flatMap(\.rows).first!
        XCTAssertEqual(row.displayName, "Clips")
        XCTAssertEqual(row.originalName, "Kneecap")
        XCTAssertTrue(row.isRenamed)
    }

    func testSearchMatchesOriginalNameOfARenamedApp() {
        var arrangement = MyAppsArrangement.empty
        arrangement.apps["app0::proj0"] = MyAppsAppEntry(name: "Clips")
        let apps = [makeApp(0, name: "Kneecap")]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .groups, query: "Kneecap", now: fixedNow))
        XCTAssertEqual(output.searchMatchCount, 1, "P1 renamed the app to Clips but still searches its original name")
        XCTAssertEqual(output.sections.first?.rows.first?.identity, "app0::proj0")
    }

    func testSearchMatchesDescriptionAndIsWordOrderFree() {
        let apps = [makeApp(0, name: "Sub Studio")]
        var arrangement = MyAppsArrangement.empty
        // descriptionLine defaults to "Does app 0 things"
        let output1 = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .groups, query: "things app", now: fixedNow))
        XCTAssertEqual(output1.searchMatchCount, 1)
        arrangement = .empty
        let output2 = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .groups, query: "nomatch", now: fixedNow))
        XCTAssertEqual(output2.searchMatchCount, 0)
    }

    func testSearchFieldShownOnlyAt12OrMoreApps() {
        let apps11 = (0..<11).map { makeApp($0) }
        let output11 = MyAppsScreen.sections(input: .init(apps: apps11, categories: [], arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertFalse(output11.showSearchField)
        let apps12 = (0..<12).map { makeApp($0) }
        let output12 = MyAppsScreen.sections(input: .init(apps: apps12, categories: [], arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertTrue(output12.showSearchField)
    }

    // MARK: Recently used (SPEC 1.1 item 4)

    func testRecentlyUsedOrdersByLastOpenedDescendingAndCapsAt8() {
        let apps = (0..<10).map { makeApp($0) }
        var arrangement = MyAppsArrangement.empty
        for i in 0..<10 {
            arrangement.apps["app\(i)::proj\(i)"] = MyAppsAppEntry(lastOpenedAt: String(format: "2026-09-28T%02d:00:00Z", i))
        }
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        XCTAssertTrue(output.showRecentlyUsed)
        XCTAssertEqual(output.recentlyUsed.count, 8)
        XCTAssertEqual(output.recentlyUsed.first?.identity, "app9::proj9", "most recently opened first")
        XCTAssertEqual(output.recentlyUsed.last?.identity, "app2::proj2")
    }

    func testRecentlyUsedHiddenBelow6AppsOrWithNoOpens() {
        let apps5 = (0..<5).map { makeApp($0) }
        var arrangement = MyAppsArrangement.empty
        arrangement.apps["app0::proj0"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T00:00:00Z")
        let output5 = MyAppsScreen.sections(input: .init(apps: apps5, categories: [], arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        XCTAssertFalse(output5.showRecentlyUsed)

        let apps6 = (0..<6).map { makeApp($0) }
        let outputNoOpens = MyAppsScreen.sections(input: .init(apps: apps6, categories: [], arrangement: .empty, sort: .groups, query: "", now: fixedNow))
        XCTAssertFalse(outputNoOpens.showRecentlyUsed)
    }

    func testRecentlyUsedNotSortedByName() {
        // Mutation #5 guard: "Recently used sorted by name" must fail this.
        let apps = ["Zebra", "Apple", "Mango"].enumerated().map { i, name in
            MyAppsAppInput(identity: "app\(i)::proj\(i)", originalName: name, descriptionLine: "", categoryIds: [], sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: true)
        }
        var arrangement = MyAppsArrangement.empty
        arrangement.apps["app0::proj0"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T09:00:00Z") // Zebra, opened first (oldest)
        arrangement.apps["app1::proj1"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T11:00:00Z") // Apple, opened most recently
        arrangement.apps["app2::proj2"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T10:00:00Z") // Mango, opened second
        let padded = apps + (3..<6).map { makeApp($0) }
        let output = MyAppsScreen.sections(input: .init(apps: padded, categories: [], arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        XCTAssertEqual(output.recentlyUsed.map(\.displayName), ["Apple", "Mango", "Zebra"], "order must be recency, not alphabetical")
    }

    // MARK: Sort rules (SPEC 1.5)

    func testSortByNameIsCaseInsensitiveAtoZ() {
        let apps = ["banana", "Apple", "cherry"].enumerated().map { i, name in
            MyAppsAppInput(identity: "app\(i)::proj\(i)", originalName: name, descriptionLine: "", categoryIds: [], sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: true)
        }
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: .empty, sort: .name, query: "", now: fixedNow))
        XCTAssertEqual(output.sections.first?.rows.map(\.displayName), ["Apple", "banana", "cherry"])
    }

    func testSortBySizeLargestFirst() {
        let apps = [
            MyAppsAppInput(identity: "a::p", originalName: "A", descriptionLine: "", categoryIds: [], sizeBytes: 500, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
            MyAppsAppInput(identity: "b::p", originalName: "B", descriptionLine: "", categoryIds: [], sizeBytes: 5000, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
            MyAppsAppInput(identity: "c::p", originalName: "C", descriptionLine: "", categoryIds: [], sizeBytes: 50, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
        ]
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: .empty, sort: .size, query: "", now: fixedNow))
        XCTAssertEqual(output.sections.first?.rows.map(\.identity), ["b::p", "a::p", "c::p"])
    }

    func testSortByRecentPutsNeverOpenedLastByName() {
        let apps = [
            MyAppsAppInput(identity: "a::p", originalName: "Zeta", descriptionLine: "", categoryIds: [], sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
            MyAppsAppInput(identity: "c::p", originalName: "Alpha", descriptionLine: "", categoryIds: [], sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
            MyAppsAppInput(identity: "b::p", originalName: "Opened", descriptionLine: "", categoryIds: [], sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: true),
        ]
        var arrangement = MyAppsArrangement.empty
        arrangement.apps["b::p"] = MyAppsAppEntry(lastOpenedAt: "2026-09-28T09:00:00Z")
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: [], arrangement: arrangement, sort: .recent, query: "", now: fixedNow))
        XCTAssertEqual(output.sections.first?.rows.map(\.identity), ["b::p", "c::p", "a::p"], "opened apps first, then never-opened apps by name (Alpha before Zeta)")
    }

    // MARK: actions(for:) -- SPEC 1.2's table

    func testActionsOrderMatchesSpecTableAndOmitsWhatDoesNotApply() {
        let context = MyAppsScreen.MenuContext(hasUpdate: true, hasCurrentVersion: true, needsDownload: false, isInFolder: true, hasCatalogSlug: true, removeAPIAvailable: true)
        XCTAssertEqual(MyAppsScreen.actions(for: context), [.update, .open, .rename, .move, .takeOut, .features, .about, .share, .remove])
    }

    func testActionsOmitTakeOutWhenNotInAFolder() {
        let context = MyAppsScreen.MenuContext(hasUpdate: false, hasCurrentVersion: true, needsDownload: false, isInFolder: false, hasCatalogSlug: true, removeAPIAvailable: true)
        XCTAssertFalse(MyAppsScreen.actions(for: context).contains(.takeOut))
    }

    func testActionsOmitShareWhenNoCatalogSlug() {
        let context = MyAppsScreen.MenuContext(hasUpdate: false, hasCurrentVersion: true, needsDownload: false, isInFolder: false, hasCatalogSlug: false, removeAPIAvailable: true)
        XCTAssertFalse(MyAppsScreen.actions(for: context).contains(.share))
    }

    func testActionsOmitRemoveUntilTheAPIExists() {
        let context = MyAppsScreen.MenuContext(hasUpdate: false, hasCurrentVersion: true, needsDownload: false, isInFolder: false, hasCatalogSlug: true, removeAPIAvailable: false)
        XCTAssertFalse(MyAppsScreen.actions(for: context).contains(.remove), "SPEC decision 12: never a dead menu item")
    }

    func testActionsShowDownloadInsteadOfOpenGatingIsCallerControlled() {
        // Download and Open are independent flags in the context (the
        // caller decides "a current version exists" separately from
        // "needs download"); the menu never shows Open for a fully
        // offloaded app because the caller passes hasCurrentVersion: false.
        let context = MyAppsScreen.MenuContext(hasUpdate: false, hasCurrentVersion: false, needsDownload: true, isInFolder: false, hasCatalogSlug: true, removeAPIAvailable: false)
        let actions = MyAppsScreen.actions(for: context)
        XCTAssertTrue(actions.contains(.download))
        XCTAssertFalse(actions.contains(.open))
    }

    // MARK: Scale (SPEC 3.3): correctness and measured time at 3, 100, 1000 apps

    func testSectionsCorrectAndFastAt3Apps() { measureAndVerify(appCount: 3, folderCount: 0) }
    func testSectionsCorrectAndFastAt100Apps() { measureAndVerify(appCount: 100, folderCount: 5) }
    func testSectionsCorrectAndFastAt1000Apps() { measureAndVerify(appCount: 1000, folderCount: 40) }

    private func measureAndVerify(appCount: Int, folderCount: Int) {
        let categoryCount = 24
        let categories = (0..<categoryCount).map { MyAppsCategoryInput(id: $0, name: "Category \($0)", order: $0) }
        var apps: [MyAppsAppInput] = []
        var arrangement = MyAppsArrangement.empty
        for f in 0..<folderCount {
            arrangement.folders.append(MyAppsFolder(id: "F\(f)", name: "Folder \(f)", order: f, createdAt: "t"))
        }
        for i in 0..<appCount {
            let category = i % categoryCount
            apps.append(makeApp(i, categoryIds: [category]))
            if folderCount > 0, i % 10 == 0 {
                let folderIndex = i % folderCount
                arrangement.folders[folderIndex].apps.append("app\(i)::proj\(i)")
            }
        }

        let start = DispatchTime.now()
        let output = MyAppsScreen.sections(input: .init(apps: apps, categories: categories, arrangement: arrangement, sort: .groups, query: "", now: fixedNow))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        print("MyAppsScreen.sections at \(appCount) apps / \(folderCount) folders: \(ms) ms (debug build; SPEC 3.3 budget is 20 ms in release)")

        // Correctness: every app appears exactly once across all sections.
        let allIdentities = output.sections.flatMap { $0.rows.map(\.identity) }
        XCTAssertEqual(allIdentities.count, appCount)
        XCTAssertEqual(Set(allIdentities).count, appCount, "no app is shown twice")

        // Generous debug-build ceiling so this fails only on a real
        // algorithmic regression (e.g. an accidental O(n^2) scan), not on
        // ordinary debug-build/CI variance.
        XCTAssertLessThan(ms, 1000, "sections() must not degrade badly at \(appCount) apps")
    }
}
