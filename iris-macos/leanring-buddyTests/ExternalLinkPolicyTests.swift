//
//  ExternalLinkPolicyTests.swift
//  leanring-buddyTests
//
//  Regression coverage for the 2026-09-06 anthropic-api-key guide fix round:
//  console.anthropic.com was entirely absent from `ExternalLinkPolicy`'s
//  allowlist, so the guide's step-1 "Open the console" button computed to
//  `.openLinkIsUnavailable` and rendered as a visibly-disabled control that
//  does nothing when pressed — read live as "the Open button opens a blank
//  window instead of the console." Anthropic also 302s that host to
//  platform.claude.com now, so both are covered here.
//

import Foundation
import Testing
@testable import Iris

struct ExternalLinkPolicyTests {

    @Test func theAnthropicConsoleGuideStepHostIsAllowlisted() {
        #expect(
            ExternalLinkPolicy.isAllowedExternalURL(
                "https://console.anthropic.com/settings/keys"
            )
        )
        #expect(ExternalLinkPolicy.isAllowedExternalHost("console.anthropic.com"))
    }

    // Anthropic now redirects console.anthropic.com to platform.claude.com
    // (page titled "Claude Console"). Both hosts stay allowlisted so a future
    // redirect-back does not silently re-break this guide the way the missing
    // host did originally.
    @Test func theClaudeConsoleRedirectHostIsAlsoAllowlisted() {
        #expect(
            ExternalLinkPolicy.isAllowedExternalURL(
                "https://platform.claude.com/settings/keys"
            )
        )
        #expect(ExternalLinkPolicy.isAllowedExternalHost("platform.claude.com"))
    }

    // A lookalike host must never ride in on the substring — matching
    // `isAllowedExternalHost`'s own documented guarantee for every entry.
    @Test func aLookalikeAnthropicHostIsStillRefused() {
        #expect(
            ExternalLinkPolicy.isAllowedExternalURL(
                "https://console.anthropic.com.evil.tld/settings/keys"
            ) == false
        )
    }
}
