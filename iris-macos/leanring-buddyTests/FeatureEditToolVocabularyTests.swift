//
//  FeatureEditToolVocabularyTests.swift
//  leanring-buddyTests
//
//  The tool vocabulary is the loop's ENTIRE interface to the repo (plan §6):
//  every action the model takes is one of these five verbs, parsed from a text
//  reply and turned into a command the jailed sandbox runs. These tests pin the
//  two halves that must stay honest — the PARSER (a model's one-tool-per-turn
//  line becomes exactly the right tool, and malformed lines become nil so the
//  loop re-prompts instead of running garbage) and the BUILDERS (the command a
//  tool becomes, including that arbitrary edit CONTENT is base64-transported so
//  no quoting hazard can ever reach the shell) plus the output summarizers that
//  cap what the model sees. Pure value logic — nothing here executes a command.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditToolVocabularyTests {

    // MARK: - Parser: the simple one-line verbs

    @Test func parsesFindFileWithAGlob() {
        #expect(FeatureEditTool.parse(modelReply: "find_file *Service.swift")
            == .findFile(nameOrGlob: "*Service.swift"))
    }

    @Test func parsesSearchSymbolKeepingAMultiWordQuery() {
        // The query is the whole remainder, so a multi-token symbol/phrase
        // survives intact rather than being cut at the first space.
        #expect(FeatureEditTool.parse(modelReply: "search_symbol func parseConfig(")
            == .searchSymbol(query: "func parseConfig("))
    }

    @Test func parsesReadRangeWithThreeTokens() {
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs 40 80")
            == .readRange(file: "src/main.rs", startLine: 40, endLine: 80))
    }

    @Test func parsesReadRangeWithADashOrColonCombinedRange() {
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs 40-80")
            == .readRange(file: "src/main.rs", startLine: 40, endLine: 80))
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs 40:80")
            == .readRange(file: "src/main.rs", startLine: 40, endLine: 80))
    }

    @Test func rejectsReadRangeWithNoRangeOrANonNumericRange() {
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs") == nil)
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs abc def") == nil)
    }

    @Test func rejectsReadRangeWhoseEndPrecedesItsStart() {
        // end < start is nonsensical; the loop must re-prompt, not read a
        // backwards range.
        #expect(FeatureEditTool.parse(modelReply: "read_range src/main.rs 80 40") == nil)
    }

    @Test func parsesRunCheckWithAKnownKind() {
        #expect(FeatureEditTool.parse(modelReply: "run_check swift Sources/App/App.swift")
            == .runCheck(kind: .swiftParse, file: "Sources/App/App.swift"))
        #expect(FeatureEditTool.parse(modelReply: "run_check node app.js")
            == .runCheck(kind: .nodeSyntax, file: "app.js"))
    }

    @Test func rejectsRunCheckWithAnUnknownKind() {
        // Only offline single-file checks are supported; an unknown kind must
        // not silently map to something.
        #expect(FeatureEditTool.parse(modelReply: "run_check ruby foo.rb") == nil)
    }

    // MARK: - Parser: verb spelling, prose, fences, one-per-turn

    @Test func acceptsVerbSpelledWithoutUnderscoreOrInCamelCase() {
        // A model may type read_range, readrange, or readRange — all the same
        // verb (normalized by dropping underscores/case).
        #expect(FeatureEditTool.parse(modelReply: "readrange a.txt 1 5")
            == .readRange(file: "a.txt", startLine: 1, endLine: 5))
        #expect(FeatureEditTool.parse(modelReply: "readRange a.txt 1 5")
            == .readRange(file: "a.txt", startLine: 1, endLine: 5))
    }

    @Test func skipsLeadingProseAndACodeFenceToFindTheVerb() {
        let reply = """
        Sure — let me look for where that symbol is defined.

        ```
        search_symbol parseConfig
        ```
        """
        #expect(FeatureEditTool.parse(modelReply: reply)
            == .searchSymbol(query: "parseConfig"))
    }

    @Test func takesOnlyTheFirstToolWhenTwoArePresent() {
        // One tool per turn: the first recognized verb wins, the rest is
        // ignored — the loop never runs two actions from one reply.
        let reply = """
        find_file main.swift
        search_symbol shouldBeIgnored
        """
        #expect(FeatureEditTool.parse(modelReply: reply)
            == .findFile(nameOrGlob: "main.swift"))
    }

    @Test func returnsNilWhenNoToolLineIsPresent() {
        #expect(FeatureEditTool.parse(modelReply: "") == nil)
        #expect(FeatureEditTool.parse(modelReply: "I think we should refactor everything.") == nil)
        // DONE is the loop's own terminator, not a tool — the vocabulary does
        // not claim it.
        #expect(FeatureEditTool.parse(modelReply: "DONE") == nil)
    }

    @Test func stripsSurroundingQuotesFromAPathWithASpace() {
        #expect(FeatureEditTool.parse(modelReply: "find_file \"My File.swift\"")
            == .findFile(nameOrGlob: "My File.swift"))
    }

    // MARK: - Parser: editRange search/replace

    @Test func parsesASearchReplaceEditBlock() {
        let reply = """
        edit_range src/main.rs
        <<<<<<< SEARCH
        let value = 1
        =======
        let value = 2
        >>>>>>> REPLACE
        """
        #expect(FeatureEditTool.parse(modelReply: reply)
            == .editRange(
                file: "src/main.rs",
                specification: .searchReplace(search: "let value = 1", replacement: "let value = 2")
            ))
    }

    @Test func preservesMultiLineSearchAndReplaceBodiesVerbatim() {
        let reply = """
        edit_range app.js
        <<<<<<< SEARCH
        function a() {
          return 1
        }
        =======
        function a() {
          return 2
        }
        >>>>>>> REPLACE
        """
        let expectedSearch = "function a() {\n  return 1\n}"
        let expectedReplacement = "function a() {\n  return 2\n}"
        #expect(FeatureEditTool.parse(modelReply: reply)
            == .editRange(
                file: "app.js",
                specification: .searchReplace(search: expectedSearch, replacement: expectedReplacement)
            ))
    }

    @Test func allowsAnEmptyReplacementForADeletionEdit() {
        // Deleting text is a legitimate edit: an empty REPLACE body is fine, as
        // long as the SEARCH text anchors it.
        let reply = """
        edit_range a.txt
        <<<<<<< SEARCH
        remove me
        =======
        >>>>>>> REPLACE
        """
        #expect(FeatureEditTool.parse(modelReply: reply)
            == .editRange(
                file: "a.txt",
                specification: .searchReplace(search: "remove me", replacement: "")
            ))
    }

    @Test func rejectsASearchReplaceWithAnEmptySearch() {
        // An empty SEARCH matches everywhere and is meaningless — reject it so
        // the loop asks for real anchoring text.
        let reply = """
        edit_range a.txt
        <<<<<<< SEARCH
        =======
        new text
        >>>>>>> REPLACE
        """
        #expect(FeatureEditTool.parse(modelReply: reply) == nil)
    }

    @Test func rejectsAnEditWithAFileButNoRecognizableBody() {
        #expect(FeatureEditTool.parse(modelReply: "edit_range a.txt") == nil)
        let danglingSearchOnly = """
        edit_range a.txt
        <<<<<<< SEARCH
        only a search, no divider or replace
        """
        #expect(FeatureEditTool.parse(modelReply: danglingSearchOnly) == nil)
    }

    // MARK: - Parser: editRange unified diff

    @Test func parsesAUnifiedDiffEditBody() {
        let reply = """
        edit_range src/main.rs
        --- a/src/main.rs
        +++ b/src/main.rs
        @@ -1,1 +1,1 @@
        -let value = 1
        +let value = 2
        """
        let parsed = FeatureEditTool.parse(modelReply: reply)
        guard case .editRange(let file, .unifiedDiff(let patchText)) = parsed else {
            Issue.record("expected a unified-diff editRange, got \(String(describing: parsed))")
            return
        }
        #expect(file == "src/main.rs")
        #expect(patchText.contains("@@ -1,1 +1,1 @@"))
        #expect(patchText.contains("+let value = 2"))
        #expect(patchText.contains("-let value = 1"))
    }

    @Test func stripsAFencedDiffBodyDownToTheDiff() {
        // A model that wraps the diff in a ```diff fence must still parse to the
        // clean patch, with the fence markers removed.
        let reply = """
        edit_range src/main.rs
        ```diff
        --- a/src/main.rs
        +++ b/src/main.rs
        @@ -1,1 +1,1 @@
        -old
        +new
        ```
        """
        let parsed = FeatureEditTool.parse(modelReply: reply)
        guard case .editRange(_, .unifiedDiff(let patchText)) = parsed else {
            Issue.record("expected a unified-diff editRange, got \(String(describing: parsed))")
            return
        }
        #expect(!patchText.contains("```"))
        #expect(patchText.contains("@@ -1,1 +1,1 @@"))
    }

    // MARK: - Builders: the simple verbs

    @Test func findFileBuildsAContainedCappedFindCommand() {
        let command = FeatureEditTool.findFile(nameOrGlob: "main.swift").invocation.shellCommand
        #expect(command.contains("find ."))
        #expect(command.contains("-not -path './.git/*'"))
        #expect(command.contains("-name 'main.swift'"))
        // head-cap is (max + 1) so the summarizer can detect overflow.
        #expect(command.contains("head -n \(FeatureEditTool.maximumFindFileResults + 1)"))
    }

    @Test func searchSymbolBuildsALiteralRecursiveGrep() {
        let command = FeatureEditTool.searchSymbol(query: "parseConfig").invocation.shellCommand
        #expect(command.contains("grep -rnI -F"))
        #expect(command.contains("--exclude-dir=.git"))
        // `--` guards a query starting with `-`; the query is single-quoted.
        #expect(command.contains("-- 'parseConfig' ."))
        #expect(command.contains("head -n \(FeatureEditTool.maximumSearchSymbolMatches + 1)"))
    }

    @Test func searchSymbolSingleQuotesAQueryContainingAQuote() {
        // A query with an embedded single quote must be escaped as '\'' so it
        // cannot break out of its shell argument.
        let command = FeatureEditTool.searchSymbol(query: "it's").invocation.shellCommand
        #expect(command.contains("'it'\\''s'"))
    }

    @Test func readRangeBuildsANumberedAwkSliceAndClampsAHugeRange() {
        let command = FeatureEditTool
            .readRange(file: "big.txt", startLine: 10, endLine: 100_000)
            .invocation.shellCommand
        #expect(command.contains("NR>=10"))
        // The span is clamped to the maximum, not the model's 100k end.
        let clampedEnd = 10 + FeatureEditTool.maximumReadRangeLineSpan - 1
        #expect(command.contains("NR<=\(clampedEnd)"))
        #expect(command.contains("'big.txt'"))
    }

    @Test func readRangeClampsADegenerateStartUpToOne() {
        let command = FeatureEditTool
            .readRange(file: "a.txt", startLine: 0, endLine: 5)
            .invocation.shellCommand
        #expect(command.contains("NR>=1"))
        #expect(command.contains("NR<=5"))
    }

    @Test func runCheckBuildsTheRightOfflineCommandPerKind() {
        #expect(FeatureEditTool.runCheck(kind: .nodeSyntax, file: "app.js")
            .invocation.shellCommand.contains("node --check 'app.js'"))
        #expect(FeatureEditTool.runCheck(kind: .pythonSyntax, file: "m.py")
            .invocation.shellCommand.contains("python3 -m py_compile 'm.py'"))
        #expect(FeatureEditTool.runCheck(kind: .swiftParse, file: "A.swift")
            .invocation.shellCommand.contains("swiftc -parse 'A.swift'"))
        #expect(FeatureEditTool.runCheck(kind: .goSyntax, file: "m.go")
            .invocation.shellCommand.contains("gofmt -e 'm.go'"))
        let jsonCommand = FeatureEditTool.runCheck(kind: .jsonWellFormed, file: "c.json")
            .invocation.shellCommand
        #expect(jsonCommand.contains("python3 -c"))
        #expect(jsonCommand.contains("json.load"))
        #expect(jsonCommand.contains("'c.json'"))
    }

    // MARK: - Builders: editRange transports content as base64 (no quoting hazard)

    @Test func searchReplaceBase64EncodesBothSidesSoContentNeverTouchesTheShell() {
        let search = "let value = 1"
        let replacement = "let value = 2"
        let command = FeatureEditTool
            .editRange(file: "src/main.rs", specification: .searchReplace(search: search, replacement: replacement))
            .invocation.shellCommand

        // The exact base64 of each side must appear — this is what proves the
        // content is transported by base64, not by fragile shell quoting.
        let expectedSearchBase64 = Data(search.utf8).base64EncodedString()
        let expectedReplacementBase64 = Data(replacement.utf8).base64EncodedString()
        #expect(command.contains("'\(expectedSearchBase64)'"))
        #expect(command.contains("'\(expectedReplacementBase64)'"))

        #expect(command.contains("openssl base64 -A -d"))
        #expect(command.contains("perl -e"))
        #expect(command.contains("'src/main.rs'"))
        // The perl program embedded in the command carries no single quote, so
        // it survives being wrapped in single quotes in the shell.
        #expect(!command.contains("perl -e ''"))
    }

    @Test func searchReplaceContentWithQuotesAndDollarsIsNotInjectedRaw() {
        // Content that WOULD wreck a naive quoted command — a single quote, a
        // double quote, a `$(...)`, a backtick — must not appear raw in the
        // command; it lives only inside the base64 blob.
        let dangerous = "x = \"$(rm -rf /)\" ; echo 'it''s' `whoami`"
        let command = FeatureEditTool
            .editRange(file: "a.txt", specification: .searchReplace(search: dangerous, replacement: "safe"))
            .invocation.shellCommand
        #expect(!command.contains("$(rm -rf /)"))
        #expect(!command.contains("`whoami`"))
        // …but its base64 is present, so the real bytes still reach the file.
        #expect(command.contains(Data(dangerous.utf8).base64EncodedString()))
    }

    @Test func unifiedDiffBuildsAGitApplyOverABase64Patch() {
        let patch = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n"
        let command = FeatureEditTool
            .editRange(file: "f", specification: .unifiedDiff(patchText: patch))
            .invocation.shellCommand
        #expect(command.contains("git apply --recount --whitespace=nowarn"))
        #expect(command.contains("openssl base64 -A -d"))
        #expect(command.contains(Data(patch.utf8).base64EncodedString()))
    }

    @Test func unifiedDiffNormalizesAMissingTrailingNewlineBeforeEncoding() {
        // git apply wants a trailing newline; a diff lacking one is normalized,
        // so the encoded patch is the newline-terminated form.
        let patchWithoutNewline = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b"
        let command = FeatureEditTool
            .editRange(file: "f", specification: .unifiedDiff(patchText: patchWithoutNewline))
            .invocation.shellCommand
        let normalizedBase64 = Data((patchWithoutNewline + "\n").utf8).base64EncodedString()
        #expect(command.contains(normalizedBase64))
    }

    // MARK: - Summarizers: bounded, honest output for the model

    @Test func findFileSummaryReportsNoMatchesPlainly() {
        let summary = FeatureEditTool.findFile(nameOrGlob: "nope.swift")
            .summarizeOutput(rawOutput: "", exitCode: 0)
        #expect(summary.contains("No files matched"))
    }

    @Test func findFileSummaryCapsAndCountsOverflow() {
        // Emit one more than the cap (the head cap surfaces exactly this) and
        // assert the summary shows the cap plus a "more" note.
        let overflowingLineCount = FeatureEditTool.maximumFindFileResults + 1
        let manyPaths = (1...overflowingLineCount).map { "src/file\($0).swift" }.joined(separator: "\n")
        let summary = FeatureEditTool.findFile(nameOrGlob: "*.swift")
            .summarizeOutput(rawOutput: manyPaths, exitCode: 0)
        #expect(summary.contains("more"))
        #expect(summary.contains("src/file1.swift"))
        // The (cap + 1)-th path must be beyond the shown window.
        #expect(!summary.contains("src/file\(overflowingLineCount).swift"))
    }

    @Test func searchSymbolSummaryKeepsNoMatchesApartFromAnError() {
        // grep exit 1 = "no matches" (not a failure); exit 2 = a real error.
        let noMatch = FeatureEditTool.searchSymbol(query: "ghost")
            .summarizeOutput(rawOutput: "", exitCode: 1)
        #expect(noMatch.contains("No matches"))

        let error = FeatureEditTool.searchSymbol(query: "ghost")
            .summarizeOutput(rawOutput: "grep: invalid option", exitCode: 2)
        #expect(error.contains("Search error"))
    }

    @Test func readRangeSummaryFlagsAnEmptyOrMissingRange() {
        let summary = FeatureEditTool.readRange(file: "gone.txt", startLine: 1, endLine: 5)
            .summarizeOutput(rawOutput: "", exitCode: 0)
        #expect(summary.contains("may not exist"))
    }

    @Test func readRangeSummaryTruncatesAVeryLongSlice() {
        let hugeOutput = String(repeating: "x", count: 20_000)
        let summary = FeatureEditTool.readRange(file: "big.txt", startLine: 1, endLine: 400)
            .summarizeOutput(rawOutput: hugeOutput, exitCode: 0)
        #expect(summary.contains("truncated"))
        #expect(summary.count < hugeOutput.count)
    }

    @Test func editRangeSummaryReportsSuccessAndFailureHonestly() {
        let applied = FeatureEditTool
            .editRange(file: "a.txt", specification: .searchReplace(search: "x", replacement: "y"))
            .summarizeOutput(rawOutput: "", exitCode: 0)
        #expect(applied.contains("Edit applied to a.txt"))

        let failed = FeatureEditTool
            .editRange(file: "a.txt", specification: .searchReplace(search: "x", replacement: "y"))
            .summarizeOutput(rawOutput: "search text not found in target file", exitCode: 2)
        #expect(failed.contains("FAILED"))
        #expect(failed.contains("search text not found"))
    }

    @Test func runCheckSummaryReportsPassAndFailWithDiagnostics() {
        let passed = FeatureEditTool.runCheck(kind: .swiftParse, file: "A.swift")
            .summarizeOutput(rawOutput: "", exitCode: 0)
        #expect(passed.contains("passed"))
        #expect(passed.contains("A.swift"))

        let failed = FeatureEditTool.runCheck(kind: .swiftParse, file: "A.swift")
            .summarizeOutput(rawOutput: "A.swift:3:1: error: expected '}'", exitCode: 1)
        #expect(failed.contains("FAILED"))
        #expect(failed.contains("expected '}'"))
    }

    // MARK: - The advertised grammar matches what the parser accepts

    @Test func toolUsageInstructionsNamesEveryVerb() {
        let instructions = FeatureEditTool.toolUsageInstructions
        #expect(instructions.contains("find_file"))
        #expect(instructions.contains("search_symbol"))
        #expect(instructions.contains("read_range"))
        #expect(instructions.contains("edit_range"))
        #expect(instructions.contains("run_check"))
        // Every check kind the parser accepts is advertised by its token.
        for checkKind in FeatureEditCheckKind.allCases {
            #expect(instructions.contains(checkKind.rawValue))
        }
    }
}
