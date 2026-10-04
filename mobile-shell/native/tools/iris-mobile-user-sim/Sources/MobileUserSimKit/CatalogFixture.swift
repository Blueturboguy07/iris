import Foundation

/// Builds the catalog envelope JSON that `PublikMobileCatalogClient.fetchCatalog()`
/// decodes for real, and the per-app `mobileShell` descriptor block it
/// validates for real. Every field name mirrors
/// `PublikMobileCatalogAppWire` / `PublikMobileShellDescriptorWire`
/// (mobile-shell/native/Sources/IrisMobileShellCore/PublikMobileModels.swift)
/// exactly; nothing here is decoded by a stub, only produced by one.
public struct CatalogFixtureApp: Sendable {
    public let slug: String
    public let name: String
    public let package: GeneratedPackage
    public let downloadURL: URL

    public init(slug: String, name: String, package: GeneratedPackage, downloadURL: URL) {
        self.slug = slug
        self.name = name
        self.package = package
        self.downloadURL = downloadURL
    }
}

public enum CatalogFixture {
    /// A collision-free, real `https://publikhq.com/...` URL for one
    /// package's raw bytes. `PublikMobileCatalogClient` only accepts exact
    /// `publikhq.com` origins with no port/user/password/fragment
    /// (`isAllowedPublikURL`), so this must stay a plain path.
    public static func downloadURL(slug: String, revisionId: String) -> URL {
        let digest = revisionId
            .split(separator: ":")
            .last
            .map(String.init) ?? revisionId
        return URL(string: "https://publikhq.com/api/iris/mobile-shell/\(slug)/\(digest).json")!
    }

    public static func envelope(apps: [CatalogFixtureApp]) -> Data {
        let appsJSON: [[String: Any]] = apps.map { app in
            [
                "slug": app.slug,
                "name": app.name,
                "guideSlug": NSNull(),
                "macBundleId": NSNull(),
                "latestReleaseTag": NSNull(),
                "mobileShell": [
                    "version": 1,
                    "platform": "ios",
                    "packageFormat": "iris.mobile-shell.package+json",
                    "downloadUrl": app.downloadURL.absoluteString,
                    "mediaType": "application/json",
                    "byteCount": app.package.bytes.count,
                    "packageSha256": app.package.packageSHA256,
                    "appId": app.package.appId,
                    "projectId": app.package.projectId,
                    "baseRevisionId": NSNull(),
                    "revisionId": app.package.revisionId,
                    "contentHash": app.package.contentHash,
                ],
            ]
        }
        let root: [String: Any] = ["apps": appsJSON]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Same shape as `envelope`, but lets a scenario set `baseRevisionId`
    /// explicitly (needed for an update descriptor whose base is the app's
    /// previously installed revision).
    public static func envelope(apps: [(app: CatalogFixtureApp, baseRevisionId: String?)]) -> Data {
        let appsJSON: [[String: Any]] = apps.map { entry in
            [
                "slug": entry.app.slug,
                "name": entry.app.name,
                "guideSlug": NSNull(),
                "macBundleId": NSNull(),
                "latestReleaseTag": NSNull(),
                "mobileShell": [
                    "version": 1,
                    "platform": "ios",
                    "packageFormat": "iris.mobile-shell.package+json",
                    "downloadUrl": entry.app.downloadURL.absoluteString,
                    "mediaType": "application/json",
                    "byteCount": entry.app.package.bytes.count,
                    "packageSha256": entry.app.package.packageSHA256,
                    "appId": entry.app.package.appId,
                    "projectId": entry.app.package.projectId,
                    "baseRevisionId": jsonNullable(entry.baseRevisionId),
                    "revisionId": entry.app.package.revisionId,
                    "contentHash": entry.app.package.contentHash,
                ],
            ]
        }
        let root: [String: Any] = ["apps": appsJSON]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func jsonNullable(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }
}
