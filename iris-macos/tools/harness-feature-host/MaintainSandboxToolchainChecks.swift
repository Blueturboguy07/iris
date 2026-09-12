import Foundation

@testable import IrisHarnessNative

/// Verifies that Test's isolated environment can use an installed Rust
/// toolchain without inheriting the reader's Cargo/Rustup state. The fixture
/// has no dependencies, so this is a toolchain preflight rather than a
/// PlantGPT build or a registry-cache test.
@main
struct MaintainSandboxToolchainChecks {
    static func main() async throws {
        let fileManager = FileManager.default
        // Test policy requires the lexical repository path to already be
        // kernel-canonical. `/private/tmp` is canonical for Seatbelt but
        // Foundation standardizes it back to `/tmp`, so use the existing
        // A fresh temporary parent keeps this disposable fixture independent
        // from any installed application's command-scratch state.
        let fixtureBaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-maintain-toolchain-parent-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = fixtureBaseURL
            .appendingPathComponent("iris-maintain-toolchain-check-\(UUID().uuidString)", isDirectory: true)
        let scratchURL = fixtureURL.appendingPathComponent("scratch", isDirectory: true)
        let sourceURL = fixtureURL.appendingPathComponent("src", isDirectory: true)
        let outsideSentinelURL = fixtureBaseURL
            .appendingPathComponent("iris-maintain-toolchain-sentinel-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureURL) }
        defer { try? fileManager.removeItem(at: outsideSentinelURL) }
        try Data("credential-canary-must-stay-outside\n".utf8).write(to: outsideSentinelURL)
        try checkDiscoveryAliases(under: fixtureURL)

        let root = MaintainSandbox.canonicalPath(fixtureURL.path)
        let scratch = MaintainSandbox.canonicalPath(scratchURL.path)
        let toolchainBins = MaintainSandbox.discoveredRustToolchainBinPaths()
        guard let directToolchainBin = toolchainBins.first else {
            throw failure("no direct Rust toolchain with cargo and rustc was discovered")
        }

        let cargoManifest = """
        [package]
        name = "iris_toolchain_fixture"
        version = "0.1.0"
        edition = "2021"
        """
        try Data(cargoManifest.utf8).write(to: fixtureURL.appendingPathComponent("Cargo.toml"))
        try Data("fn main() { println!(\"iris-toolchain-fixture\"); }\n".utf8)
            .write(to: sourceURL.appendingPathComponent("main.rs"))
        let compilerSourceURL = sourceURL.appendingPathComponent("direct-cc-probe.m")
        let compilerObjectURL = scratchURL.appendingPathComponent("direct-cc-probe.o")
        try Data("""
        @interface IrisHarnessCompilerProbe
        @end
        @implementation IrisHarnessCompilerProbe
        @end
        """.utf8).write(to: compilerSourceURL)
        let compilerArchiveURL = scratchURL.appendingPathComponent("libdirect-cc-probe.a")

        let policy = MaintainSandbox.testProcessPolicy(
            scratchDirectoryPath: scratch,
            additionalReadOnlyPaths: [
                "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                "/Library/Developer", "/Applications/Xcode.app", "/dev",
            ],
            repositoryIsRegistered: { $0 == root }
        )
        guard case .test(let testPolicy) = policy else {
            throw failure("unexpected non-Test policy")
        }
        let environment = MaintainSandbox.testProcessEnvironment(for: testPolicy)
        guard environment["HOME"] == scratch,
              environment["CARGO_HOME"] == scratch + "/cargo",
              environment["RUSTUP_HOME"] == scratch + "/rustup" else {
            throw failure("Cargo/Rustup homes escaped command scratch")
        }
        let pathEntries = environment["PATH", default: ""].split(separator: ":").map(String.init)
        let directRustIndex = pathEntries.firstIndex(of: directToolchainBin)
        let systemBinIndex = pathEntries.firstIndex(of: "/usr/bin")
        guard directRustIndex != nil,
              systemBinIndex != nil,
              directRustIndex! < systemBinIndex!,
              !pathEntries.contains(where: { $0.hasSuffix("/.cargo/bin") }),
              environment["RUSTC"] == directToolchainBin + "/rustc" else {
            throw failure("direct Rust binaries were not selected ahead of user shims")
        }
        let toolchainRoot = URL(fileURLWithPath: directToolchainBin)
            .deletingLastPathComponent().path
        guard testPolicy.additionalReadOnlyPaths.contains(toolchainRoot) else {
            throw failure("selected toolchain root was not granted read-only access")
        }
        guard let directCompiler = environment["CC"],
              let directArchiver = environment["AR"],
              let sdkRoot = environment["SDKROOT"],
              directCompiler == environment["CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER"],
              directCompiler == environment["CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER"],
              fileManager.isExecutableFile(atPath: directCompiler),
              fileManager.isExecutableFile(atPath: directArchiver),
              MaintainSandbox.canonicalPath(directCompiler) == directCompiler,
              MaintainSandbox.canonicalPath(directArchiver) == directArchiver,
              MaintainSandbox.canonicalExistingDirectory(sdkRoot) == sdkRoot else {
            throw failure("Test environment did not select canonical direct clang, ar and SDK")
        }

        guard MaintainSandbox.repositoryIsAllowed(root, under: policy) else {
            let standardized = URL(fileURLWithPath: root).standardizedFileURL.path
            let canonical = MaintainSandbox.canonicalExistingDirectory(root) ?? "<missing>"
            throw failure("fixture registration failed: root=\(root) standardized=\(standardized) canonical=\(canonical)")
        }
        let runner = try MaintainShellRunner(repoRootPath: root, processPolicy: policy)
        let readDenied = try await runner.run(
            "if /bin/cat \(shellQuote(outsideSentinelURL.path)) >/dev/null 2>&1; then exit 41; else echo read-denied; fi",
            deadline: 15
        )
        guard readDenied.succeeded,
              readDenied.outputTail.contains("read-denied"),
              !readDenied.outputTail.contains("credential-canary") else {
            throw failure("outside credential sentinel was readable in Test sandbox")
        }
        print("PASS outside credential sentinel read denied")
        let writeDenied = try await runner.run(
            "if /usr/bin/touch \(shellQuote(outsideSentinelURL.path + ".write")) >/dev/null 2>&1; then exit 42; else echo write-denied; fi",
            deadline: 15
        )
        guard writeDenied.succeeded,
              writeDenied.outputTail.contains("write-denied"),
              !fileManager.fileExists(atPath: outsideSentinelURL.path + ".write") else {
            throw failure("outside sentinel path was writable in Test sandbox")
        }
        print("PASS outside sentinel write denied")
        let directCompilerResult = try await runner.run(
            "test \"$CC\" = " + shellQuote(directCompiler) + " && "
                + "test \"$SDKROOT\" = " + shellQuote(sdkRoot) + " && "
                + "\"$CC\" -isysroot \"$SDKROOT\" -x objective-c -c "
                + shellQuote(compilerSourceURL.path) + " -o " + shellQuote(compilerObjectURL.path),
            deadline: 30
        )
        guard directCompilerResult.succeeded,
              fileManager.fileExists(atPath: compilerObjectURL.path) else {
            throw failure("sandboxed direct CC Objective-C compile failed: " + directCompilerResult.outputTail)
        }
        print("PASS Test-policy direct CC Objective-C compile")
        let directArchiverResult = try await runner.run(
            "test \"$AR\" = " + shellQuote(directArchiver) + " && "
                + "\"$AR\" rcs " + shellQuote(compilerArchiveURL.path)
                + " " + shellQuote(compilerObjectURL.path),
            deadline: 30
        )
        guard directArchiverResult.succeeded,
              fileManager.fileExists(atPath: compilerArchiveURL.path) else {
            throw failure("sandboxed direct AR archive failed: " + directArchiverResult.outputTail)
        }
        print("PASS Test-policy direct AR archive")
        // Default acceptance includes linking and executing. A narrower check
        // must be requested explicitly and must not mask a linker regression.
        let cargoAction = CommandLine.arguments.contains("--check-only") ? "check" : "build"
        let result = try await runner.run(
            "command -v cargo && command -v rustc && cargo --version && rustc --version && cargo \(cargoAction) --offline",
            deadline: 120
        )
        print("cargo/rustc paths: \(toolchainBins.joined(separator: ", "))")
        print(result.outputTail)
        guard result.succeeded else {
            print("FAIL isolated cargo \(cargoAction): exit=\(result.exitCode) timedOut=\(result.timedOut)")
            exit(1)
        }
        guard fileManager.fileExists(atPath: fixtureURL.appendingPathComponent("target/debug/deps").path) else {
            throw failure("cargo did not produce dependency-free check artifacts")
        }
        if cargoAction == "build" {
            let execution = try await runner.run("./target/debug/iris_toolchain_fixture", deadline: 15)
            guard execution.succeeded,
                  execution.outputTail.trimmingCharacters(in: .whitespacesAndNewlines) == "iris-toolchain-fixture" else {
                throw failure("the linked disposable binary did not execute successfully")
            }
            print("PASS linked disposable Rust binary runs inside Test policy")
        }
        print("PASS isolated Test-policy direct Rust toolchain cargo \(cargoAction)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "maintain-sandbox-toolchain-checks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func checkDiscoveryAliases(under fixture: URL) throws {
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("discovery-home")
        let toolchains = home.appendingPathComponent(".rustup/toolchains")
        let toolchain = toolchains.appendingPathComponent("stable-fixture")
        let bin = toolchain.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["cargo", "rustc"] {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        guard MaintainSandbox.discoveredRustToolchainBinPaths(homeDirectory: home.path) == [bin.path] else {
            throw failure("direct disposable toolchain was not discovered")
        }
        let alternateBin = toolchains.appendingPathComponent("alternate-bin")
        try fm.moveItem(at: bin, to: alternateBin)
        try fm.createSymbolicLink(at: bin, withDestinationURL: alternateBin)
        guard MaintainSandbox.discoveredRustToolchainBinPaths(homeDirectory: home.path).isEmpty else {
            throw failure("a symlinked bin broadened the toolchain read grant")
        }
        try fm.removeItem(at: bin)
        try fm.moveItem(at: alternateBin, to: bin)
        let relocated = home.appendingPathComponent("relocated-toolchains")
        try fm.moveItem(at: toolchains, to: relocated)
        try fm.createSymbolicLink(at: toolchains, withDestinationURL: relocated)
        guard MaintainSandbox.discoveredRustToolchainBinPaths(homeDirectory: home.path).isEmpty else {
            throw failure("an aliased top-level toolchains directory was accepted")
        }
        print("PASS direct discovery and aliased toolchain/bin rejection")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
