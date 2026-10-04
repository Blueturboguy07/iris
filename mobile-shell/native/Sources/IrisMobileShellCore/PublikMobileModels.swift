import Foundation

public struct PublikMobileCatalogApp: Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String
    public let guideSlug: String?
    public let macBundleId: String?
    public let latestReleaseTag: String?
    public let mobileShell: PublikMobileShellDescriptor?

    public var id: String { slug }
}

public struct PublikMobileShellDescriptor: Equatable, Sendable {
    public let version: Int
    public let platform: String
    public let packageFormat: String
    public let downloadURL: URL
    public let mediaType: String
    public let byteCount: Int
    public let packageSHA256: String
    public let appId: String
    public let projectId: String
    public let baseRevisionId: String?
    public let revisionId: String
    public let contentHash: String
    /// Guideline 4.7 metadata (age rating, privacy, support/report contact).
    /// nil on an older descriptor that predates unit m3-guideline47; such a
    /// descriptor still installs normally (see `isReadyForAppStoreListing`).
    public let appStoreMetadata: Review47AppStoreMetadata?

    public init(
        version: Int,
        platform: String,
        packageFormat: String,
        downloadURL: URL,
        mediaType: String,
        byteCount: Int,
        packageSHA256: String,
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        revisionId: String,
        contentHash: String,
        appStoreMetadata: Review47AppStoreMetadata? = nil
    ) {
        self.version = version
        self.platform = platform
        self.packageFormat = packageFormat
        self.downloadURL = downloadURL
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.packageSHA256 = packageSHA256
        self.appId = appId
        self.projectId = projectId
        self.baseRevisionId = baseRevisionId
        self.revisionId = revisionId
        self.contentHash = contentHash
        self.appStoreMetadata = appStoreMetadata
    }

    public var identity: NativeShellAppIdentity {
        NativeShellAppIdentity(appId: appId, projectId: projectId)
    }

    /// True only when this descriptor carries Guideline 4.7 metadata. Since
    /// `Review47AppStoreMetadata` cannot be constructed in an invalid state,
    /// presence alone is sufficient here (unlike the JS/website layers,
    /// which re-validate an untyped JSON value).
    public var isReadyForAppStoreListing: Bool {
        appStoreMetadata != nil
    }
}

public struct PublikMobileDownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int
    public let expectedBytes: Int

    public init(receivedBytes: Int, expectedBytes: Int) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

public struct PublikMobileDownloadedPackage: Equatable, Sendable {
    public let catalogSlug: String
    public let identity: NativeShellAppIdentity
    public let packageBytes: Data
    public let inspection: DeliveryPackageInspection
}

public enum PublikMobileDownloadError: Error, Equatable, Sendable, CustomStringConvertible {
    case mobileShellUnavailable(slug: String)
    case malformedCatalog
    case invalidCatalogField(String)
    case unsupportedDescriptorVersion(Int)
    case unsupportedPlatform(String)
    case unsupportedPackageFormat(String)
    case invalidDescriptorField(String)
    case disallowedURL
    case redirectRejected
    case unexpectedStatus(Int)
    case unexpectedMIME(expected: String, actual: String?)
    case responseTooLarge(limit: Int)
    case responseLengthMismatch(expected: Int, actual: Int)
    case packageDigestMismatch(expected: String, actual: String)
    case packageIdentityMismatch(field: String, expected: String, actual: String)
    case invalidPackage(NativeShellError)
    case transportFailure(String)
    /// `GET /api/iris/mobile/index.json` returned 404: this Publik deployment
    /// has not published catalog index v2 yet. Callers fall back to the
    /// existing `/api/iris/apps` (v1) route; this is not a network failure.
    case catalogIndexV2Unavailable
    /// A catalog icon's bytes do not hash to the index row's `iconHash`, so
    /// they are not this app's artwork (for example a CDN serving another
    /// app's icon at this path). The icon is not shown.
    case iconDigestMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .mobileShellUnavailable(let slug):
            return "Publik has no mobile-shell download descriptor for \(slug)."
        case .malformedCatalog:
            return "Publik's app catalog could not be decoded."
        case .invalidCatalogField(let field):
            return "Publik's app catalog contains an invalid field: \(field)."
        case .unsupportedDescriptorVersion(let version):
            return "This Iris build does not support Publik mobile-shell descriptor version \(version)."
        case .unsupportedPlatform(let platform):
            return "This Iris build cannot use a Publik mobile-shell artifact for platform \(platform)."
        case .unsupportedPackageFormat(let format):
            return "This Iris build cannot use Publik package format \(format)."
        case .invalidDescriptorField(let field):
            return "Publik's mobile-shell descriptor contains an invalid field: \(field)."
        case .disallowedURL:
            return "Iris only downloads mobile-shell data directly from https://publikhq.com."
        case .redirectRejected:
            return "Publik redirected the mobile-shell request; this Iris build does not follow redirects."
        case .unexpectedStatus(let status):
            return "Publik returned HTTP \(status) for the mobile-shell request."
        case .unexpectedMIME(let expected, let actual):
            return "Publik returned \(actual ?? "no content type") where Iris expected \(expected)."
        case .responseTooLarge(let limit):
            return "Publik's response exceeds the \(limit)-byte limit."
        case .responseLengthMismatch(let expected, let actual):
            return "Publik declared \(expected) bytes but delivered \(actual)."
        case .packageDigestMismatch(let expected, let actual):
            return "The downloaded package digest does not match Publik's catalog binding (expected \(expected), got \(actual))."
        case .packageIdentityMismatch(let field, let expected, let actual):
            return "The downloaded package \(field) does not match Publik's catalog binding (expected \(expected), got \(actual))."
        case .invalidPackage(let error):
            return "The downloaded bytes are not a valid Iris mobile-shell package: \(error.description)."
        case .transportFailure(let reason):
            return "Iris could not read Publik's mobile-shell data: \(reason)"
        case .catalogIndexV2Unavailable:
            return "Publik has not published catalog index v2 yet; falling back to the v1 catalog."
        case .iconDigestMismatch(let expected, let actual):
            return "The downloaded icon does not match the catalog (expected \(expected), got \(actual))."
        }
    }
}

// MARK: - Catalog v2 (index.json / index-<n>.json, categories.json, apps/<slug>.json)
//
// Mirrors mobile-shell/contracts' CatalogIndexV2 / CatalogCategoriesV1 /
// CatalogAppPageV1 (see CONTRACT.md, "Catalog index v2"). This is
// catalog/browse data, never an install authorization: `mobileShell` inside
// `PublikMobileCatalogAppPageV2` is validated exactly like the v1 catalog's
// descriptor (`PublikMobileCatalogClient.validatedDescriptor`), and install
// always goes through that same path unchanged.

public struct PublikMobileCatalogPlacementV2: Equatable, Sendable {
    public let featured: Bool
    public let sponsored: Bool
    public let label: String

    public init(featured: Bool, sponsored: Bool, label: String) {
        self.featured = featured
        self.sponsored = sponsored
        self.label = label
    }
}

public struct PublikMobileCatalogIndexAppV2: Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String
    public let summary: String
    public let categoryIds: [Int]
    public let iconHash: String
    public let iconURL: URL
    public let byteCount: Int
    public let ageRating: Int
    public let updatedAt: String
    public let badges: [String]
    public let placement: PublikMobileCatalogPlacementV2?
    /// R2-CP-3 (round3-deferred/M-store-screens). Optional, so an index
    /// page published before this field existed still decodes: absent or
    /// JSON `null` both become `nil` here, never a decode failure
    /// (`PublikMobileCatalogIndexAppWireV2.latestRevisionId` is a plain
    /// `String?`, which `Decodable`'s synthesized initializer reads with
    /// `decodeIfPresent`). When present, this is the same `rev-sha256:...`
    /// shape `PublikMobileShellDescriptor.revisionId` uses. It lets My apps
    /// show "Update available" for an installed app the catalog now lists a
    /// different revision for, without first fetching that app's own page
    /// (`decodeCatalogIndexPageV2` validates the format when present).
    public let latestRevisionId: String?
    /// RC-05. Who made the app, as written in the index row. Optional: an index
    /// published before this field existed decodes to `nil`, and the store then
    /// shows "By Publik" (`StoreApp.defaultPublisher`). `decodeCatalogIndexPageV2`
    /// checks the shape when present (`StoreApp.isValidPublisherName`).
    public let publisher: String?

    public var id: String { slug }

    public init(
        slug: String,
        name: String,
        summary: String,
        categoryIds: [Int],
        iconHash: String,
        iconURL: URL,
        byteCount: Int,
        ageRating: Int,
        updatedAt: String,
        badges: [String],
        placement: PublikMobileCatalogPlacementV2?,
        latestRevisionId: String? = nil,
        publisher: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.summary = summary
        self.categoryIds = categoryIds
        self.iconHash = iconHash
        self.iconURL = iconURL
        self.byteCount = byteCount
        self.ageRating = ageRating
        self.updatedAt = updatedAt
        self.badges = badges
        self.placement = placement
        self.latestRevisionId = latestRevisionId
        self.publisher = publisher
    }
}

public struct PublikMobileCatalogIndexPageV2: Equatable, Sendable {
    public let version: Int
    public let generatedAt: String
    public let page: Int
    public let pageCount: Int
    public let apps: [PublikMobileCatalogIndexAppV2]

    public init(version: Int, generatedAt: String, page: Int, pageCount: Int, apps: [PublikMobileCatalogIndexAppV2]) {
        self.version = version
        self.generatedAt = generatedAt
        self.page = page
        self.pageCount = pageCount
        self.apps = apps
    }
}

public struct PublikMobileCatalogCategoryV2: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let order: Int
    public let appCount: Int

    public init(id: Int, name: String, order: Int, appCount: Int) {
        self.id = id
        self.name = name
        self.order = order
        self.appCount = appCount
    }
}

public struct PublikMobileCatalogCategoriesV2: Equatable, Sendable {
    public let categories: [PublikMobileCatalogCategoryV2]

    public init(categories: [PublikMobileCatalogCategoryV2]) {
        self.categories = categories
    }
}

public struct PublikMobileCatalogScreenshotV2: Equatable, Sendable {
    public let url: URL
    public let bytes: Int

    public init(url: URL, bytes: Int) {
        self.url = url
        self.bytes = bytes
    }
}

public struct PublikMobileCatalogPermissionV2: Equatable, Sendable {
    public let capability: String
    public let label: String

    public init(capability: String, label: String) {
        self.capability = capability
        self.label = label
    }
}

public struct PublikMobileCatalogAppPageV2: Equatable, Sendable {
    public let mobileShell: PublikMobileShellDescriptor
    public let description: String
    public let screenshots: [PublikMobileCatalogScreenshotV2]
    public let permissions: [PublikMobileCatalogPermissionV2]
    public let privacySummary: String
    public let supportURL: URL
    public let whatsNew: String?

    public init(
        mobileShell: PublikMobileShellDescriptor,
        description: String,
        screenshots: [PublikMobileCatalogScreenshotV2],
        permissions: [PublikMobileCatalogPermissionV2],
        privacySummary: String,
        supportURL: URL,
        whatsNew: String?
    ) {
        self.mobileShell = mobileShell
        self.description = description
        self.screenshots = screenshots
        self.permissions = permissions
        self.privacySummary = privacySummary
        self.supportURL = supportURL
        self.whatsNew = whatsNew
    }
}

struct PublikMobileCatalogPlacementWireV2: Decodable {
    let featured: Bool
    let sponsored: Bool
    let label: String
}

struct PublikMobileCatalogIndexAppWireV2: Decodable {
    let slug: String
    let name: String
    let summary: String
    let categoryIds: [Int]
    let iconHash: String
    let iconURL: String
    let byteCount: Int
    let ageRating: Int
    let updatedAt: String
    let badges: [String]
    let placement: PublikMobileCatalogPlacementWireV2?
    /// R2-CP-3. `Decodable`'s synthesized `init(from:)` reads an `Optional`
    /// stored property with `decodeIfPresent`, so a wire document that
    /// predates this field (the key missing entirely) decodes to `nil`
    /// here, same as an explicit JSON `null`: this one field is the whole
    /// backward-compatibility story, no custom `init(from:)` needed.
    let latestRevisionId: String?
    /// RC-05: optional for the same reason as `latestRevisionId` (a missing key
    /// decodes to `nil`); a present value is checked in `decodeCatalogIndexPageV2`.
    let publisher: String?
}

struct PublikMobileCatalogIndexPageWireV2: Decodable {
    let version: Int
    let generatedAt: String
    let page: Int
    let pageCount: Int
    let apps: [PublikMobileCatalogIndexAppWireV2]
}

struct PublikMobileCatalogCategoryWireV2: Decodable {
    let id: Int
    let name: String
    let order: Int
    let appCount: Int
}

struct PublikMobileCatalogCategoriesWireV2: Decodable {
    let categories: [PublikMobileCatalogCategoryWireV2]
}

struct PublikMobileCatalogScreenshotWireV2: Decodable {
    let url: String
    let bytes: Int
}

struct PublikMobileCatalogPermissionWireV2: Decodable {
    let capability: String
    let label: String
}

struct PublikMobileCatalogAppPageWireV2: Decodable {
    let mobileShell: PublikMobileShellDescriptorWire
    let description: String
    let screenshots: [PublikMobileCatalogScreenshotWireV2]
    let permissions: [PublikMobileCatalogPermissionWireV2]
    let privacySummary: String
    let supportURL: String
    let whatsNew: String?
}

struct PublikMobileCatalogEnvelopeWire: Decodable {
    let apps: [PublikMobileCatalogAppWire]
}

struct PublikMobileCatalogAppWire: Decodable {
    let slug: String
    let name: String
    let guideSlug: String?
    let macBundleId: String?
    let latestReleaseTag: String?
    let mobileShell: PublikMobileShellDescriptorWire?
}

struct PublikMobileShellDescriptorWire: Decodable {
    let version: Int
    let platform: String
    let packageFormat: String
    let downloadURL: String
    let mediaType: String
    let byteCount: Int
    let packageSHA256: String
    let appId: String
    let projectId: String
    let baseRevisionId: String?
    let revisionId: String
    let contentHash: String
    /// Absent on an older descriptor that predates unit m3-guideline47.
    let appStoreMetadata: Review47AppStoreMetadataWire?

    private enum CodingKeys: String, CodingKey {
        case version
        case platform
        case packageFormat
        case downloadURL = "downloadUrl"
        case mediaType
        case byteCount
        case packageSHA256 = "packageSha256"
        case appId
        case projectId
        case baseRevisionId
        case revisionId
        case contentHash
        case appStoreMetadata
    }
}
