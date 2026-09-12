import Foundation

/// Presentation only. Starting an install still goes through the controller's
/// explicit start gesture, remembered consent and existing command risk gate.
nonisolated enum GuideAutopilotAvailability: Equatable, Sendable {
    case available
    case inactive
    case running
    case unsupported
    case setupRequired
    case runnerUnavailable
    case manualStepsOnly

    static func resolve(
        isActivelyGuiding: Bool,
        isRunning: Bool,
        isSupportedBranch: Bool,
        isInSetupRecovery: Bool,
        hasRunner: Bool,
        hasExecutableSteps: Bool
    ) -> Self {
        guard isActivelyGuiding else { return .inactive }
        guard !isRunning else { return .running }
        guard isSupportedBranch else { return .unsupported }
        guard !isInSetupRecovery else { return .setupRequired }
        guard hasExecutableSteps else { return .manualStepsOnly }
        guard hasRunner else { return .runnerUnavailable }
        return .available
    }

    var explanation: String? {
        switch self {
        case .available, .inactive, .running:
            return nil
        case .unsupported:
            return "This guide cannot run on this Mac. Choose a supported install option."
        case .setupRequired:
            return "Finish this setup step first. Then you can let Iris run the install."
        case .runnerUnavailable:
            return "Automatic install is unavailable right now. You can follow these steps manually."
        case .manualStepsOnly:
            return "Manual install: this guide has no commands for Iris to run. Follow the download and on-screen steps."
        }
    }
}
