import Foundation

@testable import IrisHarnessNative

@main
struct MaintainFixCommitChecks {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let fixtureBaseURL = fileManager.temporaryDirectory
            .appendingPathComponent("iris-fix-commit-parent-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = fixtureBaseURL
            .appendingPathComponent("iris-fix-commit-check-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = fixtureURL.appendingPathComponent("repo", isDirectory: true)
        let scratchURL = fixtureURL.appendingPathComponent("scratch", isDirectory: true)
        let firstRepositoryURL = fixtureURL.appendingPathComponent("first-repo", isDirectory: true)
        let firstScratchURL = fixtureURL.appendingPathComponent("first-scratch", isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: firstRepositoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: firstScratchURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureURL) }

        let root = MaintainSandbox.canonicalPath(repositoryURL.path)
        let scratch = MaintainSandbox.canonicalPath(scratchURL.path)
        func testPolicy(repositoryRoot: String, scratchPath: String) -> MaintainSandbox.ProcessPolicy {
            MaintainSandbox.testProcessPolicy(
                scratchDirectoryPath: scratchPath,
                additionalReadOnlyPaths: [
                    "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                    "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                    "/Library/Developer", "/Applications/Xcode.app", "/dev",
                ],
                repositoryIsRegistered: { $0 == repositoryRoot }
            )
        }
        let policy = testPolicy(repositoryRoot: root, scratchPath: scratch)
        let runner = try MaintainShellRunner(repoRootPath: root, processPolicy: policy)
        guard runner.isTestProcessPolicy else {
            throw failure("commit fixture did not use Test policy")
        }

        func command(_ text: String, deadline: TimeInterval = 20) async throws -> MaintainCommandResult {
            try await runner.run(text, deadline: deadline)
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw failure(message) }
        }
        func outputLines(_ result: MaintainCommandResult) -> [String] {
            result.outputTail
                .split(whereSeparator: { $0.isNewline })
                .map(String.init)
        }
        func shellQuote(_ rawText: String) -> String {
            "'" + rawText.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let firstRoot = MaintainSandbox.canonicalPath(firstRepositoryURL.path)
        let firstScratch = MaintainSandbox.canonicalPath(firstScratchURL.path)
        let firstRunner = try MaintainShellRunner(
            repoRootPath: firstRoot,
            processPolicy: testPolicy(repositoryRoot: firstRoot, scratchPath: firstScratch)
        )
        let firstSourceURL = firstRepositoryURL.appendingPathComponent("first-source.txt")
        try Data("first commit\n".utf8).write(to: firstSourceURL)
        let firstSetup = try await firstRunner.run(
            "git init -q -b first && git add first-source.txt", deadline: 20)
        try require(firstSetup.succeeded, "unborn fixture could not be initialized")
        let firstPlan = MaintainFixCommitPlan(
            branchPrefix: "iris/edit-",
            changeId: "first-commit",
            subject: "Create first commit",
            trailerLines: ["Modified-by: Iris Test"]
        )
        let firstExpectedBranch = MaintainFixCommit.branchName(
            prefix: firstPlan.branchPrefix, changeId: firstPlan.changeId)
        guard let firstCommittedBranch = await MaintainFixCommit.commitOnBranch(
            plan: firstPlan, runner: firstRunner) else {
            throw failure("unborn fixture first commit was refused")
        }
        try require(firstCommittedBranch == firstExpectedBranch, "first commit returned the wrong branch")
        let firstHead = try await firstRunner.run("git rev-parse --verify HEAD", deadline: 20)
        let firstParent = try await firstRunner.run("git rev-parse --verify HEAD^", deadline: 20)
        let firstSource = try await firstRunner.run("git show HEAD:first-source.txt", deadline: 20)
        try require(firstHead.succeeded && !firstParent.succeeded
            && firstSource.succeeded && outputLines(firstSource) == ["first commit"],
            "unborn fixture did not create the expected root commit")
        print("PASS first commit remains supported on an unborn branch")

        let sourceURL = repositoryURL.appendingPathComponent("source.txt")
        try Data("baseline\n".utf8).write(to: sourceURL)
        try require(
            (try await command("git init -q -b main && git add source.txt && git -c user.name='Fixture Baseline' -c user.email='fixture@example.invalid' commit --no-gpg-sign -qm baseline")).succeeded,
            "fixture baseline commit failed"
        )
        let baselineHead = try await command("git rev-parse --verify HEAD")
        try require(baselineHead.succeeded && outputLines(baselineHead).count == 1,
            "fixture baseline HEAD could not be read")
        let localIdentity = try await command("git config --local --get user.name || exit 1")
        try require(!localIdentity.succeeded, "fixture unexpectedly retained a local Git identity")

        try Data("changed by Iris\n".utf8).write(to: sourceURL)
        try require((try await command("git add source.txt")).succeeded, "fixture change could not be staged")
        let identityFreeCommit = try await command("git commit --no-gpg-sign -qm identity-free-attempt")
        let identityDiagnostic = identityFreeCommit.outputTail.lowercased()
        try require(!identityFreeCommit.succeeded
            && identityDiagnostic.contains("author identity unknown")
            && identityDiagnostic.contains("user.name")
            && identityDiagnostic.contains("user.email"),
            "identity-free commit did not report its missing identity")
        let headAfterRefusal = try await command("git rev-parse --verify HEAD")
        try require(headAfterRefusal.succeeded && outputLines(headAfterRefusal) == outputLines(baselineHead),
            "identity-free commit changed the baseline HEAD")
        try require(
            String(data: try Data(contentsOf: sourceURL), encoding: .utf8) == "changed by Iris\n",
            "failed commit did not preserve the staged source"
        )
        print("PASS Test-policy commit refuses missing identity without reverting source")

        let plan = MaintainFixCommitPlan(
            branchPrefix: "iris/edit-",
            changeId: "plant-project-search",
            subject: "Add project search",
            trailerLines: ["Modified-by: Iris Test"]
        )
        let expectedBranch = MaintainFixCommit.branchName(prefix: plan.branchPrefix, changeId: plan.changeId)
        guard let committedBranch = await MaintainFixCommit.commitOnBranch(plan: plan, runner: runner) else {
            throw failure("Test-policy commit did not create a branch commit")
        }
        try require(committedBranch == expectedBranch, "commit returned the wrong branch")

        let branch = try await command("git symbolic-ref --short HEAD")
        try require(branch.succeeded && outputLines(branch) == [expectedBranch], "commit landed on the wrong branch")
        let parent = try await command("git rev-parse --verify HEAD^")
        try require(parent.succeeded && outputLines(parent) == outputLines(baselineHead),
            "commit parent was not the fixture baseline")
        let committedSource = try await command("git show HEAD:source.txt")
        try require(committedSource.succeeded && outputLines(committedSource) == ["changed by Iris"],
            "committed source did not contain the staged edit")
        let identity = try await command("git show -s --format='%an%n%ae%n%cn%n%ce' HEAD")
        try require(identity.succeeded && outputLines(identity) == [
            "Iris Test", "iris-test@localhost", "Iris Test", "iris-test@localhost",
        ], "Test commit did not use the deterministic author and committer identity")
        let commitObject = try await command("git cat-file -p HEAD")
        try require(commitObject.succeeded, "committed object could not be read")
        try require(!outputLines(commitObject).contains(where: { $0.hasPrefix("gpgsig ") }),
            "Test commit unexpectedly retained a gpg signature")
        let cleanStatus = try await command("git status --porcelain")
        try require(cleanStatus.succeeded && cleanStatus.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "successful Test commit left the source tree dirty")
        let localNameAfter = try await command("git config --local --get user.name")
        let localEmailAfter = try await command("git config --local --get user.email")
        try require(!localNameAfter.succeeded && !localEmailAfter.succeeded,
            "Test commit persisted its identity in local Git config")
        print("PASS Test-policy commit uses exact branch, parent, source, identity and no signing")

        let headBeforeNoOp = try await command("git rev-parse --verify HEAD")
        let noOpPlan = MaintainFixCommitPlan(
            branchPrefix: "iris/edit-",
            changeId: "no-op",
            subject: "No-op change",
            trailerLines: ["Modified-by: Iris Test"]
        )
        let noOpResult = await MaintainFixCommit.commitOnBranch(plan: noOpPlan, runner: runner)
        try require(noOpResult == nil, "no-op commit was reported as successful")
        let headAfterNoOp = try await command("git rev-parse --verify HEAD")
        try require(headBeforeNoOp.succeeded && headAfterNoOp.succeeded
            && outputLines(headAfterNoOp) == outputLines(headBeforeNoOp),
            "no-op commit moved HEAD")
        let noOpStatus = try await command("git status --porcelain")
        try require(noOpStatus.succeeded
            && noOpStatus.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "no-op refusal left the source tree dirty")
        print("PASS no-op commit refuses without moving HEAD")

        let brokenPlan = MaintainFixCommitPlan(
            branchPrefix: "iris/edit-",
            changeId: "broken-head",
            subject: "Probe broken HEAD",
            trailerLines: ["Modified-by: Iris Test"]
        )
        let brokenExpectedBranch = MaintainFixCommit.branchName(
            prefix: brokenPlan.branchPrefix, changeId: brokenPlan.changeId)
        let brokenRef = "refs/heads/\(brokenExpectedBranch)"
        let hookURL = repositoryURL.appendingPathComponent(".git/hooks/post-checkout")
        let deadHash = String(repeating: "0", count: 40)
        let hookTarget = ".git/\(brokenRef)"
        let hookScript = "#!/bin/sh\nprintf '%s\\n' \(shellQuote(deadHash)) > \(shellQuote(hookTarget))\nexit 0\n"
        try Data(hookScript.utf8).write(to: hookURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookURL.path)
        defer { try? fileManager.removeItem(at: hookURL) }
        try Data("broken HEAD edit\n".utf8).write(to: sourceURL)
        let brokenResult = await MaintainFixCommit.commitOnBranch(plan: brokenPlan, runner: runner)
        try require(brokenResult == nil, "broken symbolic HEAD was reported as a successful commit")
        let brokenBranch = try await command("git symbolic-ref --short HEAD")
        try require(brokenBranch.succeeded && outputLines(brokenBranch) == [brokenExpectedBranch],
            "broken HEAD probe did not leave the expected symbolic branch")
        let brokenReference = try await command(
            "git show-ref --verify --quiet \(shellQuote(brokenRef))")
        try require(!brokenReference.succeeded && brokenReference.exitCode != 1
            && !brokenReference.timedOut
            && String(data: try Data(contentsOf: repositoryURL.appendingPathComponent(hookTarget)),
                      encoding: .utf8) == deadHash + "\n",
            "broken HEAD probe did not retain a malformed rather than missing ref")
        let brokenHead = try await command("git rev-parse --verify 'HEAD^{commit}'")
        try require(!brokenHead.succeeded && !brokenHead.timedOut,
            "broken HEAD unexpectedly resolved")
        try require(
            String(data: try Data(contentsOf: sourceURL), encoding: .utf8) == "broken HEAD edit\n",
            "broken HEAD refusal altered the source")
        print("PASS broken symbolic HEAD refuses without claiming delivery")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "maintain-fix-commit-checks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
