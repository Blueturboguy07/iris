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
//      `POST /api/v1/installs` and is handed a `pk_live_…` key, a claim code
//      and a small starter balance. No account, no sign-in, no card.
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
/// An anonymous install is a real, working install — it just has only the
/// starter balance and cannot reach the largest model tier. Claiming it is what
/// the CTA's primary button is for.
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
    /// changes materially; the gateway records it.
    static let currentDisclosureVersion = 1

    /// The Info.plist key holding the build's public app token. A build without
    /// one falls back to the paste route — see the file header.
    static let appTokenInfoPlistKey = "PublikAppToken"

    /// Where the client-minted install id is remembered. It must survive
    /// relaunches: re-minting one on every launch would ask the gateway for a
    /// fresh starter every time, which is exactly what its per-IP starter caps
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

    init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        self.hasKey = KeychainStore.hasSecret(ofKind: .publikAPIKey)
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
    static func gatewayPath(under baseURL: URL) -> URL {
        let path = baseURL.path
        if path.hasSuffix("/api/v1") || path.hasSuffix("/api/v1/") {
            return baseURL
        }
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
        // no starter to disclose and nothing to gate: the card requirement in
        // CONTRACT section 12 is about the starter this install was granted.
        userDefaults.set(true, forKey: Self.firstRunCardShownDefaultsKey)
        return true
    }

    func forgetKey() {
        try? KeychainStore.deleteSecret(ofKind: .publikAPIKey)
        hasKey = false
        walletSnapshot = nil
    }

    // MARK: The first-run card

    var firstRunCardHasBeenShown: Bool {
        userDefaults.bool(forKey: Self.firstRunCardShownDefaultsKey)
    }

    func recordThatTheFirstRunCardWasShown() {
        userDefaults.set(true, forKey: Self.firstRunCardShownDefaultsKey)
    }

    /// CONTRACT section 12 item 4. A provisioned install may not spend its
    /// starter until the card has been in front of the reader once.
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
    @discardableResult
    func provisionAKey(
        havingAccepted disclosureAcceptance: PublikAPIDisclosureAcceptance
    ) async -> Result<PublikAPIWalletSnapshot, ProvisioningFailure> {
        guard let appToken = Self.buildAppToken else {
            return .failure(.thisBuildHasNoAppToken)
        }

        let firstAttempt = await requestAnInstall(
            appToken: appToken,
            disclosureAcceptance: disclosureAcceptance
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
                disclosureAcceptance: disclosureAcceptance
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
        disclosureAcceptance: PublikAPIDisclosureAcceptance
    ) async -> Result<InstallsResponse, ProvisioningFailure> {
        var request = URLRequest(url: gatewayBaseURL.appendingPathComponent("installs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let body: [String: Any] = [
            "app_token": appToken,
            "app_slug": "iris",
            "app_version": AppBundleConfiguration.stringValue(forKey: "CFBundleShortVersionString") ?? "0",
            "os": "macos",
            "os_version": "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)",
            "arch": Self.machineArchitecture,
            "install_id": installIdentifier(),
            "disclosure_version": disclosureAcceptance.disclosureVersion,
            // Iris speaks the Anthropic Messages wire format, so it asks the
            // gateway for that dialect rather than the chat-completions one the
            // contract's example shows.
            "dialects": ["messages"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
