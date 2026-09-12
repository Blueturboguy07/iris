import Foundation
@testable import IrisHarnessNative

private enum SourceCheckoutRefusalCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Pure checks for the guide's found-but-rejected source-pin state. No shell,
/// repository, app, profile, or guide data is touched by this executable.
@main
struct SourceCheckoutRefusalChecks {
    private static let sourcePinGuardCommand = """
    (
    if ! git config --get remote.origin.url 2>/dev/null | grep -qxF "https://example.test/source"; then
      echo "~/fixture already exists and is not a clean copy of this app's source."
      exit 1
    fi
    if git status --porcelain 2>/dev/null | grep -q .; then
      echo "~/fixture already exists and is not a clean copy of this app's source."
      exit 1
    fi
    git checkout 0123456789abcdef0123456789abcdef01234567
    )
    """

    static func main() {
        do {
            try matchingRefusalReportsOnlyTheCompletedWorkingDirectory()
            try safePorcelainPathsAreBoundedAndTraversalFree()
            try unrelatedOrUnverifiableFailuresAreNotClassified()
            print("SOURCE CHECKOUT REFUSAL CHECKS PASS: 3 groups")
        } catch {
            print("SOURCE CHECKOUT REFUSAL CHECKS FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func matchingRefusalReportsOnlyTheCompletedWorkingDirectory() throws {
        guard let refusal = GuideAutopilotSourceCheckoutRefusal.detect(
            command: sourcePinGuardCommand,
            exitStatus: 1,
            scrubbedOutputTail: "~/fixture already exists and is not a clean copy of this app's source.",
            workingDirectory: "/private/tmp/guide-fixture"
        ) else {
            throw SourceCheckoutRefusalCheckError.failed("matching source-pin refusal was not classified")
        }
        try require(
            refusal.verifiedWorkingDirectory == "/private/tmp/guide-fixture",
            "completed shell working directory was not retained"
        )
        try require(
            refusal.safeRelativeChangedPaths.isEmpty,
            "filenames were invented when the guide did not print them"
        )
        let diagnosis = refusal.readerFacingDiagnosis
        try require(
            diagnosis.contains("source check stopped in /private/tmp/guide-fixture"),
            "diagnosis did not name the completed working directory"
        )
        try require(
            !diagnosis.contains("found the source folder")
                && !diagnosis.contains("verified checkout"),
            "diagnosis claimed more than the shell cwd proves"
        )
        print("PASS source-pin refusal preserves literal cwd and honest uncertainty")
    }

    private static func safePorcelainPathsAreBoundedAndTraversalFree() throws {
        let output = """
        ~/fixture already exists and is not a clean copy of this app's source.
         M Sources/Editor.swift
        ?? notes/local.md
        ?? ../outside.md
        ?? /private/tmp/outside.md
        ?? \"quoted name.md\"
        R  old.md -> new.md
        """
        guard let refusal = GuideAutopilotSourceCheckoutRefusal.detect(
            command: sourcePinGuardCommand,
            exitStatus: 1,
            scrubbedOutputTail: output,
            workingDirectory: "/private/tmp/guide-fixture"
        ) else {
            throw SourceCheckoutRefusalCheckError.failed("porcelain source-pin refusal was not classified")
        }
        try require(
            refusal.safeRelativeChangedPaths == ["Sources/Editor.swift", "notes/local.md"],
            "unsafe or ambiguous porcelain paths were surfaced: \(refusal.safeRelativeChangedPaths)"
        )
        try require(
            refusal.readerFacingDiagnosis.contains("Sources/Editor.swift")
                && refusal.readerFacingDiagnosis.contains("notes/local.md"),
            "safe changed paths were omitted from the diagnosis"
        )
        print("PASS bounded safe-relative porcelain path reporting")
    }

    private static func unrelatedOrUnverifiableFailuresAreNotClassified() throws {
        let refusalOutput = "not a clean copy"
        let cases: [(String, Int32, String, String)] = [
            ("git status --porcelain", 1, refusalOutput, "/private/tmp/guide-fixture"),
            (sourcePinGuardCommand, 2, refusalOutput, "/private/tmp/guide-fixture"),
            (sourcePinGuardCommand, 1, "git checkout failed", "/private/tmp/guide-fixture"),
            (sourcePinGuardCommand, 1, refusalOutput, "relative/fixture"),
            (sourcePinGuardCommand, 1, refusalOutput, "/private/tmp/../outside"),
            (sourcePinGuardCommand, 1, refusalOutput, "")
        ]
        for (command, exitStatus, output, workingDirectory) in cases {
            let refusal = GuideAutopilotSourceCheckoutRefusal.detect(
                command: command,
                exitStatus: exitStatus,
                scrubbedOutputTail: output,
                workingDirectory: workingDirectory
            )
            try require(
                refusal == nil,
                "unrelated or unverifiable failure was classified for cwd \(workingDirectory)"
            )
        }
        print("PASS unrelated Git errors and unverifiable paths fail closed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SourceCheckoutRefusalCheckError.failed(message) }
    }
}
