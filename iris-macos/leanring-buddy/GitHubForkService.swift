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
