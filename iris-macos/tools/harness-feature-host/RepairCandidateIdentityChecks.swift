import Darwin
import Foundation
@testable import IrisHarnessNative

@main
struct RepairCandidateIdentityChecks {
    enum Failure: Error { case check(String) }

    @MainActor
    static func main() async throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("iris-repair-identity-" + UUID().uuidString)
        let work = root.appendingPathComponent("work")
        let scratch = root.appendingPathComponent("scratch")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let previousScratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"]
        setenv("IRIS_HARNESS_SCRATCH", scratch.path, 1)
        defer {
            if let previousScratch { setenv("IRIS_HARNESS_SCRATCH", previousScratch, 1) }
            else { unsetenv("IRIS_HARNESS_SCRATCH") }
        }
        let source = work.appendingPathComponent("value.bin")
        try Data([0, 1, 2, 3]).write(to: source)
        let runner = try MaintainShellRunner(repoRootPath: work.path)
        func command(_ text: String) async throws {
            let result = try await runner.run(text, deadline: 10)
            guard result.succeeded else { throw Failure.check("fixture command: " + text) }
        }
        func identity() async throws -> String {
            let indexURL = work.appendingPathComponent(".git/index")
            let before = try Data(contentsOf: indexURL)
            guard let value = await MaintainTierCFixer.repairCandidateIdentity(
                runner: runner, repoRootPath: work.path) else { throw Failure.check("missing identity") }
            guard try Data(contentsOf: indexURL) == before else {
                throw Failure.check("identity collection changed the real index")
            }
            return value
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure.check(message) }
        }
        try await command("git init -q -b main && git add value.bin && git -c user.name=Fixture -c user.email=fixture@example.invalid commit --no-gpg-sign -qm baseline")
        let baseline = try await identity()
        try require(try await identity() == baseline, "unchanged content changed identity")
        let timestamp = try files.attributesOfItem(atPath: source.path)[.modificationDate]
        try Data([0, 9, 2, 3]).write(to: source)
        if let timestamp { try files.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path) }
        try require(try await identity() != baseline, "same-size binary change with restored timestamp was missed")
        try Data([0, 1, 2, 3]).write(to: source)
        try require(try await identity() == baseline, "restored content did not restore identity")
        let untracked = work.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: untracked)
        try require(try await identity() != baseline, "untracked source was omitted")
        try files.removeItem(at: untracked)
        try await command("git switch -qc second")
        try require(try await identity() != baseline, "another branch at the same commit was accepted")
        try await command("git switch -q main")
        try require(try await identity() == baseline, "original branch did not match")
        let leftovers = try files.contentsOfDirectory(atPath: work.appendingPathComponent(".git").path)
            .filter { $0.hasPrefix("iris-repair-identity-") }
        try require(leftovers.isEmpty, "private index files were left behind")
        print("PASS repair identity: unchanged, binary with preserved metadata, untracked source, branch identity, real index and private-index cleanup")
    }
}
