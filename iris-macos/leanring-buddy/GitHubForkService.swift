//
//  GitHubForkService.swift
//  leanring-buddy
//
//  The fork backup: when a local clone of a catalog app carries commits
//  beyond its pinned install commit — Iris's own fixes, or the user's — the
//  work gets backed up to a fork in the USER'S OWN GitHub namespace. Ask
//  once to connect; after that, silently, because fork+push is additive,
//  reversible, and never leaves a namespace the user owns. (For the AGPL
//  apps in the catalog this is also simply the compliant behavior.)
//
//  Auth is a GitHub App over the DEVICE FLOW: no embedded browser, no URL
//  scheme, no client secret in the bundle. The user gets a short code, types
//  it at github.com/login/device, and Iris polls. Tokens are a pair — an
//  8-hour access token and a 6-month refresh token — both in KeychainStore,
//  neither long-lived enough to be worth stealing a year later.
//
//  Hard rules, learned from other tools' scars:
//    - Fork with NO custom name; inherit the canonical one.
//    - A same-named repo that is NOT our fork: STOP AND SURFACE. Never
//      rename, never touch a repo Iris did not create (gh cli once silently
//      renamed a user's unrelated repo resolving exactly this collision).
//    - The fork endpoint returns 202 and completes async; poll with backoff.
//    - Push tokens ride one-shot URLs, never saved as remotes, never traced.
//    - The fix branch is never the default branch; merge-upstream keeps the
//      default branch mirroring the canonical repo.
//

import Combine
import Foundation

/// What KIND of change a PR carries, so its title and body tell the truth. A
/// crash-path fix went through the full 3-leg repro gate and may claim it; an
/// on-demand edit went through `earnsCleanApply` only — it is "applied and
/// rebuilt", never "verified" — and a feature must NOT borrow a bug/repro
/// narrative it never earned (adversarial #8, #13). Threaded through the PR
/// builders so the wording can never drift from the actual verification tier.
enum IrisPullRequestNarrative: Sendable, Equatable {
    /// The maintain-mode crash path: repro fails-pre / passes-post / fails-on-
    /// revert, full suite green. The only narrative allowed to say "verified".
    case verifiedCrashFix
    /// A user-initiated on-demand bug fix. Applied and rebuilt, suite green;
    /// there is no repro oracle, so it never claims "verified".
    case onDemandBugFix
    /// A user-initiated on-demand feature. Applied and rebuilt; makes NO
    /// correctness claim at all — the harness can only prove "compiles + no
    /// regression", never "does what was asked".
    case onDemandFeature
}

/// Where the connect handshake stands, for the panel to render.
enum GitHubConnectState: Equatable, Sendable {
    case notConnected
    /// Show this code; Iris is polling until the user enters it.
    case awaitingUserCode(userCode: String, verificationURL: String)
    case connected(login: String)
    /// The GitHub App id is missing from the build — the feature is dormant.
    case unavailable
}

@MainActor
final class GitHubForkService: ObservableObject {

    @Published private(set) var connectState: GitHubConnectState = .notConnected
    /// One line for the panel after a backup ("saved to github.com/you/cue").
    @Published private(set) var lastBackupSummary: String?

    /// The GitHub App's public client id, from Info.plist. Its absence makes
    /// the whole feature dormant rather than broken — the app must first be
    /// registered by the founder (device flow enabled; Contents R/W,
    /// Administration R/W, Metadata R).
    private let clientId: String?
    private let urlSession: URLSession

    init(
        clientId: String? = Bundle.main
            .object(forInfoDictionaryKey: "IrisGitHubAppClientID") as? String,
        urlSession: URLSession = .shared
    ) {
        self.clientId = (clientId?.isEmpty == false) ? clientId : nil
        self.urlSession = urlSession
        if self.clientId == nil {
            connectState = .unavailable
        } else if KeychainStore.hasSecret(ofKind: .gitHubRefreshToken) {
            connectState = .connected(login: "")
        }
    }

    // MARK: - Device flow

    /// Starts the handshake and publishes the code to show. Polls until the
    /// user finishes at github.com/login/device or the code expires.
    func connect() async {
        guard let clientId else {
            connectState = .unavailable
            return
        }
        struct DeviceCodeResponse: Codable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Int
            let interval: Int?
        }
        guard let start: DeviceCodeResponse = await postForm(
            url: "https://github.com/login/device/code",
            body: ["client_id": clientId]
        ) else { return }

        connectState = .awaitingUserCode(
            userCode: start.user_code, verificationURL: start.verification_uri
        )
        irisTrace("github: device flow started (code shown to user)")

        let deadline = Date().addingTimeInterval(TimeInterval(start.expires_in))
        var pollInterval = TimeInterval(start.interval ?? 5)
        struct TokenResponse: Codable {
            let access_token: String?
            let refresh_token: String?
            let error: String?
        }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard let token: TokenResponse = await postForm(
                url: "https://github.com/login/oauth/access_token",
                body: [
                    "client_id": clientId,
                    "device_code": start.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            ) else { continue }
            if token.error == "slow_down" { pollInterval += 5; continue }
            if token.error == "authorization_pending" { continue }
            if let accessToken = token.access_token {
                try? KeychainStore.saveSecret(accessToken, ofKind: .gitHubAccessToken)
                if let refreshToken = token.refresh_token {
                    try? KeychainStore.saveSecret(refreshToken, ofKind: .gitHubRefreshToken)
                }
                let login = await authenticatedLogin() ?? ""
                connectState = .connected(login: login)
                irisTrace("github: connected")
                return
            }
            if token.error != nil { break }
        }
        connectState = .notConnected
    }

    /// A usable access token, refreshing through the 6-month token when the
    /// 8-hour one has aged out. Nil = not connected (or refresh revoked).
    private func currentAccessToken() async -> String? {
        if let token = KeychainStore.readSecret(ofKind: .gitHubAccessToken) {
            // Cheap validity probe; an expired token earns one refresh try.
            if await authenticatedLogin(token: token) != nil { return token }
        }
        guard let clientId,
              let refreshToken = KeychainStore.readSecret(ofKind: .gitHubRefreshToken) else {
            return nil
        }
        struct TokenResponse: Codable {
            let access_token: String?
            let refresh_token: String?
        }
        guard let refreshed: TokenResponse = await postForm(
            url: "https://github.com/login/oauth/access_token",
            body: [
                "client_id": clientId,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        ), let accessToken = refreshed.access_token else { return nil }
        try? KeychainStore.saveSecret(accessToken, ofKind: .gitHubAccessToken)
        if let newRefresh = refreshed.refresh_token {
            try? KeychainStore.saveSecret(newRefresh, ofKind: .gitHubRefreshToken)
        }
        return accessToken
    }

    // MARK: - The backup

    enum ForkBackupOutcome: Equatable, Sendable {
        case backedUp(forkURL: String, branch: String)
        case nameCollisionNeedsTheUser(existingRepoURL: String)
        case notConnected
        case failed(reason: String)
    }

    /// Fork (if needed), push the given branch, and fast-forward the fork's
    /// default branch to upstream. `canonicalRepo` is "owner/name".
    func backUp(
        branch: String,
        canonicalRepo: String,
        cloneRunner: MaintainShellRunner
    ) async -> ForkBackupOutcome {
        guard let accessToken = await currentAccessToken(),
              let login = await authenticatedLogin(token: accessToken) else {
            return .notConnected
        }
        let repoName = String(canonicalRepo.split(separator: "/").last ?? "")
        guard !repoName.isEmpty else { return .failed(reason: "bad canonical repo") }

        // Collision check before any fork call. An unrelated same-named repo
        // is the user's business, never ours to rename or reuse.
        switch await repoRelationship(owner: login, name: repoName, canonicalRepo: canonicalRepo, token: accessToken) {
        case .isOurFork:
            break
        case .absent:
            guard await createFork(canonicalRepo: canonicalRepo, token: accessToken) else {
                return .failed(reason: "fork creation failed")
            }
            // 202: forking is async — usually seconds, documented up to five
            // minutes. Poll with backoff; give up politely rather than hang.
            var waited: TimeInterval = 0
            var interval: TimeInterval = 2
            var ready = false
            while waited < 120 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                waited += interval
                interval = min(interval * 1.5, 15)
                if case .isOurFork = await repoRelationship(
                    owner: login, name: repoName, canonicalRepo: canonicalRepo, token: accessToken
                ) { ready = true; break }
            }
            guard ready else { return .failed(reason: "fork not ready after two minutes") }
        case .unrelatedRepo:
            return .nameCollisionNeedsTheUser(existingRepoURL: "https://github.com/\(login)/\(repoName)")
        }

        // One-shot push URL: the token never lands in .git/config, history,
        // or the trace. The runner is non-interactive zsh -c — no history
        // file — and nothing below interpolates the URL into a log line.
        let pushURL = "https://x-access-token:\(accessToken)@github.com/\(login)/\(repoName).git"
        let push = try? await cloneRunner.run(
            "git push '\(pushURL)' 'HEAD:refs/heads/\(branch)' --force-with-lease 2>&1 | grep -v x-access-token; exit ${pipestatus[1]}",
            deadline: 300
        )
        guard push?.succeeded == true else {
            return .failed(reason: "push failed")
        }

        // Keep the fork's default branch a mirror of upstream. GitHub refuses
        // with a PR suggestion when it would conflict — which is fine; the
        // fix branch above is already safe.
        _ = await apiRequest(
            method: "POST",
            path: "/repos/\(login)/\(repoName)/merge-upstream",
            token: accessToken,
            jsonBody: ["branch": await defaultBranch(owner: login, name: repoName, token: accessToken) ?? "main"]
        )

        let forkURL = "https://github.com/\(login)/\(repoName)"
        lastBackupSummary = "Backed up to \(login)/\(repoName) (\(branch))"
        irisTrace("github: pushed \(branch) to the user's fork of \(canonicalRepo)")
        return .backedUp(forkURL: forkURL, branch: branch)
    }

    // MARK: - Ownership-aware propagation

    /// The whole propagation decision, driven by GitHub's OWN permission
    /// model: if the connected user can push to the canonical repo, this is
    /// their app — push the fix straight to it and merge it (their repo,
    /// their verified fix, no ceremony). If they cannot, this machine is a
    /// user of someone else's app — the fix goes to their fork and opens a
    /// PR on the canonical repo, where the OWNER's Iris re-verifies and
    /// decides. GitHub enforces the boundary; Iris never pushes where the
    /// token has no right to.
    enum FixPropagation: Equatable, Sendable {
        /// Owner path: merged straight into the canonical default branch.
        case mergedToCanonical(repo: String, commitSha: String?)
        /// Non-owner path: a PR is open on the canonical repo for its owner.
        case pullRequestOpened(url: String, number: Int)
        /// Fork backup happened but the canonical step didn't (owner path
        /// push failed, or a PR already existed).
        case backedUpOnly(forkURL: String, branch: String)
        case notConnected
        case failed(reason: String)
    }

    /// Propagate a verified fix as far as the user's rights allow.
    ///
    /// `narrative` defaults to `.verifiedCrashFix`, so the existing crash path
    /// is byte-for-byte unchanged. It exists so a caller opening a PR for an
    /// on-demand edit can pass the honest `.onDemandBugFix` / `.onDemandFeature`
    /// narrative — a feature PR must never inherit the bug/repro story it did not
    /// earn. NOTE: the ON-DEMAND edit tool does NOT call this — it is fork-only
    /// (`backUp`) by decision, never a push-merge to a third party's canonical
    /// even with push rights. This narrative-aware path is here for a future,
    /// separately-consented "open a PR upstream" action only.
    func propagateFix(
        branch: String,
        canonicalRepo: String,
        diagnosisTitle: String,
        narrative: IrisPullRequestNarrative = .verifiedCrashFix,
        cloneRunner: MaintainShellRunner
    ) async -> FixPropagation {
        guard let accessToken = await currentAccessToken(),
              let login = await authenticatedLogin(token: accessToken) else {
            return .notConnected
        }
        let owner = String(canonicalRepo.split(separator: "/").first ?? "")
        let repoName = String(canonicalRepo.split(separator: "/").last ?? "")
        guard !owner.isEmpty, !repoName.isEmpty else { return .failed(reason: "bad canonical repo") }

        if await authenticatedUserCanPush(toRepo: canonicalRepo, token: accessToken) {
            // Owner path: push the branch straight to canonical and merge it
            // into the default branch. "Immediate push and merge" — it is
            // their repo and the fix already passed the full gate.
            let pushURL = "https://x-access-token:\(accessToken)@github.com/\(canonicalRepo).git"
            let push = try? await cloneRunner.run(
                "git push '\(pushURL)' 'HEAD:refs/heads/\(branch)' --force-with-lease 2>&1 | grep -v x-access-token; exit ${pipestatus[1]}",
                deadline: 300
            )
            guard push?.succeeded == true else {
                return .failed(reason: "push to canonical failed")
            }
            let base = await defaultBranch(owner: owner, name: repoName, token: accessToken) ?? "main"
            // Merge via the API (a squash keeps the default branch clean).
            let merge = await apiRequest(
                method: "POST",
                path: "/repos/\(canonicalRepo)/merges",
                token: accessToken,
                jsonBody: ["base": base, "head": branch,
                           "commit_message": "Iris: \(diagnosisTitle)"]
            )
            let mergedSha = (merge?.1)?["sha"] as? String
            irisTrace("github: owner path — merged \(branch) into \(canonicalRepo)@\(base)")
            lastBackupSummary = "Fixed and merged into \(canonicalRepo)"
            return .mergedToCanonical(repo: canonicalRepo, commitSha: mergedSha)
        }

        // Non-owner path: the fork backup (which handles fork creation and
        // the push), then open a PR from the fork onto canonical.
        let backup = await backUp(branch: branch, canonicalRepo: canonicalRepo, cloneRunner: cloneRunner)
        guard case .backedUp(let forkURL, _) = backup else {
            if case .nameCollisionNeedsTheUser = backup { return .failed(reason: "repo name collision") }
            if case .notConnected = backup { return .notConnected }
            return .failed(reason: "fork backup failed")
        }
        let base = await defaultBranch(owner: owner, name: repoName, token: accessToken) ?? "main"
        guard let (status, json) = await apiRequest(
            method: "POST",
            path: "/repos/\(canonicalRepo)/pulls",
            token: accessToken,
            jsonBody: [
                "title": Self.pullRequestTitle(forNarrative: narrative, diagnosisTitle: diagnosisTitle),
                "head": "\(login):\(branch)",
                "base": base,
                "body": Self.pullRequestBody(forNarrative: narrative, diagnosisTitle: diagnosisTitle),
                "maintainer_can_modify": true,
            ]
        ) else {
            return .backedUpOnly(forkURL: forkURL, branch: branch)
        }
        // 422 = a PR from this head already exists; treat as already-open.
        if status == 201, let url = json?["html_url"] as? String, let number = json?["number"] as? Int {
            irisTrace("github: non-owner path — opened PR #\(number) on \(canonicalRepo)")
            lastBackupSummary = "Opened a fix PR on \(canonicalRepo) for its owner to review"
            return .pullRequestOpened(url: url, number: number)
        }
        return .backedUpOnly(forkURL: forkURL, branch: branch)
    }

    /// The ON-DEMAND variant: push the branch as far as the reader's rights
    /// allow and open a pull request — NEVER a merge. `propagateFix` above
    /// merges straight into the default branch when the reader owns the repo,
    /// which is right for a crash fix that passed the three-leg repro gate and
    /// wrong for an edit that is only "applied and rebuilt". Founder ruling,
    /// Sep 3 2026: once an on-demand edit works, Iris opens a pull request on
    /// its own, so a human reads the diff before it lands on main — even on
    /// the reader's own repo.
    func openPullRequest(
        branch: String,
        canonicalRepo: String,
        title: String,
        body: String,
        cloneRunner: MaintainShellRunner
    ) async -> FixPropagation {
        guard let accessToken = await currentAccessToken(),
              let login = await authenticatedLogin(token: accessToken) else {
            return .notConnected
        }
        let owner = String(canonicalRepo.split(separator: "/").first ?? "")
        let repoName = String(canonicalRepo.split(separator: "/").last ?? "")
        guard !owner.isEmpty, !repoName.isEmpty else { return .failed(reason: "bad canonical repo") }

        let head: String
        let whereTheBranchLives: String
        if await authenticatedUserCanPush(toRepo: canonicalRepo, token: accessToken) {
            // Their repo: the branch goes straight onto it, and the PR is from
            // that branch. Still a PR, never a merge.
            let pushURL = "https://x-access-token:\(accessToken)@github.com/\(canonicalRepo).git"
            let push = try? await cloneRunner.run(
                "git push '\(pushURL)' 'HEAD:refs/heads/\(branch)' --force-with-lease 2>&1 | grep -v x-access-token; exit ${pipestatus[1]}",
                deadline: 300
            )
            guard push?.succeeded == true else {
                return .failed(reason: "push to \(canonicalRepo) failed")
            }
            head = branch
            whereTheBranchLives = "https://github.com/\(canonicalRepo)"
        } else {
            // Someone else's app: the fork backup (fork creation + push), then
            // a PR from the fork.
            let backup = await backUp(branch: branch, canonicalRepo: canonicalRepo, cloneRunner: cloneRunner)
            guard case .backedUp(let forkURL, _) = backup else {
                if case .nameCollisionNeedsTheUser = backup { return .failed(reason: "repo name collision") }
                if case .notConnected = backup { return .notConnected }
                return .failed(reason: "fork backup failed")
            }
            head = "\(login):\(branch)"
            whereTheBranchLives = forkURL
        }

        let base = await defaultBranch(owner: owner, name: repoName, token: accessToken) ?? "main"
        guard let (status, json) = await apiRequest(
            method: "POST",
            path: "/repos/\(canonicalRepo)/pulls",
            token: accessToken,
            jsonBody: [
                "title": title,
                "head": head,
                "base": base,
                "body": body,
                "maintainer_can_modify": true,
            ]
        ) else {
            return .backedUpOnly(forkURL: whereTheBranchLives, branch: branch)
        }
        if status == 201, let url = json?["html_url"] as? String, let number = json?["number"] as? Int {
            irisTrace("github: opened on-demand PR #\(number) on \(canonicalRepo)")
            lastBackupSummary = "Opened a pull request on \(canonicalRepo)"
            return .pullRequestOpened(url: url, number: number)
        }
        // 422 = a PR from this head already exists; the branch is there either way.
        return .backedUpOnly(forkURL: whereTheBranchLives, branch: branch)
    }

    /// Title and body for a PR, with one sentence appended saying what
    /// established that the change works — the reader's verdict or Iris's
    /// re-check. Internal so the `gh` route (`OnDemandEditPullRequestOpener`)
    /// writes exactly the same PR the API route does.
    static func pullRequestText(
        forNarrative narrative: IrisPullRequestNarrative,
        diagnosisTitle: String,
        howItWasVerified: String
    ) -> (title: String, body: String) {
        let title = pullRequestTitle(forNarrative: narrative, diagnosisTitle: diagnosisTitle)
        let body = pullRequestBody(forNarrative: narrative, diagnosisTitle: diagnosisTitle)
            + "\n\nWhat opened this pull request: \(howItWasVerified)"
        return (title: title, body: body)
    }

    /// Whether the connected user has push (or admin) permission on a repo —
    /// the signal that decides push-direct vs. open-a-PR. GitHub returns the
    /// authenticated user's permissions inline on the repo object.
    private func authenticatedUserCanPush(toRepo repo: String, token: String) async -> Bool {
        guard let (status, json) = await apiRequest(
            method: "GET", path: "/repos/\(repo)", token: token, jsonBody: nil
        ), status == 200,
              let permissions = json?["permissions"] as? [String: Any] else { return false }
        return (permissions["push"] as? Bool ?? false) || (permissions["admin"] as? Bool ?? false)
    }

    /// The PR title, honest to the change's verification tier. A feature never
    /// borrows the word "fix".
    private static func pullRequestTitle(
        forNarrative narrative: IrisPullRequestNarrative, diagnosisTitle: String
    ) -> String {
        switch narrative {
        case .verifiedCrashFix, .onDemandBugFix:
            return "Iris fix: \(diagnosisTitle)"
        case .onDemandFeature:
            return "Iris change: \(diagnosisTitle)"
        }
    }

    /// The PR body, honest to the change's verification tier. Only the verified
    /// crash path asserts the repro narrative; an on-demand edit says plainly
    /// that it is applied-and-rebuilt (not repro-verified), and a feature makes
    /// no correctness claim at all.
    private static func pullRequestBody(
        forNarrative narrative: IrisPullRequestNarrative, diagnosisTitle: String
    ) -> String {
        switch narrative {
        case .verifiedCrashFix:
            return """
            Iris (publik's maintain mode) fixed a bug on a user's machine and \
            verified it — the repro fails before the patch, passes after, and \
            fails again when the patch is reverted, and the full test suite stays \
            green. Opened for you, the owner, to review and merge.

            Diagnosis: \(diagnosisTitle)

            The change is scoped to the reported symptom; the verification detail \
            is in the commit trailer.
            """
        case .onDemandBugFix:
            return """
            Iris (publik) applied a fix a user asked for, on their own machine, \
            under their own model key. It builds and the full test suite stays \
            green — but there is NO repro test, so this is "applied and rebuilt", \
            NOT independently verified. Opened for you, the owner, to review and \
            decide.

            Requested change: \(diagnosisTitle)

            The change is scoped and jailed during authoring; the detail is in the \
            commit trailer.
            """
        case .onDemandFeature:
            return """
            Iris (publik) implemented a feature a user asked for, on their own \
            machine, under their own model key. It compiles and the existing test \
            suite stays green — but nothing here proves the feature does what was \
            asked (there is no acceptance oracle Iris can trust). This is "applied \
            and rebuilt", NOT verified. Opened for you, the owner, to review and \
            decide.

            Requested feature: \(diagnosisTitle)

            The change is scoped and jailed during authoring; the detail is in the \
            commit trailer.
            """
        }
    }

    // MARK: - Owner side: incoming fix PRs

    /// One incoming Iris fix PR on a repo the owner controls.
    struct IncomingFixPR: Equatable, Sendable {
        let repo: String
        let number: Int
        let title: String
        let headRepoCloneURL: String
        let headBranch: String
        let url: String
    }

    /// Iris's branch prefixes, both ends of the PR contract agree on this ONE
    /// list. The engine commits crash fixes on `iris/fix-` and on-demand edits
    /// on `iris/edit-`; `iris/feature-` is reserved so a future split of the
    /// on-demand prefix by kind still matches here without another code change
    /// (design §7 branch-prefix contract). Widening this is what stops the
    /// owner-side re-verification scan from silently missing on-demand PRs.
    private static let irisBranchPrefixes = ["iris/fix-", "iris/edit-", "iris/feature-"]

    private static func branchIsAnIrisBranch(_ branch: String) -> Bool {
        irisBranchPrefixes.contains { branch.hasPrefix($0) }
    }

    /// The Iris-authored PRs open on one of the owner's repos, for their Iris
    /// to re-verify and decide. Only PRs from Iris's branch convention are
    /// surfaced; a human contributor's PR is the owner's normal GitHub flow.
    func incomingFixPullRequests(forCanonicalRepo canonicalRepo: String) async -> [IncomingFixPR] {
        guard let token = await currentAccessToken() else { return [] }
        guard let (status, _) = await apiRequest(
            method: "GET", path: "/repos/\(canonicalRepo)/pulls?state=open&per_page=30",
            token: token, jsonBody: nil
        ), status == 200 else { return [] }
        // The array response needs a raw decode; apiRequest returns an object
        // shape, so re-fetch as an array here.
        guard let url = URL(string: "https://api.github.com/repos/\(canonicalRepo)/pulls?state=open&per_page=30") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await urlSession.data(for: request),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { pull -> IncomingFixPR? in
            guard let branch = (pull["head"] as? [String: Any])?["ref"] as? String,
                  Self.branchIsAnIrisBranch(branch),
                  let head = pull["head"] as? [String: Any],
                  let headRepo = head["repo"] as? [String: Any],
                  let cloneURL = headRepo["clone_url"] as? String,
                  let number = pull["number"] as? Int,
                  let title = pull["title"] as? String,
                  let htmlURL = pull["html_url"] as? String else { return nil }
            return IncomingFixPR(
                repo: canonicalRepo, number: number, title: title,
                headRepoCloneURL: cloneURL, headBranch: branch, url: htmlURL
            )
        }
    }

    /// Merge an incoming fix PR the owner (or their Iris, after re-verifying)
    /// approved. Squash so the canonical history stays one-commit-per-fix.
    func mergeIncomingFixPR(_ pr: IncomingFixPR) async -> Bool {
        guard let token = await currentAccessToken() else { return false }
        guard let (status, _) = await apiRequest(
            method: "PUT", path: "/repos/\(pr.repo)/pulls/\(pr.number)/merge",
            token: token,
            // Neutral "Iris:" prefix — the PR title already carries its own
            // honest fix/change wording, so this must not re-assert "fix" over a
            // feature PR that came in on an iris/edit- or iris/feature- branch.
            jsonBody: ["merge_method": "squash", "commit_title": "Iris: \(pr.title)"]
        ) else { return false }
        return status == 200
    }

    // MARK: - GitHub API plumbing

    private enum RepoRelationship { case absent, isOurFork, unrelatedRepo }

    private func repoRelationship(
        owner: String, name: String, canonicalRepo: String, token: String
    ) async -> RepoRelationship {
        guard let (status, json) = await apiRequest(
            method: "GET", path: "/repos/\(owner)/\(name)", token: token, jsonBody: nil
        ) else { return .absent }
        guard status == 200, let json else { return .absent }
        let isFork = json["fork"] as? Bool ?? false
        let parentFullName = (json["parent"] as? [String: Any])?["full_name"] as? String
        if isFork, parentFullName?.caseInsensitiveCompare(canonicalRepo) == .orderedSame {
            return .isOurFork
        }
        return .unrelatedRepo
    }

    private func createFork(canonicalRepo: String, token: String) async -> Bool {
        guard let (status, _) = await apiRequest(
            method: "POST", path: "/repos/\(canonicalRepo)/forks", token: token, jsonBody: [:]
        ) else { return false }
        return status == 202 || status == 200
    }

    private func defaultBranch(owner: String, name: String, token: String) async -> String? {
        guard let (status, json) = await apiRequest(
            method: "GET", path: "/repos/\(owner)/\(name)", token: token, jsonBody: nil
        ), status == 200 else { return nil }
        return json?["default_branch"] as? String
    }

    private func authenticatedLogin(token: String? = nil) async -> String? {
        let accessToken: String?
        if let token {
            accessToken = token
        } else {
            accessToken = KeychainStore.readSecret(ofKind: .gitHubAccessToken)
        }
        guard let accessToken else { return nil }
        guard let (status, json) = await apiRequest(
            method: "GET", path: "/user", token: accessToken, jsonBody: nil
        ), status == 200 else { return nil }
        return json?["login"] as? String
    }

    private func apiRequest(
        method: String, path: String, token: String, jsonBody: [String: Any]?
    ) async -> (Int, [String: Any]?)? {
        guard let url = URL(string: "https://api.github.com\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (http.statusCode, json)
    }

    private func postForm<Response: Decodable>(
        url urlString: String, body: [String: String]
    ) async -> Response? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, _) = try? await urlSession.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
