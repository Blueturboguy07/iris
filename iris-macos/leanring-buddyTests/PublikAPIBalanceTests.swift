//
//  PublikAPIBalanceTests.swift
//  leanring-buddyTests
//
//  Balance + Add credit in Iris (founder decision, 2026-09-22): the balance
//  line, the "Last reply" cost line, the low-balance warning, and the one link
//  "Add credit" opens.
//
//  The `/balance` bodies are read from `iris-windows/tests/fixtures/publik-balance`,
//  the same bytes the Windows suite (`publik-balance.test.ts`) parses, so the
//  two clients are held to one shape. They are modelled on what the gateway's
//  `walletBody` actually returns (publik repo, `lib/publik-api/wallet.ts`).
//

import Foundation
import Testing
@testable import Iris

@Suite("publik API balance and Add credit")
@MainActor
struct PublikAPIBalanceTests {

    private func balanceFixture(named fixtureFileName: String) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // leanring-buddyTests
            .deletingLastPathComponent()   // iris-macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("iris-windows/tests/fixtures/publik-balance")
            .appendingPathComponent(fixtureFileName)
        return try Data(contentsOf: fixtureURL)
    }

    private func jsonData(_ jsonText: String) -> Data {
        Data(jsonText.utf8)
    }

    // MARK: Reading GET /balance

    @Test func anAnonymousInstallShowsItsBalanceAndLinksToTheClaimPage() throws {
        let snapshot = try #require(PublikAPIWalletSnapshot.parse(
            balanceResponseBody: try balanceFixture(named: "anonymous.json")
        ))
        #expect(snapshot.balanceMicros == 181_240)
        #expect(snapshot.claimState == .anonymous)
        #expect(PublikAPIMoney.balanceLine(balanceMicros: snapshot.balanceMicros) == "$0.18 left")
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: snapshot.balanceMicros))
        #expect(PublikAPIAddCredit.urlString(for: snapshot) == "https://publikhq.com/claim/HK7F-2QWD")
    }

    @Test func aClaimedInstallShowsItsBalanceAndLinksToTheAddCreditPage() throws {
        let snapshot = try #require(PublikAPIWalletSnapshot.parse(
            balanceResponseBody: try balanceFixture(named: "claimed.json")
        ))
        #expect(snapshot.balanceMicros == 1_843_210)
        #expect(snapshot.claimState == .claimed)
        #expect(PublikAPIMoney.balanceLine(balanceMicros: snapshot.balanceMicros) == "$1.84 left")
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: snapshot.balanceMicros) == false)
        #expect(PublikAPIAddCredit.urlString(for: snapshot) == "https://publikhq.com/dashboard/api/add")
    }

    @Test func withoutATopUpURLTheClaimStateDecidesWhichPageOpens() throws {
        // An older answer, or /installs, carries no top_up_url. The same two
        // links are present in both bodies, so only the claim state can be
        // what sends one to the claim page and the other to add-credit.
        let anonymous = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData("""
            {"balance_micros": 90000, "claim_state": "anonymous",
             "claim_url": "https://publikhq.com/claim/AB12-CD34",
             "add_credit_url": "https://publikhq.com/dashboard/api/add"}
            """)))
        let claimed = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData("""
            {"balance_micros": 90000, "claim_state": "claimed",
             "claim_url": "https://publikhq.com/claim/AB12-CD34",
             "add_credit_url": "https://publikhq.com/dashboard/api/add"}
            """)))
        #expect(PublikAPIAddCredit.urlString(for: anonymous) == "https://publikhq.com/claim/AB12-CD34")
        #expect(PublikAPIAddCredit.urlString(for: claimed) == "https://publikhq.com/dashboard/api/add")
    }

    @Test func aLinkThatIsNotAPublikPageIsNeverOpened() throws {
        // The gateway is trusted, but a link Iris opens in the reader's browser
        // is checked anyway: a top_up_url off publik, or over plain http, falls
        // through to the claim-state link, and with nothing usable at all the
        // add-credit page is the answer.
        let foreignTopUp = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData("""
            {"available_micros": 5, "claim_state": "anonymous",
             "top_up_url": "https://publikhq.com.evil.example/claim/AB12-CD34",
             "claim_url": "https://publikhq.com/claim/AB12-CD34"}
            """)))
        #expect(PublikAPIAddCredit.urlString(for: foreignTopUp) == "https://publikhq.com/claim/AB12-CD34")

        let plainHTTPOnly = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData("""
            {"available_micros": 5, "claim_state": "claimed",
             "top_up_url": "http://publikhq.com/dashboard/api/add"}
            """)))
        #expect(PublikAPIAddCredit.urlString(for: plainHTTPOnly) == PublikAPIAddCredit.fallbackURLString)
        #expect(PublikAPIAddCredit.urlString(for: nil) == "https://publikhq.com/dashboard/api/add")
    }

    @Test func aBodyWithNoBalanceIsNotReadAsZero() {
        // A 200 that carries no balance must leave the last good number on
        // screen rather than replace it with "$0.00 left".
        #expect(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData(#"{"claim_state":"claimed"}"#)) == nil)
        #expect(PublikAPIWalletSnapshot.parse(balanceResponseBody: jsonData("not json")) == nil)
    }

    @Test func theOutOfCreditRefusalOpensTheSamePageAsTheBalanceRow() throws {
        // The two "Add credit" buttons — under the 402 in the bar and in the
        // settings panel — must land on one page. Both bodies below are the
        // gateway's own shapes for the same anonymous install.
        let refusal = try #require(PublikAPIInsufficientCredit.parse(responseBody: jsonData("""
            {"type": "error", "error": {"type": "insufficient_credit",
             "message": "Not enough publik credit for this request.",
             "available_micros": 1240, "claim_state": "anonymous",
             "top_up_url": "https://publikhq.com/claim/HK7F-2QWD",
             "claim_url": "https://publikhq.com/claim/HK7F-2QWD",
             "add_credit_url": "https://publikhq.com/dashboard/api/add"}}
            """)))
        let balance = try #require(PublikAPIWalletSnapshot.parse(
            balanceResponseBody: try balanceFixture(named: "anonymous.json")
        ))
        #expect(PublikAPIAddCredit.urlString(for: refusal) == PublikAPIAddCredit.urlString(for: balance))
        #expect(PublikAPIAddCredit.urlString(for: refusal) == "https://publikhq.com/claim/HK7F-2QWD")
    }

    // MARK: The low-balance line

    @Test func theWarningStartsJustUnderAQuarterAndNotAtIt() {
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: 250_000) == false)
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: 249_999))
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: 0))
        #expect(PublikAPIMoney.balanceIsLow(balanceMicros: 250_001) == false)
    }

    // MARK: The charge header

    @Test func theChargeHeaderIsReadWhenItIsAWholeNumberAndIgnoredOtherwise() {
        #expect(PublikAPIMicrosHeader.micros(fromHeaderValue: "4321") == 4_321)
        #expect(PublikAPIMicrosHeader.micros(fromHeaderValue: " 4321 ") == 4_321)
        #expect(PublikAPIMicrosHeader.micros(fromHeaderValue: "0") == 0)
        for malformedValue in ["abc", "-5", "1.5", "", "   ", "12abc", "٤٣٢١"] {
            #expect(PublikAPIMicrosHeader.micros(fromHeaderValue: malformedValue) == nil, "read: \(malformedValue)")
        }
        #expect(PublikAPIMicrosHeader.micros(fromHeaderValue: nil) == nil)
    }

    @Test func aSettledAnswerIsPricedByTheGatewayAndCarriesItsBalance() {
        let headers = ["x-publik-charge-micros": "4321", "x-publik-balance": "1838889"]
        let receipt = PublikAPICallReceipt(
            headerValue: { headers[$0] },
            modelAlias: PublikAPIModelAlias.balanced,
            // Usage that would price to a DIFFERENT figure, so the assertion
            // proves the header won rather than coinciding with it.
            usage: AssistantTokenUsage(inputTokens: 2_000, outputTokens: 500)
        )
        #expect(receipt.chargeMicros == 4_321)
        #expect(receipt.settledBalanceMicros == 1_838_889)
    }

    @Test func aStreamedReplyIsPricedFromItsUsageAndItsBalanceHeaderIsNotTrusted() {
        // A stream's x-publik-balance is written before the charge, with the
        // call's hold still taken out. The receipt must not pass it on.
        let headers = ["x-publik-balance": "1500000", "x-publik-reserved-micros": "99000"]
        let receipt = PublikAPICallReceipt(
            headerValue: { headers[$0] },
            modelAlias: PublikAPIModelAlias.balanced,
            usage: AssistantTokenUsage(inputTokens: 2_000, outputTokens: 500)
        )
        #expect(receipt.chargeMicros == 10_000)
        #expect(receipt.settledBalanceMicros == nil)
    }

    @Test func aMalformedChargeHeaderFallsBackToTheUsage() {
        let headers = ["x-publik-charge-micros": "n/a", "x-publik-balance": "1500000"]
        let receipt = PublikAPICallReceipt(
            headerValue: { headers[$0] },
            modelAlias: PublikAPIModelAlias.fast,
            usage: AssistantTokenUsage(inputTokens: 2_000, outputTokens: 500)
        )
        #expect(receipt.chargeMicros == 1_000)
        #expect(receipt.settledBalanceMicros == nil)
    }

    @Test func aCallWithNoUsageAndNoHeaderHasNoPriceRatherThanZero() {
        let receipt = PublikAPICallReceipt(
            headerValue: { _ in nil },
            modelAlias: PublikAPIModelAlias.balanced,
            usage: AssistantTokenUsage()
        )
        #expect(receipt.chargeMicros == nil)
    }

    // MARK: What a message costs

    @Test func theTypicalMessageIsPricedFromTheTierByHand() {
        // 2,000 in and 500 out, per million tokens:
        //   balanced: 2000 × $2   + 500 × $12   = $0.004 + $0.006 = $0.010
        //   fast:     2000 × $0.2 + 500 × $1.2  = $0.0004 + $0.0006 = $0.001
        //   smart:    2000 × $4   + 500 × $20   = $0.008 + $0.010 = $0.018
        #expect(PublikAPITierPrice.balanced.typicalMessageChargeMicros == 10_000)
        #expect(PublikAPITierPrice.fast.typicalMessageChargeMicros == 1_000)
        #expect(PublikAPITierPrice.smart.typicalMessageChargeMicros == 18_000)
        #expect(PublikAPIMoney.costDescription(forMicros: 10_000) == "$0.010")
        #expect(PublikAPIMoney.costDescription(forMicros: 18_000) == "$0.018")
    }

    @Test func aStreamedChargeMatchesTheGatewaysOwnWorkedExample() {
        // publik repo, lib/publik-api/pricing/supply.test.ts: 1,000 input of
        // which 200 cached, 500 output on publik-balanced →
        // 800 × 2 = 1600, 200 × 0.2 = 40, 500 × 12 = 6000 → 7640 micros.
        // The gateway's Anthropic frames report that as input 800 (reads out),
        // cache_read 200.
        let usageAsTheStreamReportsIt = AssistantTokenUsage(
            inputTokens: 800, cacheWriteTokens: 0, cacheReadTokens: 200, outputTokens: 500
        )
        #expect(PublikAPITierPrice.balanced.chargeMicros(for: usageAsTheStreamReportsIt) == 7_640)
    }

    @Test func cacheWritesInsideTheInputCountAreNotChargedTwice() {
        // The gateway's converter leaves cache writes inside input_tokens and
        // prices them apart at the write rate. 1,000 input including 100
        // written: 900 × $2 + 100 × $2.5 = 1800 + 250 = 2050 micros.
        let usage = AssistantTokenUsage(inputTokens: 1_000, cacheWriteTokens: 100, cacheReadTokens: 0, outputTokens: 0)
        #expect(PublikAPITierPrice.balanced.chargeMicros(for: usage) == 2_050)
    }

    @Test func aCostIsShownToATenthOfACentAndNeverAsFree() {
        #expect(PublikAPIMoney.costDescription(forMicros: 4_321) == "$0.004")
        #expect(PublikAPIMoney.costDescription(forMicros: 4_500) == "$0.005")
        #expect(PublikAPIMoney.costDescription(forMicros: 1_234_567) == "$1.235")
        #expect(PublikAPIMoney.costDescription(forMicros: 400) == "under $0.001")
        #expect(PublikAPIMoney.costDescription(forMicros: 0) == "$0.00")
    }

    @Test func theCostLineNamesTheTierBeforeTheFirstReplyAndTheReplyAfter() throws {
        let beforeAnyReply = try #require(PublikAPIMoney.costPerMessageLine(
            lastReplyChargeMicros: nil,
            modelAlias: PublikAPIModelAlias.alias(forIrisModelName: "claude-sonnet-4-6")
        ))
        #expect(beforeAnyReply == "About $0.010 per message on publik-balanced")

        let afterAReply = try #require(PublikAPIMoney.costPerMessageLine(
            lastReplyChargeMicros: 4_321,
            modelAlias: PublikAPIModelAlias.balanced
        ))
        #expect(afterAReply == "Last reply: $0.004")

        // The copy rule: dollars, never tokens, never "credits".
        for line in [beforeAnyReply, afterAReply, PublikAPIMoney.balanceLine(balanceMicros: 181_240)] {
            #expect(!line.lowercased().contains("token"), "\(line)")
            #expect(!line.lowercased().contains("credit"), "\(line)")
        }
        #expect(PublikAPIMoney.costPerMessageLine(lastReplyChargeMicros: nil, modelAlias: "publik-unknown") == nil)
    }

    // MARK: One reply, however many calls

    @Test func everyCallOfOneReplyAddsUpAndCallsOutsideAReplyDoNot() {
        var tally = PublikAPIReplyCostTally()
        tally.addACall(chargeMicros: 7_000)
        #expect(tally.lastReplyChargeMicros == nil, "a call outside any reply was counted")

        let firstReply = tally.beginAReply()
        tally.addACall(chargeMicros: 3_000)
        tally.addACall(chargeMicros: 1_500)
        #expect(tally.lastReplyChargeMicros == 4_500)
        tally.finishTheReply(firstReply)
        tally.addACall(chargeMicros: 900)
        #expect(tally.lastReplyChargeMicros == 4_500)
    }

    @Test func aCancelledReplyFinishingLateDoesNotCloseItsReplacement() {
        var tally = PublikAPIReplyCostTally()
        let cancelledReply = tally.beginAReply()
        let replacementReply = tally.beginAReply()
        tally.finishTheReply(cancelledReply)
        tally.addACall(chargeMicros: 2_000)
        #expect(tally.lastReplyChargeMicros == 2_000)
        tally.finishTheReply(replacementReply)
        #expect(tally.replyInProgress == nil)
    }

    @Test func theAccountAddsTheCallsOfOneReplyIntoItsLastReplyLine() throws {
        let suiteName = "iris.tests.publik-balance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Every request this account makes is refused on the spot, so the
        // balance read a receipt schedules can never reach a network.
        let refusingConfiguration = URLSessionConfiguration.ephemeral
        refusingConfiguration.protocolClasses = [RefuseEveryRequestURLProtocol.self]
        let account = PublikAPIAccount(
            userDefaults: defaults,
            urlSession: URLSession(configuration: refusingConfiguration)
        )

        let reply = account.beginCountingAReply()
        account.noteACompletedCall(PublikAPICallReceipt(chargeMicros: 6_000, settledBalanceMicros: nil))
        account.noteACompletedCall(PublikAPICallReceipt(chargeMicros: 2_500, settledBalanceMicros: nil))
        account.finishCountingTheReply(reply)
        account.noteACompletedCall(PublikAPICallReceipt(chargeMicros: 9_999, settledBalanceMicros: nil))

        #expect(account.lastReplyChargeMicros == 8_500)
        // No balance has been read, so the button falls back to the add page.
        #expect(account.urlStringForTheAddCreditButton == "https://publikhq.com/dashboard/api/add")
    }
}

/// Fails every request immediately, so a test can hold an account whose
/// background balance read has nowhere to go.
private final class RefuseEveryRequestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
