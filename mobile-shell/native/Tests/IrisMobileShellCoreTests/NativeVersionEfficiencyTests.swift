import CryptoKit
import Darwin
import Foundation
import XCTest
import IrisMobileShellCore

// Lower-level NativeVersionStore evidence. No coordinator, rendered UI,
// physical-phone, settled-bookkeeping or exclusive-lock acceptance is implied.
final class NativeVersionEfficiencyTests: XCTestCase {
    private struct Allocation {
        var bytes: Int64 = 0
        var files = 0
        var directories = 0
        var symlinks = 0
    }

    private struct Fixture {
        let root: URL
        let storeRoot: URL
        let sentinel: URL
        let sentinelHash: String
        let store: NativeVersionStore
        let seed: UInt64
        let large: Bool
        let app: String
        let baseFiles: [NativeVersionStagedFile]
        let project = "efficiency-project"

        init(seed: UInt64, large: Bool = false, app: String = "efficiency-app") throws {
            self.seed = seed
            self.large = large
            self.app = app
            baseFiles = (0..<12).map { file in
                let total = large ? 50 * 1_024 * 1_024 : 48 * 1_024
                let count = file == 11 ? total - 11 * 4_096 : 4_096
                return NativeVersionStagedFile(path: file == 0 ? "index.html" : String(format: "file-%02d.bin", file),
                    data: file == 0 ? NativeVersionEfficiencyTests.entrypoint(seed: seed, readsColor: true)
                        : NativeVersionEfficiencyTests.bytes(count: count, seed: seed &+ UInt64(file) &* 7_919),
                    mediaType: file == 0 ? "text/html" : "application/octet-stream")
            }
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-efficiency-" + UUID().uuidString)
            storeRoot = root.appendingPathComponent("version-store")
            sentinel = root.appendingPathComponent("reader-data/sentinel")
            try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = NativeVersionEfficiencyTests.bytes(count: 4_096, seed: seed ^ 0xabcdef)
            sentinelHash = NativeVersionEfficiencyTests.digest(data)
            try data.write(to: sentinel)
            store = try NativeVersionStore(root: storeRoot)
        }

        func revision(_ index: Int) -> String { String(format: "%064x", index + 1) }

        func files(_ index: Int, rename: Bool = false, identical: Bool = false) -> [NativeVersionStagedFile] {
            var result = baseFiles
            result[1] = NativeVersionStagedFile(path: rename ? "renamed.bin" : "file-01.bin",
                data: NativeVersionEfficiencyTests.bytes(count: 4_096,
                    seed: seed &+ 7_919 &+ (identical ? 0 : UInt64(index) &* 104_729)),
                mediaType: "application/octet-stream")
            return result
        }

        @discardableResult
        func add(_ index: Int, rename: Bool = false, identical: Bool = false,
                 activate: Bool = true, fault: NativeVersionFaultInjector = .init()) async throws -> String {
            let input = files(index, rename: rename, identical: identical)
            // Independent input digest, not a store-produced content identity.
            let hash = NativeVersionEfficiencyTests.digest(input.reduce(into: Data()) { data, file in
                data.append(Data(file.path.utf8)); data.append(file.data)
            })
            _ = try await store.stage(appId: app, projectId: project, revisionId: revision(index),
                baseRevisionId: index == 0 ? nil : revision(index - 1), contentHash: hash,
                createdAt: "2026-09-30T12:00:00Z", files: input,
                changes: [.init(title: "Change note color", kind: .added, target: nil)],
                title: "Change note color", fault: fault)
            if activate { _ = try await store.activate(appId: app, projectId: project, revisionId: revision(index)) }
            return hash
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func entrypoint(seed: UInt64, readsColor: Bool) -> Data {
        // A launchable offline Notes fixture, not arbitrary bytes named HTML.
        // The changed binary file represents a stored note color; the rename
        // variant retains the same app code and uses the alternate file path.
        let script = readsColor ? """
        <script>fetch('file-01.bin').then(r=>r.ok?r:fetch('renamed.bin'))
        .then(r=>r.arrayBuffer()).then(b=>{let c=new Uint8Array(b);
        document.getElementById('note').style.backgroundColor=
        'rgb('+c[0]+','+c[1]+','+c[2]+')';});</script>
        """ : ""
        let html = "<!doctype html><html><head><title>Notes</title></head><body><main id='note'>My notes</main>"
            + script + "<!-- fixture seed " + String(format: "%016llx", seed) + " -->"
        let end = "</body></html>"
        return Data((html + String(repeating: " ", count: 4_096 - html.utf8.count - end.utf8.count) + end).utf8)
    }

    private static func bytes(count: Int, seed: UInt64) -> Data {
        // SplitMix64 gives reproducible, poorly compressible distinct content.
        var state = seed
        var result = Data(capacity: count)
        for _ in 0..<(count / 8) {
            state &+= 0x9e3779b97f4a7c15
            var word = state
            word = (word ^ (word >> 30)) &* 0xbf58476d1ce4e5b9
            word = (word ^ (word >> 27)) &* 0x94d049bb133111eb
            word ^= word >> 31
            withUnsafeBytes(of: &word) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func allocation(_ root: URL) throws -> Allocation {
        var result = Allocation()
        var seen = Set<String>()
        func visit(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: "EfficiencyAllocation", code: Int(errno)) }
            guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { return }
            result.bytes += Int64(info.st_blocks) * 512
            switch info.st_mode & S_IFMT {
            case S_IFREG: result.files += 1
            case S_IFLNK: result.symlinks += 1
            case S_IFDIR:
                result.directories += 1
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try visit(child) }
            default: break
            }
        }
        try visit(root)
        return result
    }

    private static func cpuMs() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: "EfficiencyCPU", code: Int(errno)) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }

    // DirectoryEnumerator is synchronous in Swift 6. Keep its traversal out
    // of async methods, then pass immutable URLs to the content checks.
    private static func regularFiles(at root: URL) throws -> [URL] {
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [URL] = []
        for case let file as URL in iterator {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw NSError(domain: "EfficiencyAllocation", code: Int(errno)) }
            if info.st_mode & S_IFMT == S_IFREG { files.append(file) }
        }
        return files
    }

    // Efficiency SPEC 0.1: canonicalize both sides of the relative-path oracle.
    // Mutation: a wrong restored tree still fails exact paths and independent input digests.
    private static func relativePath(_ file: URL, beneath root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve the parent, keeping the file name so an unexpected symlink is not hidden.
        let filePath = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw NSError(domain: "EfficiencyFixtureBoundary", code: 2)
        }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        XCTAssertFalse(relative.hasPrefix("/"), "reconstructed path must be relative")
        XCTAssertFalse(relative.split(separator: "/").contains(".."), "reconstructed path must not escape its root")
        return relative
    }

    private func verify(_ fixture: Fixture, index: Int, rename: Bool = false, identical: Bool = false,
                        store: NativeVersionStore? = nil) async throws {
        let verificationStore = store ?? fixture.store
        let current = try await verificationStore.launchContentRoot(appId: fixture.app, projectId: fixture.project)
        let expected = fixture.files(index, rename: rename, identical: identical)
        var actualPaths = Set<String>()
        for file in try Self.regularFiles(at: current) {
            actualPaths.insert(try Self.relativePath(file, beneath: current))
        }
        XCTAssertEqual(actualPaths, Set(expected.map(\.path)), "exact reconstructed file paths")
        for file in expected {
            XCTAssertEqual(Self.digest(try Data(contentsOf: current.appendingPathComponent(file.path))), Self.digest(file.data), file.path)
        }
        XCTAssertEqual(Self.digest(try Data(contentsOf: fixture.sentinel)), fixture.sentinelHash, "reader data must survive every switch")
    }

    private func storageHistory(large: Bool, depth: Int) async throws -> (maximumGrowth: Int64, maximumFiles: Int, growth: [Int64]) {
        let fixture = try Fixture(seed: 41, large: large)
        let initialInput = fixture.files(0)
        // Measure input allocation on the same filesystem. These files remain
        // outside the version-store oracle and are never counted as history.
        let inputs = fixture.root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        for file in initialInput { try file.data.write(to: inputs.appendingPathComponent(file.path)) }
        let initialCode = try Self.allocation(inputs).bytes
        _ = try await fixture.add(0)
        let initial = try Self.allocation(fixture.storeRoot)
        // H0 is frozen before history grows. On APFS this is only an inode-sum
        // accounting baseline until an outside no-sharing volume is verified.
        let expectedCode = Set(initialInput.map { Self.digest($0.data) })
        var initialCodeInStore: Int64 = 0
        var seenCode = Set<String>()
        for file in try Self.regularFiles(at: fixture.storeRoot) {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw NSError(domain: "EfficiencyAllocation", code: Int(errno)) }
            if info.st_mode & S_IFMT == S_IFREG && seenCode.insert("\(info.st_dev):\(info.st_ino)").inserted,
               expectedCode.contains(Self.digest(try Data(contentsOf: file))) {
                initialCodeInStore += Int64(info.st_blocks) * 512
            }
        }
        // Classify code by independently generated hashes, not object-store paths.
        let fixedOverhead = initial.bytes - initialCodeInStore
        var before = initial
        var maxGrowth: Int64 = 0
        var growthSamples: [Int64] = []
        var maxFiles = 0
        var errors: [String] = []
        let start = DispatchTime.now().uptimeNanoseconds
        let changedInput = inputs.appendingPathComponent("file-01.bin")
        let delta = try Self.allocation(changedInput).bytes
        for index in 1...depth {
            _ = try await fixture.add(index)
            let after = try Self.allocation(fixture.storeRoot)
            let growth = max(0, after.bytes - before.bytes)
            let fileGrowth = after.files - before.files
            growthSamples.append(growth)
            maxGrowth = max(maxGrowth, growth)
            maxFiles = max(maxFiles, fileGrowth)
            // One new unique 4 KiB input object, independent of product counters.
            if index > 1 && fileGrowth > 1 + 8 { errors.append("N=\(index): \(fileGrowth) new regular files exceeds K+8=9") }
            if ProcessInfo.processInfo.environment["IRIS_EFF_NO_SHARING_VERIFIED"] == "1" {
                if growth > delta + 16 * 1_024 { errors.append("N=\(index): growth=\(growth), D+H=\(delta + 16 * 1_024)") }
                if after.bytes > 2 * initialCode + fixedOverhead + Int64(index) * (delta + 16 * 1_024) { errors.append("E4 total-footprint ceiling exceeded at N=\(index)") }
            }
            print("EFF_NATIVE N=\(index) seed=41 inputDigest=\(Self.digest(fixture.files(index)[1].data)) bytesUpperBound=\(after.bytes) growthUpperBound=\(growth) files=\(after.files) dirs=\(after.directories) symlinks=\(after.symlinks)")
            before = after
            if Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 > 180 {
                XCTFail("Depth \(depth) unverified: three-minute workload bound reached at N=\(index)")
                return (maxGrowth, maxFiles, growthSamples)
            }
        }
        // Prove that retention, not deletion, accounts for small growth. Old
        // targets near the beginning, middle and end remain available after restart.
        let restarted = try NativeVersionStore(root: fixture.storeRoot)
        _ = try await restarted.recoverIfNeeded(appId: fixture.app, projectId: fixture.project)
        // Versions SPEC 2.3 step 3: each next target is an ancestor of current.
        for target in [depth - 1, depth / 2, 0] {
            let switched = try await restarted.rollback(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(target))
            XCTAssertTrue(switched)
            try await verify(fixture, index: target, store: restarted)
        }
        // Undo restores the last switch's prior version, then forward activation
        // respects base == current at every step on the way back to the tip.
        let undone = try await restarted.undo(appId: fixture.app, projectId: fixture.project)
        XCTAssertTrue(undone, "Undo returns to the previous ancestor probe")
        try await verify(fixture, index: depth / 2, store: restarted)
        for index in (depth / 2 + 1)...depth {
            let activated = try await restarted.activate(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(index))
            XCTAssertTrue(activated)
        }
        try await verify(fixture, index: depth, store: restarted)
        XCTAssertTrue(errors.isEmpty, errors.prefix(8).joined(separator: "; "))
        print("EFF_NATIVE fixture=\(fixture.root.path) N=\(depth) S=\(initialCode) H0=\(fixedOverhead) physicalSharingProof=unverified")
        return (maxGrowth, maxFiles, growthSamples)
    }

    func testE3SmallAnd50MiBFixedChangedFileHistory() async throws {
        let small = try await storageHistory(large: false, depth: 10)
        let large = try await storageHistory(large: true, depth: 10)
        if ProcessInfo.processInfo.environment["IRIS_EFF_NO_SHARING_VERIFIED"] == "1" {
            XCTAssertEqual(small.growth.count, large.growth.count)
            for (index, pair) in zip(small.growth, large.growth).enumerated() {
                XCTAssertLessThanOrEqual(abs(pair.1 - pair.0), 16 * 1_024,
                                         "N=\(index + 1): same changed file must not grow with unchanged app size")
            }
        }
    }

    func testE3E4PowerUserRetains1000Changes() async throws {
        _ = try await storageHistory(large: false, depth: 1_000)
    }

    func testE3E4IntermediateHistoryDepths() async throws {
        for depth in [100, 300] { _ = try await storageHistory(large: false, depth: depth) }
    }

    func testE3IdenticalContentRenameAndEqualPathsAddNoNewObjects() async throws {
        let fixture = try Fixture(seed: 51)
        _ = try await fixture.add(0)
        // Efficiency SPEC E3: index 1 primes current/fallback, unmeasured here;
        // storageHistory still charges bootstrap in marginal and total byte bounds.
        // Mutation: an extra full file tree after priming still exceeds K+8=8.
        _ = try await fixture.add(1, identical: true)
        try await verify(fixture, index: 1, identical: true)
        var before = try Self.allocation(fixture.storeRoot)
        for (index, rename) in [(2, false), (3, true)] {
            _ = try await fixture.add(index, rename: rename, identical: true)
            let after = try Self.allocation(fixture.storeRoot)
            XCTAssertLessThanOrEqual(after.files - before.files, 8, "no new content has K=0")
            if ProcessInfo.processInfo.environment["IRIS_EFF_NO_SHARING_VERIFIED"] == "1" {
                XCTAssertLessThanOrEqual(max(0, after.bytes - before.bytes), 16 * 1_024)
            }
            try await verify(fixture, index: index, rename: rename, identical: true)
            before = after
        }
        var duplicate = fixture.files(0)
        duplicate.append(.init(path: "same-bytes-another-path.bin", data: duplicate[1].data, mediaType: "application/octet-stream"))
        _ = try await fixture.store.stage(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(4),
            baseRevisionId: fixture.revision(3), contentHash: Self.digest(duplicate.reduce(into: Data()) { $0.append($1.data) }),
            createdAt: "2026-09-30T12:00:00Z", files: duplicate, title: "Equal content path")
        _ = try await fixture.store.activate(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(4))
        let after = try Self.allocation(fixture.storeRoot)
        XCTAssertLessThanOrEqual(after.files - before.files, 8, "duplicate path cannot allocate a new content object")
        if ProcessInfo.processInfo.environment["IRIS_EFF_NO_SHARING_VERIFIED"] == "1" {
            XCTAssertLessThanOrEqual(max(0, after.bytes - before.bytes), 16 * 1_024)
        }
        let current = try await fixture.store.launchContentRoot(appId: fixture.app, projectId: fixture.project)
        let paths = Set(try Self.regularFiles(at: current).map { try Self.relativePath($0, beneath: current) })
        XCTAssertEqual(paths, Set(duplicate.map(\.path)))
        for file in duplicate {
            XCTAssertEqual(Self.digest(try Data(contentsOf: current.appendingPathComponent(file.path))), Self.digest(file.data))
        }
        XCTAssertEqual(Self.digest(try Data(contentsOf: fixture.sentinel)), fixture.sentinelHash)
    }

    func testE5SwitchingCPUAndElapsedAcrossHistoryDepths() async throws {
        var groups: [Int: [Double]] = [:]
        for seed in [UInt64(61), 62, 63] {
            for depth in [10, 100, 300] {
                let fixture = try Fixture(seed: seed)
                for index in 0...depth { _ = try await fixture.add(index) }
                for probe in 0..<13 {
                    let target = probe.isMultiple(of: 2) ? 0 : depth
                    let cpuStart = try Self.cpuMs()
                    let timeStart = DispatchTime.now().uptimeNanoseconds
                    if target == 0 {
                        let switched = try await fixture.store.rollback(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(target))
                        XCTAssertTrue(switched)
                    } else {
                        let undone = try await fixture.store.undo(appId: fixture.app, projectId: fixture.project)
                        XCTAssertTrue(undone, "return to the descendant through Undo")
                    }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - timeStart) / 1e6
                    let cpu = try Self.cpuMs() - cpuStart
                    print("EFF_SWITCH seed=\(seed) depth=\(depth) probe=\(probe) cpuMs=\(cpu) elapsedMs=\(elapsed) warmup=\(probe < 3)")
                    if probe >= 3 {
                        groups[depth, default: []].append(cpu)
                        XCTAssertLessThan(elapsed, 1_000, "module switching budget; no UI/physical-phone credit")
                    }
                    try await verify(fixture, index: target)
                }
            }
        }
        let baseline = try XCTUnwrap(groups[10]).sorted()
        let long = try XCTUnwrap(groups[300]).sorted()
        guard baseline[15] >= 0.01 else { throw XCTSkip("CPU ratio unverified below resolution") }
        XCTAssertLessThanOrEqual((long[14] + long[15]) / (baseline[14] + baseline[15]), 2, "proposed exploratory 300/10 switching CPU ratio")
        XCTAssertLessThanOrEqual(long[28] / baseline[28], 2, "nearest-rank p95 CPU ratio")
        // A 300-depth switching ratio is not the spec's 1,000-depth E1 episode.
    }

    func testE5OneHundredAppsSwitchWithoutTouchingOtherContent() async throws {
        let fixture = try Fixture(seed: 71)
        _ = try await fixture.add(0)
        _ = try await fixture.add(1)
        for app in 0..<99 {
            let input = [NativeVersionStagedFile(path: "index.html", data: Self.entrypoint(seed: UInt64(app + 900), readsColor: false), mediaType: "text/html")]
            _ = try await fixture.store.stage(appId: "other-\(app)", projectId: "project-\(app)", revisionId: fixture.revision(0),
                baseRevisionId: nil, contentHash: Self.digest(input[0].data), createdAt: "2026-09-30T12:00:00Z", files: input)
            _ = try await fixture.store.activate(appId: "other-\(app)", projectId: "project-\(app)", revisionId: fixture.revision(0))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await fixture.store.rollback(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(0))
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, 1_000)
        try await verify(fixture, index: 0)
        for app in [0, 49, 98] {
            let root = try await fixture.store.launchContentRoot(appId: "other-\(app)", projectId: "project-\(app)")
            XCTAssertEqual(Self.digest(try Data(contentsOf: root.appendingPathComponent("index.html"))), Self.digest(Self.entrypoint(seed: UInt64(app + 900), readsColor: false)))
        }
    }

    func testE4E5RollbackUndoRestartPreserveExactContentAndData() async throws {
        let fixture = try Fixture(seed: 81, large: true)
        for index in 0...10 { _ = try await fixture.add(index) }
        for target in [0, 5, 9] {
            _ = try await fixture.store.rollback(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(target))
            try await verify(fixture, index: target)
            let undone = try await fixture.store.undo(appId: fixture.app, projectId: fixture.project)
            XCTAssertTrue(undone)
            try await verify(fixture, index: 10)
            let restarted = try NativeVersionStore(root: fixture.storeRoot)
            _ = try await restarted.recoverIfNeeded(appId: fixture.app, projectId: fixture.project)
            let current = try await restarted.launchContentRoot(appId: fixture.app, projectId: fixture.project)
            XCTAssertEqual(Self.digest(try Data(contentsOf: current.appendingPathComponent("file-01.bin"))), Self.digest(fixture.files(10)[1].data))
        }
    }

    func testE6OSBoundaryPointerInterruptPreservesAnExactVersion() async throws {
        let fixture = try Fixture(seed: 91)
        _ = try await fixture.add(0)
        _ = try await fixture.add(1, activate: false)
        do {
            _ = try await fixture.store.activate(appId: fixture.app, projectId: fixture.project, revisionId: fixture.revision(1),
                fault: .init(point: .journalWrite_afterPointerWrite))
            XCTFail("OS-edge interruption did not fire")
        } catch is NativeVersionSimulatedCrash { }
        let restarted = try NativeVersionStore(root: fixture.storeRoot)
        _ = try await restarted.recoverIfNeeded(appId: fixture.app, projectId: fixture.project)
        let current = try await restarted.launchContentRoot(appId: fixture.app, projectId: fixture.project)
        let actual = Self.digest(try Data(contentsOf: current.appendingPathComponent("file-01.bin")))
        let allowed = Set([Self.digest(fixture.files(0)[1].data), Self.digest(fixture.files(1)[1].data)])
        XCTAssertTrue(allowed.contains(actual), "recovery cannot fabricate a partially written version")
        let recoveredIndex = actual == Self.digest(fixture.files(1)[1].data) ? 1 : 0
        try await verify(fixture, index: recoveredIndex, store: restarted)
        // This injected throw is not a killed-process or accounting-screen audit.
    }

    func testCopyOnlyMutationsKillDuplicateTreeAndWrongRestore() async throws {
        let fixture = try Fixture(seed: 101)
        _ = try await fixture.add(0)
        let current = try await fixture.store.launchContentRoot(appId: fixture.app, projectId: fixture.project)
        let mutant = fixture.root.appendingPathComponent("duplicate-tree-mutant-copy")
        func materializeCopy(at destination: URL) throws {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in fixture.files(0) {
                let source = current.appendingPathComponent(file.path).resolvingSymlinksInPath()
                guard source.path.hasPrefix(fixture.storeRoot.resolvingSymlinksInPath().path + "/") else {
                    throw NSError(domain: "EfficiencyFixtureBoundary", code: 1)
                }
                // Read bytes through the public launch tree, then create fresh
                // regular files. A copied symlink must never reach the original
                // object when the mutation writes to its supposedly copied file.
                try Data(contentsOf: source).write(to: destination.appendingPathComponent(file.path))
            }
        }
        try materializeCopy(at: mutant)
        let before = try Self.allocation(mutant)
        let secondTree = mutant.appendingPathComponent("another-whole-copy")
        try materializeCopy(at: secondTree)
        let after = try Self.allocation(mutant)
        XCTAssertGreaterThan(after.files - before.files, 8, "K=0 duplicate-tree mutant must violate structural gate")
        try Data("corrupt restored file".utf8).write(to: secondTree.appendingPathComponent("file-01.bin"))
        XCTAssertNotEqual(Self.digest(try Data(contentsOf: secondTree.appendingPathComponent("file-01.bin"))), Self.digest(fixture.files(0)[1].data))
        XCTAssertEqual(Self.digest(try Data(contentsOf: current.appendingPathComponent("file-01.bin"))), Self.digest(fixture.files(0)[1].data), "original product output was not mutated")
    }
}
