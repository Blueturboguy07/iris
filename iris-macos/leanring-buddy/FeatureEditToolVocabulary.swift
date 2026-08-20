//
//  FeatureEditToolVocabulary.swift
//  leanring-buddy
//
//  The capped, ACI-style tool vocabulary the Feature Engine's agentic loop
//  speaks (plan §6). SWE-agent's central finding is that a coding agent does
//  measurably better with a small set of purpose-built, output-capped verbs
//  than with raw shell: cheaper turns, fewer shell mistakes, and output the
//  model can actually read. This file is that vocabulary, and ONLY the
//  vocabulary — five verbs, each of which:
//
//    1. builds the exact shell command the (already-present) sandbox will run
//       (`invocation`), and
//    2. truncates/summarizes that command's raw output back down to something
//       worth spending the model's context on (`summarizeOutput`).
//
//  It also parses a model's one-tool-per-turn reply line into a
//  `FeatureEditTool` (`parse(modelReply:)`), mirroring the existing Tier-C
//  loop's text-ReAct transport (one action per turn, provider-portable, trivial
//  to cap) — the verbs replace the raw ```bash block, nothing else changes.
//
//  HARD boundary: this file NEVER executes anything and NEVER touches the
//  network. It only inspects strings and builds command strings. The strings it
//  builds run later, in the SAME Seatbelt jail the Tier-C loop already uses
//  (writes confined to the repo + temp, no network), through the SAME shell
//  runner — the jail, not this file, is the security boundary, exactly as it is
//  for the raw-shell loop this vocabulary upgrades. Commands run with the repo
//  root as the working directory (that is how `MaintainShellRunner` invokes the
//  jail), so every path here is repo-relative.
//
//  Pure Foundation only — no SwiftUI, no process spawning, no URLSession.
//

import Foundation

// MARK: - How one editRange edit is expressed

/// The two edit shapes the loop may use (plan §6: "unified-diff or strict
/// search/replace … not whole-file rewrite"). Both are applied by a command
/// this file builds; neither is ever a "return a diff blob" no-op.
nonisolated enum FeatureEditRangeSpecification: Sendable, Equatable {
    /// A strict, exact-match search/replace: `search` must appear in the target
    /// file EXACTLY ONCE. The builder fails loudly (a distinct exit code + a
    /// message the model sees next turn) when it is missing or ambiguous —
    /// which is the whole point, per Aider's benchmark that exact-match edits
    /// produce far fewer silently-wrong "lazy" edits than fuzzy rewrites.
    case searchReplace(search: String, replacement: String)

    /// A unified diff applied verbatim with `git apply` (which works on the
    /// working tree even with `.git` stripped during the loop — verified).
    case unifiedDiff(patchText: String)
}

// MARK: - The cheap, in-jail syntax gate kinds

/// The per-file cheap gate the loop runs INSIDE the jail after an edit
/// (plan §6: "per-edit cheap gate … syntax/lint where those don't need
/// network"). Every kind here is a genuinely OFFLINE, single-file check — it
/// parses/validates one file WITHOUT resolving dependencies or hitting the
/// network — because the jail has no network. The heavy build + full suite run
/// once, un-jailed, after DONE (the §9 ladder); this is only the fast feedback
/// that catches a syntax slip on the turn it happened.
///
/// Raw values are the tokens the model types after `run_check` (e.g.
/// `run_check swift Sources/App.swift`), so the surface grammar and the enum
/// stay in lockstep.
nonisolated enum FeatureEditCheckKind: String, Sendable, Equatable, CaseIterable {
    /// `node --check <file>` — JavaScript/TypeScript-adjacent syntax, no deps.
    case nodeSyntax = "node"
    /// `python3 -m py_compile <file>` — Python syntax, no imports resolved.
    case pythonSyntax = "python"
    /// `swiftc -parse <file>` — parse-only, so no type-checking and no
    /// dependency/module resolution (which would need the network).
    case swiftParse = "swift"
    /// `gofmt -e <file>` — reports Go parse errors without a build.
    case goSyntax = "go"
    /// A JSON well-formedness check for config/manifest edits.
    case jsonWellFormed = "json"

    /// Reader-facing name for the terminal label and the summarized result.
    var humanReadableName: String {
        switch self {
        case .nodeSyntax: return "JavaScript syntax"
        case .pythonSyntax: return "Python syntax"
        case .swiftParse: return "Swift parse"
        case .goSyntax: return "Go syntax"
        case .jsonWellFormed: return "JSON well-formedness"
        }
    }
}

// MARK: - What one tool call resolves to at runtime

/// The command a tool call becomes, plus a plain-English description for the
/// takeover terminal's per-command label (the terminal leads every row with a
/// friendly label; see `GuideAutopilotFriendlyLabel`). The command is exactly
/// what the sandbox runs — no post-processing between here and the shell.
nonisolated struct FeatureEditToolInvocation: Sendable, Equatable {
    /// The full shell command line, handed verbatim to the jailed shell runner.
    let shellCommand: String

    /// A short human-readable description of what this call does, for the
    /// terminal label ("Search for “parseConfig”", "Read lines 40–80 of …").
    let humanReadableDescription: String
}

// MARK: - The tool vocabulary

/// One agentic-loop action. Exactly one is chosen per turn (`parse` returns the
/// first recognized verb and ignores the rest, enforcing one-tool-per-turn),
/// and each maps to a command + an output summarizer. Deliberately a CLOSED set
/// of five verbs: a small vocabulary is what makes the loop cheap and auditable,
/// so adding a verb is a deliberate change here, not something a call site can
/// invent.
nonisolated enum FeatureEditTool: Sendable, Equatable {
    /// Locate files by name/glob. `find_file <name-or-glob>`.
    case findFile(nameOrGlob: String)

    /// Find where a literal string/symbol appears. `search_symbol <text>`.
    case searchSymbol(query: String)

    /// Show a numbered slice of a file. `read_range <file> <start> <end>`.
    case readRange(file: String, startLine: Int, endLine: Int)

    /// Apply one small edit. `edit_range <file>` + a search/replace or diff body.
    case editRange(file: String, specification: FeatureEditRangeSpecification)

    /// Run a cheap offline syntax check on a file. `run_check <kind> <file>`.
    case runCheck(kind: FeatureEditCheckKind, file: String)

    // MARK: Output caps
    //
    // These bound how much of a command's output is worth the model's context.
    // Internal (not private) so the test suite can pin the truncation behavior
    // against the exact thresholds rather than hard-coded magic numbers.

    /// Most files a `find_file` should ever surface before the query is too
    /// broad to be useful — beyond this the summary tells the model to narrow.
    static let maximumFindFileResults = 50

    /// Most `search_symbol` matches worth returning before the query is too
    /// broad; past this the summary says how many more there are.
    static let maximumSearchSymbolMatches = 60

    /// The most lines a single `read_range` will span. A model asking for a
    /// huge range gets a bounded window, not the whole file — localization is
    /// supposed to be a slice, and this keeps the turn cheap.
    static let maximumReadRangeLineSpan = 400

    // Character budgets for the summarized text handed back to the model.
    private static let maximumReadRangeOutputCharacters = 6000
    private static let maximumSearchOutputCharacters = 6000
    private static let maximumEditErrorDetailCharacters = 800
    private static let maximumCheckDiagnosticsCharacters = 1500
    private static let maximumErrorTailCharacters = 400

    // MARK: - Building the command the sandbox will run

    /// The command + label for this tool call. Pure string building — nothing
    /// here runs. Paths are single-quoted so a filename with a space or a shell
    /// metacharacter can never break out of its argument; the search/replace
    /// and diff BODIES are base64-encoded into the command so arbitrary content
    /// (quotes, `$`, backticks, heredoc-looking lines) is transported with zero
    /// escaping hazards and no chance of a sentinel collision.
    var invocation: FeatureEditToolInvocation {
        switch self {
        case .findFile(let nameOrGlob):
            let quotedNameOrGlob = Self.singleQuoted(nameOrGlob)
            // Skip .git so a stripped/absent history never shows up, and skip
            // the usual heavy dependency directories so the match list stays
            // about the app's own source. head-cap at (max + 1) so the
            // summarizer can DETECT overflow rather than guess at it.
            let command =
                "find . -type f -not -path './.git/*' -name \(quotedNameOrGlob) "
                + "2>/dev/null | head -n \(Self.maximumFindFileResults + 1)"
            return FeatureEditToolInvocation(
                shellCommand: command,
                humanReadableDescription: "Find files named \(nameOrGlob)"
            )

        case .searchSymbol(let query):
            let quotedQuery = Self.singleQuoted(query)
            // -F: literal (a symbol search, not a regex, so `[`/`.`/`*` in the
            // query are safe). -I: skip binaries. -n: line numbers so the model
            // can then read_range/edit_range the exact site. `--` ends options
            // so a query starting with `-` is data, not a flag.
            let command =
                "grep -rnI -F --exclude-dir=.git --exclude-dir=node_modules "
                + "--exclude-dir=target --exclude-dir=.build -- \(quotedQuery) . "
                + "2>/dev/null | head -n \(Self.maximumSearchSymbolMatches + 1)"
            return FeatureEditToolInvocation(
                shellCommand: command,
                humanReadableDescription: "Search for “\(query)”"
            )

        case .readRange(let file, let startLine, let endLine):
            // Clamp defensively: a directly-constructed tool (a test, a future
            // caller) must never emit a nonsensical or unbounded range.
            let clampedStartLine = max(1, startLine)
            let clampedEndLine = max(
                clampedStartLine,
                min(endLine, clampedStartLine + Self.maximumReadRangeLineSpan - 1)
            )
            let quotedFile = Self.singleQuoted(file)
            // Number every line so the model can target a later edit precisely,
            // and `exit` past the window so a big file is not scanned to EOF.
            // The doubled backslashes below produce LITERAL \t and \n for awk.
            let command =
                "awk 'NR>=\(clampedStartLine) && NR<=\(clampedEndLine)"
                + "{printf \"%6d\\t%s\\n\", NR, $0} NR>\(clampedEndLine){exit}' "
                + "\(quotedFile) 2>&1"
            return FeatureEditToolInvocation(
                shellCommand: command,
                humanReadableDescription:
                    "Read lines \(clampedStartLine)–\(clampedEndLine) of \(file)"
            )

        case .editRange(let file, let specification):
            switch specification {
            case .searchReplace(let search, let replacement):
                return Self.searchReplaceInvocation(
                    file: file, search: search, replacement: replacement
                )
            case .unifiedDiff(let patchText):
                return Self.unifiedDiffInvocation(file: file, patchText: patchText)
            }

        case .runCheck(let kind, let file):
            let quotedFile = Self.singleQuoted(file)
            let command: String
            switch kind {
            case .nodeSyntax:
                command = "node --check \(quotedFile) 2>&1"
            case .pythonSyntax:
                command = "python3 -m py_compile \(quotedFile) 2>&1"
            case .swiftParse:
                // -parse stops after parsing: no type-checking, no module
                // resolution, so it needs no dependencies and no network.
                command = "swiftc -parse \(quotedFile) 2>&1"
            case .goSyntax:
                // -e reports every parse error; on a clean file it prints the
                // formatted source (which the summarizer ignores on exit 0).
                command = "gofmt -e \(quotedFile) 2>&1"
            case .jsonWellFormed:
                // The embedded python has no single quotes, so it survives the
                // outer single-quoting untouched.
                command =
                    "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "
                    + "\(quotedFile) 2>&1"
            }
            return FeatureEditToolInvocation(
                shellCommand: command,
                humanReadableDescription: "\(kind.humanReadableName) check of \(file)"
            )
        }
    }

    /// Build the exact-match search/replace command. The search and replacement
    /// are base64-encoded into the command and decoded into temp files inside
    /// the jail, so their CONTENT never has to be shell-escaped and can contain
    /// anything at all. A tiny Perl program then does a literal, single-unique-
    /// occurrence replacement, failing with a distinct exit code + a message
    /// when the search text is missing (exit 2) or appears more than once
    /// (exit 2) — that message is what the loop feeds back to the model.
    private static func searchReplaceInvocation(
        file: String, search: String, replacement: String
    ) -> FeatureEditToolInvocation {
        let base64Search = Data(search.utf8).base64EncodedString()
        let base64Replacement = Data(replacement.utf8).base64EncodedString()
        let quotedFile = singleQuoted(file)
        // Assembled with `&&`/`;` on ONE logical line (no shell line
        // continuations) so the string is easy to reason about and to test.
        // The temp dir is created inside the jail's writable area (the shell's
        // TMPDIR), used, then removed; the Perl exit code is preserved as the
        // command's exit code so the summarizer reports success/failure right.
        let command =
            "__iris_sr_dir=\"$(mktemp -d)\" && "
            + "printf %s '\(base64Search)' | openssl base64 -A -d > \"$__iris_sr_dir/search\" && "
            + "printf %s '\(base64Replacement)' | openssl base64 -A -d > \"$__iris_sr_dir/replace\" && "
            + "perl -e '\(searchReplacePerlProgram)' "
            + "\"$__iris_sr_dir/search\" \"$__iris_sr_dir/replace\" \(quotedFile); "
            + "__iris_sr_rc=$?; rm -rf \"$__iris_sr_dir\"; exit $__iris_sr_rc"
        return FeatureEditToolInvocation(
            shellCommand: command,
            humanReadableDescription: "Edit \(file) (search/replace)"
        )
    }

    /// Build the unified-diff apply command. The patch is base64-encoded into
    /// the command, decoded into a temp file, and applied with `git apply`,
    /// which patches the working tree directly and needs neither a `.git`
    /// directory (stripped during the loop) nor the network. `--recount`
    /// tolerates a model's slightly-off hunk line counts; `--whitespace=nowarn`
    /// keeps a trailing-whitespace nit from failing an otherwise-good patch.
    private static func unifiedDiffInvocation(
        file: String, patchText: String
    ) -> FeatureEditToolInvocation {
        // git apply wants a trailing newline; a model-authored diff often lacks
        // one, so normalize it before encoding.
        let normalizedPatch = patchText.hasSuffix("\n") ? patchText : patchText + "\n"
        let base64Patch = Data(normalizedPatch.utf8).base64EncodedString()
        let command =
            "__iris_diff=\"$(mktemp)\" && "
            + "printf %s '\(base64Patch)' | openssl base64 -A -d > \"$__iris_diff\" && "
            + "git apply --recount --whitespace=nowarn \"$__iris_diff\" 2>&1; "
            + "__iris_diff_rc=$?; rm -f \"$__iris_diff\"; exit $__iris_diff_rc"
        return FeatureEditToolInvocation(
            shellCommand: command,
            humanReadableDescription: "Edit \(file) (apply diff)"
        )
    }

    /// The literal single-unique-occurrence replacement, as a `perl -e`
    /// program. It is embedded inside SINGLE quotes in the shell command, so it
    /// deliberately contains NO single quotes (only double quotes) and NO `\(`
    /// Swift-interpolation sequences. `:raw` layers keep the bytes exact.
    private static let searchReplacePerlProgram = """
    my $searchPath=$ARGV[0]; my $replacePath=$ARGV[1]; my $targetPath=$ARGV[2]; local $/;
    open(my $searchHandle, "<:raw", $searchPath) or do { print STDERR "cannot read search buffer"; exit 3; };
    my $searchText=<$searchHandle>; $searchText //= "";
    open(my $replaceHandle, "<:raw", $replacePath) or do { print STDERR "cannot read replace buffer"; exit 3; };
    my $replaceText=<$replaceHandle>; $replaceText //= "";
    open(my $targetHandle, "<:raw", $targetPath) or do { print STDERR "cannot read target file"; exit 4; };
    my $targetText=<$targetHandle>; $targetText //= ""; close($targetHandle);
    my $firstAt=index($targetText, $searchText);
    if ($firstAt < 0) { print STDERR "search text not found in target file"; exit 2; }
    my $secondAt=index($targetText, $searchText, $firstAt + length($searchText));
    if ($secondAt >= 0) { print STDERR "search text is ambiguous (found more than once); include more surrounding context"; exit 2; }
    substr($targetText, $firstAt, length($searchText)) = $replaceText;
    open(my $outHandle, ">:raw", $targetPath) or do { print STDERR "cannot write target file"; exit 4; };
    print $outHandle $targetText; close($outHandle);
    """

    // MARK: - Summarizing a command's output for the model

    /// Turn one command's raw output into the compact, capped text worth
    /// spending the model's context on. Each verb summarizes to its own shape
    /// (a bounded file list, a bounded match list, a numbered slice, a one-line
    /// edit verdict, a pass/fail with diagnostics) — the "ACI formats results
    /// for the model" half of the design (plan §6). Pure string work.
    ///
    /// - Parameters:
    ///   - rawOutput: the command's combined stdout/stderr tail, as captured by
    ///     the shell runner.
    ///   - exitCode: the command's exit status (the runner reports -1 when it
    ///     could not determine one).
    func summarizeOutput(rawOutput: String, exitCode: Int) -> String {
        switch self {
        case .findFile(let nameOrGlob):
            let matchedPaths = Self.nonEmptyTrimmedLines(of: rawOutput)
            if matchedPaths.isEmpty {
                return "No files matched “\(nameOrGlob)”. Try a different name or a "
                    + "glob such as *Service.swift."
            }
            if matchedPaths.count > Self.maximumFindFileResults {
                let shownPaths = matchedPaths.prefix(Self.maximumFindFileResults)
                let howManyMore = matchedPaths.count - Self.maximumFindFileResults
                return shownPaths.joined(separator: "\n")
                    + "\n…and at least \(howManyMore) more. Narrow the name to see the rest."
            }
            return matchedPaths.joined(separator: "\n")

        case .searchSymbol(let query):
            let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            // grep exits 1 for "no matches" and >=2 for a real error — keep
            // those apart so "nothing found" never reads like a failure.
            if exitCode >= 2 {
                return "Search error (exit \(exitCode)): "
                    + Self.truncated(trimmedOutput, toCharacterCount: Self.maximumErrorTailCharacters)
            }
            let matchLines = Self.nonEmptyTrimmedLines(of: rawOutput)
            if matchLines.isEmpty {
                return "No matches for “\(query)”."
            }
            if matchLines.count > Self.maximumSearchSymbolMatches {
                let shownMatches = matchLines.prefix(Self.maximumSearchSymbolMatches)
                let howManyMore = matchLines.count - Self.maximumSearchSymbolMatches
                let shownText = Self.truncated(
                    shownMatches.joined(separator: "\n"),
                    toCharacterCount: Self.maximumSearchOutputCharacters
                )
                return shownText
                    + "\n…and at least \(howManyMore) more matches. Refine the query."
            }
            return Self.truncated(
                matchLines.joined(separator: "\n"),
                toCharacterCount: Self.maximumSearchOutputCharacters
            )

        case .readRange(let file, let startLine, let endLine):
            let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "No lines returned for \(file) [\(startLine)–\(endLine)] — the "
                    + "file may not exist or the range is past its end."
            }
            if exitCode != 0 {
                return "Could not read \(file) [\(startLine)–\(endLine)]: "
                    + Self.truncated(trimmedOutput, toCharacterCount: Self.maximumErrorTailCharacters)
            }
            return Self.truncated(
                rawOutput, toCharacterCount: Self.maximumReadRangeOutputCharacters
            )

        case .editRange(let file, _):
            if exitCode == 0 {
                return "Edit applied to \(file)."
            }
            let detail = Self.truncated(
                rawOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                toCharacterCount: Self.maximumEditErrorDetailCharacters
            )
            return "Edit FAILED for \(file) (exit \(exitCode)): "
                + (detail.isEmpty ? "no error output" : detail)

        case .runCheck(let kind, let file):
            if exitCode == 0 {
                return "\(kind.humanReadableName) check passed for \(file)."
            }
            let diagnostics = Self.truncated(
                rawOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                toCharacterCount: Self.maximumCheckDiagnosticsCharacters
            )
            return "\(kind.humanReadableName) check FAILED for \(file) (exit \(exitCode)):\n"
                + (diagnostics.isEmpty ? "no diagnostics" : diagnostics)
        }
    }

    // MARK: - Parsing a model's tool line

    /// Map a model's reply into the single tool it chose this turn, or nil when
    /// the reply holds no recognizable tool line (the loop then re-prompts,
    /// exactly as it does today for a missing ```bash block). Enforces one tool
    /// per turn: the FIRST recognized verb wins and any later verbs are ignored.
    ///
    /// Robust to the ways a model actually formats a reply: leading prose lines,
    /// a wrapping ``` fence, `read_range` written as `40 80` / `40-80` / `40:80`,
    /// quoted paths, and a verb typed as `read_range`, `readrange`, or
    /// `readRange`.
    static func parse(modelReply: String) -> FeatureEditTool? {
        let normalizedReply = modelReply
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let replyLines = normalizedReply.components(separatedBy: "\n")

        guard let verbLineIndex = indexOfFirstVerbLine(in: replyLines) else {
            return nil
        }
        let verbLine = replyLines[verbLineIndex].trimmingCharacters(in: .whitespaces)
        let (verbKey, remainderAfterVerb) = splitVerbKeyAndRemainder(fromLine: verbLine)

        switch verbKey {
        case Self.findFileVerbKey:
            let nameOrGlob = stripSurroundingQuotes(
                remainderAfterVerb.trimmingCharacters(in: .whitespaces)
            )
            return nameOrGlob.isEmpty ? nil : .findFile(nameOrGlob: nameOrGlob)

        case Self.searchSymbolVerbKey:
            let query = stripSurroundingQuotes(
                remainderAfterVerb.trimmingCharacters(in: .whitespaces)
            )
            return query.isEmpty ? nil : .searchSymbol(query: query)

        case Self.readRangeVerbKey:
            return parseReadRange(fromRemainder: remainderAfterVerb)

        case Self.runCheckVerbKey:
            return parseRunCheck(fromRemainder: remainderAfterVerb)

        case Self.editRangeVerbKey:
            let file = stripSurroundingQuotes(
                remainderAfterVerb.trimmingCharacters(in: .whitespaces)
            )
            guard !file.isEmpty else { return nil }
            // The edit body is every line AFTER the header line.
            let bodyLines = verbLineIndex + 1 < replyLines.count
                ? Array(replyLines[(verbLineIndex + 1)...])
                : []
            guard let specification = parseEditSpecification(fromBodyLines: bodyLines) else {
                return nil
            }
            return .editRange(file: file, specification: specification)

        default:
            return nil
        }
    }

    // MARK: - Advertising the vocabulary to the model

    /// The tool grammar as the loop's system prompt should present it — one
    /// place so the surface the model is TOLD about can never drift from what
    /// `parse` accepts. Not itself a runtime construct; kept beside the parser
    /// it documents.
    static let toolUsageInstructions = """
    You explore and edit through these tools. Reply with EXACTLY ONE tool call \
    per turn — a single line (edits add their body on the following lines) and \
    nothing else. When the change is complete, reply with DONE on its own line.

      find_file <name-or-glob>
          Locate files by name. Example: find_file *Service.swift

      search_symbol <text>
          Find where a literal string or symbol appears in the source.
          Example: search_symbol parseConfig

      read_range <file> <startLine> <endLine>
          Show a numbered slice of a file before editing it.
          Example: read_range src/main.rs 40 80

      edit_range <file>
          Make ONE small edit. Provide EITHER a search/replace block whose
          SEARCH text appears in the file exactly once:
              edit_range src/main.rs
              <<<<<<< SEARCH
              the exact existing text
              =======
              the replacement text
              >>>>>>> REPLACE
          …or a unified diff:
              edit_range src/main.rs
              --- a/src/main.rs
              +++ b/src/main.rs
              @@ -1,1 +1,1 @@
              -old line
              +new line

      run_check <kind> <file>
          A cheap offline syntax check of one file after you edit it. kind is
          one of: node, python, swift, go, json.
          Example: run_check swift Sources/App/App.swift

    There is no network: you cannot install dependencies or run a full build. A \
    build and the test suite run automatically after you say DONE.
    """

    // MARK: - Verb keys (normalized, underscores/case removed)

    private static let findFileVerbKey = "findfile"
    private static let searchSymbolVerbKey = "searchsymbol"
    private static let readRangeVerbKey = "readrange"
    private static let editRangeVerbKey = "editrange"
    private static let runCheckVerbKey = "runcheck"

    private static let allVerbKeys: Set<String> = [
        findFileVerbKey, searchSymbolVerbKey, readRangeVerbKey,
        editRangeVerbKey, runCheckVerbKey,
    ]

    // MARK: - Parsing helpers

    /// Index of the first line that begins with a known verb. Prose lines and
    /// ``` fence markers are skipped so a model that narrates before acting, or
    /// wraps the call in a fence, still parses.
    private static func indexOfFirstVerbLine(in lines: [String]) -> Int? {
        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("```") {
                continue
            }
            let (verbKey, _) = splitVerbKeyAndRemainder(fromLine: trimmedLine)
            if allVerbKeys.contains(verbKey) {
                return lineIndex
            }
        }
        return nil
    }

    /// Split a line into its normalized verb key (first token, lowercased with
    /// `_`/`-` removed so `read_range`/`readrange`/`readRange` all match) and
    /// the untouched remainder after that token.
    private static func splitVerbKeyAndRemainder(fromLine line: String) -> (verbKey: String, remainder: String) {
        guard let firstWhitespaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (normalizedVerbKey(from: line), "")
        }
        let firstToken = String(line[line.startIndex..<firstWhitespaceIndex])
        let remainder = String(line[line.index(after: firstWhitespaceIndex)...])
        return (normalizedVerbKey(from: firstToken), remainder)
    }

    private static func normalizedVerbKey(from token: String) -> String {
        token.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// Parse the tail of a `read_range` line into a file + a valid line range.
    /// Accepts `<file> <start> <end>`, `<file> <start>-<end>`, and
    /// `<file> <start>:<end>`. The two integers are read from the RIGHT so a
    /// path containing spaces still parses.
    private static func parseReadRange(fromRemainder remainder: String) -> FeatureEditTool? {
        let tokens = remainder
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard tokens.count >= 2 else { return nil }

        // Form 1: the last two tokens are the start and end line numbers.
        if tokens.count >= 3,
           let endLine = Int(tokens[tokens.count - 1]),
           let startLine = Int(tokens[tokens.count - 2]) {
            let file = stripSurroundingQuotes(
                tokens[0..<(tokens.count - 2)].joined(separator: " ")
            )
            return makeReadRange(file: file, startLine: startLine, endLine: endLine)
        }

        // Form 2: the last token is a combined `start-end` or `start:end`.
        if let (startLine, endLine) = parseInlineLineRange(tokens[tokens.count - 1]) {
            let file = stripSurroundingQuotes(
                tokens[0..<(tokens.count - 1)].joined(separator: " ")
            )
            return makeReadRange(file: file, startLine: startLine, endLine: endLine)
        }

        return nil
    }

    /// A combined `start-end` / `start:end` token → the two integers, or nil.
    private static func parseInlineLineRange(_ token: String) -> (startLine: Int, endLine: Int)? {
        for separator in ["-", ":"] {
            let parts = token.components(separatedBy: separator)
            if parts.count == 2, let startLine = Int(parts[0]), let endLine = Int(parts[1]) {
                return (startLine, endLine)
            }
        }
        return nil
    }

    /// Build a `.readRange` only when the file is non-empty and the range is
    /// well-formed (start ≥ 1, end ≥ start); otherwise nil so the loop
    /// re-prompts rather than issuing a nonsensical read.
    private static func makeReadRange(file: String, startLine: Int, endLine: Int) -> FeatureEditTool? {
        guard !file.isEmpty, startLine >= 1, endLine >= startLine else { return nil }
        return .readRange(file: file, startLine: startLine, endLine: endLine)
    }

    /// Parse the tail of a `run_check` line: `<kind> <file>`. An unknown kind or
    /// a missing file returns nil.
    private static func parseRunCheck(fromRemainder remainder: String) -> FeatureEditTool? {
        let tokens = remainder
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard tokens.count >= 2 else { return nil }
        guard let kind = FeatureEditCheckKind(rawValue: tokens[0].lowercased()) else { return nil }
        let file = stripSurroundingQuotes(tokens[1...].joined(separator: " "))
        return file.isEmpty ? nil : .runCheck(kind: kind, file: file)
    }

    /// Parse an `edit_range` body into a search/replace or a unified-diff spec.
    /// Search/replace is detected first because its `<<<<<<< SEARCH` marker is
    /// unmistakable; a diff is recognized by its hunk/file headers. Outer ```
    /// fences and blank padding are stripped so a fenced body still parses; the
    /// content BETWEEN the search/replace markers is preserved verbatim.
    private static func parseEditSpecification(fromBodyLines bodyLines: [String]) -> FeatureEditRangeSpecification? {
        let body = stripOuterFenceAndBlankLines(bodyLines)
        guard !body.isEmpty else { return nil }

        // Search/replace: <<<<<<< SEARCH … ======= … >>>>>>> REPLACE.
        if let searchMarkerIndex = body.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("<<<<<<<")
        }) {
            let afterSearchMarker = body[(searchMarkerIndex + 1)...]
            guard let dividerIndex = afterSearchMarker.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("=======")
            }) else { return nil }
            let afterDivider = body[(dividerIndex + 1)...]
            guard let replaceMarkerIndex = afterDivider.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(">>>>>>>")
            }) else { return nil }

            let searchText = body[(searchMarkerIndex + 1)..<dividerIndex]
                .joined(separator: "\n")
            let replacementText = body[(dividerIndex + 1)..<replaceMarkerIndex]
                .joined(separator: "\n")
            // An empty search is meaningless (it matches everywhere) — reject it
            // so the loop asks the model for real anchoring text.
            guard !searchText.isEmpty else { return nil }
            return .searchReplace(search: searchText, replacement: replacementText)
        }

        // Unified diff: a hunk header, the a/---+++/b file headers, or the
        // `diff --git` banner.
        let hasHunkHeader = body.contains { $0.hasPrefix("@@") }
        let hasFileHeaders = body.contains { $0.hasPrefix("--- ") }
            && body.contains { $0.hasPrefix("+++ ") }
        let hasGitDiffBanner = body.contains { $0.hasPrefix("diff --git") }
        if hasHunkHeader || hasFileHeaders || hasGitDiffBanner {
            let patchText = body.joined(separator: "\n")
            return patchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .unifiedDiff(patchText: patchText)
        }

        return nil
    }

    /// Drop leading and trailing lines that are blank or a ``` fence marker,
    /// leaving the interior untouched — so a fenced edit body reduces to its
    /// real content without disturbing internal blank lines.
    private static func stripOuterFenceAndBlankLines(_ lines: [String]) -> [String] {
        func isFenceOrBlank(_ line: String) -> Bool {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            return trimmedLine.isEmpty || trimmedLine.hasPrefix("```")
        }
        var result = lines
        while let first = result.first, isFenceOrBlank(first) {
            result.removeFirst()
        }
        while let last = result.last, isFenceOrBlank(last) {
            result.removeLast()
        }
        return result
    }

    // MARK: - Small string utilities

    /// The output split into trimmed, non-empty lines — the shape the file/match
    /// summarizers count and cap.
    private static func nonEmptyTrimmedLines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Truncate for the model's context, appending an explicit note of how much
    /// was dropped so a clipped result never masquerades as a complete one.
    private static func truncated(_ text: String, toCharacterCount limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        return head + "\n…[truncated, \(text.count - limit) more characters]"
    }

    /// Remove a single matching pair of surrounding quotes/backticks from a
    /// token, so a quoted path parses to the bare path.
    private static func stripSurroundingQuotes(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        let quoteCharacters: Set<Character> = ["\"", "'", "`"]
        if first == last, quoteCharacters.contains(first) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// POSIX single-quote a string for safe use as one shell argument: wrap in
    /// single quotes and turn each embedded `'` into `'\''`.
    private static func singleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
