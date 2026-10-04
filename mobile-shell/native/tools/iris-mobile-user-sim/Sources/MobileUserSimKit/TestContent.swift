import Foundation

/// Small shared helpers scenarios use to build real package content and
/// stable-id-safe identities. Kept in one place so every scenario's fixture
/// content is visibly a real, verifiable HTML entrypoint, not opaque bytes.
public enum TestContent {
    public static func html(_ marker: String) -> String {
        "<!doctype html><meta charset=utf-8><title>Persona sim</title><main>\(marker)</main>"
    }

    public static func containsMarker(_ fileContents: String, _ marker: String) -> Bool {
        fileContents.contains(marker)
    }
}
