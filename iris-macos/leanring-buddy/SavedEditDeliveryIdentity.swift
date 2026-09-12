import Foundation

/// Pins a retry to the exact clean source that already passed the edit gates.
/// A retry packages this source; it never asks a model to recreate the edit.
struct SavedEditDeliveryIdentity: Equatable, Sendable {
    let clonePath: String
    let branchName: String
    let commit: String

    @MainActor
    static func capture(clonePath: String, expectedBranch: String) async -> Self? {
        guard let runner = try? MaintainShellRunner(repoRootPath: clonePath) else { return nil }
        func checked(_ command: String) async -> String? {
            guard let result = try? await runner.run(command, deadline: 15),
                  result.succeeded, result.bytesDroppedBeforeTail == 0 else { return nil }
            return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let status = await checked("git status --porcelain"), status.isEmpty,
              let branch = await checked("git symbolic-ref --short HEAD"), branch == expectedBranch,
              let commit = await checked("git rev-parse HEAD"),
              [40, 64].contains(commit.count), commit.allSatisfy({ $0.isHexDigit }),
              let finalStatus = await checked("git status --porcelain"), finalStatus.isEmpty
        else { return nil }
        return Self(clonePath: URL(fileURLWithPath: clonePath).resolvingSymlinksInPath().path,
                    branchName: branch, commit: commit)
    }

    @MainActor
    func stillMatchesSource() async -> Bool {
        await Self.capture(clonePath: clonePath, expectedBranch: branchName) == self
    }

    @MainActor
    func hasParentCommit(_ expectedCommit: String) async -> Bool {
        guard [40, 64].contains(expectedCommit.count), expectedCommit.allSatisfy({ $0.isHexDigit }),
              let runner = try? MaintainShellRunner(repoRootPath: clonePath),
              let result = try? await runner.run("git rev-parse HEAD^", deadline: 15),
              result.succeeded, result.bytesDroppedBeforeTail == 0,
              result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCommit else { return false }
        return await stillMatchesSource()
    }
}
