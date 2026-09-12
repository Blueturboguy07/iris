import Foundation
import Testing
@testable import IrisUsability

struct DeliveredEditUndoSourceTests {
    @Test func restoresCleanCheckoutAndPreservesLaterEditBranchCommits() throws {
        try withFixture { fixture in
            try fixture.git(["commit", "--allow-empty", "-m", "later reader work"])
            let laterCommit = try fixture.git(["rev-parse", "HEAD"])
            #expect(try fixture.restore() == 0)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == fixture.originalCommit)
            #expect(try fixture.git(["rev-parse", "edit"]) == laterCommit)
            #expect(try String(contentsOf: fixture.root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "original")
        }
    }

    @Test(arguments: ["tracked.txt", "untracked.txt"])
    func refusesDirtyTreeWithoutChangingBytes(path: String) throws {
        try withFixture { fixture in
            let file = fixture.root.appendingPathComponent(path)
            let bytes = Data([0, 1, 255, 65])
            try bytes.write(to: file)
            let before = try fixture.git(["rev-parse", "HEAD"])
            #expect(try fixture.restore() != 0)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == before)
        }
    }

    @Test func refusesOriginalRefThatMovedWithoutChangingCheckout() throws {
        try withFixture { fixture in
            let before = try fixture.git(["rev-parse", "HEAD"])
            try fixture.git(["update-ref", "refs/heads/" + fixture.originalRef, before])
            #expect(try fixture.restore() != 0)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == before)
        }
    }

    @Test(arguments: [false, true])
    func refusesMissingRefOrCommit(missingCommit: Bool) throws {
        try withFixture { fixture in
            let before = try fixture.git(["rev-parse", "HEAD"])
            let result = try fixture.restore(
                reference: missingCommit ? "HEAD" : "missing-ref",
                commit: missingCommit ? String(repeating: "0", count: 40) : fixture.originalCommit
            )
            #expect(result != 0)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == before)
        }
    }

    @Test func restoresDetachedOriginalCommit() throws {
        try withFixture { fixture in
            let status = try fixture.restore(reference: "HEAD")
            #expect(status == 0)
            #expect(try fixture.git(["rev-parse", "HEAD"]) == fixture.originalCommit)
            #expect(try fixture.git(["rev-parse", "edit"]) != fixture.originalCommit)
        }
    }

    private func withFixture(_ body: (SourceFixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-undo-'quoted space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try SourceFixture(root: root)
        try body(fixture)
    }
}

private final class SourceFixture {
    let root: URL
    // Apostrophes and shell metacharacters are valid git ref bytes and must stay literal.
    let originalRef = "original'$(false);literal"
    var originalCommit = ""

    init(root: URL) throws {
        self.root = root
        try git(["init", "--quiet"])
        try git(["config", "user.name", "Undo Fixture"])
        try git(["config", "user.email", "undo-fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["checkout", "-b", originalRef])
        try Data("original".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"])
        try git(["commit", "-m", "original"])
        originalCommit = try git(["rev-parse", "HEAD"])
        try git(["checkout", "-b", "edit"])
        try Data("edited".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(["commit", "-am", "edit"])
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try run("/usr/bin/git", arguments)
        guard result.status == 0 else { throw FixtureError.commandFailed(result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restore(reference: String? = nil, commit: String? = nil) throws -> Int32 {
        let command = DeliveredEditUndoRecovery.sourceRestoreCommand(
            originalHeadRef: reference ?? originalRef, originalCommit: commit ?? originalCommit
        )
        return try run("/bin/zsh", ["-f", "-c", command]).status
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": "/dev/null"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    private enum FixtureError: Error { case commandFailed(String) }
}
