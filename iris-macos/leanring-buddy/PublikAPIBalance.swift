//
//  PublikAPIBalance.swift
//  leanring-buddy
//
//  What the reader has left on publik API, what one message costs there, and
//  the one place "Add credit" goes.
//
//  Founder decision, 2026-09-22: the balance and an Add credit button live in
//  Iris itself, not only on the dashboard. This file is pure on purpose — no
//  network and no views. `PublikAPIAccount` fetches and remembers,
//  `CompanionPanelView` draws, and every rule in between is here, where the
//  test target can reach it (`PublikAPIBalanceTests`).
//
//  THE CHARGE OF A STREAMED REPLY IS NOT IN ITS HEADERS. The gateway stamps
//  `x-publik-charge-micros` only on a non-streaming answer; a stream's headers
//  leave before the call is settled, so they carry the HOLD instead (CONTRACT.md,
//  "Headers on every metered call"). Every chat reply Iris makes streams. So the
//  charge header is read when it is there, and otherwise the charge is priced
//  here from the usage the stream reported, at the same per-tier rates the
//  gateway charges. The balance after a streamed reply is read back from
//  `GET /balance` rather than trusted from a header that predates the charge.
//
//  Copy rule (CONTRACT.md section 12 item 5): dollars and "publik API", never
//  tokens and never "credits" — the one exception is the button label
//  "Add credit", which the founder chose.
//

import Foundation

// MARK: - Tier prices

/// What publik charges on one tier, in micros per million tokens.
///
/// A copy of the gateway's own rows (`lib/publik-api/pricing/sheet.ts` in the
/// publik repo, `priceFactor` 1.0). If those change, the "Last reply" figure for
/// a streamed reply drifts until this table is updated. The balance never
/// drifts: it is always read back from the gateway, never computed here.
struct PublikAPITierPrice: Equatable, Sendable {
    let modelAlias: String
    let inputMicrosPerMillion: Int
    let cacheWriteMicrosPerMillion: Int
    let cachedInputMicrosPerMillion: Int
    let outputMicrosPerMillion: Int

    static let fast = PublikAPITierPrice(
        modelAlias: PublikAPIModelAlias.fast,
        inputMicrosPerMillion: 200_000,
        cacheWriteMicrosPerMillion: 250_000,
        cachedInputMicrosPerMillion: 20_000,
        outputMicrosPerMillion: 1_200_000
    )
    static let balanced = PublikAPITierPrice(
        modelAlias: PublikAPIModelAlias.balanced,
        inputMicrosPerMillion: 2_000_000,
        cacheWriteMicrosPerMillion: 2_500_000,
        cachedInputMicrosPerMillion: 200_000,
        outputMicrosPerMillion: 12_000_000
    )
    static let smart = PublikAPITierPrice(
        modelAlias: PublikAPIModelAlias.smart,
        inputMicrosPerMillion: 4_000_000,
        cacheWriteMicrosPerMillion: 5_000_000,
        cachedInputMicrosPerMillion: 400_000,
        outputMicrosPerMillion: 20_000_000
    )

    /// Nil for an alias this build has no price for, so a new tier shows no
    /// figure rather than a wrong one.
    static func forModelAlias(_ modelAlias: String) -> PublikAPITierPrice? {
        switch modelAlias {
        case PublikAPIModelAlias.fast: return fast
        case PublikAPIModelAlias.balanced: return balanced
        case PublikAPIModelAlias.smart: return smart
        default: return nil
        }
    }

    /// The message the "typical cost" line is quoted for: a short question with
    /// a screenshot's worth of context in, and a few sentences out.
    static let typicalMessageUsage = AssistantTokenUsage(inputTokens: 2_000, outputTokens: 500)

    var typicalMessageChargeMicros: Int {
        chargeMicros(for: Self.typicalMessageUsage)
    }

    /// What the gateway charges for one call's usage, rounded per part exactly
    /// the way its `priceTokenUsage` rounds.
    ///
    /// The usage arrives in the Anthropic shape the gateway's converter writes
    /// (`anthropicUsageFromResponses`): `input_tokens` has the cache READS taken
    /// out but still contains the cache WRITES, which the gateway prices apart.
    /// So the plain-input part is `input − cacheWrite`, not `input`.
    func chargeMicros(for usage: AssistantTokenUsage) -> Int {
        let uncachedInputTokens = max(0, usage.inputTokens - usage.cacheWriteTokens)
        return Self.micros(forTokens: uncachedInputTokens, atMicrosPerMillion: inputMicrosPerMillion)
            + Self.micros(forTokens: max(0, usage.cacheWriteTokens), atMicrosPerMillion: cacheWriteMicrosPerMillion)
            + Self.micros(forTokens: max(0, usage.cacheReadTokens), atMicrosPerMillion: cachedInputMicrosPerMillion)
            + Self.micros(forTokens: max(0, usage.outputTokens), atMicrosPerMillion: outputMicrosPerMillion)
    }

    /// `Math.round(tokens × rate / 1,000,000)`, in integers so a large count
    /// cannot lose a micro to floating point.
    private static func micros(forTokens tokenCount: Int, atMicrosPerMillion microsPerMillion: Int) -> Int {
        let scaled = tokenCount * microsPerMillion
        return (scaled + 500_000) / 1_000_000
    }
}

// MARK: - Money, in words

enum PublikAPIMoney {

    /// Under a quarter the balance line turns into a warning and "Add credit"
    /// becomes the loud button. A quarter is a couple of dozen messages on the
    /// default tier: enough warning to act, not so early that it nags.
    static let lowBalanceThresholdMicros = 250_000

    /// Strictly under the threshold. Exactly $0.25 is not yet low.
    static func balanceIsLow(balanceMicros: Int) -> Bool {
        balanceMicros < lowBalanceThresholdMicros
    }

    /// "$1.84 left". Rounded down, like every balance Iris shows.
    static func balanceLine(balanceMicros: Int) -> String {
        "\(PublikAPIWalletSnapshot.dollarsDescription(forMicros: balanceMicros)) left"
    }

    /// A per-message price, to a tenth of a cent: "$0.004", "$0.010".
    ///
    /// Rounded to the nearest tenth of a cent rather than down: this is what a
    /// message cost, not money the reader has. A cost too small to show at that
    /// precision says so instead of reading "$0.000", which would look free.
    static func costDescription(forMicros micros: Int) -> String {
        guard micros > 0 else { return "$0.00" }
        let tenthsOfACent = (micros + 500) / 1_000
        guard tenthsOfACent > 0 else { return "under $0.001" }
        return String(format: "$%d.%03d", tenthsOfACent / 1_000, tenthsOfACent % 1_000)
    }

    /// The one short line under the balance: what the last reply cost, or —
    /// before there has been one — what a typical message costs on the tier
    /// Iris is using. Nil only for a tier this build has no price for.
    static func costPerMessageLine(lastReplyChargeMicros: Int?, modelAlias: String) -> String? {
        if let lastReplyChargeMicros {
            return "Last reply: \(costDescription(forMicros: lastReplyChargeMicros))"
        }
        guard let tierPrice = PublikAPITierPrice.forModelAlias(modelAlias) else { return nil }
        return "About \(costDescription(forMicros: tierPrice.typicalMessageChargeMicros)) per message on \(modelAlias)"
    }
}

// MARK: - The one link

/// Where "Add credit" goes — from the balance row and from the 402 alike, so
/// the two can never send the reader to different pages.
enum PublikAPIAddCredit {

    /// Used when the gateway named no page Iris will open. The add-credit page
    /// asks the reader to sign in, which is always a way forward.
    static let fallbackURLString = "https://publikhq.com/dashboard/api/add"

    /// The first candidate that is a page on publik itself, else the fallback.
    static func urlString(preferring candidateURLStrings: [String?]) -> String {
        for candidateURLString in candidateURLStrings {
            if let candidateURLString, isAPublikPage(candidateURLString) {
                return candidateURLString
            }
        }
        return fallbackURLString
    }

    /// The link for the balance row, from the latest `/balance` answer.
    ///
    /// `top_up_url` first: the gateway already chose it (the claim page while
    /// the install is anonymous, the add-credit page once claimed). An older
    /// answer without it is decided the same way from the claim state. An
    /// anonymous install is never sent straight to the add-credit page while a
    /// claim page exists, because credit added to an account this computer is
    /// not linked to would not reach this key.
    static func urlString(for walletSnapshot: PublikAPIWalletSnapshot?) -> String {
        guard let walletSnapshot else { return fallbackURLString }
        switch walletSnapshot.claimState {
        case .anonymous:
            return urlString(preferring: [
                walletSnapshot.topUpURLString,
                walletSnapshot.claimURLString,
                walletSnapshot.addCreditURLString,
            ])
        case .claimed:
            return urlString(preferring: [
                walletSnapshot.topUpURLString,
                walletSnapshot.addCreditURLString,
            ])
        }
    }

    /// The link for a 402 — the one the server's refusal named.
    static func urlString(for insufficientCredit: PublikAPIInsufficientCredit) -> String {
        urlString(preferring: [insufficientCredit.linkURLString])
    }

    /// A page on publik, over https, with nothing smuggled into it. A local
    /// development build's localhost site is allowed too, the same origins
    /// `AssistantTransport.isAPublikHost` accepts for the key itself.
    static func isAPublikPage(_ candidateURLString: String) -> Bool {
        guard let urlComponents = URLComponents(string: candidateURLString),
              let host = urlComponents.host?.lowercased(),
              urlComponents.user == nil,
              urlComponents.password == nil,
              AssistantTransport.isAPublikHost(host) else {
            return false
        }
        let scheme = urlComponents.scheme?.lowercased()
        if host == "localhost" || host == "127.0.0.1" {
            return scheme == "https" || scheme == "http"
        }
        return scheme == "https"
    }
}

// MARK: - Reading the gateway

extension PublikAPIWalletSnapshot {

    /// Reads one `GET /api/v1/balance` body. Nil when the body carries no
    /// balance at all, so a malformed answer leaves the last good one on screen
    /// instead of replacing it with $0.00.
    static func parse(balanceResponseBody: Data) -> PublikAPIWalletSnapshot? {
        guard let payload = try? JSONSerialization.jsonObject(with: balanceResponseBody) as? [String: Any] else {
            return nil
        }
        // `available_micros` is the /balance alias of `balance_micros`; the two
        // are the same number today, and either is accepted so a rename on one
        // side does not blank the balance line.
        guard let balanceMicros = (payload["available_micros"] as? Int) ?? (payload["balance_micros"] as? Int) else {
            return nil
        }
        return PublikAPIWalletSnapshot(
            balanceMicros: balanceMicros,
            claimState: PublikAPIClaimState(wireValue: payload["claim_state"] as? String),
            claimURLString: nonEmptyString(payload["claim_url"]),
            addCreditURLString: nonEmptyString(payload["add_credit_url"]),
            topUpURLString: nonEmptyString(payload["top_up_url"])
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

/// Reads the gateway's integer headers. A value that is not a plain,
/// non-negative whole number is ignored rather than guessed at: a garbled
/// charge must not become a price on screen.
enum PublikAPIMicrosHeader {
    static let chargeHeaderName = "x-publik-charge-micros"
    static let balanceHeaderName = "x-publik-balance"

    static func micros(fromHeaderValue headerValue: String?) -> Int? {
        guard let trimmedValue = headerValue?.trimmingCharacters(in: .whitespaces),
              !trimmedValue.isEmpty,
              trimmedValue.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(trimmedValue)
    }
}

/// What one finished publik API call told Iris about money.
struct PublikAPICallReceipt: Equatable, Sendable {
    /// What the call cost: the gateway's own figure when it sent one, else
    /// priced from the usage the stream reported. Nil when neither exists — no
    /// header, and no usage or no price for the tier.
    let chargeMicros: Int?
    /// The balance AFTER the charge, when the gateway sent one it had settled.
    /// Always nil after a streamed reply, whose `x-publik-balance` was written
    /// before the charge and so reads low by whatever was held for the call.
    let settledBalanceMicros: Int?

    init(chargeMicros: Int?, settledBalanceMicros: Int?) {
        self.chargeMicros = chargeMicros
        self.settledBalanceMicros = settledBalanceMicros
    }

    /// Builds a receipt from a response's headers (`headerValue` looks one up
    /// by name) and the usage its body reported.
    init(headerValue: (String) -> String?, modelAlias: String, usage: AssistantTokenUsage) {
        if let chargeFromTheGateway = PublikAPIMicrosHeader.micros(
            fromHeaderValue: headerValue(PublikAPIMicrosHeader.chargeHeaderName)
        ) {
            // The gateway writes the charge only once it has settled the call,
            // and the balance beside it is the settled one (CONTRACT section 11.6).
            self.chargeMicros = chargeFromTheGateway
            self.settledBalanceMicros = PublikAPIMicrosHeader.micros(
                fromHeaderValue: headerValue(PublikAPIMicrosHeader.balanceHeaderName)
            )
            return
        }
        if usage.isEmpty {
            self.chargeMicros = nil
        } else {
            self.chargeMicros = PublikAPITierPrice.forModelAlias(modelAlias)?.chargeMicros(for: usage)
        }
        self.settledBalanceMicros = nil
    }
}

// MARK: - One reply, however many calls

/// Adds up what one reply cost.
///
/// A chat reply can take several model calls — a tool round, a resumed
/// `pause_turn` — and "Last reply" means all of them. Calls that belong to no
/// reply (the guide's pointing, the onboarding demo) still move the balance but
/// never land in this line.
struct PublikAPIReplyCostTally: Equatable, Sendable {
    /// Which reply is being added up right now, if any.
    private(set) var replyInProgress: UUID?
    private(set) var chargeOfTheReplyInProgressMicros = 0
    /// What the last reply cost. Updated as each of its calls lands, so a long
    /// reply shows its running cost rather than the previous reply's.
    private(set) var lastReplyChargeMicros: Int?

    mutating func beginAReply() -> UUID {
        let replyIdentifier = UUID()
        replyInProgress = replyIdentifier
        chargeOfTheReplyInProgressMicros = 0
        return replyIdentifier
    }

    /// Ends the reply only if it is still the current one: a cancelled reply
    /// that finishes after its replacement began must not close the new one.
    mutating func finishTheReply(_ replyIdentifier: UUID) {
        guard replyInProgress == replyIdentifier else { return }
        replyInProgress = nil
    }

    mutating func addACall(chargeMicros: Int) {
        guard replyInProgress != nil else { return }
        chargeOfTheReplyInProgressMicros += max(0, chargeMicros)
        lastReplyChargeMicros = chargeOfTheReplyInProgressMicros
    }

    mutating func forgetEverything() {
        self = PublikAPIReplyCostTally()
    }
}
