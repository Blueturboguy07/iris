//
//  ModelPriceComparison.swift
//  leanring-buddy
//
//  The side-by-side Iris shows next to "How Iris answers": publik API against
//  the reader's own Anthropic key against a ChatGPT plan (the Codex route), in
//  dollars per million tokens and an estimated dollars a month.
//
//  NO PRICE LIVES IN THIS APP. Every number comes from
//  `GET {publik}/api/iris/model-prices` (publik's `lib/iris-model-prices.ts`),
//  which reads publik's own tier prices from the code that bills them and
//  copies Anthropic's and OpenAI's from their published pages with the date
//  they were read. When that route cannot be reached the view says so; it
//  never falls back to a number compiled into the binary, because a stale
//  price shown as current is exactly the dishonest thing this exists to avoid.
//
//  The same response carries Anthropic's list prices per model, and the spend
//  ledger prices the reader's own-key calls from them once they have loaded
//  (`AssistantServerPublishedPrices`) — so "what your key spent" and "what
//  your key would cost" come from the same rows.
//

import Combine
import Foundation

/// The route's JSON, decoded as-is.
nonisolated struct ModelPriceComparison: Decodable, Equatable, Sendable {

    struct Assumption: Decodable, Equatable, Sendable {
        let questionsPerMonth: Int
        let inputTokensPerQuestion: Int
        let outputTokensPerQuestion: Int
        let summary: String
    }

    struct Option: Decodable, Equatable, Sendable, Identifiable {
        /// "publik-api", "anthropic-key" or "codex" — `AssistantProviderPreference`'s raw values.
        let provider: String
        let label: String
        let model: String
        /// The model that actually answers, when it differs from `model`.
        let servedBy: String?
        /// "per_token" or "subscription".
        let billing: String
        let inputUsdPerMillion: Double?
        let outputUsdPerMillion: Double?
        let estimatedCostPerQuestionUsd: Double?
        let estimatedMonthlyUsd: Double
        let note: String
        let source: String

        var id: String { provider }
        var isBilledPerToken: Bool { billing == "per_token" }
    }

    struct Level: Decodable, Equatable, Sendable {
        /// "fast", "balanced" or "smart".
        let tier: String
        let options: [Option]

        func option(for provider: UsageProvider) -> Option? {
            options.first { $0.provider == provider.rawValue }
        }
    }

    struct AnthropicListPrice: Decodable, Equatable, Sendable {
        let model: String
        let inputUsdPerMillion: Double
        let cacheWriteUsdPerMillion: Double
        let cacheReadUsdPerMillion: Double
        let outputUsdPerMillion: Double
    }

    let version: Int
    let assumption: Assumption
    let caveat: String
    let levels: [Level]
    let anthropicListPrices: [AnthropicListPrice]

    /// The level matching the model the reader picked in Iris, by the same
    /// mapping the gateway alias uses (`UsageModelTier.forIrisModelName`).
    func level(forIrisModelName irisModelName: String) -> Level? {
        let tier = UsageModelTier.forIrisModelName(irisModelName)
        return levels.first { $0.tier == tier.rawValue }
    }

    /// The published rows as the spend ledger's pricing type. A price is
    /// carried through its decimal text so $3.75 stays $3.75 rather than
    /// the nearest binary fraction.
    var anthropicPricingByModel: [String: AssistantModelPricing] {
        var byModel: [String: AssistantModelPricing] = [:]
        for row in anthropicListPrices {
            guard let input = Self.exactDecimal(row.inputUsdPerMillion),
                  let cacheWrite = Self.exactDecimal(row.cacheWriteUsdPerMillion),
                  let cacheRead = Self.exactDecimal(row.cacheReadUsdPerMillion),
                  let output = Self.exactDecimal(row.outputUsdPerMillion) else { continue }
            byModel[row.model] = AssistantModelPricing(
                inputPerMillion: input,
                cacheWritePerMillion: cacheWrite,
                cacheReadPerMillion: cacheRead,
                outputPerMillion: output
            )
        }
        return byModel
    }

    static func exactDecimal(_ value: Double) -> Decimal? {
        guard value.isFinite, value >= 0 else { return nil }
        return Decimal(string: String(value))
    }
}

/// Fetches the comparison once per launch, in the background. Nothing awaits
/// it: the panel renders whatever state it is in.
@MainActor
final class ModelPriceComparisonStore: ObservableObject {

    enum LoadState: Equatable {
        case notLoaded
        case loading
        case loaded(ModelPriceComparison)
        /// The route could not be reached or answered something unreadable.
        case unavailable
    }

    @Published private(set) var loadState: LoadState = .notLoaded

    var comparison: ModelPriceComparison? {
        if case .loaded(let comparison) = loadState { return comparison }
        return nil
    }

    private let endpoint: URL
    private let fetchData: @Sendable (URL) async throws -> Data

    init(
        publikBaseURL: URL,
        fetchData: @escaping @Sendable (URL) async throws -> Data = ModelPriceComparisonStore.fetchOverTheNetwork
    ) {
        self.endpoint = publikBaseURL.appendingPathComponent("api/iris/model-prices")
        self.fetchData = fetchData
    }

    /// Starts a fetch unless one has succeeded or is running. A failure can be
    /// retried by calling this again (the panel does, when it opens).
    func loadIfNeeded() {
        switch loadState {
        case .loaded, .loading:
            return
        case .notLoaded, .unavailable:
            break
        }
        loadState = .loading
        let endpoint = self.endpoint
        let fetchData = self.fetchData
        Task { [weak self] in
            let decoded: ModelPriceComparison?
            do {
                let data = try await fetchData(endpoint)
                decoded = try JSONDecoder().decode(ModelPriceComparison.self, from: data)
            } catch {
                decoded = nil
            }
            guard let self else { return }
            if let decoded, decoded.version == 1, !decoded.levels.isEmpty {
                self.loadState = .loaded(decoded)
                AssistantServerPublishedPrices.install(decoded.anthropicPricingByModel)
            } else {
                self.loadState = .unavailable
            }
        }
    }

    nonisolated static func fetchOverTheNetwork(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
