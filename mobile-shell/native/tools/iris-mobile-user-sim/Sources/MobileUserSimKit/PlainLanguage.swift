import Foundation

/// A thin, honest presentation layer over real Core values, written only so
/// this harness's oracles can judge "did the persona see plain words," not a
/// replacement for the real Host UI. `INTEGRATION_HOOKS.md` asks the
/// integrator to confirm the real Host views
/// (`NativeShellCatalogView.swift`, `NativeMarketplaceView.swift`) say the
/// same thing in substance.
public enum PlainLanguage {
    private static let capabilityWords: [String: String] = [
        "web.media.camera": "the camera",
        "web.media.export": "saving exported files",
        "web.media.photo-picker": "choosing photos",
        "web.media.microphone": "the microphone",
        "web.storage": "saving your data",
        "web.navigation.external": "opening outside links",
        "web.network.same-origin": "its own network access",
        "native.camera": "the camera",
        "native.microphone": "the microphone",
        "native.photo-library": "your photo library",
        "native.haptics": "vibration",
        "native.share": "sharing",
    ]

    public static func emptyCatalogExplanation() -> String {
        "Iris could not find any apps to show right now. Check back later."
    }

    public static func unsupportedCapabilitiesExplanation(
        appName: String,
        capabilities: [String],
        osName: String
    ) -> String {
        let words = capabilities
            .sorted()
            .map { capabilityWords[$0] ?? $0 }
        let joined = words.count <= 1
            ? (words.first ?? "a feature")
            : words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
        return "\(appName) needs \(joined), which \(osName) on this iPhone does not support yet."
    }
}
