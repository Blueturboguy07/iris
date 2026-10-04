#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Thin container wiring `coordinator` + `identity` into `FeaturesView`,
/// the same shape as `NativeStorageAppUsageContainer` wires
/// `NativeStorageAppUsageModel` into its section. This is the view
/// `StoreMyAppsView`'s `openFeatures` hook (and MA2's row-menu "Features"
/// item) should push, per mobile-versions SPEC.md section 1 and MA2
/// SPEC.md line 150 (see INTEGRATION_HOOKS.md "Features destination").
struct StoreVersionsView: View {
    let coordinator: NativeShellLibraryCoordinator
    let identity: NativeShellAppIdentity
    let appName: String
    var removeAppAvailable: Bool = false
    var onAppRemoved: (_ alsoDeleteData: Bool) -> Void = { _ in }

    var body: some View {
        FeaturesView(
            model: FeaturesModelCache.model(coordinator: coordinator, identity: identity),
            appName: appName,
            onAppRemoved: onAppRemoved,
            removeAppAvailable: removeAppAvailable
        )
    }
}
#endif
