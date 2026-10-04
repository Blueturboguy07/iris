import Foundation

// Unit m3-guideline47: App Store Guideline 4.7 obligations. Verbatim
// guideline text checked against
// https://developer.apple.com/app-store/review/guidelines/ on 2026-09-27:
//
//   4.7.1 Software offered in apps under this rule must: follow all privacy
//   guidelines ...; include a method for filtering objectionable material,
//   a mechanism to report content and timely responses to concerns, and the
//   ability to block abusive users; and follow Guideline 3.1 ...
//   4.7.4 You must provide an index of software and metadata available in
//   your app. It must include universal links that lead to all of the
//   software offered in your app.
//   4.7.5 Your app must provide a way for users to identify software that
//   exceeds the app's age rating, and use an age restriction mechanism
//   based on verified or declared age to limit access by underage users.
//
// This file provides the per-app privacy/age-rating/contact metadata model
// (4.7.1's privacy half, 4.7.4's per-app metadata, 4.7.5's rating). It
// mirrors mobile-shell/contracts/index.js's AppStoreMetadataV1 exactly and
// is validated independently by Core, never trusted from the wire as-is.
// Review47AgeGate.swift covers 4.7.5's restriction mechanism,
// Review47BlockList.swift covers 4.7.1's "ability to block abusive users",
// and Review47ReportComposer.swift covers 4.7.1's report mechanism.

/// One Guideline 4.7 metadata object for one mini app. Constructing this
/// type always yields an already-validated value: there is no way to hold
/// an invalid `Review47AppStoreMetadata`, so its mere presence on a
/// descriptor (`PublikMobileShellDescriptor.appStoreMetadata != nil`) means
/// it is ready for a 4.7 listing. A descriptor with none is still an
/// ordinary, fully installable v1 descriptor.
public struct Review47AppStoreMetadata: Equatable, Sendable {
    /// Apple App Store Connect's current age rating tiers, confirmed
    /// 2026-09-27 against
    /// https://developer.apple.com/help/app-store-connect/reference/age-ratings/
    /// (4+, 9+, 13+, 16+, 18+; "Unrated" is not publishable on the App
    /// Store). This is Iris's own per-mini-app content rating for 4.7.5,
    /// never a substitute for the Iris Apps shell binary's own App Store
    /// Connect rating.
    public static let knownAgeRatings: Set<Int> = [4, 9, 13, 16, 18]
    /// RC-02 (apple-compliance/REQUIRED_CHANGES.md), decided (not a default
    /// pending an owner answer -- apple-compliance/DECISIONS.md section 1.1,
    /// OD-01): the Iris Apps shell's own App Store Connect age rating.
    /// `Review47AgeGate.decide` gates on this: an app rated at or below it
    /// never needs a declared age at all; only an app rated above it (none
    /// of the three current starters are, today) ever asks.
    public static let shellAgeRating = 13
    public static let maximumPrivacySummaryCharacters = 600
    public static let maximumContactValueCharacters = 320
    public static let maximumURLCharacters = 2048

    public let ageRating: Int
    public let privacySummary: String
    public let privacyPolicyURL: URL
    public let supportContact: Review47ContactMethod
    public let reportContact: Review47ContactMethod

    public init(
        ageRating: Int,
        privacySummary: String,
        privacyPolicyURL: URL,
        supportContact: Review47ContactMethod,
        reportContact: Review47ContactMethod
    ) throws {
        guard Self.knownAgeRatings.contains(ageRating) else {
            throw Review47MetadataError.invalidAgeRating(ageRating)
        }
        guard Self.isValidDisplayString(privacySummary, maxLength: Self.maximumPrivacySummaryCharacters) else {
            throw Review47MetadataError.invalidPrivacySummary
        }
        guard Self.isSafeHTTPSURL(privacyPolicyURL, maxLength: Self.maximumURLCharacters) else {
            throw Review47MetadataError.invalidPrivacyPolicyURL
        }
        self.ageRating = ageRating
        self.privacySummary = privacySummary
        self.privacyPolicyURL = privacyPolicyURL
        self.supportContact = supportContact
        self.reportContact = reportContact
    }

    /// Bounded, control-character-free plain text. Not an HTML sanitizer:
    /// SwiftUI `Text` never interprets its argument as markup, so this only
    /// needs to reject control characters (including newline injection into
    /// a one-line summary) and enforce a length bound, matching the
    /// contracts-layer `isBoundedDisplayString` check exactly in intent.
    static func isValidDisplayString(_ value: String, maxLength: Int) -> Bool {
        guard (1...maxLength).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f }
    }

    /// Requires an exact `https` scheme with no userinfo and rejects raw
    /// `<`, `>`, `"`, `'` characters, so neither a `javascript:`/`data:`
    /// scheme nor an injected-markup query string can pass. Mirrors the
    /// contracts-layer `isHttpsURLString` check.
    ///
    /// Checked on `url.absoluteString`, which is what this codebase already
    /// has once a caller constructs `Review47AppStoreMetadata` directly from
    /// a `URL`. This is a secondary check only: `URL(string:)` itself may
    /// already have percent-encoded a raw `<`, `>`, `"` or `'` on
    /// construction, in which case `isSafeHTTPSURLString` below (checked on
    /// the original untrusted wire string, before it is ever parsed into a
    /// `URL`) is the check that actually rejects the hostile input.
    static func isSafeHTTPSURL(_ url: URL, maxLength: Int) -> Bool {
        isSafeHTTPSURLString(url.absoluteString, maxLength: maxLength)
    }

    /// Same checks as `isSafeHTTPSURL`, applied to the raw string a
    /// descriptor actually carries on the wire, before it is parsed into a
    /// `URL` at all. This is the check that matters for untrusted JSON
    /// input: `URL(string:)`'s own percent-encoding of `<`/`>`/`"`/`'`
    /// during parsing would otherwise let a hostile string slip past a
    /// check performed only on the already-parsed `URL`.
    static func isSafeHTTPSURLString(_ raw: String, maxLength: Int) -> Bool {
        guard raw.utf8.count <= maxLength else { return false }
        guard !raw.unicodeScalars.contains(where: { $0.value <= 0x1f || $0.value == 0x7f }) else { return false }
        guard !raw.contains(where: { "<>\"'".contains($0) }) else { return false }
        guard let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https" && components.user == nil && components.password == nil
    }
}

public enum Review47ContactMethod: Equatable, Sendable {
    case email(String)
    case url(URL)

    public init(kind: String, value: String) throws {
        switch kind {
        case "email":
            guard Self.isValidEmail(value) else { throw Review47MetadataError.invalidContactValue }
            self = .email(value)
        case "url":
            // Checked on the raw string first: URL(string:) may itself
            // percent-encode a raw "<", ">", "\"" or "'" during parsing, so
            // a check performed only on the already-parsed URL would miss it.
            guard Review47AppStoreMetadata.isSafeHTTPSURLString(value, maxLength: Review47AppStoreMetadata.maximumURLCharacters),
                  let url = URL(string: value) else {
                throw Review47MetadataError.invalidContactValue
            }
            self = .url(url)
        default:
            throw Review47MetadataError.invalidContactKind(kind)
        }
    }

    /// Not a claim of exhaustive RFC 5322 validity: a bounded sanity check,
    /// on the exact same character classes as contracts/index.js's own
    /// EMAIL_PATTERN (quoted below), not a separately hand-rolled rule.
    ///
    /// Fixed during independent verification of unit m3-guideline47: the
    /// previous ad hoc version here rejected a local part containing `'`
    /// (for example "o'brien@publikhq.com"), a real, RFC 5322-valid address
    /// character that contracts/index.js's own EMAIL_PATTERN, and therefore
    /// publisher/cli.mjs's own `approve` flags, already accept. That made a
    /// publisher-approved, guideline-compliant descriptor fail to parse here
    /// at all (Review47CatalogDescriptorTests's own
    /// "testHostileAppStoreMetadataFieldsAreRejectedBeforeAnyDescriptorIsReturned"
    /// shows any such rejection takes the whole mobileShell descriptor down,
    /// not merely "not listing ready"), and separately accepted a domain
    /// label starting with a hyphen ("person@-example.com") that
    /// contracts/index.js's own pattern rejects. Regression test:
    /// Review47ContactEmailConsistencyTests.swift.
    static let emailPattern: NSRegularExpression = {
        // contracts/index.js:
        //   const EMAIL_PATTERN = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]
        //     (?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9]
        //     (?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/
        try! NSRegularExpression(
            pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
        )
    }()

    static func isValidEmail(_ value: String) -> Bool {
        guard Review47AppStoreMetadata.isValidDisplayString(value, maxLength: Review47AppStoreMetadata.maximumContactValueCharacters) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Self.emailPattern.firstMatch(in: value, options: [], range: range) != nil
    }
}

public enum Review47MetadataError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidKind(String)
    case invalidVersion(Int)
    case invalidAgeRating(Int)
    case invalidPrivacySummary
    case invalidPrivacyPolicyURL
    case invalidContactKind(String)
    case invalidContactValue

    public var description: String {
        switch self {
        case .invalidKind(let kind): return "Guideline 4.7 metadata has an unsupported kind: \(kind)."
        case .invalidVersion(let version): return "Guideline 4.7 metadata has an unsupported version: \(version)."
        case .invalidAgeRating(let ageRating): return "Guideline 4.7 metadata has an unsupported age rating: \(ageRating)."
        case .invalidPrivacySummary: return "Guideline 4.7 metadata's privacy summary is invalid."
        case .invalidPrivacyPolicyURL: return "Guideline 4.7 metadata's privacy policy URL is invalid."
        case .invalidContactKind(let kind): return "Guideline 4.7 metadata has an unsupported contact kind: \(kind)."
        case .invalidContactValue: return "Guideline 4.7 metadata has an invalid contact value."
        }
    }
}

// --- Wire decode (from the mobile-shell descriptor's optional appStoreMetadata) ---

struct Review47ContactMethodWire: Decodable {
    let kind: String
    let value: String
}

struct Review47AppStoreMetadataWire: Decodable {
    static let expectedKind = "iris.mobile-shell.app-store-metadata"
    static let expectedVersion = 1

    let kind: String
    let version: Int
    let ageRating: Int
    let privacySummary: String
    let privacyPolicyURL: String
    let supportContact: Review47ContactMethodWire
    let reportContact: Review47ContactMethodWire

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case ageRating
        case privacySummary
        case privacyPolicyURL = "privacyPolicyUrl"
        case supportContact
        case reportContact
    }
}

extension Review47AppStoreMetadata {
    init(wire: Review47AppStoreMetadataWire) throws {
        guard wire.kind == Review47AppStoreMetadataWire.expectedKind else {
            throw Review47MetadataError.invalidKind(wire.kind)
        }
        guard wire.version == Review47AppStoreMetadataWire.expectedVersion else {
            throw Review47MetadataError.invalidVersion(wire.version)
        }
        // Checked on the raw wire string first, before URL(string:) can
        // percent-encode away a raw "<", ">", "\"" or "'".
        guard Review47AppStoreMetadata.isSafeHTTPSURLString(wire.privacyPolicyURL, maxLength: Review47AppStoreMetadata.maximumURLCharacters),
              let policyURL = URL(string: wire.privacyPolicyURL) else {
            throw Review47MetadataError.invalidPrivacyPolicyURL
        }
        let support = try Review47ContactMethod(kind: wire.supportContact.kind, value: wire.supportContact.value)
        let report = try Review47ContactMethod(kind: wire.reportContact.kind, value: wire.reportContact.value)
        try self.init(
            ageRating: wire.ageRating,
            privacySummary: wire.privacySummary,
            privacyPolicyURL: policyURL,
            supportContact: support,
            reportContact: report
        )
    }
}
