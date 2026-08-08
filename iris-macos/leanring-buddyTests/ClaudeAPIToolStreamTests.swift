//
//  ClaudeAPIToolStreamTests.swift
//  leanring-buddyTests
//
//  Drives ClaudeSSEMessageAccumulator with recorded SSE fixture lines — no
//  network. The traps these pin down: a tool's input JSON arriving split
//  across arbitrary chunk boundaries, pause_turn surviving into the final
//  message so the resend loop can see it, and a web_search_tool_result
//  whose content is an error OBJECT rather than the success LIST.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct ClaudeAPIToolStreamTests {

    private func finalMessage(from lines: [String]) -> ClaudeStreamedMessage {
        var accumulator = ClaudeSSEMessageAccumulator()
        for line in lines { _ = accumulator.consume(line: line) }
        return accumulator.finalize()
    }

    @Test func textAndAForcedToolUseInterleave() {
        let message = finalMessage(from: [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Looking at the error. "}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"propose_fix","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"diagnosis\":\"esbuild blocked\"}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
        ])
        #expect(message.text == "Looking at the error. ")
        #expect(message.stopReason == "tool_use")
        #expect(message.toolUses.count == 1)
        #expect(message.toolUses.first?.name == "propose_fix")
        #expect(message.toolUses.first?.inputObject?["diagnosis"] as? String == "esbuild blocked")
    }

    @Test func inputJSONSplitAcrossArbitraryChunkBoundariesReassembles() {
        let message = finalMessage(from: [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"propose_fix","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"diagnosis\":\"pn"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"pm blocked esb"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"uild\",\"confidence\":\"high\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ])
        let input = message.toolUses.first?.inputObject
        #expect(input?["diagnosis"] as? String == "pnpm blocked esbuild")
        #expect(input?["confidence"] as? String == "high")
    }

    @Test func pauseTurnSurvivesIntoTheFinalMessageWithItsBlocks() {
        let message = finalMessage(from: [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"pnpm allowBuilds\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#,
        ])
        #expect(message.stopReason == "pause_turn")
        // The resend loop sends these blocks back verbatim; they must be
        // present and typed as the API defined them.
        #expect(message.assistantContentBlocks.count == 1)
        #expect(message.assistantContentBlocks.first?["type"] as? String == "server_tool_use")
        // A server_tool_use is not a client tool call.
        #expect(message.toolUses.isEmpty)
    }

    @Test func webSearchErrorObjectContentIsCarriedWithoutAssumingAList() {
        let message = finalMessage(from: [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])
        let block = message.assistantContentBlocks.first
        #expect(block?["type"] as? String == "web_search_tool_result")
        let errorContent = block?["content"] as? [String: Any]
        #expect(errorContent?["error_code"] as? String == "max_uses_exceeded")
    }

    @Test func malformedAndForeignLinesAreSkippedNotFatal() {
        let message = finalMessage(from: [
            "event: message_start",
            "data: {not json at all",
            "",
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"still here"}}"#,
            "data: [DONE]",
        ])
        #expect(message.text == "still here")
    }
}
