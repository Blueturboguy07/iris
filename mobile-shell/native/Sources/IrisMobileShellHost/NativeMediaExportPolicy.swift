import Foundation

/// Pure authorization and response validation for app-produced media exports.
/// It grants no file-system destination, WebKit download lifetime, picker
/// presentation, authentication, redirect, or native bridge authority.
enum NativeMediaExportPolicy {
    static let capability = "web.media.export"
    static let maximumExportBytes = Int64(NativeMediaPermissionPolicy.maximumFileBytes)

    enum BlobSyntax: Hashable, Sendable {
        case opaqueFileOrigin
        case explicitFileOrigin
    }

    struct BlobIdentity: Equatable, Sendable {
        let absoluteString: String
        let syntax: BlobSyntax

        fileprivate init(absoluteString: String, syntax: BlobSyntax) {
            self.absoluteString = absoluteString
            self.syntax = syntax
        }
    }

    struct Metadata: Equatable, Sendable {
        let fileExtension: String
        let byteCount: Int
    }

    static func authorizeBlobDownload(
        requestedCapabilities: [String],
        isValid: Bool,
        hasWindow: Bool,
        shouldPerformDownload: Bool,
        isExportInFlight: Bool,
        sourceIsMainFrame: Bool,
        sourceURL: URL?,
        currentMainFrameURL: URL?,
        requestURL: URL?,
        contentRoot: URL,
        allowedBlobSyntaxes: Set<BlobSyntax>
    ) -> BlobIdentity? {
        guard isValid,
              hasWindow,
              shouldPerformDownload,
              !isExportInFlight,
              sourceIsMainFrame,
              let sourceURL,
              let currentMainFrameURL,
              sourceURL.absoluteString == currentMainFrameURL.absoluteString,
              NativeMediaPermissionPolicy.allows(
                capability: capability,
                requestedCapabilities: requestedCapabilities,
                isValid: isValid,
                isMainFrame: sourceIsMainFrame,
                frameURL: sourceURL,
                contentRoot: contentRoot
              ),
              let requestURL,
              let syntax = parsedBlobSyntax(requestURL),
              allowedBlobSyntaxes.contains(syntax) else {
            return nil
        }
        return BlobIdentity(absoluteString: requestURL.absoluteString, syntax: syntax)
    }

    static func responseMetadata(
        response: URLResponse,
        expectedBlobURL: URL
    ) -> Metadata? {
        guard let expectedSyntax = parsedBlobSyntax(expectedBlobURL) else { return nil }
        let expectedContentLength = response.expectedContentLength
        guard expectedContentLength > 0,
              expectedContentLength <= maximumExportBytes,
              let responseURL = response.url,
              responseURL.absoluteString == expectedBlobURL.absoluteString,
              parsedBlobSyntax(responseURL) == expectedSyntax,
              let mimeType = response.mimeType,
              let fileExtension = trustedMediaExtensions[mimeType],
              let byteCount = Int(exactly: expectedContentLength) else {
            return nil
        }
        return Metadata(
            fileExtension: fileExtension,
            byteCount: byteCount
        )
    }

    /// App exports are local blob responses only. A redirect would replace the
    /// exact blob identity whose current-frame authority was already checked.
    static func permitsRedirect(for blob: BlobIdentity, to url: URL?) -> Bool {
        _ = blob
        _ = url
        return false
    }

    /// Blob exports never borrow HTTP authentication, cookies, or credentials.
    static func permitsAuthenticationChallenge(for blob: BlobIdentity) -> Bool {
        _ = blob
        return false
    }

    private static let trustedMediaExtensions: [String: String] = [
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/gif": "gif",
        "image/webp": "webp",
        "image/heic": "heic",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
        "video/webm": "webm",
    ]

    private static func parsedBlobSyntax(_ url: URL) -> BlobSyntax? {
        guard url.scheme?.lowercased() == "blob",
              url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.host == nil,
              url.port == nil else {
            return nil
        }
        let value = url.absoluteString
        guard !value.contains("?"), !value.contains("#") else { return nil }
        if value.hasPrefix("blob:null/") {
            let suffix = String(value.dropFirst("blob:null/".count))
            guard isExactUUID(suffix) else { return nil }
            return .opaqueFileOrigin
        }
        guard value.hasPrefix("blob:file:"),
              let inner = URL(string: String(value.dropFirst("blob:".count))),
              inner.isFileURL,
              inner.query == nil,
              inner.fragment == nil,
              inner.user == nil,
              inner.password == nil,
              inner.host == nil,
              inner.port == nil,
              let last = inner.pathComponents.last,
              isExactUUID(last) else {
            return nil
        }
        return .explicitFileOrigin
    }

    private static func isExactUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }
}
