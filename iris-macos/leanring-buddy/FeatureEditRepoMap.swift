//
//  FeatureEditRepoMap.swift
//  leanring-buddy
//
//  The offline repo map + the per-repo learned-notes file for the Feature
//  Engine's agentic loop (plan §6).
//
//  Aider's finding is that a cheap, model-call-free symbol summary handed to
//  the agent at session start is the single best localization aid AND the
//  primary defense against hallucinated APIs — the agent can ground a call
//  site before writing the call. The plan deliberately SKIPS the tree-sitter +
//  PageRank version (overkill for one change in one repo on one machine) in
//  favor of this lightweight substitute: walk the source files once, pull the
//  top-level declaration names out with per-language regexes, rank the files by
//  how much structure they carry, and emit a token-budget-capped file→symbols
//  summary. It is honest about being a heuristic — a regex cannot do real scope
//  analysis, and that limitation is exactly why the full tree-sitter map was
//  scoped out, not silently faked here.
//
//  This file also owns the plan's Devin-playbook substitute: a per-repo
//  learned-notes file (`.iris/feature-notes.md`) the agent appends after a
//  session (build quirks, where things live). A fraction of the machinery, and
//  it transfers within a repo across sessions.
//
//  Everything here is pure Foundation: it only READS source files and WRITES
//  the notes file under the repo; it never executes anything from the repo and
//  never touches the network. Symlinks and ignore directories are skipped so a
//  map can never follow a link out of the clone.
//

import Foundation

// MARK: - The languages the map understands

/// One source language the offline map can extract declarations from. Each case
/// carries its file extensions and the exact set of top-level declaration
/// keywords the plan §6 map recognizes for it. Kept as a closed, CaseIterable
/// enum so adding a language is one case (extensions + keywords) rather than an
/// if/else rewrite, mirroring the data-driven recipe registry next door.
nonisolated enum RepoMapLanguage: String, Sendable, CaseIterable {
    case swift
    case typescript
    case javascript
    case rust
    case python
    case go

    /// The lowercased file extensions that map to this language.
    var fileExtensions: [String] {
        switch self {
        case .swift:
            return ["swift"]
        case .typescript:
            // .tsx is TypeScript-with-JSX; both are the same declaration shapes.
            return ["ts", "tsx"]
        case .javascript:
            // .mjs / .cjs are ES-module / CommonJS variants of the same syntax.
            return ["js", "jsx", "mjs", "cjs"]
        case .rust:
            return ["rs"]
        case .python:
            return ["py"]
        case .go:
            return ["go"]
        }
    }

    /// The declaration keywords whose following identifier the map captures, per
    /// plan §6. Swift/TS/JS deliberately share one set (`func|class|struct|enum|
    /// interface|type`): a Swift file simply never contains `interface`/`type`,
    /// and a TS file never contains `func`/`struct`, so the shared set is exact
    /// for each without a per-language split. (JS functions written with the
    /// `function` keyword are intentionally NOT captured — the plan's keyword
    /// list is `func`, not `function` — so a JS file contributes its class /
    /// interface / type / enum declarations only.)
    var declarationKeywords: [String] {
        switch self {
        case .swift, .typescript, .javascript:
            return ["func", "class", "struct", "enum", "interface", "type"]
        case .rust:
            return ["fn", "struct", "enum", "trait", "impl"]
        case .python:
            return ["def", "class"]
        case .go:
            return ["func", "type"]
        }
    }

    /// Resolve a file name to its language by extension, or nil when the file is
    /// not a recognized source file (so the walker skips it). Extension match is
    /// case-insensitive because a real clone mixes `.Swift`/`.swift`.
    static func language(forFileName fileName: String) -> RepoMapLanguage? {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        return allCases.first { languageCandidate in
            languageCandidate.fileExtensions.contains(fileExtension)
        }
    }
}

// MARK: - One file's worth of the map

/// The declarations found in one source file: its repo-relative path and the
/// deduped, first-seen-ordered symbol names. This is the unit the summary is
/// built from, kept as a value so the ranking + budgeting logic is pure and
/// unit-testable without touching a filesystem.
nonisolated struct RepoMapFileSymbolSummary: Sendable, Equatable {
    /// Path relative to the repo root (e.g. "src/app/Server.swift").
    let repoRelativePath: String

    /// The top-level declaration names, deduped, in the order first seen in the
    /// file. Never empty — a file with no declarations is dropped rather than
    /// listed, because an empty row wastes the token budget without localizing
    /// anything.
    let symbolNames: [String]
}

// MARK: - The map + the learned-notes file

/// The offline repo map (plan §6) and the per-repo learned-notes helper. Pure
/// Foundation, no model calls, no network, no execution of repo code.
nonisolated enum FeatureEditRepoMap {

    // MARK: - Tunable bounds (named so the "why this limit" story is in one place)

    /// Stop the walk after this many source files. A generous ceiling that keeps
    /// a pathologically large clone (or a symlink-induced blowup) from turning
    /// the "cheap, model-call-free" map into an unbounded scan.
    static let defaultFileScanLimit = 4000

    /// A source file larger than this is not read: it is almost certainly
    /// generated/minified/vendored, its declarations would swamp the map, and
    /// reading it wastes memory. 2 MB is comfortably above any hand-written file.
    private static let maximumSourceFileByteCount = 2 * 1024 * 1024

    /// The default token budget for the summary string (plan §6: ~1–2K tokens).
    static let defaultSummaryTokenBudget = 2000

    /// We have no real tokenizer here (pure Foundation), so the budget is
    /// approximated by characters. ~4 characters per token is the usual rule of
    /// thumb and errs slightly toward UNDER-filling the budget, which is the
    /// safe direction for a context-window guard.
    private static let approximateCharactersPerToken = 4

    /// Cap the symbols shown for any single file line so one enormous file can't
    /// consume the whole budget; the overflow is shown as a trailing "…" so the
    /// truncation is visible rather than silent.
    private static let maximumSymbolsPerFileLine = 40

    // MARK: - Ignore directories

    /// Directory names never walked into. The plan names node_modules/.git/
    /// target/build explicitly; the rest are the same class of thing (dependency
    /// caches and build outputs) whose contents are generated, not authored, and
    /// would only pollute the map. `.git` and every other dot-directory are
    /// additionally excluded by `shouldIgnoreDirectory` below, so `.git`,
    /// `.build`, `.next`, `.venv`, and Iris's own `.iris` are all covered without
    /// enumerating each.
    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules",
        "target",
        "build",
        "dist",
        "out",
        "vendor",
        "Pods",
        "DerivedData",
        "__pycache__",
        "coverage",
    ]

    /// True when a directory must not be descended into. A leading "." catches
    /// `.git` (the plan's named case) plus every other tooling/output dot-dir in
    /// one rule, so the map never mines version-control internals or hidden
    /// caches — and, crucially, never reads Iris's own `.iris/feature-notes.md`
    /// back into the symbol map.
    private static func shouldIgnoreDirectory(named directoryName: String) -> Bool {
        if directoryName.hasPrefix(".") { return true }
        return ignoredDirectoryNames.contains(directoryName)
    }

    // MARK: - Public: the summary string

    /// Build the token-budget-capped file→symbols summary for the clone at
    /// `repoRootPath`. Files are listed richest-first (most declarations first)
    /// so the most structurally central files survive a tight budget; when the
    /// budget is reached the remaining files are dropped and a single count line
    /// records how many were omitted, so the truncation is honest rather than
    /// invisible. Returns "" for a repo with no recognized declarations.
    static func summarize(
        repoRootPath: String,
        tokenBudget: Int = defaultSummaryTokenBudget,
        fileScanLimit: Int = defaultFileScanLimit
    ) -> String {
        let rankedFileSummaries = buildFileSymbolSummaries(
            repoRootPath: repoRootPath,
            fileScanLimit: fileScanLimit
        )
        guard !rankedFileSummaries.isEmpty else { return "" }

        let characterBudget = max(0, tokenBudget) * approximateCharactersPerToken

        var summaryLines: [String] = []
        var usedCharacterCount = 0
        var omittedFileCount = 0

        for (fileIndex, fileSummary) in rankedFileSummaries.enumerated() {
            let summaryLine = formatSummaryLine(for: fileSummary)
            // +1 accounts for the newline that will join this line to the next.
            let lineCharacterCost = summaryLine.count + 1

            // Stop once this line would overflow the budget — but ALWAYS emit at
            // least the first (richest) line, even if it alone exceeds a tiny
            // budget, so a caller never gets an empty map for a repo that has
            // symbols. Everything from here on is reported as omitted.
            let wouldOverflow = usedCharacterCount + lineCharacterCost > characterBudget
            if wouldOverflow && !summaryLines.isEmpty {
                omittedFileCount = rankedFileSummaries.count - fileIndex
                break
            }

            summaryLines.append(summaryLine)
            usedCharacterCount += lineCharacterCost
        }

        if omittedFileCount > 0 {
            summaryLines.append(
                "… \(omittedFileCount) more file(s) omitted to fit the map budget"
            )
        }

        return summaryLines.joined(separator: "\n")
    }

    /// Format one file's row as "path: symbolA, symbolB, symbolC", capping the
    /// symbol list so a single huge file can't dominate the budget.
    private static func formatSummaryLine(for fileSummary: RepoMapFileSymbolSummary) -> String {
        let shownSymbolNames = fileSummary.symbolNames.prefix(maximumSymbolsPerFileLine)
        var joinedSymbolNames = shownSymbolNames.joined(separator: ", ")
        if fileSummary.symbolNames.count > maximumSymbolsPerFileLine {
            joinedSymbolNames += ", …"
        }
        return "\(fileSummary.repoRelativePath): \(joinedSymbolNames)"
    }

    // MARK: - Public: the ranked per-file index

    /// Walk the clone and return one `RepoMapFileSymbolSummary` per source file
    /// that has at least one top-level declaration, ranked richest-first
    /// (declaration count descending) and tie-broken by path so the ordering is
    /// fully deterministic for the same tree.
    static func buildFileSymbolSummaries(
        repoRootPath: String,
        fileScanLimit: Int = defaultFileScanLimit
    ) -> [RepoMapFileSymbolSummary] {
        // The walk tracks each file's repo-relative path AS IT DESCENDS rather
        // than string-stripping a root prefix off the absolute path afterward.
        // That avoids a macOS foot-gun: `contentsOfDirectory(at:)` canonicalizes
        // child URLs (/var → /private/var) while `resolvingSymlinksInPath()` on
        // the root does the opposite (strips /private), so the two never share a
        // prefix and a strip-based approach would leak absolute paths. Building
        // the relative path from the component names sidesteps canonical-form
        // mismatches entirely.
        let discoveredFiles = discoverSourceFiles(
            underRepoRoot: repoRootPath,
            fileScanLimit: fileScanLimit
        )

        // Compile one regex per language once, rather than recompiling the same
        // pattern for every file of that language across a large clone.
        var compiledRegexByLanguage: [RepoMapLanguage: NSRegularExpression] = [:]
        for language in RepoMapLanguage.allCases {
            if let declarationRegex = makeDeclarationRegex(forLanguage: language) {
                compiledRegexByLanguage[language] = declarationRegex
            }
        }

        var fileSummaries: [RepoMapFileSymbolSummary] = []
        for discoveredFile in discoveredFiles {
            let fileName = (discoveredFile.absolutePath as NSString).lastPathComponent
            guard
                let language = RepoMapLanguage.language(forFileName: fileName),
                let declarationRegex = compiledRegexByLanguage[language],
                let sourceText = readSourceText(atAbsolutePath: discoveredFile.absolutePath)
            else { continue }

            let symbolNames = declarationNames(
                inSourceText: sourceText,
                usingRegex: declarationRegex
            )
            // Drop files with no declarations: an empty row localizes nothing and
            // only spends budget.
            guard !symbolNames.isEmpty else { continue }

            fileSummaries.append(RepoMapFileSymbolSummary(
                repoRelativePath: discoveredFile.repoRelativePath,
                symbolNames: symbolNames
            ))
        }

        // Richest-first so the token budget spends itself on the most central
        // files; path tie-break makes the result reproducible.
        fileSummaries.sort { leftSummary, rightSummary in
            if leftSummary.symbolNames.count != rightSummary.symbolNames.count {
                return leftSummary.symbolNames.count > rightSummary.symbolNames.count
            }
            return leftSummary.repoRelativePath < rightSummary.repoRelativePath
        }
        return fileSummaries
    }

    // MARK: - Public: pure declaration extraction (regex only, no filesystem)

    /// Extract the top-level declaration names from a block of source text for a
    /// given language, deduped and in first-seen order. Exposed on its own — free
    /// of any filesystem — so the per-language regex behavior can be unit-tested
    /// directly against literal source snippets.
    static func declarationNames(
        inSourceText sourceText: String,
        forLanguage language: RepoMapLanguage
    ) -> [String] {
        guard let declarationRegex = makeDeclarationRegex(forLanguage: language) else {
            return []
        }
        return declarationNames(inSourceText: sourceText, usingRegex: declarationRegex)
    }

    // MARK: - The learned-notes file (plan §6, Devin-playbook substitute)

    /// The directory Iris keeps its per-repo metadata in, relative to the repo
    /// root. Hidden (dot-prefixed) so the map's own walker skips it.
    private static let learnedNotesDirectoryRelativePath = ".iris"

    /// The per-repo learned-notes file, relative to the repo root. The agent
    /// appends build quirks / where-things-live notes here after a session so a
    /// later session in the SAME repo starts warmer.
    static let learnedNotesRepoRelativePath = ".iris/feature-notes.md"

    /// Written once, when the notes file is first created, so a human who opens
    /// the file understands what it is. Subsequent notes are appended as bullets
    /// beneath it.
    private static let learnedNotesFileHeader = "# Iris learned notes for this repo\n\n"

    /// A learned-notes file should stay small; anything larger is not something
    /// this helper produced and we decline to read it into memory wholesale.
    private static let maximumLearnedNotesByteCount = 4 * 1024 * 1024

    /// Read the whole learned-notes file for this repo, or nil when it does not
    /// exist / is unreadable / is unexpectedly large. nil is the "no notes yet"
    /// signal — a first-ever session in the repo.
    static func readLearnedNotes(repoRootPath: String) -> String? {
        let absoluteNotesPath = (repoRootPath as NSString)
            .appendingPathComponent(learnedNotesRepoRelativePath)

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: absoluteNotesPath),
            let byteCount = attributes[.size] as? Int,
            byteCount <= maximumLearnedNotesByteCount,
            let data = try? Data(contentsOf: URL(fileURLWithPath: absoluteNotesPath)),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        return text
    }

    /// Append one learned note for this repo, creating `.iris/feature-notes.md`
    /// (and the `.iris` directory) on first use. The note is stored as a markdown
    /// bullet beneath the header. Returns true only when the note was persisted;
    /// a blank note is refused (nothing to remember) and any filesystem failure
    /// returns false rather than throwing, so a note-taking side effect can never
    /// crash the edit loop.
    @discardableResult
    static func appendLearnedNote(_ note: String, repoRootPath: String) -> Bool {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never record an empty note — it would add a blank bullet that means
        // nothing to the next session.
        guard !trimmedNote.isEmpty else { return false }

        let fileManager = FileManager.default
        let absoluteNotesDirectoryPath = (repoRootPath as NSString)
            .appendingPathComponent(learnedNotesDirectoryRelativePath)
        let absoluteNotesFilePath = (repoRootPath as NSString)
            .appendingPathComponent(learnedNotesRepoRelativePath)

        // Ensure `.iris/` exists; if we cannot create it we cannot persist.
        do {
            try fileManager.createDirectory(
                atPath: absoluteNotesDirectoryPath,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        let newBulletLine = "- \(trimmedNote)\n"

        let updatedContents: String
        if let existingContents = readLearnedNotes(repoRootPath: repoRootPath),
           !existingContents.isEmpty {
            // Guarantee a separating newline so bullets never run together even
            // if a prior writer left no trailing newline.
            let joiningNewline = existingContents.hasSuffix("\n") ? "" : "\n"
            updatedContents = existingContents + joiningNewline + newBulletLine
        } else {
            updatedContents = learnedNotesFileHeader + newBulletLine
        }

        do {
            try updatedContents.write(
                toFile: absoluteNotesFilePath,
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private: the walk

    /// One recognized source file found by the walk: its absolute path (for
    /// reading) and its repo-relative path (for the map), the latter accumulated
    /// from component names during descent so it never depends on the OS's
    /// canonical form of the absolute path.
    private struct DiscoveredSourceFile {
        let absolutePath: String
        let repoRelativePath: String
    }

    /// One frame of the descent: the directory to list plus the repo-relative
    /// path that leads to it ("" for the root).
    private struct DirectoryToVisit {
        let url: URL
        let repoRelativePath: String
    }

    /// Depth-first walk of the clone returning recognized source files, skipping
    /// ignore/dot directories and symlinks and stopping at `fileScanLimit`.
    /// Symlinks are skipped for two reasons at once: they can form cycles that
    /// never terminate, and they can point OUTSIDE the repo — a map must never
    /// follow a link out of the clone. The repo-relative path of each file is
    /// built by appending component names as the walk descends, so it stays
    /// correct regardless of whether the OS reports the absolute path as
    /// /var/... or /private/var/....
    private static func discoverSourceFiles(
        underRepoRoot repoRootPath: String,
        fileScanLimit: Int
    ) -> [DiscoveredSourceFile] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        var discoveredFiles: [DiscoveredSourceFile] = []
        var directoryStack: [DirectoryToVisit] = [
            DirectoryToVisit(url: URL(fileURLWithPath: repoRootPath), repoRelativePath: "")
        ]

        while let currentDirectory = directoryStack.popLast() {
            guard let entryURLs = try? fileManager.contentsOfDirectory(
                at: currentDirectory.url,
                includingPropertiesForKeys: resourceKeys,
                options: []
            ) else { continue }

            // Sort by name for a deterministic traversal order, so which files
            // survive the scan limit (and thus the map) is reproducible.
            let sortedEntryURLs = entryURLs.sorted { leftURL, rightURL in
                leftURL.lastPathComponent < rightURL.lastPathComponent
            }

            for entryURL in sortedEntryURLs {
                let entryName = entryURL.lastPathComponent
                let entryRepoRelativePath = currentDirectory.repoRelativePath.isEmpty
                    ? entryName
                    : currentDirectory.repoRelativePath + "/" + entryName

                let resourceValues = try? entryURL.resourceValues(forKeys: Set(resourceKeys))

                // Never follow a symlink (cycle + escape guard).
                if resourceValues?.isSymbolicLink == true { continue }

                if resourceValues?.isDirectory == true {
                    if shouldIgnoreDirectory(named: entryName) { continue }
                    directoryStack.append(DirectoryToVisit(
                        url: entryURL,
                        repoRelativePath: entryRepoRelativePath
                    ))
                } else if RepoMapLanguage.language(forFileName: entryName) != nil {
                    discoveredFiles.append(DiscoveredSourceFile(
                        absolutePath: entryURL.path,
                        repoRelativePath: entryRepoRelativePath
                    ))
                    if discoveredFiles.count >= fileScanLimit {
                        return discoveredFiles
                    }
                }
            }
        }

        return discoveredFiles
    }

    /// Read a source file as UTF-8, refusing missing / oversized / non-UTF-8
    /// files (all of which the map treats identically: "no symbols here").
    private static func readSourceText(atAbsolutePath absolutePath: String) -> String? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath),
            let byteCount = attributes[.size] as? Int,
            byteCount <= maximumSourceFileByteCount,
            let data = try? Data(
                contentsOf: URL(fileURLWithPath: absolutePath),
                options: [.mappedIfSafe]
            ),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        return text
    }

    // MARK: - Private: the declaration regex

    /// Optional leading attribute/decorator run, e.g. `@objc `, `@MainActor `,
    /// `@objc(Name) `. Swift routinely writes attributes inline before a
    /// declaration (`@MainActor final class Foo`), so without this the map would
    /// miss every attributed declaration. Harmless for the other languages,
    /// which write decorators on their own line above the declaration.
    private static let leadingAttributePrefixPattern =
        #"(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\([^)\n]*\))?[ \t]+)*"#

    /// Optional run of leading declaration modifiers (visibility, `static`,
    /// `final`, `export`, `async`, Rust `pub`/`pub(crate)`, …). Each is followed
    /// by required whitespace and the whole run is optional, so both `func foo`
    /// and `public static func foo` match. Modifiers are a superset across the
    /// supported languages; a modifier that never appears in a given language is
    /// simply never present, which costs nothing.
    private static let declarationModifierPrefixPattern =
        #"(?:(?:public|private|internal|fileprivate|open|final|static|export|default|abstract|declare|override|const|unsafe|extern|async|pub(?:\([a-z]+\))?)[ \t]+)*"#

    /// Identifiers that, if captured as a "declaration name", indicate the regex
    /// mis-parsed one keyword sitting in front of another (Swift's `class func`
    /// type-method form is the classic case: the `class` keyword matches and the
    /// next token is the keyword `func`). Rejecting these prevents the map from
    /// ever listing a symbol literally named `func`/`type`/etc.
    private static let reservedDeclarationNames: Set<String> = [
        "func", "fn", "class", "struct", "enum", "interface", "type",
        "trait", "impl", "def", "var", "let", "function",
    ]

    /// Build the per-line declaration regex for a language. The pattern, anchored
    /// at line start:
    ///   optional whitespace → optional attributes → optional modifiers →
    ///   one of the language's declaration keywords (as a whole word) →
    ///   optional generic clause right after the keyword (handles Rust
    ///   `impl<T> Foo`) → required whitespace → the captured identifier.
    /// A fresh instance is returned each call (no shared mutable global state);
    /// callers that scan many files precompile once via `buildFileSymbolSummaries`.
    private static func makeDeclarationRegex(
        forLanguage language: RepoMapLanguage
    ) -> NSRegularExpression? {
        let keywordAlternation = language.declarationKeywords.joined(separator: "|")
        let pattern =
            "^[ \\t]*"
            + leadingAttributePrefixPattern
            + declarationModifierPrefixPattern
            + "(?:" + keywordAlternation + ")\\b"
            + "(?:<[^>\\n]*>)?"
            + "\\s+([A-Za-z_][A-Za-z0-9_]*)"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Apply a precompiled declaration regex line-by-line, returning the captured
    /// names deduped in first-seen order. Line-at-a-time (rather than one
    /// multiline match) keeps each `^` anchored to a real line start and keeps
    /// the work proportional to the file — and a `//`-commented declaration is
    /// naturally excluded because the keyword no longer sits at the line's head.
    private static func declarationNames(
        inSourceText sourceText: String,
        usingRegex declarationRegex: NSRegularExpression
    ) -> [String] {
        var orderedNames: [String] = []
        var alreadySeenNames: Set<String> = []

        // `.newlines` splits on \n, \r, and \r\n, so a CRLF file leaves no stray
        // carriage return on the end of a line.
        for line in sourceText.components(separatedBy: .newlines) {
            if line.isEmpty { continue }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard
                let match = declarationRegex.firstMatch(in: line, options: [], range: lineRange),
                match.numberOfRanges >= 2,
                let captureRange = Range(match.range(at: 1), in: line)
            else { continue }

            let capturedName = String(line[captureRange])
            // Guard against the keyword-in-front-of-keyword mis-parse.
            if reservedDeclarationNames.contains(capturedName) { continue }

            if alreadySeenNames.insert(capturedName).inserted {
                orderedNames.append(capturedName)
            }
        }

        return orderedNames
    }
}
