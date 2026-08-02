//
//  DeepLinkParser.swift
//  leanring-buddy
//
//  Parses the `iris://` links the publik website hands off to this app.
//  Ported from the Tauri shell's `parse_guide_deep_link`, `valid_slug`, and
//  `valid_branch_key` in `iris-desktop/src-tauri/src/main.rs` (lines 188-285),
//  which remains the behavioral spec for every rule in this file.
//

import Foundation

/// A handoff from the website. `branchKey` and `stepIndex` are what make it a
/// handoff rather than a bookmark: without them the app reopens the guide at
/// step one, on whichever branch it happened to use last, which for a mobile
/// guide is frequently the wrong phone entirely.
struct GuideDeepLink: Equatable, Sendable {
    let slug: String
    let version: UInt32
    /// `computer:phone` exactly as `lib/iris-guides.ts` writes it, e.g. `macos:ios`.
    let branchKey: String?
    let stepIndex: UInt32?
}

/// The OAuth redirect the website sends back after the user signs in. This form
/// does not exist in the Tauri shell; it is the one addition the Swift app makes,
/// and it keeps the same strict posture as the guide form.
struct AuthCallbackDeepLink: Equatable, Sendable {
    let authorizationCode: String
    let opaqueStateToken: String
}

/// Exactly the two link shapes Iris answers to. Anything else is rejected before
/// any of it is applied, so a malformed link can never partially take effect.
enum IrisDeepLink: Equatable, Sendable {
    case guide(GuideDeepLink)
    case authCallback(AuthCallbackDeepLink)
}

/// The reasons a link is turned away. The Rust shell emits these as a plain
/// string on `iris-deep-link-rejected`; `rejectionMessage` reproduces that text
/// so the two apps explain a refusal identically.
enum IrisDeepLinkRejection: Error, Equatable, Sendable {
    case unsupportedIrisLink
    case missingGuideSlug
    case guideLinksRequireExactlyOneSlug
    case invalidGuideSlug
    case duplicateVersionParameter
    case invalidGuideVersion
    case missingGuideVersion
    case duplicateBranchParameter
    case invalidGuideBranch
    case duplicateStepParameter
    case invalidGuideStep
    case unsupportedGuideParameter
    case duplicateAuthCallbackParameter
    case missingAuthCallbackParameter
    case invalidAuthCallbackValue
    case unsupportedAuthCallbackParameter

    var rejectionMessage: String {
        switch self {
        case .unsupportedIrisLink:
            return "unsupported Iris link"
        case .missingGuideSlug:
            return "missing guide slug"
        case .guideLinksRequireExactlyOneSlug:
            return "Iris guide links require exactly one slug"
        case .invalidGuideSlug:
            return "invalid Iris guide slug"
        case .duplicateVersionParameter:
            return "Iris guide links accept only one version parameter"
        case .invalidGuideVersion:
            return "invalid Iris guide version"
        case .missingGuideVersion:
            return "missing Iris guide version"
        case .duplicateBranchParameter:
            return "Iris guide links accept only one branch parameter"
        case .invalidGuideBranch:
            return "invalid Iris guide branch"
        case .duplicateStepParameter:
            return "Iris guide links accept only one step parameter"
        case .invalidGuideStep:
            return "invalid Iris guide step"
        case .unsupportedGuideParameter:
            return "unsupported Iris guide parameter"
        case .duplicateAuthCallbackParameter:
            return "Iris sign-in links accept each parameter only once"
        case .missingAuthCallbackParameter:
            return "incomplete Iris sign-in link"
        case .invalidAuthCallbackValue:
            return "invalid Iris sign-in value"
        case .unsupportedAuthCallbackParameter:
            return "unsupported Iris sign-in parameter"
        }
    }
}

enum IrisDeepLinkParser {
    /// The URL scheme registered to this app.
    static let irisURLScheme = "iris"

    /// `iris://guide/<slug>?version=<n>` — the guide handoff host.
    private static let guideHost = "guide"

    /// `iris://auth/callback?code=<...>&state=<...>` — the OAuth redirect host.
    private static let authHost = "auth"
    private static let authCallbackPathSegment = "callback"

    /// A slug is at most this many UTF-8 bytes, matching `valid_slug` in main.rs.
    private static let maximumSlugByteCount = 64

    /// The web panel can be many steps ahead, but nothing sane is past a
    /// hundred; the UI clamps to the guide's real step count anyway.
    private static let maximumStepIndex: UInt32 = 500

    /// An authorization code or state token longer than this is not something
    /// the publik sign-in flow produces. The Rust shell bounds untrusted link
    /// text the same way (see the 512-character fragment cap in `open_external`).
    private static let maximumAuthCallbackValueLength = 512

    static func parse(_ deepLinkString: String) -> Result<IrisDeepLink, IrisDeepLinkRejection> {
        guard let deepLinkURL = URL(string: deepLinkString) else {
            return .failure(.unsupportedIrisLink)
        }
        return parse(deepLinkURL)
    }

    static func parse(_ deepLinkURL: URL) -> Result<IrisDeepLink, IrisDeepLinkRejection> {
        guard let urlComponents = URLComponents(url: deepLinkURL, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedIrisLink)
        }

        // Every one of these is a rejection in main.rs before the path is even
        // looked at: a port, credentials, or a fragment on an `iris://` link is
        // never something the website produces.
        guard urlComponents.scheme == irisURLScheme,
              urlComponents.port == nil,
              urlComponents.user == nil || urlComponents.user?.isEmpty == true,
              urlComponents.password == nil,
              urlComponents.fragment == nil else {
            return .failure(.unsupportedIrisLink)
        }

        // The host is compared exactly rather than case-insensitively because
        // `iris` is not a special scheme, so neither the Rust url crate nor
        // Foundation normalizes the case of the host for us.
        switch urlComponents.host {
        case guideHost:
            return parseGuideDeepLink(from: urlComponents)
        case authHost:
            return parseAuthCallbackDeepLink(from: urlComponents)
        default:
            return .failure(.unsupportedIrisLink)
        }
    }

    // MARK: - Guide links

    private static func parseGuideDeepLink(
        from urlComponents: URLComponents
    ) -> Result<IrisDeepLink, IrisDeepLinkRejection> {
        let pathSegments = nonEmptyPathSegments(of: urlComponents)
        guard !pathSegments.isEmpty else {
            return .failure(.missingGuideSlug)
        }
        guard pathSegments.count == 1 else {
            return .failure(.guideLinksRequireExactlyOneSlug)
        }

        let slug = pathSegments[0]
        guard isValidGuideSlug(slug) else {
            return .failure(.invalidGuideSlug)
        }

        // Every parameter is named, known, and allowed at most once. Anything
        // else is rejected outright rather than ignored, so a crafted link
        // cannot smuggle in a field a later version of the app might read.
        var version: UInt32?
        var branchKey: String?
        var stepIndex: UInt32?

        for queryParameter in meaningfulQueryParameters(of: urlComponents) {
            switch queryParameter.name {
            case "version":
                guard version == nil else {
                    return .failure(.duplicateVersionParameter)
                }
                guard let parsedVersion = UInt32(queryParameter.value), parsedVersion != 0 else {
                    return .failure(.invalidGuideVersion)
                }
                version = parsedVersion
            case "branch":
                guard branchKey == nil else {
                    return .failure(.duplicateBranchParameter)
                }
                guard isValidBranchKey(queryParameter.value) else {
                    return .failure(.invalidGuideBranch)
                }
                branchKey = queryParameter.value
            case "step":
                guard stepIndex == nil else {
                    return .failure(.duplicateStepParameter)
                }
                guard let parsedStepIndex = UInt32(queryParameter.value),
                      parsedStepIndex <= maximumStepIndex else {
                    return .failure(.invalidGuideStep)
                }
                stepIndex = parsedStepIndex
            default:
                return .failure(.unsupportedGuideParameter)
            }
        }

        guard let resolvedVersion = version else {
            return .failure(.missingGuideVersion)
        }

        // Note that main.rs deliberately accepts a step without a branch: the
        // step is validated against the guide's real branch on arrival, so a
        // lone step is a harmless hint rather than something to refuse here.
        return .success(.guide(GuideDeepLink(
            slug: slug,
            version: resolvedVersion,
            branchKey: branchKey,
            stepIndex: stepIndex
        )))
    }

    // MARK: - Sign-in callback links

    private static func parseAuthCallbackDeepLink(
        from urlComponents: URLComponents
    ) -> Result<IrisDeepLink, IrisDeepLinkRejection> {
        let pathSegments = nonEmptyPathSegments(of: urlComponents)
        guard pathSegments.count == 1, pathSegments[0] == authCallbackPathSegment else {
            return .failure(.unsupportedIrisLink)
        }

        var authorizationCode: String?
        var opaqueStateToken: String?

        for queryParameter in meaningfulQueryParameters(of: urlComponents) {
            switch queryParameter.name {
            case "code":
                guard authorizationCode == nil else {
                    return .failure(.duplicateAuthCallbackParameter)
                }
                guard isValidAuthCallbackValue(queryParameter.value) else {
                    return .failure(.invalidAuthCallbackValue)
                }
                authorizationCode = queryParameter.value
            case "state":
                guard opaqueStateToken == nil else {
                    return .failure(.duplicateAuthCallbackParameter)
                }
                guard isValidAuthCallbackValue(queryParameter.value) else {
                    return .failure(.invalidAuthCallbackValue)
                }
                opaqueStateToken = queryParameter.value
            default:
                return .failure(.unsupportedAuthCallbackParameter)
            }
        }

        // A code without its state is exactly the shape a CSRF attempt takes, so
        // both have to be present before any of the link is applied.
        guard let resolvedAuthorizationCode = authorizationCode,
              let resolvedOpaqueStateToken = opaqueStateToken else {
            return .failure(.missingAuthCallbackParameter)
        }

        return .success(.authCallback(AuthCallbackDeepLink(
            authorizationCode: resolvedAuthorizationCode,
            opaqueStateToken: resolvedOpaqueStateToken
        )))
    }

    // MARK: - Shared validation

    /// Ported verbatim from `valid_slug` (main.rs:276-285). The first and last
    /// byte are checked for being alphanumeric *and* every byte for being
    /// lowercase-or-digit-or-hyphen, which together mean a slug can neither
    /// start nor end with a hyphen and can never contain an uppercase letter.
    /// `GuideService` reuses this so a fetched slug is held to the same rule.
    static func isValidGuideSlug(_ slug: String) -> Bool {
        let slugBytes = Array(slug.utf8)
        guard !slugBytes.isEmpty, slugBytes.count <= maximumSlugByteCount else {
            return false
        }
        guard let firstByte = slugBytes.first, let lastByte = slugBytes.last else {
            return false
        }
        guard isASCIIAlphanumeric(firstByte), isASCIIAlphanumeric(lastByte) else {
            return false
        }
        return slugBytes.allSatisfy { byte in
            isASCIILowercaseLetter(byte) || isASCIIDigit(byte) || byte == UInt8(ascii: "-")
        }
    }

    /// Ported from `valid_branch_key` (main.rs:269-274). The value has to be
    /// `computer:phone` exactly as the guide library writes it, so this app
    /// selects the same branch the reader was already following.
    static func isValidBranchKey(_ branchKey: String) -> Bool {
        guard let firstColonIndex = branchKey.firstIndex(of: ":") else {
            return false
        }
        let platform = String(branchKey[branchKey.startIndex..<firstColonIndex])
        let target = String(branchKey[branchKey.index(after: firstColonIndex)...])
        let allowedPlatforms = ["macos", "windows"]
        let allowedTargets = ["ios", "android", "desktop"]
        return allowedPlatforms.contains(platform) && allowedTargets.contains(target)
    }

    private static func isValidAuthCallbackValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumAuthCallbackValueLength else {
            return false
        }
        // Control characters have no business in an authorization code and are
        // the usual way a crafted link tries to break out of a log line.
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    // MARK: - URL component helpers

    /// The percent-encoded path is used on purpose: the Rust url crate hands
    /// `path_segments` back without decoding, so a slug written as `cue%2Fextra`
    /// stays one segment there and is refused for containing `%` rather than
    /// silently splitting into two segments here.
    private static func nonEmptyPathSegments(of urlComponents: URLComponents) -> [String] {
        urlComponents.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Query parameters with their values decoded, skipping the wholly empty
    /// segments that a trailing `&` produces. The Rust `query_pairs` iterator
    /// skips those too, so `?version=1&` is one parameter on both sides.
    private static func meaningfulQueryParameters(
        of urlComponents: URLComponents
    ) -> [(name: String, value: String)] {
        guard let queryItems = urlComponents.queryItems else {
            return []
        }
        return queryItems.compactMap { queryItem in
            if queryItem.name.isEmpty && queryItem.value == nil {
                return nil
            }
            return (name: queryItem.name, value: queryItem.value ?? "")
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte)
            || isASCIILowercaseLetter(byte)
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isASCIILowercaseLetter(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
