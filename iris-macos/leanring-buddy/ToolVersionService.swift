//
//  ToolVersionService.swift
//  leanring-buddy
//
//  Answers "is this developer tool installed, and which version?" for the
//  verify steps of a guide. Ported from `check_tool_version` and its helpers in
//  `iris-desktop/src-tauri/src/main.rs` (lines 536-699), which remains the
//  behavioral spec.
//

import Foundation

struct ToolVersion: Codable, Equatable, Sendable {
    let tool: String
    let available: Bool
    let version: String
}

enum ToolVersionError: Error, Equatable, Sendable {
    /// The requested name is not one of the fourteen tools a guide may ask about.
    case toolIsNotAllowlisted(tool: String)
    /// Looking the tool up on the search path failed for a reason other than
    /// "it isn't there" — a missing tool is data, but a broken lookup is an error.
    case couldNotLocateTool(tool: String, reason: String)
    case couldNotInspectTool(tool: String, reason: String)
    case versionCheckFailed(tool: String, output: String)
    case toolReturnedAnEmptyVersion(tool: String)

    var userFacingMessage: String {
        switch self {
        case .toolIsNotAllowlisted(let tool):
            return "tool '\(tool)' is not allowlisted"
        case .couldNotLocateTool(let tool, let reason):
            return "could not locate '\(tool)': \(reason)"
        case .couldNotInspectTool(let tool, let reason):
            return "could not inspect '\(tool)': \(reason)"
        case .versionCheckFailed(let tool, let output):
            return output.isEmpty
                ? "'\(tool)' version check failed"
                : "'\(tool)' version check failed: \(output)"
        case .toolReturnedAnEmptyVersion(let tool):
            return "'\(tool)' returned an empty version"
        }
    }
}

/// What looking a tool up on `PATH` produced. `notFoundOnSearchPath` is a normal
/// answer that becomes an "available: false" result; anything else is an error,
/// which is the distinction `select_tool_executable` draws in main.rs:599-612.
enum ToolExecutableLookupOutcome: Equatable, Sendable {
    case found(executablePath: String)
    case notFoundOnSearchPath
    case searchPathUnreadable(reason: String)
}

/// Somewhere for the two pipe-reading queues to put what they read. It is a
/// reference type on purpose: each field is written by exactly one queue and
/// read only after `DispatchGroup.wait()` has ordered both writes before it.
private final class CollectedProcessOutput {
    var standardOutput = Data()
    var standardError = Data()
}

enum ToolVersionService {
    /// Command output is bounded at this many characters, matching
    /// `MAX_COMMAND_OUTPUT` in main.rs:27.
    private static let maximumCommandOutputCharacterCount = 512

    // MARK: - The closed allowlist

    /// The fourteen tools a guide step may ask about, each with the exact
    /// arguments that make it print its version. Ported from `tool_spec`
    /// (main.rs:681-699). A name outside this table is refused, which is what
    /// keeps a guide from turning into arbitrary command execution.
    static func toolSpecification(
        for tool: String
    ) -> (executableName: String, arguments: [String])? {
        switch tool {
        case "git": return (executableName: "git", arguments: ["--version"])
        case "node": return (executableName: "node", arguments: ["--version"])
        case "npm": return (executableName: "npm", arguments: ["--version"])
        case "pnpm": return (executableName: "pnpm", arguments: ["--version"])
        case "bun": return (executableName: "bun", arguments: ["--version"])
        case "python": return (executableName: "python", arguments: ["--version"])
        case "python3": return (executableName: "python3", arguments: ["--version"])
        case "uv": return (executableName: "uv", arguments: ["--version"])
        case "cargo": return (executableName: "cargo", arguments: ["--version"])
        case "rustc": return (executableName: "rustc", arguments: ["--version"])
        case "docker": return (executableName: "docker", arguments: ["--version"])
        case "java": return (executableName: "java", arguments: ["--version"])
        case "adb": return (executableName: "adb", arguments: ["version"])
        case "xcodebuild": return (executableName: "xcodebuild", arguments: ["-version"])
        default: return nil
        }
    }

    /// Fixed locations to try when a tool is not on this app's `PATH`, which a
    /// GUI app started from Finder frequently is missing. Ported from the macOS
    /// `trusted_tool_fallback_paths` (main.rs:614-626): only Git and Node get
    /// fallbacks, because only their install locations are predictable enough to
    /// hard-code without guessing at somebody else's machine.
    static func trustedToolFallbackPaths(for tool: String) -> [String] {
        switch tool {
        case "git":
            return ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        case "node":
            return ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        default:
            return []
        }
    }

    // MARK: - Locating the executable

    /// Walks `PATH` for the tool. Never runs a shell, so nothing in the tool
    /// name can be interpreted as a command.
    static func locateExecutableOnSearchPath(named executableName: String) -> ToolExecutableLookupOutcome {
        guard let searchPathValue = ProcessInfo.processInfo.environment["PATH"] else {
            return .searchPathUnreadable(reason: "PATH is not set")
        }

        let fileManager = FileManager.default
        for searchPathDirectory in searchPathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let candidatePath = URL(fileURLWithPath: String(searchPathDirectory))
                .appendingPathComponent(executableName)
                .path
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return .found(executablePath: candidatePath)
            }
        }
        return .notFoundOnSearchPath
    }

    /// Ported from `select_tool_executable` (main.rs:599-612). Returns nil when
    /// the tool is simply absent, and throws when the lookup itself failed.
    static func selectToolExecutablePath(
        tool: String,
        searchPathLookupOutcome: ToolExecutableLookupOutcome,
        trustedFallbackPaths: [String]
    ) throws -> String? {
        switch searchPathLookupOutcome {
        case .found(let executablePath):
            return executablePath
        case .notFoundOnSearchPath:
            let fileManager = FileManager.default
            return trustedFallbackPaths.first { candidatePath in
                var candidateIsDirectory: ObjCBool = false
                let candidateExists = fileManager.fileExists(
                    atPath: candidatePath,
                    isDirectory: &candidateIsDirectory
                )
                return candidateExists && !candidateIsDirectory.boolValue
            }
        case .searchPathUnreadable(let reason):
            throw ToolVersionError.couldNotLocateTool(tool: tool, reason: reason)
        }
    }

    // MARK: - Running the check

    /// Runs the tool's version command off the main thread, mirroring the
    /// `spawn_blocking` the Tauri command uses so a slow tool never stalls the UI.
    static func checkToolVersion(tool: String) async throws -> ToolVersion {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let toolVersion = try checkToolVersionBlocking(tool: tool)
                    continuation.resume(returning: toolVersion)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func checkToolVersionBlocking(tool: String) throws -> ToolVersion {
        guard let toolSpecification = toolSpecification(for: tool) else {
            throw ToolVersionError.toolIsNotAllowlisted(tool: tool)
        }

        let searchPathLookupOutcome = locateExecutableOnSearchPath(
            named: toolSpecification.executableName
        )
        guard let executablePath = try selectToolExecutablePath(
            tool: tool,
            searchPathLookupOutcome: searchPathLookupOutcome,
            trustedFallbackPaths: trustedToolFallbackPaths(for: tool)
        ) else {
            return unavailableToolVersion(tool: tool)
        }

        let commandResult: (terminationStatus: Int32, standardOutput: Data, standardError: Data)
        do {
            commandResult = try runCommand(
                executablePath: executablePath,
                arguments: toolSpecification.arguments,
                environment: nil,
                workingDirectory: nil
            )
        } catch {
            throw ToolVersionError.couldNotInspectTool(
                tool: tool,
                reason: error.localizedDescription
            )
        }

        let version = boundedCommandOutput(
            standardOutput: commandResult.standardOutput,
            standardError: commandResult.standardError
        )

        if commandResult.terminationStatus != 0 {
            // A Mac without the Xcode command line tools has a `git` shim that
            // exits non-zero with an xcrun complaint. That means "not installed",
            // which the guide can walk the reader through, rather than an error.
            if isMissingMacOSGitDeveloperTools(tool: tool, output: version) {
                return unavailableToolVersion(tool: tool)
            }
            throw ToolVersionError.versionCheckFailed(tool: tool, output: version)
        }

        if version.isEmpty {
            throw ToolVersionError.toolReturnedAnEmptyVersion(tool: tool)
        }

        return ToolVersion(tool: tool, available: true, version: version)
    }

    static func unavailableToolVersion(tool: String) -> ToolVersion {
        ToolVersion(tool: tool, available: false, version: "")
    }

    /// Ported from `is_missing_macos_git_developer_tools` (main.rs:588-597).
    /// Only these two phrasings mean "the tools were never installed"; every
    /// other xcrun or xcode-select failure stays a real error.
    static func isMissingMacOSGitDeveloperTools(tool: String, output: String) -> Bool {
        guard tool == "git" else {
            return false
        }

        let normalizedOutput = output.lowercased()
        let hasInvalidDeveloperPath =
            normalizedOutput.contains("xcrun: error: invalid active developer path")
            && normalizedOutput.contains("missing xcrun at:")
        let hasNoDeveloperTools =
            normalizedOutput.contains("xcode-select: note: no developer tools were found")
        return hasInvalidDeveloperPath || hasNoDeveloperTools
    }

    /// Ported from `bounded_command_output` (main.rs:767-776). Standard error is
    /// used only when standard output is empty, because several of these tools
    /// print their version to stderr.
    static func boundedCommandOutput(standardOutput: Data, standardError: Data) -> String {
        let sourceData = standardOutput.isEmpty ? standardError : standardOutput
        let decodedOutput = String(decoding: sourceData, as: UTF8.self)

        // Control characters are stripped so a tool cannot repaint the panel
        // with escape sequences; newlines and tabs are kept because multi-line
        // version banners (xcodebuild, java) are still worth reading.
        var boundedOutput = ""
        boundedOutput.reserveCapacity(maximumCommandOutputCharacterCount)
        for character in decodedOutput {
            if boundedOutput.count >= maximumCommandOutputCharacterCount {
                break
            }
            let isControlCharacter = character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            }
            if isControlCharacter && character != "\n" && character != "\t" {
                continue
            }
            boundedOutput.append(character)
        }
        return boundedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Launches an executable by explicit path with an argument array. There is
    /// no shell anywhere in this call, so no part of a guide's input is ever
    /// parsed as a command.
    static func runCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) throws -> (terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
        }
        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // A tool that decides to prompt would otherwise wait forever on a
        // terminal this app does not have.
        process.standardInput = FileHandle.nullDevice
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()

        // Both pipes are drained concurrently: reading one to completion first
        // deadlocks whenever the tool fills the other pipe's buffer. The group's
        // wait is the barrier that makes both reads visible to this thread.
        let collectedOutput = CollectedProcessOutput()
        let pipeReadingGroup = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: pipeReadingGroup) {
            collectedOutput.standardOutput = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: pipeReadingGroup) {
            collectedOutput.standardError = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        pipeReadingGroup.wait()
        process.waitUntilExit()

        return (
            terminationStatus: process.terminationStatus,
            standardOutput: collectedOutput.standardOutput,
            standardError: collectedOutput.standardError
        )
    }
}
