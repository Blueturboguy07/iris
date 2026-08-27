//
//  ClaudeSSEMessageAccumulator.swift
//  leanring-buddy
//
//  A pure, line-at-a-time reconstruction of one Messages-API response from
//  its SSE stream: text deltas for progressive display, tool_use blocks with
//  their input JSON reassembled from input_json_delta fragments, and the
//  assistant's full content blocks — which the pause_turn resend loop needs
//  to send back verbatim. Pure so the tests can drive it with recorded
//  fixture lines instead of a network.
//
//  One trap worth naming: a web_search_tool_result block's `content` is a
//  LIST on success and an ERROR OBJECT on failure. Nothing here assumes
//  either shape — blocks are carried opaquely — but any caller that walks
//  results must not.
//

import Foundation

struct ClaudeToolUse: Equatable {
    let identifier: String
    let name: String
    /// The reassembled input object. Equatable via its JSON text.
    let inputJSONText: String

    var inputObject: [String: Any]? {
        guard let data = inputJSONText.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct ClaudeStreamedMessage {
    let text: String
    let toolUses: [ClaudeToolUse]
    let stopReason: String?
    /// The assistant's content blocks as the API defined them, for resending
    /// on pause_turn. Includes server_tool_use and tool-result blocks.
    let assistantContentBlocks: [[String: Any]]

    /// Every web search the model ran, as the queries it issued.
    ///
    /// The blocks are already kept for pause_turn resends, so this needs no
    /// extra parsing — but it is the only way to answer the question that
    /// matters once Tier C has a search tool: does the model REACH for it when
    /// it should? A tool the model never calls is not a capability.
    var webSearchQueries: [String] {
        assistantContentBlocks.compactMap { block in
            guard block["type"] as? String == "server_tool_use",
                  block["name"] as? String == "web_search",
                  let input = block["input"] as? [String: Any],
                  let query = input["query"] as? String else { return nil }
            return query
        }
    }

    /// Whether the model searched the web at all.
    var didSearchTheWeb: Bool { !webSearchQueries.isEmpty }
}

struct ClaudeSSEMessageAccumulator {

    private var text = ""
    private var stopReason: String?
    /// Blocks under construction, keyed by stream index.
    private var openBlocks: [Int: [String: Any]] = [:]
    private var openBlockJSONFragments: [Int: String] = [:]
    private var finishedBlocks: [(index: Int, block: [String: Any])] = []

    /// Feeds one SSE line. Returns freshly arrived display text, if any.
    mutating func consume(line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let eventType = event["type"] as? String else {
            return nil
        }

        switch eventType {
        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any] else { return nil }
            openBlocks[index] = block
            openBlockJSONFragments[index] = ""
            return nil

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return nil }
            switch deltaType {
            case "text_delta":
                guard let chunk = delta["text"] as? String else { return nil }
                text += chunk
                if var block = openBlocks[index] {
                    block["text"] = ((block["text"] as? String) ?? "") + chunk
                    openBlocks[index] = block
                }
                return chunk
            case "input_json_delta":
                if let fragment = delta["partial_json"] as? String {
                    openBlockJSONFragments[index, default: ""] += fragment
                }
                return nil
            default:
                return nil
            }

        case "content_block_stop":
            guard let index = event["index"] as? Int,
                  var block = openBlocks.removeValue(forKey: index) else { return nil }
            let fragments = openBlockJSONFragments.removeValue(forKey: index) ?? ""
            if !fragments.isEmpty,
               let data = fragments.data(using: .utf8),
               let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                block["input"] = input
            }
            finishedBlocks.append((index: index, block: block))
            return nil

        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return nil

        default:
            return nil
        }
    }

    func finalize() -> ClaudeStreamedMessage {
        // Blocks that never saw their stop event (truncated stream) still
        // count — better a partial answer than a silent nil.
        var allBlocks = finishedBlocks
        for (index, block) in openBlocks {
            allBlocks.append((index: index, block: block))
        }
        let ordered = allBlocks.sorted { $0.index < $1.index }.map(\.block)

        let toolUses: [ClaudeToolUse] = ordered.compactMap { block in
            guard (block["type"] as? String) == "tool_use",
                  let identifier = block["id"] as? String,
                  let name = block["name"] as? String else { return nil }
            let inputText: String
            if let input = block["input"],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                inputText = String(decoding: data, as: UTF8.self)
            } else {
                inputText = "{}"
            }
            return ClaudeToolUse(identifier: identifier, name: name, inputJSONText: inputText)
        }

        return ClaudeStreamedMessage(
            text: text,
            toolUses: toolUses,
            stopReason: stopReason,
            assistantContentBlocks: ordered
        )
    }
}
