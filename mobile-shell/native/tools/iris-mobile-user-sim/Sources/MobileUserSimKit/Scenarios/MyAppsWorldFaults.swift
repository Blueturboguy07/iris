import Foundation

// MA5-persona-sim. SPEC 5.2's misbehaving world: which fault lands before
// which persona step, decided only by the run's seed, so (persona, seed,
// run) replays exactly. What each fault does to the world is in
// `MyAppsScenario.swift`; how it reaches MA1 is in `MyAppsShellGlue`.

public enum MyAppsWorldFault: String, Sendable, CaseIterable {
    /// The next save fails partway (the file system refuses the write).
    case diskFull
    /// The app is killed between the temporary write and the rename.
    case crashBeforeRename
    /// `my-apps.json` is cut in half on disk, then the app relaunches.
    case truncatedFile
    /// `my-apps.json` holds bytes that are not JSON, then the app relaunches.
    case corruptFile
    /// A newer Iris wrote `my-apps.json` (version 2, with a field this
    /// reader does not know), then the app relaunches. Scheduled only near
    /// the end of a run, like restoring a backup from a newer phone.
    case versionAhead
    /// The catalog now lists different categories for one installed app.
    case categoryIdsChanged
    /// A category is deleted on the website between launches.
    case categoryDropped
    /// An app update changes the package's own name.
    case updateRenamesPackage
    /// An app that sits in a folder is removed from the iPhone (data kept),
    /// and comes back two steps later with some probability.
    case appRemovedWhileInFolder
    /// The clock is set back a year.
    case clockSkew
}

public struct MyAppsScheduledFault: Sendable, Equatable {
    public let beforeStep: Int
    public let fault: MyAppsWorldFault
}

public struct MyAppsFaultSchedule: Sendable {
    public let scheduled: [MyAppsScheduledFault]

    /// `density` is the chance each fault in the menu lands in this run;
    /// `forced` always land (a persona's own list in SPEC 5.1, for example
    /// P3's disk full, force quit and clock set back a year).
    public init(stepCount: Int, density: Double, forced: [MyAppsWorldFault], catalogOnline: Bool, rng: inout SeededGenerator) {
        guard stepCount > 1 else { scheduled = []; return }
        var picked: [MyAppsScheduledFault] = []
        for fault in MyAppsWorldFault.allCases {
            let lands = forced.contains(fault) || rng.nextBool(probability: density)
            // Draw the position even when the fault does not land, so adding
            // one fault to `forced` never reshuffles the others.
            let position = Int(rng.next() % UInt64(stepCount - 1)) + 1
            guard lands else { continue }
            if !catalogOnline, fault == .categoryIdsChanged || fault == .categoryDropped { continue }
            let step: Int
            if fault == .versionAhead {
                step = max(1, stepCount - 1 - Int(rng.next() % 3))
            } else {
                step = position
            }
            picked.append(MyAppsScheduledFault(beforeStep: step, fault: fault))
        }
        scheduled = picked.sorted { ($0.beforeStep, $0.fault.rawValue) < ($1.beforeStep, $1.fault.rawValue) }
    }

    public func faults(beforeStep index: Int) -> [MyAppsWorldFault] {
        scheduled.filter { $0.beforeStep == index }.map(\.fault)
    }
}
