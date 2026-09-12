import Foundation

/// Operator-declared split between confined checks and desktop-runtime checks.
/// The model cannot create this declaration through its command/file tools.
/// Native checks are ordinary same-user processes, not OS-contained processes.
nonisolated struct IrisTestVerificationDeclaration: Codable, Equatable, Sendable {
    let originalTestCommand: String
    let confinedTestCommand: String
    let native: IrisTestNativeVerification.Plan

    func confinedCommands(from commands: VerificationCommands) -> VerificationCommands? {
        guard commands.testCommand == originalTestCommand,
              commands.commandSubdirectory == nil,
              !confinedTestCommand.isEmpty else { return nil }
        return VerificationCommands(buildCommand: commands.buildCommand,
                                    testCommand: confinedTestCommand,
                                    commandSubdirectory: nil)
    }
}

nonisolated enum IrisTestVerificationPlan {
    struct Captured: Sendable {
        let projectSlug: String
        let clonePath: String
        let declaration: IrisTestVerificationDeclaration
        let capturedProject: IrisTestProjectRegistry.Project

        func matches(_ project: IrisTestProjectRegistry.Project) -> Bool {
            project == capturedProject && project.clonePath == clonePath
                && project.nativeVerification == declaration
        }

        func isCurrent() -> Bool {
            guard let project = IrisTestProjectRegistry.project(slug: projectSlug) else { return false }
            return matches(project)
        }

        func run(cancellationCheck: (@MainActor () -> Bool)? = nil) async throws -> MaintainCommandResult {
            guard case .test(let policy) = MaintainSandbox.runtimeProcessPolicy() else {
                throw MaintainShellRunnerError.testEnvironmentUnavailable
            }
            return try await withThrowingTaskGroup(of: MaintainCommandResult.self) { group in
                group.addTask {
                    try await IrisTestNativeVerification.run(
                        plan: declaration.native, repoRootPath: clonePath,
                        environment: MaintainSandbox.testProcessEnvironment(for: policy),
                        registrationIsCurrent: { isCurrent() })
                }
                if let cancellationCheck {
                    group.addTask {
                        while !Task.isCancelled {
                            if await cancellationCheck() { throw CancellationError() }
                            try await Task.sleep(nanoseconds: 150_000_000)
                        }
                        throw CancellationError()
                    }
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        }
    }

    static func capture(repoRootPath: String, commands: VerificationCommands) throws -> Captured? {
#if IRIS_TEST_BUILD
        guard IrisTestEnvironment.isEnabled,
              let project = IrisTestProjectRegistry.projects().first(where: { $0.clonePath == repoRootPath }),
              let declaration = project.nativeVerification else { return nil }
        guard declaration.confinedCommands(from: commands) != nil,
              case .test(let policy) = MaintainSandbox.runtimeProcessPolicy() else {
            throw IrisTestNativeVerification.Error.invalidPlan("declared suite does not match this project's verification command")
        }
        try IrisTestNativeVerification.validate(plan: declaration.native, repoRootPath: repoRootPath,
            environment: MaintainSandbox.testProcessEnvironment(for: policy))
        return Captured(projectSlug: project.slug, clonePath: repoRootPath, declaration: declaration,
            capturedProject: project)
#else
        return nil
#endif
    }
}
