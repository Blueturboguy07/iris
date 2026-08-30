//
//  AssistantSpendLedgerTests.swift
//  leanring-buddyTests
//
//  The founder's ruling, in his words: "why do we fucking care? ... if they're
//  using API for open AI or from anthropic it should show a counter of how much
//  money was spent per query and then in the settings menu it should show how
//  much you spent."
//
//  So the ledger replaces a cap. Two things have to be right for that to be an
//  improvement rather than a downgrade: it must never bill a reader for a query
//  that cost them nothing, and it must never report a cost it does not know as
//  zero.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct AssistantSpendLedgerTests {

    private func isolatedLedger() throws -> AssistantSpendLedger {
        AssistantSpendLedger(
            userDefaults: try #require(UserDefaults(suiteName: "iris.spend.tests.\(UUID().uuidString)"))
        )
    }

    // MARK: - Whose money

    /// The distinction the whole feature rests on. Three of the four routes cost
    /// the reader nothing extra for one more query, and pricing their tokens
    /// would invent a bill: publik pays for the funded tier, and a Claude Code
    /// login and the Codex CLI are flat-rate plans.
    @Test("only the reader's own API key is counted")
    func onlyMeteredRoutesAreCounted() throws {
        let ledger = try isolatedLedger()
        let usage = AssistantTokenUsage(inputTokens: 1_000, outputTokens: 1_000)

        ledger.record(model: "claude-sonnet-4-6", usage: usage, route: .publiksFundedTier)
        ledger.record(model: "claude-sonnet-4-6", usage: usage, route: .aFlatRateSubscription)
        #expect(ledger.totalCalls == 0)
        #expect(ledger.totalSpent == 0)
        #expect(ledger.mostRecentCall == nil, "a flat-rate query must not show a price")

        ledger.record(model: "claude-sonnet-4-6", usage: usage, route: .theReadersOwnAPIKey)
        #expect(ledger.totalCalls == 1)
        #expect(ledger.totalSpent > 0)
    }

    /// A Claude Code OAuth token is the reader's OWN credential and still is not
    /// metered — which is exactly the case a future edit is most likely to get
    /// wrong, because it looks like the API-key case at the call site.
    @Test("a Claude Code login is the reader's own credential and still costs nothing per query")
    func anOAuthTokenIsNotMetered() {
        #expect(AssistantTransport.bringYourOwnOAuthToken(anthropicOAuthToken: "sk-ant-oat-x")
            .spendRoute == .aFlatRateSubscription)
        #expect(AssistantTransport.bringYourOwnKey(anthropicAPIKey: "sk-ant-x")
            .spendRoute == .theReadersOwnAPIKey)
        #expect(!AssistantSpendRoute.aFlatRateSubscription.isMetered)
        #expect(AssistantSpendRoute.theReadersOwnAPIKey.isMetered)
    }

    // MARK: - The arithmetic

    /// A million of each token at Sonnet's published rates, so the sum is
    /// checkable by hand: 3 + 3.75 + 0.30 + 15 = 22.05.
    @Test("cost is the published rate, and cache tiers are priced apart")
    func costMatchesThePublishedRate() throws {
        let sonnet = try #require(AssistantModelPrices.pricing(forModel: "claude-sonnet-4-6"))
        let oneMillionOfEach = AssistantTokenUsage(
            inputTokens: 1_000_000, cacheWriteTokens: 1_000_000,
            cacheReadTokens: 1_000_000, outputTokens: 1_000_000
        )
        #expect(sonnet.cost(of: oneMillionOfEach) == Decimal(string: "22.05"))

        // Cache reads are an order of magnitude cheaper than fresh input.
        // Folding them together would overstate exactly the long conversations
        // Iris has most of.
        let cached = AssistantTokenUsage(cacheReadTokens: 1_000_000)
        let fresh = AssistantTokenUsage(inputTokens: 1_000_000)
        #expect(sonnet.cost(of: cached) < sonnet.cost(of: fresh))
    }

    /// A dated snapshot id must resolve to its family, and the longer prefix
    /// must win so a specific row can override a general one.
    @Test("a dated model id resolves to its family, longest prefix winning")
    func priceLookupMatchesByLongestPrefix() throws {
        let dated = try #require(AssistantModelPrices.pricing(forModel: "claude-sonnet-4-6-20260115"))
        let family = try #require(AssistantModelPrices.pricing(forModel: "claude-sonnet-4-6"))
        #expect(dated == family)

        // "gpt-4o-mini" must not resolve to the pricier "gpt-4o" row.
        let mini = try #require(AssistantModelPrices.pricing(forModel: "gpt-4o-mini"))
        let full = try #require(AssistantModelPrices.pricing(forModel: "gpt-4o"))
        #expect(mini.inputPerMillion < full.inputPerMillion)
    }

    // MARK: - Not knowing, said out loud

    /// The rule the file exists to enforce. The price table is hardcoded
    /// published rates and rates change; a model it has never heard of must cost
    /// `nil`, and the total must announce that it is a floor. A silent $0.00
    /// would quietly understate what somebody spent.
    @Test("an unknown model costs nil, never zero, and the total says so")
    func anUnpricedModelIsNeverCountedAsFree() throws {
        let ledger = try isolatedLedger()
        #expect(AssistantModelPrices.pricing(forModel: "some-model-shipped-next-year") == nil)

        ledger.record(
            model: "some-model-shipped-next-year",
            usage: AssistantTokenUsage(inputTokens: 500_000, outputTokens: 500_000),
            route: .theReadersOwnAPIKey
        )

        #expect(ledger.totalCalls == 1, "the call still happened and still cost real money")
        #expect(ledger.mostRecentCall?.cost == nil)
        #expect(ledger.someCallsCouldNotBePriced)
        #expect(ledger.totalSpentText.hasPrefix("at least "),
                "a total containing an unpriced call is a floor, not a fact")
    }

    /// A query that costs a fraction of a cent must not render as "$0.00" and
    /// read as free — that is the common case for a single chat turn.
    @Test("a sub-cent query shows a real number rather than rounding to nothing")
    func subCentCostsAreNotRoundedAwayToZero() {
        let tinyButReal = Decimal(string: "0.0004")!
        let text = AssistantSpendLedger.moneyText(tinyButReal)
        #expect(text != "$0.00")
        #expect(text.contains("0.0004"))
        // Ordinary amounts still read like money.
        #expect(AssistantSpendLedger.moneyText(Decimal(string: "12.30")!) == "$12.30")
    }

    // MARK: - Across launches

    @Test("the total survives a relaunch, and reset clears it")
    func theTotalPersistsAndResets() throws {
        let suiteName = "iris.spend.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))

        let firstLaunch = AssistantSpendLedger(userDefaults: defaults)
        firstLaunch.record(
            model: "claude-sonnet-4-6",
            usage: AssistantTokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000),
            route: .theReadersOwnAPIKey
        )
        let spentBefore = firstLaunch.totalSpent
        #expect(spentBefore == Decimal(18))  // 3 + 15

        let afterRelaunch = AssistantSpendLedger(userDefaults: defaults)
        #expect(afterRelaunch.totalSpent == spentBefore)
        #expect(afterRelaunch.totalCalls == 1)

        afterRelaunch.clearTheRunningTotal()
        #expect(afterRelaunch.totalSpent == 0)
        #expect(AssistantSpendLedger(userDefaults: defaults).totalSpent == 0)
    }

    /// A call that reported no tokens at all is not a call worth a row — it is
    /// almost always a failure that never reached the model.
    @Test("a call that consumed nothing is not recorded")
    func anEmptyUsageIsIgnored() throws {
        let ledger = try isolatedLedger()
        ledger.record(model: "claude-sonnet-4-6", usage: AssistantTokenUsage(), route: .theReadersOwnAPIKey)
        #expect(ledger.totalCalls == 0)
    }

    // MARK: - Reading it off the wire

    /// Anthropic splits usage across two SSE events: `message_start` carries the
    /// input side including the cache counts, `message_delta` the output count.
    /// Getting this wrong is silent — the reader just sees a number that is too
    /// small — so it is pinned against the real event shapes.
    @Test("usage is read from the two events Anthropic splits it across")
    func usageIsReadFromTheStream() {
        var usage = AssistantTokenUsage()

        ClaudeAPI.readUsage(
            from: ["message": ["usage": [
                "input_tokens": 1_200,
                "cache_creation_input_tokens": 300,
                "cache_read_input_tokens": 9_000,
            ]]],
            ofType: "message_start", into: &usage
        )
        ClaudeAPI.readUsage(
            from: ["usage": ["output_tokens": 450]],
            ofType: "message_delta", into: &usage
        )

        #expect(usage.inputTokens == 1_200)
        #expect(usage.cacheWriteTokens == 300)
        #expect(usage.cacheReadTokens == 9_000)
        #expect(usage.outputTokens == 450)

        // An unrelated event must not disturb what has been gathered.
        ClaudeAPI.readUsage(from: ["delta": ["text": "hi"]], ofType: "content_block_delta", into: &usage)
        #expect(usage.outputTokens == 450)
    }

    /// Some streams report a RUNNING output figure on several deltas rather than
    /// one final total. Summing those would multiply the reader's bill, so the
    /// reader keeps the maximum rather than accumulating.
    @Test("a repeated output count is not added to itself")
    func repeatedDeltasDoNotDoubleCount() {
        var usage = AssistantTokenUsage()
        for runningTotal in [10, 40, 90] {
            ClaudeAPI.readUsage(
                from: ["usage": ["output_tokens": runningTotal]],
                ofType: "message_delta", into: &usage
            )
        }
        #expect(usage.outputTokens == 90, "not 140")
    }
}
