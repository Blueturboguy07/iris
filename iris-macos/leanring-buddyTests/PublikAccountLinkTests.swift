//
//  PublikAccountLinkTests.swift
//  leanring-buddyTests
//
//  The pure parts of linking this Mac to the signed-in publik account: the
//  claim code read from a claim link, and the three requests (claim, the
//  user-bound mint, revoke). The property that matters most is the same one
//  `AssistantTransportTests` guards: the reader's session token and the link
//  key go to a publik host and nowhere else.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite("publik account link")
struct PublikAccountLinkTests {

    static let publikGatewayURL = URL(string: "https://publikhq.com/api/v1")!
    static let foreignGatewayURL = URL(string: "https://example.com/api/v1")!
    static let fakeSessionToken = "eyJhbGciOiJIUzI1NiJ9.not-a-real-session"
    static let fakeLinkKey = "pk_live_abc123456789_0123456789abcdef0123456789abcdef"

    // MARK: Claim codes

    @Test func readsTheClaimCodeFromTheClaimPath() {
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/claim/ABCD-EFGH") == "ABCD-EFGH")
    }

    @Test func readsTheClaimCodeFromACodeQuery() {
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/claim?code=WXYZ-2345") == "WXYZ-2345")
    }

    @Test func upperCasesALowerCaseClaimCode() {
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/claim/abcd-efgh") == "ABCD-EFGH")
    }

    @Test func refusesAnythingThatIsNotAClaimCode() {
        #expect(PublikAccountLink.claimCode(fromClaimURLString: nil) == nil)
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "") == nil)
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/dashboard/api") == nil)
        // The alphabet leaves out I, O, 0 and 1.
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/claim/ABCD-EF0H") == nil)
        #expect(PublikAccountLink.claimCode(fromClaimURLString: "https://publikhq.com/claim/ABCDEFGH") == nil)
    }

    // MARK: The claim request

    @Test func theClaimRequestCarriesTheSessionAndConfirms() throws {
        let request = try #require(PublikAccountLink.claimRequest(
            gatewayBaseURL: Self.publikGatewayURL,
            claimCode: "ABCD-EFGH",
            accountAccessToken: Self.fakeSessionToken
        ))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://publikhq.com/api/v1/installs/claim")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeSessionToken)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["claim_code"] as? String == "ABCD-EFGH")
        #expect(payload["confirm"] as? Bool == true)
        #expect(payload.count == 2)
    }

    @Test func theSessionNeverGoesToAForeignHost() {
        #expect(PublikAccountLink.claimRequest(
            gatewayBaseURL: Self.foreignGatewayURL,
            claimCode: "ABCD-EFGH",
            accountAccessToken: Self.fakeSessionToken
        ) == nil)
        #expect(PublikAccountLink.mayCarryTheAccountSession(Self.foreignGatewayURL) == false)
        #expect(PublikAccountLink.mayCarryTheAccountSession(Self.publikGatewayURL) == true)
        #expect(PublikAccountLink.mayCarryTheAccountSession(nil) == false)
    }

    // MARK: The revoke request

    @Test func theRevokeRequestCarriesTheLinkKeyOnly() throws {
        let request = try #require(PublikAccountLink.revokeRequest(
            gatewayBaseURL: Self.publikGatewayURL,
            installKey: Self.fakeLinkKey
        ))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://publikhq.com/api/v1/installs/revoke")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.fakeLinkKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test func theLinkKeyNeverGoesToAForeignHost() {
        #expect(PublikAccountLink.revokeRequest(
            gatewayBaseURL: Self.foreignGatewayURL,
            installKey: Self.fakeLinkKey
        ) == nil)
    }

    // MARK: The install request

    // The gateway is optional rather than defaulted to `publikGatewayURL`: a
    // default argument is evaluated outside the main actor, where that static
    // property may not be read.
    private static func installRequest(
        gatewayBaseURL: URL? = nil,
        disclosureVersion: Int?,
        accountAccessToken: String?
    ) -> URLRequest? {
        PublikAPIAccount.installRequest(
            gatewayBaseURL: gatewayBaseURL ?? publikGatewayURL,
            appToken: "pat_iris_0123456789abcdef0123456789abcdef",
            installIdentifier: "3f0c2a52-7a1e-4c1b-9a53-0b6c0e1d2f44",
            disclosureVersion: disclosureVersion,
            accountAccessToken: accountAccessToken,
            appVersion: "0.9.17",
            operatingSystemVersion: "15.4",
            machineArchitecture: "arm64"
        )
    }

    private static func payload(of request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func aSignedInMintCarriesTheSessionAndKeepsTheAppTokenInTheBody() throws {
        let request = try #require(Self.installRequest(disclosureVersion: 1, accountAccessToken: Self.fakeSessionToken))
        #expect(request.url?.absoluteString == "https://publikhq.com/api/v1/installs")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeSessionToken)")
        let payload = try Self.payload(of: request)
        #expect(payload["app_token"] as? String == "pat_iris_0123456789abcdef0123456789abcdef")
        #expect(payload["app_slug"] as? String == "iris")
        #expect(payload["os"] as? String == "macos")
        #expect(payload["disclosure_version"] as? Int == 1)
    }

    @Test func aSignedOutMintSendsNoAuthorization() throws {
        let request = try #require(Self.installRequest(disclosureVersion: 1, accountAccessToken: nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func theLinkMintLeavesTheDisclosureVersionOut() throws {
        let request = try #require(Self.installRequest(disclosureVersion: nil, accountAccessToken: Self.fakeSessionToken))
        let payload = try Self.payload(of: request)
        #expect(payload.keys.contains("disclosure_version") == false)
        #expect(payload["install_id"] as? String == "3f0c2a52-7a1e-4c1b-9a53-0b6c0e1d2f44")
    }

    @Test func aMintToAForeignHostNeverCarriesTheSession() {
        #expect(Self.installRequest(
            gatewayBaseURL: Self.foreignGatewayURL,
            disclosureVersion: nil,
            accountAccessToken: Self.fakeSessionToken
        ) == nil)
    }

    // MARK: Which keys publik can count as this Mac

    @Test func theWalletNamesTheInstallAndTheAppOfAnIrisKey() throws {
        let body = Data("""
        {"install_id":"7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41","app_slug":"iris","claim_state":"anonymous",
         "balance_micros":0,"available_micros":0,"claim_url":"https://publikhq.com/claim/HK7F-2QWD",
         "top_up_url":"https://publikhq.com/claim/HK7F-2QWD"}
        """.utf8)
        let snapshot = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: body))
        #expect(snapshot.installIdentifier == "7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41")
        #expect(snapshot.appSlug == "iris")
        // The fields the card already used are unchanged.
        #expect(snapshot.claimState == .anonymous)
        #expect(snapshot.claimURLString == "https://publikhq.com/claim/HK7F-2QWD")
        #expect(snapshot.balanceMicros == 0)
    }

    @Test func aDashboardKeysWalletNamesNoInstall() throws {
        let body = Data("""
        {"install_id":null,"app_slug":null,"claim_state":"claimed","balance_micros":1843210,
         "add_credit_url":"https://publikhq.com/dashboard/api/add"}
        """.utf8)
        let snapshot = try #require(PublikAPIWalletSnapshot.parse(balanceResponseBody: body))
        #expect(snapshot.installIdentifier == nil)
        #expect(snapshot.appSlug == nil)
        #expect(snapshot.claimState == .claimed)
    }

    @Test func noKeyNeedsALinkInstall() {
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: false, walletInstallIdentifier: nil, walletAppSlug: nil
        ))
    }

    @Test func aPastedDashboardKeyNeedsALinkInstall() {
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: true, walletInstallIdentifier: nil, walletAppSlug: nil
        ))
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: true, walletInstallIdentifier: "", walletAppSlug: "iris"
        ))
    }

    @Test func aKeyMintedForAnotherAppNeedsALinkInstall() {
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: true, walletInstallIdentifier: "7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41", walletAppSlug: "cue"
        ))
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: true, walletInstallIdentifier: "7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41", walletAppSlug: nil
        ))
    }

    @Test func anIrisKeyIsClaimedInstead() {
        #expect(PublikAccountLink.needsAnAccountLinkInstall(
            hasPublikAPIKey: true, walletInstallIdentifier: "7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41", walletAppSlug: "iris"
        ) == false)
    }

    // MARK: The secret

    @Test func theLinkKeyHasItsOwnKeychainItem() {
        #expect(KeychainSecretKind.publikAccountLinkKey.rawValue == "publik-account-link-key")
        #expect(KeychainSecretKind.publikAccountLinkKey != .publikAPIKey)
    }
}
