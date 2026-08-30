//
//  AssistantSpendLedger.swift
//  leanring-buddy
//
//  WHAT THIS QUERY JUST COST YOU.
//
//  Iris used to cap the fix ladder at a fixed number of model calls no matter
//  whose money was paying. The founder's ruling was that this is backwards: a
//  reader who connected their own API key has already decided to spend, and
//  Anthropic and OpenAI both enforce their own limits — a ceiling invented on
//  top of that is paternalism, not safety. What was actually missing was never
//  a cap. It was the number.
//
//  So: no limit, and a running total instead.
//
//  ONLY METERED ROUTES ARE COUNTED, and the distinction matters more than it
//  looks. Four ways a call can be paid for, and only two of them cost the
//  reader anything per query:
//
//    - the reader's own API key (Anthropic or OpenAI)  -> METERED, count it
//    - publik's funded tier                            -> publik's money, not theirs
//    - a Claude Code OAuth token                       -> a SUBSCRIPTION, flat rate
//    - the Codex CLI (a ChatGPT plan)                  -> a SUBSCRIPTION, flat rate
//
//  Showing a dollar figure for a subscription route would be a lie: those
//  queries cost the reader exactly nothing extra, and a per-query price against
//  them would invent a bill that does not exist.
//
//  THE PRICE TABLE GOES STALE. It is a hardcoded list of published rates, and
//  published rates change (CapCut doubled overnight; so can these). The whole
//  design point is what happens for a model the table does not know: the cost is
//  `nil`, the UI says the tokens but not a price, and the total says it is
//  incomplete. It NEVER falls back to zero. A silent $0.00 would quietly
//  understate what somebody spent, which is the one outcome worse than saying
//  "I don't know".
//

import Combine
import Foundation

// MARK: - What a call consumed

/// The token counts one model call reported. Cache reads and writes are held
/// apart from ordinary input because they are priced differently — a cache read
/// is an order of magnitude cheaper, and folding them together would overstate
/// the cost of exactly the long conversations Iris has most of.
nonisolated struct AssistantTokenUsage: Equatable, Sendable {
    var inputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var outputTokens: Int = 0

    var isEmpty: Bool {
        inputTokens == 0 && cacheWriteTokens == 0 && cacheReadTokens == 0 && outputTokens == 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

// MARK: - What it costs

/// Published per-million-token rates for one model.
nonisolated struct AssistantModelPricing: Equatable, Sendable {
    let inputPerMillion: Decimal
    let cacheWritePerMillion: Decimal
    let cacheReadPerMillion: Decimal
    let outputPerMillion: Decimal

    /// `Decimal` rather than `Double` throughout: these are prices, they get
    /// summed thousands of times over a session, and binary floating point
    /// drifts in exactly the last cents a person would notice.
    func cost(of usage: AssistantTokenUsage) -> Decimal {
        let million = Decimal(1_000_000)
        return (Decimal(usage.inputTokens) * inputPerMillion
            + Decimal(usage.cacheWriteTokens) * cacheWritePerMillion
            + Decimal(usage.cacheReadTokens) * cacheReadPerMillion
            + Decimal(usage.outputTokens) * outputPerMillion) / million
    }
}

nonisolated enum AssistantModelPrices {

    /// Rates as published when this was written. Matched by PREFIX, so a dated
    /// snapshot id (`claude-sonnet-4-6-20260115`) resolves to its family without
    /// needing a new row every time a snapshot ships.
    ///
    /// Longest prefix wins, so a more specific row can override a family.
    static let table: [(modelPrefix: String, pricing: AssistantModelPricing)] = [
        ("claude-opus-4", AssistantModelPricing(
            inputPerMillion: 15, cacheWritePerMillion: 18.75,
            cacheReadPerMillion: 1.50, outputPerMillion: 75
        )),
        ("claude-sonnet-4", AssistantModelPricing(
            inputPerMillion: 3, cacheWritePerMillion: 3.75,
            cacheReadPerMillion: 0.30, outputPerMillion: 15
        )),
        ("claude-haiku-4", AssistantModelPricing(
            inputPerMillion: 1, cacheWritePerMillion: 1.25,
            cacheReadPerMillion: 0.10, outputPerMillion: 5
        )),
        ("gpt-4o-mini", AssistantModelPricing(
            inputPerMillion: 0.15, cacheWritePerMillion: 0.15,
            cacheReadPerMillion: 0.075, outputPerMillion: 0.60
        )),
        ("gpt-4o", AssistantModelPricing(
            inputPerMillion: 2.50, cacheWritePerMillion: 2.50,
            cacheReadPerMillion: 1.25, outputPerMillion: 10
        )),
    ]

    /// Nil for a model the table has never heard of — deliberately, so the UI
    /// can say "not priced" rather than "$0.00".
    static func pricing(forModel model: String) -> AssistantModelPricing? {
        table
            .filter { model.hasPrefix($0.modelPrefix) }
            .max { $0.modelPrefix.count < $1.modelPrefix.count }?
            .pricing
    }
}

// MARK: - Whose money

/// Whether a call is billed to the reader per token, and so whether a dollar
/// figure is honest to show for it.
nonisolated enum AssistantSpendRoute: String, Sendable {
    /// The reader's own API key. Metered: every token is on their bill.
    case theReadersOwnAPIKey
    /// publik pays. Real money, but not the reader's, so it is not their total.
    case publiksFundedTier
    /// A Claude Code login or the Codex CLI — a flat-rate plan. The marginal
    /// cost of one more query is zero.
    case aFlatRateSubscription

    var isMetered: Bool { self == .theReadersOwnAPIKey }
}

// MARK: - The ledger

/// One recorded call, kept so the panel can show the last one and the total.
nonisolated struct AssistantSpendEntry: Equatable, Sendable {
    let model: String
    let usage: AssistantTokenUsage
    /// Nil when the model is not in the price table. Not zero. See the file note.
    let cost: Decimal?
    let at: Date
}

/// Records what the reader's own key has spent, this launch and cumulatively.
///
/// Deliberately NOT a gate. Nothing here can refuse a call or slow one down —
/// it is told what happened after the fact. That is the whole point: the
/// founder's ruling was to stop capping and start reporting.
@MainActor
final class AssistantSpendLedger: ObservableObject {

    /// The most recent metered call, for the "this query cost you" line.
    @Published private(set) var mostRecentCall: AssistantSpendEntry?
    /// Everything the reader's own key has spent, across launches.
    @Published private(set) var totalSpent: Decimal = 0
    @Published private(set) var totalCalls: Int = 0
    /// True once any metered call used a model the price table does not know,
    /// so the total can be shown as a floor ("at least $X") rather than a fact.
    @Published private(set) var someCallsCouldNotBePriced: Bool = false

    /// The ledger this app is running on.
    ///
    /// A reference rather than a threaded parameter because the Tier C
    /// providers are built inside a STATIC factory (`MaintainModelProvider`'s
    /// candidate list) that nothing can hand an instance to, and threading a
    /// closure through every construction site is a worse trade than one weak
    /// pointer set once at launch. Weak so a test that makes its own ledger
    /// cannot leak it into the next test.
    static weak var shared: AssistantSpendLedger?

    private let userDefaults: UserDefaults

    private enum Key {
        static let total = "iris:spend:totalUSD"
        static let calls = "iris:spend:callCount"
        static let unpriced = "iris:spend:someCallsUnpriced"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Stored as a string so the decimal survives the round trip exactly;
        // UserDefaults would otherwise hand it back through a Double.
        if let storedTotal = userDefaults.string(forKey: Key.total),
           let restored = Decimal(string: storedTotal) {
            totalSpent = restored
        }
        totalCalls = userDefaults.integer(forKey: Key.calls)
        someCallsCouldNotBePriced = userDefaults.bool(forKey: Key.unpriced)
    }

    /// The default sink for a provider that cannot be handed a ledger directly.
    /// A no-op when nothing has claimed `shared`, which is the state every test
    /// starts in.
    nonisolated static func recordOnTheSharedLedger(
        model: String, usage: AssistantTokenUsage, route: AssistantSpendRoute
    ) {
        Task { @MainActor in shared?.record(model: model, usage: usage, route: route) }
    }

    /// Record one finished call. Anything that is not metered is dropped on the
    /// floor here rather than at each call site, so a new provider cannot
    /// accidentally start billing a subscription reader by forgetting to check.
    func record(model: String, usage: AssistantTokenUsage, route: AssistantSpendRoute) {
        guard route.isMetered, !usage.isEmpty else { return }

        let pricing = AssistantModelPrices.pricing(forModel: model)
        let cost = pricing?.cost(of: usage)
        let entry = AssistantSpendEntry(model: model, usage: usage, cost: cost, at: Date())

        mostRecentCall = entry
        totalCalls += 1
        if let cost {
            totalSpent += cost
        } else {
            someCallsCouldNotBePriced = true
            userDefaults.set(true, forKey: Key.unpriced)
        }
        userDefaults.set("\(totalSpent)", forKey: Key.total)
        userDefaults.set(totalCalls, forKey: Key.calls)
    }

    /// For the settings row's reset. Clears the running total only — it does not
    /// and cannot refund anything, so the wording at the call site says so.
    func clearTheRunningTotal() {
        totalSpent = 0
        totalCalls = 0
        someCallsCouldNotBePriced = false
        mostRecentCall = nil
        userDefaults.removeObject(forKey: Key.total)
        userDefaults.removeObject(forKey: Key.calls)
        userDefaults.removeObject(forKey: Key.unpriced)
    }

    // MARK: - Wording

    /// A price the way a person reads one. Sub-cent costs are the common case
    /// for a single chat turn, so they get the precision that makes them
    /// non-zero rather than rounding to "$0.00" and reading as free.
    nonisolated static func moneyText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        if amount > 0 && amount < 0.01 {
            formatter.minimumFractionDigits = 4
            formatter.maximumFractionDigits = 4
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }

    /// What the panel shows for the last query.
    var mostRecentCallText: String? {
        guard let mostRecentCall else { return nil }
        guard let cost = mostRecentCall.cost else {
            return "Last query: \(mostRecentCall.usage.outputTokens) tokens out (that model isn't in Iris's price list)"
        }
        return "Last query: \(Self.moneyText(cost))"
    }

    /// What the settings row shows. Says "at least" when any call could not be
    /// priced, because the true figure is then higher than the one on screen.
    var totalSpentText: String {
        let money = Self.moneyText(totalSpent)
        return someCallsCouldNotBePriced ? "at least \(money)" : money
    }
}
