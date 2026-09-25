//
//  PublikAPINudgeTests.swift
//  leanring-buddyTests
//
//  The nudge policy (founder-approved, 2026-09-25): one nudge per session,
//  only at three decision points, 7 days of quiet after "Not now" that
//  survives a relaunch, never for somebody already on publik API, and never a
//  word that the price comparison and the ledger cannot back.
//

import Foundation
import Testing
@testable import Iris

/// The route's JSON, trimmed to one level and shaped exactly as
/// `lib/iris-model-prices.ts` builds it.
private let comparisonJSON = """
{
  "version": 1,
  "assumption": {"questionsPerMonth": 300, "inputTokensPerQuestion": 5000, "outputTokensPerQuestion": 300,
                 "summary": "Assumes 300 questions a month."},
  "caveat": "A different model answers on each route.",
  "levels": [
    {"tier": "balanced", "options": [
      {"provider": "publik-api", "label": "publik API", "model": "publik-balanced", "servedBy": "xiaomi/mimo-v2.6-pro",
       "billing": "per_token", "inputUsdPerMillion": 2, "outputUsdPerMillion": 12, "estimatedCostPerQuestionUsd": 0.0136,
       "estimatedMonthlyUsd": 4.08, "note": "Prepaid balance.", "source": "publik"},
      {"provider": "anthropic-key", "label": "Your own Anthropic key", "model": "claude-sonnet-4-6", "servedBy": null,
       "billing": "per_token", "inputUsdPerMillion": 3, "outputUsdPerMillion": 15, "estimatedCostPerQuestionUsd": 0.0195,
       "estimatedMonthlyUsd": 5.85, "note": "Billed by Anthropic.", "source": "anthropic"},
      {"provider": "codex", "label": "Your ChatGPT plan (Codex)", "model": "your codex CLI's model", "servedBy": null,
       "billing": "subscription", "inputUsdPerMillion": null, "outputUsdPerMillion": null, "estimatedCostPerQuestionUsd": null,
       "estimatedMonthlyUsd": 8, "note": "Flat monthly plan.", "source": "openai"}
    ]}
  ],
  "anthropicListPrices": [
    {"model": "claude-sonnet-4-6", "inputUsdPerMillion": 3, "cacheWriteUsdPerMillion": 3.75, "cacheReadUsdPerMillion": 0.3, "outputUsdPerMillion": 15},
    {"model": "claude-opus-4-6", "inputUsdPerMillion": 5, "cacheWriteUsdPerMillion": 6.25, "cacheReadUsdPerMillion": 0.5, "outputUsdPerMillion": 25}
  ]
}
"""

private func decodedComparison() throws -> ModelPriceComparison {
    try JSONDecoder().decode(ModelPriceComparison.self, from: Data(comparisonJSON.utf8))
}

private func scratchDefaults() throws -> UserDefaults {
    let suiteName = "iris.tests.nudge.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private let aTuesdayMorning = Date(timeIntervalSince1970: 1_790_330_000)
private let oneDay: TimeInterval = 24 * 60 * 60

@Suite("publik API nudge policy")
struct PublikAPINudgePolicyTests {

    // MARK: - 7-day quiet

    @Test func quietForSevenDaysAfterADismissalThenAllowedAgain() {
        #expect(PublikAPINudgePolicy.isQuiet(lastDismissedAt: aTuesdayMorning, now: aTuesdayMorning))
        #expect(PublikAPINudgePolicy.isQuiet(lastDismissedAt: aTuesdayMorning, now: aTuesdayMorning.addingTimeInterval(6 * oneDay + 23 * 3600)))
        #expect(!PublikAPINudgePolicy.isQuiet(lastDismissedAt: aTuesdayMorning, now: aTuesdayMorning.addingTimeInterval(7 * oneDay)))
        #expect(!PublikAPINudgePolicy.isQuiet(lastDismissedAt: nil, now: aTuesdayMorning))
    }

    @Test func aClockSetBackwardsStillCountsAsQuiet() {
        #expect(PublikAPINudgePolicy.isQuiet(lastDismissedAt: aTuesdayMorning, now: aTuesdayMorning.addingTimeInterval(-3 * oneDay)))
    }

    @Test func theDismissalSurvivesARelaunch() throws {
        let defaults = try scratchDefaults()
        PublikAPINudgeDismissalStore(userDefaults: defaults).recordDismissal(at: aTuesdayMorning)
        let afterRelaunch = PublikAPINudgeDismissalStore(userDefaults: defaults)
        #expect(afterRelaunch.lastDismissedAt == aTuesdayMorning)
        #expect(!PublikAPINudgePolicy.mayNudge(
            provider: .anthropicKey,
            hasAlreadyNudgedThisSession: false,
            lastDismissedAt: afterRelaunch.lastDismissedAt,
            now: aTuesdayMorning.addingTimeInterval(2 * oneDay)
        ))
    }

    // MARK: - Who and how often

    @Test func neverForPublikAPIOrForNobody() {
        for provider in [UsageProvider.publikAPI, nil] {
            #expect(!PublikAPINudgePolicy.mayNudge(provider: provider, hasAlreadyNudgedThisSession: false, lastDismissedAt: nil, now: aTuesdayMorning))
        }
        #expect(PublikAPINudgePolicy.mayNudge(provider: .anthropicKey, hasAlreadyNudgedThisSession: false, lastDismissedAt: nil, now: aTuesdayMorning))
        #expect(PublikAPINudgePolicy.mayNudge(provider: .codex, hasAlreadyNudgedThisSession: false, lastDismissedAt: nil, now: aTuesdayMorning))
    }

    @Test func atMostOncePerSession() {
        #expect(!PublikAPINudgePolicy.mayNudge(provider: .anthropicKey, hasAlreadyNudgedThisSession: true, lastDismissedAt: nil, now: aTuesdayMorning))
    }

    @Test func onlyTheFirstCallInAnAppIsADecisionPoint() {
        #expect(PublikAPINudgePolicy.isTheFirstAICallInThisApp(appKey: "cue", appsAlreadyAskedAboutThisSession: []))
        #expect(!PublikAPINudgePolicy.isTheFirstAICallInThisApp(appKey: "cue", appsAlreadyAskedAboutThisSession: ["cue"]))
    }

    /// (c) is measured on the key route only. A ChatGPT plan is flat-rate:
    /// there is nothing to measure, so no amount of use trips it.
    @Test func theCostThresholdIsMeasuredOnTheKeyRouteOnly() {
        #expect(PublikAPINudgePolicy.measuredSpendHasCrossedTheThreshold(provider: .anthropicKey, spentSinceLaunchUSD: 1))
        #expect(!PublikAPINudgePolicy.measuredSpendHasCrossedTheThreshold(provider: .anthropicKey, spentSinceLaunchUSD: Decimal(string: "0.99")!))
        #expect(!PublikAPINudgePolicy.measuredSpendHasCrossedTheThreshold(provider: .codex, spentSinceLaunchUSD: 50))
    }
}

@Suite("publik API nudge wording")
struct PublikAPINudgeWordingTests {

    @Test func withoutTheComparisonThereIsNoNudgeAtAll() {
        #expect(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .firstAICallInAnApp, provider: .anthropicKey, comparison: nil,
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: nil, totalIsAFloor: false
        ) == nil)
    }

    @Test func theKeyNudgeShowsBothRealPricesAndSaysADifferentModelAnswers() throws {
        let nudge = try #require(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .firstAICallInAnApp, provider: .anthropicKey, comparison: try decodedComparison(),
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: nil, totalIsAFloor: false
        ))
        let text = nudge.headline + " " + nudge.detail
        #expect(text.contains("$2.00 in / $12.00 out"))
        #expect(text.contains("$3.00 / $15.00"))
        #expect(text.contains("claude-sonnet-4-6"))
        #expect(text.contains("xiaomi/mimo-v2.6-pro answers"))
        #expect(text.contains("A different model answers on publik API"))
        #expect(!text.lowercased().contains("half"))
        #expect(!text.lowercased().contains("save"))
    }

    /// Never suggest a switch that costs more per token.
    @Test func noNudgeWhenPublikListsAboveTheKey() throws {
        let pricier = comparisonJSON.replacingOccurrences(of: "\"inputUsdPerMillion\": 2,", with: "\"inputUsdPerMillion\": 4,")
        let comparison = try JSONDecoder().decode(ModelPriceComparison.self, from: Data(pricier.utf8))
        #expect(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .modelSelection, provider: .anthropicKey, comparison: comparison,
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: nil, totalIsAFloor: false
        ) == nil)
    }

    @Test func theCostNudgeStatesTheMeasuredAmountAndSaysAtLeastWhenItIsAFloor() throws {
        let nudge = try #require(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .measuredCostThreshold, provider: .anthropicKey, comparison: try decodedComparison(),
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: Decimal(string: "1.04"), totalIsAFloor: true
        ))
        #expect(nudge.headline.contains("at least $1.04"))
        #expect(nudge.detail.contains("Measured from Anthropic's own token counts"))
    }

    @Test func theCodexNudgeIsAboutWhatIrisCanDoNotAMeasuredCost() throws {
        let comparison = try decodedComparison()
        let nudge = try #require(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .firstAICallInAnApp, provider: .codex, comparison: comparison,
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: nil, totalIsAFloor: false
        ))
        #expect(nudge.detail.contains("answers in words only"))
        #expect(nudge.detail.contains("costs nothing extra per question"))
        #expect(PublikAPINudgeCoordinator.composeNudge(
            decisionPoint: .measuredCostThreshold, provider: .codex, comparison: comparison,
            irisModelName: "claude-sonnet-4-6", spentSinceLaunchUSD: 5, totalIsAFloor: false
        ) == nil)
    }
}

@Suite("publik API nudge coordinator")
@MainActor
struct PublikAPINudgeCoordinatorTests {

    private final class Box<Value> { var value: Value; init(_ value: Value) { self.value = value } }

    private func makeCoordinator(
        provider: Box<UsageProvider?>,
        defaults: UserDefaults,
        now: Box<Date> = Box(aTuesdayMorning)
    ) throws -> PublikAPINudgeCoordinator {
        let comparison = try decodedComparison()
        return PublikAPINudgeCoordinator(
            dismissalStore: PublikAPINudgeDismissalStore(userDefaults: defaults),
            currentDate: { now.value },
            currentProvider: { provider.value },
            currentIrisModelName: { "claude-sonnet-4-6" },
            currentComparison: { comparison }
        )
    }

    @Test func theFirstCallInAnAppNudgesOnceAndTheSessionStaysQuietAfter() throws {
        let coordinator = try makeCoordinator(provider: Box(.anthropicKey), defaults: try scratchDefaults())
        coordinator.anAICallIsGoingOut(frontmostCatalogAppSlug: "cue")
        #expect(coordinator.visibleNudge?.decisionPoint == .firstAICallInAnApp)

        coordinator.readerActedOnTheNudge()
        coordinator.anAICallIsGoingOut(frontmostCatalogAppSlug: "whimprflow")
        coordinator.readerPickedAProviderOrModel()
        coordinator.measuredSpendChanged(totalSpentUSD: 10, totalIsAFloor: false)
        #expect(coordinator.visibleNudge == nil, "one nudge per session, whatever happens next")
    }

    @Test func aDismissalSilencesTheNextSessionForSevenDays() throws {
        let defaults = try scratchDefaults()
        let now = Box(aTuesdayMorning)
        let firstSession = try makeCoordinator(provider: Box(.anthropicKey), defaults: defaults, now: now)
        firstSession.readerPickedAProviderOrModel()
        #expect(firstSession.visibleNudge != nil)
        firstSession.dismiss()
        #expect(firstSession.visibleNudge == nil)

        now.value = aTuesdayMorning.addingTimeInterval(3 * oneDay)
        let laterSession = try makeCoordinator(provider: Box(.anthropicKey), defaults: defaults, now: now)
        laterSession.readerPickedAProviderOrModel()
        #expect(laterSession.visibleNudge == nil, "still inside the 7 days")

        now.value = aTuesdayMorning.addingTimeInterval(7 * oneDay + 60)
        let aWeekLater = try makeCoordinator(provider: Box(.anthropicKey), defaults: defaults, now: now)
        aWeekLater.readerPickedAProviderOrModel()
        #expect(aWeekLater.visibleNudge != nil)
    }

    @Test func aCallOnPublikAPIStillUsesUpTheAppsFirstCall() throws {
        let provider = Box<UsageProvider?>(.publikAPI)
        let coordinator = try makeCoordinator(provider: provider, defaults: try scratchDefaults())
        coordinator.anAICallIsGoingOut(frontmostCatalogAppSlug: "cue")
        #expect(coordinator.visibleNudge == nil)

        provider.value = .anthropicKey
        coordinator.anAICallIsGoingOut(frontmostCatalogAppSlug: "cue")
        #expect(coordinator.visibleNudge == nil, "not the first call in cue any more")
        coordinator.anAICallIsGoingOut(frontmostCatalogAppSlug: nil)
        #expect(coordinator.visibleNudge?.decisionPoint == .firstAICallInAnApp)
    }

    @Test func theCostThresholdCountsOnlySpendSinceLaunch() throws {
        let defaults = try scratchDefaults()
        let ledger = AssistantSpendLedger(userDefaults: defaults)
        // Pretend earlier launches already spent money on this key.
        ledger.record(model: "claude-opus-4-6", usage: AssistantTokenUsage(outputTokens: 200_000), route: .theReadersOwnAPIKey)
        let coordinator = try makeCoordinator(provider: Box(.anthropicKey), defaults: defaults)
        coordinator.watchMeasuredSpend(on: ledger)
        #expect(coordinator.visibleNudge == nil, "money spent before this launch is not a crossing")

        coordinator.measuredSpendChanged(totalSpentUSD: ledger.totalSpent + Decimal(string: "0.50")!, totalIsAFloor: false)
        #expect(coordinator.visibleNudge == nil)
        coordinator.measuredSpendChanged(totalSpentUSD: ledger.totalSpent + Decimal(string: "1.10")!, totalIsAFloor: false)
        #expect(coordinator.visibleNudge?.decisionPoint == .measuredCostThreshold)
        #expect(coordinator.visibleNudge?.headline.contains("$1.10") == true)
    }

    @Test func switchingToPublikAPIClearsAVisibleNudge() throws {
        let coordinator = try makeCoordinator(provider: Box(.codex), defaults: try scratchDefaults())
        coordinator.readerPickedAProviderOrModel()
        #expect(coordinator.visibleNudge != nil)
        coordinator.providerChanged(to: .publikAPI)
        #expect(coordinator.visibleNudge == nil)
    }
}

/// Serialized: two of these install the app-wide published prices, and a
/// parallel run would let one clear them in the middle of the other.
@Suite("Model price comparison", .serialized)
@MainActor
struct ModelPriceComparisonTests {

    @Test func decodesTheRouteAndPicksTheLevelByThePickersModel() throws {
        let comparison = try decodedComparison()
        #expect(comparison.level(forIrisModelName: "claude-sonnet-4-6")?.tier == "balanced")
        #expect(comparison.level(forIrisModelName: "claude-opus-4-6") == nil, "only the balanced level is in this fixture")
        let codex = try #require(comparison.levels.first?.option(for: .codex))
        #expect(!codex.isBilledPerToken)
        #expect(codex.inputUsdPerMillion == nil)
    }

    @Test func publishedPricesKeepTheirDecimalsExactly() throws {
        let pricing = try #require(try decodedComparison().anthropicPricingByModel["claude-sonnet-4-6"])
        #expect(pricing.cacheWritePerMillion == Decimal(string: "3.75"))
        #expect(pricing.cacheReadPerMillion == Decimal(string: "0.3"))
    }

    /// Opus 4.6 lists at $5 / $25. The ledger's own table used to apply the
    /// Opus 4 / 4.1 row ($15 / $75) to every claude-opus-4 id.
    @Test func theFallbackTableNoLongerTriplesOpus() throws {
        let opus = try #require(AssistantModelPrices.pricing(forModel: "claude-opus-4-6"))
        #expect(opus.inputPerMillion == 5)
        #expect(opus.outputPerMillion == 25)
        let oldOpus = try #require(AssistantModelPrices.pricing(forModel: "claude-opus-4-1"))
        #expect(oldOpus.outputPerMillion == 75)
    }

    @Test func theLedgerPrefersThePricesPublikServes() throws {
        let comparison = try decodedComparison()
        AssistantServerPublishedPrices.install(comparison.anthropicPricingByModel)
        defer { AssistantServerPublishedPrices.install([:]) }
        let served = try #require(AssistantServerPublishedPrices.pricing(forModel: "claude-sonnet-4-6-20260115"))
        #expect(served.inputPerMillion == 3)
        #expect(AssistantServerPublishedPrices.pricing(forModel: "claude-sonnet-4") == nil, "a family prefix is not a snapshot")
    }

    @Test func aFailedFetchIsUnavailableNeverAStaleNumber() async throws {
        let store = ModelPriceComparisonStore(
            publikBaseURL: URL(string: "https://publikhq.com")!,
            fetchData: { _ in throw URLError(.notConnectedToInternet) }
        )
        store.loadIfNeeded()
        for _ in 0..<50 where store.loadState == .loading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.loadState == .unavailable)
        #expect(store.comparison == nil)
    }

    @Test func aGoodFetchLoadsAndInstallsTheLedgerPrices() async throws {
        let data = Data(comparisonJSON.utf8)
        let store = ModelPriceComparisonStore(
            publikBaseURL: URL(string: "https://publikhq.com")!,
            fetchData: { url in
                #expect(url.absoluteString == "https://publikhq.com/api/iris/model-prices")
                return data
            }
        )
        defer { AssistantServerPublishedPrices.install([:]) }
        store.loadIfNeeded()
        for _ in 0..<50 where store.loadState == .loading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.comparison?.levels.count == 1)
        #expect(AssistantServerPublishedPrices.pricing(forModel: "claude-opus-4-6")?.outputPerMillion == 25)
    }
}
