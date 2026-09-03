//
//  Bug5PnpmChurnAndApprovalReproTests.swift
//  leanring-buddyTests
//
//  THE REPORT. Test 10, Akrit, Iris 0.9.7 build 23, on his WhimprFlow clone
//  (a Tauri app: Rust under `src-tauri/`, the frontend and its `build` script
//  under `ui/`). One cycle, in the order his log records it:
//
//    11:49:33  run 1 — "not started: the clone has uncommitted changes
//              (ui/pnpm-workspace.yaml)". He had never opened that file.
//    …         he taps "Set aside and continue"; Iris stashes the change as
//              `iris/set-aside-2026-09-02` and re-runs.
//    …         run 3 edits five source files and verifies with
//                  build=(cd 'ui' && pnpm build) && cargo build --release \
//                        --manifest-path src-tauri/Cargo.toml
//              → "verification failed (build)".
//    …         the repair round reads ui/pnpm-workspace.yaml and the README,
//              then gives up: BLOCKED — "pnpm fails its dependency-status
//              preflight before compiling any source because esbuild is
//              unapproved in the global pnpm store; run
//              `cd ui && pnpm approve-builds --all`".
//    12:28:41  ui/pnpm-workspace.yaml is dirty AGAIN, now holding
//
//                  allowBuilds:
//                    esbuild: set this to true or false
//
//              which nobody typed — pnpm wrote it, while failing. The next run
//              walks straight back into 11:49:33's refusal. That is the loop.
//
//  It is ONE bug with two halves that feed each other, and this file
//  reproduces both against real tools rather than a description of them:
//
//    HALF 1 — the verification build. `RepoRecipeRustTauriDetector` lifts the
//      frontend hook out of tauri.conf.json verbatim ("pnpm build") and composes
//      the verification build from it. Modern pnpm refuses to install a package
//      whose build script has not been reviewed (ERR_PNPM_IGNORED_BUILDS), and
//      since pnpm 11 a bare `pnpm <script>` runs its own dependency-status
//      check first — so on a fresh clone the composed command dies inside an
//      install pnpm started by itself, before one line of the model's code is
//      compiled. The run is judged as if the change did not build.
//
//    HALF 2 — the dirty-clone gate. `OnDemandEditCoordinator`'s preflight
//      (the `git status --porcelain` at OnDemandEditCoordinator.swift:1163,
//      read by `OnDemandEditDirtyTreeReport`) treats every uncommitted path as
//      the reader's own work worth refusing for. It has no notion of package
//      manager BOOKKEEPING — the placeholder pnpm just wrote, a generated
//      lockfile — which is disposable machine output that the tool regenerates
//      on demand. So the failing build in half 1 manufactures exactly the dirt
//      that makes the NEXT run refuse before it starts. Test 9 shows the same
//      shape one package manager over: that kneecap checkout's only dirty file
//      was `bun.lock`, written the second `bun install` succeeded.
//
//  What is real here, and deliberately so — a stub pnpm could only ever assert
//  what its author already believed:
//    • a real git repository in a temp directory under $HOME, shaped like
//      WhimprFlow (src-tauri/tauri.conf.json + Cargo crate, ui/ frontend);
//    • a real pnpm, pinned by the fixture's own `packageManager` field so the
//      gate under test is the one modern pnpm actually enforces (this Mac's
//      default pnpm is 10.0.0, whose gate is warn-only — a fixture that let it
//      decide would pass while proving nothing);
//    • a real esbuild dependency, whose postinstall script is the unreviewed
//      build script the whole failure turns on;
//    • the real `RepoRecipeService` → `MaintainTierCFixer.resolvedVerificationCommands`
//      composition that printed the command in the log, run through the real
//      `MaintainShellRunner` and judged by the real `VerificationHarness`;
//    • the real `OnDemandEditDirtyTreeReport`, fed the real porcelain that the
//      real failure left behind.
//
//  WHERE THE CONTRACT LIVES, for whoever fixes this: the churn suites below
//  assert through `OnDemandEditDirtyTreeReport`, because that is the type the
//  gate consults and the one that turns "what git said" into "what the reader
//  is told". A fix that instead decides churn-vs-work at the call site must
//  move these assertions to wherever the decision lands — the CONTRACT is
//  "a clone whose only dirt is a package manager's own bookkeeping does not
//  stop a run", not the property it is spelled with.
//

import Foundation
import Testing

// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// MARK: - Half 1. The verification build dies at pnpm's build-approval gate

/// Serialized: every test here spawns a real pnpm and a real cargo against its
/// own repository on disk.
@MainActor
@Suite(.serialized)
struct Bug5VerificationBuildTests {

    /// The command from the log, re-derived by the code that derived it. Not
    /// asserted verbatim on purpose: the fix is expected to CHANGE this string
    /// (that is the point), so what is pinned is the part that must survive —
    /// the hook still runs in the frontend package's own directory, and the
    /// cargo half still points at the crate under src-tauri/.
    @Test func theVerificationBuildCommandIsComposedFromTheProjectsOwnTauriHook() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }

        let buildCommand = try #require(
            Bug5WhimprflowClone.resolvedVerificationCommands(forCloneAt: clone.path).buildCommand,
            "the recipe resolved no build command at all for a Tauri clone"
        )
        #expect(
            buildCommand.contains("cd 'ui'"),
            "the frontend hook must run where the frontend package is; got: \(buildCommand)"
        )
        #expect(
            buildCommand.contains("pnpm build"),
            "the hook the project declares is `pnpm build`; got: \(buildCommand)"
        )
        #expect(
            buildCommand.contains("cargo build --release --manifest-path src-tauri/Cargo.toml"),
            "the cargo half must still point at the crate; got: \(buildCommand)"
        )
    }

    /// THE RECREATION of "verification failed (build)". A fresh clone, no
    /// node_modules — exactly what the engine verifies against — and the
    /// derived build command run through the real runner.
    ///
    /// On the unfixed code this fails with pnpm's own words:
    ///     [ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.25.0
    /// emitted by an install that `pnpm build` spawned for itself
    /// (`runDepsStatusCheck` → `pnpm install`), so nothing the model wrote was
    /// ever compiled. The verdict the reader got — "your change doesn't
    /// build" — was about pnpm's approval bookkeeping, not about their app.
    @Test func theVerificationBuildDiesAtPnpmsApprovalGateBeforeAnySourceIsCompiled() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }
        guard try await clone.theToolchainThisReproNeedsIsReachable() else { return }

        let commands = Bug5WhimprflowClone.resolvedVerificationCommands(forCloneAt: clone.path)
        let buildCommand = try #require(commands.buildCommand)
        let result = try await clone.runner.run(
            buildCommand, inSubdirectory: commands.commandSubdirectory, deadline: 600
        )

        #expect(
            !result.outputTail.contains("ERR_PNPM_IGNORED_BUILDS"),
            """
            the verification build never reached the reader's code — pnpm refused \
            to install a dependency whose build script it has not been told about, \
            and Iris has no non-interactive way past that gate. pnpm said:
            \(Bug5WhimprflowClone.lastLines(ofOutput: result.outputTail, count: 12))
            """
        )
        #expect(
            result.succeeded,
            "the verification build exited \(result.exitCode) for a clone whose only content is a hello-world crate and a one-line esbuild bundle"
        )
    }

    /// The same failure through the surface that actually printed
    /// "verification failed (build)": the real `VerificationHarness`, with the
    /// five uncommitted source edits run 3 had made sitting in the tree.
    ///
    /// Asserted narrowly on the BUILD leg. A later leg (the cheat-signature
    /// scan, the suite) blocking for its own reasons is a different subject,
    /// and this test must not become an oracle for it.
    @Test func theRealVerificationHarnessBlocksAtTheBuildLegOnAFreshClone() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }
        guard try await clone.theToolchainThisReproNeedsIsReachable() else { return }

        // Run 3 "edited five source files" before verifying. The harness's
        // diff-scope gate runs first and refuses an empty tree, so the repro
        // needs a real uncommitted diff to reach the build leg at all.
        clone.editFiveSourceFilesTheWayRunThreeDid()

        let outcome = await VerificationHarness.verifyAppliedPatch(
            runner: clone.runner,
            commands: Bug5WhimprflowClone.resolvedVerificationCommands(forCloneAt: clone.path),
            reproCommand: nil
        )

        #expect(
            outcome.blockedStage != "build",
            """
            the harness blocked this change at the build leg. What it read:
            \(Bug5WhimprflowClone.lastLines(ofOutput: outcome.blockedOutputTail ?? "", count: 12))
            """
        )
        #expect(
            outcome.build == .passed,
            "the build leg finished as \(outcome.build) — the change was judged by a command that never compiled it"
        )
    }
}

// MARK: - Half 2. The dirt a package manager leaves is not the reader's work

/// Serialized for the same reason: real git, and one of these drives real pnpm.
@MainActor
@Suite(.serialized)
struct Bug5DirtyCloneChurnTests {

    /// THE LOOP, end to end, with nothing simulated. Start from a clone the
    /// reader has not touched, let Iris run its own verification build, then
    /// ask the preflight gate — its own `git status --porcelain`, its own
    /// report — what it makes of the tree afterwards.
    ///
    /// It fails on the unfixed code because BOTH halves are wrong, and it is
    /// still failing when only one of them is fixed — which is the reason this
    /// is filed as one bug and not two. Fix the gate alone and pnpm keeps
    /// failing the build. Fix the build alone and a build that SUCCEEDS still
    /// leaves `ui/pnpm-lock.yaml` and `src-tauri/Cargo.lock` behind, so the
    /// next run refuses over those instead.
    ///
    /// On the reader's newer pnpm the dirt this leaves includes the rewritten
    /// `ui/pnpm-workspace.yaml` from his 12:28:41; on the pinned 10.30.0 it is
    /// the generated lockfiles. Same shape, same refusal, and both are pinned
    /// exactly by the two deterministic tests below.
    @Test func aVerificationBuildLeavesBehindTheDirtThatRefusesTheNextRun() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }
        guard try await clone.theToolchainThisReproNeedsIsReachable() else { return }

        // The clone the reader has not touched. If this is not true the test
        // below proves nothing, so it is asserted rather than assumed.
        let beforeTheBuild = try await clone.dirtyTreeReportTheGateWouldRead()
        #expect(
            beforeTheBuild.isDirty == false,
            "the fixture started dirty: \(beforeTheBuild.pathsForTheRunLog)"
        )

        let commands = Bug5WhimprflowClone.resolvedVerificationCommands(forCloneAt: clone.path)
        _ = try await clone.runner.run(
            try #require(commands.buildCommand),
            inSubdirectory: commands.commandSubdirectory,
            deadline: 600
        )

        // The gate's own read, through the gate's own command, of the tree
        // Iris's own verification build just left behind.
        let report = try await clone.dirtyTreeReportTheGateWouldRead()
        #expect(
            report.isDirty == false,
            "the next run stops before touching anything: the clone has uncommitted changes (\(report.pathsForTheRunLog)) — every one of them written by a tool Iris ran, not by the reader"
        )
    }

    /// The placeholder on its own, with no pnpm and no network: exactly the two
    /// lines his log shows at 12:28:41, appended to a tracked workspace file.
    /// Deterministic, so this one pins the rule rather than the weather.
    @Test func thePlaceholderPnpmWritesIsNotTheReadersWork() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }

        clone.append(
            toFile: "ui/pnpm-workspace.yaml",
            "allowBuilds:\n  esbuild: set this to true or false\n"
        )

        let report = try await clone.dirtyTreeReportTheGateWouldRead()
        #expect(
            report.isDirty == false,
            "Iris refused over its own tool's approval bookkeeping: \(report.pathsForTheRunLog)"
        )
    }

    /// Test 9's shape, one package manager over: the kneecap checkout's only
    /// dirty file was `bun.lock`, written the exact second `bun install`
    /// succeeded. A lockfile is generated output — every one of these is
    /// rebuilt on demand by the tool that wrote it — so none of them is a
    /// reason to refuse to start.
    @Test func aGeneratedLockfileIsNotTheReadersWorkEither() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }

        // Tracked and modified (bun.lock, Test 9's file) …
        clone.append(toFile: "bun.lock", "\n# rewritten by bun install\n")
        // … and untracked, which is what a first install leaves (Test 10's
        // successful build left exactly these two behind).
        clone.write("ui/pnpm-lock.yaml", "lockfileVersion: '11.0'\n")
        clone.write("src-tauri/Cargo.lock", "version = 4\n")

        let report = try await clone.dirtyTreeReportTheGateWouldRead()
        #expect(
            report.isDirty == false,
            "Iris refused over generated lockfiles: \(report.pathsForTheRunLog)"
        )
    }

    /// THE GUARD RAIL, and it passes today — it is here so that whatever makes
    /// the three tests above pass cannot be "stop refusing over that file".
    /// The dirty gate exists because the engine reverts with `git clean -fd`,
    /// which would delete a reader's real work; a hand-edited workspace file is
    /// real work and must still stop the run, in the same file the placeholder
    /// lives in.
    @Test func aRealHandEditToTheSameWorkspaceFileStillStopsTheRun() async throws {
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }

        clone.append(toFile: "ui/pnpm-workspace.yaml", "  - 'packages/*'\n")

        let report = try await clone.dirtyTreeReportTheGateWouldRead()
        #expect(
            report.isDirty,
            "a reader's own edit to their workspace config must still stop the run"
        )
        #expect(
            report.refusalSentence(appName: "whimprflow").contains("ui/pnpm-workspace.yaml"),
            "and the refusal must still name it"
        )
    }
}

// MARK: - The same refusal, end to end through the real coordinator

/// Run 1 of the field sequence, driven through the real
/// `OnDemandEditCoordinator` rather than through the pieces it calls.
///
/// GATED, exactly like `Test7DirtyCloneRefusalTests`: the coordinator's live
/// eligibility check requires a connected model provider, and that gate is
/// deliberately not stubbable. Nothing here ever calls a model (the engine seam
/// is stubbed), but on a machine with no provider connected these no-op rather
/// than fail — which is why the deterministic suites above, not this one, are
/// what proves the bug.
@MainActor
@Suite(.serialized)
struct Bug5DirtyCloneRefusalEndToEndTests {

    private var canReachTheDirtyTreeGate: Bool {
        MaintainModelProviderResolver.firstAvailable() != nil && MaintainSandbox.isAvailable
    }

    @Test func theRunIsNotRefusedWhenTheOnlyDirtIsPnpmsOwnBookkeeping() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Bug5WhimprflowClone.make()
        defer { clone.remove() }

        // 11:49:33 — the tree as pnpm left it, and as he found it.
        clone.append(
            toFile: "ui/pnpm-workspace.yaml",
            "allowBuilds:\n  esbuild: set this to true or false\n"
        )

        let run = Bug5CoordinatorRun(clone: clone)
        await run.driveToTheStartOfTheRun()

        #expect(
            run.terminalFailureReason == nil,
            "Iris refused to start over a file pnpm wrote: \(run.terminalFailureReason ?? "")"
        )
        #expect(
            run.engineWasEntered,
            "the edit the reader asked for never ran"
        )
    }
}

// MARK: - Harness

/// A real git repository shaped like WhimprFlow, under $HOME because
/// `GitInspectionService.allowedRepositoryPath` refuses anything outside it,
/// and named so no path component reads as Iris's own source tree (which the
/// coordinator refuses structurally).
@MainActor
struct Bug5WhimprflowClone {

    let path: String
    let runner: MaintainShellRunner

    /// The pnpm the fixture pins for itself, via `ui/package.json`'s
    /// `packageManager` field, which pnpm honors by fetching that version.
    ///
    /// PINNED ON PURPOSE, and 10.30.0 rather than the default, for two reasons
    /// that both had to be measured rather than assumed:
    ///
    ///   • the default pnpm on this Mac is 10.0.0, whose ignored-build handling
    ///     is a WARNING that exits 0. A fixture that let the machine's own pnpm
    ///     decide would go green while the reader's machine kept failing.
    ///   • pnpm 11 — the version whose defaults match his log exactly — cannot
    ///     run here at all. `MaintainShellRunner` spawns `/bin/zsh -l`, whose
    ///     `path_helper` puts `/usr/local/bin` at the front of PATH, so `pnpm`
    ///     resolves to a corepack shim whose `#!/usr/bin/env node` finds this
    ///     Mac's `/usr/local/bin/node` v21.5.0 (Dec 2023). pnpm 11 dies on it
    ///     with ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING before reading a single
    ///     config file — a different failure, and not this bug's.
    ///
    /// 10.30.0 runs on that node and reproduces the mechanism exactly: the
    /// dependency-status check spawns its OWN `pnpm install` before the script
    /// (`runDepsStatusCheck` in the trace, exactly as in his log), and that
    /// install hard-fails with ERR_PNPM_IGNORED_BUILDS. What 10.30.0 does NOT
    /// do is write the `allowBuilds:` placeholder his 12:28:41 file holds —
    /// that arrived in a later pnpm — so the placeholder is pinned separately
    /// and deterministically by `thePlaceholderPnpmWritesIsNotTheReadersWork`.
    static let pinnedPnpmVersion = "10.30.0"

    /// The dependency whose build script is the unreviewed one. Its postinstall
    /// (`node install.js`) is real work — this is not a synthetic script chosen
    /// to trip a gate, it is the package his own log names.
    static let unreviewedBuildScriptDependency = "esbuild"

    /// Five files, because run 3 edited five. Only `main` is the bundle's entry
    /// point, so an edit to the other four cannot change whether the build
    /// compiles — which leaves the toolchain as the only thing that can fail it.
    static let frontendSourceFileNames = ["main", "recorder", "transcript", "settings", "hotkey"]

    static func make() throws -> Bug5WhimprflowClone {
        let containingDirectory = NSHomeDirectory() + "/.iris-bug5-clones/\(UUID().uuidString)"
        let clonePath = containingDirectory + "/whimprflow"
        let fileManager = FileManager.default
        for subdirectory in ["src-tauri/src", "ui/src"] {
            try fileManager.createDirectory(
                atPath: clonePath + "/" + subdirectory, withIntermediateDirectories: true
            )
        }
        let clone = Bug5WhimprflowClone(
            path: clonePath, runner: try MaintainShellRunner(repoRootPath: clonePath)
        )

        // Build outputs and dependency trees are ignored the way a real project
        // ignores them, so the dirt left behind is only the bookkeeping this
        // bug is about rather than a node_modules tree nobody would count.
        clone.write(".gitignore", "node_modules/\ntarget/\ndist/\n")

        // The Tauri config, with the frontend hook the detector lifts verbatim.
        clone.write("src-tauri/tauri.conf.json", """
        {
          "build": {
            "beforeBuildCommand": "pnpm build",
            "frontendDist": "../ui/dist"
          }
        }
        """)
        clone.write("src-tauri/Cargo.toml", """
        [package]
        name = "whimprflow"
        version = "0.1.0"
        edition = "2021"

        [[bin]]
        name = "whimprflow"
        path = "src/main.rs"
        """)
        clone.write("src-tauri/src/main.rs", "fn main() { println!(\"whimprflow\"); }\n")

        // The frontend package: no package.json at the repo root, which is the
        // WhimprFlow shape and the reason the hook needs its own `cd`.
        clone.write("ui/package.json", """
        {
          "name": "whimprflow-ui",
          "private": true,
          "packageManager": "pnpm@\(pinnedPnpmVersion)",
          "scripts": { "build": "esbuild src/main.js --bundle --outfile=dist/main.js" },
          "devDependencies": { "\(unreviewedBuildScriptDependency)": "0.25.0" }
        }
        """)
        // The workspace file, carrying as EXPLICIT settings the two behaviours
        // that are pnpm 11's defaults and that his machine therefore had for
        // free: an install runs before `pnpm <script>`, and an unreviewed
        // dependency build script fails the install rather than warning about
        // it. Declared here so the pinned 10.30.0 behaves the way the reader's
        // pnpm behaved, instead of the fixture quietly testing older defaults.
        // `packages:` sits last so a later append reads as a plausible edit to
        // it — which is what both the churn tests and the guard rail do.
        clone.write(
            "ui/pnpm-workspace.yaml",
            "strictDepBuilds: true\nverifyDepsBeforeRun: install\npackages:\n  - '.'\n"
        )
        for sourceFile in frontendSourceFileNames {
            clone.write("ui/src/\(sourceFile).js", "export const \(sourceFile) = 1\n")
        }
        // Test 9's file, so the lockfile rule can be asserted on a TRACKED one.
        clone.write("bun.lock", "{}\n")

        clone.git(["init", "-q"])
        clone.git(["config", "user.email", "t@t"])
        clone.git(["config", "user.name", "t"])
        clone.git(["add", "-A"])
        clone.git(["commit", "-qm", "base"])
        return clone
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    // MARK: The production composition, not a copy of it

    /// The build/test vocabulary this clone is verified by, resolved exactly as
    /// the engine resolves it: derive the recipe by reading the repo, then let
    /// `MaintainTierCFixer` pick between the recipe and the stack defaults.
    /// This is the code path that printed the command in his log.
    static func resolvedVerificationCommands(forCloneAt clonePath: String) -> VerificationCommands {
        MaintainTierCFixer.resolvedVerificationCommands(
            override: nil,
            appStack: .tauri,
            repoRootPath: clonePath,
            derivedRecipe: RepoRecipeService.deriveRecipe(repoRootPath: clonePath)
        )
    }

    /// What the on-demand preflight reads before it decides to refuse: the same
    /// `git status --porcelain`, run through the same runner, parsed by the same
    /// report type (OnDemandEditCoordinator.swift:1163).
    func dirtyTreeReportTheGateWouldRead() async throws -> OnDemandEditDirtyTreeReport {
        let status = try await runner.run("git status --porcelain", deadline: 60)
        // Untrimmed, exactly as the coordinator passes it: porcelain's first
        // status column is usually a space, and trimming eats the first
        // character of the first path.
        return OnDemandEditDirtyTreeReport.read(
            porcelainOutput: status.outputTail, repoRootPath: path
        )
    }

    /// Whether the three tools this repro genuinely needs answer through the
    /// runner Iris would use. Reported as a recorded failure rather than a
    /// silent skip: a repro that quietly passes because pnpm was unreachable is
    /// worse than no repro.
    func theToolchainThisReproNeedsIsReachable() async throws -> Bool {
        let probe = try await runner.run(
            "command -v pnpm && command -v cargo && command -v node", deadline: 120
        )
        guard probe.succeeded else {
            Issue.record(
                "this repro needs pnpm, cargo and node on the runner's PATH; it saw: \(probe.outputTail)"
            )
            return false
        }
        return true
    }

    /// Run 3's shape: five source files edited and left uncommitted, which is
    /// what the verification harness's diff-scope gate expects to find.
    func editFiveSourceFilesTheWayRunThreeDid() {
        for sourceFile in Self.frontendSourceFileNames {
            append(toFile: "ui/src/\(sourceFile).js", "// touched by the edit engine\n")
        }
    }

    // MARK: Files and git

    func write(_ relativePath: String, _ contents: String) {
        try? contents.write(toFile: path + "/" + relativePath, atomically: true, encoding: .utf8)
    }

    func contents(_ relativePath: String) -> String {
        (try? String(contentsOfFile: path + "/" + relativePath, encoding: .utf8)) ?? ""
    }

    func append(toFile relativePath: String, _ addition: String) {
        write(relativePath, contents(relativePath) + addition)
    }

    /// The last few lines of a command's output — a failure message is at the
    /// end, and the whole tail would bury it in install progress.
    static func lastLines(ofOutput output: String, count: Int) -> String {
        output.components(separatedBy: "\n").suffix(count).joined(separator: "\n")
    }

    @discardableResult
    func git(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = Pipe()
        try? process.run()
        let data = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Records whether the jailed engine was ever entered. A class so the stubbed
/// engine closure and the test can share one answer across concurrency domains.
final class Bug5EngineEntryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }
    var wasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }
}

/// Drives the real coordinator — pick, describe, plan, start — with the ENGINE
/// stubbed and nothing else, so every gate the reader hits here is the real one.
@MainActor
final class Bug5CoordinatorRun {
    let coordinator: OnDemandEditCoordinator
    private let engineEntry = Bug5EngineEntryFlag()

    var engineWasEntered: Bool { engineEntry.wasEntered }

    init(clone: Bug5WhimprflowClone) {
        let provenanceStore = InstallProvenanceStore(
            userDefaults: UserDefaults(suiteName: "iris.bug5.\(UUID().uuidString)")!
        )
        provenanceStore.recordGuideSourceClone(
            appSlug: "whimprflow", clonePath: clone.path, pinnedCommit: nil, canonicalRepo: nil
        )
        let engineEntry = self.engineEntry
        self.coordinator = OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(
                baseDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iris-bug5-\(UUID().uuidString)")
            ),
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: { _, _, _, _, _, _, _, _, _, _, _ in
                engineEntry.markEntered()
                return .couldNotComplete(reason: "the engine is stubbed in this test")
            }
        )
    }

    var terminalFailureReason: String? {
        switch coordinator.phase {
        case .failed(let reason), .notEligible(let reason): return reason
        default: return nil
        }
    }

    func driveToTheStartOfTheRun() async {
        coordinator.pickApp(slug: "whimprflow", name: "whimprflow", stack: .tauri)
        guard coordinator.phase == .describe else {
            Issue.record("the app was not eligible: \(String(describing: terminalFailureReason))")
            return
        }
        coordinator.describeRequest("make the hotkey configurable", kind: .feature)
        _ = await Bug5Wait.until(timeout: 30) {
            self.coordinator.phase == .presentingPlan || self.coordinator.phase == .clarifying
        }
        if coordinator.phase == .clarifying {
            var answersByQuestionId: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                answersByQuestionId[question.id] =
                    question.options.first { !$0.lowercased().hasPrefix("stop") }
                    ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answersByQuestionId)
        }
        _ = await Bug5Wait.until(timeout: 30) { self.coordinator.phase == .presentingPlan }
        coordinator.confirmPlanAndStart()
        _ = await Bug5Wait.until(timeout: 120) {
            self.terminalFailureReason != nil || self.engineEntry.wasEntered
        }
    }
}

enum Bug5Wait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
