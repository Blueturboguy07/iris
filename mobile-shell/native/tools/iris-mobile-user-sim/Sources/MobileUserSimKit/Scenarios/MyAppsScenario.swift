import Foundation
import IrisMobileShellCore

// MA5-persona-sim. Runs one seeded persona run in a misbehaving world
// against MA1's real code (through `MyAppsShellGlue`) and writes everything
// that happened as a JSONL trace: the world, every fault, every person
// action with MA1's answer, every relaunch, and every screen the person saw
// (MA1's `MyAppsScreen.sections` output plus the real bytes on disk).
//
// This file never decides pass or fail. The verdicts, and the SPEC 5.4
// failure taxonomy, come from `round3/my-apps-organization/tests/
// oracle_myapps.py`, which replays the trace in Python from the spec alone.
// `MyAppsPersonaSimTests.swift` runs the sweep and that oracle; the Python
// mutation runner builds the same files in a scratch package against
// mutated COPIES of MA1's sources.

final class MyAppsSimWorld {
    var installed: [MyAppsSimApp]
    var removed: [String: MyAppsSimApp] = [:]
    /// `nil` is the catalog offline (never fetched): no categories known.
    var categories: [MyAppsSimCategory]?
    var needsDownload: Set<String> = []
    var clock: Date
    private(set) var indexOf: [String: Int] = [:]
    private var nextIndex = 0

    init(library: [MyAppsSimApp], categories: [MyAppsSimCategory]?, clock: Date) {
        self.installed = []
        self.categories = categories
        self.clock = clock
        for app in library { install(app) }
    }

    @discardableResult
    func install(_ app: MyAppsSimApp) -> Int {
        if let index = indexOf[app.identity] {
            if !installed.contains(where: { $0.identity == app.identity }) { installed.append(app) }
            removed.removeValue(forKey: app.identity)
            return index
        }
        let index = nextIndex
        nextIndex += 1
        indexOf[app.identity] = index
        installed.append(app)
        return index
    }

    func isInstalled(_ identity: String) -> Bool { installed.contains { $0.identity == identity } }

    func remove(_ identity: String) {
        guard let position = installed.firstIndex(where: { $0.identity == identity }) else { return }
        removed[identity] = installed.remove(at: position)
    }

    func index(_ identity: String) -> Int { indexOf[identity] ?? -1 }
}

public enum MyAppsSweep {
    /// SPEC 5.4: "Every scenario at 3 seeds x 12 runs."
    public static let seeds: [UInt64] = [20260928, 7, 4200]
    public static let runsPerSeed = 12

    public static func traceName(persona: MyAppsPersonaProfile, baseSeed: UInt64, runIndex: Int, suffix: String = "") -> String {
        "\(persona.rawValue)\(suffix)-s\(baseSeed)-r\(runIndex)"
    }

    /// Runs every persona at every seed and run index; returns the traces.
    @discardableResult
    public static func runAll(
        personas: [MyAppsPersonaProfile] = MyAppsPersonaProfile.allCases,
        seeds: [UInt64] = MyAppsSweep.seeds,
        runsPerSeed: Int = MyAppsSweep.runsPerSeed,
        workRoot: URL,
        traceDir: URL
    ) throws -> [URL] {
        var traces: [URL] = []
        for persona in personas {
            for seed in seeds {
                for run in 0..<runsPerSeed {
                    traces.append(try runOne(persona: persona, baseSeed: seed, runIndex: run, workRoot: workRoot, traceDir: traceDir))
                }
            }
        }
        return traces
    }

    /// One seeded run. `appCount` overrides the persona's library size;
    /// `measureAtLimits` (P3 scale test only) ends the run by filling the
    /// arrangement to SPEC 3.2's limits and measuring the file and its load.
    @discardableResult
    public static func runOne(
        persona: MyAppsPersonaProfile,
        baseSeed: UInt64,
        runIndex: Int,
        workRoot: URL,
        traceDir: URL,
        appCount: Int? = nil,
        measureAtLimits: Bool = false,
        randomFaults: Bool = true,
        nameSuffix: String = ""
    ) throws -> URL {
        let name = traceName(persona: persona, baseSeed: baseSeed, runIndex: runIndex, suffix: nameSuffix)
        let runDir = workRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: runDir)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let trace = try MyAppsTraceWriter(url: traceDir.appendingPathComponent("\(name).jsonl"))
        defer { trace.close() }
        let runner = try MyAppsRun(persona: persona, baseSeed: baseSeed, runIndex: runIndex, runDir: runDir, trace: trace, appCount: appCount, measureAtLimits: measureAtLimits, randomFaults: randomFaults)
        runner.run()
        return trace.url
    }
}

/// One run's state. Deliberately a class with plain methods: every branch
/// writes what happened to the trace and nothing else.
final class MyAppsRun {
    private let persona: MyAppsPersonaProfile
    private let baseSeed: UInt64
    private let runIndex: Int
    private let trace: MyAppsTraceWriter
    private let glue: MyAppsShellGlue
    private let snapshotter = MyAppsFileSnapshotter()
    private let world: MyAppsSimWorld
    private let plan: MyAppsPersonaPlan
    private let schedule: MyAppsFaultSchedule
    private let measureAtLimits: Bool
    private var rng: SeededGenerator
    private var step = 0
    private var actsSinceObserve = 0
    private var pendingReinstalls: [(dueStep: Int, identity: String)] = []

    /// `randomFaults: false` keeps only the persona's own SPEC 5.1 faults
    /// (the P3 scale run measures the limits, which a random corrupt file
    /// would erase).
    init(persona: MyAppsPersonaProfile, baseSeed: UInt64, runIndex: Int, runDir: URL, trace: MyAppsTraceWriter, appCount: Int?, measureAtLimits: Bool, randomFaults: Bool) throws {
        self.persona = persona
        self.baseSeed = baseSeed
        self.runIndex = runIndex
        self.trace = trace
        self.measureAtLimits = measureAtLimits
        let derived = SeededGenerator.derivedSeed(baseSeed: baseSeed, runIndex: runIndex)
        let salt: UInt64 = persona == .p1NonTechnical ? 0x11 : (persona == .p2Hurried ? 0x22 : 0x33)
        var rng = SeededGenerator(seed: derived ^ (salt << 56))
        let plan = persona.plan(rng: &rng, runIndex: runIndex, appCount: appCount)
        self.plan = plan
        self.world = MyAppsSimWorld(
            library: plan.library,
            categories: plan.catalogOnline ? plan.categories : nil,
            clock: ISO8601DateFormatter().date(from: "2026-09-28T09:00:00Z") ?? Date(timeIntervalSince1970: 1_790_000_000)
        )
        self.schedule = MyAppsFaultSchedule(stepCount: plan.steps.count, density: randomFaults ? persona.faultDensity : 0, forced: persona.forcedFaults, catalogOnline: plan.catalogOnline, rng: &rng)
        self.rng = rng
        self.glue = try MyAppsShellGlue(root: runDir)
        trace.emit([
            "e": "run",
            "persona": persona.rawValue,
            "baseSeed": String(baseSeed),
            "runIndex": runIndex,
            "derivedSeed": String(derived),
            "ma1Present": MyAppsIntegration.isMA1Present,
            "notes": plan.notes,
            "measureAtLimits": measureAtLimits,
        ])
        trace.emit([
            "e": "world.init",
            "apps": world.installed.map { app -> [String: Any] in
                var object = app.traceObject
                object["idx"] = world.index(app.identity)
                return object
            },
            "online": plan.catalogOnline,
            "categories": plan.catalogOnline ? plan.categories.map(\.traceObject) : [],
        ])
        trace.emit([
            "e": "schedule",
            "faults": schedule.scheduled.map { ["before": $0.beforeStep, "fault": $0.fault.rawValue] as [String: Any] },
        ])
    }

    func run() {
        installHistory()
        for (index, step) in plan.steps.enumerated() {
            self.step = index
            for fault in schedule.faults(beforeStep: index) { apply(fault) }
            for due in pendingReinstalls where due.dueStep <= index {
                reinstall(due.identity, reason: "world")
            }
            pendingReinstalls.removeAll { $0.dueStep <= index }
            world.clock = world.clock.addingTimeInterval(TimeInterval(20 + Int(rng.next() % 600)))
            execute(step)
        }
        step = plan.steps.count
        if measureAtLimits { fillToLimitsAndMeasure() }
        observe(sort: .groups, query: "")
        trace.emit(["e": "end"])
    }

    // MARK: Person

    /// Every initial app was installed at some point in the past (SPEC 1.1
    /// item 4: installs count as opens), oldest first.
    private func installHistory() {
        let count = world.installed.count
        var actions: [MyAppsAction] = []
        for (offset, app) in world.installed.enumerated() {
            let when = world.clock.addingTimeInterval(TimeInterval(-(count - offset) * 120))
            actions.append(.recordInstalled(identity: app.identity, at: glue.stamp(worldNow: when)))
        }
        let result = glue.perform(actions)
        trace.emit([
            "e": "act", "step": -1, "type": "installHistory",
            "apps": world.installed.map { world.index($0.identity) },
            "outcomes": result.outcomes, "save": result.save.traceValue,
        ])
        observe(sort: .groups, query: "")
    }

    private func execute(_ step: MyAppsPersonaStep) {
        switch step {
        case let .rename(app, typed, seen):
            guard requireInstalled(app, "rename") else { return }
            act(["type": "rename", "app": world.index(app), "typed": typed, "seen": seen], [.rename(identity: app, to: typed)])
        case let .useOriginalName(app):
            guard requireInstalled(app, "useOriginalName") else { return }
            act(["type": "useOriginalName", "app": world.index(app)], [.useOriginalName(identity: app)])
        case let .createFolder(id, typed, seen, initialApps):
            let apps = initialApps.filter(world.isInstalled)
            let createdAt = MyAppsShellGlue.format(world.clock)
            act(["type": "createFolder", "folder": id, "typed": typed, "seen": seen, "apps": apps.map(world.index)],
                [.createFolder(id: id, name: typed, initialApps: apps, createdAt: createdAt)])
        case let .renameFolder(id, typed, seen):
            act(["type": "renameFolder", "folder": id, "typed": typed, "seen": seen], [.renameFolder(folderId: id, to: typed)])
        case let .deleteFolder(id):
            act(["type": "deleteFolder", "folder": id], [.deleteFolder(folderId: id)])
        case let .move(apps, folder):
            let visible = apps.filter(world.isInstalled)
            guard !visible.isEmpty else { skip("move", "none of the apps are installed"); return }
            act(["type": "move", "apps": visible.map(world.index), "folder": folder.map { $0 as Any } ?? NSNull()],
                visible.map { .moveToFolder(identity: $0, folderId: folder) })
        case let .takeOut(app):
            guard requireInstalled(app, "takeOut") else { return }
            act(["type": "takeOut", "app": world.index(app)], [.takeOutOfFolder(identity: app)])
        case let .reorderFolderApps(folder):
            reorderFolderApps(folder)
        case .reorderFolders:
            let seen = screen().sections.compactMap { section -> String? in
                if case let .folder(id, _, _) = section.kind { return id }
                return nil
            }
            guard seen.count > 1 else { skip("reorderFolders", "fewer than 2 folders on screen"); return }
            let order = seen.shuffledSeeded(rng: &rng)
            act(["type": "reorderFolders", "order": order], [.reorderFolders(order: order)])
        case let .collapseFolder(id, collapsed):
            act(["type": "collapseFolder", "folder": id, "collapsed": collapsed], [.setFolderCollapsed(folderId: id, collapsed: collapsed)])
        case let .collapseFirstGroup(collapsed):
            let groupId = screen().sections.lazy.compactMap { section -> Int? in
                switch section.kind {
                case let .group(categoryId, _, _): return categoryId
                case .other: return MyAppsLimits.otherGroupId
                default: return nil
                }
            }.first
            guard let groupId else { skip("collapseGroup", "no group headers on screen"); return }
            act(["type": "collapseGroup", "group": groupId, "collapsed": collapsed], [.setGroupCollapsed(categoryId: groupId, collapsed: collapsed)])
        case let .open(app):
            guard requireInstalled(app, "open") else { return }
            act(["type": "open", "app": world.index(app)], [.recordOpened(identity: app, at: glue.stamp(worldNow: world.clock))])
        case let .install(app):
            let index = world.install(app)
            var object = app.traceObject
            object["idx"] = index
            trace.emit(["e": "world.install", "step": self.step, "app": object, "reinstall": false])
            act(["type": "recordInstalled", "app": index], [.recordInstalled(identity: app.identity, at: glue.stamp(worldNow: world.clock))])
        case let .reinstall(app):
            reinstall(app, reason: "person")
        case let .remove(app, alsoDeleteData):
            guard requireInstalled(app, "remove") else { return }
            world.remove(app)
            trace.emit(["e": "world.remove", "step": self.step, "app": world.index(app), "alsoDeleteData": alsoDeleteData, "by": "person"])
            if alsoDeleteData {
                act(["type": "forgetApp", "app": world.index(app)], [.forgetApp(identity: app)])
            } else {
                observe(sort: .groups, query: "")
            }
        case .relaunch:
            relaunch(reason: "person")
        case let .observe(sort, query):
            observe(sort: sort, query: query)
        case .restoreFromBackup:
            world.needsDownload = Set(world.installed.map(\.identity))
            trace.emit(["e": "world.restoreFromBackup", "step": self.step])
            relaunch(reason: "restoreFromBackup")
        case .forceQuitDuringNextSave:
            glue.armCrashOnNextSave()
            trace.emit(["e": "fault.crashArmed", "step": self.step, "by": "person"])
        }
    }

    private func reorderFolderApps(_ folder: String) {
        let rows = screen().sections.first { section in
            if case let .folder(id, _, _) = section.kind { return id == folder }
            return false
        }?.rows.map(\.identity) ?? []
        guard rows.count > 1 else { skip("reorderFolderApps", "fewer than 2 apps visible in \(folder)"); return }
        let visibleOrder = rows.shuffledSeeded(rng: &rng)
        // The Reorder screen shows installed apps only; apps removed from
        // the iPhone but kept in the folder (SPEC 1.3) keep their relative
        // order at the end. MA2 must build the same full list (HANDOFF.md).
        let hidden = (glue.arrangement.folders.first { $0.id == folder }?.apps ?? []).filter { !rows.contains($0) }
        act(["type": "reorderFolderApps", "folder": folder, "visible": visibleOrder.map(world.index)],
            [.reorderFolderApps(folderId: folder, order: visibleOrder + hidden)])
    }

    private func reinstall(_ app: String, reason: String) {
        guard let stored = world.removed[app] else { skip("reinstall", "not removed"); return }
        let index = world.install(stored)
        var object = stored.traceObject
        object["idx"] = index
        trace.emit(["e": "world.install", "step": step, "app": object, "reinstall": true, "by": reason])
        act(["type": "recordInstalled", "app": index], [.recordInstalled(identity: app, at: glue.stamp(worldNow: world.clock))])
    }

    private func requireInstalled(_ app: String, _ type: String) -> Bool {
        if world.isInstalled(app) { return true }
        skip(type, "app not installed")
        return false
    }

    private func skip(_ type: String, _ why: String) {
        trace.emit(["e": "skip", "step": step, "type": type, "why": why])
    }

    private func act(_ fields: [String: Any], _ actions: [MyAppsAction]) {
        let result = glue.perform(actions)
        var event = fields
        event["e"] = "act"
        event["step"] = step
        event["outcomes"] = result.outcomes
        event["save"] = result.save.traceValue
        trace.emit(event)
        if result.save == .crashed {
            relaunch(reason: "crash")
            return
        }
        actsSinceObserve += 1
        if actsSinceObserve >= persona.observeEvery {
            observe(sort: .groups, query: "")
        }
    }

    // MARK: World faults (SPEC 5.2)

    private func apply(_ fault: MyAppsWorldFault) {
        switch fault {
        case .diskFull:
            let current = (try? Data(contentsOf: glue.mainFileURL).count) ?? 400
            let fraction = 0.2 + rng.nextUnitDouble() * 0.6
            let limit = max(1, Int(Double(max(current, 64)) * fraction))
            glue.armDiskFullOnNextSave(limitBytes: limit)
            trace.emit(["e": "fault.diskFullArmed", "step": step, "limitBytes": limit])
        case .crashBeforeRename:
            glue.armCrashOnNextSave()
            trace.emit(["e": "fault.crashArmed", "step": step, "by": "world"])
        case .truncatedFile, .corruptFile, .versionAhead:
            writeBadFile(fault)
        case .categoryIdsChanged:
            guard world.categories != nil, !world.installed.isEmpty else { return }
            let position = Int(rng.next() % UInt64(world.installed.count))
            var app = world.installed[position]
            let catalogIds = MyAppsSeedData.categoryNames.map(\.0)
            let first = catalogIds[Int(rng.next() % UInt64(catalogIds.count))]
            let second = catalogIds[Int(rng.next() % UInt64(catalogIds.count))]
            app.categoryIds = first == second ? [first] : [first, second]
            world.installed[position] = app
            trace.emit(["e": "world.catalog", "step": step, "appCats": [app.identity: app.categoryIds] as [String: Any], "idx": world.index(app.identity)])
            observe(sort: .groups, query: "")
        case .categoryDropped:
            guard var categories = world.categories else { return }
            let known = Set(categories.map(\.id))
            let candidates = world.installed.compactMap { $0.categoryIds.first(where: known.contains) }
            guard !candidates.isEmpty else { return }
            let dropped = candidates[Int(rng.next() % UInt64(candidates.count))]
            categories.removeAll { $0.id == dropped }
            world.categories = categories
            trace.emit(["e": "world.catalog", "step": step, "categories": categories.map(\.traceObject), "dropped": dropped])
            relaunch(reason: "catalogChangedBetweenLaunches")
        case .updateRenamesPackage:
            guard !world.installed.isEmpty else { return }
            let position = world.installed.firstIndex { $0.identity == MyAppsSeedData.kneecap.identity }
                ?? Int(rng.next() % UInt64(world.installed.count))
            var app = world.installed[position]
            app.originalName = app.originalName.hasSuffix(" Pro") ? "New \(app.originalName)" : "\(app.originalName) Pro"
            world.installed[position] = app
            trace.emit(["e": "world.appUpdated", "step": step, "app": world.index(app.identity), "name": app.originalName])
            observe(sort: .groups, query: "")
        case .appRemovedWhileInFolder:
            let inFolders = Set(glue.arrangement.folders.flatMap(\.apps))
            let candidates = world.installed.filter { inFolders.contains($0.identity) }
            let pool = candidates.isEmpty ? world.installed : candidates
            guard !pool.isEmpty else { return }
            let app = pool[Int(rng.next() % UInt64(pool.count))].identity
            world.remove(app)
            trace.emit(["e": "world.remove", "step": step, "app": world.index(app), "alsoDeleteData": false, "by": "world"])
            observe(sort: .groups, query: "")
            if rng.nextBool(probability: 0.5) { pendingReinstalls.append((step + 2, app)) }
        case .clockSkew:
            world.clock = world.clock.addingTimeInterval(-365 * 24 * 3600)
            trace.emit(["e": "world.clockSkew", "step": step, "seconds": -365 * 24 * 3600])
        }
    }

    private func writeBadFile(_ fault: MyAppsWorldFault) {
        guard let current = try? Data(contentsOf: glue.mainFileURL) else {
            trace.emit(["e": "skip", "step": step, "type": fault.rawValue, "why": "no my-apps.json on disk to damage"])
            return
        }
        let bytes: Data
        switch fault {
        case .truncatedFile:
            bytes = current.prefix(max(1, current.count / 2))
        case .corruptFile:
            bytes = Data("{ \"version\": 1, \"folders\": [ not json, written by MA5's world \(rng.next() % 1000)".utf8)
        default:
            guard var object = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else {
                trace.emit(["e": "skip", "step": step, "type": fault.rawValue, "why": "current file is not a JSON object"])
                return
            }
            object["version"] = 2
            object["futureField"] = ["stickers": ["star", "moon"]]
            bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
        do {
            try bytes.write(to: glue.mainFileURL)
        } catch {
            trace.emit(["e": "harness.error", "step": step, "detail": "world could not write the bad file: \(error)"])
            return
        }
        trace.emit([
            "e": "fault.fileWritten", "step": step, "kind": fault.rawValue,
            "sha": MyAppsFileSnapshotter.sha256(bytes), "z": MyAppsFileSnapshotter.compressedBase64(bytes),
        ])
        relaunch(reason: fault.rawValue)
    }

    // MARK: Relaunch and observation

    private func relaunch(reason: String) {
        let before = snapshotter.snapshot(glue: glue)
        do {
            try glue.relaunch()
        } catch {
            trace.emit(["e": "harness.error", "step": step, "detail": "relaunch failed: \(error)"])
            return
        }
        trace.emit([
            "e": "relaunch", "step": step, "reason": reason, "before": before,
            "notice": glue.noticeShown, "versionTooNew": glue.versionTooNew, "loadMs": glue.lastLoadMilliseconds,
        ])
        observe(sort: .groups, query: "")
    }

    private func screen(sort: MyAppsSort = .groups, query: String = "") -> MyAppsSectionsOutput {
        glue.sections(apps: world.installed, categories: world.categories, needsDownload: world.needsDownload, sort: sort, query: query, now: world.clock).output
    }

    private func observe(sort: MyAppsSort, query: String) {
        actsSinceObserve = 0
        let result = glue.sections(apps: world.installed, categories: world.categories, needsDownload: world.needsDownload, sort: sort, query: query, now: world.clock)
        let names = Dictionary(uniqueKeysWithValues: world.installed.map { ($0.identity, $0.originalName) })
        func rows(_ list: [MyAppsRow]) -> [[Any]] {
            list.map { row in
                let index = world.index(row.identity)
                if names[row.identity] == row.displayName { return [index] }
                return [index, row.displayName]
            }
        }
        let sections: [[String: Any]] = result.output.sections.map { section in
            var object: [String: Any] = ["rows": rows(section.rows)]
            switch section.kind {
            case .allApps:
                object["k"] = "all"
            case let .folder(id, name, collapsed):
                object["k"] = "folder"; object["id"] = id; object["name"] = name; object["collapsed"] = collapsed
            case let .group(categoryId, name, collapsed):
                object["k"] = "group"; object["id"] = categoryId; object["name"] = name; object["collapsed"] = collapsed
            case let .other(collapsed):
                object["k"] = "other"; object["collapsed"] = collapsed
            case .flat:
                object["k"] = "flat"
            }
            return object
        }
        trace.emit([
            "e": "observe", "step": step, "sort": sort.rawValue, "query": query,
            "ms": result.milliseconds, "installed": world.installed.count,
            "out": [
                "sections": sections,
                "recents": result.output.recentlyUsed.map { world.index($0.identity) },
                "showRecents": result.output.showRecentlyUsed,
                "showHeaders": result.output.showGroupHeaders,
                "showSearch": result.output.showSearchField,
                "searching": result.output.isSearching,
            ] as [String: Any],
            "files": snapshotter.snapshot(glue: glue),
            "notice": glue.noticeShown,
        ])
    }

    // MARK: SPEC 3.2 limits measurement (P3 scale test)

    /// Fills the arrangement to the spec's limits: every app renamed to a
    /// 30-character name, every app opened, every app in one of the 40
    /// folders (one folder already holds 300), then relaunches so the load
    /// is timed on the full file.
    private func fillToLimitsAndMeasure() {
        let folderIds = glue.arrangement.folders.map(\.id)
        guard !folderIds.isEmpty else { skip("limitsSetup", "no folders"); return }
        var renames: [[Any]] = []
        var moves: [[Any]] = []
        var opens: [Int] = []
        var actions: [MyAppsAction] = []
        let inFolder = Set(glue.arrangement.folders.flatMap(\.apps))
        var counts = Dictionary(uniqueKeysWithValues: glue.arrangement.folders.map { ($0.id, $0.apps.count) })
        for app in world.installed {
            let index = world.index(app.identity)
            let label = String("Renamed at the limit \(index) xxxxxxxxxxxx".prefix(30))
            renames.append([index, label])
            actions.append(.rename(identity: app.identity, to: label))
        }
        for app in world.installed where !inFolder.contains(app.identity) {
            // SPEC 3.2: 300 apps per folder (the spec's number, not MA1's constant).
            guard let target = folderIds.first(where: { (counts[$0] ?? 0) < 300 }) else { break }
            counts[target, default: 0] += 1
            moves.append([world.index(app.identity), target])
            actions.append(.moveToFolder(identity: app.identity, folderId: target))
        }
        for app in world.installed {
            opens.append(world.index(app.identity))
            world.clock = world.clock.addingTimeInterval(1)
            actions.append(.recordOpened(identity: app.identity, at: glue.stamp(worldNow: world.clock)))
        }
        let result = glue.perform(actions)
        trace.emit([
            "e": "act", "step": step, "type": "limitsSetup", "renames": renames, "moves": moves, "opens": opens,
            "outcomes": result.outcomes, "save": result.save.traceValue,
        ])
        relaunch(reason: "measureAtLimits")
        let bytes = (try? Data(contentsOf: glue.mainFileURL).count) ?? -1
        trace.emit(["e": "measure", "step": step, "fileBytes": bytes, "loadMs": glue.lastLoadMilliseconds, "installed": world.installed.count])
    }
}
