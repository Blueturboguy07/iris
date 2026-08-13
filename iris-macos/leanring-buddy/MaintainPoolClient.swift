//
//  MaintainPoolClient.swift
//  leanring-buddy
//
//  The desktop's window onto the recipe pool: one GET that must answer
//  before any token is spent, one POST that files what a user confirmed.
//
//  Both speak to publik's routing API only — the same base URL every other
//  publik call uses. No credentials ride along: the recipe cache is
//  public-read by design (it is edge-cached), and the intake is
//  rate-limited server-side. The BYO Anthropic key never appears here, or
//  anywhere near here.
//

import Foundation

/// One pooled recipe, as the read route returns it. Field names mirror the
/// route's JSON so the decoder stays boring.
struct PooledFixRecipe: Codable, Sendable {
    let id: String
    let recipeType: String
    let modelTier: String
    let status: String
    let diagnosis: String?
    let patchSpecific: String?
    let patchBaseSha: String?
    let patchFormat: String
    let applicability: [String: AnyDecodableJSON]?
    let reviewStatus: String
    let verifiedFixes: Int
    let cleanApplies: Int
    let distinctInstallsAttempted: Int
    let score: Double
    /// The guide-steps rendering, passed through opaque — the replay engine
    /// hands it to the same renderer guide steps use.
    let recipe: AnyDecodableJSON
}

struct RecipeCacheAnswer: Sendable {
    let recipes: [PooledFixRecipe]
    /// Which tier matched: "signature", "fingerprint_strict",
    /// "fingerprint_loose", or nil for a clean miss.
    let matchedBy: String?
}

/// What the intake needs to know about a confirmed break. Assembled by the
/// incident coordinator from a BreakSignature; only structural fields — the
/// scrub pipeline ran before anything landed here.
struct ConfirmedBreakFiling: Sendable {
    let signature: BreakSignature
    let title: String
    let appVersion: String?
}

enum MaintainPoolClientError: Error {
    case badResponse
    case rateLimited(retryAfterSeconds: Int?)
}

@MainActor
final class MaintainPoolClient {

    private let publikBaseURL: URL
    private let urlSession: URLSession

    init(
        publikBaseURL: URL = AssistantTransport.configuredPublikBaseURL(),
        urlSession: URLSession = .shared
    ) {
        self.publikBaseURL = publikBaseURL
        self.urlSession = urlSession
    }

    /// The cache lookup — step one of every incident, zero tokens. A network
    /// failure returns an empty answer rather than throwing: the ladder
    /// treats "could not check the pool" exactly like "pool had nothing",
    /// because both mean the same next step.
    func lookupRecipes(for signature: BreakSignature) async -> RecipeCacheAnswer {
        var components = URLComponents(
            url: publikBaseURL.appendingPathComponent("api/iris/recipes"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "app", value: signature.appSlug),
            URLQueryItem(name: "signature", value: signature.signatureId),
            URLQueryItem(name: "fs", value: signature.fingerprintStrict),
            URLQueryItem(name: "fl", value: signature.fingerprintLoose),
        ]
        guard let url = components?.url else { return RecipeCacheAnswer(recipes: [], matchedBy: nil) }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return RecipeCacheAnswer(recipes: [], matchedBy: nil)
            }
            struct Payload: Codable {
                let recipes: [PooledFixRecipe]
                let matchedBy: String?
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return RecipeCacheAnswer(recipes: payload.recipes, matchedBy: payload.matchedBy)
        } catch {
            irisTrace("maintain: recipe lookup failed (\(error.localizedDescription)) — treating as miss")
            return RecipeCacheAnswer(recipes: [], matchedBy: nil)
        }
    }

    /// Records a recipe outcome with this install's pseudonymous id — the
    /// signal that promotes recipes across DISTINCT machines. Fire and
    /// forget: an outcome that never lands costs the pool one data point,
    /// not the user anything.
    func fileRecipeOutcome(recipeId: String, succeeded: Bool, installId: UUID) async {
        let url = publikBaseURL
            .appendingPathComponent("api/iris/recipes")
            .appendingPathComponent(recipeId)
            .appendingPathComponent("outcome")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "succeeded": succeeded,
            "installId": installId.uuidString.lowercased(),
        ] as [String: Any])
        _ = try? await urlSession.data(for: request)
    }

    /// Files a confirmed break. Returns the created break id, or nil when the
    /// intake refused or the network failed — the caller stages locally and
    /// retries on the next incident rather than looping here.
    func fileConfirmedBreak(_ filing: ConfirmedBreakFiling) async -> String? {
        let url = publikBaseURL.appendingPathComponent("api/iris/breaks")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "appSlug": filing.signature.appSlug,
            "signature": filing.signature.signatureId,
            "appStack": filing.signature.appStack.rawValue,
            "signatureKind": filing.signature.kind.rawValue,
            "algoVersion": filing.signature.algoVersion,
            "fingerprintStrict": filing.signature.fingerprintStrict,
            "fingerprintLoose": filing.signature.fingerprintLoose,
            "title": filing.title,
            "protoSignature": filing.signature.protoSignature,
            "topFrames": filing.signature.topFrames.map { frame in
                [
                    "module": frame.module,
                    "function": frame.function,
                    "file": frame.sourceFile ?? "",
                    "is_app_frame": frame.isApplicationFrame,
                ] as [String: Any]
            },
        ]
        if let appVersion = filing.appVersion { body["appVersion"] = appVersion }

        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = encoded

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                irisTrace("maintain: break filing got HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            struct Created: Codable { let breakId: String }
            return (try? JSONDecoder().decode(Created.self, from: data))?.breakId
        } catch {
            irisTrace("maintain: break filing failed (\(error.localizedDescription))")
            return nil
        }
    }
}

/// A JSON value the client passes through without caring what is inside —
/// the recipe body belongs to the renderer, not to this transport.
struct AnyDecodableJSON: Codable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        // Re-encode whatever is there to a canonical string; consumers that
        // need structure parse it themselves. Keeps this type Sendable and
        // Equatable-friendly without an any-typed payload.
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(RawJSONBox.self) {
            value = raw.stringified
        } else {
            value = "null"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(RawJSONBox(stringified: value))
    }
}

/// Decodes any JSON shape into a stringified form, one layer of plumbing the
/// standard library refuses to provide.
private struct RawJSONBox: Codable {
    let stringified: String

    init(stringified: String) { self.stringified = stringified }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringified = "\"\(string)\""
        } else if let number = try? container.decode(Double.self) {
            stringified = "\(number)"
        } else if let boolean = try? container.decode(Bool.self) {
            stringified = "\(boolean)"
        } else if let object = try? container.decode([String: RawJSONBox].self) {
            let inner = object.map { "\"\($0.key)\":\($0.value.stringified)" }
                .sorted().joined(separator: ",")
            stringified = "{\(inner)}"
        } else if let array = try? container.decode([RawJSONBox].self) {
            stringified = "[\(array.map(\.stringified).joined(separator: ","))]"
        } else {
            stringified = "null"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringified)
    }
}
