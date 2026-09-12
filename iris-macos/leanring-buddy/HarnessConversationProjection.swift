import Foundation

/// Targets the replay sent by the lab adapter without rewriting the executor's
/// local transcript. The opening user turn and recent action-result pairs stay
/// intact. Older successful tool observations may be replaced in place by a
/// truthful reread marker when they repeat or when the byte ceiling requires
/// it. User decisions, obligations and negative evidence are never eligible.
/// This is a soft target. HarnessModelSession's ledger remains the hard input
/// admission boundary when protected evidence itself exceeds the target.
nonisolated enum HarnessCodexConversationBudget {
    static let conversationByteTarget = 24_000
    static let preservedRecentActionResultPairs = 4

    struct Result {
        let messages: [HarnessModelMessage]
        let sentUTF8Bytes: Int
        let compactedObservationTurnCount: Int
        let targetWasExceeded: Bool
    }

    private struct ActionResultSpan {
        let outputRange: Range<String.Index>
        let output: String
        let exitCode: String
        let preservesEvidence: Bool
    }

    static func project(_ messages: [HarnessModelMessage]) -> Result {
        let originalBytes = utf8ByteCount(of: messages)
        guard originalBytes > conversationByteTarget else {
            return Result(messages: messages, sentUTF8Bytes: originalBytes,
                          compactedObservationTurnCount: 0,
                          targetWasExceeded: false)
        }

        var projectedMessages = messages
        let actionResultIndices = messages.indices.filter {
            messages[$0].role == "user" && actionResult(in: messages[$0].text) != nil
        }
        var protectedIndices = Set<Int>()
        if let openingIndex = messages.firstIndex(where: { $0.role == "user" }) {
            protectedIndices.insert(openingIndex)
        }

        for actionIndex in actionResultIndices.suffix(preservedRecentActionResultPairs) {
            protectedIndices.insert(actionIndex)
            if let precedingAssistant = messages[..<actionIndex].lastIndex(where: { $0.role == "assistant" }) {
                protectedIndices.insert(precedingAssistant)
            }
        }
        for assistantIndex in messages.indices.filter({ messages[$0].role == "assistant" }).suffix(2) {
            protectedIndices.insert(assistantIndex)
        }

        var compactedIndices = Set<Int>()
        var laterObservationKeys = Set<String>()

        // Work from the newest result toward the oldest so a repeated older
        // observation is summarized while the latest copy remains verbatim.
        for messageIndex in actionResultIndices.reversed() {
            guard let span = actionResult(in: messages[messageIndex].text),
                  !span.preservesEvidence else { continue }
            let key = span.output
            guard !key.isEmpty else { continue }
            let isRepeated = !laterObservationKeys.insert(key).inserted
            if isRepeated, !protectedIndices.contains(messageIndex),
               let replacement = replacedActionResult(
                   messages[messageIndex].text, span: span,
                   reason: "matches a later observation"
               ) {
                projectedMessages[messageIndex] = HarnessModelMessage(
                    role: messages[messageIndex].role,
                    text: replacement,
                    imagePNG: messages[messageIndex].imagePNG
                )
                compactedIndices.insert(messageIndex)
            }
        }

        // A run may have many distinct but superseded successful probes. Once
        // the soft target is still exceeded, summarize the oldest safe result
        // turns first. The command exit and the pair's position remain.
        if utf8ByteCount(of: projectedMessages) > conversationByteTarget {
            for messageIndex in actionResultIndices {
                guard !protectedIndices.contains(messageIndex),
                      let span = actionResult(in: projectedMessages[messageIndex].text),
                      !span.preservesEvidence,
                      let replacement = replacedActionResult(
                          projectedMessages[messageIndex].text, span: span,
                          reason: "outside the recent action-result window"
                      ) else { continue }
                projectedMessages[messageIndex] = HarnessModelMessage(
                    role: projectedMessages[messageIndex].role,
                    text: replacement,
                    imagePNG: projectedMessages[messageIndex].imagePNG
                )
                compactedIndices.insert(messageIndex)
                if utf8ByteCount(of: projectedMessages) <= conversationByteTarget { break }
            }
        }

        let sentBytes = utf8ByteCount(of: projectedMessages)
        return Result(
            messages: projectedMessages,
            sentUTF8Bytes: sentBytes,
            compactedObservationTurnCount: compactedIndices.count,
            targetWasExceeded: sentBytes > conversationByteTarget
        )
    }

    private static func actionResult(in text: String) -> ActionResultSpan? {
        guard text.hasPrefix("Command exit "),
              let outputMarker = text.range(of: ". Output:\n") else { return nil }
        let codeStart = text.index(text.startIndex, offsetBy: "Command exit ".count)
        let code = String(text[codeStart..<outputMarker.lowerBound])
        guard !code.isEmpty, Int32(code) != nil else { return nil }
        let outputStart = outputMarker.upperBound
        guard let nextMove = text.range(of: "\n\nNext:", options: .backwards,
                                        range: outputStart..<text.endIndex) else {
            return nil
        }
        let candidate = text[outputStart..<nextMove.lowerBound]
        let outputEnd = candidate.range(of: "\n\nYour reply")?.lowerBound ?? nextMove.lowerBound
        let output = String(text[outputStart..<outputEnd])
        return ActionResultSpan(
            outputRange: outputStart..<outputEnd,
            output: output,
            exitCode: code,
            preservesEvidence: Int32(code) != 0 || containsNegativeEvidence(output)
        )
    }

    private static func replacedActionResult(
        _ text: String, span: ActionResultSpan, reason: String
    ) -> String? {
        let marker = "[historical tool output truncated; reread if needed; \(reason); exit code \(span.exitCode) retained]"
        guard marker.utf8.count < span.output.utf8.count else { return nil }
        return String(text[..<span.outputRange.lowerBound])
            + marker
            + String(text[span.outputRange.upperBound...])
    }

    private static func containsNegativeEvidence(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let markers = [
            "error", "failed", "failure", "not found", "no such file", "permission denied",
            "access denied", "missing", "unavailable", "not available", "not installed",
            "blocked", "unable", "could not", "cannot", "false", "no output", "not run",
            "not changed", "unknown", "stopped", "cancelled"
        ]
        return markers.contains(where: { lowercased.contains($0) })
    }

    private static func utf8ByteCount(of messages: [HarnessModelMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            let roleResult = total.addingReportingOverflow(message.role.utf8.count)
            let textResult = roleResult.partialValue.addingReportingOverflow(message.text.utf8.count)
            total = roleResult.overflow || textResult.overflow ? Int.max : textResult.partialValue
        }
    }
}

/// Keeps durable user and execution context while removing only confirmed,
/// historical file-edit payloads from older model turns.
nonisolated enum HarnessConversationProjection {
    /// A projection result contains the complete message envelope the caller
    /// should send, plus text-byte accounting for the before and after views.
    nonisolated struct Result: Sendable {
        let messages: [HarnessModelMessage]
        let originalUTF8Bytes: Int
        let sentUTF8Bytes: Int
        let removedUTF8Bytes: Int
        let originalImageBytes: Int
        let sentImageBytes: Int
        let compactedAssistantTurnCount: Int

        var didCompact: Bool {
            compactedAssistantTurnCount > 0
        }
    }

    /// Projects a conversation using executor-owned receipts keyed by the
    /// exact raw assistant reply. A receipt's paths are the only evidence that
    /// a matching write or edit block actually changed a file.
    ///
    /// The projection is intentionally conservative. User messages, images,
    /// recent assistant turns, unknown blocks, malformed replies and blocks
    /// without a matching changed path remain byte-for-byte unchanged. Native
    /// edit fences carry the path on the opening line. An alternate historical
    /// first-body-line format is also recognized, but still requires a receipt;
    /// this does not extend the executor's accepted edit syntax.
    static func project(
        messages: [HarnessModelMessage],
        confirmedAppliedReplies: [String: [String]]
    ) -> Result {
        let originalUTF8Bytes = utf8ByteCount(of: messages)
        let originalImageBytes = imageByteCount(of: messages)
        let assistantTurnIndices = messages.indices.filter { messages[$0].role == "assistant" }
        let recentAssistantTurnIndices = Set(assistantTurnIndices.suffix(2))
        var projectedMessages = messages
        var compactedAssistantTurnCount = 0

        for messageIndex in assistantTurnIndices where !recentAssistantTurnIndices.contains(messageIndex) {
            let message = messages[messageIndex]
            guard let changedPaths = validatedChangedPaths(confirmedAppliedReplies[message.text]) else {
                continue
            }
            let scannedReply = scan(reply: message.text)
            guard !scannedReply.isMalformed else {
                continue
            }

            let changedPathSet = Set(changedPaths)
            var replacements: [Replacement] = []
            for block in scannedReply.blocks {
                guard let fileEdit = block.fileEdit,
                      changedPathSet.contains(fileEdit.path) else {
                    continue
                }

                let historicalReceipt = historicalReceipt(for: changedPaths)
                let replacementText = historicalReceipt + block.lineEnding
                let originalBodyByteCount = message.text[block.payloadRange].utf8.count
                guard replacementText.utf8.count < originalBodyByteCount else {
                    continue
                }
                replacements.append(Replacement(range: block.payloadRange, text: replacementText))
            }

            guard !replacements.isEmpty,
                  let projectedReply = replacing(replacements, in: message.text),
                  projectedReply.utf8.count < message.text.utf8.count else {
                continue
            }

            projectedMessages[messageIndex] = HarnessModelMessage(
                role: message.role,
                text: projectedReply,
                imagePNG: message.imagePNG
            )
            compactedAssistantTurnCount += 1
        }

        let sentUTF8Bytes = utf8ByteCount(of: projectedMessages)
        let sentImageBytes = imageByteCount(of: projectedMessages)
        return Result(
            messages: projectedMessages,
            originalUTF8Bytes: originalUTF8Bytes,
            sentUTF8Bytes: sentUTF8Bytes,
            removedUTF8Bytes: max(0, originalUTF8Bytes - sentUTF8Bytes),
            originalImageBytes: originalImageBytes,
            sentImageBytes: sentImageBytes,
            compactedAssistantTurnCount: compactedAssistantTurnCount
        )
    }

    // MARK: - Reply scanning

    private struct Replacement {
        let range: Range<String.Index>
        let text: String
    }

    private struct ReplyLine {
        let text: String
        let start: String.Index
        let endWithLineEnding: String.Index
        let lineEnding: String
    }

    private struct OpenFence {
        let lineIndex: Int
        let runLength: Int
        let tag: String
        let fileEditPath: String?
    }

    private struct FileEdit {
        enum Kind {
            case write
            case edit
        }

        let kind: Kind
        let path: String
    }

    private struct FenceBlock {
        let payloadRange: Range<String.Index>
        let fileEdit: FileEdit?
        let lineEnding: String
    }

    private struct ScannedReply {
        let blocks: [FenceBlock]
        let isMalformed: Bool
    }

    private static func scan(reply: String) -> ScannedReply {
        let lines = splitLines(of: reply)
        guard !lines.isEmpty else { return ScannedReply(blocks: [], isMalformed: false) }

        var blocks: [FenceBlock] = []
        var openFence: OpenFence?
        var malformed = false
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let runLength = openingRunLength(of: line.text)
            let isBareFence = isBareFence(line.text)

            if let currentOpenFence = openFence {
                if isBareFence && runLength >= currentOpenFence.runLength {
                    let openingLine = lines[currentOpenFence.lineIndex]
                    let bodyStart = openingLine.endWithLineEnding
                    let bodyEnd = line.start
                    let allBodyLines = Array(lines[(currentOpenFence.lineIndex + 1)..<lineIndex])
                        .map(\.text)
                    var payloadLines = allBodyLines
                    var payloadStart = bodyStart
                    var fileEditPath = currentOpenFence.fileEditPath

                    // An alternate historical format puts the path on the first
                    // body line. Keep that line in the replay. Recognition here
                    // is not evidence that the executor accepted this reply.
                    if (currentOpenFence.tag == "write" || currentOpenFence.tag == "edit"),
                       fileEditPath == nil {
                        guard let firstBodyLine = lines[(currentOpenFence.lineIndex + 1)..<lineIndex].first,
                              let validatedPath = validatedPath(firstBodyLine.text) else {
                            malformed = true
                            openFence = nil
                            lineIndex += 1
                            continue
                        }
                        fileEditPath = validatedPath
                        payloadLines = Array(allBodyLines.dropFirst())
                        payloadStart = firstBodyLine.endWithLineEnding
                    }
                    let fileEdit = fileEdit(
                        tag: currentOpenFence.tag,
                        path: fileEditPath,
                        bodyLines: payloadLines
                    )
                    if (currentOpenFence.tag == "write" || currentOpenFence.tag == "edit"), fileEdit == nil {
                        malformed = true
                    }
                    blocks.append(FenceBlock(
                        payloadRange: payloadStart..<bodyEnd,
                        fileEdit: fileEdit,
                        lineEnding: openingLine.lineEnding.isEmpty ? "\n" : openingLine.lineEnding
                    ))
                    openFence = nil
                } else if runLength >= 3 {
                    // A fence inside an open block is ambiguous for a replay
                    // projection. Preserve the entire reply instead of
                    // risking a partial or nested payload replacement.
                    malformed = true
                }
            } else if runLength >= 3 {
                let trimmedLine = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let openingRemainder = String(trimmedLine.dropFirst(runLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tag = openingRemainder
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map { String($0).lowercased() } ?? ""
                let isFileEditTag = tag == "write" || tag == "edit"
                let path = isFileEditTag
                    ? String(openingRemainder.dropFirst(tag.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                openFence = OpenFence(
                    lineIndex: lineIndex,
                    runLength: runLength,
                    tag: tag,
                    fileEditPath: isFileEditTag && !path.isEmpty ? path : nil,
                )
            }
            lineIndex += 1
        }

        if openFence != nil {
            malformed = true
        }
        return ScannedReply(blocks: blocks, isMalformed: malformed)
    }

    private static func splitLines(of reply: String) -> [ReplyLine] {
        guard !reply.isEmpty else { return [] }
        var lines: [ReplyLine] = []
        var lineStart = reply.startIndex

        while lineStart < reply.endIndex {
            if let newlineIndex = reply[lineStart...].firstIndex(of: "\n") {
                let characterBeforeNewline = reply.index(before: newlineIndex)
                let hasCarriageReturn = reply[characterBeforeNewline] == "\r"
                let textEnd = hasCarriageReturn ? characterBeforeNewline : newlineIndex
                let lineEnding = hasCarriageReturn ? "\r\n" : "\n"
                lines.append(ReplyLine(
                    text: String(reply[lineStart..<textEnd]),
                    start: lineStart,
                    endWithLineEnding: reply.index(after: newlineIndex),
                    lineEnding: lineEnding
                ))
                lineStart = reply.index(after: newlineIndex)
            } else {
                lines.append(ReplyLine(
                    text: String(reply[lineStart..<reply.endIndex]),
                    start: lineStart,
                    endWithLineEnding: reply.endIndex,
                    lineEnding: ""
                ))
                lineStart = reply.endIndex
            }
        }
        return lines
    }

    private static func openingRunLength(of line: String) -> Int {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let runLength = trimmedLine.prefix(while: { $0 == "`" }).count
        return runLength >= 3 ? runLength : 0
    }

    private static func isBareFence(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let runLength = openingRunLength(of: trimmedLine)
        return runLength >= 3 && runLength == trimmedLine.count
    }

    private static func fileEdit(
        tag: String,
        path: String?,
        bodyLines: [String]
    ) -> FileEdit? {
        guard let path,
              validatedPath(path) != nil,
              (tag == "write" || tag == "edit") else {
            return nil
        }
        if tag == "edit" && !isValidEditBody(bodyLines) {
            return nil
        }
        return FileEdit(kind: tag == "write" ? .write : .edit, path: path)
    }

    private static func validatedPath(_ pathLine: String) -> String? {
        let path = pathLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.contains("\n"),
              !path.contains("\r"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        return path
    }

    private static func isValidEditBody(_ bodyLines: [String]) -> Bool {
        var searchMarkerIndex: Int?
        var dividerMarkerIndex: Int?
        var replaceMarkerIndex: Int?

        for (index, line) in bodyLines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if searchMarkerIndex == nil, trimmedLine.hasPrefix("<<<<<<<") {
                searchMarkerIndex = index
            } else if searchMarkerIndex != nil, dividerMarkerIndex == nil,
                      trimmedLine.hasPrefix("=======") {
                dividerMarkerIndex = index
            } else if dividerMarkerIndex != nil, replaceMarkerIndex == nil,
                      trimmedLine.hasPrefix(">>>>>>>") {
                replaceMarkerIndex = index
            }
        }

        guard let searchMarkerIndex,
              let dividerMarkerIndex,
              let replaceMarkerIndex,
              searchMarkerIndex < dividerMarkerIndex,
              dividerMarkerIndex < replaceMarkerIndex else {
            return false
        }
        let searchText = bodyLines[(searchMarkerIndex + 1)..<dividerMarkerIndex]
            .joined(separator: "\n")
        return !searchText.isEmpty
    }

    private static func historicalReceipt(for changedPaths: [String]) -> String {
        "[historical applied edit receipt; changed paths: "
            + changedPaths.joined(separator: ", ")
            + "; no proof of current source]"
    }

    private static func replacing(
        _ replacements: [Replacement],
        in reply: String
    ) -> String? {
        let orderedReplacements = replacements.sorted {
            reply.distance(from: reply.startIndex, to: $0.range.lowerBound)
                < reply.distance(from: reply.startIndex, to: $1.range.lowerBound)
        }
        var projectedReply = ""
        var cursor = reply.startIndex
        for replacement in orderedReplacements {
            guard replacement.range.lowerBound >= cursor else { return nil }
            projectedReply += reply[cursor..<replacement.range.lowerBound]
            projectedReply += replacement.text
            cursor = replacement.range.upperBound
        }
        projectedReply += reply[cursor..<reply.endIndex]
        return projectedReply
    }

    // MARK: - Receipt and byte accounting

    private static func validatedChangedPaths(_ paths: [String]?) -> [String]? {
        guard let paths, !paths.isEmpty else { return nil }
        var validatedPaths: [String] = []
        var seenPaths: Set<String> = []
        for path in paths {
            guard !path.isEmpty,
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.contains("\n"),
                  !path.contains("\r"),
                  !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                return nil
            }
            if seenPaths.insert(path).inserted {
                validatedPaths.append(path)
            }
        }
        return validatedPaths.isEmpty ? nil : validatedPaths
    }

    private static func utf8ByteCount(of messages: [HarnessModelMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            total = addingWithoutOverflow(total, message.role.utf8.count)
            total = addingWithoutOverflow(total, message.text.utf8.count)
        }
    }

    private static func imageByteCount(of messages: [HarnessModelMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            total = addingWithoutOverflow(total, message.imagePNG?.count ?? 0)
        }
    }

    private static func addingWithoutOverflow(_ value: Int, _ addition: Int) -> Int {
        let result = value.addingReportingOverflow(addition)
        return result.overflow ? Int.max : result.partialValue
    }
}
