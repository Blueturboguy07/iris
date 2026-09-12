import Foundation
import Testing
@testable import IrisHarness

@Test("historical repeated observations are bounded without dropping turns")
func repeatedToolObservationsAreBounded() {
    let opening = "TASK CONTRACT: accepted brief; user request: keep the chosen label."
        + " User decision: preserve the existing name."
    var messages = [HarnessModelMessage(role: "user", text: opening)]
    let repeatedOutput = String(repeating: "process-state-line\n", count: 160)

    for index in 0..<9 {
        messages.append(HarnessModelMessage(
            role: "assistant",
            text: "Inspecting the next system observation \(index)."
        ))
        messages.append(HarnessModelMessage(
            role: "user",
            text: "Command exit 0. Output:\n\(repeatedOutput)\n\nNext: ONE read command."
        ))
    }

    let projection = HarnessCodexConversationBudget.project(messages)
    let projected = projection.messages
    #expect(projection.sentUTF8Bytes <= HarnessCodexConversationBudget.conversationByteTarget)
    #expect(projected.count == messages.count)
    #expect(projected[0].text == opening)
    #expect(projected[1].text == messages[1].text)
    #expect(projected[2].text.contains("truncated; reread if needed"))
    #expect(projected[2].text.contains("exit code 0 retained"))

    let latestActionIndices = stride(from: projected.count - 1, through: 1, by: -2)
        .prefix(4)
    for index in latestActionIndices {
        #expect(projected[index].text == messages[index].text)
    }
}

@Test("errors, negative evidence and decisions remain verbatim")
func negativeEvidenceAndUserDecisionsAreNotSummarized() {
    let decision = "Decision: keep the user's accepted brief and do not rename the feature."
    let error = "Command exit 1. Output:\nNo such file or directory\n\nNext: ONE read command."
    let successful = "Command exit 0. Output:\n" + String(repeating: "stable\n", count: 1_100)
        + "\n\nNext: ONE read command."
    let messages = [
        HarnessModelMessage(role: "user", text: "Accepted brief: repair the feature."),
        HarnessModelMessage(role: "assistant", text: "I will inspect the tree."),
        HarnessModelMessage(role: "user", text: error),
        HarnessModelMessage(role: "user", text: decision),
        HarnessModelMessage(role: "assistant", text: "A later observation."),
        HarnessModelMessage(role: "user", text: successful),
        HarnessModelMessage(role: "assistant", text: "Recent answer one."),
        HarnessModelMessage(role: "user", text: successful),
        HarnessModelMessage(role: "assistant", text: "Recent answer two."),
        HarnessModelMessage(role: "user", text: successful),
        HarnessModelMessage(role: "assistant", text: "Recent answer three."),
        HarnessModelMessage(role: "user", text: successful)
    ]

    let projection = HarnessCodexConversationBudget.project(messages)
    let projected = projection.messages
    #expect(projected[0].text == messages[0].text)
    #expect(projected[2].text == error)
    #expect(projected[3].text == decision)
    #expect(projected[5].text == successful)
    #expect(projected[7].text == successful)
    #expect(projected[9].text == successful)
    #expect(projected[11].text == successful)
}

@Test("source-like success output is compacted instead of treated as failure")
func sourceLikeSuccessOutputDoesNotBlockCompaction() {
    var messages = [HarnessModelMessage(role: "user", text: "Accepted brief: inspect the implementation.")]
    for index in 0..<9 {
        messages.append(HarnessModelMessage(role: "assistant", text: "Inspecting source " + String(index) + "."))
        let output = "return false // source result " + String(index) + "\n"
            + "throw new Error(\"source example " + String(index) + "\")\n"
            + String(repeating: "stable source line " + String(index) + "\n", count: 180)
        messages.append(HarnessModelMessage(
            role: "user",
            text: "Command exit 0. Output:\n" + output + "\nNext: ONE read command."
        ))
    }

    let projection = HarnessCodexConversationBudget.project(messages)
    #expect(projection.compactedObservationTurnCount > 0)
    #expect(projection.messages[2].text.contains("historical tool output truncated"))
    #expect(projection.messages[2].text.contains("exit code 0 retained"))
}

@Test("explicit diagnostic lines remain protected")
func explicitDiagnosticLinesRemainProtected() {
    var messages = [HarnessModelMessage(role: "user", text: "Accepted brief: investigate the failure.")]
    for index in 0..<4 {
        messages.append(HarnessModelMessage(role: "assistant", text: "Result " + String(index) + "."))
        let output = "Error: command " + String(index) + " failed\n" + String(repeating: "diagnostic detail\n", count: 500)
        messages.append(HarnessModelMessage(
            role: "user",
            text: "Command exit 0. Output:\n" + output + "\nNext: ONE read command."
        ))
    }

    let projection = HarnessCodexConversationBudget.project(messages)
    #expect(projection.targetWasExceeded)
    #expect(projection.messages[2].text.contains("Error: command 0 failed"))
    #expect(!projection.messages[2].text.contains("historical tool output truncated"))
}

@Test("different numeric observations are not conflated as duplicates")
func numericObservationsStayDistinct() {
    var messages = [HarnessModelMessage(role: "user", text: "Accepted brief: inspect the process state.")]
    for index in 0..<9 {
        let output = String(repeating: "state-\(index)-line\n", count: 220)
        messages.append(HarnessModelMessage(role: "assistant", text: "Inspecting probe \(index)."))
        messages.append(HarnessModelMessage(
            role: "user",
            text: "Command exit 0. Output:\n\(output)\n\nNext: ONE read command."
        ))
    }

    let projection = HarnessCodexConversationBudget.project(messages)
    let projected = projection.messages
    #expect(projection.sentUTF8Bytes <= HarnessCodexConversationBudget.conversationByteTarget)
    #expect(projected[2].text.contains("outside the recent action-result window"))
    #expect(!projected[2].text.contains("matches a later observation"))
    #expect(projected[18].text == messages[18].text)
}

@Test("protected negative evidence may exceed the soft target and stays honest")
func protectedEvidenceCanExceedSoftTarget() {
    var messages = [HarnessModelMessage(role: "user", text: "Accepted brief: investigate the failure.")]
    var errorMessages: [String] = []
    for index in 0..<4 {
        let error = "Command exit 1. Output:\nerror-\(index) diagnostic detail\n"
            + String(repeating: "failure evidence line\n", count: 500)
            + "\nNext: ONE read command."
        errorMessages.append(error)
        messages.append(HarnessModelMessage(role: "assistant", text: "Result pair \(index)."))
        messages.append(HarnessModelMessage(role: "user", text: error))
    }

    let projection = HarnessCodexConversationBudget.project(messages)
    let projected = projection.messages
    #expect(projection.targetWasExceeded)
    #expect(projection.sentUTF8Bytes > HarnessCodexConversationBudget.conversationByteTarget)
    #expect(projected.count == messages.count)
    for (index, error) in errorMessages.enumerated() {
        #expect(projected[(index * 2) + 2].text == error)
    }
}

@Test("bounded projection keeps message order and malformed results untouched")
func malformedResultsStayOrderedAndUnchanged() {
    let malformed = "Command exit 0. Output is not in the adapter result shape."
    let incomplete = "Command exit 0. Output:\nmissing next-move trailer"
    let messages = [
        HarnessModelMessage(role: "user", text: "Keep the latest request."),
        HarnessModelMessage(role: "assistant", text: "Historical note."),
        HarnessModelMessage(role: "user", text: malformed),
        HarnessModelMessage(role: "assistant", text: "Recent answer."),
        HarnessModelMessage(role: "user", text: "Decision: preserve this exact behavior."),
        HarnessModelMessage(role: "user", text: incomplete)
    ]

    let projection = HarnessCodexConversationBudget.project(messages)
    let projected = projection.messages
    #expect(projected.map(\.role) == messages.map(\.role))
    #expect(projected.map(\.text) == messages.map(\.text))
}
