//
//  MaintainFileEditApplierTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Iris

@Suite struct MaintainFileEditApplierTests {

    private static func makeRepo() -> String {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-fileedit-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        return repo
    }

    @Test func parsesWholeFileWritePreservingPathCase() {
        let reply = "Rewriting it.\n```write src/Foo.rs\nfn main() {}\nlet x = 1;\n```"
        let requests = MaintainFileEditApplier.parse(fromModelReply: reply)
        #expect(requests == [.writeWholeFile(filePath: "src/Foo.rs", content: "fn main() {}\nlet x = 1;")])
    }

    @Test func parsesSearchReplaceEdit() {
        let reply = "```edit src/a.rs\n<<<<<<< SEARCH\nold line\n=======\nnew line\n>>>>>>> REPLACE\n```"
        let requests = MaintainFileEditApplier.parse(fromModelReply: reply)
        #expect(requests == [.replaceInFile(filePath: "src/a.rs", search: "old line", replace: "new line")])
    }

    @Test func writeCreatesAndReplacesFileContentsAtomically() throws {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        let result = MaintainFileEditApplier.applyToRepo(
            .writeWholeFile(filePath: "src/new.rs", content: "line1\nline2\n"), repoRootPath: repo
        )
        #expect((try? result.get()) != nil)
        #expect((try? String(contentsOfFile: repo + "/src/new.rs", encoding: .utf8)) == "line1\nline2\n")
    }

    @Test func replaceRequiresExactlyOneMatch() throws {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        try "a\nTARGET\nb\nTARGET\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        // Two matches → refused, file untouched.
        let twice = MaintainFileEditApplier.applyToRepo(
            .replaceInFile(filePath: "f.txt", search: "TARGET", replace: "X"), repoRootPath: repo
        )
        if case .failure(.searchTextFoundMoreThanOnce) = twice {} else { Issue.record("expected ambiguous-match refusal") }
        #expect((try? String(contentsOfFile: repo + "/f.txt", encoding: .utf8)) == "a\nTARGET\nb\nTARGET\n")
        // A unique match applies.
        try "a\nONLY\nb\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
        _ = MaintainFileEditApplier.applyToRepo(
            .replaceInFile(filePath: "g.txt", search: "ONLY", replace: "DONE"), repoRootPath: repo
        )
        #expect((try? String(contentsOfFile: repo + "/g.txt", encoding: .utf8)) == "a\nDONE\nb\n")
    }

    @Test func buildScriptFilesAreRefusedAndRouteToManifest() {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        let result = MaintainFileEditApplier.applyToRepo(
            .writeWholeFile(filePath: "Cargo.toml", content: "[package]\n"), repoRootPath: repo
        )
        if case .failure(.fileIsABuildScript) = result {} else { Issue.record("expected build-script refusal") }
    }

    @Test func pathEscapesAreRefused() {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        for bad in ["../evil.rs", "/etc/passwd", "~/secret", "a/../../b.rs"] {
            let result = MaintainFileEditApplier.applyToRepo(
                .writeWholeFile(filePath: bad, content: "x"), repoRootPath: repo
            )
            if case .failure = result {} else { Issue.record("\(bad) should be refused") }
        }
    }

    // MARK: - A block that could not be read is reported, never dropped

    /// A whole-file write of a document that itself contains a fenced code
    /// block is the ordinary case for a README or a docs page, and it used to
    /// be SILENT DATA LOSS: the inner block's closing ``` line ended the write,
    /// the truncated file was written, and `applyToRepo` reported success. A
    /// build and a test suite do not catch a docs file that lost its second
    /// half. A longer opening fence now delimits such a write, exactly as it
    /// does in Markdown itself.
    @Test func aWriteFencedWithFourBackticksSurvivesAnInnerFence() {
        let reply = """
        Documenting the filters.
        ````write docs/FILTERS.md
        # Filters

        ```js
        rows.filter(Boolean)
        ```

        That is the whole list.
        ````
        """
        let requests = MaintainFileEditApplier.parse(fromModelReply: reply)
        guard case .writeWholeFile(let filePath, let content)? = requests.first else {
            Issue.record("expected one whole-file write, got \(requests)")
            return
        }
        #expect(filePath == "docs/FILTERS.md")
        #expect(content.contains("rows.filter(Boolean)"))
        // The half that used to be thrown away.
        #expect(content.contains("That is the whole list."))
    }

    /// A malformed block used to parse to an EMPTY request list, which is
    /// byte-identical to "this reply contained no edit at all" — so the loop
    /// fell through its whole dispatch and told the model to "reply with
    /// exactly one ```bash fenced command", advice about a mistake it had not
    /// made. Now the reason comes back with the requests.
    @Test func aMalformedEditBlockIsReportedRatherThanVanishing() {
        let noMarkers = MaintainFileEditApplier.parseDetailed(
            fromModelReply: "```edit src/a.rs\njust some replacement text\n```"
        )
        #expect(noMarkers.requests.isEmpty)
        #expect(noMarkers.rejections == [.editBlockHasNoSearchReplaceMarkers(path: "src/a.rs")])
        #expect(noMarkers.replyAttemptedAFileEdit)

        let unclosed = MaintainFileEditApplier.parseDetailed(
            fromModelReply: "```write src/b.rs\nfn main() {}\n"
        )
        #expect(unclosed.requests.isEmpty)
        #expect(unclosed.rejections == [.blockFenceWasNeverClosed(verb: "write", path: "src/b.rs")])

        let noPath = MaintainFileEditApplier.parseDetailed(
            fromModelReply: "```write\nfn main() {}\n```"
        )
        #expect(noPath.requests.isEmpty)
        #expect(noPath.rejections == [.blockNamesNoFilePath(verb: "write")])

        // A reply that was never about editing is still cleanly "not an edit",
        // so the loop can still tell the two apart.
        let notAnEdit = MaintainFileEditApplier.parseDetailed(
            fromModelReply: "Looking at the parser.\n```bash\ncat src/a.rs\n```"
        )
        #expect(!notAnEdit.replyAttemptedAFileEdit)
    }

    /// One broken block never discards a reply's good ones — both halves come
    /// back, so the good edit lands and the bad one is named.
    @Test func aGoodBlockStillLandsBesideABrokenOne() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: """
        Two changes.
        ```write src/good.rs
        fn good() {}
        ```
        ```edit src/bad.rs
        no markers here
        ```
        """)
        #expect(outcome.requests == [.writeWholeFile(filePath: "src/good.rs", content: "fn good() {}")])
        #expect(outcome.rejections == [.editBlockHasNoSearchReplaceMarkers(path: "src/bad.rs")])
    }

    // MARK: - The three-backtick truncation, closed 2026-08-26

    /// THE CASE THIS SCREEN EXISTS FOR. A three-backtick ```write of a Markdown
    /// file whose content holds a bare ``` used to end at that inner fence,
    /// silently write a truncated file, and report success. Only a sentence in
    /// the prompt asking for four backticks stood between the reader and a
    /// half-written file.
    @Test func aThreeBacktickWriteTruncatedByAFenceInItsContentIsRefused() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: """
        Documenting the new flag.
        ```write docs/USAGE.md
        # Usage

        Run it like this:

        ```
        iris --once
        ```

        That is all.
        ```
        """)
        // Nothing is written on a guess.
        #expect(outcome.requests.isEmpty)
        #expect(outcome.rejections == [
            .blockMayHaveEndedEarlyAtAFenceInItsContent(verb: "write", path: "docs/USAGE.md")
        ])
        // And the model is told the repair, not just the refusal.
        #expect(outcome.rejections.first?.modelFacingMessage.contains("FOUR backticks") == true)
    }

    /// The same content, opened with FOUR backticks, is unambiguous — it parses
    /// and the inner ``` survives into the file verbatim. This is the shape the
    /// rejection above asks the model to resend, so it has to work.
    @Test func theFourBacktickFormOfTheSameWriteParsesWithItsInnerFenceIntact() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: """
        Documenting the new flag.
        ````write docs/USAGE.md
        # Usage

        ```
        iris --once
        ```

        That is all.
        ````
        """)
        #expect(outcome.rejections.isEmpty)
        guard case .writeWholeFile(_, let content)? = outcome.requests.first else {
            Issue.record("expected a whole-file write"); return
        }
        #expect(content.contains("```\niris --once\n```"))
        #expect(content.hasSuffix("That is all."))
    }

    /// The screen must not fire on well-formed replies, or every multi-block
    /// turn becomes a refusal. A write followed by a bash block is the single
    /// most common shape the loop sees.
    @Test func aWriteFollowedByABashBlockIsNotMistakenForTruncation() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: """
        Fixing the parser, then checking it.
        ```write src/parser.py
        def parse(s):
            return s.strip()
        ```
        ```bash
        python3 -m pytest -q
        ```
        """)
        #expect(outcome.rejections.isEmpty)
        #expect(outcome.requests.count == 1)
    }

    /// Two writes in one reply — also legal, also must not trip the screen.
    @Test func twoWritesInOneReplyAreNotMistakenForTruncation() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: """
        ```write a.py
        a = 1
        ```
        ```write b.py
        b = 2
        ```
        """)
        #expect(outcome.rejections.isEmpty)
        #expect(outcome.requests.count == 2)
    }

    /// A write that is the last thing in the reply, with nothing after it, is
    /// the other common shape and stays clean.
    @Test func aTrailingWriteWithNothingAfterItIsNotMistakenForTruncation() {
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply:
            "Rewriting it.\n```write src/a.py\nx = 1\n```")
        #expect(outcome.rejections.isEmpty)
        #expect(outcome.requests.count == 1)
    }

    // MARK: - The two scanners agree about where a block ends

    /// `parseDetailed` and `MaintainTierCFixer.fencedBlocksWithSpans` used to
    /// carry their own boundary rules and disagree, so a truncated write leaked
    /// part of its body into the narration line the reader is shown. Both now
    /// read `fencedBlockBoundaryRules`, and this asserts they land on the same
    /// answer for the shape that used to split them: a fence with text after it
    /// on the same line, which closes nothing.
    @Test func neitherScannerClosesABlockOnAFenceThatSharesItsLine() {
        let reply = """
        Narration.
        ```write src/a.md
        text ``` still inside the block
        ```
        """
        // The applier keeps the whole body, mid-line fence and all.
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: reply)
        #expect(outcome.requests == [
            .writeWholeFile(filePath: "src/a.md", content: "text ``` still inside the block")
        ])
        // And the tier-C scanner draws the same block, so narration keeps none
        // of it.
        let blocks = MaintainTierCFixer.fencedBlocksWithSpans(in: reply)
        #expect(blocks.count == 1)
        #expect(blocks.first?.tag == "write")
        #expect(blocks.first?.body == "text ``` still inside the block")
        #expect(MaintainTierCFixer.narrationText(fromModelReply: reply) == "Narration.")
    }

    /// The unterminated case, which is where the old disagreement was visible:
    /// the reader saw half a write block inside Iris's own narration line.
    @Test func anUnterminatedWriteLeaksNothingIntoTheNarration() {
        let reply = "Rewriting the settings pane.\n```write ui/Settings.tsx\nexport function Settings() {"
        #expect(MaintainTierCFixer.narrationText(fromModelReply: reply)
            == "Rewriting the settings pane.")
        let outcome = MaintainFileEditApplier.parseDetailed(fromModelReply: reply)
        #expect(outcome.requests.isEmpty)
        #expect(outcome.rejections == [
            .blockFenceWasNeverClosed(verb: "write", path: "ui/Settings.tsx")
        ])
    }
}
