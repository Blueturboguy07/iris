import XCTest
@testable import IrisMobileShellCore

// Unit MA1-organization-core. Reducer and model tests. The seeded-run tests
// (`testPersonaLedgerSeed*`) follow the project's behavior-simulation rule:
// no asserted constant the code itself set, an oracle kept independently of
// the reducer (`PersonaLedger` below tracks what the *simulated person*
// did, in plain dictionaries, and is compared against the arrangement after
// every step), and a fixed seed so a failure replays exactly.

final class MyAppsOrganizationTests: XCTestCase {
    // MARK: Name validation

    func testNameValidatorTrimsAndAccepts() {
        switch MyAppsNameValidator.validate("  Clips  ") {
        case let .success(name): XCTAssertEqual(name, "Clips")
        case .failure: XCTFail("expected success")
        }
    }

    func testNameValidatorRejectsEmptyAfterTrim() {
        XCTAssertEqual(MyAppsNameValidator.validate("   "), .failure(.empty))
    }

    func testNameValidatorRejectsOver30Characters() {
        let raw = String(repeating: "a", count: 31)
        XCTAssertEqual(MyAppsNameValidator.validate(raw), .failure(.tooLong(limit: 30, actual: 31)))
    }

    func testNameValidatorAccepts30Characters() {
        let raw = String(repeating: "a", count: 30)
        XCTAssertTrue(MyAppsNameValidator.isValid(raw))
    }

    func testNameValidatorRejectsControlCharacters() {
        XCTAssertEqual(MyAppsNameValidator.validate("Clips\u{0007}"), .failure(.containsControlCharacters))
    }

    func testNameValidatorRejectsLineBreak() {
        XCTAssertEqual(MyAppsNameValidator.validate("Clips\nApp"), .failure(.containsControlCharacters))
    }

    /// Persona P3: "30-character names in Arabic and with combining marks".
    /// Grapheme-cluster counting means a base letter plus a combining mark
    /// counts as the one visible character.
    func testNameValidatorCountsGraphemeClustersNotUnicodeScalars() {
        // "e" + combining acute accent (U+0301), 30 times: 30 grapheme
        // clusters, 60 unicode scalars. Must be accepted.
        let combining = String(repeating: "e\u{0301}", count: 30)
        XCTAssertEqual(combining.unicodeScalars.count, 60)
        XCTAssertTrue(MyAppsNameValidator.isValid(combining), "30 grapheme clusters should be valid even though it is 60 scalars")
        let tooLong = String(repeating: "e\u{0301}", count: 31)
        XCTAssertFalse(MyAppsNameValidator.isValid(tooLong))
    }

    func testNameValidatorAcceptsArabic() {
        XCTAssertTrue(MyAppsNameValidator.isValid("تطبيقاتي"))
    }

    // MARK: Rename (1.3)

    func testRenameStoresCustomNameAndEmitsEvent() {
        let result = MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: .empty)
        guard case let .success(outcome) = result else { return XCTFail() }
        XCTAssertEqual(outcome.arrangement.customName(for: "a::p"), "Clips")
        XCTAssertEqual(outcome.event, .renamed(identity: "a::p", name: "Clips"))
    }

    func testRenameRejectsInvalidNameAndArrangementUnchanged() {
        let start = MyAppsArrangement.empty
        let result = MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: ""), to: start)
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidName(.empty))
    }

    func testUseOriginalNameClearsCustomNameAndDropsEmptyEntry() {
        let renamed = try! require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: .empty))
        let reset = try! require(MyAppsOrganizationReducer.apply(.useOriginalName(identity: "a::p"), to: renamed.arrangement))
        XCTAssertNil(reset.arrangement.customName(for: "a::p"))
        XCTAssertNil(reset.arrangement.apps["a::p"], "an all-default entry must not linger (SPEC 3.1: only non-default entries are kept)")
    }

    func testUseOriginalNameKeepsEntryWhenOtherFieldsSet() {
        let renamed = try! require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: .empty))
        let opened = try! require(MyAppsOrganizationReducer.apply(.recordOpened(identity: "a::p", at: "2026-09-28T00:00:00Z"), to: renamed.arrangement))
        let reset = try! require(MyAppsOrganizationReducer.apply(.useOriginalName(identity: "a::p"), to: opened.arrangement))
        XCTAssertNil(reset.arrangement.customName(for: "a::p"))
        XCTAssertNotNil(reset.arrangement.apps["a::p"], "lastOpenedAt must survive a name reset")
    }

    // MARK: Folders and the one-place rule (1.4)

    func testCreateFolderThenMoveAppPlacesItInExactlyOneFolder() {
        var arrangement = MyAppsArrangement.empty
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: [], createdAt: "2026-09-28T00:00:00Z"), to: arrangement)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F2", name: "Music", initialApps: [], createdAt: "2026-09-28T00:00:00Z"), to: arrangement)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.moveToFolder(identity: "a::p", folderId: "F1"), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.folder(containing: "a::p")?.id, "F1")

        arrangement = try! require(MyAppsOrganizationReducer.apply(.moveToFolder(identity: "a::p", folderId: "F2"), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.folder(containing: "a::p")?.id, "F2", "moving to a new folder must remove it from the old one")
        XCTAssertFalse(arrangement.folders.first { $0.id == "F1" }!.apps.contains("a::p"))

        let occurrences = arrangement.folders.filter { $0.apps.contains("a::p") }.count
        XCTAssertEqual(occurrences, 1, "the one-place rule: an app is in at most one folder")
    }

    func testTakeOutOfFolderReturnsAppToNoFolder() {
        var arrangement = MyAppsArrangement.empty
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p"], createdAt: "t"), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.folder(containing: "a::p")?.id, "F1")
        let outcome = try! require(MyAppsOrganizationReducer.apply(.takeOutOfFolder(identity: "a::p"), to: arrangement))
        XCTAssertNil(outcome.arrangement.folder(containing: "a::p"))
        XCTAssertEqual(outcome.event, .tookOut(identity: "a::p", fromFolderId: "F1", fromFolderName: "Editing"))
    }

    func testMoveToUnknownFolderFails() {
        let result = MyAppsOrganizationReducer.apply(.moveToFolder(identity: "a::p", folderId: "nope"), to: .empty)
        XCTAssertEqual(result, .failure(.folderNotFound))
    }

    func testFolderAppLimitEnforced() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Big", initialApps: [], createdAt: "t"), to: .empty)).arrangement
        // my-apps-organization SPEC 3.2: exactly 300 apps per folder.
        for i in 0..<300 {
            arrangement = try! require(MyAppsOrganizationReducer.apply(.moveToFolder(identity: "app\(i)::p", folderId: "F1"), to: arrangement)).arrangement
        }
        XCTAssertEqual(arrangement.folders[0].apps.count, 300)
        let overflow = MyAppsOrganizationReducer.apply(.moveToFolder(identity: "overflow::p", folderId: "F1"), to: arrangement)
        XCTAssertEqual(overflow, .failure(.folderAppLimitReached(limit: 300)))
    }

    func testFolderCountLimitEnforced() {
        var arrangement = MyAppsArrangement.empty
        // my-apps-organization SPEC 3.2: exactly 40 folders.
        for i in 0..<40 {
            arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F\(i)", name: "Folder \(i)", initialApps: [], createdAt: "t"), to: arrangement)).arrangement
        }
        XCTAssertEqual(arrangement.folders.count, 40)
        let overflow = MyAppsOrganizationReducer.apply(.createFolder(id: "F-overflow", name: "One too many", initialApps: [], createdAt: "t"), to: arrangement)
        XCTAssertEqual(overflow, .failure(.folderLimitReached(limit: 40)))
    }

    func testDeleteFolderNeverTouchesAppEntriesOrOtherFolders() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p", "b::p"], createdAt: "t"), to: .empty)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: arrangement)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F2", name: "Music", initialApps: ["c::p"], createdAt: "t"), to: arrangement)).arrangement

        let outcome = try! require(MyAppsOrganizationReducer.apply(.deleteFolder(folderId: "F1"), to: arrangement))
        XCTAssertNil(outcome.arrangement.folders.first { $0.id == "F1" })
        XCTAssertEqual(outcome.arrangement.folders.first { $0.id == "F2" }?.apps, ["c::p"], "the untouched folder must be unchanged")
        XCTAssertEqual(outcome.arrangement.customName(for: "a::p"), "Clips", "SPEC 1.4: deleting a folder never removes an app or its name")
        XCTAssertEqual(outcome.event, .folderDeleted(folderId: "F1", name: "Editing", returnedAppCount: 2))
    }

    func testReorderFolderAppsRejectsAMismatchedSet() {
        let arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p", "b::p"], createdAt: "t"), to: .empty)).arrangement
        let result = MyAppsOrganizationReducer.apply(.reorderFolderApps(folderId: "F1", order: ["a::p"]), to: arrangement)
        XCTAssertEqual(result, .failure(.reorderMismatch))
    }

    func testReorderFolderAppsAppliesAValidPermutation() {
        let arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p", "b::p", "c::p"], createdAt: "t"), to: .empty)).arrangement
        let outcome = try! require(MyAppsOrganizationReducer.apply(.reorderFolderApps(folderId: "F1", order: ["c::p", "a::p", "b::p"]), to: arrangement))
        XCTAssertEqual(outcome.arrangement.folders[0].apps, ["c::p", "a::p", "b::p"])
    }

    func testReorderFoldersAppliesOrder() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "A", initialApps: [], createdAt: "t"), to: .empty)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F2", name: "B", initialApps: [], createdAt: "t"), to: arrangement)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F3", name: "C", initialApps: [], createdAt: "t"), to: arrangement)).arrangement
        let outcome = try! require(MyAppsOrganizationReducer.apply(.reorderFolders(order: ["F3", "F1", "F2"]), to: arrangement))
        XCTAssertEqual(outcome.arrangement.folders.sorted { $0.order < $1.order }.map(\.id), ["F3", "F1", "F2"])
    }

    func testNewFolderFromMoveSheetTakesTheAppOutOfWhereverItWas() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Music", initialApps: ["a::p"], createdAt: "t"), to: .empty)).arrangement
        // "New folder..." started from the Move sheet with the app already
        // in a different folder must not duplicate it.
        arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F2", name: "Editing", initialApps: ["a::p"], createdAt: "t"), to: arrangement)).arrangement
        let occurrences = arrangement.folders.filter { $0.apps.contains("a::p") }.count
        XCTAssertEqual(occurrences, 1)
        XCTAssertEqual(arrangement.folder(containing: "a::p")?.id, "F2")
    }

    // MARK: Collapse (1.1 item 6, 8)

    func testGroupCollapseTogglesSet() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.setGroupCollapsed(categoryId: 7, collapsed: true), to: .empty)).arrangement
        XCTAssertEqual(arrangement.collapsedGroups, [7])
        arrangement = try! require(MyAppsOrganizationReducer.apply(.setGroupCollapsed(categoryId: 12, collapsed: true), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.collapsedGroups, [7, 12])
        arrangement = try! require(MyAppsOrganizationReducer.apply(.setGroupCollapsed(categoryId: 7, collapsed: false), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.collapsedGroups, [12])
    }

    func testFolderCollapseRequiresExistingFolder() {
        let result = MyAppsOrganizationReducer.apply(.setFolderCollapsed(folderId: "nope", collapsed: true), to: .empty)
        XCTAssertEqual(result, .failure(.folderNotFound))
    }

    // MARK: Recently used bookkeeping (1.1 item 4)

    func testInstallRecordsAnOpenTimestampSoAFreshInstallLeadsTheRecentsRow() {
        let outcome = try! require(MyAppsOrganizationReducer.apply(.recordInstalled(identity: "a::p", at: "2026-09-28T09:00:00Z"), to: .empty))
        XCTAssertEqual(outcome.arrangement.apps["a::p"]?.lastOpenedAt, "2026-09-28T09:00:00Z")
        XCTAssertEqual(outcome.arrangement.apps["a::p"]?.installedAt, "2026-09-28T09:00:00Z")
    }

    func testOpenAfterInstallOverwritesTheOpenTimestampButNotInstalledAt() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.recordInstalled(identity: "a::p", at: "2026-09-28T09:00:00Z"), to: .empty)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.recordOpened(identity: "a::p", at: "2026-09-28T10:00:00Z"), to: arrangement)).arrangement
        XCTAssertEqual(arrangement.apps["a::p"]?.lastOpenedAt, "2026-09-28T10:00:00Z")
        XCTAssertEqual(arrangement.apps["a::p"]?.installedAt, "2026-09-28T09:00:00Z")
    }

    // MARK: forgetApp (Remove + "Also delete my data")

    func testForgetAppDropsNameAndFolderMembership() {
        var arrangement = try! require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p"], createdAt: "t"), to: .empty)).arrangement
        arrangement = try! require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: arrangement)).arrangement
        let outcome = try! require(MyAppsOrganizationReducer.apply(.forgetApp(identity: "a::p"), to: arrangement))
        XCTAssertNil(outcome.arrangement.apps["a::p"])
        XCTAssertNil(outcome.arrangement.folder(containing: "a::p"))
    }

    // MARK: Codable round trip (SPEC 3.1 JSON shape)

    func testArrangementEncodesAndDecodesLosslessly() throws {
        var arrangement = try require(MyAppsOrganizationReducer.apply(.createFolder(id: "F1", name: "Editing", initialApps: ["a::p"], createdAt: "2026-09-28T09:12:00Z"), to: .empty)).arrangement
        arrangement = try require(MyAppsOrganizationReducer.apply(.rename(identity: "a::p", to: "Clips"), to: arrangement)).arrangement
        arrangement = try require(MyAppsOrganizationReducer.apply(.setGroupCollapsed(categoryId: 7, collapsed: true), to: arrangement)).arrangement

        let data = try JSONEncoder().encode(arrangement)
        let decoded = try JSONDecoder().decode(MyAppsArrangement.self, from: data)
        XCTAssertEqual(decoded, arrangement)
    }

    func testDecodingTheSpecsOwnExampleJSON() throws {
        let json = """
        {
          "version": 1,
          "folders": [
            { "id": "F9A3", "name": "Editing", "order": 0, "createdAt": "2026-09-28T09:12:00Z",
              "collapsed": false, "apps": ["publik.kneecap::publik.kneecap.shell", "acme.clips::acme.clips.mobile"] }
          ],
          "apps": {
            "publik.kneecap::publik.kneecap.shell": { "name": "Clips", "lastOpenedAt": "2026-09-28T09:40:11Z", "installedAt": "2026-09-20T18:02:00Z" }
          },
          "collapsedGroups": [7, 12],
          "hintDismissed": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MyAppsArrangement.self, from: json)
        XCTAssertEqual(decoded.folders.count, 1)
        XCTAssertEqual(decoded.folders[0].apps.count, 2)
        XCTAssertEqual(decoded.customName(for: "publik.kneecap::publik.kneecap.shell"), "Clips")
        XCTAssertEqual(decoded.collapsedGroups, [7, 12])
    }

    // MARK: Seeded persona-ledger runs (SPEC 5.1 to 5.4, scaled to what MA1 alone can check without the file, catalog and world MA5 owns)

    func testPersonaLedgerSeed1At100Apps() { runPersonaLedger(seed: 1, appCount: 100, stepCount: 400) }
    func testPersonaLedgerSeed2At100Apps() { runPersonaLedger(seed: 2, appCount: 100, stepCount: 400) }
    func testPersonaLedgerSeed3At100Apps() { runPersonaLedger(seed: 3, appCount: 100, stepCount: 400) }
    func testPersonaLedgerSeed4At1000Apps() { runPersonaLedger(seed: 4, appCount: 1000, stepCount: 600) }

    /// Drives the reducer with a seeded pseudo-random sequence of the
    /// person's actions (P1/P2-shaped: rename, move, new folder, take out,
    /// delete folder, reorder) and checks every step against `PersonaLedger`,
    /// a ground truth kept by the *test*, not derived from the reducer's own
    /// data structures. Mirrors SPEC 5.3's "persona's own ledger" oracle,
    /// scoped to what MA1 (no file, no catalog, no world) can check on its
    /// own; MA5 extends this with the file and fault schedule.
    private func runPersonaLedger(seed: UInt64, appCount: Int, stepCount: Int) {
        var rng = SeededRNG(seed: seed)
        var arrangement = MyAppsArrangement.empty
        var ledger = PersonaLedger()
        let identities = (0..<appCount).map { "app\($0)::proj\($0)" }
        var nextFolderId = 0

        for step in 0..<stepCount {
            let identity = identities[Int(rng.next(upperBound: UInt64(identities.count)))]
            let choice = rng.next(upperBound: 8)
            switch choice {
            case 0: // rename
                let name = "Name\(rng.next(upperBound: 999))"
                let result = MyAppsOrganizationReducer.apply(.rename(identity: identity, to: name), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.names[identity] = name
                }
            case 1: // use original name
                let result = MyAppsOrganizationReducer.apply(.useOriginalName(identity: identity), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.names.removeValue(forKey: identity)
                }
            case 2, 3: // move to an existing folder (if any)
                guard let folderId = ledger.folderOrder.randomElementDeterministic(&rng) else { continue }
                let result = MyAppsOrganizationReducer.apply(.moveToFolder(identity: identity, folderId: folderId), to: arrangement)
                if case .success(let outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.membership[identity] = folderId
                } else if case .failure(.folderAppLimitReached) = result {
                    // Expected once a folder is deliberately filled; not a bug.
                } else if case .failure = result {
                    XCTFail("seed \(seed) step \(step): unexpected move failure")
                }
            case 4: // take out
                let result = MyAppsOrganizationReducer.apply(.takeOutOfFolder(identity: identity), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.membership.removeValue(forKey: identity)
                }
            case 5: // new folder
                guard ledger.folderOrder.count < 40 else { continue }
                let id = "F\(nextFolderId)"; nextFolderId += 1
                let name = "Folder\(rng.next(upperBound: 999))"
                let result = MyAppsOrganizationReducer.apply(.createFolder(id: id, name: name, initialApps: [], createdAt: "t\(step)"), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.folderOrder.append(id)
                    ledger.folderNames[id] = name
                }
            case 6: // delete a folder
                guard let folderId = ledger.folderOrder.randomElementDeterministic(&rng) else { continue }
                let result = MyAppsOrganizationReducer.apply(.deleteFolder(folderId: folderId), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.folderOrder.removeAll { $0 == folderId }
                    ledger.folderNames.removeValue(forKey: folderId)
                    for (app, folder) in ledger.membership where folder == folderId {
                        ledger.membership.removeValue(forKey: app)
                    }
                }
            default: // rename a folder
                guard let folderId = ledger.folderOrder.randomElementDeterministic(&rng) else { continue }
                let name = "Renamed\(rng.next(upperBound: 999))"
                let result = MyAppsOrganizationReducer.apply(.renameFolder(folderId: folderId, to: name), to: arrangement)
                if case let .success(outcome) = result {
                    arrangement = outcome.arrangement
                    ledger.folderNames[folderId] = name
                }
            }

            // Independent-oracle checks, every step:
            assertOneePlaceRule(arrangement, step: step, seed: seed)
            assertFolderCountsMatchRows(arrangement, step: step, seed: seed)
            for (app, expectedFolder) in ledger.membership {
                XCTAssertEqual(arrangement.folder(containing: app)?.id, expectedFolder, "seed \(seed) step \(step): ledger says \(app) is in \(expectedFolder)")
            }
            for (app, expectedName) in ledger.names {
                XCTAssertEqual(arrangement.customName(for: app), expectedName, "seed \(seed) step \(step): ledger says \(app) is called \(expectedName)")
            }
            XCTAssertEqual(Set(arrangement.folders.map(\.id)), Set(ledger.folderOrder), "seed \(seed) step \(step): folder set drifted from the ledger")
            for folder in arrangement.folders {
                XCTAssertEqual(folder.name, ledger.folderNames[folder.id], "seed \(seed) step \(step)")
            }
        }

        // Codable round trip must hold on the final, most-exercised state too.
        XCTAssertNoThrow(try JSONDecoder().decode(MyAppsArrangement.self, from: JSONEncoder().encode(arrangement)))
    }

    private func assertOneePlaceRule(_ arrangement: MyAppsArrangement, step: Int, seed: UInt64) {
        var seen = Set<String>()
        for folder in arrangement.folders {
            for identity in folder.apps {
                XCTAssertFalse(seen.contains(identity), "seed \(seed) step \(step): \(identity) is in two folders")
                seen.insert(identity)
            }
        }
    }

    private func assertFolderCountsMatchRows(_ arrangement: MyAppsArrangement, step: Int, seed: UInt64) {
        for folder in arrangement.folders {
            XCTAssertEqual(Set(folder.apps).count, folder.apps.count, "seed \(seed) step \(step): folder \(folder.id) has a duplicate row")
            XCTAssertLessThanOrEqual(folder.apps.count, 300, "seed \(seed) step \(step): folder \(folder.id) over its limit")
        }
        XCTAssertLessThanOrEqual(arrangement.folders.count, 40, "seed \(seed) step \(step): too many folders")
    }
}

/// The test's own ground truth: what the simulated person meant to have
/// happen, tracked with nothing borrowed from `MyAppsArrangement`'s own
/// types (plain `[String: String]` / `[String]`), so a bug that makes the
/// reducer agree with itself cannot also make the oracle agree.
private struct PersonaLedger {
    var names: [String: String] = [:]
    var membership: [String: String] = [:]
    var folderOrder: [String] = []
    var folderNames: [String: String] = [:]
}

/// A small deterministic PRNG (SplitMix64), used only so a failing seeded
/// run can be reproduced exactly by re-running the same seed; never
/// `Int.random` / `SystemRandomNumberGenerator`.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else { return 0 }
        return next() % upperBound
    }
}

private extension Array {
    func randomElementDeterministic(_ rng: inout SeededRNG) -> Element? {
        guard !isEmpty else { return nil }
        return self[Int(rng.next(upperBound: UInt64(count)))]
    }
}

func require<T>(_ result: Result<T, MyAppsActionError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    switch result {
    case let .success(value): return value
    case let .failure(error):
        XCTFail("expected success, got \(error)", file: file, line: line)
        throw error
    }
}
