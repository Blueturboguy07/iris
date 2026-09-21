//
//  AssistantProviderPreference.swift
//  leanring-buddy
//
//  Which of the three providers answers questions, as an explicit choice the
//  reader made rather than something Iris worked out from what happened to be
//  lying around.
//
//  This replaces an implicit ladder that was quietly wrong: being signed in
//  beat a key the reader had pasted themselves, so somebody who deliberately
//  connected their own Anthropic account could never actually reach it and
//  nothing on screen said so.
//
//  THE RULE THAT MATTERS: a stored preference that has stopped working does NOT
//  fall through to another provider. Spending somebody's money on an account
//  they did not choose is worse than an error message, so a broken choice says
//  what broke. Only the absence of a choice resolves down the list.
//

import Foundation

/// The three things that can answer a question.
enum AssistantProviderPreference: String, CaseIterable, Sendable, Equatable {
    /// publik's metered gateway. The default, and the only one that works
    /// without the reader bringing anything of their own.
    case publikAPI = "publik-api"
    /// The reader's own `sk-ant-…` key, straight to Anthropic.
    case anthropicKey = "anthropic-key"
    /// The reader's ChatGPT account, driven through their own `codex` CLI.
    case codex = "codex"

    /// What the picker shows.
    var displayName: String {
        switch self {
        case .publikAPI: return "publik API"
        case .anthropicKey: return "Your own Anthropic key"
        case .codex: return "Sign in with ChatGPT"
        }
    }

    /// The one-line explanation under each choice.
    ///
    /// Copy rules (`CONTRACT.md` section 12 item 5, and the site's own
    /// `copy-guard.test.ts`): say "publik API", talk in dollars, never tokens
    /// and never "credits" as a unit, and never name the upstream provider in
    /// the justification. "ChatGPT" is named in the Codex row because that is
    /// the account the reader signs in to, not a model publik is reselling.
    var explanation: String {
        switch self {
        case .publikAPI:
            return "Works right away. You pay for what you use, at half what the model would cost you directly."
        case .anthropicKey:
            return "Your key, your bill, straight to Anthropic. publik never sees it."
        case .codex:
            // The limitation is named here rather than discovered mid-answer:
            // `codex exec` has no tool-use wire format, so on this route Iris
            // answers in words and cannot copy, run or open things for you.
            return "Free if you already pay for ChatGPT. Iris drives the codex CLI and stores nothing. Answers only — it can't run things for you."
        }
    }
}

// MARK: - Where the choice lives

/// The reader's stored provider choice.
///
/// Absent means "no preference" — which is a real, common state (nobody has
/// opened settings yet) and resolves down the contract's order rather than
/// being treated as an error.
@MainActor
enum AssistantProviderChoice {
    private static let defaultsKey = "irisAssistantProviderPreference"

    private static var userDefaults: UserDefaults = .standard

    /// Points the store at a scratch `UserDefaults` for tests, and back again.
    static func useForTesting(_ testUserDefaults: UserDefaults) {
        userDefaults = testUserDefaults
    }

    static var current: AssistantProviderPreference? {
        get {
            guard let storedValue = userDefaults.string(forKey: defaultsKey) else { return nil }
            return AssistantProviderPreference(rawValue: storedValue)
        }
        set {
            if let newValue {
                userDefaults.set(newValue.rawValue, forKey: defaultsKey)
            } else {
                userDefaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// Which provider a question would actually go to right now, given what is
    /// set up. Pure, so the panel can render the answer and the tests can assert
    /// it without touching a network or a Keychain.
    ///
    /// Returns nil when nothing can answer — the state that puts the three
    /// options in front of the reader.
    static func resolve(
        preference: AssistantProviderPreference?,
        publikAPIIsReady: Bool,
        anthropicKeyIsSaved: Bool,
        codexIsUsable: Bool
    ) -> AssistantProviderPreference? {
        // An explicit choice is honoured even when it is currently broken: the
        // caller turns that into "here is what broke", not into a silent switch
        // to somebody else's account.
        if let preference { return preference }

        if publikAPIIsReady { return .publikAPI }
        if anthropicKeyIsSaved { return .anthropicKey }
        if codexIsUsable { return .codex }
        return nil
    }

    /// Whether the resolved provider can actually serve a request, so the
    /// composer can say "you can't ask yet" instead of offering a field that
    /// fails on send.
    static func isUsable(
        _ provider: AssistantProviderPreference?,
        publikAPIIsReady: Bool,
        anthropicKeyIsSaved: Bool,
        codexIsUsable: Bool
    ) -> Bool {
        switch provider {
        case .publikAPI: return publikAPIIsReady
        case .anthropicKey: return anthropicKeyIsSaved
        case .codex: return codexIsUsable
        case nil: return false
        }
    }
}
