import Foundation

/// The plan's own failure taxonomy (PLAN.md section 5, step 5): one label per
/// failure, deciding which layer must fix it.
public enum FailureClass: String, Sendable, Equatable, Codable, CaseIterable {
    /// Bootstrap, resources, CSP, package construction.
    case setupPackaging = "setup/packaging"
    /// Editor, DB, compositor, WebCodecs use inside a mini app.
    case appSide = "app-side"
    /// Picker, Save, data store, lifecycle inside the native shell host.
    case hostSide = "host-side"
    /// A WebKit or OS limit, documented with a workaround or scope cut.
    case platform = "platform"
    /// Signing, review, catalog, AASA: an owner or website task.
    case distribution = "distribution"
}
