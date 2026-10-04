import XCTest
@testable import MobileUserSimKit

// MA5-persona-sim (SPEC 5.1 to 5.4). Runs the persona simulation against
// MA1's real code, then hands the traces to the independent Python oracle
// (`round3/my-apps-organization/tests/oracle_myapps.py`) and fails on any
// failure the oracle reports that is not a documented, verified finding in
// `tests/known_findings.json`. The Swift side never judges MA1 itself.
//
// `swift test --filter MyApps` runs this file.
final class MyAppsPersonaSimTests: XCTestCase {
    /// SPEC 5.4: every scenario at 3 seeds x 12 runs, all three personas.
    func testSweepAcrossPersonasHasNoUnknownFailures() throws {
        let scratch = try makeScratch("myapps-sweep")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let traces = scratch.appendingPathComponent("traces", isDirectory: true)
        try MyAppsSweep.runAll(workRoot: scratch.appendingPathComponent("work"), traceDir: traces)

        let summaryURL = myAppsOrganizationTestsDirectory().appendingPathComponent("myapps-sweep-results.json")
        let (exitCode, output) = try runOracle(traces: traces, out: summaryURL)
        let summary = try loadJSON(summaryURL)

        XCTAssertEqual(summary["runs"] as? Int, MyAppsPersonaProfile.allCases.count * MyAppsSweep.seeds.count * MyAppsSweep.runsPerSeed,
                       "the oracle must have read one trace per run")
        // The world really misbehaved: every SPEC 5.2 fault landed somewhere
        // in the sweep (a run that silently skipped its faults would pass
        // everything else).
        let exercised = summary["faultsExercised"] as? [String: Int] ?? [:]
        for fault in MyAppsWorldFault.allCases {
            XCTAssertGreaterThan(exercised[fault.rawValue] ?? 0, 0, "the sweep never exercised \(fault.rawValue)")
        }
        XCTAssertEqual(summary["harnessNoteCount"] as? Int, 0, "harness inconsistencies:\n\(output)")
        XCTAssertEqual(exitCode, 0, "the oracle found failures that are not known findings:\n\(output)")
    }

    /// SPEC 5.1 P3 at full scale: 1,000 apps, 40 folders (a 41st refused),
    /// 300 apps in one folder (a 301st refused), a 31-character name
    /// refused, then the arrangement filled to SPEC 3.2's limits and the
    /// file measured and re-read. Fails when any limit slips, when any app
    /// is lost or shown twice at scale, or when the file outgrows the spec.
    func testP3EdgeScaleHoldsEveryLimit() throws {
        let scratch = try makeScratch("myapps-p3-scale")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let traces = scratch.appendingPathComponent("traces", isDirectory: true)
        try MyAppsSweep.runOne(persona: .p3Edge, baseSeed: 20260928, runIndex: 0, workRoot: scratch.appendingPathComponent("work"),
                               traceDir: traces, appCount: 1000, measureAtLimits: true, randomFaults: false, nameSuffix: "-scale")
        let summaryURL = scratch.appendingPathComponent("p3-scale-summary.json")
        let (exitCode, output) = try runOracle(traces: traces, out: summaryURL)
        let summary = try loadJSON(summaryURL)
        let report = (summary["reports"] as? [[String: Any]])?.first ?? [:]
        let coverage = report["coverage"] as? [String: Any] ?? [:]
        let rejections = coverage["expectedRejections"] as? [String: Int] ?? [:]

        // The run reached every edge (counted by the oracle from the
        // person's own actions, not by this harness).
        XCTAssertEqual(coverage["maxFolders"] as? Int, 40)
        XCTAssertEqual(coverage["maxFolderSize"] as? Int, 300)
        XCTAssertGreaterThanOrEqual(rejections["folder-limit"] ?? 0, 1, "the 41st folder was never attempted")
        XCTAssertGreaterThanOrEqual(rejections["folder-full"] ?? 0, 1, "the 301st app was never attempted")
        XCTAssertGreaterThanOrEqual(rejections["name-too-long"] ?? 0, 1, "the 31-character name was never attempted")
        XCTAssertNotNil(report["measure"] as? [String: Any], "the file was never measured at the limits")
        XCTAssertEqual(exitCode, 0, "P3 at scale:\n\(output)")
    }

    /// SPEC 5.4: "exact-seed replay by (scenario, seed, run)". The same
    /// persona, seed and run must replay the same world, the same person,
    /// the same answers from MA1 and the same screens. Timings are dropped,
    /// and so are file hashes and compressed bytes: MA1's JSONEncoder writes
    /// the `apps` object in Swift's per-process hash order, so the bytes
    /// differ between runs while their meaning (and their size) does not.
    func testSameSeedReplaysTheSameRun() throws {
        let scratch = try makeScratch("myapps-replay")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var bodies: [[String]] = []
        for attempt in 0..<2 {
            let url = try MyAppsSweep.runOne(persona: .p2Hurried, baseSeed: 7, runIndex: 5,
                                             workRoot: scratch.appendingPathComponent("work\(attempt)"),
                                             traceDir: scratch.appendingPathComponent("traces\(attempt)"))
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            bodies.append(try lines.map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                let kept = Self.dropping(["ms", "loadMs", "sha", "z"], from: object)
                return String(decoding: try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]), as: UTF8.self)
            })
        }
        XCTAssertGreaterThan(bodies[0].count, 20)
        XCTAssertEqual(bodies[0], bodies[1])
    }

    private static func dropping(_ keys: Set<String>, from value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in dict where !keys.contains(key) { out[key] = dropping(keys, from: inner) }
            return out
        }
        if let list = value as? [Any] { return list.map { dropping(keys, from: $0) } }
        return value
    }

    // MARK: Helpers

    private func makeScratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func runOracle(traces: URL, out: URL) throws -> (Int32, String) {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            myAppsOrganizationTestsDirectory().appendingPathComponent("oracle_myapps.py").path,
            "--traces", traces.path, "--out", out.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// `round3/my-apps-organization/tests/`, from this file's own `#filePath`.
func myAppsOrganizationTestsDirectory() -> URL {
    // iris/mobile-shell/native/tools/iris-mobile-user-sim/Tests/MobileUserSimKitTests/<this file>
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() } // -> iris/
    return url.appendingPathComponent("docs/plans/20260928-all-routes/round3/my-apps-organization/tests", isDirectory: true)
}
