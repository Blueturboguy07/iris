//
// Focused Test-process containment probe. This file is intentionally not part
// of the app target; compile it with MaintainSandbox.swift and
// MaintainShellRunner.swift when reviewing the Test-only policy.
//

import Darwin
import Foundation

// Keep this probe independent of the app's login-shell capture machinery.
enum LoginShellEnvironment {
    static func environmentForChildProcesses() -> [String: String] { [:] }
}

private final class RegistryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func close() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

@main
struct TestContainmentProbe {
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func waitForFile(_ url: URL, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func startLocalListener(portFile: URL, hitFile: URL) -> (process: Process, port: Int)? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import socket, sys
            listener = socket.socket()
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            with open(sys.argv[1], "w") as output:
                output.write(str(listener.getsockname()[1]))
            listener.settimeout(4)
            try:
                client, _ = listener.accept()
                with open(sys.argv[2], "w") as output:
                    output.write("connected")
                client.close()
            except Exception:
                pass
            """,
            portFile.path,
            hitFile.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        guard waitForFile(portFile),
              let port = Int((try? String(contentsOf: portFile, encoding: .utf8)) ?? "") else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return nil
        }
        return (process, port)
    }

    private static func run(
        _ runner: MaintainShellRunner,
        _ command: String,
        deadline: TimeInterval = 10
    ) async throws -> MaintainCommandResult {
        try await runner.run(command, deadline: deadline)
    }

    private static func safeOutput(_ output: String, basePath: String) -> String {
        output.replacingOccurrences(of: basePath, with: "<fixture>")
            .replacingOccurrences(of: "FAKE-CANARY-DO-NOT-USE", with: "<fake-canary>")
    }

    static func main() async {
        let fileManager = FileManager.default
        // Keep every fake secret/canary under the private campaign fixture
        // directory. A source-controlled path also avoids Foundation's
        // /private/tmp -> /tmp spelling alias while exercising spaces in
        // Seatbelt and shell literals.
        guard let fixtureRootPath = ProcessInfo.processInfo.environment["IRIS_CONTAINMENT_FIXTURE_ROOT"],
              fixtureRootPath.hasPrefix("/") else {
            print("setup=FAIL IRIS_CONTAINMENT_FIXTURE_ROOT is required")
            Darwin.exit(2)
        }
        let fixtureRoot = URL(fileURLWithPath: fixtureRootPath, isDirectory: true)
        let base = fixtureRoot
            .appendingPathComponent("private-probe-fixture \(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("registered-clone", isDirectory: true)
        let scratch = base.appendingPathComponent("command-scratch", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        do {
            try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        } catch {
            print("setup=FAIL")
            Darwin.exit(1)
        }

        var failures = 0
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            print("\(name)=\(passed ? "PASS" : "FAIL")\(detail.isEmpty ? "" : " \(detail)")")
            if !passed { failures += 1 }
        }

        let canonicalRepo = MaintainSandbox.canonicalExistingDirectory(repo.path)!
        let canonicalScratch = MaintainSandbox.canonicalExistingDirectory(scratch.path)!
        let gate = RegistryGate()
        let policy = MaintainSandbox.testProcessPolicy(
            scratchDirectoryPath: canonicalScratch,
            additionalReadOnlyPaths: [
                "/System", "/usr", "/bin", "/sbin", "/etc", "/private/var/select", "/dev"
            ],
            repositoryIsRegistered: { candidate in
                gate.isOpen && candidate == canonicalRepo
            }
        )
        record(
            "policy_initially_allows_canonical_repo",
            MaintainSandbox.repositoryIsAllowed(canonicalRepo, under: policy)
        )
        let outsideFile = outside.appendingPathComponent("write-canary.txt")
        let fakeSecret = outside.appendingPathComponent("fake-secret-canary.txt")
        let zshenv = scratch.appendingPathComponent(".zshenv")
        let zshenvMarker = scratch.appendingPathComponent("zshenv-was-sourced")
        try? write("FAKE-CANARY-DO-NOT-USE\n", to: fakeSecret)
        try? write("touch \(quote(zshenvMarker.path))\n", to: zshenv)

        do {
            let runner = try MaintainShellRunner(repoRootPath: canonicalRepo, processPolicy: policy)
            let inside = try await run(
                runner,
                "printf allowed > \(quote(repo.appendingPathComponent("inside.txt").path))"
            )
            record("inside_write", inside.succeeded,
                   "exit=\(inside.exitCode) output=\(safeOutput(inside.outputTail, basePath: base.path))")
            record("inside_write_file",
                   (try? String(contentsOf: repo.appendingPathComponent("inside.txt"), encoding: .utf8)) == "allowed")

            let outsideWrite = try await run(
                runner,
                "printf blocked > \(quote(outsideFile.path))"
            )
            record("outside_write_denied", !outsideWrite.succeeded && !fileManager.fileExists(atPath: outsideFile.path),
                   "exit=\(outsideWrite.exitCode)")

            let outsideRead = try await run(
                runner,
                "test -f \(quote(fakeSecret.path))"
            )
            record("outside_read_denied", !outsideRead.succeeded, "exit=\(outsideRead.exitCode)")

            let sourceBuild = try await run(
                runner,
                "printf '#!/bin/sh\\nexit 0\\n' > build-canary.sh && /bin/sh build-canary.sh"
            )
            record("source_build_canary", sourceBuild.succeeded,
                   "exit=\(sourceBuild.exitCode) output=\(safeOutput(sourceBuild.outputTail, basePath: base.path))")

            let portFile = scratch.appendingPathComponent("listener-port")
            let hitFile = scratch.appendingPathComponent("listener-was-reached")
            if let listener = startLocalListener(portFile: portFile, hitFile: hitFile) {
                defer {
                    if listener.process.isRunning { listener.process.terminate() }
                    listener.process.waitUntilExit()
                }
                let noNetwork = try await run(
                    runner,
                    "curl -sS --max-time 2 http://127.0.0.1:\(listener.port)/ > /dev/null"
                )
                record(
                    "loopback_test_server_reachable",
                    fileManager.fileExists(atPath: hitFile.path),
                    "exit=\(noNetwork.exitCode)"
                )
            } else {
                record("loopback_test_server_reachable", false, "listener setup failed")
            }

            let remoteNetwork = try await run(runner,
                "/usr/bin/perl -MSocket -e 'socket(S, PF_INET, SOCK_STREAM, getprotobyname(\"tcp\")) or die $!; connect(S, sockaddr_in(9, inet_aton(\"192.0.2.1\"))) or die $!;'",
                deadline: 3)
            record("external_network_denied", !remoteNetwork.succeeded
                && remoteNetwork.outputTail.contains("Operation not permitted"),
                "exit=\(remoteNetwork.exitCode)")

            record("startup_rc_not_sourced", !fileManager.fileExists(atPath: zshenvMarker.path))

            let nestedTarget = repo.appendingPathComponent("nested.txt")
            if let nested = MaintainSandbox.jailedInvocation(
                forCommand: "printf nested > \(quote(nestedTarget.path))",
                repoRootPath: canonicalRepo,
                policy: policy
            ) {
                defer { try? fileManager.removeItem(atPath: nested.profilePath) }
                let nestedResult = try await run(runner, nested.invocation)
                record("nested_jail", nestedResult.succeeded
                    && (try? String(contentsOf: nestedTarget, encoding: .utf8)) == "nested",
                    "exit=\(nestedResult.exitCode) output=\(safeOutput(nestedResult.outputTail, basePath: base.path))")
            } else {
                record("nested_jail", false, "invocation unavailable")
            }

            let symlinkRoot = base.appendingPathComponent("repo-alias", isDirectory: true)
            try? fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: repo)
            let symlinkRejected: Bool
            do {
                _ = try MaintainShellRunner(repoRootPath: symlinkRoot.path, processPolicy: policy)
                symlinkRejected = false
            } catch {
                symlinkRejected = true
            }
            record("symlink_repo_rejected", symlinkRejected)

            gate.close()
            do {
                _ = try await run(runner, ":")
                record("registry_rechecked", false, "run unexpectedly allowed")
            } catch {
                record("registry_rechecked", true)
            }
        } catch {
            record("runner_setup", false, String(reflecting: error))
        }

        try? fileManager.removeItem(at: base)
        Darwin.exit(failures == 0 ? 0 : 1)
    }
}
