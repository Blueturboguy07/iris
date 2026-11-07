//
//  PublikAccountLink.swift
//  leanring-buddy
//
//  Linking this Mac to the publik account the reader signed in to.
//
//  Signing in (Google, GitHub or email) used to keep only a Supabase session.
//  Nothing on publik's side learned that this computer belonged to that
//  account, so the usage counts (publik telemetry v1) counted a signed-in
//  reader as an anonymous computer. publik counts a computer by its account
//  only when the count carries a publik install key whose install is linked to
//  the account. So, when a session starts:
//
//    - a reader who already holds a publik API key from `POST /installs` has
//      that install CLAIMED: `POST /installs/claim` with the install's claim
//      code and the session's access token as the bearer;
//    - a reader with no publik API key, or with a developer key pasted from
//      the dashboard (`GET /balance` names no `install_id` for it, so publik
//      never counts it as this Mac), gets a small install of its own, minted
//      WITH the session's access token, which binds it to the account at mint.
//      Its key is kept apart from the publik API key (Keychain item
//      `publik-account-link-key`) and is never a model credential.
//
//  The usage counts carry the link key first when there is one.
//
//  The sign-in panel says "Signing in links this Mac to your publik account",
//  so the reader is told before it happens. Signing out deletes the link key
//  and revokes its install.
//
//  This file holds the pure parts (claim code parsing and request building),
//  so the unit suite can reach them without a network or a Keychain.
//

import Foundation

enum PublikAccountLink {

    /// publik's claim code alphabet: four characters, a dash, four characters,
    /// with the look-alike letters and digits (I, O, 0, 1) left out. The same
    /// pattern the gateway checks (`CLAIM_CODE_PATTERN`).
    private static let claimCodePattern = #"^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$"#

    /// The claim code inside a claim link, or nil when the link holds none.
    ///
    /// The gateway sends the link as `https://publikhq.com/claim/XXXX-XXXX`; a
    /// `?code=XXXX-XXXX` form is accepted too, so a change of link shape on the
    /// server does not silently stop the claim.
    static func claimCode(fromClaimURLString claimURLString: String?) -> String? {
        guard let claimURLString,
              let claimURL = URL(string: claimURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        var candidates: [String] = [claimURL.lastPathComponent]
        if let queryItems = URLComponents(url: claimURL, resolvingAgainstBaseURL: false)?.queryItems {
            candidates += queryItems.filter { $0.name == "code" }.compactMap(\.value)
        }
        for candidate in candidates {
            let normalizedCandidate = candidate.uppercased()
            if normalizedCandidate.range(of: claimCodePattern, options: .regularExpression) != nil {
                return normalizedCandidate
            }
        }
        return nil
    }

    /// `POST {gateway}/installs/claim` for one claim code, signed by the
    /// reader's session. Nil when the gateway is not a publik host: the
    /// session's access token is a publik account credential and goes to
    /// publik only.
    static func claimRequest(
        gatewayBaseURL: URL,
        claimCode: String,
        accountAccessToken: String
    ) -> URLRequest? {
        guard let gatewayHost = gatewayBaseURL.host, AssistantTransport.isAPublikHost(gatewayHost) else {
            return nil
        }
        var request = URLRequest(url: gatewayBaseURL.appendingPathComponent("installs").appendingPathComponent("claim"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accountAccessToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["claim_code": claimCode, "confirm": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `POST {gateway}/installs/revoke` with the install's own key and an
    /// empty body: publik revokes that one install (reason "user"). The key
    /// rides in `x-api-key`, the header `AssistantTransport.validatedRequest`
    /// inspects, so the same "a pk_ key only ever reaches a publik host" gate
    /// applies. Nil when that gate refuses.
    static func revokeRequest(gatewayBaseURL: URL, installKey: String) -> URLRequest? {
        var request = URLRequest(url: gatewayBaseURL.appendingPathComponent("installs").appendingPathComponent("revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(installKey, forHTTPHeaderField: "x-api-key")
        return try? AssistantTransport.validatedRequest(request)
    }

    /// This app's slug on publik, as `GET /balance` names it in `app_slug`.
    static let irisAppSlug = "iris"

    /// Whether linking this Mac needs an account-link install of its own,
    /// rather than a claim of the publik API key's install.
    ///
    /// publik counts a computer by its account only through a key whose
    /// install belongs to this app. A developer key pasted from the dashboard
    /// has no install (`install_id` is null), and a key minted for another app
    /// names that app, so neither can ever be counted as this Mac: both get a
    /// link install, exactly like a reader with no key at all.
    static func needsAnAccountLinkInstall(
        hasPublikAPIKey: Bool,
        walletInstallIdentifier: String?,
        walletAppSlug: String?
    ) -> Bool {
        guard hasPublikAPIKey else { return true }
        guard let walletInstallIdentifier, !walletInstallIdentifier.isEmpty else { return true }
        return walletAppSlug != irisAppSlug
    }

    /// Whether a URL may carry the reader's session token: publik hosts only.
    static func mayCarryTheAccountSession(_ url: URL?) -> Bool {
        guard let host = url?.host else { return false }
        return AssistantTransport.isAPublikHost(host)
    }
}
