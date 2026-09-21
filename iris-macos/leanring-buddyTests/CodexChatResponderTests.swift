//
//  CodexChatResponderTests.swift
//  leanring-buddyTests
//
//  The Codex chat route, tested where it can be tested without a CLI: the
//  prompt bytes and the honesty of what the route claims about itself.
//
//  Running the real thing needs a signed-in `codex` on the machine, which CI
//  does not have — so what is asserted here is everything that is decided
//  BEFORE the process starts, which is also where the interesting mistakes
//  live. The framing preamble in particular is load-bearing: Codex is an agent
//  whose default instinct is to go and investigate with its own shell, and a
//  turn spent doing that against an empty scratch directory comes back empty.
//

import Foundation
import Testing
@testable import Iris

@Suite("Codex chat")
@MainActor
struct CodexChatResponderTests {

    // MARK: What the route admits about itself

    @Test func theRouteDoesNotClaimToSupportChatsClientTools() {
        // `codex exec` has no tool-use wire format. If this ever flips to true
        // without an adapter behind it, chat would silently offer the model
        // three tools it cannot call.
        #expect(CodexChatResponder.supportsChatActionTools == false)
    }

    @Test func theProviderRowSaysSoBeforeAnybodyReliesOnIt() {
        let explanation = AssistantProviderPreference.codex.explanation.lowercased()
        #expect(explanation.contains("can't run things") || explanation.contains("answers only"))
    }

    @Test func theAnswerTimeoutIsTighterThanTheEditLoops() {
        // Chat has a person watching a spinner; Tier C does not. A question
        // that has not been answered in a minute and a half has failed as far
        // as they are concerned.
        #expect(CodexChatResponder.answerTimeoutSeconds <= 120)
        #expect(CodexChatResponder.answerTimeoutSeconds >= 30)
    }

    // MARK: The prompt

    @Test func theFramingTellsTheAgentNotToGoOffAndInvestigate() {
        let preamble = CodexChatResponder.chatFramingPreamble.lowercased()
        #expect(preamble.contains("scratch directory"))
        #expect(preamble.contains("do not use your own shell")
            || preamble.contains("do not use your own shell, file"))
        // And it must NOT inherit Tier C's instruction, which tells the model it
        // can reach a repository through command blocks — there is no
        // repository in a question about somebody's screen.
        #expect(!preamble.contains("repository is reached"))
    }

    @Test func theFramingTellsItNotToClaimActionsItCannotTake() {
        // The failure this prevents: a model that says "I've copied that for
        // you" on a route with no clipboard tool.
        let preamble = CodexChatResponder.chatFramingPreamble.lowercased()
        #expect(preamble.contains("cannot take actions"))
        #expect(preamble.contains("never claim you have done it"))
    }

    @Test func thePromptCarriesTheSystemPromptTheHistoryAndTheQuestionInOrder() {
        let prompt = CodexChatResponder.chatPromptText(
            systemPrompt: "SYSTEM-PROMPT-MARKER",
            conversationHistory: [
                (userPlaceholder: "what is this window", assistantResponse: "it is a terminal"),
            ],
            userPrompt: "and what about this one",
            imageLabels: []
        )

        let systemIndex = try? #require(prompt.range(of: "SYSTEM-PROMPT-MARKER")?.lowerBound)
        let historyIndex = try? #require(prompt.range(of: "what is this window")?.lowerBound)
        let questionIndex = try? #require(prompt.range(of: "and what about this one")?.lowerBound)

        #expect(systemIndex != nil && historyIndex != nil && questionIndex != nil)
        if let systemIndex, let historyIndex, let questionIndex {
            #expect(systemIndex < historyIndex, "the system prompt must come first")
            #expect(historyIndex < questionIndex, "history must precede the new question")
        }
        // The trailing cue names the shape of the turn being waited for.
        #expect(prompt.hasSuffix("Assistant:"))
    }

    @Test func bothHalvesOfEveryPastExchangeSurvive() {
        // A history that dropped the assistant's side would leave the model
        // reading a list of questions nobody answered.
        let prompt = CodexChatResponder.chatPromptText(
            systemPrompt: "s",
            conversationHistory: [
                (userPlaceholder: "first question", assistantResponse: "first answer"),
                (userPlaceholder: "second question", assistantResponse: "second answer"),
            ],
            userPrompt: "third question",
            imageLabels: []
        )
        for fragment in ["first question", "first answer", "second question", "second answer"] {
            #expect(prompt.contains(fragment), "lost: \(fragment)")
        }
    }

    @Test func screenLabelsRideAlongBecauseTheCLITakesUnlabelledFiles() {
        // The Anthropic route labels each screenshot inline with its image
        // block. `codex exec --image` takes bare files, so without this a
        // multi-monitor answer cannot say which screen it means.
        let prompt = CodexChatResponder.chatPromptText(
            systemPrompt: "s",
            conversationHistory: [],
            userPrompt: "what is on my screens",
            imageLabels: ["Built-in Display", "Studio Display"]
        )
        #expect(prompt.contains("Image 1: Built-in Display"))
        #expect(prompt.contains("Image 2: Studio Display"))
    }

    @Test func noImagesMeansNoEmptyImageSection() {
        let prompt = CodexChatResponder.chatPromptText(
            systemPrompt: "s", conversationHistory: [], userPrompt: "q", imageLabels: []
        )
        #expect(!prompt.contains("The attached images"))
    }

    // MARK: How its failures reach the reader

    @Test func aCodexFailureKeepsTheSentenceThatNamesTheFix() async {
        // The Codex route throws the Tier C provider's error type, not a
        // transport one. Those cases carry the actionable sentence; the chat
        // error path's generic branch would replace it with "check your
        // connection", which is the "(… error 8.)" mistake again.
        for missing: MaintainModelProviderError.MissingCredential in [
            .codexCommandNotFound, .codexLoginNotUsable,
        ] {
            let message = MaintainModelProviderError.noCredential(missing).userFacingMessage
            #expect(message.contains("codex"), "did not name the tool: \(message)")
            #expect(!message.contains("check your connection"),
                    "fell back to the generic sentence: \(message)")
        }
    }
}
