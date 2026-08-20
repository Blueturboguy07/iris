//
//  ClaudeCodeLoginTests.swift
//  leanring-buddyTests
//
//  The parts of the Claude Code CLI-login flow Iris CAN verify without a live
//  login: the token scan over terminal output, the parse of an existing
//  `claude login` credential blob, and the display redaction. The interactive
//  `setup-token` browser step and the live OAuth header are exercised on a real
//  Mac — see the notes in ClaudeCodeLogin.swift.
//

import Foundation
import Testing
@testable import Iris

struct ClaudeCodeLoginTests {

    // A token shaped like a real long-lived one, long enough to clear the scan's
    // minimum body length. Never a real credential.
    private static let fakeToken = "sk-ant-oat01-AbCdEf0123456789_-GhIjKlMnOpQrStUvWx"

    // MARK: - Scanning setup-token output

    @Test func theTokenIsFoundInAChattyTranscript() {
        let transcript = """
        Opening your browser to authenticate…
        Paste this into your app:

        \(Self.fakeToken)

        Done. You can close this window.
        """
        #expect(ClaudeCodeLogin.scanForOAuthToken(in: transcript) == Self.fakeToken)
    }

    @Test func theCompleteTokenWinsOverAnEarlierPartialRead() {
        // A pty can deliver the token across two reads: a prefix, then the rest.
        // The accumulated buffer then contains both a short and a long match, and
        // the complete one must be the answer.
        let prefix = "sk-ant-oat01-AbCdEf0123456789_-Gh"
        let accumulated = "\(prefix) …more bytes arrive… \(Self.fakeToken)"
        #expect(ClaudeCodeLogin.scanForOAuthToken(in: accumulated) == Self.fakeToken)
    }

    @Test func outputWithNoTokenScansToNil() {
        #expect(ClaudeCodeLogin.scanForOAuthToken(in: "just some ordinary terminal output") == nil)
        // A near-miss (right prefix, body far too short) is not mistaken for one.
        #expect(ClaudeCodeLogin.scanForOAuthToken(in: "sk-ant-oat01-short") == nil)
    }

    // MARK: - Redacting the token from what the panel shows

    @Test func aCapturedTokenIsNotLeftRenderedInTheTranscript() {
        let redacted = ClaudeCodeLogin.redactingAnyOAuthToken(
            in: "Your token: \(Self.fakeToken) — copy it"
        )
        #expect(!redacted.contains(Self.fakeToken))
        #expect(redacted.contains("[hidden]"))
    }

    // MARK: - Parsing an existing `claude login`

    @Test func theTokenIsPulledFromClaudeCodesNestedBlobShape() throws {
        let blob = Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(Self.fakeToken)",
            "refreshToken": "sk-ant-ort01-whatever",
            "expiresAt": 9999999999,
            "scopes": ["user:inference"]
          }
        }
        """.utf8)
        #expect(ClaudeCodeLogin.extractOAuthToken(fromClaudeCodeCredentialBlob: blob) == Self.fakeToken)
    }

    @Test func aTopLevelAccessTokenIsAcceptedAsAFallbackShape() throws {
        let blob = Data("""
        {"accessToken": "\(Self.fakeToken)"}
        """.utf8)
        #expect(ClaudeCodeLogin.extractOAuthToken(fromClaudeCodeCredentialBlob: blob) == Self.fakeToken)
    }

    @Test func anUnexpectedOrEmptyBlobYieldsNoToken() {
        // Not JSON at all.
        #expect(ClaudeCodeLogin.extractOAuthToken(
            fromClaudeCodeCredentialBlob: Data("not json".utf8)
        ) == nil)
        // JSON, but no token anywhere (e.g. an API-key-only login).
        #expect(ClaudeCodeLogin.extractOAuthToken(
            fromClaudeCodeCredentialBlob: Data(#"{"claudeAiOauth":{"scopes":[]}}"#.utf8)
        ) == nil)
        // An empty token string is treated as no token, not an empty credential.
        #expect(ClaudeCodeLogin.extractOAuthToken(
            fromClaudeCodeCredentialBlob: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
        ) == nil)
    }
}
