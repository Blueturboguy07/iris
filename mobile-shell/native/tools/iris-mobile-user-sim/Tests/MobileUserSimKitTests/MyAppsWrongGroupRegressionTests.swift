import XCTest
@testable import MobileUserSimKit
import IrisMobileShellCore

// MA5-persona-sim. A regression test guarding SPEC section 1.1 item 6:
// an app's automatic group must be its FIRST known catalog category id,
// matching MA1's own comment in MyAppsScreen.swift ("bucket every app not
// in a folder by its first category id... mutation #6 guards against
// 'last category id instead of first'").
//
// History (MA5 takeover, 2026-09-28, checked against files on disk): MA1's
// MyAppsScreen.swift DID read `app.categoryIds.last(where:...)` when MA5's
// first pass wrote this test. MA1's own verifier fixed it to `.first(where:`
// at 10:14 (pre-fix copy: scratchpad/round3-backups/MA1-verifier/
// MyAppsScreen.swift.orig, line 219). MA5's verifier later read the fixed
// file and called the original report false; it was true when written and
// is fixed now. This test passes against the current code and fails if the
// `.last` bug comes back (SPEC 5.5 mutant 6). It checks an observable
// outcome (which section the row appears in), never MA1's source text.
final class MyAppsWrongGroupRegressionTests: XCTestCase {
    func testAppGroupsByFirstCategoryIdNotLast() throws {
        let categories = [
            IrisMobileShellCore.MyAppsCategoryInput(id: 5, name: "Editing", order: 0),
            IrisMobileShellCore.MyAppsCategoryInput(id: 7, name: "Utilities", order: 1),
        ]
        // 6 apps, 2 non-empty groups: crosses both showGroupHeaders
        // thresholds (MyAppsLimits.groupHeaderMinInstalledApps = 6,
        // groupHeaderMinNonEmptyGroups = 2) so the grouped path actually
        // renders group sections instead of falling back to "All apps".
        var apps: [IrisMobileShellCore.MyAppsAppInput] = (0..<5).map { index in
            IrisMobileShellCore.MyAppsAppInput(
                identity: "publik.filler\(index)::publik.filler\(index).shell",
                originalName: "Filler \(index)", descriptionLine: "", categoryIds: [5],
                sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: false
            )
        }
        // categoryIds lists 7 first, 5 last: SPEC says this app's automatic
        // group must be category 7 (the first entry), never 5 (the last).
        let target = IrisMobileShellCore.MyAppsAppInput(
            identity: "publik.target::publik.target.shell",
            originalName: "Target App", descriptionLine: "", categoryIds: [7, 5],
            sizeBytes: nil, hasUpdate: false, isBlocked: false, hasCatalogSlug: false
        )
        apps.append(target)

        let input = IrisMobileShellCore.MyAppsSectionsInput(
            apps: apps, categories: categories, arrangement: .empty,
            sort: .groups, query: "", now: Date()
        )
        let output = IrisMobileShellCore.MyAppsScreen.sections(input: input)

        var groupOfTarget: Int?
        for section in output.sections {
            if case .group(let categoryId, _, _) = section.kind, section.rows.contains(where: { $0.identity == target.identity }) {
                groupOfTarget = categoryId
            }
        }

        XCTAssertEqual(
            groupOfTarget, 7,
            "SPEC 1.1 item 6: the app's automatic group must be its FIRST catalog category id (7), " +
            "not its last (5). This is SPEC 5.4's wrong-group failure / SPEC 5.5 mutation 6. If this " +
            "assertion ever fails, MyAppsScreen.groupedSections has regressed to categoryIds.last(where:)."
        )
    }
}
