//
//  FeatureEditRepoMapTests.swift
//  leanring-buddyTests
//
//  Tests for the offline repo map + the per-repo learned-notes helper
//  (plan §6). Two independent surfaces are pinned here:
//
//    1. Declaration extraction — the per-language regexes, tested directly
//       against literal source snippets (no filesystem) so each language's
//       keyword set, the inline-attribute and modifier handling, and the
//       keyword-in-front-of-keyword mis-parse guard are all nailed down.
//
//    2. The walk + ranking + budgeting — tested against tiny fixture repos in
//       temp directories: ignore directories (node_modules/.git/target/build)
//       are never mined, files are ranked richest-first, the summary is capped
//       to a token budget with an honest "omitted" marker, and an empty repo
//       yields an empty summary.
//
//    3. The learned-notes file — created on first append, appended as bullets,
//       read back verbatim, blank notes refused, and never mined back into the
//       symbol map.
//
//  Pure logic + filesystem — no processes, no network, nothing is ever executed.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditRepoMapTests {

    // MARK: - Fixture helper

    /// Materialize a throwaway repo: write every (repo-relative path → contents)
    /// pair, creating intermediate directories so a fixture can place nested
    /// files (e.g. "node_modules/dep.js"), and return the repo root path.
    static func makeFixtureRepo(files: [String: String]) throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-repo-map-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: repoRootPath,
            withIntermediateDirectories: true
        )
        for (repoRelativePath, contents) in files {
            let absoluteFilePath = (repoRootPath as NSString)
                .appendingPathComponent(repoRelativePath)
            let containingDirectory = (absoluteFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: containingDirectory,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)
        }
        return repoRootPath
    }

    static func makeEmptyFixtureRepo() throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-repo-map-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: repoRootPath,
            withIntermediateDirectories: true
        )
        return repoRootPath
    }

    static func removeFixtureRepo(_ repoRootPath: String) {
        try? FileManager.default.removeItem(atPath: repoRootPath)
    }

    // MARK: - Language detection

    @Test func fileExtensionsMapToTheExpectedLanguages() {
        #expect(RepoMapLanguage.language(forFileName: "Overlay.swift") == .swift)
        #expect(RepoMapLanguage.language(forFileName: "Component.tsx") == .typescript)
        #expect(RepoMapLanguage.language(forFileName: "helper.ts") == .typescript)
        #expect(RepoMapLanguage.language(forFileName: "index.mjs") == .javascript)
        #expect(RepoMapLanguage.language(forFileName: "main.rs") == .rust)
        #expect(RepoMapLanguage.language(forFileName: "service.py") == .python)
        #expect(RepoMapLanguage.language(forFileName: "server.go") == .go)

        // Case-insensitive, so a `.Swift` file is still Swift.
        #expect(RepoMapLanguage.language(forFileName: "Weird.SWIFT") == .swift)

        // Non-source files resolve to nil so the walker skips them.
        #expect(RepoMapLanguage.language(forFileName: "package.json") == nil)
        #expect(RepoMapLanguage.language(forFileName: "README.md") == nil)
        #expect(RepoMapLanguage.language(forFileName: "Makefile") == nil)
    }

    // MARK: - Declaration extraction: Swift/TS/JS shared keyword set

    @Test func swiftDeclarationsCaptureTypesFunctionsAttributesAndModifiers() {
        let swiftSource = """
        import Foundation

        public final class OverlayWindow {
            func trackCursor() {}
            @objc func handleClick() {}
            static func makeShared() -> OverlayWindow { OverlayWindow() }
            class func typeMethod() {}
        }

        struct IrisEyePupilGeometry {}
        enum AssistantState { case idle }
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: swiftSource,
            forLanguage: .swift
        )

        // Ordered, first-seen. `typeMethod` is deliberately ABSENT: `class func`
        // makes the `class` keyword match and the next token be the keyword
        // `func`, which the reserved-name guard rejects rather than listing a
        // symbol named "func".
        #expect(symbolNames == [
            "OverlayWindow",
            "trackCursor",
            "handleClick",
            "makeShared",
            "IrisEyePupilGeometry",
            "AssistantState",
        ])
        #expect(!symbolNames.contains("typeMethod"))
        #expect(!symbolNames.contains("func"))
    }

    /// TypeScript captures interface/type/class/enum AND the two forms a real
    /// TS or JS file actually declares functions with.
    ///
    /// This test used to assert the opposite — that `function notCaptured()`
    /// and `const arrow = () => {}` were deliberately NOT captured, on the
    /// grounds that the plan's keyword list said `func`, not `function`. That
    /// reasoning held right up until it met a JavaScript file: a repo that
    /// declares everything with plain `function` yielded zero symbols per file,
    /// every file was dropped as empty, `summarize` returned "", and the whole
    /// repo-map section vanished from the opening turn with nothing to say it
    /// had been attempted. It is the map's most important omission, not its
    /// intended behaviour, and this test was pinning it in place.
    @Test func typeScriptCapturesInterfaceTypeClassEnumAndBothFunctionForms() {
        let typeScriptSource = """
        export interface CompanionProps {
          title: string
        }
        export type CompanionId = string
        export default class CompanionManager {
          method() {}
        }
        type InternalAlias = number
        enum Mood { Idle }
        function plainFunction() {}
        export async function exportedAsyncFunction() {}
        const arrowBinding = () => {}
        export const typedArrow: Formatter = (value: string) => value
        const notAFunction = (first + second) * 2
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: typeScriptSource,
            forLanguage: .typescript
        )

        #expect(symbolNames == [
            "CompanionProps",
            "CompanionId",
            "CompanionManager",
            "InternalAlias",
            "Mood",
            "plainFunction",
            "exportedAsyncFunction",
            "arrowBinding",
            "typedArrow",
        ])
        // A method line with no declaration keyword is still not captured (the
        // map is top-level declarations only), and a `const` bound to an
        // ordinary VALUE is not a declaration the map should list — the
        // arrow-binding pattern insists on a real function on the right.
        #expect(!symbolNames.contains("method"))
        #expect(!symbolNames.contains("notAFunction"))
    }

    // MARK: - Declaration extraction: Rust

    @Test func rustDeclarationsCaptureFnStructEnumTraitImplWithVisibilityAndGenerics() {
        let rustSource = """
        pub struct GuideRunner {
            field: u32,
        }

        pub(crate) fn start_session() {}

        fn helper() {}

        impl<T> GuideRunner {
            pub fn run(&self) {}
        }

        impl Display for GuideRunner {}

        trait Recipe {}

        enum Tier { Zero }
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: rustSource,
            forLanguage: .rust
        )

        // `impl<T> GuideRunner` re-lists GuideRunner (deduped away); `impl
        // Display for GuideRunner` captures the FIRST identifier after `impl`
        // (Display), which is the documented behavior of the lightweight regex.
        #expect(symbolNames == [
            "GuideRunner",
            "start_session",
            "helper",
            "run",
            "Display",
            "Recipe",
            "Tier",
        ])
    }

    // MARK: - Declaration extraction: Python

    @Test func pythonDeclarationsCaptureIndentedDefAndClassAndAsyncDef() {
        let pythonSource = """
        class GuideService:
            def load(self):
                pass

            async def fetch(self):
                pass

        def top_level():
            pass
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: pythonSource,
            forLanguage: .python
        )

        // Indented methods ARE captured (the map allows leading whitespace);
        // `async def` is handled via the modifier prefix.
        #expect(symbolNames == ["GuideService", "load", "fetch", "top_level"])
    }

    // MARK: - Declaration extraction: Go

    @Test func goDeclarationsCaptureFuncAndTypeButSkipReceiverMethods() {
        let goSource = """
        package main

        type Server struct {
            port int
        }

        func main() {}

        func (s *Server) Handle() {}

        type Handler interface {
            Serve()
        }
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: goSource,
            forLanguage: .go
        )

        // A receiver method (`func (s *Server) Handle()`) has a `(` immediately
        // after `func`, not an identifier, so it is not captured — a documented
        // limitation of the regex map, and acceptable noise reduction.
        #expect(symbolNames == ["Server", "main", "Handler"])
        #expect(!symbolNames.contains("Handle"))
        #expect(!symbolNames.contains("package"))
    }

    // MARK: - Declaration extraction: commented-out declarations are excluded

    @Test func lineCommentedDeclarationsAreNotCaptured() {
        let swiftSource = """
        // func ghostFunction() {}
        /// struct GhostDoc {}
        struct RealType {}
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: swiftSource,
            forLanguage: .swift
        )

        // A `//`-prefixed line no longer has the keyword at its head (after only
        // whitespace/modifiers), so it never matches — only the real declaration
        // survives.
        #expect(symbolNames == ["RealType"])
    }

    @Test func repeatedDeclarationNamesAreDedupedInFirstSeenOrder() {
        let swiftSource = """
        struct Repeated {}
        extension Repeated {
            func first() {}
        }
        struct Repeated {}
        func first() {}
        """

        let symbolNames = FeatureEditRepoMap.declarationNames(
            inSourceText: swiftSource,
            forLanguage: .swift
        )

        #expect(symbolNames == ["Repeated", "first"])
    }

    // MARK: - Declaration extraction: every language must actually yield something

    /// The map's most consequential failure mode is not a wrong symbol — it is
    /// NO symbols, because that is indistinguishable from a repo with nothing
    /// in it. A language whose keyword list matches nothing drops every file as
    /// empty, `summarize` returns "", and the whole "Repo map" section is
    /// omitted from the opening turn with no indication it was ever attempted.
    /// Measured over a six-task edit battery: the section was present for every
    /// Python and Rust task and absent from all six JavaScript ones — and
    /// Iris's own targets (the Windows client, publikclip, kneecap, notetion)
    /// are Electron/TS, which is exactly where it was blind.
    ///
    /// So this sweeps EVERY case of `RepoMapLanguage` against a representative
    /// file. Adding a language without a working pattern for it fails here.
    @Test func everySupportedLanguageYieldsSymbolsForARepresentativeFile() {
        let representativeSourceByLanguage: [RepoMapLanguage: String] = [
            .swift: "final class Widget {\n    func render() {}\n}",
            .typescript: "export function formatMoney(cents: number): string { return \"\" }",
            .javascript: "function splitEvenly(total, ways) { return total / ways }",
            .rust: "pub fn parse_row(line: &str) -> Vec<String> { vec![] }",
            .python: "def paginate(items, size):\n    return items",
            .go: "func Serve(port int) error { return nil }",
        ]
        for language in RepoMapLanguage.allCases {
            let representativeSource = representativeSourceByLanguage[language]
            #expect(representativeSource != nil, "no representative source for \(language.rawValue)")
            guard let representativeSource else { continue }
            let symbolNames = FeatureEditRepoMap.declarationNames(
                inSourceText: representativeSource,
                forLanguage: language
            )
            #expect(
                !symbolNames.isEmpty,
                "\(language.rawValue) extracted no symbols from a file that plainly declares one"
            )
        }
    }

    /// The JavaScript case end to end, through the walk and the summary rather
    /// than the regex alone — because "" from `summarize` is what actually
    /// reached the loop, and it reached it silently.
    @Test func javaScriptFunctionsAndArrowBindingsReachTheSummary() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "src/money.js": """
            function splitEvenly(total, ways) {
              return Math.floor(total / ways)
            }

            export const formatCents = (cents) => `$${(cents / 100).toFixed(2)}`

            module.exports = { splitEvenly }
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: repoRootPath) }

        let summary = FeatureEditRepoMap.summarize(repoRootPath: repoRootPath)
        #expect(summary.contains("src/money.js"))
        #expect(summary.contains("splitEvenly"))
        #expect(summary.contains("formatCents"))
    }

    // MARK: - The walk: ignore directories are never mined

    @Test func buildSymbolSummariesSkipsIgnoreAndDotDirectories() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "App.swift": "struct A {}\nstruct B {}\nstruct C {}\n",
            "lib/util.ts": "export interface Foo {}\ntype Bar = string\n",
            "README.md": "# not a source file\nstruct NotCaptured {}\n",
            // Each of these lives under a directory the map must never descend.
            "node_modules/dep.js": "class ShouldNotAppearFromNodeModules {}\n",
            ".git/hooks/hook.swift": "struct ShouldNotAppearFromGit {}\n",
            "target/gen.rs": "struct ShouldNotAppearFromTarget {}\n",
            "build/out.go": "type ShouldNotAppearFromBuild struct {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let summaries = FeatureEditRepoMap.buildFileSymbolSummaries(repoRootPath: repoRootPath)

        // Only the two real source files under non-ignored paths survive.
        #expect(summaries.count == 2)
        let allPaths = summaries.map { $0.repoRelativePath }
        #expect(allPaths.contains("App.swift"))
        #expect(allPaths.contains("lib/util.ts"))

        // Nothing from an ignore/dot directory, and nothing from a non-source
        // file (README.md), leaked in.
        let allSymbols = summaries.flatMap { $0.symbolNames }
        #expect(!allSymbols.contains("ShouldNotAppearFromNodeModules"))
        #expect(!allSymbols.contains("ShouldNotAppearFromGit"))
        #expect(!allSymbols.contains("ShouldNotAppearFromTarget"))
        #expect(!allSymbols.contains("ShouldNotAppearFromBuild"))
        #expect(!allSymbols.contains("NotCaptured"))
    }

    // MARK: - The walk: files are ranked richest-first

    @Test func summariesAreRankedByDeclarationCountThenPath() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "small.swift": "struct One {}\n",
            "big.swift": "struct A {}\nstruct B {}\nstruct C {}\nstruct D {}\n",
            "medium.swift": "struct E {}\nstruct F {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let summaries = FeatureEditRepoMap.buildFileSymbolSummaries(repoRootPath: repoRootPath)

        #expect(summaries.map { $0.repoRelativePath } == [
            "big.swift",    // 4 declarations
            "medium.swift", // 2 declarations
            "small.swift",  // 1 declaration
        ])
        #expect(summaries.first?.symbolNames == ["A", "B", "C", "D"])
    }

    @Test func equalDeclarationCountsTieBreakByPathAscending() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "zebra.swift": "struct Z1 {}\nstruct Z2 {}\n",
            "alpha.swift": "struct A1 {}\nstruct A2 {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let summaries = FeatureEditRepoMap.buildFileSymbolSummaries(repoRootPath: repoRootPath)

        // Same count (2 each) → deterministic path ascending order.
        #expect(summaries.map { $0.repoRelativePath } == ["alpha.swift", "zebra.swift"])
    }

    // MARK: - summarize: format + token budget

    @Test func summarizeProducesFileToSymbolLinesRichestFirst() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "App.swift": "struct A {}\nstruct B {}\nstruct C {}\n",
            "lib/util.ts": "export interface Foo {}\ntype Bar = string\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let summary = FeatureEditRepoMap.summarize(repoRootPath: repoRootPath)
        let lines = summary.components(separatedBy: "\n")

        #expect(lines.first == "App.swift: A, B, C")
        #expect(summary.contains("lib/util.ts: Foo, Bar"))
    }

    @Test func summarizeCapsToTheTokenBudgetAndMarksOmittedFilesHonestly() throws {
        // Six single-symbol files; a 1-token budget can only fit the first
        // (richest-ties-broken-by-path) line, and the rest must be reported as
        // omitted rather than silently dropped.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "file0.swift": "struct S0 {}\n",
            "file1.swift": "struct S1 {}\n",
            "file2.swift": "struct S2 {}\n",
            "file3.swift": "struct S3 {}\n",
            "file4.swift": "struct S4 {}\n",
            "file5.swift": "struct S5 {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let summary = FeatureEditRepoMap.summarize(repoRootPath: repoRootPath, tokenBudget: 1)
        let lines = summary.components(separatedBy: "\n")

        // Exactly the first file's line plus the omission marker.
        #expect(lines.count == 2)
        #expect(lines.first == "file0.swift: S0")
        #expect(lines.last == "… 5 more file(s) omitted to fit the map budget")
    }

    @Test func summarizeAlwaysEmitsAtLeastOneLineEvenWithAZeroBudget() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "only.swift": "struct TheOnlyType {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        // A single-file repo can never overflow (nothing follows to omit), so a
        // zero budget still yields the one honest line with no marker.
        let summary = FeatureEditRepoMap.summarize(repoRootPath: repoRootPath, tokenBudget: 0)
        #expect(summary == "only.swift: TheOnlyType")
    }

    @Test func summarizeReturnsEmptyStringForARepoWithNoRecognizedDeclarations() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "README.md": "# just docs\n",
            "data.json": "{ \"k\": 1 }\n",
            "blank.swift": "// only comments here\nimport Foundation\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(FeatureEditRepoMap.summarize(repoRootPath: repoRootPath) == "")
        #expect(FeatureEditRepoMap.buildFileSymbolSummaries(repoRootPath: repoRootPath).isEmpty)
    }

    @Test func summarizeReturnsEmptyStringForAnEmptyRepo() throws {
        let repoRootPath = try Self.makeEmptyFixtureRepo()
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(FeatureEditRepoMap.summarize(repoRootPath: repoRootPath) == "")
    }

    // MARK: - Learned notes

    @Test func readLearnedNotesReturnsNilWhenNoNotesExistYet() throws {
        let repoRootPath = try Self.makeEmptyFixtureRepo()
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(FeatureEditRepoMap.readLearnedNotes(repoRootPath: repoRootPath) == nil)
    }

    @Test func appendLearnedNoteCreatesTheFileWithAHeaderAndReadsBackVerbatim() throws {
        let repoRootPath = try Self.makeEmptyFixtureRepo()
        defer { Self.removeFixtureRepo(repoRootPath) }

        let firstNote = "Build with `swift build`; the UI lives under leanring-buddy/."
        let didWrite = FeatureEditRepoMap.appendLearnedNote(firstNote, repoRootPath: repoRootPath)
        #expect(didWrite)

        // The file exists at the documented path.
        let notesFilePath = (repoRootPath as NSString)
            .appendingPathComponent(FeatureEditRepoMap.learnedNotesRepoRelativePath)
        #expect(FileManager.default.fileExists(atPath: notesFilePath))

        let readBack = try #require(FeatureEditRepoMap.readLearnedNotes(repoRootPath: repoRootPath))
        #expect(readBack.contains("# Iris learned notes for this repo"))
        #expect(readBack.contains("- \(firstNote)"))
    }

    @Test func appendLearnedNoteAppendsBulletsAndKeepsASingleHeader() throws {
        let repoRootPath = try Self.makeEmptyFixtureRepo()
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(FeatureEditRepoMap.appendLearnedNote("First quirk", repoRootPath: repoRootPath))
        #expect(FeatureEditRepoMap.appendLearnedNote("Second quirk", repoRootPath: repoRootPath))

        let readBack = try #require(FeatureEditRepoMap.readLearnedNotes(repoRootPath: repoRootPath))
        #expect(readBack.contains("- First quirk"))
        #expect(readBack.contains("- Second quirk"))

        // The header is written exactly once, on creation — a second append must
        // not re-stamp it.
        let headerOccurrences = readBack.components(separatedBy: "# Iris learned notes for this repo").count - 1
        #expect(headerOccurrences == 1)

        // The two bullets are on their own lines (the separating newline is
        // guaranteed even if a prior write lacked a trailing newline).
        #expect(readBack.contains("- First quirk\n"))
    }

    @Test func appendLearnedNoteRefusesABlankNoteAndWritesNothing() throws {
        let repoRootPath = try Self.makeEmptyFixtureRepo()
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(FeatureEditRepoMap.appendLearnedNote("   \n  ", repoRootPath: repoRootPath) == false)

        // A refused blank note must not have created the file.
        #expect(FeatureEditRepoMap.readLearnedNotes(repoRootPath: repoRootPath) == nil)
        let notesFilePath = (repoRootPath as NSString)
            .appendingPathComponent(FeatureEditRepoMap.learnedNotesRepoRelativePath)
        #expect(FileManager.default.fileExists(atPath: notesFilePath) == false)
    }

    @Test func theLearnedNotesFileIsNeverMinedBackIntoTheSymbolMap() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "App.swift": "struct RealType {}\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        // A note whose text looks like a declaration must never surface as a map
        // symbol — `.iris` is a dot-directory the walker skips, and the file is
        // markdown besides.
        #expect(FeatureEditRepoMap.appendLearnedNote("struct FakeSymbolInANote {}", repoRootPath: repoRootPath))

        let summaries = FeatureEditRepoMap.buildFileSymbolSummaries(repoRootPath: repoRootPath)
        let allSymbols = summaries.flatMap { $0.symbolNames }
        #expect(allSymbols.contains("RealType"))
        #expect(!allSymbols.contains("FakeSymbolInANote"))
        #expect(!summaries.contains { $0.repoRelativePath.contains(".iris") })
    }
}
