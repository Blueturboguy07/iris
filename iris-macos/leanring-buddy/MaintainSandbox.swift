//
//  MaintainSandbox.swift
//  leanring-buddy
//
//  The jail Tier C's exploration and edits run inside. Novel-fix commands
//  come from a model reasoning over the user's own repo, so the risk gate is
//  not enough on its own; the sandbox is the compensating boundary.
//
//  The headless harness and the Iris Test app both use the Seatbelt profile
//  below. Ordinary Iris keeps the historical helper for its explicit
//  low-level harness checks, but its regular runner remains unchanged.
//

import Foundation
import Darwin

nonisolated enum MaintainSandbox {

    /// A runtime policy for the process that will run one command. The Test
    /// policy carries its registry check instead of consulting mutable global
    /// state, so a focused probe can exercise the same path safely.
    struct TestProcessPolicy: Sendable {
        let scratchDirectoryPath: String
        let additionalReadOnlyPaths: [String]
        /// Direct Rust toolchain bins are selected without consulting the
        /// reader's Cargo/Rustup configuration. They are kept separately so
        /// the child environment can use the real binaries rather than the
        /// `~/.cargo/bin` rustup shims.
        let rustToolchainBinPaths: [String]
        let repositoryIsRegistered: @Sendable (String) -> Bool

        init(
            scratchDirectoryPath: String,
            additionalReadOnlyPaths: [String] = [],
            repositoryIsRegistered: @escaping @Sendable (String) -> Bool
        ) {
            self.scratchDirectoryPath = scratchDirectoryPath
            let directRustBins = MaintainSandbox.discoveredRustToolchainBinPaths()
            self.rustToolchainBinPaths = directRustBins
            self.additionalReadOnlyPaths = MaintainSandbox.uniquePaths(
                additionalReadOnlyPaths + directRustBins.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path
                }
            )
            self.repositoryIsRegistered = repositoryIsRegistered
        }
    }

    enum ProcessPolicy: Sendable {
        case ordinary
        case headless
        case test(TestProcessPolicy)
        /// A Test-configured executable with the wrong runtime bundle must
        /// fail closed rather than silently taking the ordinary path.
        case unavailable
    }

    /// The policy selected by the caller's build. `IRIS_TEST_BUILD` is set only
    /// on the Iris Test configuration. The exact bundle check is still needed:
    /// a copied or misnamed executable must not acquire Test privileges.
    static func runtimeProcessPolicy() -> ProcessPolicy {
#if IRIS_HARNESS_HEADLESS
        return .headless
#elseif IRIS_TEST_BUILD
        guard IrisTestEnvironment.isEnabled,
              let scratchDirectoryPath = prepareTestScratchDirectory() else {
            return .unavailable
        }
        let toolchainPaths = [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/private/etc",
            "/private/var/select",
            "/private/var/db",
            "/opt/homebrew",
            "/usr/local",
            "/Library/Developer",
            "/Applications/Xcode.app",
            "/dev",
        ]
        return .test(TestProcessPolicy(
            scratchDirectoryPath: scratchDirectoryPath,
            additionalReadOnlyPaths: toolchainPaths,
            repositoryIsRegistered: { candidate in
                guard IrisTestEnvironment.isEnabled,
                      let canonical = canonicalExistingDirectory(candidate),
                      canonical == candidate else { return false }
                // `projects()` performs the full bounded manifest validation.
                // Do not call `permitsEdit` here: that would reload the
                // mutable manifest a second time and widen a check/use race.
                return IrisTestProjectRegistry.projects().contains { project in
                    project.clonePath == candidate
                }
            }
        ))
#else
        return .ordinary
#endif
    }

    /// Pure-policy entry point for focused tests and trusted callers that have
    /// already established a disposable registry. No runtime bundle lookup is
    /// performed for this explicit policy.
    static func testProcessPolicy(
        scratchDirectoryPath: String,
        additionalReadOnlyPaths: [String] = [],
        repositoryIsRegistered: @escaping @Sendable (String) -> Bool
    ) -> ProcessPolicy {
        .test(TestProcessPolicy(
            scratchDirectoryPath: scratchDirectoryPath,
            additionalReadOnlyPaths: additionalReadOnlyPaths,
            repositoryIsRegistered: repositoryIsRegistered
        ))
    }

    /// The kernel-canonical path, via realpath(3). Seatbelt enforces on the
    /// fully-resolved real path. Foundation's symlink resolution has different
    /// behavior for macOS's /private aliases, so this uses the kernel result.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Returns a canonical existing directory. A missing path is not a safe
    /// working directory for the Test process because a later mkdir could
    /// replace a validated path with a symlink.
    static func canonicalExistingDirectory(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value == 0 }),
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return canonical
    }

    /// Finds direct, already-installed Rust toolchain binaries without
    /// sourcing `.cargo/env` or reading Cargo/Rustup settings. The Test
    /// process still receives scratch `CARGO_HOME` and `RUSTUP_HOME`; only the
    /// selected toolchain's executable tree is granted read access.
    ///
    /// Reject aliased toolchain roots and bins instead of following a link
    /// into a broader directory and granting that directory read access.
    static func discoveredRustToolchainBinPaths(
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        let fileManager = FileManager.default
        let toolchainsPath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".rustup", isDirectory: true)
            .appendingPathComponent("toolchains", isDirectory: true)
            .path
        guard let canonicalToolchains = canonicalExistingDirectory(toolchainsPath),
              canonicalToolchains == toolchainsPath,
              let entries = try? fileManager.contentsOfDirectory(atPath: canonicalToolchains) else {
            return []
        }

        let sortedEntries = entries.sorted { lhs, rhs in
            let lhsStable = lhs.hasPrefix("stable-")
            let rhsStable = rhs.hasPrefix("stable-")
            if lhsStable != rhsStable { return lhsStable }
            return lhs < rhs
        }
        let candidates: [String] = sortedEntries.compactMap { entry -> String? in
            let candidateRoot = URL(fileURLWithPath: canonicalToolchains)
                .appendingPathComponent(entry, isDirectory: true)
            guard let canonicalRoot = canonicalExistingDirectory(candidateRoot.path),
                  canonicalRoot == candidateRoot.path,
                  isDescendant(canonicalRoot, of: canonicalToolchains) else {
                return nil
            }
            let candidateBin = URL(fileURLWithPath: canonicalRoot)
                .appendingPathComponent("bin", isDirectory: true)
            guard let canonicalBin = canonicalExistingDirectory(candidateBin.path),
                  canonicalBin == candidateBin.path,
                  isDescendant(canonicalBin, of: canonicalToolchains),
                  isExecutableDirectFile(atPath: canonicalBin + "/cargo"),
                  isExecutableDirectFile(atPath: canonicalBin + "/rustc") else {
                return nil
            }
            return canonicalBin
        }
        // Keep the grant narrow and deterministic. A project that needs a
        // different Rust toolchain must declare that prerequisite explicitly;
        // Test never exposes every user-installed toolchain to a command.
        return Array(candidates.prefix(1))
    }

    private static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor + "/")
    }

    private static func isExecutableDirectFile(atPath path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard canonical == path else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && canonical.hasPrefix(parent + "/")
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Re-check a repository against the policy immediately before a command
    /// is spawned. The Test path requires a canonical spelling as well as an
    /// exact registered project; an alias through a symlink is not accepted.
    static func repositoryIsAllowed(_ repoRootPath: String, under policy: ProcessPolicy) -> Bool {
        switch policy {
        case .test(let testPolicy):
            guard let canonical = canonicalExistingDirectory(repoRootPath),
                  URL(fileURLWithPath: repoRootPath).standardizedFileURL.path == canonical else {
                return false
            }
            return testPolicy.repositoryIsRegistered(canonical)
        case .headless, .ordinary:
            return true
        case .unavailable:
            return false
        }
    }

    /// A Seatbelt profile for the historical headless and explicit harness
    /// checks. This shape is retained so the existing headless fixture stays
    /// behaviorally identical, including its source-tree read denial.
    private static func legacyProfile(repoRootPath: String) -> String {
        let root = canonicalPath(repoRootPath)
#if IRIS_HARNESS_HEADLESS
        let tempDir = canonicalPath(HarnessFixtureEnvironment.scratchDirectory.path)
#else
        let tempDir = canonicalPath(NSTemporaryDirectory())
#endif
        var profile = """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec)
        ; Test runners may stop their own workers, not unrelated processes.
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow file-read*)
        (allow process-info-pidinfo)
        (allow process-info-listpids)
        (deny network*)
        (allow file-write*
          (subpath \(seatbeltLiteral(root)))
          (subpath \(seatbeltLiteral(tempDir)))
          (subpath "/dev"))
        """
#if IRIS_HARNESS_HEADLESS
        // The held-out oracle remains outside the disposable clone. Also
        // prevent source commands from searching the lab for the answer.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let escapedRoot = seatbeltLiteral(canonicalPath(sourceRoot))
        profile += "\n(deny file-read* (subpath \(escapedRoot)))\n"
#endif
        return profile
    }

    /// The Test profile is intentionally narrower than the legacy profile:
    /// there is no broad file-read or mach-lookup grant. Only the current
    /// registered clone, the Test command scratch, and explicit system/toolchain
    /// paths are readable. Writes are limited to the clone, scratch and /dev.
    private static func testProfile(
        repoRootPath: String, policy: TestProcessPolicy
    ) -> String {
        let root = canonicalPath(repoRootPath)
        let scratch = canonicalPath(policy.scratchDirectoryPath)
        var readPaths = [root, scratch] + policy.additionalReadOnlyPaths
        var seen = Set<String>()
        readPaths = readPaths.compactMap { path in
            let canonical = canonicalPath(path)
            return seen.insert(canonical).inserted ? canonical : nil
        }
        let ancestorPaths = readPaths
            .flatMap { ancestorDirectories(for: $0) }
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }
        let ancestorClauses = ancestorPaths
            .map { "  (literal \(seatbeltLiteral($0)))" }
            .joined(separator: "\n")
        let readClauses = readPaths.map { "  (subpath \(seatbeltLiteral($0)))" }.joined(separator: "\n")
        let writePaths = [root, scratch, "/dev"]
            .map { "  (subpath \(seatbeltLiteral(canonicalPath($0))))" }
            .joined(separator: "\n")
        return """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec)
        ; Test runners may stop their own workers, not unrelated processes.
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow process-info-pidinfo)
        (allow process-info-listpids)
        ; Path resolution needs metadata on each allowed path's parent, but
        ; these literals grant no read-data access to the parent directories.
        (allow file-read-metadata
        \(ancestorClauses)
        )
        ; The dynamic loader and zsh need the root directory's metadata while
        ; resolving absolute paths. This grants only "/" itself; contents
        ; remain constrained by the subpath clauses below.
        (allow file-read* (literal "/"))
        (allow file-read*
        \(readClauses)
        )
        (deny network*)
        ; Desktop integration tests run their own local HTTP servers. This
        ; permits loopback only, never remote downloads or external services.
        (allow network-bind (local ip "localhost:*"))
        (allow network-inbound (local ip "localhost:*"))
        (allow network-outbound (remote ip "localhost:*"))
        (allow file-write*
        \(writePaths)
        )
        """
    }

    private static func ancestorDirectories(for path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        var result = [String("/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// Returns a profile string for existing callers. A misidentified Test
    /// process gets a deny-default profile rather than the ordinary broad-read
    /// profile; `jailedInvocation` itself returns nil in that case.
    static func writeConfinedNoNetworkProfile(repoRootPath: String) -> String {
        switch runtimeProcessPolicy() {
        case .test(let policy):
            guard repositoryIsAllowed(repoRootPath, under: .test(policy)) else {
                return denyAllProfile()
            }
            return testProfile(repoRootPath: repoRootPath, policy: policy)
        case .headless, .ordinary:
            return legacyProfile(repoRootPath: repoRootPath)
        case .unavailable:
            return denyAllProfile()
        }
    }

    /// Wraps a command so it runs under the selected profile. The profile is
    /// written under the selected scratch directory with O_NOFOLLOW. Passing
    /// an explicit policy is useful for pure probes; the default is the current
    /// build's policy, including the live Test registry check.
    static func jailedInvocation(
        forCommand commandText: String,
        repoRootPath: String,
        policy explicitPolicy: ProcessPolicy? = nil
    ) -> (invocation: String, profilePath: String)? {
        guard !commandText.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        guard isAvailable else { return nil }
        let policy = explicitPolicy ?? runtimeProcessPolicy()
        guard repositoryIsAllowed(repoRootPath, under: policy) else { return nil }
        let canonicalRoot = canonicalPath(repoRootPath)

        let profile: String
        switch policy {
        case .test(let testPolicy):
            profile = testProfile(repoRootPath: canonicalRoot, policy: testPolicy)
        case .headless, .ordinary:
            profile = legacyProfile(repoRootPath: canonicalRoot)
        case .unavailable:
            return nil
        }

        let profileDirectoryPath: String
        switch policy {
        case .test(let testPolicy):
            profileDirectoryPath = testPolicy.scratchDirectoryPath
        case .headless:
#if IRIS_HARNESS_HEADLESS
            profileDirectoryPath = HarnessFixtureEnvironment.scratchDirectory.path
#else
            // An explicit HEADLESS policy is meaningful only in the fixture
            // host. Never silently turn it into an ordinary process here.
            return nil
#endif
        case .ordinary:
            profileDirectoryPath = NSTemporaryDirectory()
        case .unavailable:
            return nil
        }
        let requireCanonicalDirectorySpelling: Bool
        if case .test = policy {
            requireCanonicalDirectorySpelling = true
        } else {
            // Keep the historical /tmp <-> /private/tmp alias behavior for
            // ordinary and HEADLESS callers.
            requireCanonicalDirectorySpelling = false
        }
        guard let profilePath = writeProfile(
            profile,
            inDirectory: profileDirectoryPath,
            requireCanonicalDirectorySpelling: requireCanonicalDirectorySpelling
        ) else {
            return nil
        }
        let innerShell: String
        if case .test = policy {
            innerShell = "/bin/zsh -f -c"
        } else {
            innerShell = "/bin/zsh -c"
        }
        return (
            "/usr/bin/sandbox-exec -f \(shellSingleQuoted(profilePath)) \(innerShell) \(shellSingleQuoted(commandText))",
            profilePath
        )
    }

    /// True when sandbox-exec is present. Its absence must degrade to a
    /// refusal for Test/HEADLESS callers rather than an unjailed process.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }

    /// Test's child environment is built from scratch. In particular, HOME is
    /// the command scratch, not the reader's home, and Git/npm/Cargo config
    /// locations do not inherit user files or credentials.
    static func testProcessEnvironment(for policy: TestProcessPolicy) -> [String: String] {
        let scratch = policy.scratchDirectoryPath
        func child(_ name: String) -> String { (scratch as NSString).appendingPathComponent(name) }
        let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        let directRustPath = policy.rustToolchainBinPaths.joined(separator: ":")
        let commandPath = directRustPath.isEmpty ? systemPath : directRustPath + ":" + systemPath
        var environment = [
            "PATH": commandPath,
            "HOME": scratch,
            "TMPDIR": scratch,
            "XDG_CONFIG_HOME": child("config"),
            "XDG_CACHE_HOME": child("cache"),
            "XDG_DATA_HOME": child("data"),
            "NPM_CONFIG_USERCONFIG": child("npmrc"),
            "npm_config_cache": child("npm-cache"),
            "CARGO_HOME": child("cargo"),
            "RUSTUP_HOME": child("rustup"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "LANG": "en_US.UTF-8",
        ]
        // Finder launches do not carry a shell's developer-tool selection.
        // Use a known, read-only toolchain directly instead of asking Apple's
        // /usr/bin/git shim to resolve a denied /var/select symlink in the jail.
        var firstGitDeveloper: String?
        for developer in ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"] {
            let binaries = developer + "/usr/bin"
            if FileManager.default.isExecutableFile(atPath: binaries + "/git") {
                if firstGitDeveloper == nil, canonicalExistingDirectory(developer) == developer {
                    firstGitDeveloper = developer
                }
                // The SDK/linker shims consult machine state unavailable in
                // Test's jail and can falsely report an unaccepted license.
                // Select files inside the already permitted developer tree;
                // this adds no read grant and does not alter license state.
                let commandLineTools = developer == "/Library/Developer/CommandLineTools"
                let sdk = developer + (commandLineTools
                    ? "/SDKs/MacOSX.sdk"
                    : "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
                let clang = developer + (commandLineTools
                    ? "/usr/bin/clang"
                    : "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
                let archiver = developer + (commandLineTools
                    ? "/usr/bin/ar"
                    : "/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar")
                guard canonicalExistingDirectory(developer) == developer,
                      let canonicalSDK = canonicalExistingDirectory(sdk),
                      isDescendant(canonicalSDK, of: developer),
                      isExecutableDirectFile(atPath: clang),
                      isExecutableDirectFile(atPath: archiver) else { continue }
                environment["DEVELOPER_DIR"] = developer
                environment["PATH"] = binaries + ":" + environment["PATH", default: systemPath]
                environment["SDKROOT"] = canonicalSDK
                environment["CC"] = clang
                environment["AR"] = archiver
                environment["CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"] = clang
                environment["CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER"] = clang
                break
            }
        }
        // Keep Git-only tasks usable if neither installation has a complete
        // SDK, but do not let incomplete Xcode hide a complete CLT candidate.
        if environment["DEVELOPER_DIR"] == nil, let developer = firstGitDeveloper {
            environment["DEVELOPER_DIR"] = developer
            environment["PATH"] = developer + "/usr/bin:" + environment["PATH", default: systemPath]
        }
        if let directRustBin = policy.rustToolchainBinPaths.first {
            // Keep Rust resolution independent of any rustup shim or config.
            // Cargo/Rustup homes remain scratch-only even though this points
            // at a preinstalled, read-only toolchain.
            environment["RUSTC"] = directRustBin + "/rustc"
            let rustdoc = directRustBin + "/rustdoc"
            if isExecutableDirectFile(atPath: rustdoc) {
                environment["RUSTDOC"] = rustdoc
            }
        }
        return environment
    }

    /// Headless environment retained as a named helper so the runner's process
    /// setup remains visibly identical to the existing fixture host.
    static func headlessProcessEnvironment() -> [String: String] {
#if IRIS_HARNESS_HEADLESS
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TMPDIR": HarnessFixtureEnvironment.scratchDirectory.path,
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
#else
        // The runner rejects an explicit HEADLESS policy outside the fixture
        // host before this can be used; keep a harmless definition for the
        // exhaustive switch in the shared source file.
        [:]
#endif
    }

    private static func prepareTestScratchDirectory() -> String? {
#if IRIS_TEST_BUILD
        let fileManager = FileManager.default
        let scratchURL = IrisTestEnvironment.commandScratchDirectory.standardizedFileURL
        do {
            try fileManager.createDirectory(at: scratchURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                          ofItemAtPath: scratchURL.path)
        } catch {
            return nil
        }
        guard let canonical = canonicalExistingDirectory(scratchURL.path),
              canonical == scratchURL.path else { return nil }
        return canonical
#else
        return nil
#endif
    }

    private static func denyAllProfile() -> String {
        "(version 1)\n(deny default)\n"
    }

    private static func writeProfile(
        _ profile: String,
        inDirectory directoryPath: String,
        requireCanonicalDirectorySpelling: Bool = false
    ) -> String? {
        let standardizedDirectory = URL(fileURLWithPath: directoryPath).standardizedFileURL.path
        guard let canonicalDirectory = canonicalExistingDirectory(directoryPath) else { return nil }
        if requireCanonicalDirectorySpelling && canonicalDirectory != standardizedDirectory {
            return nil
        }
        let profilePath = URL(fileURLWithPath: canonicalDirectory, isDirectory: true)
            .appendingPathComponent("iris-sandbox-\(UUID().uuidString).sb").path
        let descriptor = open(profilePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(profile.utf8))
            try handle.synchronize()
            try handle.close()
            return profilePath
        } catch {
            try? handle.close()
            _ = unlink(profilePath)
            return nil
        }
    }

    /// Seatbelt string literals are not shell strings. Escape every character
    /// that could terminate or alter a quoted profile path.
    static func seatbeltLiteral(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: escaped += "\\\\"
            case 0x22: escaped += "\\\""
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x09: escaped += "\\t"
            case 0x00...0x1F:
                escaped += String(format: "\\\\%03o", Int(scalar.value))
            default:
                escaped.append(String(scalar))
            }
        }
        escaped += "\""
        return escaped
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
