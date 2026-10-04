import IrisMobileShellCore
import WebKit

public enum NativeWebStorageConfigurationError: Error, Equatable {
    case persistentDataStoreUnavailable
}

/// Platform boundary for installed web capabilities. Storage stays isolated;
/// media uses the separate consented WebKit/OS delegates, not a native bridge.
///
/// Hosts should pass `capabilityPolicy` into the core coordinator. A launch
/// that does not request storage receives no persistent data store. A verified
/// launch that does request storage can use a named WebKit store only on the
/// OS versions where Apple's public identifier API is available.
public enum NativeWebStorageConfiguration {
    public static var capabilityPolicy: CapabilityPolicy {
#if os(iOS)
        if #available(iOS 18.4, *) {
            var supported: Set<String> = ["web.storage", "web.media.photo-picker", "web.media.export"]
            // The camera declaration belongs to this Host, never app metadata.
            if let explanation = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
               !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                supported.insert("web.media.camera")
            }
            return CapabilityPolicy(supportedCapabilities: supported)
        }
        if #available(iOS 17.0, *) {
            return CapabilityPolicy(supportedCapabilities: ["web.storage"])
        }
#elseif os(macOS)
        if #available(macOS 14.0, *) {
            return CapabilityPolicy(supportedCapabilities: ["web.storage"])
        }
#endif
        return .denyAll
    }

    @MainActor
    public static func dataStore(
        for launch: VerifiedLaunchDescriptor
    ) throws -> WKWebsiteDataStore? {
        guard let storageIdentity = launch.webStorageIdentity else { return nil }

#if os(iOS)
        guard #available(iOS 17.0, *) else {
            throw NativeWebStorageConfigurationError.persistentDataStoreUnavailable
        }
#elseif os(macOS)
        guard #available(macOS 14.0, *) else {
            throw NativeWebStorageConfigurationError.persistentDataStoreUnavailable
        }
#else
        throw NativeWebStorageConfigurationError.persistentDataStoreUnavailable
#endif

        return WKWebsiteDataStore(forIdentifier: storageIdentity.identifier)
    }
}
