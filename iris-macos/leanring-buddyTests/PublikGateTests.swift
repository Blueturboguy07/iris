//
//  PublikGateTests.swift
//  leanring-buddyTests
//
//  The publik module (`Publik.swift`): the slug and the version the publik
//  scan reads, and the words of the gate, which are the same in every publik
//  app (publikhq.com/sdk/publik.swift.md). Nothing here touches the network,
//  the credential file or the Keychain.
//

import Foundation
import Testing
@testable import Iris

@Suite("Sign in with publik")
struct PublikGateTests {

    @Test func theModuleNamesThisListingAndItsVersion() {
        #expect(Publik.appSlug == "iris")
        #expect(Publik.usesAI, "Iris uses AI, so the gate asks how it is paid for")
        #expect(Publik.credentialURL.path.hasSuffix("/publik/apps/iris.json"))
        // The suite runs inside the Iris build under test, so the module's
        // version literal has to follow MARKETING_VERSION. A bump that forgets
        // the module would count every user under the old version.
        let hostVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #expect(hostVersion == Publik.appVersion)
    }

    @Test func theAppTokenHasOneSource() {
        // `PublikAPIAccount.buildAppToken` is what the settings card asks; the
        // module is what provisions. They read the same Info.plist key.
        if let buildToken = PublikAPIAccount.buildAppToken {
            #expect(buildToken == Publik.appToken)
        } else {
            #expect(!Publik.appToken.hasPrefix("pat_"))
        }
    }

    @Test func theSignInScreenHasTheContractWords() {
        let screen = Publik.gateScreen("sign_in")
        #expect(screen.title == "Sign in with publik")
        #expect(screen.body == "This app uses your publik account. Click Sign in with publik, then sign in in your browser. This window continues when you are signed in.")
        #expect(screen.note == nil)
        #expect(screen.buttons.map { $0.label } == ["Sign in with publik"])
        #expect(screen.buttons.map { $0.action } == ["sign_in"])

        let waiting = Publik.gateScreen("sign_in", note: "Waiting for you to sign in in your browser.")
        #expect(waiting.note == "Waiting for you to sign in in your browser.")
    }

    @Test func theUnreachableScreenOffersRetryOnly() {
        let screen = Publik.gateScreen("unreachable")
        #expect(screen.title == "Sign in with publik")
        #expect(screen.body == "publik is not reachable. Check your connection.")
        #expect(screen.buttons.map { $0.label } == ["Retry"])
        #expect(screen.buttons.map { $0.action } == ["retry"])
        // A message from publik replaces the connection line.
        #expect(Publik.gateScreen("unreachable", message: "This key is not valid.").body == "This key is not valid.")
    }

    @Test func noPlanAndNoBalanceAsksHowToPayForAI() {
        let wallet = Publik.Wallet(claimed: true, claimURL: nil, handle: "mann", planKind: "none", planLabel: nil, balanceMicros: 0, topUpURL: "https://publikhq.com/wallet")
        let screen = Publik.gateScreen("choose", wallet)
        #expect(screen.title == "Choose how to pay for AI")
        #expect(screen.body == "You are signed in as @mann. This app uses AI. Get a publik plan, or use your own key.")
        #expect(screen.buttons.map { $0.label } == ["Get a plan", "Use my own key"])
        #expect(screen.buttons.map { $0.action } == ["get_plan", "own_key"])
    }

    @Test func aPlanOrABalanceOffersToConnectIt() {
        var wallet = Publik.Wallet(claimed: true, claimURL: nil, handle: "mann", planKind: "plan", planLabel: "Plus", balanceMicros: 0, topUpURL: "https://publikhq.com/wallet")
        let plan = Publik.gateScreen("choose", wallet)
        #expect(plan.title == "Connect your plan")
        #expect(plan.body == "You are signed in as @mann. Your plan: Plus. Connect it to use AI in this app, or use your own key.")
        #expect(plan.buttons.map { $0.label } == ["Connect your plan", "Use my own key"])
        #expect(plan.buttons.map { $0.action } == ["connect", "own_key"])

        wallet.planKind = "pack"
        wallet.planLabel = nil
        wallet.balanceMicros = 1_500_000
        wallet.handle = nil
        let balance = Publik.gateScreen("choose", wallet)
        #expect(balance.body == "You are signed in to publik. Your balance: $1.50. Connect it to use AI in this app, or use your own key.")
    }

    @Test func a402IsTheServersMessageAndOneLink() {
        let body = Data(#"{"error":{"type":"insufficient_credit","message":"Add a plan to continue.","top_up_url":"https://publikhq.com/wallet?top_up=1"}}"#.utf8)
        let parsed = Publik.topUpURLFrom402(body)
        #expect(parsed.message == "Add a plan to continue.")
        #expect(parsed.url?.absoluteString == "https://publikhq.com/wallet?top_up=1")
        #expect(Publik.topUpURLFrom402(Data("{}".utf8)).url == nil)
    }
}
