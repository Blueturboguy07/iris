//
//  OnDemandEditInterruptedRunRecoveryTests.swift
//  leanring-buddyTests
//
//  The Sep 3 2026 WhimprFlow orphan: Iris quit on the manifest-consent card
//  with two of its own edits sitting uncommitted in the reader's clone, and
//  the next run refused the clone and blamed the reader. See the header of
//  `OnDemandEditInterruptedRunRecovery.swift`.
//
//  Real git in a scratch repository, never the reader's clones.
//

import Foundation
import Testing
@testable import Iris

@Suite(.serialized)
struct OnDemandEditInterruptedRunRecoveryTests {

    // MARK: - Fixtures

    private struct ScratchRepo {
        let root: URL
        let recordPath: String
        let runLogPath: String
        var path: String { root.path }

        func git(_ arguments: [String]) -> OnDemandEditInterruptedRunRecovery.GitResult {
            OnDemandEditInterruptedRunRecovery.runGit(arguments, in: path)
        }

        func write(_ relativePath: String, _ text: String) throws {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        func read(_ relativePath: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }

        var head: String {
            git(["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var porcelain: String {
            git(["status", "--porcelain", "--untracked-files=all"]).output
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    private func aScratchRepo() throws -> ScratchRepo {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = ScratchRepo(
            root: root,
            recordPath: base.appendingPathComponent("in-flight.json").path,
            runLogPath: base.appendingPathComponent("run.log").path
        )
        try "Iris on-demand edit — scratch\n".write(toFile: repo.runLogPath, atomically: true, encoding: .utf8)
        #expect(repo.git(["init", "-q", "-b", "main"]).exitCode == 0)
        _ = repo.git(["config", "user.email", "iris-tests@example.invalid"])
        _ = repo.git(["config", "user.name", "Iris tests"])
        try repo.write("src-tauri/src/lib.rs", "fn main() {}\n")
        try repo.write("src-tauri/src/paste.rs", "pub fn paste() {}\n")
        try repo.write("README.md", "scratch\n")
        _ = repo.git(["add", "-A"])
        #expect(repo.git(["commit", "-q", "-m", "base"]).exitCode == 0)
        return repo
    }

    private func aRecord(for repo: ScratchRepo, paths: [String], waitingOn: String? = "your answer to \"Add the Rust crate block2 0.6 to src-tauri/Cargo.toml\"") -> OnDemandEditInFlightRecord {
        OnDemandEditInFlightRecord(
            appSlug: "whimprflow",
            clonePath: repo.path,
            baseCommit: repo.head,
            pathsIrisEdited: paths,
            startedAt: Date(),
            runLogPath: repo.runLogPath,
            whatIrisWasWaitingFor: waitingOn
        )
    }

    // MARK: - 1. The report, replayed

    /// Iris edited two files, parked on the consent card, and went away. At
    /// the next launch exactly those two files go back, the record is gone,
    /// and the run log says what happened.
    @Test func theSep3OrphanIsRevertedAtTheNextLaunch() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }

        // What the engine did at 16:04:26 — one edit, one new file.
        try repo.write("src-tauri/src/lib.rs", "fn main() { request_microphone_access(); }\n")
        try repo.write("src-tauri/src/mic.rs", "pub fn request_microphone_access() {}\n")
        #expect(repo.porcelain.isEmpty == false)
        OnDemandEditInterruptedRunRecovery.remember(
            aRecord(for: repo, paths: ["src-tauri/src/lib.rs", "src-tauri/src/mic.rs"]),
            recordPath: repo.recordPath
        )

        let outcome = OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: repo.recordPath)

        #expect(outcome == .revertedIrisOwnEdits(clonePath: repo.path, paths: ["src-tauri/src/lib.rs", "src-tauri/src/mic.rs"]))
        #expect(repo.porcelain.isEmpty, "the clone is not clean after recovery: \(repo.porcelain)")
        #expect(repo.read("src-tauri/src/lib.rs") == "fn main() {}\n")
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("src-tauri/src/mic.rs").path) == false)
        #expect(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: repo.recordPath) == nil)

        let runLog = try #require(try? String(contentsOfFile: repo.runLogPath, encoding: .utf8))
        #expect(runLog.contains("recovery: Iris went away before this run finished"))
        #expect(runLog.contains("waiting on your answer to"))
        #expect(runLog.contains("were reverted; the clone is clean again"))
    }

    // MARK: - 2. The reader's own work is never touched

    /// A file Iris did not edit is dirty too: nothing is reverted, the record
    /// stays, and the dirty-clone card can say which files were Iris's.
    @Test func aTreeWithTheReadersOwnWorkIsLeftAloneAndNamed() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }

        try repo.write("src-tauri/src/lib.rs", "fn main() { changed_by_iris(); }\n")
        try repo.write("README.md", "the reader's own notes\n")
        let record = aRecord(for: repo, paths: ["src-tauri/src/lib.rs"])
        OnDemandEditInterruptedRunRecovery.remember(record, recordPath: repo.recordPath)

        let outcome = OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: repo.recordPath)

        guard case .leftAlone(let clonePath, let reason, let pathsIrisEdited) = outcome else {
            Issue.record("expected .leftAlone, got \(outcome)")
            return
        }
        #expect(clonePath == repo.path)
        #expect(reason.contains("README.md"))
        #expect(pathsIrisEdited == ["src-tauri/src/lib.rs"])
        // Untouched, both of them.
        #expect(repo.read("src-tauri/src/lib.rs") == "fn main() { changed_by_iris(); }\n")
        #expect(repo.read("README.md") == "the reader's own notes\n")
        // The record stays (dates lose their sub-second part in the file, so
        // the fields that matter are compared rather than the whole value).
        let recordStillOnDisk = OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: repo.recordPath)
        #expect(recordStillOnDisk?.clonePath == record.clonePath)
        #expect(recordStillOnDisk?.baseCommit == record.baseCommit)
        #expect(recordStillOnDisk?.pathsIrisEdited == record.pathsIrisEdited)

        // The card, next time: names Iris's file as Iris's, and the reader's as
        // the reader's.
        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: repo.porcelain, repoRootPath: repo.path,
            leftByAnInterruptedIrisEdit: record
        )
        #expect(report.pathsThatWereIriss == ["src-tauri/src/lib.rs"])
        let sentence = report.refusalSentence(appName: "WhimprFlow")
        #expect(sentence.contains("1 of these (src-tauri/src/lib.rs) were written by an Iris edit that never finished"))
        #expect(sentence.contains("while waiting on your answer to"))
        #expect(sentence.contains("They are not your work"))
    }

    /// When EVERY dirty file was Iris's, the note says so without a count.
    @Test func whenAllTheDirtyFilesWereIrissTheNoteSaysSo() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }
        try repo.write("src-tauri/src/lib.rs", "fn main() { changed(); }\n")
        try repo.write("src-tauri/src/paste.rs", "pub fn paste() { changed(); }\n")
        let record = aRecord(for: repo, paths: ["src-tauri/src/lib.rs", "src-tauri/src/paste.rs"], waitingOn: nil)

        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: repo.porcelain, repoRootPath: repo.path,
            leftByAnInterruptedIrisEdit: record
        )
        let sentence = report.refusalSentence(appName: "WhimprFlow")
        #expect(sentence.contains("Those changes were written by an Iris edit that never finished — Iris went away, so they were never committed or reverted."))
    }

    // MARK: - 3. A stale record

    /// The run committed after all (HEAD moved): the record is stale and goes;
    /// whatever is dirty now is not Iris's orphan and is not touched.
    @Test func aRecordWhoseRunCommittedIsForgottenWithoutTouchingTheTree() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }
        let record = aRecord(for: repo, paths: ["src-tauri/src/lib.rs"])
        OnDemandEditInterruptedRunRecovery.remember(record, recordPath: repo.recordPath)

        try repo.write("src-tauri/src/lib.rs", "fn main() { committed(); }\n")
        _ = repo.git(["add", "-A"])
        #expect(repo.git(["commit", "-q", "-m", "On-demand fix"]).exitCode == 0)
        try repo.write("src-tauri/src/lib.rs", "fn main() { the_readers_later_work(); }\n")

        let outcome = OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: repo.recordPath)

        #expect(outcome == .theRunHadAlreadyCommitted(clonePath: repo.path))
        #expect(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: repo.recordPath) == nil)
        #expect(repo.read("src-tauri/src/lib.rs") == "fn main() { the_readers_later_work(); }\n")
    }

    @Test func aCleanTreeJustClearsTheRecord() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }
        OnDemandEditInterruptedRunRecovery.remember(aRecord(for: repo, paths: ["src-tauri/src/lib.rs"]), recordPath: repo.recordPath)

        #expect(OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: repo.recordPath) == .theTreeWasAlreadyClean(clonePath: repo.path))
        #expect(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: repo.recordPath) == nil)
    }

    @Test func noRecordMeansNothingHappens() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-no-such-record-\(UUID().uuidString).json").path
        #expect(OnDemandEditInterruptedRunRecovery.recoverNow(recordPath: missing) == .nothingToRecover)
    }

    // MARK: - 4. Plumbing

    @Test func theRecordSurvivesARoundTrip() throws {
        let repo = try aScratchRepo()
        defer { repo.tearDown() }
        let record = aRecord(for: repo, paths: ["a.rs", "b/c.rs"])
        OnDemandEditInterruptedRunRecovery.remember(record, recordPath: repo.recordPath)
        let readBack = try #require(OnDemandEditInterruptedRunRecovery.recordOnDisk(recordPath: repo.recordPath))
        #expect(readBack.appSlug == record.appSlug)
        #expect(readBack.clonePath == record.clonePath)
        #expect(readBack.baseCommit == record.baseCommit)
        #expect(readBack.pathsIrisEdited == record.pathsIrisEdited)
        #expect(readBack.whatIrisWasWaitingFor == record.whatIrisWasWaitingFor)
        #expect(abs(readBack.startedAt.timeIntervalSince(record.startedAt)) < 1)
    }

    @Test func porcelainIsParsedThePlainWay() {
        let entries = OnDemandEditInterruptedRunRecovery.dirtyEntries(fromPorcelain: """
             M src/a.rs
            ?? src/new.rs
            R  old.rs -> renamed.rs
            A  "with space.rs"

            """)
        #expect(entries == [
            .init(path: "src/a.rs", isUntracked: false),
            .init(path: "src/new.rs", isUntracked: true),
            .init(path: "renamed.rs", isUntracked: false),
            .init(path: "with space.rs", isUntracked: false),
        ])
    }
}
