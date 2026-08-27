//
//  EditLoopPromptContractTests.swift
//  leanring-buddyTests
//
//  What the Tier C loop TELLS the model — the reply contract it restates every
//  turn, and the environment it describes before the first turn. Two defects
//  found by an edit battery live here, and both are about the prompt disagreeing
//  with the code that runs beside it:
//
//    - The legal-move set had no single source of truth. `onDemandReplyFormatRecap`
//      enumerates all four legal replies and even declares that it "overrides
//      anything above that seems to conflict" — and every runtime turn was then
//      hand-written against a different version of the protocol. Across 28
//      engine turns of a six-task battery, not one mentioned ```write or ```edit,
//      while the steer whose job is to extract an edit from a stalled model told
//      it to "make the edit now — one ```bash command per reply", which is the
//      sed-surgery failure the file-edit channel exists to prevent.
//
//    - The loop hid its own environment from the model and then charged it for
//      not knowing: `.git` is moved aside for the whole run and nothing said so,
//      the model was judged by a test command it was never shown, a constraint
//      about EDITING build files was read as a constraint on reading them, and
//      `rg` is not installed.
//
//  Pure string assertions — no processes, no filesystem, no model.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite struct EditLoopPromptContractTests {

    // MARK: - The legal-move set has one source

    /// Every runtime steer must name the channel the model actually changes
    /// files through. Before the fix the on-demand steers offered a bash
    /// command and DONE, and nothing else, at every one of the six places a
    /// turn is appended.
    @Test("the next-move line names the edit protocol and the repro")
    func nextMoveLineNamesTheEditProtocolAndTheRepro() {
        let afterAnEdit = MaintainTierCFixer.nextMoveLine(
            task: .onDemand(request: "x", kind: .bugFix), theModelHasEditedTheTree: true
        )
        #expect(afterAnEdit.contains("```write"))
        #expect(afterAnEdit.contains("```edit"))
        #expect(afterAnEdit.contains("```bash"))
        #expect(afterAnEdit.contains("BLOCKED"))
        // The repro ask reaches the model AT the moment it decides to finish,
        // not only once, five sections deep in the system prompt.
        #expect(afterAnEdit.contains("```repro"))
        #expect(afterAnEdit.contains("DONE"))
    }

    /// DONE is not a legal move until something has changed — the loop rejects
    /// it and steers — so a steer that offers it before then is inviting the
    /// reply it will refuse.
    @Test("DONE is offered only once the tree has actually changed")
    func doneIsOfferedOnlyAfterAnEdit() {
        let beforeAnyEdit = MaintainTierCFixer.nextMoveLine(
            task: .onDemand(request: "x", kind: .bugFix), theModelHasEditedTheTree: false
        )
        #expect(!beforeAnyEdit.contains("DONE"))
        #expect(beforeAnyEdit.contains("```write"))
        #expect(beforeAnyEdit.contains("BLOCKED"))
    }

    /// A feature is never "verified", so it is never asked for a repro — the
    /// same honesty rule the result type enforces, restated where the model can
    /// act on it.
    @Test("a feature's next-move line never asks for a repro")
    func aFeatureIsNeverAskedForARepro() {
        let featureMoves = MaintainTierCFixer.nextMoveLine(
            task: .onDemand(request: "x", kind: .feature), theModelHasEditedTheTree: true
        )
        #expect(featureMoves.contains("DONE"))
        #expect(!featureMoves.contains("repro"))
    }

    /// The DONE-without-changes steer is the single highest-leverage turn in
    /// the loop, and it used to prescribe the exact failure mode the file-edit
    /// channel was built to end.
    @Test("the DONE-without-changes steer sends the model to the edit blocks")
    func theDoneWithoutChangesSteerNamesTheEditBlocks() {
        let steer = MaintainTierCFixer.doneWithoutAnyChangeSteer(
            task: .onDemand(request: "x", kind: .bugFix)
        )
        #expect(steer.contains("```write"))
        #expect(steer.contains("```edit"))
        #expect(!steer.contains("one ```bash command per reply"))
        #expect(steer.contains("BLOCKED"))
    }

    /// A reply the loop cannot act on, and a command the model already ran,
    /// both used to be answered with "or reply DONE" and nothing about editing.
    @Test("the fallback steers carry the same move list")
    func theFallbackSteersCarryTheSameMoveList() {
        let noMove = MaintainTierCFixer.noActionableReplySteer(
            task: .onDemand(request: "x", kind: .bugFix), theModelHasEditedTheTree: true
        )
        #expect(noMove.contains("```write"))

        let repeated = MaintainTierCFixer.repeatedCommandSteer(
            task: .onDemand(request: "x", kind: .bugFix), theModelHasEditedTheTree: true
        )
        #expect(repeated.contains("```write"))
        #expect(repeated.contains("already ran that exact command"))
    }

    /// The crash path's prompt is the bare `bugFixSystemPrompt` — no file-edit
    /// addendum, no reply-format recap — so a steer naming ```write/```edit
    /// would point it at a protocol it was never taught. Whether it should be
    /// taught that protocol is an open product decision; until it is made, its
    /// wording is pinned here so nobody changes it by accident while unifying
    /// the on-demand ones.
    @Test("the crash path's steers are unchanged")
    func theCrashPathKeepsItsOwnWording() {
        let crashTask = MaintainEditTask.crashFix(evidence: "SIGSEGV")
        #expect(MaintainTierCFixer.nextMoveLine(
            task: crashTask, theModelHasEditedTheTree: true
        ) == "Next command, or DONE.")
        #expect(MaintainTierCFixer.noActionableReplySteer(
            task: crashTask, theModelHasEditedTheTree: true
        ) == "Reply with exactly one ```bash fenced command, or DONE on its own line.")
        #expect(MaintainTierCFixer.repeatedCommandSteer(
            task: crashTask, theModelHasEditedTheTree: true
        ).hasSuffix("Run a DIFFERENT command that makes progress, or reply DONE."))
        #expect(MaintainTierCFixer.doneWithoutAnyChangeSteer(task: crashTask)
            .contains("one ```bash command per reply"))
    }

    // MARK: - The base prompt no longer prescribes shell editing

    /// The on-demand prompts opened with "Read files, grep, and edit in place —
    /// heredocs do NOT work in this sandbox, so write files some other way",
    /// whose only unrejected reading is `sed -i` or `printf >`. Four sections
    /// later the same prompt said not to do that. A live model resolved the
    /// contradiction by preferring the later section; one that prefers the
    /// earlier lands in the documented 56-step sed-surgery failure.
    @Test("the on-demand prompts do not tell the model to edit with the shell")
    func onDemandPromptsDoNotPrescribeShellEditing() {
        for task in [
            MaintainEditTask.onDemand(request: "x", kind: .bugFix),
            MaintainEditTask.onDemand(request: "x", kind: .feature),
        ] {
            let prompt = MaintainTierCFixer.systemPrompt(for: task)
            #expect(!prompt.contains("edit in place"))
            #expect(!prompt.contains("write files some other way"))
            // And the replacement says what the shell IS for.
            #expect(prompt.contains("The jailed shell is for READING"))
        }
    }

    /// The crash path's prompt is deliberately untouched — the other half of
    /// the pending decision above.
    @Test("the crash path's system prompt is unchanged")
    func theCrashPathSystemPromptIsUnchanged() {
        let crashPrompt = MaintainTierCFixer.systemPrompt(for: .crashFix(evidence: "SIGSEGV"))
        #expect(crashPrompt.contains("edit in place"))
        #expect(crashPrompt.contains("write files some other way"))
    }

    // MARK: - The loop declares its own environment

    /// The four facts the loop knew before its first model call and told the
    /// model none of.
    @Test("the sandbox contract states git, tooling, build files, and the verdict commands")
    func theSandboxContractStatesTheRunsOwnFacts() {
        let contract = MaintainTierCFixer.sandboxContractSection(
            buildCommand: "npm run build", testCommand: "npm test"
        )
        #expect(contract.contains("Git history is NOT available"))
        #expect(contract.contains("not a git repository"))
        #expect(contract.contains("`rg` is not installed"))
        #expect(contract.contains("freely READ and grep build files"))
        #expect(contract.contains("npm run build"))
        #expect(contract.contains("npm test"))
    }

    /// A stack that resolves no commands has to say so in words, not leave the
    /// sentence dangling — "Iris runs exactly: build , test ." is worse than
    /// saying nothing.
    @Test("a stack with no build or test command says so plainly")
    func theSandboxContractIsHonestAboutAbsentCommands() {
        let contract = MaintainTierCFixer.sandboxContractSection(
            buildCommand: nil, testCommand: nil
        )
        #expect(contract.contains("no build step"))
        #expect(contract.contains("no test suite"))
    }

    /// And it actually reaches the opening turn, on both paths — the `.git`
    /// strip that motivates it is shared code, so the fact is true for both.
    @Test("the opening turn declares that git is unavailable")
    func theOpeningTurnDeclaresThatGitIsUnavailable() {
        for task in [
            MaintainEditTask.onDemand(request: "the export button does nothing", kind: .bugFix),
            MaintainEditTask.crashFix(evidence: "SIGSEGV"),
        ] {
            let opening = MaintainTierCFixer.openingMessage(
                appSlug: "demo",
                task: task,
                repoMapSummary: "",
                runtimeShapePreflightAddendum: nil,
                sandboxContractSection: MaintainTierCFixer.sandboxContractSection(
                    buildCommand: "cargo build", testCommand: "cargo test"
                )
            )
            #expect(opening.contains("Git history is NOT available"))
            #expect(opening.contains("cargo test"))
        }
    }

    // MARK: - One precedence rule for the verification vocabulary

    /// The build/test vocabulary is resolved twice now — once for the opening
    /// turn, once at the verify step — so the precedence has to live in one
    /// function or the two readings can disagree about more than timing.
    @Test("an explicit override wins the verification-command precedence")
    func anOverrideWinsTheVerificationPrecedence() {
        let override = VerificationCommands(
            buildCommand: "true", testCommand: "grep -q OK health.txt", commandSubdirectory: nil
        )
        let resolved = MaintainTierCFixer.resolvedVerificationCommands(
            override: override,
            appStack: .nextjs,
            repoRootPath: NSTemporaryDirectory(),
            derivedRecipe: nil
        )
        #expect(resolved.buildCommand == "true")
        #expect(resolved.testCommand == "grep -q OK health.txt")
    }
}
