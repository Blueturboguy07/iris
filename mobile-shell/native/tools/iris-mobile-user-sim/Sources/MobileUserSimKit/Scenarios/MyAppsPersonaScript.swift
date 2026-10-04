import Foundation
import IrisMobileShellCore

// MA5-persona-sim. The three people from SPEC 5.1 and the world they live
// in. Each persona turns a seed into a list of steps: what the person does
// on the My apps screen, in their own words (the note), plus the name they
// typed and how many characters THEY see in it (counted by the persona as
// it builds the name, never by Swift's `String.count` or MA1's validator,
// so the Python oracle judges the 30-character rule from the person's side).
//
// Seeds from real evidence: the app names, descriptions and task groups
// come from SPEC 1.1's sketch and the owner's phone test words the same day
// ("categories of like editing, clipping etc"), with Kneecap as the one app
// the owner actually installs and renames.

public enum MyAppsPersonaProfile: String, Sendable, CaseIterable {
    case p1NonTechnical = "p1-nontechnical"
    case p2Hurried = "p2-hurried"
    case p3Edge = "p3-edge"

    /// Chance each world fault lands in one run (SPEC 5.2), before `forced`.
    var faultDensity: Double {
        switch self {
        case .p1NonTechnical: return 0.25
        case .p2Hurried: return 0.4
        case .p3Edge: return 0.6
        }
    }

    /// SPEC 5.1's own per-persona list: P3 always gets disk full during a
    /// save, a force quit right after a rename and the clock set back a
    /// year.
    var forcedFaults: [MyAppsWorldFault] {
        switch self {
        case .p1NonTechnical: return [.updateRenamesPackage]
        case .p2Hurried: return [.appRemovedWhileInFolder]
        case .p3Edge: return [.diskFull, .crashBeforeRename, .clockSkew]
        }
    }

    /// Observe the screen after every Nth person action (P3's screen has
    /// 1,000 rows, so it looks less often; relaunches are always observed).
    var observeEvery: Int {
        switch self {
        case .p1NonTechnical, .p2Hurried: return 1
        case .p3Edge: return 6
        }
    }
}

/// One thing the person does. Folder ids are the ones the person's own
/// "New folder" produced (the shell makes the id when the dialog saves), so
/// the persona can refer back to "my Editing folder" later.
public enum MyAppsPersonaStep: Sendable {
    case rename(app: String, typed: String, seen: Int)
    case useOriginalName(app: String)
    case createFolder(id: String, typed: String, seen: Int, initialApps: [String])
    case renameFolder(id: String, typed: String, seen: Int)
    case deleteFolder(id: String)
    /// One app is the Move sheet; many is Select mode then "Move to folder".
    /// `nil` is the sheet's "No folder" row.
    case move(apps: [String], folder: String?)
    case takeOut(app: String)
    /// Drags the rows the person SEES in this folder into a new order.
    case reorderFolderApps(folder: String)
    case reorderFolders
    case collapseFolder(id: String, collapsed: Bool)
    /// Folds the first automatic group the person sees on screen.
    case collapseFirstGroup(collapsed: Bool)
    case open(app: String)
    case install(MyAppsSimApp)
    case reinstall(app: String)
    case remove(app: String, alsoDeleteData: Bool)
    case relaunch
    case observe(sort: MyAppsSort, query: String)
    /// P3: an iPhone restored from backup (every app's files are gone and
    /// need a download, the arrangement file is back), then a relaunch.
    case restoreFromBackup
    /// The world kills the app between the temporary write and the rename
    /// of the very next save (SPEC 5.1 P3: "a force quit 1 ms after a
    /// rename"); the scenario then relaunches, because the process died.
    case forceQuitDuringNextSave
}

public struct MyAppsPersonaPlan: Sendable {
    public let library: [MyAppsSimApp]
    public let categories: [MyAppsSimCategory]
    public let catalogOnline: Bool
    public let steps: [MyAppsPersonaStep]
    public let notes: [String]
}

// MARK: - World seed data

enum MyAppsSeedData {
    /// SPEC 1.1's task groups plus the owner's "editing, clipping", with
    /// catalog ids that do not match their display order.
    static let categoryNames: [(Int, String)] = [
        (1, "Editing"), (2, "Clipping"), (3, "Nutrition"), (4, "Music"), (5, "Photos"), (6, "Notes"),
        (7, "Fitness"), (8, "Study"), (9, "Money"), (10, "Travel"), (11, "Games"), (12, "Tools"),
    ]

    static let kneecap = MyAppsSimApp(
        identity: "publik.kneecap::publik.kneecap.shell", originalName: "Kneecap",
        description: "Clip, crop and share videos", categoryIds: [2, 1], sizeBytes: 42_000_000
    )

    static let sketchApps: [MyAppsSimApp] = [
        MyAppsSimApp(identity: "publik.substudio::publik.substudio.shell", originalName: "Sub Studio", description: "Add captions to a clip", categoryIds: [1, 2], sizeBytes: 18_000_000),
        MyAppsSimApp(identity: "publik.nutai::publik.nutai.shell", originalName: "Nut AI", description: "Track meals and food with photos", categoryIds: [3, 5], sizeBytes: 25_000_000),
        MyAppsSimApp(identity: "acme.plate::acme.plate.mobile", originalName: "Plate", description: "Plan a week of meals", categoryIds: [3], sizeBytes: 9_000_000),
        MyAppsSimApp(identity: "local.imported-thing::local.imported-thing.pkg", originalName: "Imported thing", description: "18 MB, updated 2026-09-21", categoryIds: [], sizeBytes: 18_000_000),
        MyAppsSimApp(identity: "acme.beatpad::acme.beatpad.mobile", originalName: "Beat Pad", description: "Make a beat in a minute", categoryIds: [4], sizeBytes: 31_000_000),
        MyAppsSimApp(identity: "acme.jot::acme.jot.mobile", originalName: "Jot", description: "Quick notes that sync", categoryIds: [6], sizeBytes: 4_000_000),
    ]

    static let adjectives = ["Quick", "Tiny", "Bright", "Calm", "Daily", "Sharp", "Handy", "Clever", "Simple", "Pocket", "Swift", "Neat"]
    static let nouns = ["Cut", "Frame", "Meal", "Beat", "Note", "Step", "Card", "Snap", "Plan", "Trip", "Coin", "Tool", "Clip", "Tune", "Page"]

    static func categories(rng: inout SeededGenerator) -> [MyAppsSimCategory] {
        var orders = Array(0..<categoryNames.count)
        for index in stride(from: orders.count - 1, to: 0, by: -1) {
            let other = Int(rng.next() % UInt64(index + 1))
            orders.swapAt(index, other)
        }
        return categoryNames.enumerated().map { offset, pair in
            MyAppsSimCategory(id: pair.0, name: pair.1, order: orders[offset])
        }
    }

    /// A generated app. Some have no category (imported), some list a
    /// category the catalog no longer has (id 99) before a real one, some
    /// share a name with another app (two "Notes" apps is a real thing).
    static func generatedApp(number: Int, rng: inout SeededGenerator) -> MyAppsSimApp {
        let adjective = adjectives[Int(rng.next() % UInt64(adjectives.count))]
        let noun = nouns[Int(rng.next() % UInt64(nouns.count))]
        let name = rng.nextBool(probability: 0.1) ? "\(adjective) \(noun)" : "\(adjective) \(noun) \(number)"
        var cats: [Int] = []
        let roll = rng.nextUnitDouble()
        if roll < 0.08 {
            cats = []
        } else {
            let count = 1 + Int(rng.next() % 3)
            while cats.count < count {
                let id = 1 + Int(rng.next() % UInt64(categoryNames.count))
                if !cats.contains(id) { cats.append(id) }
            }
            if roll > 0.9 { cats.insert(99, at: 0) }
        }
        let slug = "\(adjective.lowercased())\(noun.lowercased())\(number)"
        return MyAppsSimApp(
            identity: "acme.\(slug)::acme.\(slug).mobile",
            originalName: name,
            description: "\(noun) things, the \(adjective.lowercased()) way",
            categoryIds: cats,
            sizeBytes: Int64(1_000_000 + Int(rng.next() % 90_000_000))
        )
    }
}

// MARK: - Names the person types (with the characters they see)

enum MyAppsTypedNames {
    /// P1: spaces and an emoji (SPEC 5.1). `seen` is what the person counts.
    static let p1Renames: [(String, Int)] = [
        ("Clips", 5), ("  Clips  ", 5), ("Clips \u{1F3AC}", 7), ("My clips", 8), ("Clip it", 7),
    ]

    static let arabicLetters: [UInt32] = [0x0627, 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F, 0x0631, 0x0633, 0x0634, 0x0635, 0x0639, 0x0641, 0x0642, 0x0643, 0x0644, 0x0645, 0x0646, 0x0647, 0x0648, 0x064A]
    static let arabicMarks: [UInt32] = [0x064E, 0x064F, 0x0650, 0x0651, 0x0652]

    /// `count` Arabic letters, each carrying 0 to 2 combining marks: the
    /// person sees `count` characters, while the text holds many more
    /// Unicode scalars.
    static func arabic(count: Int, rng: inout SeededGenerator) -> (String, Int) {
        var scalars = String.UnicodeScalarView()
        for _ in 0..<count {
            scalars.append(Unicode.Scalar(arabicLetters[Int(rng.next() % UInt64(arabicLetters.count))])!)
            let marks = Int(rng.next() % 3)
            var used: Set<UInt32> = []
            for _ in 0..<marks {
                let mark = arabicMarks[Int(rng.next() % UInt64(arabicMarks.count))]
                if used.insert(mark).inserted { scalars.append(Unicode.Scalar(mark)!) }
            }
        }
        return (String(scalars), count)
    }

    /// Latin letters with combining accents (e + U+0301 and so on).
    static func latinCombining(count: Int, rng: inout SeededGenerator) -> (String, Int) {
        let bases: [Character] = ["a", "e", "i", "o", "u", "n", "c"]
        let marks: [UInt32] = [0x0301, 0x0308, 0x0302, 0x0323, 0x0327]
        var scalars = String.UnicodeScalarView()
        for _ in 0..<count {
            scalars.append(contentsOf: String(bases[Int(rng.next() % UInt64(bases.count))]).unicodeScalars)
            scalars.append(Unicode.Scalar(marks[Int(rng.next() % UInt64(marks.count))])!)
        }
        return (String(scalars), count)
    }

    static func ascii(count: Int) -> (String, Int) {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJ")
        return (String(letters.prefix(count)), count)
    }
}

// MARK: - The three personas

extension MyAppsPersonaProfile {
    /// `appCount` overrides the persona's default library size (P3 = 1,000).
    public func plan(rng: inout SeededGenerator, runIndex: Int, appCount: Int? = nil) -> MyAppsPersonaPlan {
        switch self {
        case .p1NonTechnical: return Self.p1(rng: &rng)
        case .p2Hurried: return Self.p2(rng: &rng, appCount: appCount)
        case .p3Edge: return Self.p3(rng: &rng, runIndex: runIndex, appCount: appCount ?? 1000)
        }
    }

    private static func pick(_ pool: [MyAppsSimApp], rng: inout SeededGenerator) -> MyAppsSimApp {
        pool[Int(rng.next() % UInt64(pool.count))]
    }

    /// P1, non-technical: starts with 5 apps (the 5-app world must stay one
    /// "All apps" list), gets a few more from the store, renames Kneecap
    /// from the long press, makes at most 2 folders by tapping the first big
    /// control, and later looks for Kneecap by its OLD name.
    private static func p1(rng: inout SeededGenerator) -> MyAppsPersonaPlan {
        let categories = MyAppsSeedData.categories(rng: &rng)
        var sketch = MyAppsSeedData.sketchApps
        var library = [MyAppsSeedData.kneecap]
        while library.count < 5 {
            let index = Int(rng.next() % UInt64(sketch.count))
            library.append(sketch.remove(at: index))
        }
        var extra: [MyAppsSimApp] = sketch
        var number = 100
        while extra.count < 12 {
            extra.append(MyAppsSeedData.generatedApp(number: number, rng: &rng))
            number += 1
        }
        let kneecap = MyAppsSeedData.kneecap.identity
        let (renameTo, seen) = MyAppsTypedNames.p1Renames[Int(rng.next() % UInt64(MyAppsTypedNames.p1Renames.count))]
        var steps: [MyAppsPersonaStep] = [
            .observe(sort: .groups, query: ""),
            .open(app: kneecap),
        ]
        // Gets 1 or 2 apps from the store: the screen crosses 6 apps.
        let firstInstalls = 1 + Int(rng.next() % 2)
        for _ in 0..<firstInstalls { steps.append(.install(extra.removeFirst())) }
        steps.append(.rename(app: kneecap, typed: renameTo, seen: seen))
        // Move sheet, "New folder...": the dialog is prefilled with the
        // app's group name and P1 taps Save.
        steps.append(.createFolder(id: "p1-folder-1", typed: "Clipping", seen: 8, initialApps: [kneecap]))
        steps.append(.open(app: library[2].identity))
        // More store installs, to 12 to 14 apps (the search field appears).
        var installed = library.count + firstInstalls
        let target = 12 + Int(rng.next() % 3)
        while !extra.isEmpty, installed < target {
            steps.append(.install(extra.removeFirst()))
            installed += 1
        }
        steps.append(.observe(sort: .groups, query: "Kneecap"))
        steps.append(.observe(sort: .groups, query: "clips"))
        steps.append(.relaunch)
        // Taps the first folder in the Move sheet.
        steps.append(.move(apps: [library[1].identity], folder: "p1-folder-1"))
        if rng.nextBool(probability: 0.6) {
            steps.append(.createFolder(id: "p1-folder-2", typed: "Food", seen: 4, initialApps: [library[3].identity]))
        }
        steps.append(.open(app: library[1].identity))
        steps.append(.observe(sort: .recent, query: ""))
        steps.append(.observe(sort: .name, query: ""))
        steps.append(.relaunch)
        steps.append(.observe(sort: .groups, query: "kneecap"))
        steps.append(.open(app: kneecap))
        steps.append(.relaunch)
        return MyAppsPersonaPlan(library: library, categories: categories, catalogOnline: true, steps: steps, notes: ["P1 renames Kneecap to \"\(renameTo)\""])
    }

    /// P2, hurried: 10 folders in a minute, 50 apps through Select mode,
    /// double taps Save, fast reorders, searches with a sheet open, removes
    /// an app that sits in a folder and gets it back, deletes a folder.
    private static func p2(rng: inout SeededGenerator, appCount: Int?) -> MyAppsPersonaPlan {
        let categories = MyAppsSeedData.categories(rng: &rng)
        let count = appCount ?? (40 + Int(rng.next() % 21))
        var library = [MyAppsSeedData.kneecap] + MyAppsSeedData.sketchApps
        var number = 0
        while library.count < count {
            library.append(MyAppsSeedData.generatedApp(number: number, rng: &rng))
            number += 1
        }
        let ids = library.map(\.identity)
        let folderNames = ["Work", "Fun", "Videos", "Food", "Money", "Daily", "Kids", "Later", "Work", "Try"]
        var steps: [MyAppsPersonaStep] = []
        for (index, name) in folderNames.enumerated() {
            steps.append(.createFolder(id: "p2-folder-\(index)", typed: name, seen: name.utf8.count, initialApps: []))
        }
        // Select mode: 50 apps in a few batches, each to a folder.
        var toMove = Array(ids.shuffledSeeded(rng: &rng).prefix(50))
        while !toMove.isEmpty {
            let size = min(toMove.count, 5 + Int(rng.next() % 12))
            let batch = Array(toMove.prefix(size))
            toMove.removeFirst(size)
            let folder = "p2-folder-\(Int(rng.next() % 10))"
            steps.append(.move(apps: batch, folder: folder))
            // Searches while the Move sheet is open.
            if rng.nextBool(probability: 0.5) { steps.append(.observe(sort: .groups, query: "clip")) }
        }
        let renamed = ids[Int(rng.next() % UInt64(ids.count))]
        steps.append(.rename(app: renamed, typed: "Renamed Twice", seen: 13))
        steps.append(.rename(app: renamed, typed: "Renamed Twice", seen: 13)) // double tap on Save
        steps.append(.rename(app: ids[1], typed: "   ", seen: 0)) // an empty name: Save must refuse
        steps.append(.rename(app: ids[2], typed: "Clip\ns", seen: 6)) // a pasted line break: refused
        steps.append(.rename(app: ids[3], typed: MyAppsTypedNames.ascii(count: 31).0, seen: 31))
        for _ in 0..<3 {
            steps.append(.reorderFolderApps(folder: "p2-folder-\(Int(rng.next() % 10))"))
        }
        steps.append(.reorderFolders)
        steps.append(.takeOut(app: ids[Int(rng.next() % UInt64(min(50, ids.count)))]))
        steps.append(.collapseFolder(id: "p2-folder-\(Int(rng.next() % 10))", collapsed: true))
        steps.append(.collapseFirstGroup(collapsed: true))
        steps.append(.renameFolder(id: "p2-folder-1", typed: "Weekend", seen: 7))
        // Removes an app it had put in a folder (keeps its data), then gets
        // it back from the store: it must land in the same folder, same name.
        let movedAndRemoved = ids.shuffledSeeded(rng: &rng).first ?? ids[0]
        steps.append(.move(apps: [movedAndRemoved], folder: "p2-folder-2"))
        steps.append(.rename(app: movedAndRemoved, typed: "Keep me", seen: 7))
        steps.append(.remove(app: movedAndRemoved, alsoDeleteData: false))
        steps.append(.observe(sort: .groups, query: ""))
        steps.append(.reinstall(app: movedAndRemoved))
        steps.append(.deleteFolder(id: "p2-folder-3"))
        steps.append(.relaunch)
        for _ in 0..<3 { steps.append(.open(app: ids[Int(rng.next() % UInt64(ids.count))])) }
        steps.append(.observe(sort: .recent, query: ""))
        // Removes one more with "Also delete my data" and gets it back.
        let forgotten = ids[Int(rng.next() % UInt64(ids.count))]
        steps.append(.remove(app: forgotten, alsoDeleteData: true))
        steps.append(.reinstall(app: forgotten))
        steps.append(.useOriginalName(app: renamed))
        steps.append(.move(apps: [ids[0]], folder: nil))
        steps.append(.relaunch)
        return MyAppsPersonaPlan(library: library, categories: categories, catalogOnline: true, steps: steps, notes: ["P2 library of \(count) apps"])
    }

    /// P3, edge: 1,000 apps, 40 folders (a 41st refused), 300 apps in one
    /// folder (a 301st refused), 30-character Arabic and combining-mark
    /// names (a 31st character refused), the catalog offline for the whole
    /// run on odd runs or a category deleted between launches on even runs,
    /// a restore from backup, and the world's forced faults (disk full,
    /// force quit right after a rename, the clock set back a year). The
    /// largest text size changes only the view (MA3 and MA6 own that); the
    /// screen's logic is the same at every size.
    private static func p3(rng: inout SeededGenerator, runIndex: Int, appCount: Int) -> MyAppsPersonaPlan {
        let categories = MyAppsSeedData.categories(rng: &rng)
        let online = runIndex % 2 == 0
        var library = [MyAppsSeedData.kneecap] + MyAppsSeedData.sketchApps
        var number = 0
        while library.count < appCount {
            library.append(MyAppsSeedData.generatedApp(number: number, rng: &rng))
            number += 1
        }
        let ids = library.map(\.identity)
        var steps: [MyAppsPersonaStep] = [.observe(sort: .groups, query: "")]
        let arabic = MyAppsTypedNames.arabic(count: 30, rng: &rng)
        steps.append(.rename(app: ids[0], typed: arabic.0, seen: arabic.1))
        let latin = MyAppsTypedNames.latinCombining(count: 30, rng: &rng)
        steps.append(.rename(app: ids[1], typed: latin.0, seen: latin.1))
        let tooLong = MyAppsTypedNames.arabic(count: 31, rng: &rng)
        steps.append(.rename(app: ids[2], typed: tooLong.0, seen: tooLong.1))
        steps.append(.observe(sort: .groups, query: ""))
        for index in 0..<40 {
            steps.append(.createFolder(id: "p3-folder-\(index)", typed: "Folder \(index)", seen: "Folder \(index)".utf8.count, initialApps: []))
        }
        steps.append(.createFolder(id: "p3-folder-40", typed: "One too many", seen: 12, initialApps: []))
        steps.append(.observe(sort: .groups, query: ""))
        // Select mode: 300 apps into one folder, then one more.
        let shuffled = ids.shuffledSeeded(rng: &rng)
        let fill = min(300, shuffled.count - 2)
        steps.append(.move(apps: Array(shuffled.prefix(fill)), folder: "p3-folder-0"))
        steps.append(.observe(sort: .groups, query: ""))
        steps.append(.move(apps: [shuffled[fill]], folder: "p3-folder-0"))
        var cursor = fill + 1
        for folder in 1..<40 where cursor < shuffled.count - shuffled.count / 5 {
            let size = 1 + Int(rng.next() % 12)
            steps.append(.move(apps: Array(shuffled[cursor..<min(cursor + size, shuffled.count)]), folder: "p3-folder-\(folder)"))
            cursor += size
        }
        steps.append(.observe(sort: .groups, query: ""))
        steps.append(.reorderFolderApps(folder: "p3-folder-0"))
        // A force quit 1 ms after a rename: the save never reaches its rename.
        steps.append(.forceQuitDuringNextSave)
        steps.append(.rename(app: ids[3], typed: "Force quit after this", seen: 21))
        for _ in 0..<4 { steps.append(.open(app: ids[Int(rng.next() % UInt64(ids.count))])) }
        steps.append(.observe(sort: .recent, query: ""))
        steps.append(.observe(sort: .groups, query: "kneecap"))
        steps.append(.deleteFolder(id: "p3-folder-\(1 + Int(rng.next() % 39))"))
        steps.append(.restoreFromBackup)
        steps.append(.observe(sort: .name, query: ""))
        steps.append(.open(app: ids[0]))
        steps.append(.relaunch)
        return MyAppsPersonaPlan(
            library: library, categories: categories, catalogOnline: online, steps: steps,
            notes: ["P3 with \(appCount) apps, catalog \(online ? "online" : "offline for the whole run")"]
        )
    }
}

extension Array {
    /// Fisher-Yates driven by the run's own generator (reproducible).
    func shuffledSeeded(rng: inout SeededGenerator) -> [Element] {
        var copy = self
        guard copy.count > 1 else { return copy }
        for index in stride(from: copy.count - 1, to: 0, by: -1) {
            let other = Int(rng.next() % UInt64(index + 1))
            copy.swapAt(index, other)
        }
        return copy
    }
}
