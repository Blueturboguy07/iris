//
//  PublikAPINudge.swift
//  leanring-buddy
//
//  The one place Iris suggests publik API to somebody using another provider,
//  and the rules that keep that suggestion honest and rare (founder-approved
//  nudge policy, 2026-09-25):
//
//    - At most ONE nudge per session (a launch of Iris).
//    - Only at three decision points:
//        (a) the reader picks a provider or a model;
//        (b) the first AI call in an app, while on a provider that is not
//            publik API;
//        (c) a MEASURED cost crossing a threshold.
//    - Dismissing it silences every nudge for 7 days, and that survives a
//      relaunch.
//    - Never modal and never in the way: it is a small inline card, and the
//      question the reader was asking goes out exactly as it would have.
//
//  WHAT (c) CAN AND CANNOT MEASURE. Iris measures cost only on the reader's
//  own Anthropic key: each response carries Anthropic's own token counts, and
//  `AssistantSpendLedger` prices them at the list price publik serves. A
//  ChatGPT plan through the Codex CLI is flat-rate — one more question costs
//  nothing measurable — so (c) never fires there. Nothing is estimated to
//  make a threshold trip.
//
//  WHAT A NUDGE MAY SAY. Only numbers from publik's price comparison
//  (`ModelPriceComparison`, served by publik) and the ledger's measured total.
//  With the comparison not loaded there is no nudge at all rather than one
//  without numbers. On the Anthropic-key route a nudge is shown only while
//  publik's per-token prices at that tier are at or below the key's list
//  prices, and it always says that a different model answers on publik API.
//

import Combine
import Foundation

/// The three moments a nudge may appear.
nonisolated enum PublikAPINudgeDecisionPoint: String, Sendable, Equatable {
    case modelSelection
    case firstAICallInAnApp
    case measuredCostThreshold
}

/// The pure rules. No clock, no storage, no UI.
nonisolated enum PublikAPINudgePolicy {

    /// How long "Not now" keeps every nudge away.
    static let quietPeriodAfterDismissal: TimeInterval = 7 * 24 * 60 * 60

    /// (c): measured spend on the reader's own key since Iris opened.
    static let measuredSpendThresholdUSD: Decimal = 1

    /// Whether a nudge may appear at all right now.
    static func mayNudge(
        provider: UsageProvider?,
        hasAlreadyNudgedThisSession: Bool,
        lastDismissedAt: Date?,
        now: Date
    ) -> Bool {
        // Somebody already on publik API, or with nothing set up, is never nudged.
        guard provider == .anthropicKey || provider == .codex else { return false }
        guard !hasAlreadyNudgedThisSession else { return false }
        return !isQuiet(lastDismissedAt: lastDismissedAt, now: now)
    }

    /// Inside the 7 days after a dismissal.
    static func isQuiet(lastDismissedAt: Date?, now: Date) -> Bool {
        guard let lastDismissedAt else { return false }
        // A clock set backwards past the dismissal still counts as quiet: a
        // negative interval is "within the week", never "long ago".
        return now.timeIntervalSince(lastDismissedAt) < quietPeriodAfterDismissal
    }

    /// (b): the first question asked about this app this session. `appKey` is
    /// the frontmost catalog slug, or a fixed key for "no catalog app in front".
    static func isTheFirstAICallInThisApp(appKey: String, appsAlreadyAskedAboutThisSession: Set<String>) -> Bool {
        !appsAlreadyAskedAboutThisSession.contains(appKey)
    }

    /// (c): Codex is flat-rate and never measured, so only the key route counts.
    static func measuredSpendHasCrossedTheThreshold(provider: UsageProvider?, spentSinceLaunchUSD: Decimal) -> Bool {
        provider == .anthropicKey && spentSinceLaunchUSD >= measuredSpendThresholdUSD
    }

    /// On the key route, only nudge while publik lists at or below the key at
    /// this tier on both input and output. Anything else would be suggesting a
    /// switch that costs more per token.
    static func publikListsAtOrBelowTheKey(publik: ModelPriceComparison.Option, key: ModelPriceComparison.Option) -> Bool {
        guard let publikIn = publik.inputUsdPerMillion, let publikOut = publik.outputUsdPerMillion,
              let keyIn = key.inputUsdPerMillion, let keyOut = key.outputUsdPerMillion else { return false }
        return publikIn <= keyIn && publikOut <= keyOut
    }
}

/// "Not now", remembered across launches. Its own tiny store so tests can
/// point it at a scratch defaults domain.
nonisolated final class PublikAPINudgeDismissalStore: @unchecked Sendable {
    private static let lastDismissedAtKey = "iris:nudge:publik-api:last-dismissed-at"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var lastDismissedAt: Date? {
        userDefaults.object(forKey: Self.lastDismissedAtKey) as? Date
    }

    func recordDismissal(at date: Date) {
        userDefaults.set(date, forKey: Self.lastDismissedAtKey)
    }
}

/// What the card shows. Every figure in these strings came from the price
/// comparison or the ledger.
nonisolated struct PublikAPINudge: Equatable, Sendable {
    let decisionPoint: PublikAPINudgeDecisionPoint
    let headline: String
    let detail: String
}

/// Owns the session's one nudge.
@MainActor
final class PublikAPINudgeCoordinator: ObservableObject {

    @Published private(set) var visibleNudge: PublikAPINudge?

    private let dismissalStore: PublikAPINudgeDismissalStore
    private let currentDate: () -> Date
    private let currentProvider: () -> UsageProvider?
    private let currentIrisModelName: () -> String
    private let currentComparison: () -> ModelPriceComparison?

    private(set) var hasNudgedThisSession = false
    private var appsAskedAboutThisSession: Set<String> = []
    private var spendAtLaunchUSD: Decimal?
    private var spendSubscription: AnyCancellable?

    /// The key used for (b) when no catalog app is in front.
    static let noCatalogAppInFrontKey = "(no catalog app in front)"

    init(
        dismissalStore: PublikAPINudgeDismissalStore = PublikAPINudgeDismissalStore(),
        currentDate: @escaping () -> Date = { Date() },
        currentProvider: @escaping () -> UsageProvider?,
        currentIrisModelName: @escaping () -> String,
        currentComparison: @escaping () -> ModelPriceComparison?
    ) {
        self.dismissalStore = dismissalStore
        self.currentDate = currentDate
        self.currentProvider = currentProvider
        self.currentIrisModelName = currentIrisModelName
        self.currentComparison = currentComparison
    }

    // MARK: - The three decision points

    /// (a) The reader picked a provider or a model.
    func readerPickedAProviderOrModel() {
        considerShowing(at: .modelSelection)
    }

    /// (b) An AI call is about to go out. Called for every call; only the first
    /// one per app per session is a decision point.
    func anAICallIsGoingOut(frontmostCatalogAppSlug: String?) {
        let appKey = frontmostCatalogAppSlug ?? Self.noCatalogAppInFrontKey
        let isFirst = PublikAPINudgePolicy.isTheFirstAICallInThisApp(
            appKey: appKey,
            appsAlreadyAskedAboutThisSession: appsAskedAboutThisSession
        )
        appsAskedAboutThisSession.insert(appKey)
        guard isFirst, currentProvider() != .publikAPI else { return }
        considerShowing(at: .firstAICallInAnApp)
    }

    /// (c) Watches the ledger's measured total. The first value seen is the
    /// baseline, so only money spent since this launch counts.
    func watchMeasuredSpend(on spendLedger: AssistantSpendLedger) {
        spendAtLaunchUSD = spendLedger.totalSpent
        spendSubscription = spendLedger.$totalSpent
            .dropFirst()
            .sink { [weak self, weak spendLedger] totalSpent in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.measuredSpendChanged(
                        totalSpentUSD: totalSpent,
                        totalIsAFloor: spendLedger?.someCallsCouldNotBePriced ?? false
                    )
                }
            }
    }

    func measuredSpendChanged(totalSpentUSD: Decimal, totalIsAFloor: Bool) {
        let baseline = spendAtLaunchUSD ?? 0
        let spentSinceLaunch = totalSpentUSD - baseline
        guard PublikAPINudgePolicy.measuredSpendHasCrossedTheThreshold(
            provider: currentProvider(),
            spentSinceLaunchUSD: spentSinceLaunch
        ) else { return }
        considerShowing(at: .measuredCostThreshold, spentSinceLaunchUSD: spentSinceLaunch, totalIsAFloor: totalIsAFloor)
    }

    // MARK: - The reader's answer

    /// "Not now": gone, and every nudge stays away for 7 days.
    func dismiss() {
        dismissalStore.recordDismissal(at: currentDate())
        visibleNudge = nil
    }

    /// "Compare" or "Use publik API": the reader acted on it, so it goes away
    /// for this session without starting the 7-day quiet.
    func readerActedOnTheNudge() {
        visibleNudge = nil
    }

    /// The reader switched to publik API some other way; a nudge still up
    /// would be describing a choice they no longer have.
    func providerChanged(to provider: UsageProvider?) {
        if provider == .publikAPI { visibleNudge = nil }
    }

    // MARK: - Deciding

    private func considerShowing(
        at decisionPoint: PublikAPINudgeDecisionPoint,
        spentSinceLaunchUSD: Decimal? = nil,
        totalIsAFloor: Bool = false
    ) {
        let provider = currentProvider()
        guard PublikAPINudgePolicy.mayNudge(
            provider: provider,
            hasAlreadyNudgedThisSession: hasNudgedThisSession,
            lastDismissedAt: dismissalStore.lastDismissedAt,
            now: currentDate()
        ) else { return }
        guard let nudge = Self.composeNudge(
            decisionPoint: decisionPoint,
            provider: provider,
            comparison: currentComparison(),
            irisModelName: currentIrisModelName(),
            spentSinceLaunchUSD: spentSinceLaunchUSD,
            totalIsAFloor: totalIsAFloor
        ) else { return }
        hasNudgedThisSession = true
        visibleNudge = nudge
    }

    /// The words, or nil when there is nothing true and specific to say.
    nonisolated static func composeNudge(
        decisionPoint: PublikAPINudgeDecisionPoint,
        provider: UsageProvider?,
        comparison: ModelPriceComparison?,
        irisModelName: String,
        spentSinceLaunchUSD: Decimal?,
        totalIsAFloor: Bool
    ) -> PublikAPINudge? {
        guard let level = comparison?.level(forIrisModelName: irisModelName),
              let publik = level.option(for: .publikAPI),
              let publikIn = publik.inputUsdPerMillion,
              let publikOut = publik.outputUsdPerMillion else { return nil }
        let publikPriceText = "\(dollarText(publikIn)) in / \(dollarText(publikOut)) out per 1M tokens"
        let answeredBy = publik.servedBy.map { " (\($0) answers)" } ?? ""

        switch provider {
        case .anthropicKey:
            guard let key = level.option(for: .anthropicKey),
                  let keyIn = key.inputUsdPerMillion, let keyOut = key.outputUsdPerMillion,
                  PublikAPINudgePolicy.publikListsAtOrBelowTheKey(publik: publik, key: key) else { return nil }
            let keyPriceText = "\(dollarText(keyIn)) / \(dollarText(keyOut))"
            let comparisonSentence =
                "\(publik.model)\(answeredBy): \(publikPriceText). Your key's \(key.model): \(keyPriceText). A different model answers on publik API."
            if decisionPoint == .measuredCostThreshold, let spentSinceLaunchUSD {
                let spentText = AssistantSpendLedger.moneyText(spentSinceLaunchUSD)
                return PublikAPINudge(
                    decisionPoint: decisionPoint,
                    headline: "Your Anthropic key has spent \(totalIsAFloor ? "at least " : "")\(spentText) through Iris since it opened",
                    detail: "Measured from Anthropic's own token counts at list price. " + comparisonSentence
                )
            }
            return PublikAPINudge(
                decisionPoint: decisionPoint,
                headline: "publik API at this tier: \(publikPriceText)",
                detail: comparisonSentence
            )
        case .codex:
            // Flat-rate: no cost is measured and no price is compared against a
            // plan the reader already pays for. What is true and different is
            // what Iris can do on each route.
            guard decisionPoint != .measuredCostThreshold else { return nil }
            return PublikAPINudge(
                decisionPoint: decisionPoint,
                headline: "On publik API, Iris can also act for you",
                detail: "Through your ChatGPT plan Iris answers in words only. On publik API it can also copy, run and open things, billed per use: \(publik.model)\(answeredBy), \(publikPriceText). Your plan costs nothing extra per question."
            )
        case .publikAPI, .none:
            return nil
        }
    }

    nonisolated static func dollarText(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
