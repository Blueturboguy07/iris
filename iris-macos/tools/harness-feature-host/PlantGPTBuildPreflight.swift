import Foundation
import Darwin
@testable import IrisHarnessNative

/// Runs the already-reviewed PlantGPT build, without an editor or delivery.
/// Uses the actual Test command scratch and the same explicit Test policy.
@main
struct PlantGPTBuildPreflight {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["IRIS_TEST_PLANTGPT_ROOT"],
              let scratch = environment["IRIS_TEST_COMMAND_SCRATCH"],
              let registryPath = environment["IRIS_TEST_REGISTRY_PATH"],
              root.hasPrefix("/"), scratch.hasPrefix("/"), registryPath.hasPrefix("/") else {
            throw NSError(domain: "plantgpt-preflight", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "IRIS_TEST_PLANTGPT_ROOT, IRIS_TEST_COMMAND_SCRATCH, and IRIS_TEST_REGISTRY_PATH are required"])
        }
        let registry = URL(fileURLWithPath: registryPath)
        let registrySnapshot = try Data(contentsOf: registry)
        let entries = try JSONSerialization.jsonObject(with: registrySnapshot) as? [[String: Any]]
        guard entries?.contains(where: { $0["clonePath"] as? String == root }) == true else {
            throw NSError(domain: "PlantGPTBuildPreflight", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PlantGPT Test clone is not registered"])
        }
        let policy = MaintainSandbox.testProcessPolicy(
            scratchDirectoryPath: scratch,
            additionalReadOnlyPaths: ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                "/Library/Developer", "/Applications/Xcode.app", "/dev"],
            repositoryIsRegistered: {
                $0 == root && (try? Data(contentsOf: registry)) == registrySnapshot
            }
        )
        let runner = try MaintainShellRunner(repoRootPath: root, processPolicy: policy)
        let status = try await runner.run("git status --porcelain --untracked-files=all", deadline: 15)
        guard OnDemandEditCoordinator.repositoryStatusWasRead(status), status.outputTail.isEmpty else {
            throw NSError(domain: "PlantGPTBuildPreflight", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Test source is not clean; no build started"])
        }
        let tools = try await runner.run("command -v cargo && cargo --version && rustc --version", deadline: 15)
        print("TOOLCHAIN exit=\(tools.exitCode) timedOut=\(tools.timedOut)\n\(tools.outputTail)")
        guard tools.succeeded else { Darwin.exit(1) }
        let result = try await runner.run(
            "npm run build && cargo build --release --manifest-path src-tauri/Cargo.toml", deadline: 900)
        print("FULL BUILD exit=\(result.exitCode) timedOut=\(result.timedOut) dropped=\(result.bytesDroppedBeforeTail)\n\(result.outputTail)")
        let finalStatus = try await runner.run("git status --porcelain --untracked-files=all", deadline: 15)
        let clean = OnDemandEditCoordinator.repositoryStatusWasRead(finalStatus) && finalStatus.outputTail.isEmpty
        print("SOURCE CLEAN=\(clean); no model, packaging, installation or app launch performed")
        Darwin.exit(result.succeeded && clean ? 0 : 1)
    }
}
