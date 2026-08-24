//
//  OnDemandEditEvidenceDisciplineTests.swift
//  leanring-buddyTests
//
//  The four guards added after the WhimprFlow post-mortem, where five
//  consecutive on-demand runs each reported a fixed bug and left the user's
//  complaint exactly where it was.
//
//  What actually happened: the installed app was ad-hoc signed, so its
//  designated requirement was a bare hash of the binary. macOS records that
//  requirement when a permission is granted, so every rebuild made the app a
//  different client to TCC and silently dropped the Accessibility grant —
//  while System Settings kept showing the switch on. The cause was never in
//  the source, and every run looked only at the source. Each then "verified"
//  its change with a grep for the line it had just written, and wrote its
//  invented cause into memory, where the next run read it as established.
//
//  These tests pin the four places that let that happen.
//

import Foundation
import Testing
@testable import Iris

@Suite struct OnDemandEditEvidenceDisciplineTests {

    // MARK: - A repro may not be a look at its own diff

    @Test("the repro that shipped five false verifications is rejected")
    func rejectsTheWhimprFlowTautology() {
        // Verbatim from run 5. It fails before the patch, passes after it, and
        // fails on revert — three green legs, and no evidence whatsoever.
        let repro = #"grep -q "useEffect" ui/src/hub/SettingsPane.tsx && grep -q "no relaunch needed" ui/src/hub/SettingsPane.tsx"#
        let reason = MaintainTierCFixer.reproMerelyReReadsTheChange(
            repro, changedPaths: ["ui/src/hub/SettingsPane.tsx"]
        )
        #expect(reason != nil)
        #expect(reason?.contains("SettingsPane.tsx") == true)
    }

    @Test("a bare file name counts as naming the file")
    func rejectsTautologyByBasename() {
        let reason = MaintainTierCFixer.reproMerelyReReadsTheChange(
            "cd ui/src/hub && grep -q stable_identity Onboarding.tsx",
            changedPaths: ["ui/src/hub/Onboarding.tsx"]
        )
        #expect(reason != nil)
    }

    @Test("a check that runs the code is kept, even when it names an edited file")
    func keepsRealChecksThatMentionEditedFiles() {
        #expect(MaintainTierCFixer.reproMerelyReReadsTheChange(
            "cargo test --quiet signing::tests::adhoc_is_unstable",
            changedPaths: ["src-tauri/src/signing.rs"]
        ) == nil)
        #expect(MaintainTierCFixer.reproMerelyReReadsTheChange(
            "node scripts/check.js && grep -q ok out.txt",
            changedPaths: ["scripts/check.js"]
        ) == nil)
    }

    @Test("a grep of build output is kept — generated files are not touched paths")
    func keepsGrepOfGeneratedOutput() {
        #expect(MaintainTierCFixer.reproMerelyReReadsTheChange(
            #"grep -q "stable_identity" ui/dist/assets/index.js"#,
            changedPaths: ["ui/src/hub/api.ts"]
        ) == nil)
    }

    @Test("a repro touching nothing the patch wrote is kept")
    func keepsUnrelatedRepro() {
        #expect(MaintainTierCFixer.reproMerelyReReadsTheChange(
            "test \"$(cat /tmp/whimpr-probe-result)\" = granted",
            changedPaths: ["src-tauri/src/paste.rs"]
        ) == nil)
    }

    // MARK: - The model sees both ends of a file, not just the tail

    @Test("short output is passed through untouched")
    func shortOutputIsUnchanged() {
        #expect(MaintainTierCFixer.outputForModel("hello") == "hello")
    }

    @Test("long output keeps the head as well as the tail")
    func longOutputKeepsBothEnds() {
        let raw = "TOP-OF-FILE\n" + String(repeating: "x", count: 9000) + "\nEND-OF-FILE"
        let shown = MaintainTierCFixer.outputForModel(raw)
        // The head is what tail-only truncation used to throw away: imports,
        // declarations, the top of the function under investigation.
        #expect(shown.hasPrefix("TOP-OF-FILE"))
        #expect(shown.hasSuffix("END-OF-FILE"))
        #expect(shown.contains("omitted"))
        #expect(shown.count < raw.count)
    }

    // MARK: - The repo's own build instructions reach the model

    @Test("the README section that names the trap is quoted")
    func quotesTheBuildSection() throws {
        let root = NSTemporaryDirectory() + "iris-doc-excerpt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Trimmed from WhimprFlow's actual README.
        try """
        # WhimprFlow

        Dictation, locally.

        ## Build (macOS)

        Requires Rust (stable), Node + pnpm.

        Or a signed .app bundle — build ONLY via `tauri build`; a bare `cargo
        build` + manual codesign will NOT bundle the UI and can drop TCC grants.

        ## License

        MIT.
        """.write(toFile: root + "/README.md", atomically: true, encoding: .utf8)

        let excerpt = try #require(
            MaintainTierCFixer.buildAndInstallDocExcerpt(repoRootPath: root)
        )
        #expect(excerpt.contains("Build (macOS)"))
        #expect(excerpt.contains("can drop TCC grants"))
        // The section ends at the next same-depth heading.
        #expect(!excerpt.contains("MIT."))
    }

    @Test("a repo with no build documentation yields nothing rather than noise")
    func noDocsYieldsNil() throws {
        let root = NSTemporaryDirectory() + "iris-doc-excerpt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "# Thing\n\nA thing.\n".write(
            toFile: root + "/README.md", atomically: true, encoding: .utf8
        )
        #expect(MaintainTierCFixer.buildAndInstallDocExcerpt(repoRootPath: root) == nil)
    }

    // MARK: - "We have tried this before and it did not work"

    @Test("two applied runs with nothing confirmed escalates")
    func repeatedApplyWithoutCureEscalates() throws {
        let directory = try freshMemoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for index in 0..<2 {
            OnDemandEditRunLog.appendMemoryRecord(
                OnDemandEditMemoryRecord(
                    appSlug: "whimprflow",
                    date: Date(),
                    kind: "bug fix",
                    scrubbedRequest: "perms already granted",
                    filesTouched: ["ui/src/hub/SettingsPane.tsx"],
                    agentFinalNarration: "attempt \(index)",
                    outcome: "applied on branch iris/edit-\(index)",
                    symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictUnverified
                ),
                directoryPath: directory
            )
        }
        #expect(OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "whimprflow", directoryPath: directory
        ))
    }

    @Test("a single prior attempt does not escalate")
    func oneAttemptDoesNotEscalate() throws {
        let directory = try freshMemoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        OnDemandEditRunLog.appendMemoryRecord(
            OnDemandEditMemoryRecord(
                appSlug: "whimprflow",
                date: Date(),
                kind: "bug fix",
                scrubbedRequest: "perms already granted",
                filesTouched: [],
                agentFinalNarration: "first try",
                outcome: "applied on branch iris/edit-0",
                symptomVerdict: nil
            ),
            directoryPath: directory
        )
        #expect(!OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "whimprflow", directoryPath: directory
        ))
    }

    @Test("a confirmed fix stops the escalation")
    func confirmedFixStopsEscalating() throws {
        let directory = try freshMemoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for verdict in [
            OnDemandEditMemoryRecord.symptomVerdictUnverified,
            OnDemandEditMemoryRecord.symptomVerdictUnverified,
            OnDemandEditMemoryRecord.symptomVerdictConfirmed,
        ] {
            OnDemandEditRunLog.appendMemoryRecord(
                OnDemandEditMemoryRecord(
                    appSlug: "whimprflow",
                    date: Date(),
                    kind: "bug fix",
                    scrubbedRequest: "perms already granted",
                    filesTouched: [],
                    agentFinalNarration: "n",
                    outcome: "applied on branch iris/edit-x",
                    symptomVerdict: verdict
                ),
                directoryPath: directory
            )
        }
        #expect(!OnDemandEditRunLog.priorAttemptsDidNotCureTheComplaint(
            forAppSlug: "whimprflow", directoryPath: directory
        ))
    }

    // MARK: - Memory hands the next run a claim, not a finding

    @Test("a remembered diagnosis is labelled unconfirmed")
    func memoryLabelsDiagnosesAsClaims() {
        let entry = OnDemandEditRunLog.memoryPromptEntry(
            for: OnDemandEditMemoryRecord(
                appSlug: "whimprflow",
                date: Date(),
                kind: "bug fix",
                scrubbedRequest: "granted but still asking",
                filesTouched: ["src-tauri/src/paste.rs"],
                // This sentence is false about that API, was never checked, and
                // three later runs repeated it because they read it here.
                agentFinalNarration: "AXIsProcessTrusted caches its answer for the process lifetime",
                outcome: "applied on branch iris/edit-b825",
                symptomVerdict: OnDemandEditMemoryRecord.symptomVerdictStillBroken
            )
        )
        #expect(entry.contains("claimed (UNCONFIRMED)"))
        #expect(!entry.contains("Iris's own diagnosis"))
    }

    // MARK: - Helpers

    private func freshMemoryDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "iris-memory-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        return directory
    }
}
