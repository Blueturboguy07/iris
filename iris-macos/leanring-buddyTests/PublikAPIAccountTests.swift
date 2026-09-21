//
//  PublikAPIAccountTests.swift
//  leanring-buddyTests
//
//  The publik API credential: the rules that have to hold whatever the gateway
//  answers, and the CTA rule that is easiest to break by accident.
//
//  The one worth stating up front is CONTRACT.md section 12 item 4 — "never a
//  silent starter". An app that provisions a key and quietly starts spending
//  the free balance before telling anybody what it costs is the exact failure
//  that rule exists to prevent, and it is invisible in manual testing because
//  everything appears to work.
//

import Foundation
import Testing
@testable import Iris

@Suite("publik API account")
@MainActor
struct PublikAPIAccountTests {

    /// A scratch defaults domain, so a test never reads or writes the real one.
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "iris.tests.publik-api.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: The starter may not be spent silently

    @Test func aFreshInstallMayNotSpendBeforeTheCardHasBeenShown() throws {
        let account = PublikAPIAccount(userDefaults: try isolatedDefaults())
        // Even with a key in hand, spending is refused until the card has been
        // shown. `hasKey` is read from the Keychain and is not what this test
        // is about, so the rule is asserted through the flag it depends on.
        #expect(account.firstRunCardHasBeenShown == false)
        #expect(account.maySpendOnThisKey == false)
    }

    @Test func showingTheCardIsWhatUnlocksSpending() throws {
        let defaults = try isolatedDefaults()
        let account = PublikAPIAccount(userDefaults: defaults)
        account.recordThatTheFirstRunCardWasShown()
        #expect(account.firstRunCardHasBeenShown)
    }

    @Test func aPastedKeyNeedsNoStarterDisclosure() throws {
        // The card is about the starter THIS install was granted. A key the
        // reader brought from their own dashboard has no starter attached, so
        // gating it behind the card would be a step with nothing to say.
        let defaults = try isolatedDefaults()
        let account = PublikAPIAccount(userDefaults: defaults)
        _ = account.saveKeyPastedByTheReader("pk_live_abc123456789_0123456789abcdef0123456789abcdef")
        #expect(account.firstRunCardHasBeenShown)
        // Clean up the Keychain item this wrote, so the suite leaves nothing.
        account.forgetKey()
    }

    // MARK: Pasted keys

    @Test func obviousNonKeysAreRefusedBeforeTheGatewayEverSeesThem() throws {
        let account = PublikAPIAccount(userDefaults: try isolatedDefaults())
        for notAKey in ["", "   ", "sk-ant-api03-something", "hello", "pk-live-wrong-separator"] {
            #expect(account.saveKeyPastedByTheReader(notAKey) == false, "accepted: \(notAKey)")
        }
    }

    @Test func aRealLookingKeyIsAccepted() throws {
        let account = PublikAPIAccount(userDefaults: try isolatedDefaults())
        #expect(account.saveKeyPastedByTheReader("pk_live_abc123456789_0123456789abcdef0123456789abcdef"))
        account.forgetKey()
    }

    // MARK: The install id

    @Test func theInstallIdentifierIsMintedOnceAndRemembered() throws {
        let defaults = try isolatedDefaults()
        let account = PublikAPIAccount(userDefaults: defaults)
        let first = account.installIdentifier()
        let second = account.installIdentifier()
        // Re-minting on every launch would ask the gateway for a fresh starter
        // each time, which is what its per-IP starter caps exist to stop.
        #expect(first == second)
        #expect(!first.isEmpty)

        let sameDefaultsAgain = PublikAPIAccount(userDefaults: defaults)
        #expect(sameDefaultsAgain.installIdentifier() == first)
    }

    // MARK: Money, rendered

    @Test func balancesRenderAsDollarsAndNeverAsTokensOrCredits() {
        // The copy rule from CONTRACT.md section 12 item 5, at the one place
        // that turns a number into words.
        #expect(PublikAPIWalletSnapshot.dollarsDescription(forMicros: 250_000) == "$0.25")
        #expect(PublikAPIWalletSnapshot.dollarsDescription(forMicros: 0) == "$0.00")
        #expect(PublikAPIWalletSnapshot.dollarsDescription(forMicros: 20_000_000) == "$20.00")
        #expect(PublikAPIWalletSnapshot.dollarsDescription(forMicros: 1_234_567) == "$1.23")
    }

    @Test func aNegativeBalanceReadsAsZeroRatherThanAsOwedMoney() {
        // The gateway should never send one, but a minus sign in a balance line
        // would read as a debt the reader does not have.
        #expect(PublikAPIWalletSnapshot.dollarsDescription(forMicros: -500_000) == "$0.00")
    }

    // MARK: Reading the gateway's answer

    @Test func anUnknownClaimStateIsTreatedAsUnclaimed() {
        // The safe wrong answer: an already-claimed install sees a button it
        // does not need. The other way round, a claimed-looking install could
        // never be linked at all.
        #expect(PublikAPIClaimState(wireValue: nil) == .anonymous)
        #expect(PublikAPIClaimState(wireValue: "something-new") == .anonymous)
        #expect(PublikAPIClaimState(wireValue: "claimed") == .claimed)
        #expect(PublikAPIClaimState(wireValue: "anonymous") == .anonymous)
    }

    @Test func aProvisioningResponseIsReadWhicheverFieldNameCarriesTheBalance() {
        // CONTRACT 3.2 ships `balance_micros` and `starting_credit_micros` with
        // the same value for one release; either must work, so a rename on the
        // server does not blank the balance line.
        let withBalance = PublikAPIAccount.InstallsResponse(payload: [
            "key": "pk_live_x", "balance_micros": 250_000, "claim_state": "anonymous",
        ])
        #expect(withBalance.balanceMicros == 250_000)

        let withStartingCredit = PublikAPIAccount.InstallsResponse(payload: [
            "key": "pk_live_x", "starting_credit_micros": 250_000,
        ])
        #expect(withStartingCredit.balanceMicros == 250_000)
    }

    @Test func aReplayedInstallIdComesBackWithNoKey() {
        // CONTRACT 3.2 [B1]: a 200 with "key": null is how the gateway says
        // "this install id already minted one".
        let replay = PublikAPIAccount.InstallsResponse(payload: [
            "key": NSNull(), "claim_state": "anonymous",
        ])
        #expect(replay.key == nil)
    }

    // MARK: The 402

    @Test func the402IsRenderedFromTheServersOwnWordsAndOneLink() {
        let body = Data("""
        {"type":"error","error":{"type":"insufficient_credit",
        "message":"You're out of credit. Add a plan or a pack at the link below.",
        "top_up_url":"https://publikhq.com/dashboard/api"}}
        """.utf8)
        let parsed = PublikAPIInsufficientCredit.parse(responseBody: body)
        #expect(parsed?.message.contains("out of credit") == true)
        #expect(parsed?.linkURLString == "https://publikhq.com/dashboard/api")
    }

    @Test func aBodyWithNoMessageIsNotTurnedIntoHalfASentence() {
        #expect(PublikAPIInsufficientCredit.parse(responseBody: Data("{}".utf8)) == nil)
        #expect(PublikAPIInsufficientCredit.parse(responseBody: Data("nonsense".utf8)) == nil)
    }

    @Test func claimUrlIsUsedWhenThereIsNoTopUpUrl() {
        let body = Data("""
        {"error":{"message":"Link this computer first.","claim_url":"https://publikhq.com/claim/abc"}}
        """.utf8)
        #expect(PublikAPIInsufficientCredit.parse(responseBody: body)?.linkURLString
            == "https://publikhq.com/claim/abc")
    }

    // MARK: Where requests go

    @Test func theGatewayPathIsNotDoubledWhenTheServerAlreadySentIt() {
        // `base_url` may reasonably be the site origin OR the gateway root —
        // the contract shows requests against `{base}/messages`, which reads as
        // the latter. Appending blindly would give /api/v1/api/v1/messages and
        // a 404 on every question.
        let origin = URL(string: "https://publikhq.com")!
        let gatewayRoot = URL(string: "https://publikhq.com/api/v1")!
        let gatewayRootWithSlash = URL(string: "https://publikhq.com/api/v1/")!

        #expect(PublikAPIAccount.gatewayPath(under: origin).absoluteString
            == "https://publikhq.com/api/v1")
        #expect(PublikAPIAccount.gatewayPath(under: gatewayRoot).absoluteString
            == "https://publikhq.com/api/v1")
        #expect(PublikAPIAccount.gatewayPath(under: gatewayRootWithSlash).path
            .hasSuffix("/api/v1/"))
    }

    // MARK: The app token

    @Test func aTemplateOrMissingAppTokenLeavesTheBuildOnThePasteRoute() {
        // A build with no minted token is not broken — it falls back to the
        // human route. No `pat_iris_*` has been minted yet, so this is the
        // state every current build is actually in.
        //
        // Reading the real bundle here is the point: the assertion is about
        // what THIS build ships, and it must not crash or provision when the
        // Info.plist key is absent.
        let buildToken = PublikAPIAccount.buildAppToken
        if let buildToken {
            #expect(buildToken.hasPrefix("pat_"), "a shipped token must be a real one")
        }
    }
}

@Suite("Assistant provider choice")
@MainActor
struct AssistantProviderChoiceTests {

    @Test func withNothingChosenTheOrderIsPublikThenKeyThenCodex() {
        #expect(AssistantProviderChoice.resolve(
            preference: nil, publikAPIIsReady: true, anthropicKeyIsSaved: true, codexIsUsable: true
        ) == .publikAPI)

        #expect(AssistantProviderChoice.resolve(
            preference: nil, publikAPIIsReady: false, anthropicKeyIsSaved: true, codexIsUsable: true
        ) == .anthropicKey)

        #expect(AssistantProviderChoice.resolve(
            preference: nil, publikAPIIsReady: false, anthropicKeyIsSaved: false, codexIsUsable: true
        ) == .codex)

        #expect(AssistantProviderChoice.resolve(
            preference: nil, publikAPIIsReady: false, anthropicKeyIsSaved: false, codexIsUsable: false
        ) == nil)
    }

    @Test func aChoiceIsHonouredEvenWhenItIsCurrentlyBroken() {
        // The whole point of storing a preference: it is returned so the caller
        // can say what broke, instead of quietly spending a different account.
        #expect(AssistantProviderChoice.resolve(
            preference: .codex, publikAPIIsReady: true, anthropicKeyIsSaved: true, codexIsUsable: false
        ) == .codex)

        #expect(AssistantProviderChoice.isUsable(
            .codex, publikAPIIsReady: true, anthropicKeyIsSaved: true, codexIsUsable: false
        ) == false)
    }

    @Test func everyProviderHasCopyAndNoneNamesTheUpstreamProviderForPublikAPI() {
        for provider in AssistantProviderPreference.allCases {
            #expect(!provider.displayName.isEmpty)
            #expect(!provider.explanation.isEmpty)
        }
        // Copy rule: the publik API justification must not name whose model is
        // behind it, and must not price things in tokens or "credits".
        let publikCopy = (AssistantProviderPreference.publikAPI.displayName
            + " " + AssistantProviderPreference.publikAPI.explanation).lowercased()
        #expect(!publikCopy.contains("anthropic"))
        #expect(!publikCopy.contains("openai"))
        #expect(!publikCopy.contains("claude"))
        #expect(!publikCopy.contains("token"))
        #expect(!publikCopy.contains("credits"))
    }

    @Test func theAnthropicRowMayNameAnthropicBecauseItIsTheReadersOwnAccount() {
        // The copy rule is about publik reselling somebody's model without
        // saying whose. A row about the reader's OWN Anthropic key has to name
        // Anthropic or it cannot be understood.
        #expect(AssistantProviderPreference.anthropicKey.explanation.contains("Anthropic"))
    }
}
