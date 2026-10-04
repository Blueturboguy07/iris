#if os(iOS)
import Foundation

// Unit MA2 my-apps-screen. One place that turns MA1's combined identity
// string (`NativeShellAppIdentity.id`, `"appId::projectId"`, SPEC 3.1) back
// into the bare `appId` every kept M-store-screens identifier uses
// (`iris.store.my-apps.row.<appId>`, `iris.open.<appId>`,
// `iris.versions.<appId>`, `MyAppsUITests.kneecapAppId = "publik.kneecap"`,
// no `::projectId` suffix). Every new SPEC section-6 identifier that also
// carries `<appId>` uses the same bare form for consistency with those kept
// ones. Business logic (dispatch to `MyAppsOrganizationStore`, the
// arrangement's own dictionary/array keys) always uses the full combined
// identity string instead; only display/identifier strings go through this.
enum MyAppsIdentifiers {
    static func appIdComponent(_ identity: String) -> String {
        String(identity.split(separator: ":", maxSplits: 1).first ?? Substring(identity))
    }
}
#endif
