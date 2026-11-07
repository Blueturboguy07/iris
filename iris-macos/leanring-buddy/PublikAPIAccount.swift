//
//  PublikAPIAccount.swift
//  leanring-buddy
//
//  The publik API credential: how Iris gets one, where it lives, and what the
//  gateway has most recently said about it.
//
//  `docs/assistant-credentials.md` is the cross-platform contract and
//  `CONTRACT.md` sections 3.2 (provisioning) and 12 (the CTA) are the gateway's
//  own spec. The short version:
//
//    - A packaged build ships a public app token (`pat_iris_<32>`). On first
//      run, AFTER the reader accepts the disclosure, Iris calls
//      `POST /api/v1/installs` and is handed a `pk_live_…` key and a claim
//      code, at a $0.00 balance — no account, no sign-in, no card needed to
//      get the key itself. Linking an account afterward (the claim_url CTA) is
//      what grants that account its one-time $0.05 of free use (publik
//      migration 0059, 2026-09-28). Until then every metered call is a 402.
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

    /// The Info.plist key holding the build's public app token. A build without
    /// one falls back to the paste route — see the file header.
    static let appTokenInfoPlistKey = "PublikAppToken"

    /// Where the client-minted install id is remembered. It must survive
    /// relaunches: re-minting one on every launch would ask the gateway for a
    /// fresh install every time, which is exactly what its per-IP mint caps
    /// exist to stop.
    private static let installIdentifierDefaultsKey = "irisPublikAPIInstallIdentifier"

    /// Whether the first-run card (balance + why it costs + link this computer)
    /// has been shown at least once. CONTRACT section 12 item 4 — "never a
    /// silent starter" — is enforced by checking this before spending.
    private static let firstRunCardShownDefaultsKey = "irisPublikAPIFirstRunCardShown"

    /// The gateway base the provisioning response named, when it named one.
    /// Honoured over any compiled default (contract, "Request shape").
    private static let baseURLFromProvisioningDefaultsKey = "irisPublikAPIBaseURL"

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

    /// The gateway origin for this install: what provisioning returned, else the
    /// app's configured publik origin. Both are run through the same allowlist
    /// `AssistantTransport` uses, so a tampered stored value cannot redirect the
    /// key to somebody else's server.
    var gatewayBaseURL: URL {
        let configuredOrigin = AssistantTransport.configuredPublikBaseURL()
        guard let storedBaseURLString = userDefaults.string(forKey: Self.baseURLFromProvisioningDefaultsKey),
              let allowedBaseURLString = GuideService.normalizedAPIBase(storedBaseURLString),
              let storedBaseURL = URL(string: allowedBaseURLString) else {
            return Self.gatewayPath(under: configuredOrigin)
        }
        return Self.gatewayPath(under: storedBaseURL)
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

    /// The build's app token, or nil when this build ships without one.
    static var buildAppToken: String? {
        guard let token = AppBundleConfiguration.stringValue(forKey: appTokenInfoPlistKey),
              !token.isEmpty,
              // A template value left in an Info.plist is not a token. Refusing
              // it here is what keeps a mis-built copy on the paste route
              // instead of sending nonsense to the gateway on every launch.
              token.hasPrefix("pat_") else {
            return nil
        }
        return token
    }

    var canProvisionAutomatically: Bool { Self.buildAppToken != nil }

    /// The install id for this copy of Iris, minted once and remembered.
    func installIdentifier() -> String {
        if let existing = userDefaults.string(forKey: Self.installIdentifierDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        userDefaults.set(fresh, forKey: Self.installIdentifierDefaultsKey)
        return fresh
    }

    /// Discards the remembered install id so the next provisioning call mints a
    /// fresh one. CONTRACT section 3.2 [B1]: a replayed install id answers `200`
    /// with `"key": null`, and an app holding no credential is allowed to mint a
    /// new id ONCE to recover from that.
    private func forgetInstallIdentifier() {
        userDefaults.removeObject(forKey: Self.installIdentifierDefaultsKey)
    }

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

    /// Mints a key for this install. Requires the disclosure to have been
    /// accepted — see the file header.
    ///
    /// `accountAccessToken` is the reader's publik session when they are
    /// signed in. It rides as the bearer of the mint, which binds the new
    /// install to that account at once (the gateway claims it inside the same
    /// call), so a signed-in reader is counted by their account from the
    /// first request on. Nil when signed out: the mint is anonymous, as before.
    @discardableResult
    func provisionAKey(
        havingAccepted disclosureAcceptance: PublikAPIDisclosureAcceptance,
        accountAccessToken: String? = nil
    ) async -> Result<PublikAPIWalletSnapshot, ProvisioningFailure> {
        guard let appToken = Self.buildAppToken else {
            return .failure(.thisBuildHasNoAppToken)
        }

        let firstAttempt = await requestAnInstall(
            appToken: appToken,
            installIdentifier: installIdentifier(),
            disclosureVersion: disclosureAcceptance.disclosureVersion,
            accountAccessToken: accountAccessToken
        )

        switch firstAttempt {
        case .failure(let failure):
            return .failure(failure)
        case .success(let response):
            if let key = response.key {
                return .success(adopt(response: response, key: key))
            }
            // A 200 with no key is a replay of an install id we already used.
            // With no credential in hand that is a dead end, so mint one fresh
            // id and try exactly once more (CONTRACT 3.2 [B1] allows one).
            guard storedKey == nil else {
                return .success(adopt(response: response, key: nil))
            }
            forgetInstallIdentifier()
            let secondAttempt = await requestAnInstall(
                appToken: appToken,
                installIdentifier: installIdentifier(),
                disclosureVersion: disclosureAcceptance.disclosureVersion,
                accountAccessToken: accountAccessToken
            )
            switch secondAttempt {
            case .failure(let failure):
                return .failure(failure)
            case .success(let retriedResponse):
                guard let retriedKey = retriedResponse.key else {
                    return .failure(.gatewayDeclined(statusCode: 200))
                }
                return .success(adopt(response: retriedResponse, key: retriedKey))
            }
        }
    }

    /// One `POST /api/v1/installs`.
    private func requestAnInstall(
        appToken: String,
        installIdentifier: String,
        disclosureVersion: Int?,
        accountAccessToken: String?
    ) async -> Result<InstallsResponse, ProvisioningFailure> {
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        guard let request = Self.installRequest(
            gatewayBaseURL: gatewayBaseURL,
            appToken: appToken,
            installIdentifier: installIdentifier,
            disclosureVersion: disclosureVersion,
            accountAccessToken: accountAccessToken,
            appVersion: AppBundleConfiguration.stringValue(forKey: "CFBundleShortVersionString") ?? "0",
            operatingSystemVersion: "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)",
            machineArchitecture: Self.machineArchitecture
        ) else {
            return .failure(.couldNotReachPublik)
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.couldNotReachPublik)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return .failure(.gatewayDeclined(statusCode: httpResponse.statusCode))
            }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.gatewayDeclined(statusCode: httpResponse.statusCode))
            }
            return .success(InstallsResponse(payload: payload))
        } catch {
            return .failure(.couldNotReachPublik)
        }
    }

    /// The request for one `POST /api/v1/installs`. Pure, so the suite can
    /// check its shape.
    ///
    /// - `disclosureVersion` is the wording the reader accepted on the publik
    ///   API disclosure sheet. Nil leaves the field out (the gateway then
    ///   records version 1, its default): the account-link mint is made at
    ///   sign-in, not from that sheet, so claiming a version would be false.
    /// - `accountAccessToken`, when present, rides as the bearer and binds the
    ///   install to that publik account at mint. The app token stays in the
    ///   body, where the gateway reads it first. A gateway that is not a
    ///   publik host never receives the session: nil is returned instead.
    static func installRequest(
        gatewayBaseURL: URL,
        appToken: String,
        installIdentifier: String,
        disclosureVersion: Int?,
        accountAccessToken: String?,
        appVersion: String,
        operatingSystemVersion: String,
        machineArchitecture: String
    ) -> URLRequest? {
        var request = URLRequest(url: gatewayBaseURL.appendingPathComponent("installs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountAccessToken {
            guard PublikAccountLink.mayCarryTheAccountSession(gatewayBaseURL) else { return nil }
            request.setValue("Bearer \(accountAccessToken)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "app_token": appToken,
            "app_slug": "iris",
            "app_version": appVersion,
            "os": "macos",
            "os_version": operatingSystemVersion,
            "arch": machineArchitecture,
            "install_id": installIdentifier,
            // Iris speaks the Anthropic Messages wire format, so it asks the
            // gateway for that dialect rather than the chat-completions one the
            // contract's example shows.
            "dialects": ["messages"],
        ]
        if let disclosureVersion {
            body["disclosure_version"] = disclosureVersion
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The fields of a provisioning response Iris reads. Everything else the
    /// gateway sends is ignored rather than stored.
    struct InstallsResponse {
        let key: String?
        let balanceMicros: Int
        let claimState: PublikAPIClaimState
        let claimURLString: String?
        let addCreditURLString: String?
        let baseURLString: String?

        init(payload: [String: Any]) {
            key = (payload["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // `balance_micros` and `starting_credit_micros` are the same value
            // in this release of the gateway (CONTRACT 3.2); either is accepted
            // so a rename on one side does not blank the balance line.
            balanceMicros = payload["balance_micros"] as? Int
                ?? payload["starting_credit_micros"] as? Int
                ?? payload["starter_micros"] as? Int
                ?? 0
            claimState = PublikAPIClaimState(wireValue: payload["claim_state"] as? String)
            claimURLString = payload["claim_url"] as? String
            addCreditURLString = payload["add_credit_url"] as? String
            baseURLString = payload["base_url"] as? String
        }
    }

    @discardableResult
    private func adopt(response: InstallsResponse, key: String?) -> PublikAPIWalletSnapshot {
        if let key {
            try? KeychainStore.saveSecret(key, ofKind: .publikAPIKey)
            hasKey = KeychainStore.hasSecret(ofKind: .publikAPIKey)
        }
        if let baseURLString = response.baseURLString,
           let allowedBaseURLString = GuideService.normalizedAPIBase(baseURLString) {
            userDefaults.set(allowedBaseURLString, forKey: Self.baseURLFromProvisioningDefaultsKey)
        }
        let snapshot = PublikAPIWalletSnapshot(
            balanceMicros: response.balanceMicros,
            claimState: response.claimState,
            claimURLString: response.claimURLString,
            addCreditURLString: response.addCreditURLString
        )
        walletSnapshot = snapshot
        return snapshot
    }

    // MARK: Linking this computer to the signed-in publik account

    /// Where the install id of the account-link install is remembered. It is
    /// separate from the publik API install's id on purpose: if the reader
    /// later accepts the publik API disclosure, that mint keeps its own id and
    /// is not answered as a replay of the link install.
    private static let accountLinkInstallIdentifierDefaultsKey = "irisPublikAccountLinkInstallIdentifier"

    /// The key of the install that links this Mac to the signed-in account,
    /// or nil. Read only by the usage-count client; never a model credential.
    var storedAccountLinkKey: String? {
        KeychainStore.readSecret(ofKind: .publikAccountLinkKey)
    }

    /// What one attempt to link this computer did. Logged as a word, never
    /// shown to the reader: linking is best effort and silent.
    enum AccountLinkOutcome: Equatable, Sendable {
        /// The publik API install this Mac already had is now claimed.
        case claimedTheExistingInstall
        /// The publik API install was already linked to an account.
        case existingInstallWasAlreadyLinked
        /// A new install, bound to the account, now holds the link key.
        case mintedAnAccountLinkInstall
        /// A link install from earlier in this session is still here.
        case alreadyHadAnAccountLinkInstall
        /// This build ships no app token, so it cannot mint.
        case thisBuildHasNoAppToken
        /// `GET /balance` could not be read, so nothing was done.
        case walletUnreadable
        /// The wallet held no claim code.
        case noClaimCodeAvailable
        /// publik answered, but not with success.
        case gatewayDeclined(statusCode: Int)
        /// publik was not reached.
        case couldNotReachPublik
    }

    /// Links this computer to the publik account the reader just signed in to.
    ///
    /// Called once per session start (sign-in, or the silent restore at
    /// launch) with that session's access token. With a publik API key that
    /// Iris minted on this Mac, its install is claimed. Without one, or with a
    /// developer key pasted from the dashboard (no install of its own, so
    /// publik never counts it as this computer), a small install bound to the
    /// account is minted and its key kept apart from the publik API key.
    /// Never throws and never touches the UI: the reader's chat route is the
    /// same before and after.
    @discardableResult
    func linkThisComputerToTheSignedInAccount(accountAccessToken: String) async -> AccountLinkOutcome {
        if storedKey != nil {
            // Always a fresh read: `install_id` and `app_slug` come from
            // `GET /balance` only. A failed read changes nothing.
            guard await refreshTheBalance(), let snapshot = walletSnapshot else {
                return .walletUnreadable
            }
            if !PublikAccountLink.needsAnAccountLinkInstall(
                hasPublikAPIKey: true,
                walletInstallIdentifier: snapshot.installIdentifier,
                walletAppSlug: snapshot.appSlug
            ) {
                return await claimTheExistingInstall(snapshot: snapshot, accountAccessToken: accountAccessToken)
            }
        }
        return await mintAnAccountLinkInstall(accountAccessToken: accountAccessToken)
    }

    /// Case A: the reader holds a publik API key from an Iris install, which
    /// may still be anonymous. The claim code comes from that fresh wallet.
    private func claimTheExistingInstall(
        snapshot: PublikAPIWalletSnapshot,
        accountAccessToken: String
    ) async -> AccountLinkOutcome {
        guard snapshot.claimState == .anonymous else { return .existingInstallWasAlreadyLinked }
        guard let claimCode = PublikAccountLink.claimCode(fromClaimURLString: snapshot.claimURLString)
                ?? PublikAccountLink.claimCode(fromClaimURLString: snapshot.topUpURLString),
              let claimRequest = PublikAccountLink.claimRequest(
                gatewayBaseURL: gatewayBaseURL,
                claimCode: claimCode,
                accountAccessToken: accountAccessToken
              ) else {
            return .noClaimCodeAvailable
        }

        do {
            let (_, response) = try await urlSession.data(for: claimRequest)
            guard let httpResponse = response as? HTTPURLResponse else { return .couldNotReachPublik }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return .gatewayDeclined(statusCode: httpResponse.statusCode)
            }
            // The wallet changed hands (and may have gained the one-time link
            // credit), so the card is re-read rather than guessed.
            _ = await refreshTheBalance()
            return .claimedTheExistingInstall
        } catch {
            return .couldNotReachPublik
        }
    }

    /// Case C: no publik API key. Mints an install bound to the account. The
    /// same replay rule as `provisionAKey`: a `200` with no key means the id
    /// was used before, so one fresh id is minted and tried once more.
    private func mintAnAccountLinkInstall(accountAccessToken: String) async -> AccountLinkOutcome {
        guard storedAccountLinkKey == nil else { return .alreadyHadAnAccountLinkInstall }
        guard let appToken = Self.buildAppToken else { return .thisBuildHasNoAppToken }

        for attemptNumber in 1...2 {
            let result = await requestAnInstall(
                appToken: appToken,
                installIdentifier: accountLinkInstallIdentifier(),
                disclosureVersion: nil,
                accountAccessToken: accountAccessToken
            )
            switch result {
            case .failure(.gatewayDeclined(let statusCode)):
                return .gatewayDeclined(statusCode: statusCode)
            case .failure:
                return .couldNotReachPublik
            case .success(let response):
                if let linkKey = response.key {
                    try? KeychainStore.saveSecret(linkKey, ofKind: .publikAccountLinkKey)
                    return .mintedAnAccountLinkInstall
                }
                if attemptNumber == 1 { forgetAccountLinkInstallIdentifier() }
            }
        }
        return .gatewayDeclined(statusCode: 200)
    }

    /// Called when the reader signs out: the link key is deleted at once, then
    /// its install is revoked on publik, best effort. A failed revoke leaves an
    /// install nobody holds a key for, which publik's idle sweep retires.
    func forgetTheAccountLink() async {
        guard let linkKey = storedAccountLinkKey else { return }
        try? KeychainStore.deleteSecret(ofKind: .publikAccountLinkKey)
        forgetAccountLinkInstallIdentifier()
        guard let revokeRequest = PublikAccountLink.revokeRequest(
            gatewayBaseURL: gatewayBaseURL,
            installKey: linkKey
        ) else { return }
        _ = try? await urlSession.data(for: revokeRequest)
    }

    private func accountLinkInstallIdentifier() -> String {
        if let existing = userDefaults.string(forKey: Self.accountLinkInstallIdentifierDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        userDefaults.set(fresh, forKey: Self.accountLinkInstallIdentifierDefaultsKey)
        return fresh
    }

    private func forgetAccountLinkInstallIdentifier() {
        userDefaults.removeObject(forKey: Self.accountLinkInstallIdentifierDefaultsKey)
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

    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
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
