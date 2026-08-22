//
//  OnDemandEditTests.swift
//  leanring-buddyTests
//
//  The on-demand edit tool's load-bearing SAFETY logic, tested without a
//  screen. Two suites:
//
//    OnDemandEditPureLogicTests — pure/deterministic, no process spawning: the
//      per-clone lock's mutual exclusion + canonicalization, the build-script
//      guard, the synthesized changeId, the branch naming, the up-front
//      too-large refusal, the fix/feature classifiers, the structural honesty
//      of the result type, and the coordinator's fail-closed eligibility gate.
//
//    OnDemandEditEngineTests — drives the REAL jailed loop through a scripted
//      stand-in for the model against real temp git repos (the same shape the
//      maintain-test-harness proves the crash path with). It pins the two facts
//      that only fall out of running the engine: an on-demand FEATURE edit is
//      committed as "applied", NEVER "verified", and a model edit to a
//      build-script file is blocked BEFORE the un-jailed build and reverted.
//      Serialized + gated on the Seatbelt sandbox, exactly like the pty tests.
//

import Foundation
import Testing
@testable import Iris

// MARK: - Pure logic (no processes)

@MainActor
@Suite struct OnDemandEditPureLogicTests {

    // MARK: - Per-clone lock (mutual exclusion + canonicalization)

    @Test func theLockExcludesASecondHolderOnTheSamePath() {
        let lock = MaintainClonePathLock()
        let path = Self.makeTemporaryDirectory()
        #expect(lock.tryAcquire(clonePath: path, owner: "on-demand:cue"))
        // A second acquire of the same path takes nothing and returns false.
        #expect(!lock.tryAcquire(clonePath: path, owner: "incident:cue"))
        #expect(lock.currentOwner(ofClonePath: path) == "on-demand:cue")
    }

    @Test func releasingTheLockLetsTheNextHolderIn() {
        let lock = MaintainClonePathLock()
        let path = Self.makeTemporaryDirectory()
        #expect(lock.tryAcquire(clonePath: path, owner: "on-demand:cue"))
        lock.release(clonePath: path)
        #expect(lock.currentOwner(ofClonePath: path) == nil)
        #expect(lock.tryAcquire(clonePath: path, owner: "incident:cue"))
    }

    @Test func twoDifferentClonesLatchIndependently() {
        let lock = MaintainClonePathLock()
        let first = Self.makeTemporaryDirectory()
        let second = Self.makeTemporaryDirectory()
        #expect(lock.tryAcquire(clonePath: first, owner: "on-demand:a"))
        // A different clone is a different latch — never blocked by the first.
        #expect(lock.tryAcquire(clonePath: second, owner: "on-demand:b"))
    }

    /// The exact incident-vs-on-demand collision the lock exists for: the
    /// incident path acquires with the RAW `record.clonePath`, the on-demand
    /// path with the symlink-resolved twin. They must map to the SAME latch, or
    /// the mutual exclusion is one-sided and two `.git` strips can race.
    @Test func rawAndSymlinkResolvedPathsShareOneLatch() {
        let lock = MaintainClonePathLock()
        let rawPath = Self.makeTemporaryDirectory()
        let resolvedPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        // The two string forms differ (on macOS /var → /private/var); if they
        // did not this test would be vacuous, so assert they really differ.
        #expect(rawPath != resolvedPath)

        #expect(lock.tryAcquire(clonePath: rawPath, owner: "incident:cue"))
        // The on-demand path, using the resolved form, is excluded.
        #expect(!lock.tryAcquire(clonePath: resolvedPath, owner: "on-demand:cue"))
        // Releasing via the OTHER form still frees the one latch.
        lock.release(clonePath: resolvedPath)
        #expect(lock.tryAcquire(clonePath: rawPath, owner: "on-demand:cue"))
    }

    @Test func aTrailingSlashIsTheSameLatch() {
        let lock = MaintainClonePathLock()
        let path = Self.makeTemporaryDirectory()
        #expect(lock.tryAcquire(clonePath: path, owner: "on-demand:cue"))
        #expect(!lock.tryAcquire(clonePath: path + "/", owner: "incident:cue"))
    }

    // MARK: - Build-script guard

    @Test func buildScriptFilesAreDetected() {
        // Files a build/package step EXECUTES — a model edit to one runs
        // un-jailed during verification, so each must be caught.
        for path in [
            "build.rs",
            "package.json",
            "Cargo.toml",
            "Makefile",
            "GNUmakefile",
            "app.podspec",
            "binding.gyp",
            "config.gypi",
            "cmake/toolchain.cmake",
            "CMakeLists.txt",
            "deep/nested/gulpfile.js",
            "fragment.mk",
        ] {
            #expect(MaintainBuildScriptGuard.isBuildScriptFile(path), "\(path) should be a build-script file")
        }
    }

    @Test func ordinarySourceFilesAreNotBuildScripts() {
        for path in [
            "src/main.rs",
            "Sources/App/ContentView.swift",
            "README.md",
            "app/index.ts",
            "lib/util.js",
            "styles/app.css",
        ] {
            #expect(!MaintainBuildScriptGuard.isBuildScriptFile(path), "\(path) should NOT be a build-script file")
        }
    }

    @Test func buildScriptFilePathsFiltersOnlyTheOffenders() {
        let changed = ["src/main.rs", "package.json", "README.md", "sub/build.rs"]
        let offenders = MaintainBuildScriptGuard.buildScriptFilePaths(inChangedPaths: changed)
        #expect(offenders == ["package.json", "sub/build.rs"])
    }

    // MARK: - Synthesized changeId

    @Test func changeIdIsThirtyTwoLowercaseHex() {
        let id = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button"
        )
        #expect(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
    }

    @Test func changeIdIsDeterministicForAFixedMoment() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let first = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button", at: moment
        )
        let second = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button", at: moment
        )
        #expect(first == second)
    }

    /// Re-running the SAME request is a distinct edit and must not collide on a
    /// branch — that is exactly why the changeId folds in the timestamp (unlike
    /// a crash signature, which is stable).
    @Test func rerunningTheSameRequestYieldsADistinctChangeId() {
        let a = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let b = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button",
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        #expect(a != b)
    }

    @Test func differentAppsAndRequestsNeverShareAChangeId() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let cueShare = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a share button", at: moment
        )
        let lunaraShare = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "lunara", normalizedRequest: "add a share button", at: moment
        )
        let cueDark = MaintainTierCFixer.synthesizedChangeId(
            appSlug: "cue", normalizedRequest: "add a dark mode", at: moment
        )
        #expect(cueShare != lunaraShare)
        #expect(cueShare != cueDark)
    }

    // MARK: - Branch naming

    @Test func onDemandBranchNameIsPrefixPlusFirstTwelveOfChangeIdPlusDate() {
        let changeId = "abcdef0123456789abcdef0123456789"
        let branch = MaintainFixCommit.branchName(prefix: "iris/edit-", changeId: changeId)
        // iris/edit-<first 12>-<yyyyMMdd>
        #expect(branch.hasPrefix("iris/edit-abcdef012345-"))
        #expect(branch.range(of: "^iris/edit-abcdef012345-[0-9]{8}$", options: .regularExpression) != nil)
    }

    // MARK: - Conversation windowing on a long run

    @Test func aShortConversationIsSentWholeAndUntouched() {
        let conversation = (0..<20).map { turnIndex in
            MaintainChatTurn(
                role: turnIndex.isMultiple(of: 2) ? "user" : "assistant",
                text: "turn \(turnIndex)"
            )
        }
        let sent = MaintainTierCFixer.conversationWindowedForSending(conversation)
        #expect(sent.count == conversation.count)
        #expect(sent.first?.text == "turn 0")
        #expect(sent.last?.text == "turn 19")
    }

    @Test func aLongRunKeepsTheOpeningTurnBridgesTheMiddleAndAlternatesCleanly() {
        // 201 turns: user opening, then assistant/user pairs — the shape the
        // real loop produces. Well past the window, so the middle must fold.
        var conversation = [MaintainChatTurn(role: "user", text: "the task")]
        for turnIndex in 0..<200 {
            conversation.append(MaintainChatTurn(
                role: turnIndex.isMultiple(of: 2) ? "assistant" : "user",
                text: "turn \(turnIndex)"
            ))
        }
        let sent = MaintainTierCFixer.conversationWindowedForSending(conversation)

        // The opening turn survives, carrying the bridge note for the fold.
        #expect(sent.first?.role == "user")
        #expect(sent.first?.text.hasPrefix("the task") == true)
        #expect(sent.first?.text.contains("omitted") == true)
        // The most recent turn is always the last thing the model sees.
        #expect(sent.last?.text == conversation.last?.text)
        // Bounded, and alternation-safe: after the opening user turn comes an
        // assistant turn, and roles alternate all the way down.
        #expect(sent.count <= MaintainTierCFixer.replayedConversationTurnWindow + 1)
        for (adjacentIndex, laterTurn) in sent.dropFirst().enumerated() {
            #expect(laterTurn.role != sent[adjacentIndex].role)
        }
    }

    // MARK: - Fix/feature classification (always a preselect, never binding)

    @Test func theDoorBChipsRouteToTheRightPreselectedKind() {
        // The chip text and the classifier must agree, or a tapped chip would
        // open the flow with the wrong preselect.
        let chips = OverlayEyeSuggestions.frontmostCatalogAppEditChips(forAppNamed: "NoScroll")
        #expect(chips.count == 2)
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: chips[0]) == .bugFix)
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: chips[1]) == .feature)
    }

    @Test func anOrdinaryQuestionIsNeverMistakenForAnEditInstruction() {
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: "why does it keep crashing?") == nil)
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: "how do I export?") == nil)
        // Deliberately narrow: a bare "add a dark mode" is a wish to POOL, not a
        // build instruction — it stays on the chat pipeline, so nil here.
        #expect(OverlayEyeSuggestions.editInstructionKind(forMessage: "add a dark mode") == nil)
    }

    @Test func theSuggestedKindPreselectFollowsThePhrasing() {
        #expect(OnDemandEditCoordinator.suggestedKind(forRequest: "please add a dark mode") == .feature)
        #expect(OnDemandEditCoordinator.suggestedKind(forRequest: "it crashes when I click save") == .bugFix)
    }

    // MARK: - Structural honesty of the result type

    /// The on-demand result deliberately has NO "verified" case — an on-demand
    /// edit runs with `reproCommand` nil and can only ever earn a clean apply.
    /// This exhaustive switch is the tripwire: adding a `.verified`-style case
    /// would make it non-exhaustive and fail to compile, forcing a re-review of
    /// the honesty contract.
    @Test func theResultTypeCannotRepresentAVerifiedEdit() {
        let result: MaintainOnDemandEditResult = .appliedAndRebuilt(
            branchName: "iris/edit-x", changeId: "x", kind: .feature, suitePassed: true
        )
        switch result {
        case .appliedAndRebuilt(_, _, let kind, _):
            #expect(kind == .feature)
        case .couldNotComplete:
            Issue.record("unexpected couldNotComplete")
        case .notEligible:
            Issue.record("unexpected notEligible")
        }
    }

    // MARK: - Coordinator eligibility (fail-closed)

    @Test func pickingAnAppWithNoRecordedProvenanceRefuses() {
        let coordinator = Self.makeCoordinator(provenanceStore: InstallProvenanceStore(userDefaults: Self.ephemeralDefaults()))
        coordinator.pickApp(slug: "cue", name: "cue", stack: .tauri)
        #expect(Self.refusalReason(coordinator.phase)?.contains("publik guide") == true)
        #expect(coordinator.statusLine != nil)
    }

    @Test func pickingASignedDownloadAppRefuses() {
        let store = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        store.recordSignedDownload(appSlug: "cue")
        let coordinator = Self.makeCoordinator(provenanceStore: store)
        coordinator.pickApp(slug: "cue", name: "cue", stack: .tauri)
        // A signed download is never patched — fails at the provenance gate.
        #expect(Self.refusalReason(coordinator.phase)?.contains("publik guide") == true)
    }

    @Test func aSourceCloneWhoseFolderIsGoneRefuses() {
        let store = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        // A guide-source clone recorded, but the clone folder no longer exists
        // (deleted, or wiped) — provenance falls back to fail-closed.
        store.recordGuideSourceClone(
            appSlug: "cue",
            clonePath: NSTemporaryDirectory() + "iris-gone-\(UUID().uuidString)",
            pinnedCommit: nil, canonicalRepo: nil
        )
        let coordinator = Self.makeCoordinator(provenanceStore: store)
        coordinator.pickApp(slug: "cue", name: "cue", stack: .tauri)
        #expect(Self.refusalReason(coordinator.phase)?.contains("publik guide") == true)
    }

    /// Provenance says guide-source clone AND `.git` is present, but the clone
    /// sits OUTSIDE $HOME — the stricter `allowedRepositoryPath` gate the bare
    /// `.git`-exists check skips must still refuse it.
    @Test func aSourceCloneOutsideHomeRefusesAtTheLocationGate() throws {
        // /tmp resolves to /private/tmp, which is outside $HOME on macOS.
        let repoPath = "/tmp/iris-ondemand-test-\(UUID().uuidString)/repo"
        try FileManager.default.createDirectory(
            atPath: repoPath + "/.git", withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: (repoPath as NSString).deletingLastPathComponent) }

        let store = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        store.recordGuideSourceClone(
            appSlug: "cue", clonePath: repoPath, pinnedCommit: nil, canonicalRepo: nil
        )
        let coordinator = Self.makeCoordinator(provenanceStore: store)
        coordinator.pickApp(slug: "cue", name: "cue", stack: .tauri)
        // Whatever the exact wording, the outcome must be a refusal, not an
        // offer — an out-of-home clone is never editable.
        #expect(Self.refusalReason(coordinator.phase) != nil)
    }

    // MARK: - Reader stop + transparency (pure pieces)

    /// A stop the READER chose must never read as a failure: the mapped copy is
    /// the calm "stopped, nothing changed" sentence, with no build-script flag
    /// and no settings offer (there is nothing to fix).
    @Test func aReaderStopReasonMapsToACalmSentence() {
        let mapped = OnDemandEditCoordinator.mappedFailure(
            reason: MaintainTierCFixer.stoppedByReaderReason
        )
        #expect(mapped.userFacing == "Stopped at your request — nothing was changed.")
        #expect(!mapped.wasBuildScriptBlock)
        #expect(!mapped.offersModelKeySetup)
    }

    /// Only a DROPPED call (a timeout, a lost connection) is retried
    /// identically — a refusal (bad credential, 429) would just refuse again,
    /// and each has its own handling.
    @Test func onlyTransportDropsCountAsTransient() {
        #expect(MaintainTierCFixer.errorLooksLikeATransientTransportDrop(
            AssistantTransportError.transportFailure(reason: "The request timed out.")
        ))
        #expect(MaintainTierCFixer.errorLooksLikeATransientTransportDrop(
            URLError(.timedOut)
        ))
        #expect(!MaintainTierCFixer.errorLooksLikeATransientTransportDrop(
            AssistantTransportError.bringYourOwnKeyRejected
        ))
        #expect(!MaintainTierCFixer.errorLooksLikeATransientTransportDrop(
            AssistantTransportError.rateLimited(retryAfterSeconds: 5)
        ))
    }

    /// The agent's narration is the reply's prose with the fenced command and
    /// any bare DONE line removed, flattened to one line — and a reply with no
    /// prose yields nil, never an empty row.
    @Test func narrationIsTheReplyProseWithoutTheCommandOrDone() {
        #expect(MaintainTierCFixer.narrationText(
            fromModelReply: "Opening the settings view to see how toggles are wired.\n```bash\ncat src/settings.tsx\n```"
        ) == "Opening the settings view to see how toggles are wired.")
        #expect(MaintainTierCFixer.narrationText(
            fromModelReply: "All done — the toggle persists now.\nDONE"
        ) == "All done — the toggle persists now.")
        // Old-style replies (command only, or bare DONE) carry no prose.
        #expect(MaintainTierCFixer.narrationText(
            fromModelReply: "```bash\nls\n```"
        ) == nil)
        #expect(MaintainTierCFixer.narrationText(fromModelReply: "DONE") == nil)
    }

    /// The per-file snapshot diff names writes, creations, and deletions, and
    /// an identical snapshot names nothing — the pair of facts the no-progress
    /// detector and the "Changed: …" transparency line both stand on.
    @Test func changedPathsNameWritesCreationsAndDeletions() {
        let previous = ["a.txt": "3|100.0", "b.txt": "5|100.0", "gone.txt": "1|100.0"]
        let latest = ["a.txt": "9|200.0", "b.txt": "5|100.0", "new.txt": "2|200.0"]
        #expect(MaintainTierCFixer.changedPathsBetween(previous: previous, latest: latest)
            == ["a.txt", "gone.txt", "new.txt"])
        #expect(MaintainTierCFixer.changedPathsBetween(previous: previous, latest: previous).isEmpty)
    }

    /// The live-transcript output tail is display-safe: control sequences
    /// stripped, blank lines dropped, at most four lines, each line capped so
    /// one long compiler line can't flood a terminal row.
    @Test func displayableOutputTailLinesAreStrippedAndCapped() {
        let rawOutput = "\u{1B}[31mred error\u{1B}[0m\n\n"
            + "line two\nline three\nline four\nline five\n"
            + String(repeating: "x", count: 500) + "\n"
        let tailLines = MaintainTierCFixer.displayableOutputTailLines(fromRawOutput: rawOutput)
        #expect(tailLines.count == 4)
        #expect(tailLines.allSatisfy { !$0.contains("\u{1B}") })
        #expect(tailLines.allSatisfy { $0.count <= 220 })
        // The tail keeps the END of the output — where the error usually is.
        #expect(tailLines.last?.hasPrefix("xxxx") == true)
    }

    /// The per-run log writes a header naming the run and the request, then
    /// timestamped lines, then the outcome — the file a failed run leaves
    /// behind so "what did it actually try?" has an answer.
    @Test func theRunLogPersistsTheRequestActivityAndOutcome() throws {
        let directory = Self.makeTemporaryDirectory()
        let runLog = OnDemandEditRunLog(
            appSlug: "demo", kindLabel: "feature",
            scrubbedRequest: "add a dark mode toggle",
            directoryPath: directory
        )
        let unwrappedRunLog = try #require(runLog)
        unwrappedRunLog.record("iris: Opening the settings view.")
        unwrappedRunLog.record("$ cat src/settings.tsx")
        unwrappedRunLog.finish(outcome: "failed: ran out of steps")

        let contents = try String(contentsOfFile: unwrappedRunLog.filePath, encoding: .utf8)
        #expect(contents.contains("demo (feature)"))
        #expect(contents.contains("Request: add a dark mode toggle"))
        #expect(contents.contains("iris: Opening the settings view."))
        #expect(contents.contains("$ cat src/settings.tsx"))
        #expect(contents.contains("outcome: failed: ran out of steps"))
        // Closed: a record after finish writes nothing.
        unwrappedRunLog.record("after close")
        let contentsAfterClose = try String(contentsOfFile: unwrappedRunLog.filePath, encoding: .utf8)
        #expect(!contentsAfterClose.contains("after close"))
    }

    /// The runs directory is pruned oldest-first so it never grows unbounded —
    /// creating a new log keeps the total at the cap.
    @Test func oldRunLogsArePrunedOldestFirst() throws {
        let directory = Self.makeTemporaryDirectory()
        // Timestamp-first names sort chronologically as plain strings; these
        // stand in for old runs.
        for index in 0..<(OnDemandEditRunLog.maximumKeptRunLogFiles + 5) {
            let name = String(format: "20260801-%09d-old.log", index)
            FileManager.default.createFile(
                atPath: (directory as NSString).appendingPathComponent(name), contents: Data()
            )
        }
        let runLog = try #require(OnDemandEditRunLog(
            appSlug: "demo", kindLabel: "bug fix", scrubbedRequest: "r",
            directoryPath: directory
        ))
        _ = runLog
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".log") }
        #expect(remaining.count == OnDemandEditRunLog.maximumKeptRunLogFiles)
        // The oldest files are the ones that went.
        #expect(!remaining.contains(String(format: "20260801-%09d-old.log", 0)))
    }

    // MARK: - Helpers

    private static func makeCoordinator(provenanceStore: InstallProvenanceStore) -> OnDemandEditCoordinator {
        OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(baseDirectoryURL: makeTemporaryDirectoryURL())
        )
    }

    /// The reason carried by a terminal refusal phase, or nil if the phase is
    /// not a refusal (which is itself a test failure signal at the call site).
    private static func refusalReason(_ phase: OnDemandEditPhase) -> String? {
        switch phase {
        case .notEligible(let reason), .failed(let reason): return reason
        default: return nil
        }
    }

    private static func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "iris.ondemand.tests.\(UUID().uuidString)")!
    }

    private static func makeTemporaryDirectory() -> String {
        makeTemporaryDirectoryURL().path
    }

    private static func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-ondemand-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Engine (real jailed loop, scripted model, real git repos)

/// Serialized and env-gated, exactly like the pty tests: these spawn
/// `sandbox-exec` + `git` and run the REAL Tier C loop. Set
/// IRIS_SKIP_ONDEMAND_ENGINE_TESTS=1 to skip. Each test additionally no-ops
/// when the Seatbelt sandbox is unavailable (the sandbox check must run on the
/// main actor, so it lives inside the test, not in the suite gate) — the pure
/// suite above still covers the decision logic on such a box.
@MainActor
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["IRIS_SKIP_ONDEMAND_ENGINE_TESTS"] != "1"),
    .serialized
)
struct OnDemandEditEngineTests {

    /// The engine loop needs the Seatbelt jail; on a box without it these tests
    /// no-op rather than fail (mirroring the pty tests' graceful skip).
    private var sandboxIsAvailable: Bool { MaintainSandbox.isAvailable }

    /// A stand-in for the model: replays canned turns, then DONE. Mirrors the
    /// maintain-test-harness's `ScriptedProvider` so these tests exercise the
    /// same real loop the crash path is proven with, without a key.
    final class ScriptedProvider: MaintainModelProviding {
        let displayName = "scripted-mock"
        let isAvailable = true
        private let turns: [String]
        private var index = 0
        init(_ turns: [String]) { self.turns = turns }
        func respond(
            systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
        ) async throws -> String {
            defer { index += 1 }
            return index < turns.count ? turns[index] : "DONE"
        }
    }

    /// Build/test that need no real toolchain: `true` builds, and the suite is a
    /// grep against a health file, so the loop's verify leg is real but fast.
    private static func fastCommands(testCommand: String = "grep -q OK health.txt") -> VerificationCommands {
        VerificationCommands(buildCommand: "true", testCommand: testCommand, commandSubdirectory: nil)
    }

    /// A FEATURE edit that succeeds is committed as "applied and rebuilt", never
    /// "verified": the commit trailer says `Applied:` (not `Verified:`), carries
    /// the on-demand `Change-Kind`, lands on an `iris/edit-` branch, and has no
    /// `Co-Authored-By`. This is the honesty contract the whole tool turns on.
    @Test func aFeatureEditIsCommittedAsAppliedNeverVerified() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "```bash\nprintf 'FIXED\\n' > app.txt\n```",
            "DONE",
        ]))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "abcdef0123456789abcdef0123456789",
            request: "please make the app say FIXED", kind: .feature,
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .appliedAndRebuilt(let branchName, _, let kind, let suitePassed) = result else {
            Issue.record("expected .appliedAndRebuilt, got \(result)")
            return
        }
        #expect(kind == .feature)
        #expect(suitePassed == true)
        #expect(branchName.hasPrefix("iris/edit-"))

        let commitMessage = Self.git(["log", "-1", "--format=%B"], in: repo)
        #expect(commitMessage.contains("Change-Kind: on-demand-feature"))
        #expect(commitMessage.contains("Applied:"))
        // The load-bearing honesty line: a feature is NEVER "verified".
        #expect(!commitMessage.contains("Verified:"))
        #expect(commitMessage.contains("Modified-by: Iris (publik)"))
        // The structured trailer block is a provenance record, not a
        // co-authorship claim.
        #expect(!commitMessage.contains("Co-Authored-By"))
        // The edit actually landed, and `.git` was restored after the loop.
        #expect(Self.fileContents(repo, "app.txt") == "FIXED")
        #expect(FileManager.default.fileExists(atPath: repo + "/.git"))
    }

    /// Replays canned turns like `ScriptedProvider`, but throws the given
    /// error for each of the first `throwCount` calls. The rate-limit ride-out
    /// exists exactly for this shape: a transient 429, then normal service.
    final class ThrowingThenScriptedProvider: MaintainModelProviding {
        let displayName = "throwing-then-scripted-mock"
        let isAvailable = true
        private let turns: [String]
        private let errorToThrow: Error
        private var remainingThrows: Int
        private var index = 0
        init(throwing errorToThrow: Error, times throwCount: Int, then turns: [String]) {
            self.errorToThrow = errorToThrow
            self.remainingThrows = throwCount
            self.turns = turns
        }
        func respond(
            systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
        ) async throws -> String {
            if remainingThrows > 0 {
                remainingThrows -= 1
                throw errorToThrow
            }
            defer { index += 1 }
            return index < turns.count ? turns[index] : "DONE"
        }
    }

    /// A transient 429 mid-run is waited out (Retry-After honored, here 0s so
    /// the test is instant) instead of reverting the whole run — the shape a
    /// Claude Code login hits constantly, since that credential shares the
    /// subscription's limit with Claude Code itself.
    @Test func aRateLimitedModelCallIsRiddenOutNotReverted() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ThrowingThenScriptedProvider(
            throwing: AssistantTransportError.rateLimited(retryAfterSeconds: 0),
            times: MaintainTierCFixer.maximumRateLimitWaitsPerRun,
            then: [
                "```bash\nprintf 'FIXED\\n' > app.txt\n```",
                "DONE",
            ]
        ))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "bbbbbbbbbbbbbbbbcccccccccccccccc",
            request: "please make the app say FIXED", kind: .feature,
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .appliedAndRebuilt = result else {
            Issue.record("expected .appliedAndRebuilt after riding out the 429s, got \(result)")
            return
        }
        #expect(Self.fileContents(repo, "app.txt") == "FIXED")
    }

    /// One 429 more than the run will wait out fails honestly — with the
    /// Tier-C rate-limit wording, not the funded tier's "add your own key".
    @Test func aPersistentRateLimitFailsWithActionableWording() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ThrowingThenScriptedProvider(
            throwing: AssistantTransportError.rateLimited(retryAfterSeconds: 0),
            times: MaintainTierCFixer.maximumRateLimitWaitsPerRun + 1,
            then: ["DONE"]
        ))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "ddddddddddddddddeeeeeeeeeeeeeeee",
            request: "please make the app say FIXED", kind: .feature,
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .couldNotComplete(let reason) = result else {
            Issue.record("expected .couldNotComplete on a persistent 429, got \(result)")
            return
        }
        #expect(reason.contains("rate-limiting"))
        // The revert left the tree exactly as it started, `.git` restored.
        #expect(Self.fileContents(repo, "app.txt") == "BROKEN")
        #expect(FileManager.default.fileExists(atPath: repo + "/.git"))
    }

    /// The Aug 22 whimprflow failure, replayed and fixed: a model that edits a
    /// build-script file mid-run (here `package.json`) has that ONE file
    /// restored on the spot and is steered onward — the rest of its work
    /// survives, the run lands, and the commit carries only the legitimate
    /// edit. Previously the end-of-run guard discarded the entire run.
    @Test func aBuildScriptEditIsRestoredMidLoopAndTheRunStillLands() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo(extraFiles: ["package.json": "{\"name\":\"x\"}\n"])
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "Adding a dependency for the fix.\n```bash\nprintf '{\"name\":\"x\",\"dependencies\":{\"left-pad\":\"1\"}}\\n' > package.json\n```",
            "Understood — implementing inline instead.\n```bash\nprintf 'FIXED\\n' > app.txt\n```",
            "DONE",
        ]))
        var observedEvents: [MaintainTierCProgressEvent] = []
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "0000000000000000aaaaaaaaaaaaaaaa",
            request: "make the app say FIXED", kind: .bugFix,
            progressHandler: { progressEvent in observedEvents.append(progressEvent) },
            verificationCommandsOverride: Self.fastCommands(testCommand: "true")
        )

        guard case .appliedAndRebuilt = result else {
            Issue.record("expected the restored run to land, got \(result)")
            return
        }
        // The forbidden edit was undone, the legitimate edit survived, and the
        // reader was shown the correction.
        #expect(Self.fileContents(repo, "package.json") == "{\"name\":\"x\"}")
        #expect(Self.fileContents(repo, "app.txt") == "FIXED")
        #expect(observedEvents.contains(
            .revertedForbiddenBuildScriptEdit(paths: ["package.json"], stepNumber: 1)
        ))
    }

    /// A model that keeps going back to build-script files after two restores
    /// is not going to implement without them: the run fails fast with the
    /// honest blocked reason, everything reverted, nothing committed.
    @Test func repeatedBuildScriptEditsFailFastBlockedAndReverted() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo(extraFiles: ["package.json": "{\"name\":\"x\"}\n"])
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "```bash\nprintf '{\"name\":\"a\"}\\n' > package.json\n```",
            "```bash\nprintf '{\"name\":\"b\"}\\n' > package.json\n```",
            "```bash\nprintf '{\"name\":\"c\"}\\n' > package.json\n```",
            "DONE",
        ]))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "4444444444444444dddddddddddddddd",
            request: "add a build script", kind: .feature,
            verificationCommandsOverride: Self.fastCommands(testCommand: "true")
        )

        guard case .couldNotComplete(let reason) = result else {
            Issue.record("expected .couldNotComplete (build-script block), got \(result)")
            return
        }
        #expect(reason.contains("build-script"))
        // The revert put package.json back exactly, and nothing was committed on
        // an iris/edit- branch.
        #expect(Self.fileContents(repo, "package.json") == "{\"name\":\"x\"}")
        #expect(FileManager.default.fileExists(atPath: repo + "/.git"))
        #expect(!Self.git(["branch", "--list", "iris/edit-*"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines).contains("iris/edit-"))
    }

    /// The reader's Stop is honored at the next step boundary and undoes
    /// EVERYTHING: the model's tracked edit reverted, its untracked file
    /// removed, `.git` restored, no branch created — and the result is the
    /// dedicated stopped reason, never a generic failure.
    @Test func aReaderStopRevertsEverythingAndEndsCalmly() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "```bash\nprintf 'FIXED\\n' > app.txt; printf 'scratch\\n' > junk.txt\n```",
            "DONE",
        ]))
        // "The reader taps Stop right after the first command finishes": the
        // progress stream is the trigger, so the test pins the real sequence
        // (command runs → stop lands → next boundary reverts) without counting
        // internal polls.
        var readerAskedToStop = false
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "ffffffffffffffff0000000000000000",
            request: "please make the app say FIXED", kind: .feature,
            progressHandler: { progressEvent in
                if case .jailedCommandFinished = progressEvent {
                    readerAskedToStop = true
                }
            },
            cancellationCheck: { readerAskedToStop },
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .couldNotComplete(let reason) = result else {
            Issue.record("expected the stopped result, got \(result)")
            return
        }
        #expect(reason == MaintainTierCFixer.stoppedByReaderReason)
        // The tracked edit is reverted, the untracked scratch file is gone,
        // `.git` is back, and nothing was committed on any iris/edit- branch.
        #expect(Self.fileContents(repo, "app.txt") == "BROKEN")
        #expect(!FileManager.default.fileExists(atPath: repo + "/junk.txt"))
        #expect(FileManager.default.fileExists(atPath: repo + "/.git"))
        #expect(!Self.git(["branch", "--list", "iris/edit-*"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines).contains("iris/edit-"))
    }

    /// The progress stream narrates the REAL run in order: the model
    /// consulted, the exact jailed command, its green exit, verification with
    /// the real build/test commands, and the commit. This is the transparency
    /// surface's contract — every event is something that actually happened.
    @Test func progressEventsNarrateTheRealRunInOrder() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let editCommand = "printf 'FIXED\\n' > app.txt"
        // Replies in the shape the on-demand narration addendum asks for: one
        // plain-English sentence of intent, then the command (or DONE).
        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "Writing FIXED into app.txt, which is what the request asks for.\n```bash\n\(editCommand)\n```",
            "All done — app.txt now says FIXED.\nDONE",
        ]))
        var observedEvents: [MaintainTierCProgressEvent] = []
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "1111111111111111aaaaaaaaaaaaaaaa",
            request: "please make the app say FIXED", kind: .feature,
            progressHandler: { progressEvent in observedEvents.append(progressEvent) },
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .appliedAndRebuilt = result else {
            Issue.record("expected .appliedAndRebuilt, got \(result)")
            return
        }
        #expect(observedEvents.first == .waitingOnTheModel(stepNumber: 1))
        // The agent's OWN words stream out — both the step's intent sentence
        // (with the fenced command stripped) and the DONE summary.
        #expect(observedEvents.contains(.agentNarration(
            text: "Writing FIXED into app.txt, which is what the request asks for.", stepNumber: 1
        )))
        #expect(observedEvents.contains(.agentNarration(
            text: "All done — app.txt now says FIXED.", stepNumber: 2
        )))
        #expect(observedEvents.contains(
            .runningJailedCommand(command: editCommand, stepNumber: 1)
        ))
        #expect(observedEvents.contains { event in
            if case .jailedCommandFinished(let exitCode, _, _) = event { return exitCode == 0 }
            return false
        })
        // The step's tree diff names exactly the file the agent wrote.
        #expect(observedEvents.contains(.editedFiles(paths: ["app.txt"], stepNumber: 1)))
        #expect(observedEvents.contains(
            .verifyingTheChange(buildCommand: "true", testCommand: "grep -q OK health.txt")
        ))
        #expect(observedEvents.last == .committingTheChange)
    }

    /// Replays a scripted edit, then endless DISTINCT read-only commands — the
    /// exact "checking my own finished work" spree that killed a real dogfood
    /// run — until the loop's finish-or-continue nudge appears in the
    /// conversation, then declares DONE. `respondsToNudge: false` never
    /// declares DONE, pinning the honest stop one threshold later.
    final class StallsUntilNudgedProvider: MaintainModelProviding {
        let displayName = "stalls-until-nudged"
        let isAvailable = true
        private let respondsToNudge: Bool
        private var index = 0
        private let readOnlyFillerCommands = [
            "ls", "pwd", "cat app.txt", "cat health.txt", "echo checking",
            "true", "echo again", "ls -la", "wc -l app.txt", "head app.txt",
            "tail app.txt", "echo more", "date -u +%Y", "echo still", "id -u",
        ]
        init(respondsToNudge: Bool) { self.respondsToNudge = respondsToNudge }
        func respond(
            systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
        ) async throws -> String {
            if respondsToNudge, conversation.contains(where: { turn in
                turn.role == "user" && turn.text.contains("reply DONE now")
            }) {
                return "The change was already complete — finishing.\nDONE"
            }
            defer { index += 1 }
            if index == 0 {
                return "Making the edit.\n```bash\nprintf 'FIXED\\n' > app.txt\n```"
            }
            let filler = readOnlyFillerCommands[index % readOnlyFillerCommands.count]
            return "Checking my work.\n```bash\n\(filler)\n```"
        }
    }

    /// The Aug 22 dogfood failure, replayed and fixed: an agent that finished
    /// its edit and then only READ for five steps used to be killed and
    /// reverted ("couldn't converge"). Now the loop nudges it — finish or make
    /// the next edit — and a model that was simply done declares DONE and the
    /// change lands.
    @Test func aPostEditReadingSpreeIsNudgedToDoneNotKilled() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: StallsUntilNudgedProvider(respondsToNudge: true))
        var observedEvents: [MaintainTierCProgressEvent] = []
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "2222222222222222bbbbbbbbbbbbbbbb",
            request: "please make the app say FIXED", kind: .bugFix,
            progressHandler: { progressEvent in observedEvents.append(progressEvent) },
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .appliedAndRebuilt = result else {
            Issue.record("expected the nudge to rescue the run, got \(result)")
            return
        }
        #expect(Self.fileContents(repo, "app.txt") == "FIXED")
        #expect(observedEvents.contains { event in
            if case .nudgedTowardConvergence = event { return true }
            return false
        })
    }

    /// A model that stalls straight through the nudge still stops honestly —
    /// one threshold later — with everything reverted and the step count in
    /// the reason for the run log.
    @Test func aModelThatIgnoresTheNudgeStillStopsAndReverts() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo()
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: StallsUntilNudgedProvider(respondsToNudge: false))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "3333333333333333cccccccccccccccc",
            request: "please make the app say FIXED", kind: .bugFix,
            verificationCommandsOverride: Self.fastCommands()
        )

        guard case .couldNotComplete(let reason) = result else {
            Issue.record("expected the honest stop after the ignored nudge, got \(result)")
            return
        }
        #expect(reason.contains("ran out of steps"))
        #expect(Self.fileContents(repo, "app.txt") == "BROKEN")
        #expect(FileManager.default.fileExists(atPath: repo + "/.git"))
    }

    // MARK: - Git repo helpers

    /// A fresh repo with a real bug committed clean: app.txt=BROKEN (the loop
    /// fixes it to FIXED) and health.txt=OK (the suite greps for it).
    static func makeBuggyRepo(extraFiles: [String: String] = [:]) throws -> String {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-ondemand-engine-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git(["init", "-q"], in: repo)
        git(["config", "user.email", "t@t"], in: repo)
        git(["config", "user.name", "t"], in: repo)
        try "BROKEN\n".write(toFile: repo + "/app.txt", atomically: true, encoding: .utf8)
        try "OK\n".write(toFile: repo + "/health.txt", atomically: true, encoding: .utf8)
        for (name, contents) in extraFiles {
            try contents.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
        }
        git(["add", "-A"], in: repo)
        git(["commit", "-qm", "base"], in: repo)
        return repo
    }

    static func removeRepo(_ repo: String) {
        try? FileManager.default.removeItem(atPath: repo)
    }

    static func fileContents(_ repo: String, _ name: String) -> String {
        ((try? String(contentsOfFile: repo + "/" + name, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git synchronously in `directory` and returns its stdout. Setup and
    /// inspection only — the engine under test uses its own runner.
    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
