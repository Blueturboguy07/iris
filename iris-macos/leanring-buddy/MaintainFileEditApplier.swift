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

    /// Every file-edit block in a reply, in order. A ```write block's tag line
    /// is `write <repo-relative-path>`; a ```edit block's is `edit <path>` and
    /// its body holds a search/replace pair delimited by the conflict-marker
    /// format models produce reliably:
    ///
    ///     ```edit src/foo.rs
    ///     <<<<<<< SEARCH
    ///     old exact text
    ///     =======
    ///     new text
    ///     >>>>>>> REPLACE
    ///     ```
    ///
    /// A malformed block is skipped (not a hard error) — the model is told and
    /// retries — so one bad block never discards a reply's good ones.
    static func parse(fromModelReply reply: String) -> [MaintainFileEditRequest] {
        // Scanned directly from raw lines (NOT the shared `fencedBlocks`, whose
        // tag stops at the first space and would fold the path into the body):
        // find a `\`\`\`write <path>` / `\`\`\`edit <path>` opening line, take every
        // line up to the closing `\`\`\`` as the body, case-preserved.
        var requests: [MaintainFileEditRequest] = []
        let lines = reply.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let opening = lines[index].trimmingCharacters(in: .whitespaces)
            let verb: String? = opening.hasPrefix("```write ") ? "write"
                : (opening.hasPrefix("```edit ") ? "edit" : nil)
            guard let verb else { index += 1; continue }
            let filePath = String(opening.dropFirst(("```" + verb + " ").count)).trimmingCharacters(in: .whitespaces)
            // Body runs to the next line that is exactly a closing fence.
            var bodyLines: [String] = []
            var cursor = index + 1
            var foundClose = false
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "```" { foundClose = true; break }
                bodyLines.append(lines[cursor]); cursor += 1
            }
            if !filePath.isEmpty && foundClose {
                let body = bodyLines.joined(separator: "\n")
                if verb == "write" {
                    requests.append(.writeWholeFile(filePath: filePath, content: body))
                } else if let (search, replace) = parseSearchReplace(fromBody: body) {
                    requests.append(.replaceInFile(filePath: filePath, search: search, replace: replace))
                }
            }
            index = foundClose ? cursor + 1 : index + 1
        }
        return requests
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
