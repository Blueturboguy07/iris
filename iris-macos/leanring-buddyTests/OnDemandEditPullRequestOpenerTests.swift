//
//  OnDemandEditPullRequestOpenerTests.swift
//  leanring-buddyTests
//
//  "after edits if it works, auto submit a pr to git repo" (founder, Sep 3
//  2026). The `gh` route, scripted: the commands Iris runs, in order, with the
//  arguments a maintainer would see, and every way gh can answer.
//

import Foundation
import Testing
@testable import Iris

/// A shell that answers from a script and remembers what it was asked.
private final class ScriptedShell: OnDemandEditPullRequestShell, @unchecked Sendable {
    var commandsRun: [String] = []
    var answer: (String) -> (succeeded: Bool, outputTail: String)
    init(answer: @escaping (String) -> (succeeded: Bool, outputTail: String)) { self.answer = answer }
    func runForThePullRequest(_ command: String, deadline: TimeInterval) async -> (succeeded: Bool, outputTail: String) {
        commandsRun.append(command)
        return answer(command)
    }
}

@MainActor
@Suite(.serialized)
struct OnDemandEditPullRequestOpenerTests {

    private var facts: OnDemandEditPullRequestFacts {
        OnDemandEditPullRequestFacts(
            branchName: "iris/edit-f30161c41fb0-20260903",
            canonicalRepo: "Blueturboguy07/WhimprFlow",
            narrative: .onDemandBugFix,
            requestTitle: "mic isn't showing up in settings to allow access",
            howItWasVerified: "the user confirmed the symptom is fixed after Iris rebuilt and relaunched the app with this change."
        )
    }

    // MARK: - The gh route

    @Test func signedInGhPushesTheBranchThenOpensThePullRequest() async throws {
        var bodySeenAtCreateTime: String?
        let shell = ScriptedShell { command in
            if command.contains("gh auth status") { return (true, "") }
            if command.hasPrefix("GIT_TERMINAL_PROMPT=0 git push") { return (true, "branch 'iris/edit-f30161c41fb0-20260903' set up to track 'origin/...'") }
            if command.hasPrefix("gh pr create") {
                // The body file must exist WHILE gh runs — read it now.
                if let range = command.range(of: #"--body-file '([^']+)'"#, options: .regularExpression) {
                    let path = String(command[range]).replacingOccurrences(of: "--body-file '", with: "").dropLast()
                    bodySeenAtCreateTime = try? String(contentsOfFile: String(path), encoding: .utf8)
                }
                return (true, "Creating pull request for iris/edit-f30161c41fb0-20260903 into main in Blueturboguy07/WhimprFlow\n\nhttps://github.com/Blueturboguy07/WhimprFlow/pull/12\n")
            }
            return (false, "unexpected command")
        }
        let opener = OnDemandEditPullRequestOpener(gitHubForkService: nil, shell: shell)

        let outcome = await opener.openPullRequest(facts)

        #expect(outcome == .opened(url: "https://github.com/Blueturboguy07/WhimprFlow/pull/12"))
        #expect(shell.commandsRun.count == 3)
        #expect(shell.commandsRun[0].contains("gh auth status"))
        #expect(shell.commandsRun[1] == "GIT_TERMINAL_PROMPT=0 git push --set-upstream --force-with-lease origin 'iris/edit-f30161c41fb0-20260903' 2>&1")
        #expect(shell.commandsRun[2].hasPrefix("gh pr create --head 'iris/edit-f30161c41fb0-20260903' --title 'Iris fix: mic isn'\\''t showing up in settings to allow access' --body-file '"))

        let body = try #require(bodySeenAtCreateTime)
        #expect(body.contains("NOT independently verified"))
        #expect(body.contains("What opened this pull request: the user confirmed the symptom is fixed"))
    }

    /// gh refuses a second PR for the same branch, exits non-zero, and prints
    /// the existing one. That is the reader's PR — reported as such.
    @Test func anExistingPullRequestIsReportedAsAlreadyOpen() async {
        let shell = ScriptedShell { command in
            if command.contains("gh auth status") { return (true, "") }
            if command.hasPrefix("GIT_TERMINAL_PROMPT=0 git push") { return (true, "Everything up-to-date") }
            if command.hasPrefix("gh pr create") {
                return (false, "a pull request for branch \"iris/edit-f30161c41fb0-20260903\" into branch \"main\" already exists:\nhttps://github.com/Blueturboguy07/WhimprFlow/pull/7\n")
            }
            return (false, "")
        }
        let opener = OnDemandEditPullRequestOpener(gitHubForkService: nil, shell: shell)
        #expect(await opener.openPullRequest(facts) == .alreadyOpen(url: "https://github.com/Blueturboguy07/WhimprFlow/pull/7"))
    }

    @Test func withoutASignedInGhNothingIsPushedAndTheReasonSaysWhatToDo() async {
        let shell = ScriptedShell { _ in (false, "gh: command not found") }
        let opener = OnDemandEditPullRequestOpener(gitHubForkService: nil, shell: shell)

        let outcome = await opener.openPullRequest(facts)

        #expect(outcome == .notSetUp(reason: OnDemandEditPullRequestOpener.notSetUpReason))
        #expect(shell.commandsRun.count == 1, "only the sign-in check may run before giving up: \(shell.commandsRun)")
        #expect(OnDemandEditPullRequestOpener.notSetUpReason.contains("gh auth login"))
    }

    @Test func aFailedPushStopsBeforeAnyPullRequestIsAttempted() async {
        let shell = ScriptedShell { command in
            if command.contains("gh auth status") { return (true, "") }
            if command.hasPrefix("GIT_TERMINAL_PROMPT=0 git push") { return (false, "fatal: could not read Username for 'https://github.com': terminal prompts disabled") }
            return (true, "https://github.com/x/y/pull/1")
        }
        let opener = OnDemandEditPullRequestOpener(gitHubForkService: nil, shell: shell)

        let outcome = await opener.openPullRequest(facts)

        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("pushing iris/edit-f30161c41fb0-20260903 to origin failed"))
        #expect(reason.contains("terminal prompts disabled"))
        #expect(shell.commandsRun.contains { $0.hasPrefix("gh pr create") } == false)
    }

    // MARK: - Who may auto-open

    @Test func whetherTheReaderCanPushIsReadFromGh() async {
        for (answer, expected) in [("WRITE\n", true), ("ADMIN", true), ("MAINTAIN", true), ("READ", false), ("", false)] {
            let shell = ScriptedShell { _ in (true, answer) }
            #expect(await OnDemandEditPullRequestOpener.readerCanPushToTheRepo(behind: shell) == expected, "gh said \(answer)")
        }
        let failing = ScriptedShell { _ in (false, "not a git repository") }
        #expect(await OnDemandEditPullRequestOpener.readerCanPushToTheRepo(behind: failing) == false)
    }

    // MARK: - Text

    @Test func thePullRequestURLIsFoundInGhOutput() {
        #expect(OnDemandEditPullRequestOpener.pullRequestURL(in: "noise\nhttps://github.com/o/r/pull/42\n") == "https://github.com/o/r/pull/42")
        #expect(OnDemandEditPullRequestOpener.pullRequestURL(in: "already exists:\nhttps://github.com/o/r/pull/7") == "https://github.com/o/r/pull/7")
        #expect(OnDemandEditPullRequestOpener.pullRequestURL(in: "https://github.com/o/r/compare/x") == nil)
    }

    @Test func theTitleIsTheRequestsFirstLineBoundedToATitle() {
        #expect(OnDemandEditCoordinator.pullRequestTitle(fromRequest: "fix the mic\nand while you're at it…") == "fix the mic")
        let long = String(repeating: "word ", count: 30)
        let title = OnDemandEditCoordinator.pullRequestTitle(fromRequest: long)
        #expect(title.count <= 72)
        #expect(title.hasSuffix("…"))
    }

    @Test func theBodySaysHowItWasVerifiedAndAFeatureNeverBorrowsTheWordFix() {
        let fix = GitHubForkService.pullRequestText(forNarrative: .onDemandBugFix, diagnosisTitle: "mic access", howItWasVerified: "the user confirmed it.")
        #expect(fix.title == "Iris fix: mic access")
        #expect(fix.body.hasSuffix("What opened this pull request: the user confirmed it."))

        let feature = GitHubForkService.pullRequestText(forNarrative: .onDemandFeature, diagnosisTitle: "dark mode", howItWasVerified: "Iris's own automatic re-check of the relaunched app looked fixed; the user has not confirmed it themselves.")
        #expect(feature.title == "Iris change: dark mode")
        #expect(feature.title.contains("fix") == false)
        #expect(feature.body.contains("NOT verified"))
    }

    @Test func oneAttemptPerEdit() {
        #expect(OnDemandEditPullRequestState.notAttempted.allowsAnAttempt)
        #expect(OnDemandEditPullRequestState.failed(reason: "x").allowsAnAttempt)
        #expect(OnDemandEditPullRequestState.notSetUp(reason: "x").allowsAnAttempt)
        #expect(OnDemandEditPullRequestState.opening.allowsAnAttempt == false)
        #expect(OnDemandEditPullRequestState.opened(url: "u").allowsAnAttempt == false)
        #expect(OnDemandEditPullRequestState.alreadyOpen(url: "u").allowsAnAttempt == false)
        #expect(OnDemandEditPullRequestState.opened(url: "u").url == "u")
    }
}
