import Foundation

public enum NativeWebsiteInstallIntentError: Error, Equatable, Sendable, CustomStringConvertible {
    case nonCanonicalURL
    case invalidSlug

    public var description: String {
        switch self {
        case .nonCanonicalURL:
            return "The website install link is not a canonical Iris app intent."
        case .invalidSlug:
            return "The website install link contains an invalid app slug."
        }
    }
}

/// A website listing or handoff link is only an untrusted request to look up one exact Publik slug.
/// It never carries a package URL, credential, approval, identity, or capability.
public struct NativeWebsiteInstallIntent: Equatable, Sendable {
    public let slug: String

    public init(slug: String) throws {
        guard NativeSecurity.isStableId(slug) else {
            throw NativeWebsiteInstallIntentError.invalidSlug
        }
        self.slug = slug
    }

    public static func parse(_ url: URL) throws -> NativeWebsiteInstallIntent {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.fragment == nil else {
            throw NativeWebsiteInstallIntentError.nonCanonicalURL
        }

        let encodedPath = components.percentEncodedPath
        let slug: String
        if components.scheme == "https", components.host == "publikhq.com" {
            // Accept the app page people can actually share today, without
            // requiring a new website route. Both forms remain slug-only;
            // the catalog and verified package still decide install authority.
            let handoffPrefix = "/iris/apps/"
            let prefix = encodedPath.hasPrefix(handoffPrefix) ? handoffPrefix : "/"
            guard encodedPath.hasPrefix(prefix) else {
                throw NativeWebsiteInstallIntentError.nonCanonicalURL
            }
            slug = String(encodedPath.dropFirst(prefix.count))
            guard !slug.isEmpty, !slug.contains("/"), encodedPath == prefix + slug else {
                throw NativeWebsiteInstallIntentError.nonCanonicalURL
            }
        } else if components.scheme == "iris-apps", components.host == "install" {
            guard encodedPath.hasPrefix("/") else {
                throw NativeWebsiteInstallIntentError.nonCanonicalURL
            }
            slug = String(encodedPath.dropFirst())
            guard !slug.isEmpty, encodedPath == "/" + slug else {
                throw NativeWebsiteInstallIntentError.nonCanonicalURL
            }
        } else {
            throw NativeWebsiteInstallIntentError.nonCanonicalURL
        }

        // Stable ids exclude percent escapes, slashes, dot traversal and other
        // syntax that could turn the slug intent into a second URL/path channel.
        return try NativeWebsiteInstallIntent(slug: slug)
    }
}
