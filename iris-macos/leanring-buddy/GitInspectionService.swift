//
//  GitInspectionService.swift
//  leanring-buddy
//
//  Reads the commit a cloned repository is sitting on, so a guide can tell the
//  reader whether they are on the commit the guide was written against. Ported
//  from `git_head` and `allowed_repository_path` in
//  `iris-desktop/src-tauri/src/main.rs` (lines 701-760), which remains the
//  behavioral spec. Everything here is read-only: no command in this file can
//  change a single byte of the user's repository.
//

import Foundation

struct GitHead: Codable, Equatable, Sendable {
    let repositoryPath: String
    let head: String
}

enum GitInspectionError: Error, Equatable, Sendable {
    case invalidRepositoryPath
    case repositoryPathDoesNotExist
    /// The path resolved somewhere outside the user's home directory, or to the
    /// home directory itself. Both are refused before Git is ever launched.
    case repositoryMustBeADirectoryInsideHome
    case pathIsNotAGitWorkingTree
    case homeDirectoryIsUnavailable
    case gitIsNotInstalled
    case couldNotInspectRepository(reason: String)
    case pathIsNotAReadableGitRepository
    case gitReturnedAnInvalidCommitIdentifier

    var userFacingMessage: String {
        switch self {
        case .invalidRepositoryPath:
            return "invalid repository path"
        case .repositoryPathDoesNotExist:
            return "repository path does not exist"
        case .repositoryMustBeADirectoryInsideHome:
            return "repository must be a directory inside the current user's home"
        case .pathIsNotAGitWorkingTree:
            return "path is not a Git working tree"
        case .homeDirectoryIsUnavailable:
            return "home directory is unavailable"
        case .gitIsNotInstalled:
            return "Git is not installed"
        case .couldNotInspectRepository(let reason):
            return "could not inspect Git repository: \(reason)"
        case .pathIsNotAReadableGitRepository:
            return "path is not a readable Git repository"
        case .gitReturnedAnInvalidCommitIdentifier:
            return "Git returned an invalid commit identifier"
        }
    }
}

enum GitInspectionService {
    /// Longer than any real path, and the point past which the input is not a
    /// path at all. Matches the bound in `allowed_repository_path`.
    private static let maximumRepositoryPathLength = 4096

    /// The two commit identifier lengths Git produces, for SHA-1 and SHA-256
    /// repositories respectively.
    private static let validCommitIdentifierLengths: Set<Int> = [40, 64]

    /// Environment that keeps the inspection read-only and silent: no system
    /// config a guide cannot see, no lock files written into the user's
    /// repository, and no credential prompt that would hang with no terminal.
    private static let readOnlyGitEnvironment: [String: String] = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// Resolves and vets the path a guide wants inspected. Ported from
    /// `allowed_repository_path` (main.rs:737-760).
    static func allowedRepositoryPath(_ repositoryPath: String) throws -> String {
        guard !repositoryPath.isEmpty, repositoryPath.count <= maximumRepositoryPathLength else {
            throw GitInspectionError.invalidRepositoryPath
        }

        let fileManager = FileManager.default

        // `resolvingSymlinksInPath` is the stand-in for Rust's `canonicalize`,
        // so a symlink pointing out of home cannot be used to escape the check
        // below. Existence is verified separately because, unlike canonicalize,
        // resolving a path does not require the path to be there.
        let resolvedRepositoryURL = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var repositoryIsDirectory: ObjCBool = false
        let repositoryExists = fileManager.fileExists(
            atPath: resolvedRepositoryURL.path,
            isDirectory: &repositoryIsDirectory
        )
        guard repositoryExists else {
            throw GitInspectionError.repositoryPathDoesNotExist
        }

        let resolvedHomeDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard !resolvedHomeDirectoryURL.path.isEmpty else {
            throw GitInspectionError.homeDirectoryIsUnavailable
        }

        // The home directory itself is refused as well as anything outside it:
        // running Git at the top of a home directory is either a mistake or an
        // attempt to read a repository the reader did not point us at.
        let isTheHomeDirectoryItself = resolvedRepositoryURL.path == resolvedHomeDirectoryURL.path
        guard !isTheHomeDirectoryItself,
              isPath(resolvedRepositoryURL, containedInDirectory: resolvedHomeDirectoryURL),
              repositoryIsDirectory.boolValue else {
            throw GitInspectionError.repositoryMustBeADirectoryInsideHome
        }

        let gitMetadataPath = resolvedRepositoryURL.appendingPathComponent(".git").path
        guard fileManager.fileExists(atPath: gitMetadataPath) else {
            throw GitInspectionError.pathIsNotAGitWorkingTree
        }

        return resolvedRepositoryURL.path
    }

    /// Component-wise containment, which is what Rust's `Path::starts_with`
    /// does. A plain string prefix test would let `/Users/someone-else` pass as
    /// being inside `/Users/someone`.
    static func isPath(_ candidateURL: URL, containedInDirectory directoryURL: URL) -> Bool {
        let candidateComponents = candidateURL.pathComponents
        let directoryComponents = directoryURL.pathComponents
        guard candidateComponents.count >= directoryComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    /// Runs `git rev-parse` off the main thread, mirroring the `spawn_blocking`
    /// the Tauri command uses.
    static func gitHead(repositoryPath: String) async throws -> GitHead {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let gitHead = try gitHeadBlocking(repositoryPath: repositoryPath)
                    continuation.resume(returning: gitHead)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func gitHeadBlocking(repositoryPath: String) throws -> GitHead {
        let allowedRepositoryDirectoryPath = try allowedRepositoryPath(repositoryPath)

        guard case .found(let gitExecutablePath) =
                ToolVersionService.locateExecutableOnSearchPath(named: "git") else {
            // A Mac with no Git on PATH still has the Homebrew and Apple
            // locations worth trying before giving up.
            guard let fallbackGitExecutablePath = try ToolVersionService.selectToolExecutablePath(
                tool: "git",
                searchPathLookupOutcome: .notFoundOnSearchPath,
                trustedFallbackPaths: ToolVersionService.trustedToolFallbackPaths(for: "git")
            ) else {
                throw GitInspectionError.gitIsNotInstalled
            }
            return try readHead(
                gitExecutablePath: fallbackGitExecutablePath,
                allowedRepositoryDirectoryPath: allowedRepositoryDirectoryPath
            )
        }

        return try readHead(
            gitExecutablePath: gitExecutablePath,
            allowedRepositoryDirectoryPath: allowedRepositoryDirectoryPath
        )
    }

    private static func readHead(
        gitExecutablePath: String,
        allowedRepositoryDirectoryPath: String
    ) throws -> GitHead {
        // `rev-parse --verify HEAD^{commit}` reads and resolves; it writes
        // nothing, and `--no-optional-locks` keeps Git from refreshing the index
        // on disk while it answers.
        let commandArguments = [
            "--no-optional-locks",
            "-C",
            allowedRepositoryDirectoryPath,
            "rev-parse",
            "--verify",
            "HEAD^{commit}",
        ]

        var gitEnvironment = ProcessInfo.processInfo.environment
        for (variableName, variableValue) in readOnlyGitEnvironment {
            gitEnvironment[variableName] = variableValue
        }

        let commandResult: (terminationStatus: Int32, standardOutput: Data, standardError: Data)
        do {
            commandResult = try ToolVersionService.runCommand(
                executablePath: gitExecutablePath,
                arguments: commandArguments,
                environment: gitEnvironment,
                workingDirectory: nil
            )
        } catch {
            throw GitInspectionError.couldNotInspectRepository(reason: error.localizedDescription)
        }

        guard commandResult.terminationStatus == 0 else {
            throw GitInspectionError.pathIsNotAReadableGitRepository
        }

        let head = String(decoding: commandResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCommitIdentifier(head) else {
            throw GitInspectionError.gitReturnedAnInvalidCommitIdentifier
        }

        return GitHead(repositoryPath: allowedRepositoryDirectoryPath, head: head)
    }

    static func isValidCommitIdentifier(_ head: String) -> Bool {
        guard validCommitIdentifierLengths.contains(head.count) else {
            return false
        }
        return head.allSatisfy { character in
            character.isHexDigit && character.isASCII
        }
    }
}
