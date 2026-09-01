//
//  Test7DirtyCloneReproTests.swift
//  leanring-buddyTests
//
//  THE REPORT. Test 7, Akrit, Iris 0.9.1 build 17. He asked for two features on
//  an app he had installed from a publik guide. Both were rejected before
//  anything ran, both with the same sentence:
//
//      "your clone has uncommitted changes — commit or stash them first so
//       Iris never touches your own work"
//
//  and his answer was:
//
//      "i made no changes this doesn't make sense as to why that is the error."
//
//  He was telling the truth AND so was Iris. Runtime inspection of his clone
//  found exactly ONE modification, dated Aug 25 — left behind by an earlier
//  build or guide run, not by him. The refusal was correct and still failed
//  him, for three separate reasons, which are the three suites below:
//
//    1. IT NAMED NOTHING. Iris had just run `git status --porcelain` — it was
//       holding the filename — and each file's date is one `stat` away. It
//       discarded both before speaking, so a reader who had made no changes had
//       no way to see that the sentence was not about him.
//    2. IT WAS A DEAD END. "commit or stash them first" is a shell instruction
//       handed to somebody working in a GUI, and stashing is something Iris can
//       do itself in one tap while HONORING the never-touch-your-work rule
//       better than a dead end does — a stash preserves the work; refusing
//       preserves it and delivers nothing.
//    3. HE COULD NOT COPY IT. "i can't copy paste text on that tab with the
//       error" — a straight regression of the same complaint from Test 4. Every
//       reader-facing line on a failure / blocked / refusal card needs
//       `.textSelection(.enabled)`; the committed-diff block had it and nothing
//       else on the card did.
//
//  The first suite drives the REAL coordinator against a REAL git clone holding
//  a REAL stale modification, so the sentence under test is the one the reader
//  gets rather than a reconstruction of it.
//

import Foundation
import Testing

// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// MARK: - 1 + 2. The refusal, end to end, against a real dirty clone

/// Serialized: each test spawns git inside a real repository under $HOME and
/// drives the whole coordinator, including its live eligibility re-check.
@MainActor
@Suite(.serialized)
struct Test7DirtyCloneRefusalTests {

    /// The live eligibility gate needs a model provider connected, exactly as it
    /// does for a reader. Nothing here ever CALLS one (the engine seam is
    /// stubbed), but that gate is deliberately not stubbable, so on a machine
    /// with no provider these tests no-op rather than fail — the same graceful
    /// skip the Seatbelt-gated engine tests use.
    private var canReachTheDirtyTreeGate: Bool {
        MaintainModelProviderResolver.firstAvailable() != nil && MaintainSandbox.isAvailable
    }

    /// THE RECREATION. One stale modification, six days old, and the refusal
    /// that comes back must NAME it and DATE it.
    ///
    /// At HEAD before the fix this failed on the second expectation: the
    /// sentence was a fixed literal with no path in it, no date, and nothing a
    /// reader who had made no changes could check.
    @Test func theRefusalNamesTheDirtyFileAndDatesIt() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Test7Clone.make()
        defer { clone.remove() }

        // Akrit's clone, reproduced: ONE file, modified, old enough that it
        // plainly predates this sitting.
        clone.leaveAStaleModification(
            inFile: "scripts/dev.sh",
            contents: "#!/bin/sh\necho dev --patched-by-an-earlier-run\n",
            daysAgo: 6
        )

        let run = Test7Run(clone: clone)
        await run.driveToTheDirtyTreeRefusal()
        let reason = try #require(run.terminalFailureReason, "expected a terminal refusal")

        // (1) The engine was never entered. This is a PREFLIGHT rejection, and
        //     nothing anywhere may imply that anything was changed.
        #expect(run.engineWasEntered == false)

        // (2) The refusal names the file.
        #expect(
            reason.contains("scripts/dev.sh"),
            "the refusal must name the dirty file; it said: \(reason)"
        )

        // (3) …and dates it, so "i made no changes" is checkable rather than
        //     contradicted. The format is localized, so the day of the month is
        //     the stable part to assert on.
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        let dayOfMonth = Calendar.current.component(.day, from: sixDaysAgo)
        #expect(
            reason.contains("\(dayOfMonth)"),
            "the refusal must date the change; it said: \(reason)"
        )

        // (4) …and offers the likely explanation, which is the entire content
        //     of his complaint.
        #expect(
            reason.contains("rather than by you"),
            "the refusal must say it probably wasn't him; it said: \(reason)"
        )
    }

    /// A change the reader made MINUTES ago is not blamed on a build. The note
    /// above is evidence-gated, not decoration: saying "this wasn't you" about
    /// something that WAS them would be a new small lie in place of the old one.
    @Test func aFreshChangeIsNotBlamedOnABuild() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Test7Clone.make()
        defer { clone.remove() }
        clone.leaveAStaleModification(
            inFile: "src/app.js", contents: "console.log('mine')\n", daysAgo: 0
        )

        let run = Test7Run(clone: clone)
        await run.driveToTheDirtyTreeRefusal()
        let reason = try #require(run.terminalFailureReason)

        #expect(reason.contains("src/app.js"))
        #expect(!reason.contains("rather than by you"))
    }

    /// THE ONE TAP OUT. "Set aside and continue" stashes — it does not
    /// discard — and then runs the edit the reader already asked for.
    @Test func settingAsideStashesTheWorkAndThenRunsTheEdit() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Test7Clone.make()
        defer { clone.remove() }
        clone.leaveAStaleModification(
            inFile: "scripts/dev.sh",
            contents: "#!/bin/sh\necho dev --patched-by-an-earlier-run\n",
            daysAgo: 6
        )
        // An UNTRACKED file too: the revert this refusal exists to protect
        // against is `git clean -fd`, which DELETES untracked files, so the
        // set-aside has to cover exactly what the danger covers.
        clone.write("notes-from-an-earlier-run.txt", "left behind\n")

        let run = Test7Run(clone: clone)
        await run.driveToTheDirtyTreeRefusal()
        #expect(run.coordinator.dirtyCloneRefusal != nil, "the card must be able to offer the action")

        run.coordinator.setAsideDirtyChangesAndRetry()
        let reachedTheEngine = await Test7Wait.until(timeout: 120) { run.engineWasEnteredNow }
        #expect(reachedTheEngine, "the edit must actually run once the changes are set aside")

        // The work is SET ASIDE, not deleted: one stash, named and dated.
        let stashes = clone.git(["stash", "list"])
        #expect(stashes.contains("iris/set-aside-"), "the stash must be named; got: \(stashes)")

        // AND THE READER IS STILL TOLD WHERE IT WENT. The card's caption
        // promises `git stash pop` BEFORE the tap; after the tap that promise
        // has to survive somewhere the reader can still read, or "set aside"
        // becomes a word they have to take on faith. The retry re-opens the
        // run, and `beginRun` clears the transcript, so the note has to be
        // written on the far side of that — which is not where the first cut of
        // this fix put it.
        let whatTheTerminalSays = run.coordinator.editRunner.transcript.map { entry -> String in
            if case .explanation(let text) = entry { return text }
            return ""
        }.joined(separator: "\n")
        #expect(
            whatTheTerminalSays.contains("iris/set-aside-"),
            "the stash name must survive the retry; the terminal said: \(whatTheTerminalSays)"
        )
        #expect(
            whatTheTerminalSays.contains("git stash pop"),
            "the way back must survive the retry too"
        )
        // And it is genuinely recoverable — the reader's own escape hatch, the
        // one the card's caption promises them.
        clone.git(["stash", "pop"])
        #expect(clone.contents("scripts/dev.sh").contains("patched-by-an-earlier-run"))
        #expect(FileManager.default.fileExists(
            atPath: clone.path + "/notes-from-an-earlier-run.txt"
        ))
    }

    /// The action is never automatic. It lives on a card the reader has to tap;
    /// reaching the refusal must leave the clone byte-identical.
    @Test func nothingIsStashedUntilTheReaderAsks() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Test7Clone.make()
        defer { clone.remove() }
        clone.leaveAStaleModification(
            inFile: "scripts/dev.sh", contents: "#!/bin/sh\necho changed\n", daysAgo: 6
        )

        let run = Test7Run(clone: clone)
        await run.driveToTheDirtyTreeRefusal()

        #expect(clone.git(["stash", "list"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(clone.contents("scripts/dev.sh").contains("echo changed"))
    }

    /// A rejected run still becomes a session exchange — that is how the overlay
    /// remembers it at all — so its recorded outcome must be the honest refusal
    /// and never a claim that something was changed.
    @Test func aRejectedRunIsRememberedAsARefusalNotAsAChange() async throws {
        guard canReachTheDirtyTreeGate else { return }
        let clone = try Test7Clone.make()
        defer { clone.remove() }
        clone.leaveAStaleModification(
            inFile: "scripts/dev.sh", contents: "#!/bin/sh\necho changed\n", daysAgo: 6
        )

        let run = Test7Run(clone: clone)
        await run.driveToTheDirtyTreeRefusal()

        // RUNTIME FINDING 3, as an assertion: this rejection happened BEFORE
        // the engine was ever entered, so no surface may imply otherwise. The
        // terminal is the surface the reader watches while a run is up, and it
        // is the one that opens with "Adding a feature to demo" — so it is the
        // one that could most easily leave a reader believing something was
        // done to their code.
        let whatTheTerminalSays = run.coordinator.editRunner.transcript.map { entry -> String in
            if case .explanation(let text) = entry { return text }
            return ""
        }.joined(separator: "\n").lowercased()
        #expect(whatTheTerminalSays.contains("stopped before touching anything"))
        for claim in ["applied", "rebuilt", "relaunched", "made the change", "on a new branch"] {
            #expect(
                !whatTheTerminalSays.contains(claim),
                "the terminal claims \"\(claim)\" about a run that never started"
            )
        }
        // Nothing ran, so nothing ran a command: a rejected preflight leaves no
        // executed-command rows behind to read as work.
        let anyCommandWasShown = run.coordinator.editRunner.transcript.contains { entry in
            if case .commandFromTheGuide = entry { return true }
            if case .commandFromAFix = entry { return true }
            return false
        }
        #expect(anyCommandWasShown == false)

        run.coordinator.cancel()

        let filed = try #require(run.coordinator.sessionThread.last)
        #expect(filed.outcome.contains("stopped before touching anything"))
    }
}

// MARK: - The porcelain reader, on its own

struct Test7PorcelainReadingTests {

    @Test func everyPorcelainShapeIsNamedCorrectly() {
        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: """
             M scripts/dev.sh
            ?? notes.txt
            A  src/added.js
             D src/gone.js
            R  src/old.js -> src/new.js
            """,
            repoRootPath: "/nowhere-this-path-need-not-exist"
        )
        #expect(report.entries.map(\.path) == [
            "scripts/dev.sh", "notes.txt", "src/added.js", "src/gone.js", "src/new.js",
        ])
        #expect(report.entries.map(\.whatHappenedToIt) == [
            "modified", "untracked", "added", "deleted", "renamed",
        ])
        // Nothing on disk to stat, so no date is invented for any of them.
        #expect(report.entries.allSatisfy { $0.lastModified == nil })
    }

    /// The bug the end-to-end test above caught on its very first run: the
    /// caller trimmed the porcelain block before parsing it, which removed
    /// git's leading status space (` M path`), and the parser's blind
    /// "drop three characters" then ate the first letter of the path — the
    /// refusal told the reader their dirty file was "cripts/dev.sh". A refusal
    /// whose whole job is naming the file must not misname it. The caller no
    /// longer trims; the parser no longer depends on the caller not trimming.
    @Test func aTrimmedBlockStillYieldsTheWholePath() {
        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: "M scripts/dev.sh", repoRootPath: "/nowhere"
        )
        #expect(report.entries.first?.path == "scripts/dev.sh")
    }

    /// Git quotes a path holding unusual bytes. The quotes are Git's, not the
    /// filename's, and a reader should never be shown them.
    @Test func aQuotedPathIsUnquoted() {
        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: " M \"src/a file.js\"", repoRootPath: "/nowhere"
        )
        #expect(report.entries.first?.path == "src/a file.js")
    }

    /// Long lists are counted, not recited: this sentence renders in a 320pt bar
    /// floating over somebody's desktop.
    @Test func aLongListIsCountedRatherThanRecited() {
        let porcelain = (1...9).map { " M src/file\($0).js" }.joined(separator: "\n")
        let report = OnDemandEditDirtyTreeReport.read(
            porcelainOutput: porcelain, repoRootPath: "/nowhere"
        )
        let sentence = report.refusalSentence(appName: "demo")
        #expect(sentence.contains("9 changes that aren't committed"))
        #expect(sentence.contains("src/file1.js"))
        #expect(sentence.contains("and 6 more"))
        #expect(!sentence.contains("src/file9.js"))
    }

    /// The age note is a claim about evidence, and is made only when the
    /// evidence is there.
    @Test func theAgeNoteFollowsTheDatesAndNothingElse() {
        let path = "scripts/dev.sh"
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 60 * 60)
        let old = OnDemandEditDirtyTreeReport(entries: [
            .init(path: path, statusCode: " M", lastModified: sixDaysAgo),
        ])
        #expect(old.probablyNotTheReadersNote()?.contains("6 days old") == true)

        let fresh = OnDemandEditDirtyTreeReport(entries: [
            .init(path: path, statusCode: " M", lastModified: Date()),
        ])
        #expect(fresh.probablyNotTheReadersNote() == nil)

        // A deletion leaves no file to stat. No date, so no claim about one.
        let undatable = OnDemandEditDirtyTreeReport(entries: [
            .init(path: path, statusCode: " D", lastModified: nil),
        ])
        #expect(undatable.probablyNotTheReadersNote() == nil)
        #expect(undatable.refusalSentence(appName: "demo").contains("scripts/dev.sh (deleted)"))
    }

    /// The stash name is an identifier written into somebody's repository, so
    /// its shape must not follow the machine's locale.
    @Test func theStashNameIsStableAndFindable() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 25
        let august25 = Calendar(identifier: .gregorian).date(from: components)!
        #expect(
            OnDemandEditCoordinator.setAsideStashName(now: august25) == "iris/set-aside-2026-08-25"
        )
    }
}

// MARK: - 3. "i can't copy paste text on that tab with the error"

/// A SwiftUI modifier cannot be observed from a unit test, and what went wrong
/// is an ABSENCE — so this reads the card's own source and states the absence
/// directly, the way `OverlayEyeBarDoesNotDelegateToTheOldPanelTests` pins a
/// deletion. The rule: inside the failure, blocked and refusal cards, every
/// `Text(` carries `.textSelection(.enabled)`.
struct Test7FailureCardTextIsSelectableTests {

    private static var sourceOfTheCard: String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()      // leanring-buddyTests
            .deletingLastPathComponent()      // iris-macos
        let cardSourceURL = repositoryRoot
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("OnDemandEditCard.swift")
        return (try? String(contentsOf: cardSourceURL, encoding: .utf8)) ?? ""
    }

    /// From a declaration to the next `// MARK:`, capped so a section with no
    /// MARK after it cannot swallow the rest of the file and pass on somebody
    /// else's modifier.
    private static func source(
        ofDeclarationMatching needle: String, in source: String, lines maximumLines: Int
    ) -> String {
        guard let start = source.range(of: needle) else { return "" }
        let rest = source[start.lowerBound...]
        let upToTheNextSection = rest.range(of: "\n    // MARK:").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        return upToTheNextSection
            .components(separatedBy: "\n").prefix(maximumLines).joined(separator: "\n")
    }

    @Test func everyReaderFacingLineOnAFailureCardIsSelectable() {
        let cardSource = Self.sourceOfTheCard
        // A missing or unreadable file must fail loudly rather than pass by
        // finding nothing inside an empty string.
        #expect(cardSource.contains("struct OnDemandEditCard"), "the card's source could not be read")

        for declaration in ["private func terminalMessageCard(", "private func blockedByModelCard("] {
            let body = Self.source(ofDeclarationMatching: declaration, in: cardSource, lines: 140)
            #expect(!body.isEmpty, "\(declaration) not found in the card's source")
            let lines = body.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("Text(") {
                // The modifier sits on the chain under the `Text(`; six lines is
                // wider than any modifier chain in this file.
                let modifierChain = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")
                #expect(
                    modifierChain.contains(".textSelection(.enabled)"),
                    "\(declaration) — this line is not selectable: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    /// SELECTION IS ONLY HALF OF IT, AND THE OTHER HALF IS WHY HE COULDN'T COPY.
    ///
    /// The card renders inside the eye's input-bar panel, and that panel's
    /// `canBecomeKey` is false in every phase except "a question is being
    /// composed" — deliberately, because a panel that keeps the keyboard
    /// swallows the reader's typing in their own app. A window that cannot
    /// become key is never sent a key event, so ⌘C over a failure card has
    /// nowhere to land however selectable the text is. A button is not a key
    /// event, so both terminal cards carry one.
    @Test func bothFailureCardsOfferACopyButtonThatNeedsNoKeyWindow() {
        let cardSource = Self.sourceOfTheCard
        #expect(cardSource.contains("struct OnDemandEditCard"), "the card's source could not be read")
        for declaration in ["private func terminalMessageCard(", "private func blockedByModelCard("] {
            let body = Self.source(ofDeclarationMatching: declaration, in: cardSource, lines: 140)
            #expect(
                body.contains("copyTheseWordsButton("),
                "\(declaration) offers no way to copy its words without a key window"
            )
        }
        // And the pasteboard write itself is real, not a label.
        #expect(cardSource.contains("NSPasteboard.general.setString"))
    }

    /// What lands on the clipboard is what was on screen — heading included,
    /// empty slots left out.
    @Test func theCopiedTextIsEverythingTheReaderCanSee() {
        let copied = OnDemandEditFailureText.everythingOnTheCard(
            title: "Your clone has changes Iris won't touch",
            lines: ["Iris stopped before touching anything: …", "", "Nothing was changed."]
        )
        #expect(copied == """
        Your clone has changes Iris won't touch

        Iris stopped before touching anything: …

        Nothing was changed.
        """)
    }

    /// The shared header is reader-facing text on those same cards, and it is
    /// where a reader copying a failure naturally starts the selection.
    @Test func theCardHeaderIsSelectableToo() {
        let header = Self.source(
            ofDeclarationMatching: "private func header(icon:", in: Self.sourceOfTheCard, lines: 20
        )
        #expect(!header.isEmpty, "the header helper was not found")
        #expect(header.contains(".textSelection(.enabled)"), "the card header is not selectable")
    }
}

// MARK: - Harness

/// A real git clone under $HOME, shaped like an app installed from a publik
/// guide. Under $HOME because `GitInspectionService.allowedRepositoryPath`
/// refuses anything outside it, and named so that no path component reads as
/// Iris's own source tree, which the coordinator refuses structurally.
@MainActor
struct Test7Clone {
    let path: String

    static func make() throws -> Test7Clone {
        let containingDirectory = NSHomeDirectory() + "/.iris-test7-clones/\(UUID().uuidString)"
        let clone = Test7Clone(path: containingDirectory + "/demo-app")
        try FileManager.default.createDirectory(
            atPath: clone.path + "/scripts", withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: clone.path + "/src", withIntermediateDirectories: true
        )
        // A package.json with a build script is what makes this app eligible at
        // all — Iris refuses an app it has no way to rebuild.
        clone.write("package.json", #"{"name":"demo","scripts":{"build":"true","test":"true"}}"#)
        clone.write("scripts/dev.sh", "#!/bin/sh\necho dev\n")
        clone.write("src/app.js", "console.log('hi')\n")
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

    func write(_ relativePath: String, _ contents: String) {
        try? contents.write(toFile: path + "/" + relativePath, atomically: true, encoding: .utf8)
    }

    func contents(_ relativePath: String) -> String {
        (try? String(contentsOfFile: path + "/" + relativePath, encoding: .utf8)) ?? ""
    }

    /// The thing that was actually on Akrit's machine: a modification nobody
    /// remembers making, carrying the date of whatever left it there.
    func leaveAStaleModification(inFile relativePath: String, contents: String, daysAgo: Int) {
        write(relativePath, contents)
        let whenItWasLeft = Date().addingTimeInterval(-Double(daysAgo) * 24 * 60 * 60)
        try? FileManager.default.setAttributes(
            [.modificationDate: whenItWasLeft], ofItemAtPath: path + "/" + relativePath
        )
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
final class Test7EngineEntryFlag: @unchecked Sendable {
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

/// Drives the whole real flow — pick, describe, plan, start — with the ENGINE
/// stubbed and nothing else. Every gate the reader hits here is the real one.
@MainActor
final class Test7Run {
    let coordinator: OnDemandEditCoordinator
    private let engineEntry = Test7EngineEntryFlag()
    private(set) var engineWasEntered = false

    /// The live reading, for waiting on the retry.
    var engineWasEnteredNow: Bool { engineEntry.wasEntered }

    init(clone: Test7Clone) {
        let provenanceStore = InstallProvenanceStore(
            userDefaults: UserDefaults(suiteName: "iris.test7.\(UUID().uuidString)")!
        )
        provenanceStore.recordGuideSourceClone(
            appSlug: "demo", clonePath: clone.path, pinnedCommit: nil, canonicalRepo: nil
        )
        let engineEntry = self.engineEntry
        self.coordinator = OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(
                baseDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iris-test7-\(UUID().uuidString)")
            ),
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            // The two model-derived clarification triggers, stubbed quiet: this
            // is a test about a preflight, and no model is reachable from it.
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

    func driveToTheDirtyTreeRefusal() async {
        coordinator.pickApp(slug: "demo", name: "demo", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was not eligible: \(String(describing: terminalFailureReason))")
            return
        }
        coordinator.describeRequest("add a settings window", kind: .feature)
        _ = await Test7Wait.until(timeout: 30) {
            self.coordinator.phase == .presentingPlan || self.coordinator.phase == .clarifying
        }
        if coordinator.phase == .clarifying {
            // Answer every question with its first option that is not a "Stop".
            var answersByQuestionId: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                answersByQuestionId[question.id] =
                    question.options.first { !$0.lowercased().hasPrefix("stop") }
                    ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answersByQuestionId)
        }
        _ = await Test7Wait.until(timeout: 30) { self.coordinator.phase == .presentingPlan }
        coordinator.confirmPlanAndStart()
        _ = await Test7Wait.until(timeout: 90) { self.terminalFailureReason != nil }
        engineWasEntered = engineEntry.wasEntered
    }
}

enum Test7Wait {
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
