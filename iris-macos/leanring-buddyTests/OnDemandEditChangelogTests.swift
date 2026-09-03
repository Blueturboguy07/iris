//
//  OnDemandEditChangelogTests.swift
//  leanring-buddyTests
//
//  "not auto pr for edit, only for bug fixes; if there's an edit it should just
//  changelog and push to publik db" (founder, Sep 3 2026). A working BUG FIX
//  opens a pull request; a working FEATURE is changelogged to publik instead
//  and never PR'd. These pin the split, the client call, and the state.
//

import Foundation
import Testing
@testable import Iris

// A URLSession that answers from a canned response and captures the request.
private final class CapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var statusToReturn = 201

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusToReturn, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct OnDemandEditChangelogTests {

    private func aStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        CapturingURLProtocol.lastRequest = nil
        CapturingURLProtocol.lastBody = nil
        return URLSession(configuration: config)
    }

    // MARK: - The split

    /// The whole founder ruling, as one function: a fix opens a PR, a feature
    /// does not.
    @Test func onlyABugFixOpensAPullRequest() {
        #expect(OnDemandEditCoordinator.aWorkingEditOpensAPullRequest(forKind: .bugFix))
        #expect(OnDemandEditCoordinator.aWorkingEditOpensAPullRequest(forKind: .feature) == false)
        // A nil kind falls back to a fix, matching the commit-trailer default.
        #expect(OnDemandEditCoordinator.aWorkingEditOpensAPullRequest(forKind: nil))
    }

    // MARK: - The client call

    /// A feature changelog POSTs to api/iris/changelog with the summary, the
    /// repo, and kind "feature" — the publik db push the ruling asks for.
    @Test func recordChangelogPostsTheFeatureEntry() async throws {
        let client = MaintainPoolClient(
            publikBaseURL: URL(string: "https://publik.example")!,
            urlSession: aStubbedSession()
        )
        CapturingURLProtocol.statusToReturn = 201

        let accepted = await client.recordChangelog(
            appSlug: "whimprflow", summary: "add a dark mode toggle",
            repo: "Blueturboguy07/WhimprFlow", kind: "feature"
        )

        #expect(accepted)
        let request = try #require(CapturingURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://publik.example/api/iris/changelog")
        #expect(request.httpMethod == "POST")
        let body = try #require(CapturingURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["appSlug"] as? String == "whimprflow")
        #expect(json["summary"] as? String == "add a dark mode toggle")
        #expect(json["kind"] as? String == "feature")
        #expect(json["repo"] as? String == "Blueturboguy07/WhimprFlow")
    }

    /// A local-only app has no canonical repo; the entry still posts, without
    /// a repo field, rather than being dropped.
    @Test func recordChangelogOmitsAMissingRepo() async throws {
        let client = MaintainPoolClient(
            publikBaseURL: URL(string: "https://publik.example")!,
            urlSession: aStubbedSession()
        )
        CapturingURLProtocol.statusToReturn = 201
        _ = await client.recordChangelog(appSlug: "notetion", summary: "add tags", repo: nil, kind: "feature")
        let body = try #require(CapturingURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["repo"] == nil)
        #expect(json["summary"] as? String == "add tags")
    }

    /// A server refusal is reported as not-accepted, so the card can say it
    /// didn't land rather than claiming it did.
    @Test func aRefusedChangelogReportsFailure() async {
        let client = MaintainPoolClient(
            publikBaseURL: URL(string: "https://publik.example")!,
            urlSession: aStubbedSession()
        )
        CapturingURLProtocol.statusToReturn = 500
        let accepted = await client.recordChangelog(appSlug: "x", summary: "y", repo: nil, kind: "feature")
        #expect(accepted == false)
    }

    // MARK: - The state

    @Test func changelogStateAllowsOneAttempt() {
        #expect(OnDemandEditChangelogState.notAttempted.allowsAnAttempt)
        #expect(OnDemandEditChangelogState.failed(reason: "x").allowsAnAttempt)
        #expect(OnDemandEditChangelogState.notSetUp(reason: "x").allowsAnAttempt)
        #expect(OnDemandEditChangelogState.pushing.allowsAnAttempt == false)
        #expect(OnDemandEditChangelogState.pushed.allowsAnAttempt == false)
    }
}
