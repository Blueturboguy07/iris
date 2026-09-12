import Foundation

// Only the explicit Test process policy is exercised. No login shell runs.
enum LoginShellEnvironment {
    static func environmentForChildProcesses() -> [String: String] { [:] }
}

@main
struct IrisTestGitPreflightChecks {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["IRIS_TEST_PROJECT_ROOT"],
              let scratchBase = environment["IRIS_TEST_COMMAND_SCRATCH"],
              root.hasPrefix("/"), scratchBase.hasPrefix("/") else {
            throw NSError(domain: "test-git-preflight", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "IRIS_TEST_PROJECT_ROOT and IRIS_TEST_COMMAND_SCRATCH are required"])
        }
        let scratchURL = URL(fileURLWithPath: scratchBase)
            .appendingPathComponent("iris-test-git-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: MaintainSandbox.canonicalPath(scratchURL.path))
        defer { try? FileManager.default.removeItem(at: scratch) }
        let policy = MaintainSandbox.testProcessPolicy(scratchDirectoryPath: scratch.path,
            additionalReadOnlyPaths: ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                "/Library/Developer", "/Applications/Xcode.app", "/dev"],
            repositoryIsRegistered: { $0 == root })
        let runner = try MaintainShellRunner(repoRootPath: root, processPolicy: policy)
        for command in ["git --version", "git status --porcelain", "git rev-parse HEAD",
                        "git var GIT_AUTHOR_IDENT >/dev/null", "git var GIT_COMMITTER_IDENT >/dev/null"] {
            let result = try await runner.run(command, deadline: 15)
            print("\(command): exit=\(result.exitCode) dropped=\(result.bytesDroppedBeforeTail) \(result.outputTail)")
            guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
                throw NSError(domain: "test-git-preflight", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(command): \(result.outputTail)"])
            }
            if command == "git status --porcelain", !result.outputTail.isEmpty {
                throw NSError(domain: "fixture-not-clean", code: 1)
            }
        }
        print("PASS real Test-policy Git inspection, clean clone, no writes to project")
    }
}
