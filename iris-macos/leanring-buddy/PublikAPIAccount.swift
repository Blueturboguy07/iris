//
//  PublikAPIAccount.swift
//  leanring-buddy
//
//  The publik API credential: where it lives, how the settings card reads the
//  balance, and what the gateway has most recently said about it.
//
//  Since 0.9.18 the install itself comes from the publik module
//  (`Publik.swift`). At launch, before any window, `Publik.ensureSignedIn`
//  provisions this Mac's install (`POST /api/v1/installs` with the build's app
//  token), shows Sign in with publik until the install is claimed by the
//  reader's publik account, and asks once how Iris pays for AI. When they
//  press Connect your plan, `adoptTheInstallKey` puts that install key in the
//  Keychain as the publik API key. When they press Use my own key, nothing
//  here changes, and their own Anthropic key or ChatGPT account answers.
//
//  `docs/assistant-credentials.md` is the cross-platform contract and
//  `CONTRACT.md` section 12 (the CTA) is the gateway's own spec. The short
//  version:
//
//    - The settings sheet can still set up publik API later (after Use my own
//      key). It shows the disclosure, then `provisionAKey` adopts the module's
//      install: the same install, never a second one for this Mac.
//    - A build with no app token is NOT broken. It falls back to the reader
//      pasting a key from publikhq.com/dashboard/api, which is also the route
//      for somebody who already has one.
//
//  CONSENT PRECEDES THE MINT. `provisionAKey` is deliberately not callable
//  without a `DisclosureAcceptance`, which only the disclosure sheet can make —
//  so "we provisioned before asking" is not a mistake this file can express.
//

import Combine
import Foundation

// MARK: - Consent

/// Proof that the reader saw the disclosure and accepted it.
///
/// A value only the disclosure sheet constructs. It carries nothing: its whole
/// job is to be impossible to obtain without having shown the sheet, so the
/// provisioning call cannot be made from anywhere that skipped it.
struct PublikAPIDisclosureAcceptance: Sendable {
    /// Which version of the disclosure wording the reader accepted. The gateway
    /// records this and never rejects on it (CONTRACT section 3.2 [S18]).
    let disclosureVersion: Int

    /// Called by the disclosure sheet when the reader taps accept, and nowhere
    /// else. Marked with an explicit argument label rather than a bare `init()`
    /// so a future caller has to type the words out.
    static func readerAcceptedTheDisclosure(
        disclosureVersion: Int = PublikAPIAccount.currentDisclosureVersion
    ) -> PublikAPIDisclosureAcceptance {
        PublikAPIDisclosureAcceptance(disclosureVersion: disclosureVersion)
    }
}

// MARK: - What the gateway told us

/// Whether this install has been linked to a publik account yet.
///
/// An anonymous install has a real key but, since publik's migration 0059, a
/// $0.00 balance: every metered call is refused with a 402 until it is linked
/// to a publik account (which gives that account $0.05 of free use, once), a
/// plan or a pack is added, or the reader pastes their own key. It also cannot
/// reach the largest model tier. Claiming it is what the CTA's primary button
/// is for.
enum PublikAPIClaimState: String, Sendable, Equatable {
    case anonymous
    case claimed

    /// Anything the gateway sends that this build does not know is treated as
    /// anonymous: the CTA then offers to link the computer, which is the safe
    /// wrong answer (an already-claimed install just sees a button it does not
    /// need, rather than a claimed-looking install that can never be linked).
    init(wireValue: String?) {
        self = PublikAPIClaimState(rawValue: wireValue ?? "") ?? .anonymous
    }
}

/// The last thing the gateway said about this install's money, kept so the CTA
/// can render without making a request of its own.
struct PublikAPIWalletSnapshot: Sendable, Equatable {
    /// Balance in micros (millionths of a dollar), the unit the gateway bills
    /// in. Rendered as dollars and never shown as a token or credit count —
    /// see `dollarsDescription` and the copy rule in `CONTRACT.md` section 12.
    var balanceMicros: Int
    var claimState: PublikAPIClaimState
    /// Where the CTA's primary button goes while the install is anonymous.
    var claimURLString: String?
    /// Where it goes once claimed.
    var addCreditURLString: String?
    /// The one link the gateway itself picked for this install (`top_up_url`:
    /// the claim page while anonymous, the add-credit page once claimed). Only
    /// `GET /balance` sends it; see `PublikAPIAddCredit`.
    var topUpURLString: String? = nil
    /// The publik install this key belongs to (`install_id` in `GET /balance`).
    /// Nil for a developer key pasted from the dashboard: it belongs to an
    /// account, not to an install, so publik's usage counts never treat it
    /// as this computer's. Only `GET /balance` sends it.
    var installIdentifier: String? = nil
    /// The app that install was minted for (`app_slug`); "iris" for a key Iris
    /// minted. Only `GET /balance` sends it.
    var appSlug: String? = nil

    /// "$0.25". Always two decimal places, always a dollar sign, rounded DOWN
    /// so Iris never advertises money that is not there.
    var dollarsDescription: String {
        Self.dollarsDescription(forMicros: balanceMicros)
    }

    static func dollarsDescription(forMicros micros: Int) -> String {
        let wholeCents = max(0, micros) / 10_000
        return String(format: "$%d.%02d", wholeCents / 100, wholeCents % 100)
    }
}

// MARK: - The account

/// Everything Iris knows about its publik API credential, and the one place
/// that credential is obtained.
@MainActor
final class PublikAPIAccount: ObservableObject {

    /// The disclosure wording Iris currently ships. Bump when the wording
    /// changes materially; the gateway records it. Version 2 is the
    /// "$0.00 to start, $0.05 of free use once you link" wording (publik
    /// migration 0059); version 1 promised a free start.
    static let currentDisclosureVersion = 2

    /// Whether the first-run card (balance + why it costs + link this computer)
    /// has been shown at least once. CONTRACT section 12 item 4 — "never a
    /// silent starter" — is enforced by checking this before spending.
    private static let firstRunCardShownDefaultsKey = "irisPublikAPIFirstRunCardShown"

    private let userDefaults: UserDefaults
    private let urlSession: URLSession

    /// The last wallet state seen, from provisioning or from an `x-publik-*`
    /// response header. Published so the settings card re-renders on its own.
    @Published private(set) var walletSnapshot: PublikAPIWalletSnapshot?

    /// True once a key is stored, whichever route it arrived by.
    @Published private(set) var hasKey: Bool

    /// What the last chat reply cost on publik API, in micros, or nil before
    /// the first one. Published so the "Last reply" line re-renders on its own.
    @Published private(set) var lastReplyChargeMicros: Int?

    /// Adds the calls of one reply together; see `PublikAPIReplyCostTally`.
    private var replyCostTally = PublikAPIReplyCostTally()

    /// The one pending "read the balance again" after a reply. Replaced, not
    /// stacked, so a burst of calls costs one `GET /balance`.
    private var pendingBalanceRefresh: Task<Void, Never>?

    /// How long to wait after a reply before reading the balance back. A
    /// streamed reply is settled by the gateway AFTER its last byte, so asking
    /// at once would read the balance with the call's hold still taken out.
    static let balanceRefreshDelayAfterAReply: Duration = .milliseconds(1_500)

    init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        self.hasKey = KeychainStore.hasSecret(ofKind: .publikAPIKey)
    }

    /// Uses isolated preferences and never reads the Mac's Keychain.
    /// Only used by isolated manager tests.
    init(inertForTesting userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.urlSession = URLSession(configuration: .ephemeral)
        self.hasKey = false
    }

    // MARK: Where requests go

    /// The gateway root for this install: the app's configured publik origin
    /// plus the gateway path. The origin is run through the same allowlist
    /// `AssistantTransport` uses, so a tampered Info.plist cannot redirect the
    /// key to somebody else's server.
    var gatewayBaseURL: URL {
        Self.gatewayPath(under: AssistantTransport.configuredPublikBaseURL())
    }

    /// Appends the gateway path unless it is already there.
    ///
    /// The provisioning response's `base_url` may reasonably be either the site
    /// origin or the gateway root — the contract shows requests against
    /// `{base}/messages`, which reads as the latter. Appending blindly would
    /// produce `/api/v1/api/v1/messages` against a server that sent the fuller
    /// form, and a 404 on every question is an unpleasant way to find that out.
    /// `URL.path` normalizes a trailing slash away, so one check covers both
    /// `…/api/v1` and `…/api/v1/`.
    static func gatewayPath(under baseURL: URL) -> URL {
        guard !baseURL.path.hasSuffix("/api/v1") else { return baseURL }
        return baseURL.appendingPathComponent("api/v1")
    }

    // MARK: The key

    var storedKey: String? {
        KeychainStore.readSecret(ofKind: .publikAPIKey)
    }

    /// Saves a key the reader pasted from the dashboard. The shape check is
    /// deliberately loose — the gateway is the authority on whether a key works
    /// — but a value that is obviously not a publik key is refused here so the
    /// reader is told immediately rather than by a 401 on their next question.
    @discardableResult
    func saveKeyPastedByTheReader(_ pastedKey: String) -> Bool {
        let trimmedKey = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.hasPrefix("pk_live_") || trimmedKey.hasPrefix("pk_test_") else {
            return false
        }
        try? KeychainStore.saveSecret(trimmedKey, ofKind: .publikAPIKey)
        hasKey = KeychainStore.hasSecret(ofKind: .publikAPIKey)
        // A pasted key belongs to an account the reader already has, so there is
        // nothing to disclose and nothing to gate: the card requirement in
        // CONTRACT section 12 is about the balance of the install Iris minted.
        userDefaults.set(true, forKey: Self.firstRunCardShownDefaultsKey)
        return true
    }

    func forgetKey() {
        try? KeychainStore.deleteSecret(ofKind: .publikAPIKey)
        hasKey = false
        walletSnapshot = nil
        pendingBalanceRefresh?.cancel()
        pendingBalanceRefresh = nil
        replyCostTally.forgetEverything()
        lastReplyChargeMicros = nil
    }

    // MARK: The first-run card

    var firstRunCardHasBeenShown: Bool {
        userDefaults.bool(forKey: Self.firstRunCardShownDefaultsKey)
    }

    func recordThatTheFirstRunCardWasShown() {
        userDefaults.set(true, forKey: Self.firstRunCardShownDefaultsKey)
    }

    /// CONTRACT section 12 item 4. A provisioned install may not spend its
    /// balance until the card has been in front of the reader once.
    var maySpendOnThisKey: Bool {
        hasKey && firstRunCardHasBeenShown
    }

    // MARK: Provisioning

    /// The build's app token, or nil when this build ships without one. The
    /// module reads it (`Publik.appToken`: the `PublikAppToken` Info.plist key
    /// that the release build expands from the PUBLIK_APP_TOKEN build setting).
    /// A template value or an empty one is not a token, so a mis-built copy
    /// stays on the paste route instead of sending nonsense to the gateway.
    static var buildAppToken: String? {
        let token = Publik.appToken
        return token.hasPrefix("pat_") ? token : nil
    }

    var canProvisionAutomatically: Bool { Self.buildAppToken != nil }

    enum ProvisioningFailure: Error, Equatable {
        /// This build ships no app token, so only the paste route exists.
        case thisBuildHasNoAppToken
        /// The gateway answered, but not with a key.
        case gatewayDeclined(statusCode: Int)
        /// The gateway was never reached.
        case couldNotReachPublik

        var userFacingMessage: String {
            switch self {
            case .thisBuildHasNoAppToken:
                return "this copy of iris can't set up publik API on its own. paste a key from publikhq.com/dashboard/api instead."
            case .gatewayDeclined:
                return "publik couldn't set this computer up just now. try again in a minute, or paste a key from publikhq.com/dashboard/api."
            case .couldNotReachPublik:
                return "i couldn't reach publik to set this up. check your connection and try again."
            }
        }
    }

    /// Adopts the install the publik module provisioned (`Publik.swift`) as
    /// the publik API key. The app delegate calls it after the gate when the
    /// reader pressed Connect your plan; `provisionAKey` calls it too. The
    /// gate showed their plan or balance and they agreed to use it, which is
    /// what the first-run card asks for (CONTRACT section 12 item 4), so
    /// spending is unlocked here.
    func adoptTheInstallKey(_ installKey: String) {
        guard installKey.hasPrefix("pk_") else { return }
        if storedKey != installKey {
            try? KeychainStore.saveSecret(installKey, ofKind: .publikAPIKey)
        }
        hasKey = KeychainStore.hasSecret(ofKind: .publikAPIKey)
        userDefaults.set(true, forKey: Self.firstRunCardShownDefaultsKey)
    }

    /// Sets up publik API from the settings sheet, after the disclosure. The
    /// install is the module's: the one the gate provisioned at launch
    /// (`Publik.readCredential()`), or a fresh one from `Publik.provision()`
    /// when the credential file is gone. Never a second install for this Mac.
    @discardableResult
    func provisionAKey(
        havingAccepted disclosureAcceptance: PublikAPIDisclosureAcceptance
    ) async -> Result<PublikAPIWalletSnapshot, ProvisioningFailure> {
        guard Self.buildAppToken != nil else {
            return .failure(.thisBuildHasNoAppToken)
        }
        let credential: Publik.Credential
        if let saved = Publik.readCredential() {
            credential = saved
        } else {
            do {
                credential = try await Publik.provision()
            } catch is URLError {
                return .failure(.couldNotReachPublik)
            } catch {
                return .failure(.gatewayDeclined(statusCode: 0))
            }
        }
        adoptTheInstallKey(credential.key)
        Publik.setChoice("publik")
        _ = await refreshTheBalance()
        return .success(walletSnapshot ?? PublikAPIWalletSnapshot(
            balanceMicros: 0,
            claimState: .anonymous,
            claimURLString: credential.claim_url,
            addCreditURLString: nil
        ))
    }

    // MARK: Reading the headers back

    /// Updates the remembered wallet from one metered response's `x-publik-*`
    /// headers, so the settings card stays current without polling.
    func noteHeaders(fromResponse httpResponse: HTTPURLResponse) {
        let balanceHeader = httpResponse.value(forHTTPHeaderField: "x-publik-balance")
        let claimStateHeader = httpResponse.value(forHTTPHeaderField: "x-publik-claim-state")
        guard balanceHeader != nil || claimStateHeader != nil else { return }

        var snapshot = walletSnapshot ?? PublikAPIWalletSnapshot(
            balanceMicros: 0,
            claimState: .anonymous,
            claimURLString: nil,
            addCreditURLString: nil
        )
        if let balanceHeader, let balanceMicros = Int(balanceHeader.trimmingCharacters(in: .whitespaces)) {
            snapshot.balanceMicros = balanceMicros
        }
        if let claimStateHeader {
            snapshot.claimState = PublikAPIClaimState(wireValue: claimStateHeader)
        }
        walletSnapshot = snapshot
    }

    // MARK: The balance, read back

    /// Reads `GET {gateway}/balance` and keeps what it says. Called at launch,
    /// when the settings panel opens, and (debounced) after every reply.
    ///
    /// Returns false and leaves the last good snapshot on screen when anything
    /// goes wrong — no key, offline, a non-2xx, a body without a balance. A
    /// balance line that blanks or drops to $0.00 because one read failed would
    /// tell the reader something false about their money.
    @discardableResult
    func refreshTheBalance() async -> Bool {
        guard let publikAPIKey = storedKey.flatMap({ PublikAPIKey($0) }) else { return false }

        var balanceRequest = URLRequest(url: gatewayBaseURL.appendingPathComponent("balance"))
        balanceRequest.httpMethod = "GET"
        balanceRequest.timeoutInterval = 15
        // `x-api-key` rather than a bearer header, which the gateway accepts
        // equally: it is the header `AssistantTransport.validatedRequest`
        // inspects, so this read passes the same "a pk_ key only ever reaches a
        // publik host" gate as every chat request.
        balanceRequest.setValue(publikAPIKey.value, forHTTPHeaderField: "x-api-key")
        guard let validatedBalanceRequest = try? AssistantTransport.validatedRequest(balanceRequest) else {
            return false
        }

        do {
            let (responseData, response) = try await urlSession.data(for: validatedBalanceRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let freshSnapshot = PublikAPIWalletSnapshot.parse(balanceResponseBody: responseData) else {
                return false
            }
            walletSnapshot = freshSnapshot
            return true
        } catch {
            return false
        }
    }

    /// Reads the balance back once the gateway has had time to settle the call
    /// that just finished. A second call inside the delay replaces the first.
    func refreshTheBalanceSoon() {
        pendingBalanceRefresh?.cancel()
        pendingBalanceRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.balanceRefreshDelayAfterAReply)
            guard !Task.isCancelled else { return }
            await self?.refreshTheBalance()
        }
    }

    // MARK: What each reply cost

    /// Starts adding up a chat reply. The returned identifier is handed back to
    /// `finishCountingTheReply` so a cancelled reply cannot close its successor.
    func beginCountingAReply() -> UUID {
        replyCostTally.beginAReply()
    }

    func finishCountingTheReply(_ replyIdentifier: UUID) {
        replyCostTally.finishTheReply(replyIdentifier)
    }

    /// One finished publik API call. Its cost joins the reply in progress, if
    /// there is one; the balance is taken from the receipt when the gateway had
    /// already settled the call, and read back from `/balance` otherwise.
    func noteACompletedCall(_ receipt: PublikAPICallReceipt) {
        if let chargeMicros = receipt.chargeMicros {
            replyCostTally.addACall(chargeMicros: chargeMicros)
            lastReplyChargeMicros = replyCostTally.lastReplyChargeMicros
        }
        if let settledBalanceMicros = receipt.settledBalanceMicros, var snapshot = walletSnapshot {
            snapshot.balanceMicros = settledBalanceMicros
            walletSnapshot = snapshot
        } else {
            refreshTheBalanceSoon()
        }
    }

    // MARK: Add credit

    /// Where the balance row's "Add credit" button goes right now: the
    /// `top_up_url` from the latest `/balance` answer, else the page the claim
    /// state implies, else the add-credit page. The 402's button goes through
    /// the same `PublikAPIAddCredit` rules, so the two cannot disagree.
    var urlStringForTheAddCreditButton: String {
        PublikAPIAddCredit.urlString(for: walletSnapshot)
    }

    /// Opens an "Add credit" page in the reader's own browser, through the same
    /// allowlist every other link Iris opens goes through.
    @discardableResult
    static func openTheAddCreditPage(_ addCreditURLString: String) -> Bool {
        ExternalLinkPolicy.openExternalURLIfAllowed(addCreditURLString)
    }
}

// MARK: - The 402

/// What the gateway said when the wallet is empty.
///
/// CONTRACT section 12 item 3: render the server's own message and exactly ONE
/// link. Iris does not write its own copy for this state — the server's wording
/// knows whether the reader still has to link the computer or merely top it up,
/// and inventing a sentence here is how the two get confused.
struct PublikAPIInsufficientCredit: Sendable, Equatable {
    let message: String
    let linkURLString: String?

    /// Parses one `402` body. Returns nil when the body is not the shape the
    /// gateway documents, so the caller falls back to a generic failure rather
    /// than showing half a sentence.
    static func parse(responseBody: Data) -> PublikAPIInsufficientCredit? {
        guard let payload = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
            return nil
        }
        // Anthropic-dialect errors are wrapped: {"type":"error","error":{…}}.
        let errorObject = (payload["error"] as? [String: Any]) ?? payload
        guard let message = (errorObject["message"] as? String) ?? (payload["message"] as? String),
              !message.isEmpty else {
            return nil
        }
        // Exactly one link, in the order the contract prefers.
        let linkURLString = (errorObject["top_up_url"] as? String)
            ?? (payload["top_up_url"] as? String)
            ?? (errorObject["claim_url"] as? String)
            ?? (payload["claim_url"] as? String)
            ?? (errorObject["add_credit_url"] as? String)
            ?? (payload["add_credit_url"] as? String)
        return PublikAPIInsufficientCredit(message: message, linkURLString: linkURLString)
    }
}
