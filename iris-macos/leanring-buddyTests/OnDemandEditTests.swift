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

    // MARK: - Up-front "too large" refusal

    @Test func anObviouslyBroadRequestIsRefusedUpFront() {
        // Three or more enumerated items = a batch, not one edit.
        #expect(OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(
            "1. add dark mode\n2. add a share button\n3. add export"
        ))
        // Several asks conjoined into one sentence.
        #expect(OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(
            "add a dark mode and also add a share sheet"
        ))
        // A very long request is a proxy for a broad change.
        #expect(OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(
            String(repeating: "make it better ", count: 120)
        ))
    }

    @Test func aNormalSingleRequestIsNotRefused() {
        #expect(!OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(
            "add a dark mode toggle to the settings screen"
        ))
        #expect(!OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(
            "fix the crash when I tap export"
        ))
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

    /// A model edit to a build-script file (here `package.json`) is a jail
    /// escape — it would run un-jailed during the verification build — so it is
    /// blocked BEFORE any build runs and the tree is reverted. Nothing is
    /// committed; the offending file is back exactly as it was.
    @Test func anEditToABuildScriptFileIsBlockedBeforeBuildingAndReverted() async throws {
        guard sandboxIsAvailable else { return }
        let repo = try Self.makeBuggyRepo(extraFiles: ["package.json": "{\"name\":\"x\"}\n"])
        defer { Self.removeRepo(repo) }

        let fixer = MaintainTierCFixer(provider: ScriptedProvider([
            "```bash\nprintf '{\"name\":\"x\",\"scripts\":{\"build\":\"echo pwned\"}}\\n' > package.json\n```",
            "DONE",
        ]))
        let result = await fixer.attemptOnDemandEdit(
            clonePath: repo, appSlug: "demo", appStack: .nextjs,
            changeId: "0000000000000000aaaaaaaaaaaaaaaa",
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
        #expect(!Self.git(["branch", "--list", "iris/edit-*"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines).contains("iris/edit-"))
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
