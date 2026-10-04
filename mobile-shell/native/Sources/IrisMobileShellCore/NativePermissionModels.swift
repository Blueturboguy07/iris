import Foundation

/// A person's remembered answer for one installed app's use of one phone
/// capability inside the Iris shell. This is Iris's own record of what the
/// person chose for THIS app; it is never a substitute for iOS's own camera
/// permission for the whole Iris app, which iOS still asks about separately,
/// at most once per install.
public enum NativePermissionDecision: String, Codable, Equatable, Sendable {
    /// The person has not answered for this app and this capability yet.
    /// The Host must still ask before using the capability.
    case notDecided
    /// The person allowed this app to use this capability. Holds until the
    /// person changes it, even across relaunches and app updates.
    case granted
    /// The person chose never for this app. Holds until the person changes
    /// it; the Host must not ask again on its own.
    case denied
}

/// Named capability strings this store knows how to remember a decision for.
/// A capability here is always one of the same strings carried in
/// `VerifiedLaunchDescriptor.requestedCapabilities`, never a separate ID
/// space; the store itself accepts any `String` so that a future capability
/// is a new named constant here, not a change to the store's API or to the
/// unit that owns it.
public enum NativePermissionCapability {
    /// Matches `NativeMediaPermissionPolicy`'s capability string for camera.
    public static let camera = "web.media.camera"
}

public enum NativePermissionStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidCapability
    case invalidRoot
    case invalidStoreFile
}
