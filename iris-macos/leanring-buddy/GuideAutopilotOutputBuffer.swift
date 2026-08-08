//
//  GuideAutopilotOutputBuffer.swift
//  leanring-buddy
//
//  What the autopilot terminal remembers, and the two very different shapes
//  it hands out. The display ring keeps what the reader scrolls — bounded so
//  a chatty `npm ci` cannot grow without limit, unscrubbed because the
//  reader's own terminal shows their own secrets and masking them here would
//  only confuse. The model tail is the opposite: short, ANSI-stripped, and
//  secret-scrubbed, because it leaves the machine. Scrub on egress only —
//  that is the line.
//

import Foundation

// nonisolated: pure value logic used on the shell session's own queue. The
// target's default MainActor isolation must not apply — output bookkeeping
// runs regardless of what the main thread is doing.
nonisolated struct GuideAutopilotOutputBuffer {

    static let maximumDisplayLines = 4_000
    static let maximumDisplayBytes = 256 * 1_024
    static let modelTailMaximumLines = 60
    static let modelTailMaximumCharacters = 3_000

    /// True once the head of the buffer has been trimmed; the view renders
    /// an "… earlier output trimmed" marker above the first line.
    private(set) var earlierOutputWasTrimmed = false

    private var lines: [String] = []
    private var byteCount = 0
    /// The still-open final line — output that has not seen its newline yet.
    private var openLine = ""
    /// Bytes of a UTF-8 code point split across read chunks.
    private var pendingUTF8: [UInt8] = []

    // MARK: - Ingest

    mutating func append(_ bytes: [UInt8]) {
        var buffer = pendingUTF8
        buffer.append(contentsOf: bytes)
        pendingUTF8 = []

        // Decode as much complete UTF-8 as the chunk holds; carry a trailing
        // partial code point to the next append instead of mangling it.
        var validPrefixLength = buffer.count
        while validPrefixLength > 0,
              String(bytes: buffer[0..<validPrefixLength], encoding: .utf8) == nil {
            validPrefixLength -= 1
            if buffer.count - validPrefixLength > 4 {
                // Not a split code point, just bad bytes: decode lossily.
                validPrefixLength = buffer.count
                break
            }
        }
        pendingUTF8 = Array(buffer[validPrefixLength...])
        let text = String(bytes: buffer[0..<validPrefixLength], encoding: .utf8)
            ?? String(decoding: buffer[0..<validPrefixLength], as: UTF8.self)

        ingest(text)
    }

    mutating func ingest(_ text: String) {
        var remainder = openLine + text
        openLine = ""
        while let newline = remainder.firstIndex(of: "\n") {
            let line = String(remainder[..<newline])
            appendCompleteLine(Self.strippedOfControlSequences(line))
            remainder = String(remainder[remainder.index(after: newline)...])
        }
        // A process can emit megabytes with no newline at all; force-rotate
        // an oversized open line so the buffer stays bounded regardless.
        while remainder.count > 8_192 {
            let head = String(remainder.prefix(8_192))
            appendCompleteLine(Self.strippedOfControlSequences(head))
            remainder = String(remainder.dropFirst(8_192))
        }
        openLine = remainder
        enforceBounds()
    }

    private mutating func appendCompleteLine(_ line: String) {
        lines.append(line)
        byteCount += line.utf8.count + 1
    }

    private mutating func enforceBounds() {
        while lines.count > Self.maximumDisplayLines
            || byteCount > Self.maximumDisplayBytes {
            guard !lines.isEmpty else { break }
            let removed = lines.removeFirst()
            byteCount -= removed.utf8.count + 1
            earlierOutputWasTrimmed = true
        }
    }

    // MARK: - What the reader sees

    var displayLines: [String] {
        let stripped = Self.strippedOfControlSequences(openLine)
        return stripped.isEmpty ? lines : lines + [stripped]
    }

    /// The unfinished final line, for prompt detection: a command that is
    /// asking a question typically parks the cursor after "…? (y/n) ".
    var unterminatedTail: String {
        Self.strippedOfControlSequences(openLine)
    }

    mutating func removeAll() {
        lines.removeAll()
        openLine = ""
        pendingUTF8 = []
        byteCount = 0
        earlierOutputWasTrimmed = false
    }

    // MARK: - What the model sees

    func tailForTheModel() -> String {
        let tail = displayLines.suffix(Self.modelTailMaximumLines)
        var joined = tail.joined(separator: "\n")
        if joined.count > Self.modelTailMaximumCharacters {
            joined = String(joined.suffix(Self.modelTailMaximumCharacters))
        }
        return Self.scrubbed(joined)
    }

    // MARK: - ANSI / control stripping
    //
    // Not a terminal emulator: CSI and OSC sequences are removed, printable
    // text survives, and that is the whole contract. Cursor-art progress bars
    // degrade to their final text, which is what a transcript should hold.

    static func strippedOfControlSequences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var characters = Substring(text)
        while let escape = characters.firstIndex(of: "\u{1B}") {
            result += characters[..<escape]
            var rest = characters[characters.index(after: escape)...]
            if rest.first == "[" {
                // CSI: parameters then one final byte in @-~.
                rest = rest.dropFirst()
                while let head = rest.first, !("\u{40}"..."\u{7E}").contains(head) {
                    rest = rest.dropFirst()
                }
                rest = rest.dropFirst()
            } else if rest.first == "]" {
                // OSC: runs to BEL or ESC-backslash.
                if let bell = rest.firstIndex(of: "\u{07}") {
                    rest = rest[rest.index(after: bell)...]
                } else if let terminator = rest.range(of: "\u{1B}\\") {
                    rest = rest[terminator.upperBound...]
                } else {
                    rest = Substring("")
                }
            } else {
                // Two-character escape (ESC c, ESC =, …).
                rest = rest.dropFirst()
            }
            characters = rest
        }
        result += characters
        // The pty's ONLCR discipline ends every line with \r\n, so first
        // drop the terminator's \r — it is not a progress bar. Interior
        // carriage returns ARE progress bars; keep only the final frame.
        while result.hasSuffix("\r") { result.removeLast() }
        let afterCarriage = result.components(separatedBy: "\r").last ?? result
        return String(afterCarriage.filter { character in
            character == "\t" || !character.isControlCharacter
        })
    }

    // MARK: - Secret scrubbing (egress only)

    private static let secretPatterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_-]{20,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|\z)"#,
        #"Bearer [A-Za-z0-9._-]{20,}"#,
        #"\b[A-Z_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z_]*\s*=\s*\S+"#,
    ].map {
        // Compile-time constant patterns; a typo should crash tests loudly.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: $0, options: [])
    }

    static func scrubbed(_ text: String) -> String {
        var scrubbed = text
        for pattern in secretPatterns {
            let range = NSRange(scrubbed.startIndex..., in: scrubbed)
            scrubbed = pattern.stringByReplacingMatches(
                in: scrubbed, range: range, withTemplate: "[REDACTED]"
            )
        }
        return scrubbed
    }
}

private extension Character {
    nonisolated var isControlCharacter: Bool {
        unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}
