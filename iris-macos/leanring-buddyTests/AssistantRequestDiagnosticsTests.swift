import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct AssistantRequestDiagnosticsTests {
    @Test func fundedFailureRetainsOnlyItsKnownCodeAndRoute() {
        let response = Data(#"{"error":"upstream_error","message":"private-response-body"}"#.utf8)
        #expect(AssistantRequestDiagnostics.traceLine(route: .funded, statusCode: 400, responseData: response)
                == "assistant/request: failed route=funded status=400 class=upstream_error")
    }

    @Test func nestedAnthropicErrorTypeIsRecognizedWithoutItsMessage() {
        let response = Data(#"{"error":{"type":"invalid_request_error","message":"private-prompt"},"request_id":"private-id"}"#.utf8)
        #expect(AssistantRequestDiagnostics.traceLine(route: .anthropicKey, statusCode: 400, responseData: response)
                == "assistant/request: failed route=anthropic-key status=400 class=invalid_request_error")
    }

    @Test(arguments: [
        #"{"error":"private credential"}"#,
        #"{"error":{"type":"private credential"}}"#,
        #"{"message":"invalid_request_error"}"#,
        #"{"error":"upstream_error\nprivate-prompt"}"#,
        "not JSON", "[]", "{}",
    ])
    func unknownAndFreeFormErrorsNeverBecomeLogText(_ response: String) {
        #expect(AssistantRequestDiagnostics.errorClass(in: Data(response.utf8)) == "unclassified")
    }

    @Test func oversizedErrorBodiesAreNotParsed() {
        #expect(AssistantRequestDiagnostics.errorClass(in: Data(repeating: 32, count: 65_537)) == "unclassified")
    }
}
