//
//  GuidePositionLiveTests.swift
//  leanring-buddyTests
//
//  CAN IRIS ACTUALLY TELL WHERE AN INSTALL IS UP TO?
//
//  `GuideActualPositionFinderTests` proves the parsing, the ordering rule and
//  the cost gate. It proves nothing about the only question that matters: given
//  a real machine and the real prompt, does the model land on the right step?
//  That was shipped in 0.8.1 on unit tests alone, and the founder's doubt was
//  the correct response to that — "i dont know if it is able to check actually
//  what point the setup is in".
//
//  So this builds REAL machine states on disk, gathers facts from them the way
//  the app does, sends the REAL prompt to a REAL model, and checks where it
//  says to resume. Every scenario is a state a reader has actually been in.
//
//  Real, billed calls, so it is off unless asked for:
//
//      IRIS_POSITION_LIVE=1 xcodebuild test -project leanring-buddy.xcodeproj \
//        -scheme leanring-buddy -destination platform=macOS,arch=arm64 \
//        -derivedDataPath .build-check -parallel-testing-enabled NO \
//        -only-testing:leanring-buddyTests/GuidePositionLiveTests
//
//  IRIS_POSITION_LIVE_REPEATS=3 (default 2) — one sample of a stochastic system
//  is an anecdote. IRIS_POSITION_LIVE_OUT=/path for the raw record.
//
//  A NOTE ON WHICH MODEL. In the app the position check runs on the CHAT route
//  (`CompanionManager` wires it to `ClaudeAPI`), because it is a small judgement
//  and that is the route already open. Here it runs against whichever Tier C
//  providers are connected, so the judgement can be measured on more than one
//  model and an arm with a lapsed credential is reported as unavailable rather
//  than quietly skipped.
//

import Foundation
import Testing
@testable import Iris

nonisolated enum PositionLiveGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IRIS_POSITION_LIVE"] == "1"
    }

    static var repeats: Int {
        guard let raw = ProcessInfo.processInfo.environment["IRIS_POSITION_LIVE_REPEATS"],
              let parsed = Int(raw), parsed > 0 else { return 2 }
        return parsed
    }

    static var resultsPath: String {
        ProcessInfo.processInfo.environment["IRIS_POSITION_LIVE_OUT"]
            ?? NSTemporaryDirectory() + "iris-position-live-results.txt"
    }
}

// MARK: - The guide under test

/// The whimprflow macOS branch, exactly as `/api/iris/guides/whimprflow` serves
/// it. Hardcoded rather than fetched so the test does not depend on the network
/// or on prod's current version — and this is the branch every reported
/// position failure happened on.
nonisolated enum WhimprflowMacBranchFixture {
    static let steps: [(index: Int, id: String, title: String, command: String?)] = [
        (0, "open-shell", "Open Terminal", nil),
        (1, "check-tools", "Check your tools", nil),
        (2, "install-pnpm", "Install pnpm", "npm install -g pnpm"),
        (3, "install-rust", "Install Rust", nil),
        (4, "clone", "Download the code", "git clone https://github.com/Blueturboguy07/whimprflow.git"),
        (5, "enter-folder", "Go into the folder", "cd whimprflow"),
        (6, "pin-source", "Pin the source", "git checkout main"),
        (7, "dependencies", "Install dependencies", "cd ui\npnpm install"),
        (8, "models-folder", "Make the models folder", "mkdir -p models"),
        (9, "download-model", "Download the speech model", "curl -L -o models/ggml-base.en.bin https://example/model"),
        (10, "package", "Build the app", "ui/node_modules/.bin/tauri build --bundles app"),
        (11, "install-app", "Put WhimprFlow in Applications",
         "ditto target/release/bundle/macos/WhimprFlow.app /Applications/WhimprFlow.app"),
        (12, "open-app", "Open WhimprFlow", "open /Applications/WhimprFlow.app"),
        (13, "cleanup-engine", "Clean up", nil),
        (14, "permissions", "Grant permissions", nil),
        (15, "finish", "You're done", nil),
    ]
}

// MARK: - A machine state, built for real on disk

/// One situation a reader has actually been in, expressed as files that do or
/// do not exist. Nothing here is a described state — the facts sent to the
/// model are read off a directory this test created.
nonisolated struct PositionScenario: Sendable {
    let name: String
    /// Where saved progress says they are.
    let rememberedStep: Int
    /// Which steps are a defensible place to resume. A range rather than one
    /// number because more than one answer can be right — resuming at the
    /// build or at the dependency install before it are both defensible when
    /// the build output is missing — but most of the sixteen are plainly wrong.
    let acceptableSteps: Set<Int>
    /// Whether Iris should even spend a call. Everything present means there is
    /// nothing to move back for.
    let shouldAskAtAll: Bool
    /// Builds the machine state inside a fresh temporary directory and returns
    /// the facts, read from it.
    let buildFacts: @Sendable (_ workingDirectory: String) -> [GuidePositionFact]
    let why: String
}

nonisolated enum PositionScenarioBattery {

    private static func makeCheckout(in workingDirectory: String) -> String {
        let clonePath = (workingDirectory as NSString).appendingPathComponent("whimprflow")
        try? FileManager.default.createDirectory(
            atPath: (clonePath as NSString).appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return clonePath
    }

    private static func makeFile(_ path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    }

    /// The facts the app would gather, read off whatever is really on disk.
    private static func facts(
        clonePath: String?,
        toolAnswers: [(String, String)],
        appInstalled: Bool
    ) -> [GuidePositionFact] {
        var gathered: [GuidePositionFact] = []
        for (tool, answer) in toolAnswers {
            gathered.append(GuidePositionFact(
                question: "does `\(tool)` respond on this machine", answer: answer
            ))
        }
        if let clonePath {
            let gitPath = (clonePath as NSString).appendingPathComponent(".git")
            gathered.append(GuidePositionFact(
                question: "does the checkout at \(clonePath) exist",
                answer: FileManager.default.fileExists(atPath: gitPath)
                    ? "yes" : GuidePositionEvidence.absent
            ))
            for referenced in ["target/release/bundle/macos/WhimprFlow.app",
                               "models/ggml-base.en.bin",
                               "ui/node_modules"] {
                let full = (clonePath as NSString).appendingPathComponent(referenced)
                gathered.append(GuidePositionFact(
                    question: "does \(referenced) exist in the checkout",
                    answer: FileManager.default.fileExists(atPath: full)
                        ? "yes" : GuidePositionEvidence.absent
                ))
            }
        } else {
            gathered.append(GuidePositionFact(
                question: "does the checkout at ~/whimprflow exist",
                answer: GuidePositionEvidence.absent
            ))
        }
        gathered.append(GuidePositionFact(
            question: "is the finished app (com.whimpr.whimprflow) installed",
            answer: appInstalled ? "yes" : GuidePositionEvidence.absent
        ))
        return gathered
    }

    private static let everyToolPresent = [
        ("git", "yes (2.51.0)"), ("node", "yes (v22.3.0)"),
        ("pnpm", "yes (10.0.0)"), ("cargo", "yes (1.83.0)"),
    ]

    static func all() -> [PositionScenario] {
        [
            // THE REPORTED FAILURE, exactly. Saved progress says step 11
            // (`install-app`), which copies a bundle step 10 builds. The
            // checkout is there, the bundle is not.
            PositionScenario(
                name: "resumed-at-install-with-no-build",
                rememberedStep: 11,
                acceptableSteps: [7, 8, 9, 10],
                shouldAskAtAll: true,
                buildFacts: { workingDirectory in
                    let clone = makeCheckout(in: workingDirectory)
                    makeFile((clone as NSString).appendingPathComponent("models/ggml-base.en.bin"))
                    makeFile((clone as NSString).appendingPathComponent("ui/node_modules/.keep"))
                    return facts(clonePath: clone, toolAnswers: everyToolPresent, appInstalled: false)
                },
                why: "the bundle install-app copies has never been built"
            ),

            // The machine was cleaned, or the clone was never made. Everything
            // after the clone is meaningless.
            PositionScenario(
                name: "resumed-late-with-no-checkout",
                rememberedStep: 11,
                acceptableSteps: [4],
                shouldAskAtAll: true,
                buildFacts: { _ in
                    facts(clonePath: nil, toolAnswers: everyToolPresent, appInstalled: false)
                },
                why: "there is no checkout at all, so the download step is the only place to be"
            ),

            // A prerequisite is missing. Everything downstream will fail.
            PositionScenario(
                name: "missing-prerequisite",
                rememberedStep: 9,
                acceptableSteps: [1, 2, 3],
                shouldAskAtAll: true,
                buildFacts: { workingDirectory in
                    let clone = makeCheckout(in: workingDirectory)
                    return facts(
                        clonePath: clone,
                        toolAnswers: [("git", "yes (2.51.0)"), ("node", "yes (v22.3.0)"),
                                      ("pnpm", "yes (10.0.0)"),
                                      ("cargo", GuidePositionEvidence.absent)],
                        appInstalled: false
                    )
                },
                why: "cargo is missing, so the Rust step is not done however far storage thinks they got"
            ),

            // Dependencies never installed: the build cannot run.
            PositionScenario(
                name: "checkout-but-no-dependencies",
                rememberedStep: 10,
                acceptableSteps: [7, 8, 9],
                shouldAskAtAll: true,
                buildFacts: { workingDirectory in
                    let clone = makeCheckout(in: workingDirectory)
                    return facts(clonePath: clone, toolAnswers: everyToolPresent, appInstalled: false)
                },
                why: "ui/node_modules is absent, so the build step cannot be where they are"
            ),

            // Nothing is missing. There is nothing to move back for, and Iris
            // must not spend a call to be told so.
            PositionScenario(
                name: "everything-present",
                rememberedStep: 12,
                acceptableSteps: [],
                shouldAskAtAll: false,
                buildFacts: { workingDirectory in
                    let clone = makeCheckout(in: workingDirectory)
                    makeFile((clone as NSString)
                        .appendingPathComponent("target/release/bundle/macos/WhimprFlow.app/Contents/Info.plist"))
                    makeFile((clone as NSString).appendingPathComponent("models/ggml-base.en.bin"))
                    makeFile((clone as NSString).appendingPathComponent("ui/node_modules/.keep"))
                    return facts(clonePath: clone, toolAnswers: everyToolPresent, appInstalled: true)
                },
                why: "every prerequisite, artifact and the installed app are all present"
            ),
        ]
    }
}

// MARK: - The run

@Suite(.enabled(if: PositionLiveGate.isEnabled,
                "set IRIS_POSITION_LIVE=1 to make real model calls"))
struct GuidePositionLiveTests {

    @MainActor
    @Test func irisWorksOutWhereAnInstallActuallyIs() async throws {
        let scenarios = PositionScenarioBattery.all()
        var report: [String] = ["=== arms ==="]

        var providers: [(name: String, provider: any MaintainModelProviding)] = []
        for candidate in [("anthropic", AnthropicMaintainProvider() as any MaintainModelProviding),
                          ("codex", CodexMaintainProvider() as any MaintainModelProviding)] {
            let available = candidate.1.isAvailable
            report.append("  \(candidate.0): \(available ? "available" : "NOT AVAILABLE")")
            if available { providers.append((candidate.0, candidate.1)) }
        }
        try #require(!providers.isEmpty, "no provider available — connect a credential first")

        var failures: [String] = []
        report.append("\n=== per run ===")

        for scenario in scenarios {
            // A fresh directory per scenario, so one scenario's files can never
            // be another's evidence.
            let workingDirectory = NSTemporaryDirectory()
                + "iris-position-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(
                atPath: workingDirectory, withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(atPath: workingDirectory) }

            let gatheredFacts = scenario.buildFacts(workingDirectory)
            let evidence = GuidePositionEvidence(facts: gatheredFacts)

            // The cost gate is part of the behaviour under test, not a
            // precondition of it: a scenario where nothing is missing must not
            // reach a model at all.
            let wouldAsk = evidence.isWorthInterpreting
            if wouldAsk != scenario.shouldAskAtAll {
                failures.append("\(scenario.name): would\(wouldAsk ? "" : " not") ask, expected the opposite")
            }
            report.append("  \(scenario.name)")
            report.append("      remembered step \(scenario.rememberedStep) · \(scenario.why)")
            report.append("      asks a model: \(wouldAsk) (expected \(scenario.shouldAskAtAll))")
            guard wouldAsk else { continue }

            let userMessage = GuideActualPositionFinder.promptText(
                guideName: "WhimprFlow",
                steps: WhimprflowMacBranchFixture.steps,
                evidence: evidence
            )

            var usableVerdictsThisScenario = 0
            for provider in providers {
                for attempt in 1...PositionLiveGate.repeats {
                    let startedAt = Date()
                    var reply = ""
                    do {
                        reply = try await provider.provider.respond(
                            systemPrompt: GuideActualPositionFinder.systemPrompt,
                            conversation: [MaintainChatTurn(role: "user", text: userMessage)],
                            maximumOutputTokens: 200
                        )
                    } catch {
                        report.append("      \(provider.name) #\(attempt): INCONCLUSIVE — \(error)")
                        continue
                    }
                    let seconds = Date().timeIntervalSince(startedAt)
                    guard let verdict = GuideActualPositionFinder.verdict(
                        fromReply: reply, numberOfSteps: WhimprflowMacBranchFixture.steps.count
                    ) else {
                        // DECLINING IS A DESIGNED OUTCOME, NOT A DEFECT. The
                        // prompt asks for "unknown" when the facts do not
                        // settle it, and an unknown leaves saved progress
                        // exactly as it was — merely imperfect, never wrong.
                        // Scoring it as a failure would push the prompt toward
                        // guessing, which is the behaviour this whole feature
                        // exists to remove.
                        //
                        // It is still tracked: a check that declines EVERY time
                        // is useless even though it is safe, and that is caught
                        // below by requiring at least one usable verdict per
                        // scenario.
                        report.append("      \(provider.name) #\(attempt): declined (safe) — "
                                      + reply.prefix(110).replacingOccurrences(of: "\n", with: " "))
                        continue
                    }
                    usableVerdictsThisScenario += 1

                    let movedCorrectly = GuideActualPositionFinder.shouldMove(
                        from: scenario.rememberedStep, to: verdict.stepIndex
                    )
                    let landedWell = scenario.acceptableSteps.contains(verdict.stepIndex)
                    let verdictLabel = (movedCorrectly && landedWell) ? "PASS" : "FAIL"
                    report.append("      \(provider.name) #\(attempt): step \(verdict.stepIndex) "
                                  + "[\(WhimprflowMacBranchFixture.steps[verdict.stepIndex].id)] "
                                  + String(format: "%.1fs ", seconds) + verdictLabel)
                    report.append("          why: \(verdict.reason)")
                    if verdictLabel == "FAIL" {
                        failures.append(
                            "\(scenario.name)/\(provider.name)#\(attempt): picked step "
                            + "\(verdict.stepIndex), acceptable were "
                            + "\(scenario.acceptableSteps.sorted())"
                        )
                    }
                }
            }

            // A finder that always declines is safe and worthless. At least one
            // sample has to have actually answered — otherwise this scenario
            // proves only that Iris knows how to say "I don't know".
            if usableVerdictsThisScenario == 0 {
                failures.append(
                    "\(scenario.name): every sample declined — the check never helps here"
                )
            }
        }

        if !failures.isEmpty {
            report.append("\n=== failures ===")
            for failure in failures { report.append("  \(failure)") }
        } else {
            report.append("\n=== every scenario landed on a defensible step ===")
        }

        let text = report.joined(separator: "\n")
        try? text.write(toFile: PositionLiveGate.resultsPath, atomically: true, encoding: .utf8)
        print(text)
        let summary = "position failures (report at \(PositionLiveGate.resultsPath)): "
            + failures.joined(separator: "; ")
        #expect(failures.isEmpty, "\(summary)")
    }
}
