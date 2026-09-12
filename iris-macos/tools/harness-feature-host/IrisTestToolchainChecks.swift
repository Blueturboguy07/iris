import Foundation
import Darwin
#if IRIS_TEST_TOOLCHAIN_PROBE
enum LoginShellEnvironment {
    static func environmentForChildProcesses() -> [String: String] { [:] }
}
#else
@testable import IrisHarnessNative
#endif

/// Real toolchain smoke on the disposable, staged NitroAI copy. No model call.
@main
struct IrisTestToolchainChecks {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["IRIS_TEST_PROJECT_ROOT"],
              let scratch = environment["IRIS_TEST_COMMAND_SCRATCH"],
              let registryPath = environment["IRIS_TEST_REGISTRY_PATH"],
              root.hasPrefix("/"), scratch.hasPrefix("/"), registryPath.hasPrefix("/") else {
            throw NSError(domain: "test-toolchain", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "IRIS_TEST_PROJECT_ROOT, IRIS_TEST_COMMAND_SCRATCH, and IRIS_TEST_REGISTRY_PATH are required"])
        }
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let policy = MaintainSandbox.testProcessPolicy(
            scratchDirectoryPath: scratch,
            additionalReadOnlyPaths: ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local", "/Library/Developer",
                "/Applications/Xcode.app", "/dev"],
            repositoryIsRegistered: { $0 == root }
        )
        let runner = try MaintainShellRunner(repoRootPath: root, processPolicy: policy)
        var failed = false
        for (label, command) in [
            ("confined-suite", "npm run test -- --exclude server/desktop-persistence.test.mjs"),
            ("build", "npm run build"),
            ("package", "CSC_IDENTITY_AUTO_DISCOVERY=false node_modules/.bin/electron-builder --mac --arm64 --dir --publish never")
        ] {
            if CommandLine.arguments.contains("--package-only"), label != "package" { continue }
            let result = try await runner.run(command, deadline: 180)
            print("\(label): exit=\(result.exitCode) timedOut=\(result.timedOut)")
            print(result.outputTail)
            failed = failed || !result.succeeded
        }
        if !CommandLine.arguments.contains("--package-only") {
            let manifest = URL(fileURLWithPath: registryPath)
            let manifestData = try Data(contentsOf: manifest)
            let projects = try JSONSerialization.jsonObject(with: manifestData) as! [[String: Any]]
            let entry = projects.first { $0["clonePath"] as? String == root }!
            let declaration = entry["nativeVerification"] as! [String: Any]
            let plan = try JSONDecoder().decode(IrisTestNativeVerification.Plan.self,
                from: JSONSerialization.data(withJSONObject: declaration["native"]!))
            guard case .test(let testPolicy) = policy else { fatalError("Wrong test policy") }
            let native = try await IrisTestNativeVerification.run(
                plan: plan, repoRootPath: root,
                environment: MaintainSandbox.testProcessEnvironment(for: testPolicy),
                registrationIsCurrent: { (try? Data(contentsOf: manifest)) == manifestData })
            print("native-suite (operator-reviewed fixture, not OS-contained): exit=\(native.exitCode) timedOut=\(native.timedOut)")
            print(native.outputTail)
            failed = failed || !native.succeeded
        }
        Darwin.exit(failed ? 1 : 0)
    }
}
