import Foundation
import IrisMobileShellCore

private struct StaticAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "RevisionStorageBenchmark", code: 1)
    }
    return value
}

private func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else {
        throw NSError(
            domain: "RevisionStorageBenchmark",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "missing \(key)"]
        )
    }
    return value
}

private func nullable(_ object: [String: Any], _ key: String) throws -> String? {
    if object[key] is NSNull { return nil }
    return try string(object, key)
}

private func authority(for packageBytes: Data) throws -> StaticAuthority {
    let root = try object(packageBytes)
    guard let approval = root["approval"] as? [String: Any] else {
        throw NSError(domain: "RevisionStorageBenchmark", code: 3)
    }
    return StaticAuthority(approval: TrustedDeliveryApproval(
        approvalId: try string(approval, "approvalId"),
        requestId: try nullable(approval, "requestId"),
        requestNonce: try nullable(approval, "requestNonce"),
        appId: try string(approval, "appId"),
        projectId: try string(approval, "projectId"),
        baseRevisionId: try nullable(approval, "baseRevisionId"),
        approvedRevisionId: try string(approval, "approvedRevisionId"),
        approvedContentHash: try string(approval, "approvedContentHash"),
        approvedAt: try string(approval, "approvedAt")
    ))
}

private func nanos(_ body: () async throws -> Void) async rethrows -> UInt64 {
    let clock = ContinuousClock()
    let start = clock.now
    try await body()
    let duration = start.duration(to: clock.now).components
    return UInt64(max(0, duration.seconds)) * 1_000_000_000
        + UInt64(max(0, duration.attoseconds / 1_000_000_000))
}

/// Generates one real, validator-accepted `.irisapp` package by shelling
/// out to the same desktop-CLI-backed generator the Core test suites use
/// (`Tests/Fixtures/generate-desktop-package.mjs`), so `multi-app` mode
/// needs no separately-prepared fixture directory: it builds its own
/// synthetic store from scratch, matching SPEC.md R8.10's own words
/// ("measured in SwiftPM with a synthetic store").
private func generatePackage(
    generatorScript: URL, outputDir: URL, appId: String, projectId: String,
    content: String, baseRevisionId: String?, nonce: String
) throws -> (bytes: Data, authority: StaticAuthority, revisionId: String) {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let html = "<!doctype html><meta charset=utf-8><title>Multi-app scale</title><main>\(content)</main>"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "node", generatorScript.path,
        "--output", outputDir.path,
        "--base", baseRevisionId ?? "null",
        "--content", html,
        "--nonce", nonce,
        "--namespace", appId,
        "--capabilities", "[]",
        "--app", appId,
        "--project", projectId,
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "RevisionStorageBenchmark", code: 5, userInfo: [
            NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "generator failed",
        ])
    }
    let result = try object(outputData)
    let packagePath = try string(result, "packagePath")
    let approvalPath = try string(result, "trustedApprovalPath")
    let revisionId = try string(result, "revisionId")
    let approvalRoot = try object(try Data(contentsOf: URL(fileURLWithPath: approvalPath)))
    let approval = TrustedDeliveryApproval(
        approvalId: try string(approvalRoot, "approvalId"),
        requestId: try nullable(approvalRoot, "requestId"),
        requestNonce: try nullable(approvalRoot, "requestNonce"),
        appId: try string(approvalRoot, "appId"),
        projectId: try string(approvalRoot, "projectId"),
        baseRevisionId: try nullable(approvalRoot, "baseRevisionId"),
        approvedRevisionId: try string(approvalRoot, "approvedRevisionId"),
        approvedContentHash: try string(approvalRoot, "approvedContentHash"),
        approvedAt: try string(approvalRoot, "approvedAt")
    )
    return (
        bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
        authority: StaticAuthority(approval: approval),
        revisionId: revisionId
    )
}

/// `multi-app APP_COUNT REVISIONS_PER_APP STORE_ROOT`: builds a synthetic
/// store of `APP_COUNT` installed apps, each with `REVISIONS_PER_APP`
/// activated revisions (real staged/activated revisions, not a mock), then
/// times `NativeShellLibraryCoordinator.globalStorageUsage()`, exactly the
/// call the Host's Library/Storage screens make and the same read this
/// unit's brief item 3 (and SPEC.md R8.10) asks be under 500 ms at 100
/// apps x 5 revisions. Also reports the global cap plan's timing (brief
/// item 1) against the same store.
private func runMultiAppMode() async throws {
    guard CommandLine.arguments.count == 5,
          let appCount = Int(CommandLine.arguments[2]), appCount > 0,
          let revisionsPerApp = Int(CommandLine.arguments[3]), revisionsPerApp > 0 else {
        fputs("usage: RevisionStorageBenchmark multi-app APP_COUNT REVISIONS_PER_APP STORE_ROOT\n", stderr)
        exit(2)
    }
    let storeRoot = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
    try? FileManager.default.removeItem(at: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let scratchRoot = storeRoot.deletingLastPathComponent().appendingPathComponent("multi-app-scratch", isDirectory: true)
    try? FileManager.default.removeItem(at: scratchRoot)
    try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    // #filePath: .../mobile-shell/native/Tools/revision-storage-benchmark/
    //            Sources/RevisionStorageBenchmark/main.swift; five
    //            `deletingLastPathComponent()` calls land on .../native/.
    let generatorScript = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/generate-desktop-package.mjs")

    let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
    var packageIndex = 0
    let generationClock = ContinuousClock()
    let generationStart = generationClock.now
    for appIndex in 0..<appCount {
        let appId = "iris.bench-multi-app-\(appIndex)"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try NativeRevisionStore(
            rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0"
        )
        var baseRevisionId: String?
        var revisionIds: [String] = []
        // The coordinator prunes after every activate (current, previous,
        // pending, up to 2 pinned; SPEC R8.9). To reach the largest shape
        // the rule allows, the two oldest versions are pinned before the
        // update that would prune them and the last one is staged on top of
        // current but not activated (pending). R2-mobile-integration.
        for revisionIndex in 0..<revisionsPerApp {
            packageIndex += 1
            let outputDir = scratchRoot.appendingPathComponent("pkg-\(packageIndex)", isDirectory: true)
            let nonce = String(format: "%064x", packageIndex)
            let generated = try generatePackage(
                generatorScript: generatorScript, outputDir: outputDir,
                appId: appId, projectId: projectId, content: "r\(revisionIndex)",
                baseRevisionId: baseRevisionId, nonce: nonce
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            revisionIds.append(generated.revisionId)
            baseRevisionId = generated.revisionId
            if revisionsPerApp > 1, revisionIndex == revisionsPerApp - 1 { break }
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            if revisionIndex >= 1, revisionIndex <= NativeStorageRetentionPolicy.pinLimit {
                try await coordinator.pin(identity: identity, revisionId: revisionIds[revisionIndex - 1])
            }
        }
    }
    let generationNanos = generationStart.duration(to: generationClock.now)

    func millis(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    let clock = ContinuousClock()
    let usageStart = clock.now
    let usage = try await coordinator.globalStorageUsage()
    let usageMillis = millis(usageStart.duration(to: clock.now))

    let planStart = clock.now
    let plan = try await coordinator.planGlobalCapEnforcement(capBytes: 1)
    let planMillis = millis(planStart.duration(to: clock.now))

    let result: [String: Any] = [
        "mode": "multi-app",
        "appCount": appCount,
        "revisionsPerApp": revisionsPerApp,
        "generationMillis": millis(generationNanos),
        "globalStorageUsageMillis": usageMillis,
        "planGlobalCapEnforcementMillis": planMillis,
        "perAppCount": usage.perApp.count,
        "storedRevisionsTotal": usage.perApp.reduce(0) { $0 + $1.storedRevisionCount },
        "totalCodeBytes": usage.totalCodeBytes,
        "planReclaimableBytes": plan.reclaimableBytes,
    ]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// `measure-existing STORE_ROOT`: times the Library/Storage read (and the
/// global cap plan) again on a store an earlier `multi-app` run left behind,
/// without rebuilding it (R2-mobile-integration; building 500 versions takes
/// about two minutes, the read itself about a second or less). Read-only.
private func runMeasureExistingMode() async throws {
    guard CommandLine.arguments.count == 3 else {
        fputs("usage: RevisionStorageBenchmark measure-existing STORE_ROOT\n", stderr)
        exit(2)
    }
    let storeRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
    let clock = ContinuousClock()
    func millis(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
    var runs: [Double] = []
    var usage: NativeStorageGlobalUsage?
    let iterations = Int(ProcessInfo.processInfo.environment["IRIS_BENCH_RUNS"] ?? "") ?? 3
    for _ in 0..<max(1, iterations) {
        let start = clock.now
        usage = try await coordinator.globalStorageUsage()
        runs.append(millis(start.duration(to: clock.now)))
    }
    let result: [String: Any] = [
        "mode": "measure-existing",
        "globalStorageUsageMillisRuns": runs,
        "perAppCount": usage?.perApp.count ?? 0,
        "storedRevisionsTotal": usage?.perApp.reduce(0) { $0 + $1.storedRevisionCount } ?? 0,
        "totalCodeBytes": usage?.totalCodeBytes ?? 0,
    ]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// `scale-table [STORE_ROOT]`: MV5's brief item "extend revision-storage-
/// benchmark with the SPEC scale table (3, 100, 1,000 apps x 1, 10, 50
/// versions) so a regression in bytes, refresh time or GC time fails".
///
/// Runs a subset of SPEC.md section 3.1's (apps x versions) cells against
/// TODAY's real store (`NativeRevisionStore`/`NativeShellLibraryCoordinator`,
/// the pre-MV1/MV2 full-copy layout: MV1 exists as a standalone module but
/// is "not wired into the running app" per its own handoff, MV2 is the unit
/// that wires it), so this mode can only regression-check the "Full
/// copies" column (A x V x S) today; the phase 1/2/3 columns need MV2's
/// content-addressed store to be live here and are covered independently,
/// against the real measurements, by ../../../docs/plans/20260928-all-
/// routes/round3/mobile-versions/tests/scale_table_check.py in the
/// meantime (see that file's docstring). Once MV2 lands, this mode should
/// switch its generation to the new store and start checking phase 1
/// directly; that swap is listed in HANDOFF.md's "what remains".
///
/// CELLS below is deliberately smaller than the SPEC's full 3x3 grid
/// (drops the 1,000-app and the 100x50/1,000x* rows): those cells take on
/// the order of `versions * ~0.24s` per app to generate with today's
/// subprocess-per-revision generator (500 versions measured at about two
/// minutes elsewhere in this codebase), so 1,000 apps x 50 versions would
/// be tens of thousands of subprocess calls and not finish inside one
/// heavy-lock slot's reasonable turn. Run the dropped cells with
/// `IRIS_BENCH_SCALE_TABLE_FULL=1` (still through the heavy lock, and
/// expect it to take a long time; split it across background runs).
private struct ScaleTableCell { let apps: Int; let versions: Int }

private let ScaleTableCellsReduced: [ScaleTableCell] = [
    ScaleTableCell(apps: 3, versions: 1), ScaleTableCell(apps: 3, versions: 10), ScaleTableCell(apps: 3, versions: 50),
    ScaleTableCell(apps: 100, versions: 1), ScaleTableCell(apps: 100, versions: 10),
]
private let ScaleTableCellsFull: [ScaleTableCell] = ScaleTableCellsReduced + [
    ScaleTableCell(apps: 100, versions: 50),
    ScaleTableCell(apps: 1000, versions: 1), ScaleTableCell(apps: 1000, versions: 10), ScaleTableCell(apps: 1000, versions: 50),
]

/// S = 19.2 MB, independently measured (see scale_table_check.py); a 15
/// percent band around A*V*S is "no regression" for today's full-copy
/// layout, since real per-app sizes vary (Kneecap/FreeHarmony/NutAI are not
/// literally 19.2 MB each, only their average is).
private let MeasuredSBytes: Double = 19_200_000

private func runScaleTableMode() async throws {
    let full = ProcessInfo.processInfo.environment["IRIS_BENCH_SCALE_TABLE_FULL"] == "1"
    let cells = full ? ScaleTableCellsFull : ScaleTableCellsReduced
    let outRootArg = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil
    let outRoot = URL(fileURLWithPath: outRootArg ?? NSTemporaryDirectory() + "iris-scale-table-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

    var rows: [[String: Any]] = []
    var anyRegression = false
    for cell in cells {
        let storeRoot = outRoot.appendingPathComponent("store-\(cell.apps)x\(cell.versions)", isDirectory: true)
        let scratchRoot = outRoot.appendingPathComponent("scratch-\(cell.apps)x\(cell.versions)", isDirectory: true)
        try? FileManager.default.removeItem(at: storeRoot)
        try? FileManager.default.removeItem(at: scratchRoot)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let generatorScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/generate-desktop-package.mjs")

        let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
        var packageIndex = 0
        let clock = ContinuousClock()
        let genStart = clock.now
        for appIndex in 0..<cell.apps {
            let appId = "iris.scale-table-\(cell.apps)x\(cell.versions)-\(appIndex)"
            let projectId = "\(appId).mobile"
            let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
            let store = try NativeRevisionStore(rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0")
            var baseRevisionId: String?
            for revisionIndex in 0..<cell.versions {
                packageIndex += 1
                let outputDir = scratchRoot.appendingPathComponent("pkg-\(packageIndex)", isDirectory: true)
                let nonce = String(format: "%064x", packageIndex)
                let generated = try generatePackage(
                    generatorScript: generatorScript, outputDir: outputDir,
                    appId: appId, projectId: projectId, content: "r\(revisionIndex)",
                    baseRevisionId: baseRevisionId, nonce: nonce
                )
                _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
                try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
                baseRevisionId = generated.revisionId
            }
        }
        let genMillis = Double(genStart.duration(to: clock.now).components.seconds) * 1000

        let usageStart = clock.now
        let usage = try await coordinator.globalStorageUsage()
        let usageMillis = Double(usageStart.duration(to: clock.now).components.seconds) * 1000
            + Double(usageStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000

        let expectedFullCopies = Double(cell.apps) * Double(cell.versions) * MeasuredSBytes
        let actualBytes = Double(usage.totalCodeBytes)
        let ratio = actualBytes / max(1, expectedFullCopies)
        // Today's layout is full copies with APFS clone sharing for
        // adjacent chains (SPEC section 0), so actual bytes can legitimately
        // be well BELOW the naive A*V*S estimate; only flag a regression
        // when it is unexpectedly ABOVE (more bytes than "everything is a
        // separate full copy" would predict, which should never happen) or
        // dramatically below (near zero, suggesting the measurement broke).
        let regressed = ratio > 1.15 || actualBytes < expectedFullCopies * 0.01
        if regressed { anyRegression = true }
        let refreshBudgetMillis = 500.0  // SPEC 3.2, R8.10
        let refreshRegressed = usageMillis > refreshBudgetMillis && cell.apps <= 100 && cell.versions <= 10
        if refreshRegressed { anyRegression = true }

        rows.append([
            "apps": cell.apps, "versions": cell.versions,
            "generationMillis": genMillis, "globalStorageUsageMillis": usageMillis,
            "actualTotalCodeBytes": usage.totalCodeBytes, "expectedFullCopiesBytes": expectedFullCopies,
            "ratioActualToExpectedFullCopies": ratio,
            "bytesRegressed": regressed, "refreshRegressed": refreshRegressed,
        ])
        FileHandle.standardError.write(Data(
            "[scale-table] \(cell.apps)x\(cell.versions): actual=\(Int(actualBytes)) expectedFull=\(Int(expectedFullCopies)) "
            + "ratio=\(String(format: "%.2f", ratio)) refreshMs=\(String(format: "%.0f", usageMillis)) "
            + "regressed=\(regressed || refreshRegressed)\n".utf8
        ))
    }

    let report: [String: Any] = [
        "schemaVersion": 1, "full": full, "measuredSBytes": MeasuredSBytes,
        "note": "checks the Full-copies column only (today's pre-MV2 store); "
            + "phase 1/2/3 are checked independently by scale_table_check.py",
        "rows": rows, "anyRegression": anyRegression,
    ]
    let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if anyRegression {
        exit(1)
    }
}

@main
struct Main {
    static func main() async throws {
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "multi-app" {
            try await runMultiAppMode()
            return
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "measure-existing" {
            try await runMeasureExistingMode()
            return
        }
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "scale-table" {
            try await runScaleTableMode()
            return
        }
        guard CommandLine.arguments.count == 4,
              let count = Int(CommandLine.arguments[1]),
              count > 0 else {
            fputs("usage: RevisionStorageBenchmark COUNT PACKAGE_DIR STORE_ROOT\n", stderr)
            fputs("   or: RevisionStorageBenchmark multi-app APP_COUNT REVISIONS_PER_APP STORE_ROOT\n", stderr)
            exit(2)
        }
        let packageRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let storeRoot = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try? FileManager.default.removeItem(at: storeRoot)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let store = try NativeRevisionStore(
            rootURL: storeRoot,
            appId: "publik.lunara",
            projectId: "publik.lunara.mobile",
            shellVersion: "1.0.0",
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.storage"])
        )

        var revisions: [String] = []
        var stageNanos: UInt64 = 0
        for index in 1...count {
            let packageURL = packageRoot.appendingPathComponent(
                String(format: "lunara-%02d.irisapp", index)
            )
            let bytes = try Data(contentsOf: packageURL)
            let approvalAuthority = try authority(for: bytes)
            var receipt: StagedRevisionReceipt?
            stageNanos += try await nanos {
                receipt = try await store.stage(
                    packageBytes: bytes,
                    approvalAuthority: approvalAuthority
                )
            }
            guard let revisionId = receipt?.revisionId else {
                throw NSError(domain: "RevisionStorageBenchmark", code: 4)
            }
            try await store.activate(revisionId: revisionId)
            revisions.append(revisionId)
        }

        var summaryCount = 0
        let listNanos = try await nanos {
            summaryCount = try await store.revisionSummaries().count
        }
        var openedRevision = ""
        let openNanos = try await nanos {
            openedRevision = try await store.launchDescriptorForActiveRevision().revisionId
        }
        let revertNanos = try await nanos {
            try await store.rollback(to: revisions[0])
        }

        let result: [String: Any] = [
            "count": count,
            "stageNanos": stageNanos,
            "stageMeanNanos": stageNanos / UInt64(count),
            "listNanos": listNanos,
            "openNanos": openNanos,
            "revertNanos": revertNanos,
            "summaryCount": summaryCount,
            "openedRevision": openedRevision,
            "revertedRevision": try await store.activeRevisionId() as Any,
            "firstRevision": revisions[0],
            "lastRevision": revisions[count - 1],
        ]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
