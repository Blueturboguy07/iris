import Foundation

// Unit m3-guideline47, Guideline 4.7.1's "mechanism to report content and
// timely responses to concerns" (verbatim text checked 2026-09-27 against
// https://developer.apple.com/app-store/review/guidelines/). This builds
// the compose target for a report or a support request from an app's own
// AppStoreMetadataV1 contact, with NO network call: pure string/URL
// construction. The Host opens the returned URL (a mail compose sheet for
// `.mail`, or a share sheet / in-app browser for `.webURL`); Core never
// sends anything itself.

public enum Review47ReportComposer {
    public struct ComposeTarget: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case mail
            case webURL
        }

        public let kind: Kind
        public let url: URL
    }

    public static func composeReport(
        for contact: Review47ContactMethod,
        appDisplayName: String,
        appId: String
    ) -> ComposeTarget {
        compose(for: contact, subjectPrefix: "Report", appDisplayName: appDisplayName, appId: appId)
    }

    public static func composeSupportRequest(
        for contact: Review47ContactMethod,
        appDisplayName: String,
        appId: String
    ) -> ComposeTarget {
        compose(for: contact, subjectPrefix: "Support request", appDisplayName: appDisplayName, appId: appId)
    }

    private static func compose(
        for contact: Review47ContactMethod,
        subjectPrefix: String,
        appDisplayName: String,
        appId: String
    ) -> ComposeTarget {
        switch contact {
        case .email(let address):
            let subject = "\(subjectPrefix): \(appDisplayName)"
            let body = "App: \(appDisplayName) (\(appId))\n\nDescribe the issue below.\n"
            return ComposeTarget(kind: .mail, url: mailtoURL(address: address, subject: subject, body: body))
        case .url(let webURL):
            return ComposeTarget(kind: .webURL, url: webURL)
        }
    }

    /// Builds a `mailto:` URL by hand rather than through `URLComponents`
    /// (whose scheme-specific handling of a bare, non-authority "mailto"
    /// path is not something this codebase wants to depend on). `address`
    /// is already validated by `Review47ContactMethod.isValidEmail`
    /// (no whitespace, no `<>"'`, exactly one "@"), so only `subject` and
    /// `body` need percent-encoding, and only within the query string.
    static func mailtoURL(address: String, subject: String, body: String) -> URL {
        let encodedSubject = percentEncodeQueryComponent(subject)
        let encodedBody = percentEncodeQueryComponent(body)
        let string = "mailto:\(address)?subject=\(encodedSubject)&body=\(encodedBody)"
        // address is pre-validated ASCII-safe local@domain text and the
        // query values are percent-encoded above, so this always parses;
        // the fallback exists only so a future change to this function
        // cannot crash the Host, never because it is expected to trigger.
        return URL(string: string) ?? URL(string: "mailto:\(address)")!
    }

    private static func percentEncodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
