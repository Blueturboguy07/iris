import Foundation
import Testing
@testable import IrisHarness

@Test @MainActor func workflowKeepsDecisionsAcrossLongCodingConversations() async throws {
    let request = "Let me import contacts without losing what I already have."
    let brief = try HarnessTaskBrief(userRequest: request, desiredOutcome: "Merge contacts without losing existing values",
        acceptanceCriteria: [.init(id: "preserve", statement: "Existing values survive a duplicate import")],
        targetedQuestions: [.init(id: "duplicates", prompt: "When a contact already exists, what should happen?",
            options: [.init(id: "keep", label: "Keep my existing information"), .init(id: "replace", label: "Use the imported information")])],
        milestones: [.init(id: "merge", title: "Implement duplicate handling")])
    var captured: [HarnessModelRequest] = []
    let json = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 100_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { input in
            captured.append(input)
            return HarnessModelReply(text: input.phase == .intake ? json : "candidate change")
        }
    let flow = HarnessFeatureWorkflow(modelSession: session)
    _ = try await flow.plan(request: request, repositorySummary: "importer and database adapter")
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.self) { try flow.implementationContext() }
    try flow.recordAnswer(questionID: "duplicates", optionID: "keep", answer: "Keep my existing information")
    let conversation = (0..<100).map { HarnessModelMessage(role: "user", text: "Older investigation result \($0)") }
    _ = try await flow.implementationReply(systemPrompt: "editor protocol", conversation: conversation, maximumOutputTokens: 100)
    #expect(captured.last?.systemPrompt.contains("Keep my existing information") == true)
    #expect(captured.last?.systemPrompt.contains("Existing values survive a duplicate import") == true)
    #expect(captured.first?.route == .planner)
    #expect(captured.last?.route == HarnessImplementationArm.astraLow.route)
    #expect(flow.state?.unresolvedAcceptanceCriteria.count == 1)
}

@Test @MainActor func planningFailureDoesNotBecomePermissionToImplement() async throws {
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in HarnessModelReply(text: "not a plan") }
    let flow = HarnessFeatureWorkflow(modelSession: session)
    await #expect(throws: (any Error).self) {
        _ = try await flow.plan(request: "Search offline", repositorySummary: "search module")
    }
    #expect(flow.state == nil)
    #expect(throws: HarnessFeatureWorkflow.WorkflowError.self) { try flow.implementationContext() }
    #expect(session.ledger.snapshot.admittedCallCount == 1)
}

@Test @MainActor func tooManyQuestionsCannotReachTheEditScreen() async throws {
    let brief = try HarnessTaskBrief(userRequest: "Improve search", desiredOutcome: "Useful search",
        acceptanceCriteria: [.init(id: "find", statement: "Finds matching records")],
        targetedQuestions: (1...3).map { index in
            .init(id: "q\(index)", prompt: "Choice \(index)?", options: [
                .init(id: "a", label: "One"), .init(id: "b", label: "Two")])
        })
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(brief)) as! [String: Any]
    var questions = object["targetedQuestions"] as! [[String: Any]]
    var fourth = questions[0]
    fourth["id"] = "q4"
    questions.append(fourth)
    object["targetedQuestions"] = questions
    let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 20_000),
        maximumDurationNanoseconds: 1_000_000_000) { _ in HarnessModelReply(text: text) }
    let flow = HarnessFeatureWorkflow(modelSession: session)
    await #expect(throws: (any Error).self) {
        _ = try await flow.plan(request: "Improve search", repositorySummary: "search module")
    }
    #expect(flow.state == nil)
}

@Test @MainActor func anOlderPlanCannotReplaceTheLatestRequest() async throws {
    var firstReply: CheckedContinuation<Void, Never>?
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 40_000),
        maximumDurationNanoseconds: 2_000_000_000) { input in
            let payload = try JSONSerialization.jsonObject(with: Data(input.conversation[0].text.utf8)) as! [String: String]
            let request = payload["userRequest"]!
            if request == "Older request" {
                await withCheckedContinuation { firstReply = $0 }
            }
            let brief = try HarnessTaskBrief(userRequest: request, desiredOutcome: request,
                acceptanceCriteria: [.init(id: "check", statement: "Requested behavior works")])
            return HarnessModelReply(text: String(decoding: try JSONEncoder().encode(brief), as: UTF8.self))
        }
    let flow = HarnessFeatureWorkflow(modelSession: session)
    let old = Task { try await flow.plan(request: "Older request", repositorySummary: "module") }
    while firstReply == nil { await Task.yield() }
    _ = try await flow.plan(request: "Latest request", repositorySummary: "module")
    firstReply?.resume()
    await #expect(throws: HarnessFeatureWorkflow.WorkflowError.self) { try await old.value }
    #expect(flow.state?.brief.userRequest == "Latest request")
    #expect(session.ledger.snapshot.admittedCallCount == 2)
}
