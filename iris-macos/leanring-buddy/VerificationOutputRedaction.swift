//
//  VerificationOutputRedaction.swift
//  leanring-buddy
//
//  Pure, bounded redaction for verification-stage labels and output tails.
//  This stays separate from the verification runner so the standalone
//  usability package can compile the same egress boundary without pulling in
//  the app's execution harness.
//

import Foundation

/// Normalize and redact verification output before retaining a tail. Secret
/// patterns need the key/header prefix to match; truncating first can leave a
/// value suffix looking like harmless output while still carrying the secret.
nonisolated func scrubbedVerificationOutputTail(_ tail: String) -> String {
    let controlStripped = tail.components(separatedBy: "\n").map {
        GuideAutopilotOutputBuffer.strippedOfControlSequences($0)
    }.joined(separator: "\n")
    let scrubbed = GuideAutopilotOutputBuffer.scrubbed(controlStripped)
    let scrubbedCount = scrubbed.count
    let maximumCharacters = 2_000
    guard scrubbedCount > maximumCharacters else { return scrubbed }

    let omissionMarker = "… earlier verification output omitted …"
    let separatorCharacters = 2
    let maximumDiagnosticCharacters = 700
    let reservedTailCharacters = maximumCharacters - maximumDiagnosticCharacters
        - omissionMarker.count - separatorCharacters
    var cursor = 0
    var diagnostic: String?
    for line in scrubbed.components(separatedBy: "\n") {
        let lineStart = cursor
        cursor += line.count + 1
        guard lineStart < scrubbedCount - reservedTailCharacters,
              isLikelyVerificationDiagnosticLine(line) else { continue }
        diagnostic = boundedVerificationDiagnostic(line, maximumCharacters: maximumDiagnosticCharacters)
        break
    }

    guard let diagnostic else { return String(scrubbed.suffix(maximumCharacters)) }
    let suffixCharacters = maximumCharacters - diagnostic.count
        - omissionMarker.count - separatorCharacters
    let suffix = String(scrubbed.suffix(max(0, suffixCharacters)))
    return diagnostic + "\n" + omissionMarker + "\n" + suffix
}

nonisolated private func boundedVerificationDiagnostic(_ line: String, maximumCharacters: Int) -> String {
    guard line.count > maximumCharacters else { return line }
    guard maximumCharacters > 1 else { return String(line.prefix(maximumCharacters)) }
    return String(line.prefix(maximumCharacters - 1)) + "…"
}

nonisolated private func isLikelyVerificationDiagnosticLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isObviousVerificationMarkupLine(trimmed) else { return false }
    let lowercased = trimmed.lowercased()
    let diagnosticPatterns = [
        #"\berror(?:\s*:|\s)"#, #"\bfail(?:ed)?(?:\s*:|\s)"#, #"\bfatal(?:\s*:|\s)"#,
        #"\bexception(?:\s*:|\s)"#, #"\bassert(?:ion)?(?:\s*:|\s)"#,
        #"\bexpected(?:\s*:|\s)"#, #"\breceived(?:\s*:|\s)"#, #"\bnot found\b"#,
        #"\bcannot\b"#, #"\bcould not\b"#, #"\bunable to\b"#, #"\btimed out\b"#,
        #"\bexit (?:code|status)\b"#, #"\bpanic(?:\s*:|\s)"#,
    ]
    return diagnosticPatterns.contains {
        lowercased.range(of: $0, options: .regularExpression) != nil
    }
}

nonisolated private func isObviousVerificationMarkupLine(_ line: String) -> Bool {
    guard !line.isEmpty else { return true }
    if line.hasPrefix("<") || line == ">" || line == "/>" {
        return true
    }
    if line.range(of: #"^[A-Za-z_:][-A-Za-z0-9_:.]*\s*=\s*["']"#, options: .regularExpression) != nil {
        return true
    }
    let markupPrefixes = [
        "class=", "data-", "aria-", "href=", "title=", "width=", "height=", "viewbox=",
        "xmlns=", "fill=", "stroke=", "stroke-", "style=", "id=", "role=", "d=", "x=", "y=",
    ]
    let lowercased = line.lowercased()
    return markupPrefixes.contains { lowercased.hasPrefix($0) }
}
