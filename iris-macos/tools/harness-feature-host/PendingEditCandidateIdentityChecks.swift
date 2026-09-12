import Foundation
@testable import IrisHarnessNative

/// Disposable checks for the identity of an uncommitted, review-held Test
/// candidate. The fixture never consults the normal registry or a real app.
@main
struct PendingEditCandidateIdentityChecks {
    private struct CheckFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func main() async {
        do {
            try await runChecks()
            print("PENDING EDIT CANDIDATE IDENTITY CHECKS PASS: 1 group; disposable Git fixture only")
        } catch {
            print("PENDING EDIT CANDIDATE IDENTITY CHECKS STOPPED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func runChecks() async throws {
        let files = FileManager.default
        let fixtureBase = files.temporaryDirectory
            .appendingPathComponent("iris-pending-candidate-parent-\(UUID().uuidString)", isDirectory: true)
        let fixture = fixtureBase
            .appendingPathComponent("iris-pending-candidate-\(UUID().uuidString)", isDirectory: true)
        let clone = fixture.appendingPathComponent("clone", isDirectory: true)
        let scratch = fixture.appendingPathComponent("scratch", isDirectory: true)
        let application = fixture.appendingPathComponent("Fixture.app", isDirectory: true)
        let artifact = clone.appendingPathComponent("build/Fixture.app", isDirectory: true)
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        try files.createDirectory(at: clone, withIntermediateDirectories: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        try files.createDirectory(at: application, withIntermediateDirectories: true)
        try files.createDirectory(at: artifact, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixture) }

        let canonicalClone = MaintainSandbox.canonicalPath(clone.path)
        let policy = MaintainSandbox.testProcessPolicy(
            scratchDirectoryPath: MaintainSandbox.canonicalPath(scratch.path),
            additionalReadOnlyPaths: [
                "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                "/private/var/db", "/private/var/select", "/opt/homebrew",
                "/usr/local", "/Library/Developer", "/Applications/Xcode.app", "/dev"
            ],
            repositoryIsRegistered: { $0 == canonicalClone }
        )
        let runner = try MaintainShellRunner(repoRootPath: canonicalClone, processPolicy: policy)
        try require(runner.isTestProcessPolicy, "fixture runner did not use Test policy")

        func command(_ text: String) async throws {
            let result = try await runner.run(text, deadline: 30)
            guard result.succeeded else {
                throw CheckFailure(message: "fixture command failed (\(result.exitCode)): \(result.outputTail)")
            }
        }
        func output(_ text: String) async throws -> String {
            let result = try await runner.run(text, deadline: 30)
            guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
                throw CheckFailure(message: "fixture query failed (\(result.exitCode)): \(result.outputTail)")
            }
            return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func capture(
            _ record: OnDemandEditInFlightRecord,
            project candidateProject: IrisTestProjectRegistry.Project
        ) async -> PendingEditCandidateIdentity? {
            try? await PendingEditCandidateIdentity.capture(
                record: record, project: candidateProject, runner: runner
            )
        }

        try await command("git init -q -b main")
        let tracked = clone.appendingPathComponent("tracked.txt")
        try Data("baseline\n".utf8).write(to: tracked)
        try await command("git add -- tracked.txt && git -c user.name=Fixture -c user.email=fixture@example.invalid commit --no-gpg-sign -qm baseline")
        let baseline = try await output("git rev-parse --verify HEAD^{commit}")
        try require(baseline.count == 40 || baseline.count == 64, "baseline commit was not a full object id")
        try await command("git checkout -q -b iris/edit-pending")

        try Data("candidate\n".utf8).write(to: tracked)
        let added = clone.appendingPathComponent("new.txt")
        try Data("new candidate\n".utf8).write(to: added)
        try await command("git add -- tracked.txt new.txt")

        let project = IrisTestProjectRegistry.Project(
            slug: "fixture",
            name: "Fixture",
            clonePath: canonicalClone,
            applicationPath: application.path,
            buildArtifactPath: artifact.path,
            bundleIdentifier: "com.publikhq.iris.test.fixture",
            pinnedCommit: baseline
        )
        func record(
            base: String = baseline,
            paths: [String] = ["tracked.txt", "new.txt"],
            review: Bool? = true,
            clonePath: String = canonicalClone
        ) -> OnDemandEditInFlightRecord {
            OnDemandEditInFlightRecord(
                appSlug: project.slug,
                clonePath: clonePath,
                baseCommit: base,
                pathsIrisEdited: paths,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                runLogPath: nil,
                whatIrisWasWaitingFor: "review",
                requiresReviewBeforeRecovery: review
            )
        }

        guard let identity = await capture(record(), project: project) else {
            throw CheckFailure(message: "valid staged candidate was refused")
        }
        try require(identity.project == project, "project snapshot was not retained")
        try require(identity.baselineCommit == baseline, "baseline commit was not retained")
        try require(identity.branchName == "iris/edit-pending", "candidate branch was not captured")
        try require(identity.changedPaths == ["new.txt", "tracked.txt"], "staged paths were not sorted")
        try require(identity.stagedTree.count == 40 || identity.stagedTree.count == 64,
                    "staged tree was not a full object id")
        try require(await identity.stillMatches(record: record(), project: project, runner: runner),
                    "unchanged candidate did not match itself")

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(PendingEditCandidateIdentity.self, from: encoded)
        try require(decoded == identity, "candidate identity JSON roundtrip changed its value")
        guard let repeated = await capture(record(), project: project) else {
            throw CheckFailure(message: "repeated candidate capture was refused")
        }
        try require(repeated == identity, "repeated capture was not stable")
        print("PASS staged tracked and new files capture exact branch, base, tree and paths")

        try require(await identity.stillMatches(record: record(base: String(repeating: "a", count: 40)), project: project, runner: runner) == false,
                    "changed base was accepted")
        try require(await identity.stillMatches(record: record(review: false), project: project, runner: runner) == false,
                    "non-review record was accepted")
        try require(await capture(record(clonePath: fixture.path), project: project) == nil,
                    "changed clone path was accepted")
        let changedProject = IrisTestProjectRegistry.Project(
            slug: project.slug,
            name: "Changed Fixture",
            clonePath: project.clonePath,
            applicationPath: project.applicationPath,
            buildArtifactPath: project.buildArtifactPath,
            bundleIdentifier: project.bundleIdentifier,
            pinnedCommit: project.pinnedCommit
        )
        try require(await identity.stillMatches(record: record(), project: changedProject, runner: runner) == false,
                    "changed project snapshot was accepted")
        print("PASS changed base, clone, project and review state refuse without mutation")

        let worktreeDrift = clone.appendingPathComponent("tracked.txt")
        try Data("unstaged drift\n".utf8).write(to: worktreeDrift)
        try require(await identity.stillMatches(record: record(), project: project, runner: runner) == false,
                    "unstaged worktree drift was accepted")
        try Data("candidate\n".utf8).write(to: worktreeDrift)
        try require(await identity.stillMatches(record: record(), project: project, runner: runner),
                    "candidate did not recover after worktree drift was removed")

        try Data("staged drift\n".utf8).write(to: worktreeDrift)
        try await command("git add -- tracked.txt")
        try require(await identity.stillMatches(record: record(), project: project, runner: runner) == false,
                    "changed index tree was accepted")
        try Data("candidate\n".utf8).write(to: worktreeDrift)
        try await command("git add -- tracked.txt")
        try require(await identity.stillMatches(record: record(), project: project, runner: runner),
                    "candidate did not recover after index drift was removed")

        let foreign = clone.appendingPathComponent("reader-owned.txt")
        try Data("foreign\n".utf8).write(to: foreign)
        try require(await identity.stillMatches(record: record(), project: project, runner: runner) == false,
                    "foreign untracked file was accepted")
        try files.removeItem(at: foreign)

        let extra = clone.appendingPathComponent("extra.txt")
        try Data("extra staged path\n".utf8).write(to: extra)
        try await command("git add -- extra.txt")
        try require(await capture(record(), project: project) == nil, "staged path outside the record was accepted")
        try await command("git reset -q -- extra.txt")
        try files.removeItem(at: extra)
        print("PASS changed worktree, index tree, foreign untracked and extra staged paths refuse")

        let outside = fixture.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outside)
        let symlink = clone.appendingPathComponent("link.txt")
        try files.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try await command("git add -- link.txt")
        var symlinkRecord = record(paths: ["tracked.txt", "new.txt", "link.txt"])
        try require(await capture(symlinkRecord, project: project) == nil, "symlinked changed path was accepted")
        try await command("git reset -q -- link.txt")
        try files.removeItem(at: symlink)
        try files.removeItem(at: outside)
        symlinkRecord.pathsIrisEdited = record().pathsIrisEdited
        try require(await identity.stillMatches(record: record(), project: project, runner: runner),
                    "cleanup after symlink refusal did not restore candidate")
        print("PASS symlink components are refused while the disposable source remains intact")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }
    }
}
