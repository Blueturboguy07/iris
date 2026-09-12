import Foundation
import Testing
@testable import IrisHarness

@Test("four older multi-file edit steps shrink while the recent two stay verbatim")
func fourOlderMultiFileStepsAreCompacted() {
    var messages: [HarnessModelMessage] = [
        HarnessModelMessage(role: "user", text: "Please make the requested change.")
    ]
    var confirmedAppliedReplies: [String: [String]] = [:]
    var originalAssistantReplies: [String] = []

    for step in 1...6 {
        let reply = multiFileReply(step: step)
        messages.append(HarnessModelMessage(role: "assistant", text: reply))
        originalAssistantReplies.append(reply)
        confirmedAppliedReplies[reply] = [
            "Sources/Feature\(step).swift",
            "Tests/Feature\(step)Tests.swift"
        ]
        if step == 2 {
            messages.append(HarnessModelMessage(
                role: "user",
                text: "Correction: keep the user's chosen naming and do not rename this feature."
            ))
        }
    }

    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: confirmedAppliedReplies
    )

    #expect(result.compactedAssistantTurnCount == 4)
    #expect(result.didCompact)
    #expect(result.originalUTF8Bytes > result.sentUTF8Bytes)
    #expect(result.removedUTF8Bytes == result.originalUTF8Bytes - result.sentUTF8Bytes)
    #expect(result.sentUTF8Bytes + result.removedUTF8Bytes == result.originalUTF8Bytes)
    #expect(result.messages[0].text == messages[0].text)
    #expect(result.messages[3].text == messages[3].text)
    let projectedAssistantReplies = result.messages
        .filter { $0.role == "assistant" }
        .map(\.text)
    #expect(projectedAssistantReplies[4] == originalAssistantReplies[4])
    #expect(projectedAssistantReplies[5] == originalAssistantReplies[5])

    for step in 1...4 {
        let projectedReply = projectedAssistantReplies[step - 1]
        #expect(projectedReply.contains("historical applied edit receipt"))
        #expect(projectedReply.contains("no proof of current source"))
        #expect(projectedReply.contains("Sources/Feature\(step).swift"))
        #expect(projectedReply.contains("Tests/Feature\(step)Tests.swift"))
        #expect(!projectedReply.contains("long replacement payload for step \(step)"))
    }
}

@Test("a first-body-line path is retained while its payload is compacted")
func firstBodyLinePathIsRetained() {
    let reply = """
    Applying the queued files.
    ```write
    Sources/BodyPath.swift
    \(String(repeating: "let sourceLine = true\n", count: 28))
    ```
    ```edit
    Tests/BodyPathTests.swift
    <<<<<<< SEARCH
    old body-path assertion
    =======
    \(String(repeating: "new body-path assertion\n", count: 20))
    >>>>>>> REPLACE
    ```
    """
    let messages = [
        HarnessModelMessage(role: "assistant", text: reply),
        HarnessModelMessage(role: "assistant", text: "Recent answer one."),
        HarnessModelMessage(role: "assistant", text: "Recent answer two.")
    ]
    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: [reply: [
            "Sources/BodyPath.swift",
            "Tests/BodyPathTests.swift"
        ]]
    )
    let projectedReply = result.messages[0].text

    #expect(result.compactedAssistantTurnCount == 1)
    #expect(projectedReply.contains("```write\nSources/BodyPath.swift\n[historical applied edit receipt"))
    #expect(projectedReply.contains("```edit\nTests/BodyPathTests.swift\n[historical applied edit receipt"))
    #expect(!projectedReply.contains("let sourceLine = true"))
    #expect(!projectedReply.contains("new body-path assertion"))
}

@Test("unseen and rejected replies remain unchanged")
func unseenAndRejectedRepliesRemainUnchanged() {
    let unseenReply = """
    The editor has not applied this yet.
        ```write Sources/Unseen.swift
    \(String(repeating: "unseen payload ", count: 30))
    ```
    """
    let rejectedReply = """
    The requested path was rejected by the executor.
        ```write Sources/Rejected.swift
    \(String(repeating: "rejected payload ", count: 30))
    ```
    """
    let messages = [
        HarnessModelMessage(role: "user", text: "Keep this request."),
        HarnessModelMessage(role: "assistant", text: unseenReply),
        HarnessModelMessage(role: "assistant", text: rejectedReply),
        HarnessModelMessage(role: "assistant", text: "The latest answer stays here.")
    ]

    // The first reply is unseen. The second has a receipt for a different
    // path, which is equivalent to a rejected block for this projection.
    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: [rejectedReply: ["Sources/Different.swift"]]
    )

    #expect(result.messages.map(\.text) == messages.map(\.text))
    #expect(result.originalUTF8Bytes == result.sentUTF8Bytes)
    #expect(result.removedUTF8Bytes == 0)
    #expect(result.compactedAssistantTurnCount == 0)
}

@Test("the latest two assistant turns keep their full payloads")
func recentAssistantPayloadsAreUntouched() {
    let firstReply = multiFileReply(step: 1)
    let secondReply = multiFileReply(step: 2)
    let messages = [
        HarnessModelMessage(role: "assistant", text: "An older non-editing note."),
        HarnessModelMessage(role: "assistant", text: firstReply),
        HarnessModelMessage(role: "assistant", text: secondReply)
    ]
    let receipts = [
        firstReply: ["Sources/Feature1.swift", "Tests/Feature1Tests.swift"],
        secondReply: ["Sources/Feature2.swift", "Tests/Feature2Tests.swift"]
    ]

    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: receipts
    )

    #expect(result.messages[1].text == firstReply)
    #expect(result.messages[2].text == secondReply)
    #expect(result.compactedAssistantTurnCount == 0)
    #expect(result.originalUTF8Bytes == result.sentUTF8Bytes)
}

@Test("user corrections, image data and outside-fence text are preserved")
func userCorrectionsImagesAndOutsideFenceTextArePreserved() {
    let reply = """
    I applied the implementation after your correction. Keep this explanation.
    ```bash
    printf 'do not change this command block'
    ```
    ```write Sources/WithImage.swift
    \(String(repeating: "payload that is safe to compact ", count: 24))
    ```
    Keep the correction visible after the edit.
    """
    let imageData = Data([0, 1, 2, 3, 254, 255])
    let correction = "Actually, use the existing label exactly and preserve this sentence."
    let messages = [
        HarnessModelMessage(role: "user", text: correction),
        HarnessModelMessage(role: "assistant", text: reply, imagePNG: imageData),
        HarnessModelMessage(role: "assistant", text: "Recent answer one."),
        HarnessModelMessage(role: "assistant", text: "Recent answer two.")
    ]

    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: [reply: ["Sources/WithImage.swift"]]
    )
    let projectedReply = result.messages[1].text

    #expect(result.messages[0].text == correction)
    #expect(result.messages[1].imagePNG == imageData)
    #expect(result.originalImageBytes == imageData.count)
    #expect(result.sentImageBytes == imageData.count)
    #expect(projectedReply.hasPrefix("I applied the implementation after your correction. Keep this explanation.\n"))
    #expect(projectedReply.contains("```bash\nprintf 'do not change this command block'\n```"))
    #expect(projectedReply.contains("Keep the correction visible after the edit."))
    #expect(projectedReply.contains("Sources/WithImage.swift"))
    #expect(projectedReply.contains("no proof of current source"))
    #expect(!projectedReply.contains("payload that is safe to compact"))
}

@Test("malformed or nested fences fail safe without changing a reply")
func malformedAndNestedFencesFailSafe() {
    let unclosedReply = """
    ```write Sources/Unclosed.swift
    (String(repeating: "payload ", count: 30))
    """
    let nestedReply = """
    ````write Sources/Nested.swift
    outer payload
    ```swift
    let inner = true
    ```
    ````
    """
    let messages = [
        HarnessModelMessage(role: "assistant", text: unclosedReply),
        HarnessModelMessage(role: "assistant", text: nestedReply),
        HarnessModelMessage(role: "assistant", text: "Recent answer one."),
        HarnessModelMessage(role: "assistant", text: "Recent answer two.")
    ]
    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: [
            unclosedReply: ["Sources/Unclosed.swift"],
            nestedReply: ["Sources/Nested.swift"]
        ]
    )

    #expect(result.messages.map(\.text) == messages.map(\.text))
    #expect(result.originalUTF8Bytes == result.sentUTF8Bytes)
    #expect(result.removedUTF8Bytes == 0)
    #expect(result.compactedAssistantTurnCount == 0)
}

@Test("a receipt that would add bytes does not create prompt overhead")
func noSavingsMeansNoProjectionChange() {
    let tinyReply = "```write a\nx\n```"
    let messages = [
        HarnessModelMessage(role: "assistant", text: tinyReply),
        HarnessModelMessage(role: "assistant", text: "Recent answer one."),
        HarnessModelMessage(role: "assistant", text: "Recent answer two.")
    ]
    let result = HarnessConversationProjection.project(
        messages: messages,
        confirmedAppliedReplies: [tinyReply: ["a"]]
    )

    #expect(result.messages.map(\.text) == messages.map(\.text))
    #expect(result.originalUTF8Bytes == result.sentUTF8Bytes)
    #expect(result.removedUTF8Bytes == 0)
    #expect(!result.didCompact)
}

private func multiFileReply(step: Int) -> String {
    """
    Step \(step) finished. The surrounding narration and this correction must remain.
    ```write
    Sources/Feature\(step).swift
    // long replacement payload for step \(step)
    \(String(repeating: "let retainedContext\(step) = true\n", count: 18))
    ```
    The next file is part of the same applied step.
    ```edit
    Tests/Feature\(step)Tests.swift
    <<<<<<< SEARCH
    old assertion for step \(step)
    =======
    new assertion for step \(step)
    \(String(repeating: "# additional stable test context\n", count: 18))
    >>>>>>> REPLACE
    ```
    The model must still see this outside-fence instruction.
    """
}
