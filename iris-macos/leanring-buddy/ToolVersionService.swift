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
/// `@unchecked Sendable` rather than actor-isolated: the ordering argument above
/// is the safety argument, and it is one the compiler cannot check. Isolating it
/// to an actor instead would mean the two pipe-reading queues could not write to
/// it at all, which is the entire job.
private nonisolated final class CollectedProcessOutput: @unchecked Sendable {
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
        // Added Aug 27 2026. A guide step ran `brew install gh` on a Mac with
        // no Homebrew and failed with "command not found", and nothing in the
        // guide installed Homebrew or could even ask whether it was there —
        // `brew` was not a tool this service knew, so a `toolVersion` watch on
        // it could never be satisfied. Same for `gh`: without it, a reader who
        // already had the GitHub CLI was walked through installing it again,
        // which is the cargo failure wearing different clothes.
        case "brew": return (executableName: "brew", arguments: ["--version"])
        // The whisper.cpp build needs cmake on BOTH platforms, but only the
        // Windows branch of the whimprflow guide ever installed it. A macOS
        // reader reached the build and got "cmake: No such file or directory"
        // with no step that could fix it, and no way for the guide to notice.
        case "cmake": return (executableName: "cmake", arguments: ["--version"])
        case "gh": return (executableName: "gh", arguments: ["--version"])
        default: return nil
        }
    }

    /// Fixed locations to try when a tool is not on this app's `PATH`, which a
    /// GUI app started from Finder frequently is missing. Ported from the macOS
    /// `trusted_tool_fallback_paths` (main.rs:614-626): only Git and Node get
    /// fallbacks, because only their install locations are predictable enough to
    /// hard-code without guessing at somebody else's machine.
    /// Where to look for a tool when `PATH` does not have it.
    ///
    /// This was a two-case switch — `git` and `node` — and everything else got
    /// an empty list. A Finder-launched app's PATH is the four system
    /// directories `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so for
    /// the other twelve tools the answer to "is this installed" was
    /// effectively "no".
    ///
    /// That PATH is MEASURED, from a stub .app opened by Finder itself. This
    /// comment used to claim it was
    /// `/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
    /// which is the login/path_helper PATH, not launchd's — and the difference
    /// is load-bearing rather than pedantic: /usr/local/bin/node exists on the
    /// machine this was written on, so believing the old string made the
    /// "Iris can't run any Node tool" bug look impossible to reproduce here.
    /// `cargo` lives in `~/.cargo/bin`, which is on no such PATH, so Iris has
    /// never once been able to see that a reader has Rust — which is why the
    /// hickeyfield guide walks somebody who already has it through installing
    /// it again, and why that step's own comment says the local signal "would
    /// never fire for anybody".
    ///
    /// Now it reuses the discovery written for the Codex lookup, which finds
    /// the SHAPE a tool installs into (`<dir>/bin`, `<dir>/shims`, npm's
    /// configured prefix, per-version manager directories) rather than naming
    /// paths one at a time. `~/.cargo/bin/cargo` needs no special case: it is
    /// just another `<dir>/bin`.
    static func trustedToolFallbackPaths(for tool: String) -> [String] {
        let executableName = toolSpecification(for: tool)?.executableName ?? tool
        var paths = CodexCLILogin.candidatePaths(forExecutableNamed: executableName)

        // System locations the generic discovery deliberately leaves out — it
        // looks where user installs land, and these are shipped with macOS or
        // by an installer that owns a fixed path.
        paths += ["/usr/bin/\(executableName)", "/bin/\(executableName)"]

        // The few tools that live somewhere no amount of shape-guessing finds.
        switch tool {
        case "docker":
            paths.append("/Applications/Docker.app/Contents/Resources/bin/docker")
        case "adb":
            paths.append("\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb")
        case "xcodebuild":
            paths.append("/usr/bin/xcodebuild")
        default:
            break
        }
        return paths
    }

    // MARK: - Locating the executable

    /// Walks `PATH` for the tool. The tool name is never handed to a shell, so
    /// nothing in it can be interpreted as a command.
    ///
    /// The PATH walked is `LoginShellEnvironment`'s — the reader's own login
    /// shell's, unioned with this process's — and not the raw inherited one.
    /// An Iris launched from Finder inherits launchd's four system directories,
    /// which is why a reader with Homebrew, nvm or an npm prefix looked to Iris
    /// like a reader with nothing installed. (A shell IS run to learn that
    /// PATH, once per launch, with a constant command that never sees a tool
    /// name.)
    static func locateExecutableOnSearchPath(named executableName: String) -> ToolExecutableLookupOutcome {
        guard let searchPathValue = LoginShellEnvironment.searchPathForChildProcesses() else {
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

    /// The environment a version probe is launched in. Named, and used by the
    /// test that asserts "the executable Iris picks can actually run in the
    /// environment Iris gives it", so the two can never drift apart.
    ///
    /// It used to be nil — inherit whatever Iris itself has — and on an Iris
    /// launched from Finder that is launchd's `/usr/bin:/bin:/usr/sbin:/sbin`.
    /// Every Node-based tool a guide can watch for (`pnpm`, `npm`, `npx`,
    /// `corepack`) is a `#!/usr/bin/env node` script, so the probe found the
    /// right file, ran it, and got `env: node: No such file or directory` and
    /// exit 127. That throw became "could not check", and the position finder
    /// read "could not check pnpm" as a reader who never installed it and sent
    /// them back to step 2 — the "Iris doesn't remember where I was" report.
    static func environmentForToolVersionCommands() -> [String: String] {
        LoginShellEnvironment.environmentForChildProcesses()
    }

    /// Where a version probe is run from — the reader's home directory, not
    /// wherever Iris happens to have been launched.
    ///
    /// `--version` looks like a question that cannot depend on a directory,
    /// and for a real binary it does not. But `pnpm` on this Mac is a corepack
    /// shim that reads the nearest package.json, and it answers by location:
    /// measured, cwd=/ gives 9.15.9, cwd=<a repo> gives 10.0.0, and cwd=a
    /// workspace root gives `ERROR packages field missing or empty` and a
    /// non-zero exit — which is the same "could not check" that discards the
    /// reader's progress, arriving by a second route. Home is stable, always
    /// readable, and holds no package.json.
    static func workingDirectoryForToolVersionCommands() -> URL {
        let homeDirectoryPath = NSHomeDirectory()
        var homeIsADirectory: ObjCBool = false
        let homeExists = FileManager.default.fileExists(
            atPath: homeDirectoryPath, isDirectory: &homeIsADirectory
        )
        guard homeExists && homeIsADirectory.boolValue else {
            return URL(fileURLWithPath: "/")
        }
        return URL(fileURLWithPath: homeDirectoryPath)
    }

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
                environment: environmentForToolVersionCommands(),
                workingDirectory: workingDirectoryForToolVersionCommands()
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
    ///
    /// `nonisolated` because it touches no shared state and is deliberately
    /// blocking: every caller runs it off the main actor, and `AppInventoryService`
    /// calls it from a detached task while scanning for installed apps.
    nonisolated static func runCommand(
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
