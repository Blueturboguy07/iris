import Darwin
import Foundation

/// Exact identity for an Iris Test edit that was staged but not committed.
/// This is deliberately separate from `SavedEditDeliveryIdentity`, whose
/// contract starts at a clean committed branch.
nonisolated struct PendingEditCandidateIdentity: Codable, Equatable, Sendable {
    /// The complete registered Test project snapshot, not only its slug.
    let project: IrisTestProjectRegistry.Project
    /// HEAD before the edit was staged. A candidate may resume only from this
    /// exact commit.
    let baselineCommit: String
    /// The short branch name. Capture validates its full `refs/heads/...` ref.
    let branchName: String
    /// The tree object written from the staged index. `git write-tree` writes
    /// normal Git metadata only; it does not create a source commit.
    let stagedTree: String
    /// The net staged paths, sorted and captured from Git rather than inferred.
    let changedPaths: [String]

    /// Capture a candidate left by a failed commit. The caller supplies the
    /// review-held interruption record and the exact current registry project.
    /// No source or commit is changed by these probes.
    @MainActor
    static func capture(
        record: OnDemandEditInFlightRecord,
        project: IrisTestProjectRegistry.Project,
        runner: MaintainShellRunner
    ) async throws -> Self {
        guard runner.isTestProcessPolicy,
              record.requiresReviewBeforeRecovery == true,
              record.appSlug == project.slug,
              record.clonePath == project.clonePath,
              isSafeProjectSnapshot(project),
              isGitObjectID(record.baseCommit),
              isCanonicalAbsolutePath(record.clonePath),
              let canonicalRoot = MaintainSandbox.canonicalExistingDirectory(record.clonePath),
              canonicalRoot == record.clonePath,
              canonicalRoot == project.clonePath,
              runner.repoRootPath == canonicalRoot,
              !record.pathsIrisEdited.isEmpty,
              Set(record.pathsIrisEdited).count == record.pathsIrisEdited.count,
              record.pathsIrisEdited.allSatisfy(isSafeRelativePath) else {
            throw CaptureError.refused
        }

        guard let head = await checkedSingleLine(
            "git rev-parse --verify HEAD^{commit}", runner: runner
        ), head == record.baseCommit else {
            throw CaptureError.refused
        }
        guard let symbolicRef = await checkedSingleLine(
            "git symbolic-ref --quiet HEAD", runner: runner
        ), symbolicRef.hasPrefix("refs/heads/") else {
            throw CaptureError.refused
        }
        let branchFromRef = String(symbolicRef.dropFirst("refs/heads/".count))
        guard !branchFromRef.isEmpty, isSafeBranch(branchFromRef) else {
            throw CaptureError.refused
        }

        // The failed commit stages the candidate. A later unstaged change is
        // ambiguous, so it must refuse rather than silently re-stage it.
        guard let cleanIndexWorktree = try? await runner.run(
            "git diff --quiet --no-ext-diff --no-textconv", deadline: 30
        ), cleanIndexWorktree.succeeded,
              cleanIndexWorktree.bytesDroppedBeforeTail == 0,
              cleanIndexWorktree.outputTail.isEmpty else {
            throw CaptureError.refused
        }
        guard let untracked = try? await runner.run(
            "git ls-files --others --exclude-standard -z", deadline: 30
        ), untracked.succeeded,
              untracked.bytesDroppedBeforeTail == 0,
              untracked.outputTail.isEmpty else {
            throw CaptureError.refused
        }

        guard let stagedPathResult = try? await runner.run(
            "git diff --cached --name-only --no-renames -z", deadline: 30
        ), stagedPathResult.succeeded,
              stagedPathResult.bytesDroppedBeforeTail == 0,
              let lastByte = stagedPathResult.outputTail.utf8.last,
              lastByte == 0,
              let stagedPaths = parseNulTerminatedPaths(stagedPathResult.outputTail),
              !stagedPaths.isEmpty,
              Set(stagedPaths).count == stagedPaths.count,
              stagedPaths.allSatisfy(isSafeRelativePath),
              Set(stagedPaths).isSubset(of: Set(record.pathsIrisEdited)),
              stagedPaths.allSatisfy({ !hasSymlinkComponent($0, under: canonicalRoot) }) else {
            throw CaptureError.refused
        }

        guard let treeResult = try? await runner.run("git write-tree", deadline: 30),
              let stagedTree = checkedSingleLine(treeResult),
              isGitObjectID(stagedTree) else {
            throw CaptureError.refused
        }
        guard await checkedSingleLine("git rev-parse --verify HEAD^{commit}", runner: runner) == head,
              await checkedSingleLine("git symbolic-ref --quiet HEAD", runner: runner) == symbolicRef else {
            throw CaptureError.refused
        }
        return Self(
            project: project,
            baselineCommit: record.baseCommit,
            branchName: branchFromRef,
            stagedTree: stagedTree,
            changedPaths: stagedPaths.sorted()
        )
    }

    /// Re-run every capture probe and compare the complete value. A changed
    /// registry snapshot, base, branch, staged tree, or path set returns false.
    @MainActor
    func stillMatches(
        record: OnDemandEditInFlightRecord,
        project currentProject: IrisTestProjectRegistry.Project,
        runner: MaintainShellRunner
    ) async -> Bool {
        guard project == currentProject,
              baselineCommit == record.baseCommit else { return false }
        do {
            return try await Self.capture(
                record: record,
                project: currentProject,
                runner: runner
            ) == self
        } catch {
            return false
        }
    }

    enum CaptureError: Error, Equatable {
        case refused
    }

    private static func checkedSingleLine(
        _ command: String, runner: MaintainShellRunner
    ) async -> String? {
        guard let result = try? await runner.run(command, deadline: 30) else { return nil }
        return checkedSingleLine(result)
    }

    private static func checkedSingleLine(_ result: MaintainCommandResult) -> String? {
        guard result.succeeded, result.bytesDroppedBeforeTail == 0 else { return nil }
        let lines = result.outputTail.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count == 1, !lines[0].isEmpty else { return nil }
        return lines[0]
    }

    private static func parseNulTerminatedPaths(_ output: String) -> [String]? {
        guard let lastScalar = output.unicodeScalars.last, lastScalar.value == 0 else {
            return nil
        }
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard !paths.isEmpty, !paths.contains(where: { $0.contains("\u{FFFD}") }) else { return nil }
        return paths
    }

    private static func isSafeProjectSnapshot(
        _ project: IrisTestProjectRegistry.Project
    ) -> Bool {
        safeMetadata(project.slug)
            && safeMetadata(project.name)
            && isCanonicalAbsolutePath(project.clonePath)
            && isCanonicalAbsolutePath(project.applicationPath)
            && isCanonicalAbsolutePath(project.buildArtifactPath)
            && safeMetadata(project.bundleIdentifier)
            && !project.bundleIdentifier.contains("/")
            && isGitObjectID(project.pinnedCommit)
    }

    private static func safeMetadata(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSafeBranch(_ branch: String) -> Bool {
        guard safeMetadata(branch), branch != "HEAD",
              !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.contains(".."), !branch.contains("@{"),
              !branch.hasSuffix("."), !branch.hasSuffix(".lock"),
              !branch.contains(where: { " ~^:?*[\\".contains($0) }) else {
            return false
        }
        let components = branch.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            let part = String(component)
            return !part.isEmpty && part != "." && part != ".."
                && part != "@" && !part.hasPrefix(".") && !part.hasSuffix(".")
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count)
            && value.allSatisfy { $0.isHexDigit }
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
        return true
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), !path.contains("\u{FFFD}"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }) else {
            return false
        }
        return !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Walk with lstat so a changed path cannot resolve through a symlink.
    /// Missing final paths are allowed for staged deletions; unreadable path
    /// components refuse rather than becoming an unverifiable candidate.
    private static func hasSymlinkComponent(_ relativePath: String, under root: String) -> Bool {
        var current = URL(fileURLWithPath: root, isDirectory: true)
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                let kind = metadata.st_mode & S_IFMT
                if kind == S_IFLNK { return true }
                if index < components.count - 1, kind != S_IFDIR { return true }
                continue
            }
            if errno == ENOENT { return false }
            return true
        }
        return false
    }
}
