//
//  MaintainFeatureRequests.swift
//  leanring-buddy
//
//  The feature half of maintain mode. Bugs are found by watching; features
//  are found by LISTENING — the highest-signal, lowest-cost trigger is the
//  user simply saying what they wish an app did, while that app is in front.
//
//  This file does two small, honest things:
//    - recognizes a wish in a chat message ("I wish cue could…", "it should
//      really…", "why can't this…") and pools it as a demand signal, keyed
//      to a normalized signature so the same wish from many people adds up.
//    - answers "what do people most want for this app" from the pool, so Iris
//      can proactively suggest a top request — but only at k>=5, enforced
//      server-side, so a suggestion is never one person's wish echoed back.
//
//  It never implements anything itself: a wish the user asks Iris to build
//  runs through the SAME Tier C harness a novel fix does — jailed, bounded,
//  verified, forked. This file only turns talk into a pooled, ranked signal.
//

import CryptoKit
import Foundation

/// One pooled feature request, as the intake normalized it.
struct PooledFeatureRequest: Sendable, Equatable {
    let request: String
    let installs: Int
    let implementedCount: Int
}

@MainActor
final class MaintainFeatureRequests {

    private let publikBaseURL: URL
    private let installIdentity: MaintainInstallIdentity
    private let urlSession: URLSession

    init(
        publikBaseURL: URL = AssistantTransport.configuredPublikBaseURL(),
        installIdentity: MaintainInstallIdentity,
        urlSession: URLSession = .shared
    ) {
        self.publikBaseURL = publikBaseURL
        self.installIdentity = installIdentity
        self.urlSession = urlSession
    }

    // MARK: - Recognizing a wish

    /// Phrasings that mark a message as a feature wish rather than a question
    /// or a bug report. Deliberately conservative — a false positive pools
    /// noise, and the user is never interrupted by this, only offered.
    nonisolated private static let wishPatterns = [
        #"(?i)\bi wish (it|this|the app|\w+) (could|would|had)\b"#,
        #"(?i)\bit should (really )?(be able to|have|let me|support)\b"#,
        #"(?i)\bwhy (can't|cant|doesn't|doesnt) (it|this|the app)\b"#,
        #"(?i)\bcan (it|this|you) (add|support|do)\b"#,
        #"(?i)\bwould be (great|nice|amazing) if\b"#,
        #"(?i)\b(please )?add (a|an|support for)\b"#,
        #"(?i)\bfeature request\b"#,
    ]

    /// True when a message reads like a feature wish about the app in front.
    nonisolated static func messageLooksLikeAFeatureWish(_ message: String) -> Bool {
        wishPatterns.contains {
            message.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Normalizes a wish to its identity: lowercased, stripped of the wish
    /// framing and punctuation, so "I wish it could export to PDF" and
    /// "please add PDF export" pool near each other. Reuses the break
    /// message normalizer for the PII/path/number stripping.
    nonisolated static func normalizedRequest(from message: String) -> String {
        var text = BreakSignatureService.normalizeMessage(message)
        for framing in [
            "i wish it could ", "i wish this could ", "i wish the app could ",
            "it should really ", "it should ", "would be great if ",
            "would be nice if ", "please add ", "add support for ", "add a ", "add an ",
            "can you add ", "why can't it ", "why cant it ",
        ] {
            if text.hasPrefix(framing) { text = String(text.dropFirst(framing.count)); break }
        }
        return String(text.prefix(300)).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func signature(appSlug: String, normalizedRequest: String) -> String {
        let composite = "\(appSlug)|feature|\(normalizedRequest)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }

    // MARK: - Pooling

    /// Files a wish to the demand pool. Fire and forget — a lost request
    /// costs the pool one signal, nothing more. Returns the normalized text
    /// so the caller can acknowledge it ("noted — I'll add your voice to the
    /// N people who want that").
    @discardableResult
    func poolWish(_ message: String, forAppSlug appSlug: String) async -> String? {
        let normalized = Self.normalizedRequest(from: message)
        guard !normalized.isEmpty else { return nil }
        let signature = Self.signature(appSlug: appSlug, normalizedRequest: normalized)

        let url = publikBaseURL.appendingPathComponent("api/iris/feature-requests")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appSlug": appSlug,
            "signature": signature,
            "request": normalized,
            "installId": installIdentity.currentInstallId.uuidString.lowercased(),
        ])
        _ = try? await urlSession.data(for: request)
        irisTrace("maintain: pooled a feature wish for \(appSlug)")
        return normalized
    }

    /// The top requests for an app, k>=5-gated server-side. For a proactive
    /// "most people who run this also wanted…" suggestion.
    func topRequests(forAppSlug appSlug: String) async -> [PooledFeatureRequest] {
        var components = URLComponents(
            url: publikBaseURL.appendingPathComponent("api/iris/feature-requests"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "app", value: appSlug)]
        guard let url = components?.url else { return [] }
        guard let (data, response) = try? await urlSession.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        struct Payload: Codable {
            struct Row: Codable {
                let request: String
                let installs: Int
                let implementedCount: Int
            }
            let requests: [Row]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.requests.map {
            PooledFeatureRequest(request: $0.request, installs: $0.installs, implementedCount: $0.implementedCount)
        }
    }
}
