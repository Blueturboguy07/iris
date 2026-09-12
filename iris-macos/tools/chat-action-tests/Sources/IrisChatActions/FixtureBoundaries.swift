import Foundation

struct ClaudeClientToolResult: Sendable {
    let contentText: String
    let isError: Bool
}

@MainActor enum GuideAutopilotFixProposer {
    static var webSearchTool: [String: Any] { [:] }
}

struct MaintainShellRunner {
    struct FixtureShellIsUnavailable: Error {}
    struct Result {
        let exitCode: Int32
        let outputTail: String
        let timedOut: Bool
    }

    init(repoRootPath: String) throws { throw FixtureShellIsUnavailable() }
    func run(_ command: String, deadline: TimeInterval) async throws -> Result {
        throw FixtureShellIsUnavailable()
    }
}

func irisTrace(_ message: String) {}
