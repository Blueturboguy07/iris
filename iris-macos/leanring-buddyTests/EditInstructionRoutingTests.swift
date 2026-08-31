//
//  EditInstructionRoutingTests.swift
//  leanring-buddyTests
//
//  Founder report: "iris no longer fixes bugs when i ask it to if an app from
//  publik is frontmost ... when i try to type it in the normal text box and
//  enter it points at some bullshit."
//
//  Two causes, one symptom. The first was a wiped provenance store, which made
//  every app read as not-locally-editable so the chips vanished. The second is
//  this: `editInstructionKind` matched six exact prefixes — "fix a bug", "add a
//  feature" and four near-variants — so any natural phrasing fell through to
//  chat, and chat points at things. The feature was chip-only in practice.
//
//  Widening is safe at this call site and nowhere else: the caller has already
//  established that a catalog app Iris may edit locally is FRONTMOST, and the
//  card still makes the reader confirm, so a wrong guess costs a click.
//

import Foundation
import Testing
@testable import Iris

@Suite struct EditInstructionRoutingTests {

    /// The exact sentences that used to fall through to chat and get answered
    /// with a point at something irrelevant.
    @Test("a natural bug report routes to an edit, not to chat")
    func naturalBugReportsRouteToTheEditFlow() {
        for message in [
            "fix the export crash",
            "fix the timeline scrolling",
            "make the export button bigger",
            "remove the watermark",
            "change the default font",
            "stop it from crashing on launch",
            "disable the auto-update prompt",
            "rename the Adjust tab",
            "increase the max volume",
        ] {
            #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: message) == .bugFix,
                    "fell through to chat: \(message)")
        }
    }

    @Test("a request for new behaviour preselects feature")
    func newBehaviourPreselectsFeature() {
        for message in [
            "add dark mode",
            "add a feature that exports to mp4",
            "build a settings panel",
            "support webm files",
            "let me pin a clip",
        ] {
            #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: message) == .feature,
                    "not read as a feature: \(message)")
        }
    }

    /// The chip openers state their kind outright and must keep winning, so a
    /// chip tap is never reinterpreted by the verb rule.
    @Test("the chip openers still decide their own kind")
    func chipOpenersStillWin() {
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: "fix a bug in WhimprFlow") == .bugFix)
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: "add a feature to WhimprFlow") == .feature)
    }

    /// THE GUARD THAT KEEPS WIDENING HONEST. A question stays a question even
    /// when it contains a change verb — otherwise asking Iris about an app
    /// would start editing it.
    @Test("a question is never an edit instruction")
    func questionsStayOnTheChatPipeline() {
        for message in [
            "what does this button do",
            "why does the export fail?",
            "how do i fix the export crash",
            "can you fix the export crash?",
            "should i remove the watermark",
            "is the timeline supposed to scroll",
            "explain the adjust tab",
            "tell me how this works",
            "does it support webm",
        ] {
            #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: message) == nil,
                    "a question was routed into an edit run: \(message)")
        }
    }

    /// Anything that is not an instruction to change the app stays chat. The
    /// verb has to OPEN the message — a passing mention is not a request.
    @Test("non-instructions stay on chat")
    func nonInstructionsStayOnChat() {
        for message in [
            "",
            "   ",
            "point at what i should click",
            "the export is broken",
            "i think there's a bug here",
            "this app keeps crashing",
            "nice work on the timeline",
        ] {
            #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: message) == nil,
                    "routed into an edit run: \(message)")
        }
    }
}
