//
//  OnDemandEditPullRequestOpener.swift
//  leanring-buddy
//
//  "after edits if it works, auto submit a pr to git repo" — founder, Sep 3
//  2026. Once an on-demand edit is confirmed working, Iris pushes its branch
//  and opens a pull request on the app's repository, without being asked.
//
//  TWO ROUTES, ONE OUTCOME. The GitHub App device flow (`GitHubForkService`)
//  is the route that needs nothing installed — but it is dormant until the
//  App's client id ships in Info.plist, which it has not yet. The reader's own
//  `gh` command line is the route that works today: it holds their login and
//  its refresh exactly the way `codex` holds theirs for Tier C, and Iris
//  stores nothing for it. The service is tried first when it is connected;
//  otherwise `gh`; otherwise an honest "not set up" that says what would set
//  it up.
//
//  NEVER A MERGE. `GitHubForkService.propagateFix` merges straight into the
//  default branch when the reader owns the repo — written for the crash path,
//  whose fixes pass a three-leg repro gate. An on-demand edit is "applied and
//  rebuilt", and the founder asked for a pull request, so even on the reader's
//  own repo a human reads the diff before it lands on main.
//
//  THE PR SAYS HOW IT WAS VERIFIED. The body carries the honest narrative for
//  the edit's kind (`IrisPullRequestNarrative`) plus one sentence naming the
//  verdict that opened it: the reader's own "Fixed", or Iris's re-check. A
//  maintainer reading it knows exactly how much to trust it.
//

import Foundation

// MARK: - The shell the opener drives

/// The two commands the `gh` route needs, behind a seam a test can script.
protocol OnDemandEditPullRequestShell {
    func runForThePullRequest(_ command: String, deadline: TimeInterval) async -> (succeeded: Bool, outputTail: String)
}

extension MaintainShellRunner: OnDemandEditPullRequestShell {
    func runForThePullRequest(_ command: String, deadline: TimeInterval) async -> (succeeded: Bool, outputTail: String) {
        guard let result = try? await run(command, deadline: deadline) else {
            return (succeeded: false, outputTail: "the command could not be run")
        }
        return (succeeded: result.succeeded, outputTail: result.outputTail)
    }
}

// MARK: - What goes into the PR

struct OnDemandEditPullRequestFacts: Equatable {
    let branchName: String
    /// "owner/name" of the repo the PR targets, when provenance knows it. The
    /// `gh` route works without it (gh reads the clone's own remotes).
    var canonicalRepo: String?
    let narrative: IrisPullRequestNarrative
    /// The reader's request, first line, for the title.
    let requestTitle: String
    /// One sentence for the body: what established that the edit works.
    let howItWasVerified: String
}

enum OnDemandEditPullRequestOutcome: Equatable {
    case opened(url: String)
    /// `gh pr create` refuses a second PR for the same branch and prints the
    /// existing one's URL — that is the reader's PR, not a failure.
    case alreadyOpen(url: String)
    /// The branch reached GitHub but no pull request came back.
    case pushedButNoPullRequest(detail: String)
    /// Neither route is available. The reason says what would make one so.
    case notSetUp(reason: String)
    case failed(reason: String)
}

// MARK: - The opener

@MainActor
final class OnDemandEditPullRequestOpener {

    private let gitHubForkService: GitHubForkService?
    private let shell: any OnDemandEditPullRequestShell
    /// The service route pushes through the real runner; nil means that route
    /// is not offered (a test scripting only the `gh` route).
    private let cloneRunnerForTheService: MaintainShellRunner?

    init(
        gitHubForkService: GitHubForkService?,
        shell: any OnDemandEditPullRequestShell,
        cloneRunnerForTheService: MaintainShellRunner? = nil
    ) {
        self.gitHubForkService = gitHubForkService
        self.shell = shell
        self.cloneRunnerForTheService = cloneRunnerForTheService
    }

    static let notSetUpReason = "Iris isn't connected to GitHub and the gh command line isn't signed in — install GitHub CLI and run `gh auth login`, or connect GitHub in Iris's settings, and tap Open a pull request"

    func openPullRequest(_ facts: OnDemandEditPullRequestFacts) async -> OnDemandEditPullRequestOutcome {
        let text = GitHubForkService.pullRequestText(
            forNarrative: facts.narrative,
            diagnosisTitle: facts.requestTitle,
            howItWasVerified: facts.howItWasVerified
        )

        // Route 1: the GitHub App, when the reader connected it.
        if let service = gitHubForkService,
           case .connected = service.connectState,
           let canonicalRepo = facts.canonicalRepo,
           let cloneRunner = cloneRunnerForTheService {
            switch await service.openPullRequest(
                branch: facts.branchName, canonicalRepo: canonicalRepo,
                title: text.title, body: text.body, cloneRunner: cloneRunner
            ) {
            case .pullRequestOpened(let url, _):
                return .opened(url: url)
            case .backedUpOnly(let forkURL, let branch):
                return .pushedButNoPullRequest(detail: "\(branch) is on \(forkURL), but GitHub did not open a pull request — one may already exist")
            case .failed(let reason):
                return .failed(reason: reason)
            case .mergedToCanonical(let repo, _):
                // `openPullRequest` never merges; this case exists for the
                // crash path's `propagateFix`. Said plainly rather than hidden.
                return .failed(reason: "unexpected: merged into \(repo) instead of opening a pull request")
            case .notConnected:
                // The token lapsed between the state check and the call. The
                // `gh` route below is the honest next try.
                break
            }
        }

        // Route 2: the reader's own gh.
        let ghIsSignedIn = await shell.runForThePullRequest(
            "command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1", deadline: 60
        )
        guard ghIsSignedIn.succeeded else {
            return .notSetUp(reason: Self.notSetUpReason)
        }

        let push = await shell.runForThePullRequest(
            "GIT_TERMINAL_PROMPT=0 git push --set-upstream --force-with-lease origin \(Self.shellQuoted(facts.branchName)) 2>&1",
            deadline: 300
        )
        guard push.succeeded else {
            return .failed(reason: "pushing \(facts.branchName) to origin failed: \(Self.lastLine(of: push.outputTail))")
        }

        // The body goes through a file: it is several paragraphs with quotes
        // and backticks in it, and a file has no quoting problem.
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-pull-request-\(UUID().uuidString).md")
        do {
            try text.body.write(to: bodyFileURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed(reason: "could not write the pull request body: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let create = await shell.runForThePullRequest(
            "gh pr create --head \(Self.shellQuoted(facts.branchName)) --title \(Self.shellQuoted(text.title)) --body-file \(Self.shellQuoted(bodyFileURL.path)) 2>&1",
            deadline: 120
        )
        if let url = Self.pullRequestURL(in: create.outputTail) {
            // gh exits non-zero AND prints the URL when a PR for the branch
            // already exists ("a pull request for branch … already exists: …").
            return create.succeeded ? .opened(url: url) : .alreadyOpen(url: url)
        }
        guard create.succeeded else {
            return .failed(reason: "gh pr create failed: \(Self.lastLine(of: create.outputTail))")
        }
        return .pushedButNoPullRequest(detail: "gh reported success but printed no pull request URL")
    }

    /// Whether the reader can push to the repo the clone came from — the
    /// signal that decides if Iris's OWN re-check may open a pull request
    /// (only on a repo that is the reader's) or must wait for the reader's
    /// "Fixed". Read from gh, which knows the viewer's permission on the
    /// clone's repo; anything short of an answer is "no".
    static func readerCanPushToTheRepo(behind shell: any OnDemandEditPullRequestShell) async -> Bool {
        let permission = await shell.runForThePullRequest(
            "gh repo view --json viewerPermission --jq .viewerPermission 2>/dev/null", deadline: 60
        )
        guard permission.succeeded else { return false }
        let answer = permission.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["ADMIN", "MAINTAIN", "WRITE"].contains(answer)
    }

    // MARK: Text helpers

    /// The first `https://github.com/…/pull/N` in gh's output, which is how gh
    /// reports both a new PR and an existing one.
    static func pullRequestURL(in output: String) -> String? {
        let pattern = #"https://github\.com/[^\s'"<>]+/pull/\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lastLine(of output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "(no output)"
    }
}
