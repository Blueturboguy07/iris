//
//  MaintainFileEditApplier.swift
//  leanring-buddy
//
//  A structured file-writing tool for the Tier C edit loop — the single
//  biggest gap between it and a real coding agent (Claude Code, SWE-agent),
//  found on a real dogfood run (Aug 22 2026, whimprflow): the agent had
//  correctly diagnosed the fix but spent 56 steps doing `sed -i '' '63,76d'`
//  line-surgery on ONE file, because the Seatbelt jail blocks heredocs (`cat
//  << 'EOF'` → "can't create temp file for here document: operation not
//  permitted"), leaving only `sed` (line numbers drift after each edit, so the
//  next edit corrupts the file) or `printf` (escaping hell for multi-line
//  code). It never reached a compilable state to declare DONE.
//
//  So the model no longer edits files through the jailed shell at all. It
//  emits a structured block — a whole-file ```write or a search/replace
//  ```edit — and IRIS's own code applies it: atomic, path-checked, jailed to
//  the repo, with no line-number drift and no shell-escaping. Reading, grep,
//  and inspection still go through the jailed shell (that is what the jail is
//  for — untrusted exploration); only the WRITE is lifted out, exactly the
//  code-vs-command split the whole design rests on. A write to a build-script
//  file is still refused here (it must go through the manifest channel), so
//  this never widens what the un-jailed verification build will execute.
//
//  Pure Foundation, no network. All path resolution is standardized AND
//  symlink-resolved and confined under the repo root, so a model-planted
//  symlink cannot walk a write out of the clone.
//

import Foundation

/// One structured file operation the model asked Iris to perform. A reply may
/// carry several (unlike a shell command, a file write is deterministic and
/// needs no output fed back between operations, so the model can rewrite a few
/// files in one turn).
nonisolated enum MaintainFileEditRequest: Equatable, Sendable {
    /// Replace the ENTIRE contents of `filePath` with `content` (creating the
    /// file, and any missing parent directories, if absent).
    case writeWholeFile(filePath: String, content: String)
    /// Replace the FIRST exact occurrence of `search` in `filePath` with
    /// `replace`. `search` must match exactly once — zero or multiple matches
    /// are a refusal, so an edit is never applied to the wrong place.
    case replaceInFile(filePath: String, search: String, replace: String)

    var filePath: String {
        switch self {
        case .writeWholeFile(let filePath, _): return filePath
        case .replaceInFile(let filePath, _, _): return filePath
        }
    }
}

nonisolated enum MaintainFileEditApplier {

    enum ApplyError: Error, Equatable {
        case pathEscapesRepositoryRoot(path: String)
        case pathIsASymbolicLink(path: String)
        case fileIsABuildScript(path: String)
        case fileDoesNotExistForReplace(path: String)
        case fileCouldNotBeRead(path: String)
        case fileCouldNotBeWritten(path: String)
        case searchTextNotFound(path: String)
        case searchTextFoundMoreThanOnce(path: String, occurrences: Int)

        var readerFacingMessage: String {
            switch self {
            case .pathEscapesRepositoryRoot(let path): return "the edit targets \(path), outside the app's repository"
            case .pathIsASymbolicLink(let path): return "\(path) is a symbolic link, which Iris won't write through"
            case .fileIsABuildScript(let path): return "\(path) is a build file — declare that change with a manifest block, don't write it directly"
            case .fileDoesNotExistForReplace(let path): return "\(path) does not exist, so there is nothing to replace in it"
            case .fileCouldNotBeRead(let path): return "\(path) could not be read"
            case .fileCouldNotBeWritten(let path): return "\(path) could not be written"
            case .searchTextNotFound(let path): return "the text to replace was not found in \(path)"
            case .searchTextFoundMoreThanOnce(let path, let occurrences): return "the text to replace appears \(occurrences) times in \(path) — make it unique"
            }
        }
    }

    // MARK: - Parsing

    /// Why one file-edit block could not be turned into a request. These exist
    /// because the alternative — the block silently vanishing — is a lie the
    /// model has no way to detect: a reply whose only content was a malformed
    /// ```edit parsed to an EMPTY request list, which is byte-identical to "the
    /// reply contained no edit at all", so the loop fell through its whole
    /// dispatch and steered "Reply with exactly one ```bash fenced command" —
    /// advice about a mistake the model did not make, and that it cannot act
    /// on. The manifest parser was given exactly this treatment for exactly
    /// this reason; this is the same fix on the channel that carries the
    /// actual changes.
    enum ParseRejection: Error, Equatable {
        case blockFenceWasNeverClosed(verb: String, path: String)
        case blockNamesNoFilePath(verb: String)
        case editBlockHasNoSearchReplaceMarkers(path: String)
        case blockMayHaveEndedEarlyAtAFenceInItsContent(verb: String, path: String)

        /// Said to the MODEL, so it names the mistake and the repair.
        var modelFacingMessage: String {
            switch self {
            case .blockFenceWasNeverClosed(let verb, let path):
                return "your ```\(verb) block for \(path.isEmpty ? "(no path)" : path) was never closed "
                    + "with a matching fence line, so it could not be applied"
            case .blockNamesNoFilePath(let verb):
                return "a ```\(verb) block must name the repo-relative file path on its opening line "
                    + "(```\(verb) path/to/File.swift)"
            case .editBlockHasNoSearchReplaceMarkers(let path):
                return "the ```edit block for \(path) needs the three markers on their own lines, in order "
                    + "— <<<<<<< SEARCH, then =======, then >>>>>>> REPLACE — with non-empty search text"
            case .blockMayHaveEndedEarlyAtAFenceInItsContent(let verb, let path):
                return "your three-backtick ```\(verb) block for \(path) is ambiguous: the fences after it "
                    + "do not pair up, which is what happens when the content itself contains a ``` line and "
                    + "the block ended there instead of where you meant. Resend it opened with FOUR backticks "
                    + "(````\(verb) \(path)) so a ``` inside the content cannot close it"
            }
        }
    }

    /// The result of scanning one reply for file-edit blocks: what will be
    /// applied, and what was refused and why. Both halves matter — a reply can
    /// legitimately carry one good block and one broken one, and the good one
    /// must still land while the broken one is named.
    struct ParseOutcome: Equatable {
        let requests: [MaintainFileEditRequest]
        let rejections: [ParseRejection]

        /// True when the reply mentioned file editing at all, well or badly.
        /// The loop uses this to tell "this reply was about editing and got it
        /// wrong" apart from "this reply was about something else entirely".
        var replyAttemptedAFileEdit: Bool { !requests.isEmpty || !rejections.isEmpty }
    }

    /// Every file-edit block in a reply, in order, discarding the reasons any
    /// were refused. Kept because most callers only want the requests; the loop
    /// itself uses `parseDetailed`.
    static func parse(fromModelReply reply: String) -> [MaintainFileEditRequest] {
        parseDetailed(fromModelReply: reply).requests
    }

    /// Every file-edit block in a reply, in order, WITH the reason each refused
    /// block was refused. A ```write block's tag line is
    /// `write <repo-relative-path>`; a ```edit block's is `edit <path>` and its
    /// body holds a search/replace pair delimited by the conflict-marker format
    /// models produce reliably:
    ///
    ///     ```edit src/foo.rs
    ///     <<<<<<< SEARCH
    ///     old exact text
    ///     =======
    ///     new text
    ///     >>>>>>> REPLACE
    ///     ```
    ///
    /// A malformed block never discards a reply's good ones — it is reported
    /// alongside them.
    static func parseDetailed(fromModelReply reply: String) -> ParseOutcome {
        // Scanned directly from raw lines (NOT the shared `fencedBlocks`, whose
        // tag stops at the first space and would fold the path into the body):
        // find a `\`\`\`write <path>` / `\`\`\`edit <path>` opening line, take every
        // line up to the closing fence as the body, case-preserved. Fence
        // matching is by BACKTICK-RUN LENGTH: an opening run of N backticks
        // closes only on a run of at least N, so a ````write can carry an inner
        // ``` safely.
        //
        // The two limits an earlier version of this comment recorded as open are
        // now closed, and the comment says how rather than that they are gone:
        //   1. This DOES now agree with `MaintainTierCFixer.fencedBlocksWithSpans`
        //      about where a block starts and ends. That scanner used to close on
        //      a long-enough backtick run ANYWHERE on a line while this one has
        //      always required a backticks-only line, so the two disagreed and a
        //      truncated write leaked part of its body into the narration the
        //      reader sees. The scanner was moved onto this rule, not the other
        //      way round — `fencedBlockBoundaryRules` states it once for both.
        //   2. A THREE-backtick ```write whose content holds a bare ``` used to
        //      end at that inner fence SILENTLY and report success. It is now
        //      detected — see `fencesAfterAreUnbalanced` below — and refused with
        //      `blockMayHaveEndedEarlyAtAFenceInItsContent`, which tells the model
        //      to reopen it with four backticks. The prompt still asks for four
        //      backticks, but that request is now a convenience rather than the
        //      only thing standing between the reader and a truncated file.
        //
        // What remains genuinely open: a three-backtick write whose content's
        // stray fences happen to pair up AND which is the last block in the
        // reply is still indistinguishable from a correctly closed one. Four
        // backticks are the only complete answer; this catches the rest.
        var requests: [MaintainFileEditRequest] = []
        var rejections: [ParseRejection] = []
        let lines = reply.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let opening = lines[index].trimmingCharacters(in: .whitespaces)
            let openingBacktickCount = fencedBlockBoundaryRules.openingRunLength(of: lines[index])
            guard openingBacktickCount > 0 else { index += 1; continue }
            let afterFence = String(opening.dropFirst(openingBacktickCount))
            let verb: String? = afterFence == "write" || afterFence.hasPrefix("write ") ? "write"
                : (afterFence == "edit" || afterFence.hasPrefix("edit ") ? "edit" : nil)
            guard let verb else { index += 1; continue }
            let filePath = String(afterFence.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)

            // Body runs to the next line that is nothing but a backtick run of
            // at least the opening length.
            var bodyLines: [String] = []
            var cursor = index + 1
            var foundClose = false
            while cursor < lines.count {
                if fencedBlockBoundaryRules.isClosingFence(
                    lines[cursor], minimum: openingBacktickCount
                ) {
                    foundClose = true
                    break
                }
                bodyLines.append(lines[cursor]); cursor += 1
            }

            guard foundClose else {
                rejections.append(.blockFenceWasNeverClosed(verb: verb, path: filePath))
                index += 1
                continue
            }
            guard !filePath.isEmpty else {
                rejections.append(.blockNamesNoFilePath(verb: verb))
                index = cursor + 1
                continue
            }
            // A three-backtick block can be closed by a ``` line that was meant
            // to be CONTENT. The tell is downstream: if the fences after this
            // block no longer pair up — a bare fence with nothing open, or a
            // block left hanging at the end of the reply — then this block
            // almost certainly ended in the wrong place, and applying it would
            // write a truncated file while reporting success. Four-backtick
            // blocks cannot have this problem and are never checked.
            if openingBacktickCount == 3,
               fencesAfterAreUnbalanced(lines: lines, startingAfter: cursor) {
                rejections.append(.blockMayHaveEndedEarlyAtAFenceInItsContent(
                    verb: verb, path: filePath
                ))
                index = cursor + 1
                continue
            }

            let body = bodyLines.joined(separator: "\n")
            if verb == "write" {
                requests.append(.writeWholeFile(filePath: filePath, content: body))
            } else if let (search, replace) = parseSearchReplace(fromBody: body) {
                requests.append(.replaceInFile(filePath: filePath, search: search, replace: replace))
            } else {
                rejections.append(.editBlockHasNoSearchReplaceMarkers(path: filePath))
            }
            index = cursor + 1
        }
        return ParseOutcome(requests: requests, rejections: rejections)
    }

    /// Where a fenced block begins and ends, stated ONCE so the two scanners
    /// that need the answer cannot drift apart again. `parseDetailed` here and
    /// `MaintainTierCFixer.fencedBlocksWithSpans` both read block boundaries off
    /// these rules; they used to each have their own, disagreed about where a
    /// malformed block ended, and the visible symptom was half a write block
    /// showing up in the narration line the reader is told is Iris's own words.
    ///
    /// The rules are deliberately the stricter of the two originals, because a
    /// fence that opens mid-sentence is far more likely to be prose about code
    /// than a real block:
    ///   * an OPENING fence starts its line (leading whitespace allowed) and is
    ///     followed on that line by its tag, if it has one;
    ///   * a CLOSING fence is ALONE on its line, and is at least as long as the
    ///     opening run — which is what makes ````write a real, distinct
    ///     delimiter that a ``` in its content cannot close.
    enum fencedBlockBoundaryRules {
        /// The backtick-run length at the start of `line`, or 0 if it does not
        /// begin one of at least three.
        static func openingRunLength(of line: String) -> Int {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let run = trimmed.prefix(while: { $0 == "`" }).count
            return run >= 3 ? run : 0
        }

        /// Whether `line` is nothing but a backtick run of at least `minimum`.
        static func isClosingFence(_ line: String, minimum: Int) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let run = trimmed.prefix(while: { $0 == "`" }).count
            return run >= minimum && run == trimmed.count && run >= 3
        }

        /// Whether `line` is a bare fence — a run alone on its line, opening
        /// nothing. In a well-formed reply one of these only ever appears as
        /// the CLOSE of a block that is already open.
        static func isBareFence(_ line: String) -> Bool {
            isClosingFence(line, minimum: 3)
        }
    }

    /// Whether the fences from `startingAfter` to the end of the reply fail to
    /// pair up: a bare fence turning up with no block open, or a block left
    /// open when the reply ends.
    ///
    /// This is the signal that a three-backtick block above ended in the wrong
    /// place. When a ```write closes early on a ``` that was meant to be part of
    /// its content, everything after inherits the mistake — the model's REAL
    /// closing fence is then read as opening something, and the books stop
    /// balancing. When the block ended where the model intended, every fence
    /// after it is either a tagged opening or the close of one, and they do.
    static func fencesAfterAreUnbalanced(lines: [String], startingAfter closeIndex: Int) -> Bool {
        var openRunLength: Int?
        var index = closeIndex + 1
        while index < lines.count {
            let line = lines[index]
            if let open = openRunLength {
                if fencedBlockBoundaryRules.isClosingFence(line, minimum: open) { openRunLength = nil }
            } else {
                let run = fencedBlockBoundaryRules.openingRunLength(of: line)
                if run > 0 {
                    // A bare fence with nothing open closes a block that was
                    // never opened here — the books are already wrong.
                    if fencedBlockBoundaryRules.isBareFence(line) { return true }
                    openRunLength = run
                }
            }
            index += 1
        }
        // A block still open at the end of the reply is the other half of the
        // same failure.
        return openRunLength != nil
    }

    /// Pull the SEARCH and REPLACE halves out of an ```edit body. Tolerant of
    /// the exact marker widths (`<<<<<<<`, `=======`, `>>>>>>>`) as long as the
    /// three markers appear in order on their own lines.
    static func parseSearchReplace(fromBody body: String) -> (search: String, replace: String)? {
        let lines = body.components(separatedBy: "\n")
        var searchStart: Int?, divider: Int?, replaceEnd: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if searchStart == nil, trimmed.hasPrefix("<<<<<<<") { searchStart = index }
            else if searchStart != nil, divider == nil, trimmed.hasPrefix("=======") { divider = index }
            else if divider != nil, replaceEnd == nil, trimmed.hasPrefix(">>>>>>>") { replaceEnd = index }
        }
        guard let s = searchStart, let d = divider, let r = replaceEnd, s < d, d < r else { return nil }
        let search = lines[(s + 1)..<d].joined(separator: "\n")
        let replace = lines[(d + 1)..<r].joined(separator: "\n")
        // An empty search would match everywhere; refuse it at parse time.
        return search.isEmpty ? nil : (search, replace)
    }

    // MARK: - Applying (Iris's own code, never the jailed shell)

    /// Apply one request to the repo. Returns the applied path on success.
    static func applyToRepo(
        _ request: MaintainFileEditRequest, repoRootPath: String
    ) -> Result<String, ApplyError> {
        let relativePath = request.filePath
        // Build-script files never go through here — they must be declared via
        // the manifest channel so the un-jailed build's executed inputs stay
        // code-adjudicated.
        if MaintainBuildScriptGuard.isBuildScriptFile(relativePath) {
            return .failure(.fileIsABuildScript(path: relativePath))
        }
        guard let resolvedPath = repoConfinedAbsolutePath(relativePath, repoRootPath: repoRootPath) else {
            return .failure(.pathEscapesRepositoryRoot(path: relativePath))
        }
        // Never write THROUGH a symlink (a model could plant one inside the
        // jail pointing out of the repo).
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
           (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            return .failure(.pathIsASymbolicLink(path: relativePath))
        }

        switch request {
        case .writeWholeFile(_, let content):
            let parentDirectory = (resolvedPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: parentDirectory, withIntermediateDirectories: true
            )
            do {
                try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                return .success("wrote \(relativePath) (\(content.count) chars)")
            } catch {
                return .failure(.fileCouldNotBeWritten(path: relativePath))
            }

        case .replaceInFile(_, let search, let replace):
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                return .failure(.fileDoesNotExistForReplace(path: relativePath))
            }
            guard let original = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
                return .failure(.fileCouldNotBeRead(path: relativePath))
            }
            let occurrences = original.components(separatedBy: search).count - 1
            guard occurrences != 0 else { return .failure(.searchTextNotFound(path: relativePath)) }
            guard occurrences == 1 else {
                return .failure(.searchTextFoundMoreThanOnce(path: relativePath, occurrences: occurrences))
            }
            guard let matchRange = original.range(of: search) else {
                return .failure(.searchTextNotFound(path: relativePath))
            }
            let edited = original.replacingCharacters(in: matchRange, with: replace)
            do {
                try edited.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                return .success("edited \(relativePath)")
            } catch {
                return .failure(.fileCouldNotBeWritten(path: relativePath))
            }
        }
    }

    /// A one-line human summary of the applied requests, for the transcript.
    static func appliedSummary(_ appliedPaths: [String]) -> String {
        appliedPaths.joined(separator: ", ")
    }

    // MARK: - Path confinement

    /// The absolute on-disk path for a repo-relative path, or nil if it would
    /// escape the repo root (standardized AND, for an existing parent,
    /// symlink-resolved). Mirrors the manifest applier's confinement.
    private static func repoConfinedAbsolutePath(
        _ relativePath: String, repoRootPath: String
    ) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.contains("..") else { return nil }
        let rootStandard = (repoRootPath as NSString).standardizingPath
        let candidate = ((rootStandard as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        // The candidate must sit under the root by prefix. Resolve the existing
        // parent chain's symlinks so a linked directory can't relocate it.
        let parent = (candidate as NSString).deletingLastPathComponent
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        let resolvedRoot = (rootStandard as NSString).resolvingSymlinksInPath
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
            return nil
        }
        return candidate
    }
}
