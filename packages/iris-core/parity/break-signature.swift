import Foundation

// Verbatim from BreakSignatureService.swift — the macOS implementation as it
// ships today. It is the reference; the core has to match IT, not the reverse.
func normalizeMessage(_ message: String) -> String {
    var normalized = message.lowercased()
    for (pattern, replacement) in [
        (#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, "<uuid>"),
        (#"0x[0-9a-f]+"#, "<addr>"),
        (#"\b[0-9a-f]{7,}\b"#, "<hex>"),
        (#"[a-z]:\\[^\s"']*"#, "<path>"),
        (#"(?:/[^\s"'/]+){2,}/?"#, "<path>"),
        (#"\d+"#, "<n>"),
        (#"\s+"#, " "),
    ] {
        normalized = normalized.replacingOccurrences(
            of: pattern, with: replacement, options: .regularExpression)
    }
    normalized = normalized.trimmingCharacters(in: .whitespaces)
    if normalized.count > 300 { normalized = String(normalized.prefix(300)) }
    return normalized
}

let raw = try! Data(contentsOf: URL(fileURLWithPath: "corpus.json"))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [String]
let out = cases.map { normalizeMessage($0) }
FileManager.default.createFile(
    atPath: "swift-out.json",
    contents: try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]))
print("swift produced \(out.count) results")
