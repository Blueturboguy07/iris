import Foundation
@testable import IrisHarnessNative

private nonisolated final class HookCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Disposable boundary checks for the unverified Iris Test candidate lane.
/// Every Git checkout and app bundle lives below a UUID-scoped temporary root;
/// this executable never reads the normal profile or touches an installed app.
@main
struct CandidateBoundaryChecks {
    private struct CheckFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func main() async {
        do {
            try await checkExpectedParentIdentity()
            print("PASS candidate identity requires the reviewed commit's exact parent")
            try await checkRestoreHookBoundary()
            print("PASS restore hook refusal leaves the temporary bundle untouched")
            print("CANDIDATE BOUNDARY CHECKS PASS: 2 groups; disposable Git and bundle fixtures only")
        } catch {
            print("CANDIDATE BOUNDARY CHECKS STOPPED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func checkExpectedParentIdentity() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("iris-candidate-boundary-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try files.createDirectory(at: clone, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        try git(["init"], at: clone)
        try git(["config", "user.email", "fixture@example.invalid"], at: clone)
        try git(["config", "user.name", "Candidate Boundary Fixture"], at: clone)
        try git(["config", "commit.gpgSign", "false"], at: clone)
        let source = clone.appendingPathComponent("source.txt")
        try Data("base source\n".utf8).write(to: source)
        try git(["add", "source.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "base"], at: clone)
        let originalHeadCommit = try git(["rev-parse", "HEAD"], at: clone)
        try git(["branch", "-M", "main"], at: clone)

        try git(["checkout", "-b", "iris-edit"], at: clone)
        try Data("edited source\n".utf8).write(to: source)
        try git(["add", "source.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "candidate edit"], at: clone)
        let reviewedCommit = try git(["rev-parse", "HEAD"], at: clone)
        let reviewedPatch = try git(["diff", "HEAD^", "HEAD", "--", "source.txt"], at: clone)
        let reviewedIdentity = SavedEditDeliveryIdentity(
            clonePath: clone.path, branchName: "iris-edit", commit: reviewedCommit)
        try require(await reviewedIdentity.hasParentCommit(originalHeadCommit),
                    "a clean candidate directly based on the reviewed head was refused")

        // Make a newer base commit that changes an unrelated file, then apply
        // the same source-file edit. The patch is identical, but its parent is
        // no longer the source commit captured when the candidate was reviewed.
        try git(["checkout", "main"], at: clone)
        try Data("unrelated newer base\n".utf8).write(to: clone.appendingPathComponent("unrelated.txt"))
        try git(["add", "unrelated.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "newer base"], at: clone)
        let newerBaseCommit = try git(["rev-parse", "HEAD"], at: clone)
        try git(["checkout", "-b", "iris-edit-newer-base"], at: clone)
        try Data("edited source\n".utf8).write(to: source)
        try git(["add", "source.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "same candidate diff"], at: clone)
        let newerCandidateCommit = try git(["rev-parse", "HEAD"], at: clone)
        let newerPatch = try git(["diff", "HEAD^", "HEAD", "--", "source.txt"], at: clone)
        try require(reviewedPatch == newerPatch, "newer-base fixture did not preserve the same source diff")
        try require(newerBaseCommit != originalHeadCommit, "newer-base fixture did not advance the source base")
        let newerIdentity = SavedEditDeliveryIdentity(
            clonePath: clone.path, branchName: "iris-edit-newer-base", commit: newerCandidateCommit)
        try require(await newerIdentity.hasParentCommit(originalHeadCommit) == false,
                    "same diff on a newer base was accepted as the reviewed candidate")
    }

    @MainActor
    private static func checkRestoreHookBoundary() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("iris-candidate-restore-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let installed = root.appendingPathComponent("installed/Boundary.app", isDirectory: true)
        let backup = root.appendingPathComponent("backup/Boundary.app", isDirectory: true)
        let identifier = "com.publikhq.iris.test.boundary.\(UUID().uuidString.lowercased())"
        try makeBundle(installed, identifier: identifier, payload: "current installed\n")
        try makeBundle(backup, identifier: identifier, payload: "previous saved\n")
        let store = AppDeliveryReceiptStore(baseDirectory: root.appendingPathComponent("receipts"))
        let service = AppRelaunchService(deliveryReceiptStore: store)
        let hookCalls = HookCallCounter()
        defer { try? files.removeItem(at: root) }

        let refused = await service.restoreInstalledAppFromBackup(
            installedPath: installed.path, backupPath: backup.path
        ) {
            hookCalls.next() == 1
        }
        try require(!refused, "restore hook refusal was reported as a restore")
        try require(hookCalls.calls == 2,
                    "restore hook was not checked both before and immediately before replacement")
        try require(try payload(in: installed) == "current installed\n",
                    "restore hook refusal changed the installed temporary bundle")
        try require(files.fileExists(atPath: backup.path), "restore hook refusal consumed the backup")

        let restored = await service.restoreInstalledAppFromBackup(
            installedPath: installed.path, backupPath: backup.path
        ) { true }
        try require(restored, "allowed restore did not replace the temporary bundle")
        try require(try payload(in: installed) == "previous saved\n",
                    "allowed restore did not expose the saved bundle payload")
    }

    private static func makeBundle(_ path: URL, identifier: String, payload: String) throws {
        let contents = path.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Boundary",
            "CFBundleExecutable": "Boundary",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(payload.utf8).write(to: contents.appendingPathComponent("Payload.bin"))
    }

    private static func payload(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/Payload.bin"), encoding: .utf8)
    }

    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CheckFailure(message: "git \(arguments.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }
    }
}
