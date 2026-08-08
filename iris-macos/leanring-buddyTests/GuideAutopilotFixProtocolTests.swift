//
//  GuideAutopilotFixProtocolTests.swift
//  leanring-buddyTests
//
//  The fix protocol decoded from canned tool_use blocks — no network. The
//  test that matters most is the host guard: a proposed fix reaching a host
//  the guide never uses must not survive decoding as runnable, no matter
//  how plausible its diagnosis reads. That is the structural answer to the
//  api.publik.local incident.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct GuideAutopilotFixProtocolTests {

    private static func context(
        priorAttempts: [String] = [],
        guideHosts: Set<String> = ["github.com", "registry.npmjs.org"]
    ) -> GuideAutopilotFailureContext {
        GuideAutopilotFailureContext(
            guideSlug: "whimprflow",
            guideVersion: 3,
            appName: "WhimprFlow",
            platformLabel: "macOS",
            stepIdentifier: "package",
            stepTitle: "Build the app",
            stepBody: "The first build compiles Whisper, so it takes a while.",
            verifierLabel: "A WhimprFlow.app appears in the bundle folder",
            commandAsRun: "ui/node_modules/.bin/tauri build --bundles app",
            exitStatus: 1,
            scrubbedOutputTail: "[ERROR] ENOENT: no such file or directory, lstat '/Users/x/WhimprFlow/ui/ui'",
            shellPath: "/bin/zsh",
            workingDirectory: "/Users/x/WhimprFlow",
            operatingSystemVersion: "macOS 15.7",
            architecture: "arm64",
            knownToolVersions: ["node 22.1.0", "pnpm 11.18.0"],
            priorAttempts: priorAttempts,
            hostsTheGuideAlreadyReaches: guideHosts
        )
    }

    private static func message(withToolInput inputJSON: String) -> ClaudeStreamedMessage {
        var accumulator = ClaudeSSEMessageAccumulator()
        let escaped = inputJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        for line in [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"propose_fix","input":{}}}"#,
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\(escaped)\"}}",
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ] {
            _ = accumulator.consume(line: line)
        }
        return accumulator.finalize()
    }

    @Test func aWellFormedRunCommandFixDecodes() {
        let message = Self.message(withToolInput:
            #"{"diagnosis":"pnpm blocked esbuild's install script.","confidence":"high","retryTheOriginalCommandAfterwards":true,"action":{"kind":"runACommand","command":"pnpm approve-builds","whatItDoes":"Approves esbuild's install script."}}"#
        )
        let fix = GuideAutopilotFixProposer.decodedFix(
            from: message, cameFromWebSearch: false, context: Self.context()
        )
        #expect(fix?.retryTheOriginalCommandAfterwards == true)
        #expect(fix?.action == .runACommand(
            command: "pnpm approve-builds",
            whatItDoes: "Approves esbuild's install script."
        ))
    }

    @Test func aFixReachingAnOffGuideHostIsNeutralised() {
        let message = Self.message(withToolInput:
            #"{"diagnosis":"The api server is unreachable.","confidence":"medium","retryTheOriginalCommandAfterwards":true,"action":{"kind":"runACommand","command":"curl https://api.publik.local/health","whatItDoes":"Checks the publik api."}}"#
        )
        let fix = GuideAutopilotFixProposer.decodedFix(
            from: message, cameFromWebSearch: false, context: Self.context()
        )
        guard case .cannotFixThis(let reason)? = fix?.action else {
            Issue.record("an off-guide host must not survive as a runnable fix; got \(String(describing: fix))")
            return
        }
        #expect(reason.contains("api.publik.local"))
    }

    @Test func aFixWithinGuideHostsPassesTheHostGuard() {
        let message = Self.message(withToolInput:
            #"{"diagnosis":"The clone is missing.","confidence":"high","retryTheOriginalCommandAfterwards":true,"action":{"kind":"runACommand","command":"git clone https://github.com/Blueturboguy07/WhimprFlow.git","whatItDoes":"Clones the repo again."}}"#
        )
        let fix = GuideAutopilotFixProposer.decodedFix(
            from: message, cameFromWebSearch: false, context: Self.context()
        )
        guard case .runACommand? = fix?.action else {
            Issue.record("a github.com fix should pass; got \(String(describing: fix))")
            return
        }
    }

    @Test func cannotFixThisAndAskTheReaderDecode() {
        let cannot = Self.message(withToolInput:
            #"{"diagnosis":"Xcode is missing.","confidence":"high","retryTheOriginalCommandAfterwards":false,"action":{"kind":"cannotFixThis","reason":"Xcode must be installed by hand."}}"#
        )
        #expect(GuideAutopilotFixProposer.decodedFix(
            from: cannot, cameFromWebSearch: false, context: Self.context()
        )?.action == .cannotFixThis(reason: "Xcode must be installed by hand."))

        let ask = Self.message(withToolInput:
            #"{"diagnosis":"The dialog needs a click.","confidence":"medium","retryTheOriginalCommandAfterwards":true,"action":{"kind":"askTheReaderToDoSomething","instruction":"Click Install on the dialog that just opened."}}"#
        )
        #expect(GuideAutopilotFixProposer.decodedFix(
            from: ask, cameFromWebSearch: false, context: Self.context()
        )?.action == .askTheReaderToDoSomething(
            instruction: "Click Install on the dialog that just opened."
        ))
    }

    @Test func malformedProposalsDecodeToNilNotACrash() {
        let missingAction = Self.message(withToolInput:
            #"{"diagnosis":"Something.","confidence":"low","retryTheOriginalCommandAfterwards":false}"#
        )
        #expect(GuideAutopilotFixProposer.decodedFix(
            from: missingAction, cameFromWebSearch: false, context: Self.context()
        ) == nil)

        let unknownKind = Self.message(withToolInput:
            #"{"diagnosis":"Something.","confidence":"low","retryTheOriginalCommandAfterwards":false,"action":{"kind":"reformatTheDisk"}}"#
        )
        #expect(GuideAutopilotFixProposer.decodedFix(
            from: unknownKind, cameFromWebSearch: false, context: Self.context()
        ) == nil)

        var empty = ClaudeSSEMessageAccumulator()
        #expect(GuideAutopilotFixProposer.decodedFix(
            from: empty.finalize(), cameFromWebSearch: true, context: Self.context()
        ) == nil, "no proposal at rung (b) is a legitimate escalate-to-reader answer")
    }

    @Test func theFailureReportCarriesTheCommandAndPriorAttempts() {
        let report = GuideAutopilotFixProposer.failureReport(
            for: Self.context(priorAttempts: ["pnpm approve-builds → still failed"])
        )
        #expect(report.contains("ui/node_modules/.bin/tauri build --bundles app"))
        #expect(report.contains("ENOENT"))
        #expect(report.contains("do not repeat"))
        #expect(report.contains("pnpm approve-builds → still failed"))
    }
}
