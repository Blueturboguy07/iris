//
//  FeatureEditRepositoryContext.swift
//  leanring-buddy
//
//  A small, explicit source-context boundary for model prompts. The repo map
//  tells the caller which unchanged files are relevant; this helper reads only
//  those paths, keeps complete UTF-8 files under a byte budget, and reports
//  omitted context so a reviewer cannot mistake an unseen file for a missing
//  guard.
//

import Foundation
import Darwin

/// One complete, UTF-8 file included in a bounded repository context.
nonisolated struct FeatureEditRepositoryContextFile: Sendable, Equatable {
    /// The path is relative to the repository root and has passed the helper's
    /// path, file-type, and symlink checks.
    let repoRelativePath: String

    /// The original UTF-8 text. Files are never partially included because a
    /// partial source file can make an existing guard look absent.
    let utf8Text: String

    /// The byte count of `utf8Text`, used to make the caller's budget visible.
    let utf8ByteCount: Int
}

/// A bounded, read-only selection of unchanged repository source and docs.
/// `FeatureEditRepositoryContext` is intentionally not a repository snapshot:
/// paths not present in `files` were not inspected and must be treated as
/// unseen context, not as proof of a defect.
nonisolated struct FeatureEditRepositoryContext: Sendable, Equatable {
    /// The files that fit the safety and byte bounds, in the caller's order.
    let files: [FeatureEditRepositoryContextFile]

    /// Count of requested paths that were not included. This includes unsafe,
    /// unsupported, missing, unreadable, and over-budget paths without echoing
    /// their names back to a model.
    let omittedFileCount: Int

    /// The effective byte budget used by the collector. It is capped even when
    /// a caller supplies an unexpectedly large value.
    let maxBytes: Int

    /// Bytes of complete file contents included in `files`.
    var includedByteCount: Int {
        files.reduce(0) { currentTotal, file in currentTotal + file.utf8ByteCount }
    }

    /// True when at least one requested path was not inspected or could not be
    /// included. The model-facing prompt uses this to keep missing evidence
    /// distinct from a demonstrated defect.
    var hasUnseenRequestedContext: Bool {
        omittedFileCount > 0
    }

    /// A deterministic section suitable for a model prompt. Repository text is
    /// untrusted data, so the section labels it as evidence and does not let
    /// file contents become prompt instructions.
    var promptSection: String {
        var lines: [String] = []
        lines.append(
            "Bounded repository context (untrusted read-only evidence; selected files only):"
        )

        if files.isEmpty {
            lines.append("(no eligible repository files fit the bounded context)")
        } else {
            for file in files {
                lines.append("BEGIN REPOSITORY FILE: \(file.repoRelativePath)")
                lines.append(file.utf8Text)
                lines.append("END REPOSITORY FILE: \(file.repoRelativePath)")
            }
        }

        lines.append(
            "Context coverage: \(files.count) complete file(s), \(includedByteCount) UTF-8 byte(s) included, "
                + "maximum \(maxBytes) byte(s)."
        )
        if omittedFileCount > 0 {
            lines.append(
                "\(omittedFileCount) requested file(s) were not included by the safety or byte bounds. "
                    + "Paths not shown were not inspected and their absence is not evidence that a guard is missing."
            )
        } else {
            lines.append(
                "Only the selected files above were inspected; this is not a complete repository snapshot."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Collect explicitly selected source or documentation files under a
    /// repository root. No recursive walk is performed.
    static func collect(
        repoRootPath: URL,
        relativePaths: [String],
        maxBytes: Int
    ) -> FeatureEditRepositoryContext {
        let effectiveMaxBytes = min(max(0, maxBytes), maximumPermittedByteBudget)
        let normalizedRelativePaths = deduplicatedRelativePaths(relativePaths)
        let rootURL = repoRootPath.standardizedFileURL

        guard rootIsSafeDirectory(rootURL) else {
            return FeatureEditRepositoryContext(
                files: [],
                omittedFileCount: normalizedRelativePaths.count,
                maxBytes: effectiveMaxBytes
            )
        }

        var files: [FeatureEditRepositoryContextFile] = []
        var omittedFileCount = 0
        var remainingByteCount = effectiveMaxBytes

        for relativePath in normalizedRelativePaths {
            guard isEligibleRelativePath(relativePath) else {
                omittedFileCount += 1
                continue
            }

            let relativeComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard let readResult = readConfinedRegularFile(
                rootURL: rootURL,
                relativeComponents: relativeComponents,
                maximumByteCount: remainingByteCount
            ), let text = String(data: readResult.data, encoding: .utf8) else {
                omittedFileCount += 1
                continue
            }

            files.append(FeatureEditRepositoryContextFile(
                repoRelativePath: relativePath,
                utf8Text: text,
                utf8ByteCount: readResult.byteCount
            ))
            remainingByteCount -= readResult.byteCount
        }

        return FeatureEditRepositoryContext(
            files: files,
            omittedFileCount: omittedFileCount,
            maxBytes: effectiveMaxBytes
        )
    }

    /// String convenience for the app's existing clone-path APIs.
    static func collect(
        repoRootPath: String,
        relativePaths: [String],
        maxBytes: Int
    ) -> FeatureEditRepositoryContext {
        collect(
            repoRootPath: URL(fileURLWithPath: repoRootPath, isDirectory: true),
            relativePaths: relativePaths,
            maxBytes: maxBytes
        )
    }

    /// Collect the bounded review context in priority order. Changed tests and
    /// declared native tests stay ahead of changed sources, then one local
    /// import hop, then the caller's same-directory fallback paths. The first
    /// pass reads changed files through this type's confined collector so
    /// dependency discovery cannot follow a symlink or escape the clone.
    static func collectReviewContext(
        repoRootPath: String,
        changedTestPaths: [String],
        declaredNativeTestPaths: [String],
        changedPaths: [String],
        sameDirectoryNeighborPaths: [String],
        preferredDependencySourceByPath: [String: String] = [:],
        isNativeFinalReview: Bool = false,
        maxFileCount: Int = maximumPermittedReviewFileCount,
        maxBytes: Int = maximumPermittedByteBudget
    ) -> FeatureEditRepositoryContext {
        let effectiveFileCount = min(
            max(0, maxFileCount),
            maximumPermittedReviewFileCount
        )
        guard effectiveFileCount > 0 else {
            return collect(repoRootPath: repoRootPath, relativePaths: [], maxBytes: maxBytes)
        }

        let normalizedChangedPaths = deduplicatedRelativePaths(changedPaths)
        let changedSourceContext = collect(
            repoRootPath: repoRootPath,
            relativePaths: Array(normalizedChangedPaths.prefix(maximumDependencySourceFileCount)),
            maxBytes: maximumPermittedByteBudget
        )
        let directDependencyPaths = directDependencyPaths(
            from: changedSourceContext.files,
            repoRootPath: repoRootPath,
            preferredDependencySourceByPath: preferredDependencySourceByPath
        )
        let orderedPaths = deduplicatedRelativePaths(
            (isNativeFinalReview
                ? declaredNativeTestPaths + changedTestPaths
                : changedTestPaths + declaredNativeTestPaths)
                + normalizedChangedPaths
                + directDependencyPaths
                + sameDirectoryNeighborPaths
        )

        return collect(
            repoRootPath: repoRootPath,
            relativePaths: Array(orderedPaths.prefix(effectiveFileCount)),
            maxBytes: maxBytes
        )
    }

    /// Best-effort priority hints, never a source of file contents or authority.
    /// Unsupported quoted headers fall back to the normal dependency order.
    static func addedDependencySourceByPath(in unifiedDiff: String) -> [String: String] {
        var addedSource: [String: String] = [:]
        var currentPath: String?
        var inHunk = false
        var remainingBytes = maximumPermittedByteBudget
        let boundedDiff = String(decoding: unifiedDiff.utf8.prefix(maximumPermittedByteBudget), as: UTF8.self)
        for line in boundedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                currentPath = nil
                inHunk = false
            } else if !inHunk && line.hasPrefix("+++ b/") {
                let path = String(line.dropFirst(6))
                currentPath = isEligibleRelativePath(path) ? path : nil
            } else if line.hasPrefix("@@") {
                inHunk = line.range(of: #"^@@ -[0-9]+(?:,[0-9]+)? \+[0-9]+(?:,[0-9]+)? @@"#,
                    options: .regularExpression) != nil
                if let currentPath, addedSource[currentPath] != nil, remainingBytes >= 2 {
                    addedSource[currentPath, default: ""] += ";\n"
                    remainingBytes -= 2
                }
            } else if inHunk, let currentPath {
                let fragment = line.hasPrefix("+") ? String(line.dropFirst()) + "\n" : ";\n"
                let bytes = fragment.utf8.count
                guard bytes <= remainingBytes else { break }
                remainingBytes -= bytes
                addedSource[currentPath, default: ""] += fragment
            }
        }
        return addedSource
    }

    // MARK: - Bounds and path checks

    /// A hard ceiling prevents a malformed caller from turning this helper
    /// into an unbounded prompt loader. Callers should normally use a much
    /// smaller review-specific budget.
    static let maximumPermittedByteBudget = 64 * 1024

    /// The review selector never places more than this many paths into the
    /// final collector request, even when a caller supplies a larger value.
    static let maximumPermittedReviewFileCount = 24

    private static let supportedModuleExtensions = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
    ]

    private static let localModuleSpecifierRegex = try! NSRegularExpression(
        pattern: #"(?:\bimport\b[^;]*?\bfrom\s*|\bimport\s*|\bexport\b[^;]*?\bfrom\s*|\brequire\s*\(\s*)[\"'](\.{1,2}/[^\"']+)[\"']"#,
        options: []
    )

    private static let maximumDependencySourceFileCount = 24
    private static let maximumDependencySpecifierCount = 64
    private static let maximumDependencyCandidateProbeCount = 128
    private static let maximumResolvedDependencyCount = 24

    /// The source extensions understood by the repo map, plus common authored
    /// source files that can be useful to a caller outside those six languages.
    private static let allowedSourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "dart", "css", "cs", "fs", "fsx", "go", "h", "hpp",
        "html", "java", "js", "mjs", "cjs", "jsx", "kt", "kts", "m", "mm", "php", "py", "rb",
        "rs", "scala", "sh", "sql", "swift", "svelte", "ts", "tsx", "vue", "xml", "zig", "zsh",
    ]

    /// Documentation extensions and extensionless documentation names. JSON,
    /// YAML, plist, lockfiles, and environment files are deliberately absent:
    /// they are configuration or secret-bearing surfaces, not context sources.
    private static let allowedDocumentationExtensions: Set<String> = [
        "adoc", "markdown", "md", "rst", "text", "txt",
    ]

    private static let allowedExtensionlessDocumentationNames: Set<String> = [
        "CHANGELOG", "CONTRIBUTING", "LICENSE", "NOTICE", "README", "SECURITY",
    ]

    private static let rejectedExtensions: Set<String> = [
        "cfg", "conf", "env", "ini", "json", "key", "lock", "pem", "plist", "p12", "pfx",
        "secret", "secrets", "toml", "yaml", "yml",
    ]

    private static let rejectedExtensionlessNames: Set<String> = [
        "CREDENTIALS", "DOCKERFILE", "GEMFILE", "MAKEFILE", "PODFILE", "VAGRANTFILE",
    ]

    private static func deduplicatedRelativePaths(_ relativePaths: [String]) -> [String] {
        var seenPaths: Set<String> = []
        var deduplicatedPaths: [String] = []
        for relativePath in relativePaths {
            if seenPaths.insert(relativePath).inserted {
                deduplicatedPaths.append(relativePath)
            }
        }
        return deduplicatedPaths
    }

    /// Extract only static local module references. Package names and aliases
    /// are intentionally ignored because resolving them would require a wider
    /// repository walk or dependency metadata outside this review boundary.
    private static func localModuleSpecifiers(in sourceText: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var specifiers: [String] = []
        var seenSpecifiers: Set<String> = []
        let sourceRange = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
        localModuleSpecifierRegex.enumerateMatches(in: sourceText, options: [], range: sourceRange) {
            match,
            _,
            stop in
            guard let match,
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: sourceText) else { return }
            let specifier = String(sourceText[captureRange])
            if seenSpecifiers.insert(specifier).inserted {
                specifiers.append(specifier)
                if specifiers.count >= limit {
                    stop.pointee = true
                }
            }
        }
        return specifiers
    }

    /// Return one hop of local module paths that passed the same confined
    /// collector used for the final prompt. A missing, unreadable, oversized,
    /// or symlinked candidate is not treated as a resolved dependency.
    private static func directDependencyPaths(
        from changedFiles: [FeatureEditRepositoryContextFile],
        repoRootPath: String,
        preferredDependencySourceByPath: [String: String] = [:]
    ) -> [String] {
        var dependencies: [String] = []
        var seenDependencies: Set<String> = []
        var seenSpecifierSets: Set<String> = []
        var candidateProbeResults: [String: Bool] = [:]
        var candidateProbeCount = 0

        let changedFilesForDependencyDiscovery = Array(
            changedFiles.prefix(maximumDependencySourceFileCount)
        )
        let specifiersByChangedFile = changedFilesForDependencyDiscovery.map {
            localModuleSpecifiers(
                in: $0.utf8Text,
                limit: maximumDependencySpecifierCount
            )
        }
        var nextSpecifierIndexByChangedFile = Array(
            repeating: 0,
            count: changedFilesForDependencyDiscovery.count
        )
        var interleavedSpecifierPairs: [
            (changedFile: FeatureEditRepositoryContextFile, specifier: String)
        ] = []
        while interleavedSpecifierPairs.count < maximumDependencySpecifierCount {
            var consumedSpecifier = false
            for changedFileIndex in changedFilesForDependencyDiscovery.indices {
                guard interleavedSpecifierPairs.count < maximumDependencySpecifierCount else {
                    break
                }
                let specifierIndex = nextSpecifierIndexByChangedFile[changedFileIndex]
                guard specifierIndex < specifiersByChangedFile[changedFileIndex].count else {
                    continue
                }
                consumedSpecifier = true
                nextSpecifierIndexByChangedFile[changedFileIndex] += 1
                let changedFile = changedFilesForDependencyDiscovery[changedFileIndex]
                let specifier = specifiersByChangedFile[changedFileIndex][specifierIndex]
                let specifierSetKey = changedFile.repoRelativePath + "\u{0}" + specifier
                guard seenSpecifierSets.insert(specifierSetKey).inserted else { continue }
                interleavedSpecifierPairs.append((changedFile: changedFile, specifier: specifier))
            }
            guard consumedSpecifier else { break }
        }

        // Reorder the same bounded candidate list, not a second discovery pass.
        // A diff hint cannot add a dependency absent from current safe source.
        let preferredSpecifiersByPath = Dictionary(uniqueKeysWithValues:
            changedFilesForDependencyDiscovery.map { file in
                (file.repoRelativePath, Set(localModuleSpecifiers(
                    in: String((preferredDependencySourceByPath[file.repoRelativePath] ?? "")
                        .prefix(maximumPermittedByteBudget)),
                    limit: maximumDependencySpecifierCount)))
            })
        func isPreferred(_ pair: (changedFile: FeatureEditRepositoryContextFile, specifier: String)) -> Bool {
            preferredSpecifiersByPath[pair.changedFile.repoRelativePath]?.contains(pair.specifier) == true
        }
        let orderedSpecifierPairs = interleavedSpecifierPairs.filter { isPreferred($0) }
            + interleavedSpecifierPairs.filter { !isPreferred($0) }
        for specifierPair in orderedSpecifierPairs {
            let candidates = moduleCandidates(
                for: specifierPair.specifier,
                importingPath: specifierPair.changedFile.repoRelativePath
            )
            var resolvedPath: String?
            for candidate in candidates {
                if let wasEligible = candidateProbeResults[candidate] {
                    if wasEligible {
                        resolvedPath = candidate
                        break
                    }
                    continue
                }
                guard candidateProbeCount < maximumDependencyCandidateProbeCount else {
                    return dependencies
                }
                candidateProbeCount += 1
                let wasEligible = collect(
                    repoRootPath: repoRootPath,
                    relativePaths: [candidate],
                    maxBytes: maximumPermittedByteBudget
                ).files.count == 1
                candidateProbeResults[candidate] = wasEligible
                if wasEligible {
                    resolvedPath = candidate
                    break
                }
            }
            guard let resolvedPath else { continue }
            if seenDependencies.insert(resolvedPath).inserted {
                dependencies.append(resolvedPath)
                if dependencies.count >= maximumResolvedDependencyCount {
                    return dependencies
                }
            }
        }
        return dependencies
    }

    /// Resolve a relative JavaScript or TypeScript module without consulting
    /// aliases, package metadata, or a parent directory outside the clone.
    private static func moduleCandidates(
        for specifier: String,
        importingPath: String
    ) -> [String] {
        guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else { return [] }
        guard let normalizedPath = normalizedLocalModulePath(
            specifier: specifier,
            importingPath: importingPath
        ) else { return [] }

        let fileExtension = (normalizedPath as NSString).pathExtension.lowercased()
        let pathStem: String
        if supportedModuleExtensions.contains(fileExtension) {
            pathStem = (normalizedPath as NSString).deletingPathExtension
        } else if fileExtension.isEmpty {
            pathStem = normalizedPath
        } else {
            return []
        }

        var candidates: [String] = [normalizedPath]
        if !fileExtension.isEmpty {
            if ["js", "jsx", "mjs", "cjs"].contains(fileExtension) {
                candidates.append(pathStem + ".ts")
                candidates.append(pathStem + ".tsx")
            }
        } else {
            candidates.removeAll(keepingCapacity: true)
            for extensionName in supportedModuleExtensions {
                candidates.append(pathStem + "." + extensionName)
            }
            for extensionName in supportedModuleExtensions {
                candidates.append(pathStem + "/index." + extensionName)
            }
        }
        return deduplicatedRelativePaths(candidates)
    }

    /// Normalize a local specifier component-by-component. An upward step that
    /// would leave the repository has no candidate and is never handed to the
    /// collector.
    private static func normalizedLocalModulePath(
        specifier: String,
        importingPath: String
    ) -> String? {
        var components = importingPath.split(separator: "/").dropLast().map(String.init)
        for component in specifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            guard !component.isEmpty, !component.contains("\0") else { return nil }
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    private static func rootIsSafeDirectory(_ rootURL: URL) -> Bool {
        guard
            let values = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else { return false }
        return true
    }

    private static func isEligibleRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.contains("\0") else { return false }
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }

        let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !pathComponents.isEmpty, !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        guard !pathComponents.contains(where: { $0.hasPrefix(".") }) else { return false }

        let fileName = pathComponents.last ?? ""
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if rejectedExtensions.contains(fileExtension) {
            return false
        }
        if fileExtension.isEmpty,
           rejectedExtensionlessNames.contains(fileName.uppercased()) {
            return false
        }
        if !fileExtension.isEmpty {
            return allowedSourceExtensions.contains(fileExtension)
                || allowedDocumentationExtensions.contains(fileExtension)
        }
        return allowedExtensionlessDocumentationNames.contains(fileName.uppercased())
    }

    /// Shared by callers that select operator-declared source paths before
    /// handing them to this collector. Keep the extension and filename rules
    /// in one place so a native evidence hint cannot widen the review reader.
    static func isEligibleSourcePath(_ relativePath: String) -> Bool {
        isEligibleRelativePath(relativePath)
    }

    private struct ReadRepositoryFileResult {
        let data: Data
        let byteCount: Int
    }

    /// Open from the root descriptor so a renamed or replaced path cannot turn
    /// a checked relative path into an outside read. Every component uses
    /// `O_NOFOLLOW`; the final descriptor also uses non-blocking open so a FIFO
    /// is rejected by `fstat` instead of blocking before it can be classified.
    private static func readConfinedRegularFile(
        rootURL: URL,
        relativeComponents: [String],
        maximumByteCount: Int
    ) -> ReadRepositoryFileResult? {
        guard !relativeComponents.isEmpty else { return nil }

        let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootDescriptor = rootURL.path.withCString {
            open($0, directoryOpenFlags)
        }
        guard rootDescriptor >= 0 else { return nil }

        var directoryDescriptor = rootDescriptor
        for directoryComponent in relativeComponents.dropLast() {
            let nextDirectoryDescriptor = directoryComponent.withCString {
                openat(directoryDescriptor, $0, directoryOpenFlags)
            }
            guard nextDirectoryDescriptor >= 0 else {
                close(directoryDescriptor)
                return nil
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDirectoryDescriptor
        }

        guard let fileName = relativeComponents.last else {
            close(directoryDescriptor)
            return nil
        }
        let fileOpenFlags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let fileDescriptor = fileName.withCString {
            openat(directoryDescriptor, $0, fileOpenFlags)
        }
        close(directoryDescriptor)
        guard fileDescriptor >= 0 else { return nil }

        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? fileHandle.close() }

        var initialInformation = stat()
        guard fstat(fileDescriptor, &initialInformation) == 0,
              isRegularFile(initialInformation),
              let byteCount = safeByteCount(from: initialInformation),
              byteCount <= maximumByteCount else { return nil }

        guard let data = try? fileHandle.read(upToCount: maximumByteCount + 1),
              data.count == byteCount else { return nil }

        var finalInformation = stat()
        guard fstat(fileDescriptor, &finalInformation) == 0,
              isRegularFile(finalInformation),
              finalInformation.st_dev == initialInformation.st_dev,
              finalInformation.st_ino == initialInformation.st_ino,
              finalInformation.st_size == initialInformation.st_size else {
            return nil
        }
        return ReadRepositoryFileResult(data: data, byteCount: byteCount)
    }

    private static func isRegularFile(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFREG
    }

    private static func safeByteCount(from information: stat) -> Int? {
        guard information.st_size >= 0,
              information.st_size <= off_t(Int.max) else { return nil }
        return Int(information.st_size)
    }
}
